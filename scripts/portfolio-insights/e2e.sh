#!/usr/bin/env bash
# Portfolio Insights reachability and API end-to-end check against one running Compose project.
# It walks the feature's 13 end-to-end steps through the reverse proxy: the flag off, a fixture
# of two fresh accounts, enabling the flag, the insights figures, the empty account, every
# documented 400 and 404, alert CRUD for both types, a trigger within two evaluation cycles, no
# second notification, the browser check in both modes, an untriggered acknowledge, and cleanup.
# Run it from the repository root, once per dialect, against a project whose stack is up.
#
# Usage: scripts/portfolio-insights/e2e.sh --project NAME [--base-url URL]
#            [--compose-file FILE] [--evidence-dir DIR]
#   --project NAME       Compose project of the running stack (required)
#   --base-url URL       Reverse-proxy origin of that stack (default: http://localhost)
#   --compose-file FILE  Compose file of that project, relative to the current directory
#                        (default: compose.dev.yaml)
#   --evidence-dir DIR   Directory the browser check writes its evidence to
#                        (default: the run directory)
#   --help               Show this help and exit
#
# One project and one dialect per invocation. Never run it alongside perf.sh or
# loadgen-check.sh: all three toggle the same portfolio-insights-enabled flag.
#
# What it touches: it signs up two fresh accounts, pi-e2e-<epoch>-holder and
# pi-e2e-<epoch>-empty, deposits to and buys on the holder only, creates alerts on them, and
# toggles no flag but portfolio-insights-enabled. No preset account is used. On exit, normal or
# not, it deletes every alert it created by id and restores the flag to the value it read at
# start; a second interrupt during that cleanup abandons it and fails the cleanup check. The two
# accounts remain, because no account-deletion endpoint exists.
#
# Prints one PASS or FAIL line per check, INFO lines (the browser check's own output among them,
# prefixed) and a final SUMMARY line; a FAIL line never shows a fixture password. Exits 0 when
# every check passes, 1 when any check fails, 2 on a usage error, a missing tool or a private
# directory it cannot restrict to the current user, and 130 when interrupted. The generated
# passwords exist only in the fixture, which sits with the raw HTTP responses in a private
# directory outside the run directory that only the current user can open (an ACL set with
# icacls on Windows, mode 700 elsewhere). On exit, normal, failed or interrupted, both are
# removed, and a removal that fails fails the cleanup check. The run directory, printed at start
# and end, keeps the browser evidence (unless --evidence-dir names another directory) and
# working files the run derives, never a copy of a response body.

# shellcheck disable=SC2016 # jq filters are single-quoted on purpose: their $names are jq's own.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

FLAG_ID="portfolio-insights-enabled"
# The readiness pair, the database path, user-service for the signups and pricing-service for
# insights and evaluation: any of them down would only surface later as a confusing 5xx.
REQUIRED_SERVICES="broker-service db db-adapter feature-flag-service pricing-service reverse-proxy user-service"
READY_TIMEOUT_SECONDS=300
READY_STEP_SECONDS=5
HTTP_TIMEOUT_SECONDS=15
NOTIFY_STEP_SECONDS=5
LOG_STEP_SECONDS=5
# A line the broker has already written is awaited this long, so log shipping lag is no failure.
LOG_LINE_TIMEOUT_SECONDS=30
# Log windows start this far back so a host clock ahead of the Docker engine's loses no line;
# lines already present when a window opens are counted as its baseline, never read as new.
LOG_SKEW_MARGIN_SECONDS=30
# Cleanup stops sending DELETEs after this many transport errors in a row.
MAX_CONSECUTIVE_TRANSPORT_ERRORS=5
# The threshold domain maximum (10 integer and 8 fractional digits), sent as the exact token.
MAX_THRESHOLD="9999999999.99999999"
# A close of C units of 1e-8 in this range keeps both C - 1 and C + 1 inside the TARGET_PRICE
# threshold domain, which is above 0 and at most MAX_THRESHOLD.
MIN_CLOSE_UNITS=2
MAX_CLOSE_UNITS=999999999999999998
# Any observed P/L percent is above the first or below the second, so one member triggers.
PL_ABOVE_THRESHOLD="-0.00000001"
PL_BELOW_THRESHOLD="0.00000001"
PACKAGE_ID="a0000000-0000-4000-8000-000000000001"
DEPOSIT_AMOUNT=10000
FORBIDDEN_BODY='{"error":"feature_disabled"}'
# The broker's interval rule: a whole number from 1 to 4294967 seconds, otherwise 60.
DEFAULT_INTERVAL_SECONDS=60
MAX_INTERVAL_SECONDS=4294967

CYCLE_MARKER="Alert evaluation cycle finished"
TRIGGER_MARKER="] triggered for account ["
# "Alert [<id>] triggered for account [<account>] type [..] direction [..] threshold [..]
# value [..] revision [<n>]", as AlertEvaluationService renders it.
TRIGGER_RE='Alert \[([0-9a-fA-F-]{36})\] triggered for account \[[^]]*\] .*revision \[([0-9]+)\]'
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
THRESHOLD_TOKEN_RE='^-?(0|[1-9][0-9]*)(\.[0-9]+)?$'
PAIRS="target_price profit_loss"

usage() {
    cat <<'EOF'
Usage: scripts/portfolio-insights/e2e.sh --project NAME [--base-url URL]
           [--compose-file FILE] [--evidence-dir DIR]
  --project NAME       Compose project of the running stack (required)
  --base-url URL       Reverse-proxy origin of that stack (default: http://localhost)
  --compose-file FILE  Compose file of that project, relative to the current directory
                       (default: compose.dev.yaml)
  --evidence-dir DIR   Directory the browser check writes its evidence to
                       (default: the run directory)
  --help               Show this help and exit
Run one project at a time, never alongside perf.sh or loadgen-check.sh.
EOF
}

usage_error() {
    echo "$1" >&2
    usage >&2
    exit 2
}

BASE_URL="http://localhost"
COMPOSE_FILE="compose.dev.yaml"
PROJECT=""
EVIDENCE_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-url | --compose-file | --project | --evidence-dir)
            if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
                usage_error "Option $1 requires a value."
            fi
            case "$1" in
                --base-url) BASE_URL="$2" ;;
                --compose-file) COMPOSE_FILE="$2" ;;
                --project) PROJECT="$2" ;;
                --evidence-dir) EVIDENCE_DIR="$2" ;;
            esac
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            usage_error "Unknown option: $1"
            ;;
    esac
done

if [[ -z "$PROJECT" ]]; then
    usage_error "Option --project is required."
fi
# The browser check serves the app from the origin's root, so a path is refused here as well.
if [[ ! "$BASE_URL" =~ ^https?://[^/?#[:space:]]+/?$ ]]; then
    usage_error "Option --base-url needs an http:// or https:// origin without a path, got: $BASE_URL"
fi
BASE_URL="${BASE_URL%/}"
if [[ ! -f "$COMPOSE_FILE" ]]; then
    usage_error "Compose file not found: $COMPOSE_FILE (resolved from $(pwd); the repository root is $REPO_ROOT)"
fi

missing_tools=""
for tool in bash curl jq docker node; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing_tools="$missing_tools $tool"
    fi
done
if [[ -n "$missing_tools" ]]; then
    echo "Missing required tools:$missing_tools" >&2
    exit 2
fi
if ! docker compose version >/dev/null 2>&1 </dev/null; then
    echo "The docker compose plugin is required (docker compose version failed)." >&2
    exit 2
fi

# restrict_private_dir: limits PRIVATE_DIR to the current user, and proves it, while it is still
# empty; every file created inside inherits that. umask 077 alone does not do it on Git Bash,
# MSYS2 or Cygwin, which only emulate file modes over the Windows ACL a new directory inherits.
# There, icacls removes the inherited entries and grants full control, inherited by everything
# created inside, to the SID the system's own whoami reports; the listing must then hold that
# one entry and no other. Elsewhere the mode must read drwx------ with no access control list.
# Prints the reason on stderr and fails when either cannot be established.
restrict_private_dir() {
    local fault="Could not restrict the private working directory $PRIVATE_DIR to this user"
    local perms account name sid win out="" listing line entries=0 entry="" found="" expected
    local account_re='^"([^"]+)","(S-1-[0-9-]+)"$'
    case "$(uname -s)" in
        MINGW* | MSYS* | CYGWIN*) ;;
        *)
            if ! chmod 700 "$PRIVATE_DIR"; then
                echo "$fault: chmod 700 failed." >&2
                return 1
            fi
            perms="$(ls -ld "$PRIVATE_DIR")" || perms=""
            perms="${perms%% *}"
            if [[ ! "$perms" =~ ^drwx------[.@]?$ ]]; then
                echo "$fault: it shows [$perms], not drwx------ without an access control list." >&2
                return 1
            fi
            return 0
            ;;
    esac
    # Arguments must reach the Windows tools unchanged, and the whoami on PATH is usually the
    # coreutils one, which cannot print a SID.
    account="$(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "$(cygpath -S)/whoami.exe" /user \
        /fo csv /nh </dev/null | tr -d '\r')" || account=""
    if [[ ! "$account" =~ $account_re ]]; then
        echo "$fault: whoami /user did not report the current user and SID." >&2
        return 1
    fi
    name="${BASH_REMATCH[1]}"
    sid="${BASH_REMATCH[2]}"
    if ! win="$(cygpath -w "$PRIVATE_DIR")" || [[ -z "$win" ]]; then
        echo "$fault: cygpath -w gave no Windows path." >&2
        return 1
    fi
    if ! out="$(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' icacls "$win" /inheritance:r \
        /grant:r "*$sid:(OI)(CI)F" </dev/null 2>&1)"; then
        echo "$fault: icacls failed: $(tr -d '\r' <<<"$out" | sed -n '1p')" >&2
        return 1
    fi
    if ! listing="$(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' icacls "$win" </dev/null)"; then
        echo "$fault: icacls could not list its entries." >&2
        return 1
    fi
    # The listing starts "<path> <entry>", continues with one indented entry per line and ends at
    # a blank line. The directory's own name is ASCII, so it marks where the path ends.
    while IFS= read -r line; do
        line="${line%$'\r'}"
        if [[ -z "$line" ]]; then
            break
        fi
        if [[ $entries -eq 0 ]]; then
            line="${line#*"${PRIVATE_DIR##*/} "}"
        fi
        entries=$((entries + 1))
        entry="${line#"${line%%[![:space:]]*}"}"
        found="${found:+$found, }$entry"
    done <<<"$listing"
    # icacls and whoami may spell the domain in different case.
    entry="$(tr '[:upper:]' '[:lower:]' <<<"$entry")"
    expected="$(tr '[:upper:]' '[:lower:]' <<<"$name:(OI)(CI)(F)")"
    if [[ $entries -ne 1 || "$entry" != "$expected" ]]; then
        echo "$fault: icacls lists [$found], expected only $name:(OI)(CI)(F)." >&2
        return 1
    fi
}

if ! RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pi-e2e.XXXXXX")"; then
    echo "Could not create a run directory under ${TMPDIR:-/tmp}." >&2
    exit 2
fi
# The fixture, the only file that holds the passwords, and the raw response bytes stay out of
# the run and evidence directories: in a directory only this user can read, removed on exit.
if ! PRIVATE_DIR="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/pi-e2e-private.XXXXXX")"; then
    echo "Could not create a private working directory under ${TMPDIR:-/tmp}." >&2
    rmdir "$RUN_DIR"
    exit 2
fi
if ! restrict_private_dir; then
    rmdir "$RUN_DIR" "$PRIVATE_DIR" || true
    exit 2
fi
# The browser check runs from src/loadgen, so every path handed to it is absolute.
if [[ -z "$EVIDENCE_DIR" ]]; then
    EVIDENCE_DIR="$RUN_DIR"
fi
if ! mkdir -p "$EVIDENCE_DIR" || ! EVIDENCE_DIR="$(cd "$EVIDENCE_DIR" && pwd)"; then
    echo "Could not create the evidence directory: $EVIDENCE_DIR" >&2
    rmdir "$RUN_DIR" "$PRIVATE_DIR"
    exit 2
fi
FIXTURE="$PRIVATE_DIR/fixture.json"
PRIVATE_LEFT=""
: >"$RUN_DIR/owned"
: >"$RUN_DIR/deleted"
: >"$RUN_DIR/pairs"
: >"$RUN_DIR/triggered"

B="$BASE_URL/broker-service"
F="$BASE_URL/feature-flag-service/v1/flags/$FLAG_ID"
U="$BASE_URL/user-service"
ALERTS_URL="$B/v1/alerts"
INSIGHTS_URL="$B/v1/portfolio/insights"

passed=0
failed=0
IN_CREATE=0
PENDING_EXIT=""
FLAG_INITIAL=""
FLAG_TOUCHED=0
DIALECT=""
INTERVAL="$DEFAULT_INTERVAL_SECONDS"
HOLDER_USER=""
EMPTY_USER=""
HOLDER_PASSWORD=""
EMPTY_PASSWORD=""
HOLDER_ID=""
EMPTY_ID=""
HOLDER_INSIGHTS=""
H1=""
LOG4_SINCE=""
LOG9_SINCE=""
BASE9=0
LAST_TRIGGER_INDEX=""
PAIRS_READY=0
SKIP_REASON=""
POLL_DETAIL=""

# ---------------------------------------------------------------------------------------------
# Reporting

pass() {
    passed=$((passed + 1))
    echo "PASS $1"
}

# fail CHECK REASON: REASON can carry text a server sent. Every occurrence of a fixture password
# in it becomes <redacted>, whichever field carried it, and then every byte outside printable
# ASCII becomes ?, which keeps each FAIL line one line long and free of terminal control
# sequences.
fail() {
    local reason="$2" secret
    for secret in "$HOLDER_PASSWORD" "$EMPTY_PASSWORD"; do
        if [[ -n "$secret" ]]; then
            reason="${reason//"$secret"/"<redacted>"}"
        fi
    done
    failed=$((failed + 1))
    echo "FAIL $1: $(printf '%s' "$reason" | LC_ALL=C tr -c '\040-\176' '?')"
}

info() {
    echo "INFO $*"
}

# Fails a prerequisite check and ends the run; the EXIT trap still cleans up.
abort() {
    fail "$1" "$2"
    exit 1
}

# ---------------------------------------------------------------------------------------------
# HTTP and JSON

# http METHOD URL [BODY]: sets HTTP_STATUS (000 on a transport error), HTTP_CTYPE, HTTP_BODY
# (the response text; the exact bytes stay in $PRIVATE_DIR/body) and HTTP_ERROR (curl's message
# on a transport error). Never trips set -e. BODY goes through stdin, byte for byte, so neither
# the process list nor Git Bash path conversion ever sees it. The raw body, headers and curl
# messages are kept in the private directory only, never in the run directory.
http() {
    local method="$1" url="$2" out rc=0
    local args=(-sS --max-time "$HTTP_TIMEOUT_SECONDS" -X "$method"
        -o "$PRIVATE_DIR/body" -D "$PRIVATE_DIR/headers" -w '%{http_code} %{content_type}'
        -H 'Accept: application/json')
    : >"$PRIVATE_DIR/body"
    : >"$PRIVATE_DIR/headers"
    if [[ $# -ge 3 ]]; then
        args+=(-H 'Content-Type: application/json' --data-binary @-)
        out="$(printf '%s' "$3" | curl "${args[@]}" "$url" 2>"$PRIVATE_DIR/curl-error")" || rc=$?
    else
        if [[ "$method" != "GET" && "$method" != "DELETE" ]]; then
            args+=(-H 'Content-Length: 0')
        fi
        out="$(curl "${args[@]}" "$url" 2>"$PRIVATE_DIR/curl-error" </dev/null)" || rc=$?
    fi
    if [[ $rc -ne 0 ]]; then
        HTTP_STATUS="000"
        HTTP_CTYPE=""
        HTTP_ERROR="$(tr -d '\r' <"$PRIVATE_DIR/curl-error" | grep -v 'Debug-enabled' | head -c 300)"
    else
        HTTP_STATUS="${out%% *}"
        HTTP_CTYPE="${out#* }"
        HTTP_ERROR=""
    fi
    # A shell variable cannot hold NUL, so a body's NUL bytes are dropped here, without bash's
    # warning; the exact bytes stay in the file.
    HTTP_BODY="$(tr -d '\000' <"$PRIVATE_DIR/body")"
}

# jget FILTER JSON: prints jq's raw output, or nothing when the JSON does not parse.
jget() {
    jq -r "$1" 2>/dev/null <<<"$2" | tr -d '\r' || true
}

# jitem ID JSON [FILTER]: FILTER (default: the item itself, keys sorted, compact) applied to the
# first .results item whose id is ID. Prints nothing when there is none.
jitem() {
    jq -S -c -r --arg id "$1" \
        "first(.results[]? | select((.id // \"\" | ascii_downcase) == \$id)) | ${3:-.}" \
        2>/dev/null <<<"$2" | tr -d '\r' || true
}

# jcount ID JSON: how many .results items carry the id ID.
jcount() {
    jq -r --arg id "$1" '[.results[]? | select((.id // "" | ascii_downcase) == $id)] | length' \
        2>/dev/null <<<"$2" | tr -d '\r' || true
}

lower() {
    tr '[:upper:]' '[:lower:]'
}

# Status text for a failure reason, with curl's message on a transport error.
status_text() {
    if [[ "$HTTP_STATUS" == "000" ]]; then
        echo "transport error (${HTTP_ERROR:-no response})"
    else
        echo "status $HTTP_STATUS"
    fi
}

# describe_file FILE: what FILE holds, for failure reasons, without any of its bytes: "empty",
# or its size and either "not JSON" or the type of its one JSON document, with an object's
# first 10 key names or an array's length. Each key name is cut to 32 characters, with every
# character but A-Z, a-z, 0-9, _, . and - replaced by ?, and the names are withheld when the
# file holds a fixture password. So a secret or a terminal control sequence a server reflects
# never reaches the output.
describe_file() {
    local size content secret with_names=true shape
    local filter='def safe: explode | map(if (. >= 48 and . <= 57) or (. >= 65 and . <= 90)
            or (. >= 97 and . <= 122) or . == 45 or . == 46 or . == 95 then . else 63 end)
        | .[0:32] | implode;
    if length != 1 then "not JSON"
    else .[0]
      | if type == "object" then
          "JSON object with \(length) key\(if length == 1 then "" else "s" end)"
          + if length == 0 then ""
            elif $withNames then
              " [" + (keys_unsorted | .[0:10] | map(safe) | join(","))
              + (if length > 10 then ",...]" else "]" end)
            else ", names withheld: the body holds a fixture password" end
        elif type == "array" then "JSON array of \(length) item\(if length == 1 then "" else "s" end)"
        else "JSON \(type)" end
    end'
    size="$(wc -c <"$1" | tr -d ' \r')" || size=""
    if [[ ! "$size" =~ ^[0-9]+$ ]]; then
        echo "unreadable"
        return 0
    fi
    if [[ $size -eq 0 ]]; then
        echo "empty"
        return 0
    fi
    content="$(tr -d '\000' <"$1")"
    for secret in "$HOLDER_PASSWORD" "$EMPTY_PASSWORD"; do
        if [[ -n "$secret" && "$content" == *"$secret"* ]]; then
            with_names=false
        fi
    done
    shape="$(jq -r -s --argjson withNames "$with_names" "$filter" "$1" 2>/dev/null | tr -d '\r')" ||
        shape=""
    echo "$size bytes, ${shape:-not JSON}"
}

# body_snippet: the last response body, for failure reasons, as describe_file describes it.
# The exact bytes stay in $PRIVATE_DIR/body, where the checks read them.
body_snippet() {
    describe_file "$PRIVATE_DIR/body"
}

# expect_status CHECK STATUS: PASS when the last response has STATUS.
expect_status() {
    if [[ "$HTTP_STATUS" == "$2" ]]; then
        pass "$1"
    else
        fail "$1" "$(status_text), expected $2; body [$(body_snippet)]"
    fi
}

# jcheck CHECK FILTER JSON: PASS when the jq FILTER, run on JSON, prints "ok". Every filter
# prints "ok" or the reason it rejects the value.
jcheck() {
    local verdict
    verdict="$(jget "$2" "$3")"
    if [[ "$verdict" == "ok" ]]; then
        pass "$1"
    elif [[ -n "$verdict" ]]; then
        fail "$1" "$verdict"
    else
        printf '%s' "$3" >"$PRIVATE_DIR/jcheck-text"
        fail "$1" "unreadable JSON [$(describe_file "$PRIVATE_DIR/jcheck-text")]"
    fi
}

# expect_json CHECK STATUS FILTER: the last response has STATUS and jcheck passes on its body.
expect_json() {
    if [[ "$HTTP_STATUS" != "$2" ]]; then
        fail "$1" "$(status_text), expected $2; body [$(body_snippet)]"
        return 0
    fi
    jcheck "$1" "$3" "$HTTP_BODY"
}

# expect_forbidden CHECK METHOD URL [BODY]: PASS only for a 403 whose body bytes are exactly
# {"error":"feature_disabled"} and whose content type is application/json. read stops at the
# first NUL, so the body's size must also be the expected body's (ASCII, one byte a character).
expect_forbidden() {
    local check="$1" content="" size
    shift
    http "$@"
    own_if_created
    IFS= read -r -d '' content <"$PRIVATE_DIR/body" || true
    size="$(wc -c <"$PRIVATE_DIR/body" | tr -d ' \r')" || size=""
    if [[ "$HTTP_STATUS" == "403" && "$size" == "${#FORBIDDEN_BODY}" && "$content" == "$FORBIDDEN_BODY" &&
        "$HTTP_CTYPE" == application/json* ]]; then
        pass "$check"
    else
        fail "$check" "$(status_text), content type [$HTTP_CTYPE], body [$(body_snippet)]; expected 403 application/json $FORBIDDEN_BODY"
    fi
}

# ---------------------------------------------------------------------------------------------
# Exact decimals. jq compares and prints numbers as doubles (0.00000001 comes out as 1E-8), so
# thresholds, closes and trigger values are compared here as bash integers in units of 1e-8.

# dec_to_units TEXT: plain decimal text to units of 1e-8, rounding half away from zero beyond
# the eighth fractional digit. Fails on anything else or on more than 10 integer digits, which
# keeps every result inside int64.
dec_to_units() {
    local sign int frac units
    if [[ ! "$1" =~ ^(-?)([0-9]+)(\.([0-9]+))?$ ]]; then
        return 1
    fi
    sign="${BASH_REMATCH[1]}"
    int="${BASH_REMATCH[2]}"
    frac="${BASH_REMATCH[4]}000000000"
    int="${int#"${int%%[!0]*}"}"
    if [[ ${#int} -gt 10 ]]; then
        return 1
    fi
    units=$((10#${int:-0} * 100000000 + 10#${frac:0:8}))
    if [[ ${frac:8:1} -ge 5 ]]; then
        units=$((units + 1))
    fi
    if [[ "$sign" == "-" && $units -ne 0 ]]; then
        units=$((-units))
    fi
    echo "$units"
}

# num_to_units TEXT: a number as jq prints it, exponent form included (1E-8, 1.5E+3), to units
# of 1e-8. The decimal point is shifted textually, so no digit is lost to floating point.
num_to_units() {
    local sign int frac exp digits point zeros negative=0
    if [[ ! "$1" =~ ^(-?)([0-9]+)(\.([0-9]+))?([eE]([+-]?[0-9]+))?$ ]]; then
        return 1
    fi
    sign="${BASH_REMATCH[1]}"
    int="${BASH_REMATCH[2]}"
    frac="${BASH_REMATCH[4]}"
    exp="${BASH_REMATCH[6]}"
    if [[ -z "${BASH_REMATCH[5]}" ]]; then
        dec_to_units "$1"
        return
    fi
    case "$exp" in
        -*)
            negative=1
            exp="${exp#-}"
            ;;
        +*) exp="${exp#+}" ;;
    esac
    exp="${exp#"${exp%%[!0]*}"}"
    # A shift beyond 999 places cannot leave a value that fits; refusing it bounds the padding.
    if [[ ${#exp} -gt 3 ]]; then
        return 1
    fi
    exp=$((10#${exp:-0}))
    if [[ $negative -eq 1 ]]; then
        exp=$((-exp))
    fi
    digits="$int$frac"
    point=$((${#int} + exp))
    if [[ $point -le 0 ]]; then
        printf -v zeros '%*s' "$((-point))" ''
        int="0"
        frac="${zeros// /0}$digits"
    elif [[ $point -ge ${#digits} ]]; then
        printf -v zeros '%*s' "$((point - ${#digits}))" ''
        int="$digits${zeros// /0}"
        frac=""
    else
        int="${digits:0:point}"
        frac="${digits:point}"
    fi
    dec_to_units "$sign$int${frac:+.$frac}"
}

# units_to_dec UNITS: units of 1e-8 back to normalised decimal text (no trailing zeros).
units_to_dec() {
    local units="$1" sign="" int frac
    if [[ ! "$units" =~ ^-?[0-9]+$ ]]; then
        return 1
    fi
    if [[ "$units" == -* ]]; then
        sign="-"
        units="${units#-}"
    fi
    units=$((10#$units))
    int=$((units / 100000000))
    frac=$((units % 100000000))
    if [[ $frac -eq 0 ]]; then
        if [[ $int -eq 0 ]]; then
            sign=""
        fi
        echo "$sign$int"
        return 0
    fi
    frac="$(printf '%08d' "$frac")"
    while [[ "$frac" == *0 ]]; do
        frac="${frac%0}"
    done
    echo "$sign$int.$frac"
}

# ---------------------------------------------------------------------------------------------
# Identifiers and times

# random_guid: a version-4-shaped GUID from $RANDOM. It only has to be well formed and unknown.
random_guid() {
    printf '%04x%04x-%04x-4%03x-%04x-%04x%04x%04x\n' "$RANDOM" "$RANDOM" "$RANDOM" \
        $((RANDOM & 0x0fff)) $(((RANDOM & 0x3fff) | 0x8000)) "$RANDOM" "$RANDOM" "$RANDOM"
}

# random_secret: a throwaway password for a fixture account, Pi- and 16 bytes of the operating
# system's cryptographic random source as 32 hex digits. It is written only to the fixture and
# sent only in the signup body. Fails, printing nothing, when /dev/urandom cannot supply them.
random_secret() {
    local hex
    if ! hex="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" || [[ ! "$hex" =~ ^[0-9a-f]{32}$ ]]; then
        return 1
    fi
    printf 'Pi-%s\n' "$hex"
}

now_rfc3339() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# epoch_to_rfc3339 EPOCH: GNU date first, then BSD date.
epoch_to_rfc3339() {
    date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

# log_since_now: the start of a log window opened now, LOG_SKEW_MARGIN_SECONDS back.
log_since_now() {
    epoch_to_rfc3339 $(($(date -u +%s) - LOG_SKEW_MARGIN_SECONDS))
}

# poll CHECK TIMEOUT STEP COMMAND [ARGS...]: runs COMMAND every STEP seconds until it succeeds
# or the deadline TIMEOUT seconds from now passes. On expiry it reports FAIL CHECK, with the
# POLL_DETAIL the last attempt left, and fails. STEP is the only sleep the script makes.
poll() {
    local check="$1" timeout="$2" step="$3" deadline
    shift 3
    deadline=$(($(date -u +%s) + timeout))
    POLL_DETAIL=""
    while :; do
        if "$@"; then
            return 0
        fi
        if [[ $(($(date -u +%s) + step)) -gt $deadline ]]; then
            fail "$check" "deadline $timeout s expired${POLL_DETAIL:+; $POLL_DETAIL}"
            return 1
        fi
        sleep "$step"
    done
}


# ---------------------------------------------------------------------------------------------
# Docker, runtime facts and logs

# Arguments must reach docker unchanged: Git Bash would rewrite path-like ones to Windows
# paths. stdin is detached so docker never consumes the input of a surrounding read loop.
compose() {
    MSYS_NO_PATHCONV=1 docker compose -p "$PROJECT" -f "$COMPOSE_FILE" "$@" </dev/null
}

running_services() {
    compose ps --status running --services 2>>"$RUN_DIR/compose.log" | tr -d '\r'
}

# container_env SERVICE NAME: the value of NAME in the service container's environment.
# Prints nothing when it is unset.
container_env() {
    local cid
    cid="$(compose ps -q "$1" 2>>"$RUN_DIR/compose.log" | tr -d '\r' | sed -n '1p')" || return 1
    if [[ -z "$cid" ]]; then
        return 1
    fi
    MSYS_NO_PATHCONV=1 docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$cid" </dev/null \
        | tr -d '\r' | sed -n "/^$2=/{s/^$2=//p;q;}"
}

# resolve_interval RAW: the broker's interval rule. Like int.TryParse with NumberStyles.Integer,
# surrounding white space and a leading sign are allowed; a whole number from 1 to
# MAX_INTERVAL_SECONDS is used, anything else (unset included) gives the default.
resolve_interval() {
    local raw="$1" digits
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    if [[ "$raw" =~ ^([+-]?)([0-9]+)$ && "${BASH_REMATCH[1]}" != "-" ]]; then
        digits="${BASH_REMATCH[2]}"
        digits="${digits#"${digits%%[!0]*}"}"
        if [[ -n "$digits" && ${#digits} -le ${#MAX_INTERVAL_SECONDS} ]] &&
            [[ $((10#$digits)) -le $MAX_INTERVAL_SECONDS ]]; then
            echo $((10#$digits))
            return 0
        fi
    fi
    echo "$DEFAULT_INTERVAL_SECONDS"
}

# broker_logs SINCE: broker-service output since SINCE, without colour codes or carriage
# returns. The custom console logger pads each line and ends it with " | <CallerName>", so
# callers match substrings only.
broker_logs() {
    compose logs --no-color --no-log-prefix --since "$1" broker-service 2>>"$RUN_DIR/compose.log" \
        | sed "s/$(printf '\033')\[[0-9;]*m//g" | tr -d '\r'
}

# shellcheck disable=SC2329 # Invoked through poll.
# log_has_text SINCE TEXT: whether the broker logged a line containing TEXT since SINCE.
log_has_text() {
    if ! broker_logs "$1" >"$RUN_DIR/text.log"; then
        POLL_DETAIL="broker-service logs unreadable (see $RUN_DIR/compose.log)"
        return 1
    fi
    if grep -qF "$2" "$RUN_DIR/text.log"; then
        return 0
    fi
    POLL_DETAIL="no broker-service line contains [$2]"
    return 1
}

# read_window SINCE: the broker's cycle summary and trigger lines since SINCE, in log order,
# into $RUN_DIR/window.events as "C" for a cycle line or "T <alert id> <revision>".
read_window() {
    local line id
    broker_logs "$1" >"$RUN_DIR/window.log" || return 1
    : >"$RUN_DIR/window.events"
    while IFS= read -r line; do
        if [[ "$line" == *"$CYCLE_MARKER"* ]]; then
            echo "C" >>"$RUN_DIR/window.events"
        elif [[ "$line" =~ $TRIGGER_RE ]]; then
            id="$(lower <<<"${BASH_REMATCH[1]}")"
            echo "T $id ${BASH_REMATCH[2]}" >>"$RUN_DIR/window.events"
        fi
    done < <(grep -F -e "$CYCLE_MARKER" -e "$TRIGGER_MARKER" "$RUN_DIR/window.log" || true)
}

# window_cycles: the cycle lines in the current window.
window_cycles() {
    grep -c '^C$' "$RUN_DIR/window.events" || true
}

# shellcheck disable=SC2329 # Invoked by trigger_logged, a poll command.
# trigger_position ID REVISION: sets TRIGGER_INDEX, the event number of the trigger line of
# that alert arming in the current window, and TRIGGER_CYCLES, the cycle lines before it.
# Fails when the window holds no such line.
trigger_position() {
    local kind id revision index=0 cycles=0
    while read -r kind id revision; do
        index=$((index + 1))
        if [[ "$kind" == "C" ]]; then
            cycles=$((cycles + 1))
        elif [[ "$id" == "$1" && "$revision" == "$2" ]]; then
            TRIGGER_INDEX=$index
            TRIGGER_CYCLES=$cycles
            return 0
        fi
    done <"$RUN_DIR/window.events"
    return 1
}

# shellcheck disable=SC2329 # Invoked through poll.
# trigger_logged ID REVISION: poll command; rereads the step-9 window and finds the trigger.
trigger_logged() {
    if ! read_window "$LOG9_SINCE"; then
        POLL_DETAIL="broker-service logs unreadable (see $RUN_DIR/compose.log)"
        return 1
    fi
    if trigger_position "$1" "$2"; then
        return 0
    fi
    POLL_DETAIL="no line [Alert [$1] triggered for account [...] ... revision [$2]] since $LOG9_SINCE"
    return 1
}

# shellcheck disable=SC2329 # Invoked through poll.
# later_cycles_seen: poll command; true once two cycle lines follow the last step-9 trigger
# line, the triggering cycle's own summary and the next cycle's.
later_cycles_seen() {
    local after
    if ! read_window "$LOG9_SINCE"; then
        POLL_DETAIL="broker-service logs unreadable (see $RUN_DIR/compose.log)"
        return 1
    fi
    after="$(tail -n "+$((LAST_TRIGGER_INDEX + 1))" "$RUN_DIR/window.events" | grep -c '^C$' || true)"
    POLL_DETAIL="$after cycle lines after the last trigger line, 2 needed (the triggering cycle's own and the next)"
    [[ $after -ge 2 ]]
}

# ---------------------------------------------------------------------------------------------
# Alerts this run owns

# own_alert ID: records an alert this run created, the moment its 201 arrives.
own_alert() {
    lower <<<"$1" >>"$RUN_DIR/owned"
}

# own_if_created: owns the id of a 201 from POST /v1/alerts, so even a request expected to be
# refused leaves nothing behind when it is accepted.
own_if_created() {
    local id
    if [[ "$HTTP_STATUS" != "201" ]]; then
        return 0
    fi
    id="$(jget '.id // empty' "$HTTP_BODY" | lower)"
    if [[ "$id" =~ $UUID_RE ]]; then
        own_alert "$id"
    fi
}

# delete_alert ID: DELETE the alert; 204 and 404 mark it deleted, so cleanup skips it. The
# status is left in HTTP_STATUS.
delete_alert() {
    http DELETE "$ALERTS_URL/$1"
    if [[ "$HTTP_STATUS" == "204" || "$HTTP_STATUS" == "404" ]]; then
        echo "$1" >>"$RUN_DIR/deleted"
    fi
}

# remaining_owned: owned ids not yet deleted, into $RUN_DIR/to-delete; prints their count.
remaining_owned() {
    LC_ALL=C sort -u "$RUN_DIR/owned" >"$RUN_DIR/owned.sorted"
    LC_ALL=C sort -u "$RUN_DIR/deleted" >"$RUN_DIR/deleted.sorted"
    LC_ALL=C comm -23 "$RUN_DIR/owned.sorted" "$RUN_DIR/deleted.sorted" >"$RUN_DIR/to-delete"
    wc -l <"$RUN_DIR/to-delete" | tr -d ' '
}

# alert_body ACCOUNT TYPE INSTRUMENT DIRECTION THRESHOLD: the create body with THRESHOLD
# written in as an unquoted token, exactly as given; it never passes through a number type.
alert_body() {
    printf '{"accountId":"%s","type":"%s","instrumentId":"%s","direction":"%s","threshold":%s}' \
        "$1" "$2" "$3" "$4" "$5"
}

# create_alert ACCOUNT TYPE INSTRUMENT DIRECTION THRESHOLD: POST /v1/alerts. On 201 the id is
# owned at once and left in CREATED_ID; otherwise CREATE_ERROR says why. The response stays in
# the HTTP_* globals for the caller's checks.
# An interrupt that arrives while the POST is in flight is held until the id is recorded:
# exiting in between would leave an alert this run created but cannot delete.
create_alert() {
    local rc=0
    IN_CREATE=1
    post_alert "$@" || rc=$?
    IN_CREATE=0
    if [[ -n "$PENDING_EXIT" ]]; then
        exit "$PENDING_EXIT"
    fi
    return "$rc"
}

post_alert() {
    CREATED_ID=""
    CREATE_ERROR=""
    if [[ ! "$5" =~ $THRESHOLD_TOKEN_RE ]]; then
        CREATE_ERROR="threshold [$5] is not a plain decimal token"
        return 1
    fi
    http POST "$ALERTS_URL" "$(alert_body "$@")"
    if [[ "$HTTP_STATUS" == "000" ]]; then
        CREATE_ERROR="$(status_text); the alert may exist without an id this run knows"
        return 1
    fi
    if [[ "$HTTP_STATUS" != "201" ]]; then
        CREATE_ERROR="$(status_text); body [$(body_snippet)]"
        return 1
    fi
    CREATED_ID="$(jget '.id // empty' "$HTTP_BODY" | lower)"
    if [[ ! "$CREATED_ID" =~ $UUID_RE ]]; then
        CREATE_ERROR="201 without a readable id; the created alert cannot be deleted by this run"
        CREATED_ID=""
        return 1
    fi
    own_alert "$CREATED_ID"
}

# post_expect CHECK STATUS BODY: POST BODY, sent verbatim, to /v1/alerts and expect STATUS.
post_expect() {
    http POST "$ALERTS_URL" "$3"
    own_if_created
    expect_status "$1" "$2"
}

# check_forbidden_endpoints STEP ACCOUNT ALERT INSTRUMENT: the seven feature endpoints, each
# expected to answer 403 {"error":"feature_disabled"}.
check_forbidden_endpoints() {
    local step="$1" account="$2" alert="$3" instrument="$4"
    expect_forbidden "$step GET insights forbidden" GET "$INSIGHTS_URL/$account"
    expect_forbidden "$step POST alert forbidden" POST "$ALERTS_URL" \
        "$(alert_body "$account" TARGET_PRICE "$instrument" ABOVE 1)"
    expect_forbidden "$step GET alerts forbidden" GET "$ALERTS_URL?accountId=$account"
    expect_forbidden "$step GET notifications forbidden" GET \
        "$ALERTS_URL/notifications?accountId=$account&unacknowledged=true"
    expect_forbidden "$step PATCH alert forbidden" PATCH "$ALERTS_URL/$alert" '{"enabled":true}'
    expect_forbidden "$step DELETE alert forbidden" DELETE "$ALERTS_URL/$alert"
    expect_forbidden "$step POST acknowledge forbidden" POST "$ALERTS_URL/$alert/acknowledge"
}

# ---------------------------------------------------------------------------------------------
# Fixture and browser check

# write_fixture ALERTS_JSON: the fixture the browser check reads, with ALERTS_JSON as its
# alerts array. Thresholds stay strings and revisions integers, as its reader requires.
# The passwords reach jq as stdin lines from the printf builtin, never as command arguments,
# and the file is created readable by this user only. Fails when it cannot write the fixture.
write_fixture() {
    if [[ "$HOLDER_PASSWORD$EMPTY_PASSWORD" == *$'\n'* ]]; then
        return 1
    fi
    (
        umask 077
        printf '%s\n%s\n' "$HOLDER_PASSWORD" "$EMPTY_PASSWORD" | jq -n -R \
            --argjson interval "$INTERVAL" \
            --arg holderUser "$HOLDER_USER" \
            --arg holderId "$HOLDER_ID" \
            --arg emptyUser "$EMPTY_USER" \
            --arg emptyId "$EMPTY_ID" \
            --argjson alerts "$1" \
            'input as $holderPassword | input as $emptyPassword
             | {evaluationIntervalSeconds: $interval,
                holder: {username: $holderUser, password: $holderPassword, accountId: $holderId},
                empty: {username: $emptyUser, password: $emptyPassword, accountId: $emptyId},
                alerts: $alerts}' >"$FIXTURE"
    )
}

# prefix_lines LABEL LOG: copies stdin to LOG and prints each line as "INFO LABEL: <line>", so
# the browser check's own PASS and FAIL lines are never counted as this script's checks.
prefix_lines() {
    local line
    : >"$2"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        echo "$line" >>"$2"
        echo "INFO $1: $line"
    done
}

# run_browser_check MODE CHECK: runs the browser check with the fixture; PASS on exit code 0.
run_browser_check() {
    local mode="$1" check="$2" rc=0
    if [[ ! -d "$REPO_ROOT/src/loadgen/node_modules/puppeteer" ]]; then
        fail "$check" "run npm ci in src/loadgen"
        return 0
    fi
    info "browser check --mode $mode started; its output follows, also in $RUN_DIR/browser-$mode.log"
    set +e
    (cd "$REPO_ROOT/src/loadgen" &&
        node verification/portfolio-insights-page-check.mjs --base-url "$BASE_URL" \
            --mode "$mode" --fixture "$FIXTURE" --evidence-dir "$EVIDENCE_DIR") </dev/null 2>&1 \
        | prefix_lines "browser $mode" "$RUN_DIR/browser-$mode.log"
    rc=${PIPESTATUS[0]}
    set -e
    if [[ $rc -eq 0 ]]; then
        pass "$check"
    else
        fail "$check" "exit code $rc (1: a check failed, 2: a usage or fixture error); see $RUN_DIR/browser-$mode.log and $EVIDENCE_DIR"
    fi
}

# ---------------------------------------------------------------------------------------------
# Cleanup and exit. Every step is idempotent, so it is safe however far the run got.

# shellcheck disable=SC2329 # Invoked by cleanup, the EXIT trap.
# delete_remaining: DELETEs every owned id not yet deleted. Sets CLEANUP_LEFT to the number of
# alerts left in place.
delete_remaining() {
    local id transport=0
    CLEANUP_LEFT=0
    remaining_owned >/dev/null
    while IFS= read -r id; do
        if [[ $transport -ge $MAX_CONSECUTIVE_TRANSPORT_ERRORS ]]; then
            info "cleanup left alert $id: not attempted after $transport transport errors in a row"
            CLEANUP_LEFT=$((CLEANUP_LEFT + 1))
            continue
        fi
        delete_alert "$id"
        case "$HTTP_STATUS" in
            204 | 404) transport=0 ;;
            *)
                if [[ "$HTTP_STATUS" == "000" ]]; then
                    transport=$((transport + 1))
                else
                    transport=0
                fi
                info "cleanup left alert $id: $(status_text)"
                CLEANUP_LEFT=$((CLEANUP_LEFT + 1))
                ;;
        esac
    done <"$RUN_DIR/to-delete"
}

# shellcheck disable=SC2329 # Invoked by cleanup, the EXIT trap, and by its interrupt trap.
# remove_private: removes the fixture, then the whole private directory, and checks that both
# are gone. A path counts as removed only when rm succeeded and neither -e nor -L finds it,
# since -e alone cannot see an entry it is denied access to. Sets PRIVATE_LEFT to what may
# remain, empty when nothing does.
remove_private() {
    PRIVATE_LEFT=""
    if [[ -n "$FIXTURE" ]]; then
        if ! rm -f -- "$FIXTURE" || [[ -e "$FIXTURE" || -L "$FIXTURE" ]]; then
            PRIVATE_LEFT="fixture $FIXTURE"
        fi
    fi
    if [[ -n "$PRIVATE_DIR" ]]; then
        if ! rm -rf -- "$PRIVATE_DIR" || [[ -e "$PRIVATE_DIR" || -L "$PRIVATE_DIR" ]]; then
            PRIVATE_LEFT="${PRIVATE_LEFT:+$PRIVATE_LEFT and }private directory $PRIVATE_DIR"
        fi
    fi
}

# shellcheck disable=SC2329 # Invoked by cleanup's INT and TERM trap.
# on_cleanup_signal: a second interrupt, while cleanup runs. The remaining requests are
# abandoned, but the private directory is still removed and the run still ends with a cleanup
# verdict and the SUMMARY line. Further interrupts are ignored, so it runs once.
on_cleanup_signal() {
    trap '' INT TERM
    remove_private
    fail "cleanup" "interrupted before it finished: owned alerts may be left in place and flag $FLAG_ID may not be restored${PRIVATE_LEFT:+; $PRIVATE_LEFT not removed}"
    info "run dir $RUN_DIR"
    echo "SUMMARY $passed passed, $failed failed"
    exit 130
}

# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() {
    local rc=$? remaining problems=""
    trap - EXIT
    # A second interrupt abandons the remaining requests, but never leaves the passwords behind
    # and still ends the run with a cleanup verdict and the SUMMARY line.
    trap on_cleanup_signal INT TERM
    set +e
    remaining="$(remaining_owned)"
    if [[ "$remaining" -gt 0 ]]; then
        # DELETE answers 403 while the flag is off, so the flag is switched on to delete.
        http GET "$F"
        if [[ "$HTTP_STATUS" == "200" && "$(jget '.enabled' "$HTTP_BODY")" == "false" ]]; then
            FLAG_TOUCHED=1
            http PUT "$F" '{"enabled": true}'
            info "cleanup: flag $FLAG_ID switched on to delete $remaining owned alerts ($(status_text))"
        fi
        delete_remaining
        info "cleanup: $((remaining - CLEANUP_LEFT)) of $remaining remaining owned alerts deleted or already absent"
        if [[ $CLEANUP_LEFT -gt 0 ]]; then
            problems="$CLEANUP_LEFT owned alerts left in place"
        fi
    fi
    if [[ $FLAG_TOUCHED -eq 1 && -n "$FLAG_INITIAL" ]]; then
        http PUT "$F" "{\"enabled\": $FLAG_INITIAL}"
        if [[ "$HTTP_STATUS" == "200" && "$(jget '.enabled' "$HTTP_BODY")" == "$FLAG_INITIAL" ]]; then
            info "cleanup: flag $FLAG_ID restored to enabled=$FLAG_INITIAL"
        else
            problems="${problems:+$problems; }flag $FLAG_ID not restored to enabled=$FLAG_INITIAL: $(status_text)"
        fi
    fi
    if [[ -n "$HOLDER_USER" ]]; then
        info "cleanup: fixture accounts $HOLDER_USER and $EMPTY_USER remain (no account-deletion endpoint exists)"
    fi
    # Last, once no request needs the private directory: the passwords go with it. Nothing is
    # left to abandon after that, so a further interrupt cannot cut the verdict short.
    remove_private
    trap '' INT TERM
    if [[ -z "$PRIVATE_LEFT" ]]; then
        info "cleanup: fixture and private working files removed"
    else
        problems="${problems:+$problems; }$PRIVATE_LEFT not removed"
    fi
    # A check of its own, as in perf.sh: an alert left behind, a flag left changed or a fixture
    # left on disk fails the run even when every step passed.
    if [[ -z "$problems" ]]; then
        pass "cleanup"
    else
        fail "cleanup" "$problems"
    fi
    info "run dir $RUN_DIR"
    echo "SUMMARY $passed passed, $failed failed"
    if [[ $rc -eq 0 && $failed -gt 0 ]]; then
        rc=1
    fi
    exit "$rc"
}

# shellcheck disable=SC2329 # Invoked by the INT and TERM traps below.
on_signal() {
    if [[ $IN_CREATE -eq 1 ]]; then
        PENDING_EXIT=130
        return 0
    fi
    exit 130
}


# ---------------------------------------------------------------------------------------------
# Step 1: ready (prerequisite)

# shellcheck disable=SC2329 # Invoked through poll.
readiness_once() {
    local broker flag
    http GET "$BASE_URL/broker-service/readyz"
    broker="$(status_text)"
    http GET "$BASE_URL/feature-flag-service/readyz"
    flag="$(status_text)"
    POLL_DETAIL="broker-service readyz gave $broker, feature-flag-service readyz gave $flag"
    [[ "$broker" == "status 200" && "$flag" == "status 200" ]]
}

step1_ready() {
    local running missing="" service flag_id modifiable enabled raw_interval
    running="$(running_services)" || running=""
    for service in $REQUIRED_SERVICES; do
        if ! grep -qxF "$service" <<<"$running"; then
            missing="$missing $service"
        fi
    done
    if [[ -n "$missing" ]]; then
        abort "step 1 services running" "not running in project [$PROJECT]:$missing"
    fi
    pass "step 1 services running"

    if ! poll "step 1 readiness" "$READY_TIMEOUT_SECONDS" "$READY_STEP_SECONDS" readiness_once; then
        exit 1
    fi
    pass "step 1 readiness"

    http GET "$F"
    if [[ "$HTTP_STATUS" != "200" ]]; then
        abort "step 1 flag modifiable" "GET $FLAG_ID gave $(status_text); body [$(body_snippet)]"
    fi
    flag_id="$(jget '.id' "$HTTP_BODY")"
    modifiable="$(jget '.isModifiable' "$HTTP_BODY")"
    enabled="$(jget '.enabled' "$HTTP_BODY")"
    if [[ "$flag_id" != "$FLAG_ID" || ("$enabled" != "true" && "$enabled" != "false") ]]; then
        abort "step 1 flag modifiable" "GET $FLAG_ID answered id [$flag_id] enabled [$enabled]"
    fi
    if [[ "$modifiable" != "true" ]]; then
        abort "step 1 flag modifiable" "isModifiable is [$modifiable]: a deployment with ENABLE_MODIFY=false cannot be toggled"
    fi
    FLAG_INITIAL="$enabled"
    pass "step 1 flag modifiable"
    info "flag $FLAG_ID initially enabled=$FLAG_INITIAL"
    if [[ "$FLAG_INITIAL" == "true" ]]; then
        info "switching $FLAG_ID off for step 2; it is restored on exit"
        FLAG_TOUCHED=1
        http PUT "$F" '{"enabled": false}'
        if [[ "$HTTP_STATUS" != "200" || "$(jget '.enabled' "$HTTP_BODY")" != "false" ]]; then
            abort "step 1 flag switched off" "PUT {\"enabled\": false} gave $(status_text); body [$(body_snippet)]"
        fi
    fi

    DIALECT="$(container_env db-adapter DB_TYPE)" || DIALECT=""
    if [[ "$DIALECT" != "mssql" && "$DIALECT" != "postgres" ]]; then
        abort "step 1 runtime facts" "db-adapter DB_TYPE is [$DIALECT], expected mssql or postgres"
    fi
    raw_interval="$(container_env broker-service ALERT_EVALUATION_INTERVAL_SECONDS)" || raw_interval=""
    INTERVAL="$(resolve_interval "$raw_interval")"
    pass "step 1 runtime facts"
    info "db type $DIALECT; evaluation interval ${INTERVAL}s (ALERT_EVALUATION_INTERVAL_SECONDS [$raw_interval])"
}

# ---------------------------------------------------------------------------------------------
# Step 2: flag off

step2_flag_off() {
    http GET "$F"
    expect_json "step 2 flag reads disabled" 200 \
        'if .enabled == false and .tag == "feature" then "ok"
         else "enabled [\(.enabled)] tag [\(.tag)], expected false and feature" end'

    http GET "$BASE_URL/feature-flag-service/v1/flags?tag=problem_pattern"
    expect_json "step 2 flag not listed as a problem pattern" 200 \
        'if (.results | type) != "array" then "no results array"
         elif any(.results[]; .id == "portfolio-insights-enabled") then "listed under tag problem_pattern"
         else "ok" end'

    check_forbidden_endpoints "step 2" "$(random_guid)" "$(random_guid)" "$(random_guid)"
}

# ---------------------------------------------------------------------------------------------
# Step 3: fixture (prerequisite, except the browser check)

# signup CHECK USERNAME PASSWORD LAST_NAME: POST /api/auth/signup with every required field.
# Sets SIGNUP_ID; aborts unless it answers 201 with an id. PASSWORD reaches jq as its whole
# stdin, from the printf builtin, never as a command argument.
signup() {
    local body
    body="$(printf '%s' "$3" | jq -c -R -s --arg packageId "$PACKAGE_ID" --arg username "$2" \
        --arg lastName "$4" \
        '. as $password
         | {packageId: $packageId, firstName: "Portfolio", lastName: $lastName,
            username: $username, email: "\($username)@example.com", password: $password,
            origin: "WEB", address: "1 Test Street, Springfield"}')"
    http POST "$U/api/auth/signup" "$body"
    SIGNUP_ID="$(jget '.id // empty' "$HTTP_BODY" | lower)"
    if [[ "$HTTP_STATUS" != "201" || ! "$SIGNUP_ID" =~ $UUID_RE ]]; then
        abort "$1" "$(status_text), expected 201 with an id; body [$(body_snippet)]"
    fi
    pass "$1"
}

step3_fixture() {
    local epoch body ids id n=0
    epoch="$(date -u +%s)"
    HOLDER_USER="pi-e2e-$epoch-holder"
    EMPTY_USER="pi-e2e-$epoch-empty"
    if ! HOLDER_PASSWORD="$(random_secret)" || ! EMPTY_PASSWORD="$(random_secret)"; then
        abort "step 3 signup holder" "no password generated: /dev/urandom did not supply 16 random bytes"
    fi
    signup "step 3 signup holder" "$HOLDER_USER" "$HOLDER_PASSWORD" "Holder"
    HOLDER_ID="$SIGNUP_ID"
    signup "step 3 signup empty" "$EMPTY_USER" "$EMPTY_PASSWORD" "Empty"
    EMPTY_ID="$SIGNUP_ID"
    info "fixture accounts $HOLDER_USER [$HOLDER_ID] and $EMPTY_USER [$EMPTY_ID]"

    body="$(jq -cn --argjson amount "$DEPOSIT_AMOUNT" --arg email "$HOLDER_USER@example.com" \
        '{amount: $amount, name: "Portfolio Holder", address: "1 Test Street, Springfield",
          email: $email, cardNumber: "5555555555554444", cardType: "mastercard", cvv: "123"}')"
    http POST "$B/v1/balance/$HOLDER_ID/deposit" "$body"
    if [[ "$HTTP_STATUS" != "200" ]]; then
        abort "step 3 deposit" "$(status_text), expected 200; body [$(body_snippet)]"
    fi
    pass "step 3 deposit"

    http GET "$B/v1/instrument?accountId=$HOLDER_ID"
    ids="$(jget '[.results[]?.id] | .[0:2] | join(" ")' "$HTTP_BODY" | lower)"
    if [[ "$HTTP_STATUS" != "200" || ! "$ids" =~ ^[0-9a-f-]{36}\ [0-9a-f-]{36}$ ]]; then
        abort "step 3 buy instrument 1" "the holder's instrument listing gave $(status_text) without two instruments; body [$(body_snippet)]"
    fi
    for id in $ids; do
        n=$((n + 1))
        http POST "$B/v1/trade/buy" "$(printf '{"accountId":"%s","instrumentId":"%s","amount":1}' "$HOLDER_ID" "$id")"
        if [[ "$HTTP_STATUS" != "200" ]]; then
            abort "step 3 buy instrument $n" "buying 1 of [$id] gave $(status_text); body [$(body_snippet)]"
        fi
        pass "step 3 buy instrument $n"
    done
    H1="${ids%% *}"

    http GET "$B/v1/instrument?accountId=$HOLDER_ID"
    if [[ "$HTTP_STATUS" != "200" ]]; then
        abort "step 3 holdings" "the holder's instrument listing gave $(status_text)"
    fi
    for id in $ids; do
        if [[ "$(jitem "$id" "$HTTP_BODY" '.amount >= 1')" != "true" ]]; then
            abort "step 3 holdings" "instrument [$id] shows amount [$(jitem "$id" "$HTTP_BODY" '.amount')], expected at least 1"
        fi
    done
    pass "step 3 holdings"

    if ! write_fixture '[]'; then
        abort "step 3 fixture file" "could not write $FIXTURE"
    fi
    info "fixture written to $FIXTURE"
    run_browser_check flag-off "step 3 browser flag-off"
}

# ---------------------------------------------------------------------------------------------
# Step 4: enable (prerequisite)

step4_enable() {
    local t4
    t4="$(now_rfc3339)"
    LOG4_SINCE="$(log_since_now)"
    FLAG_TOUCHED=1
    http PUT "$F" '{"enabled": true}'
    if [[ "$HTTP_STATUS" != "200" || "$(jget '.enabled' "$HTTP_BODY")" != "true" ]]; then
        abort "step 4 enable flag" "PUT {\"enabled\": true} gave $(status_text); body [$(body_snippet)]"
    fi
    pass "step 4 enable flag"
    info "flag $FLAG_ID enabled at $t4"

    # The broker reads the flag fresh on every request, so the very first request must pass.
    http GET "$INSIGHTS_URL/$HOLDER_ID"
    if [[ "$HTTP_STATUS" != "200" ]]; then
        abort "step 4 first insights request" "$(status_text), expected 200 with no retry; body [$(body_snippet)]"
    fi
    HOLDER_INSIGHTS="$HTTP_BODY"
    pass "step 4 first insights request"
}


# ---------------------------------------------------------------------------------------------
# Step 5: figures of the holder (doubles with a 1e-6 tolerance are precise enough here)

step5_figures() {
    local j="$HOLDER_INSIGHTS"
    jcheck "step 5 two allocations" \
        'if (.allocations | length) == 2 then "ok" else "\(.allocations | length) allocations, expected 2" end' "$j"
    jcheck "step 5 percents sum to 100" \
        '([.allocations[].percent] | add) as $sum
         | if $sum != null and (($sum - 100) | fabs) <= 1e-6 then "ok"
           else "allocation percents sum to \($sum)" end' "$j"
    jcheck "step 5 totalValue is the sum of the values" \
        '([.allocations[].value] | add) as $sum
         | if $sum != null and ((.totalValue - $sum) | fabs) <= 1e-6 then "ok"
           else "totalValue \(.totalValue), values sum to \($sum)" end' "$j"
    jcheck "step 5 largest position" \
        '([.allocations[].value] | max) as $max
         | ([.allocations[] | select(.value == $max) | .instrumentId | ascii_downcase] | min) as $lowest
         | if .largestPosition == null then "largestPosition is null"
           elif .largestPosition.value != $max then
             "largestPosition value \(.largestPosition.value), highest value \($max)"
           elif (.largestPosition.instrumentId | ascii_downcase) != $lowest then
             "largestPosition [\(.largestPosition.instrumentId)], expected [\($lowest)], the lowest id among the highest values"
           else "ok" end' "$j"
    jcheck "step 5 risk level" \
        '.largestPosition.percent as $share
         | (if $share == null then null elif $share < 25 then "LOW"
            elif $share <= 50 then "MEDIUM" else "HIGH" end) as $expected
         | if $expected == null then "largestPosition has no percent"
           elif .riskLevel == $expected then "ok"
           else "riskLevel [\(.riskLevel)], a largest share of \($share) % gives \($expected)" end' "$j"
    if poll "step 5 insights log line" "$LOG_LINE_TIMEOUT_SECONDS" "$LOG_STEP_SECONDS" \
        log_has_text "$LOG4_SINCE" "Portfolio insights for account [$HOLDER_ID]"; then
        pass "step 5 insights log line"
    fi
}

# ---------------------------------------------------------------------------------------------
# Step 6: the empty account

step6_empty() {
    http GET "$INSIGHTS_URL/$EMPTY_ID"
    expect_json "step 6 empty account insights" 200 \
        'if .totalValue == 0 and .totalInvested == 0 and .unrealizedPnl == 0
            and .unrealizedPnlPercent == 0 and .allocations == [] and .largestPosition == null
            and .riskLevel == null then "ok"
         else "got \(tojson)" end'
}

# ---------------------------------------------------------------------------------------------
# Step 7: every documented 400 and 404

step7_errors() {
    local nh unknown patch_status patch_body
    unknown="$(random_guid)"

    http GET "$B/v1/instrument?accountId=$EMPTY_ID"
    nh="$(jget 'first(.results[]? | select(.amount == 0) | .id) // empty' "$HTTP_BODY" | lower)"

    post_expect "step 7 POST type target_price 400" 400 \
        "$(alert_body "$HOLDER_ID" target_price "$H1" ABOVE 1)"
    post_expect "step 7 POST direction UP 400" 400 \
        "$(alert_body "$HOLDER_ID" TARGET_PRICE "$H1" UP 1)"
    post_expect "step 7 POST quoted threshold \"abc\" 400" 400 \
        "$(alert_body "$HOLDER_ID" TARGET_PRICE "$H1" ABOVE '"abc"')"
    post_expect "step 7 POST quoted threshold \"12\" 400" 400 \
        "$(alert_body "$HOLDER_ID" TARGET_PRICE "$H1" ABOVE '"12"')"
    post_expect "step 7 POST TARGET_PRICE threshold 0 400" 400 \
        "$(alert_body "$HOLDER_ID" TARGET_PRICE "$H1" ABOVE 0)"
    post_expect "step 7 POST TARGET_PRICE threshold -1 400" 400 \
        "$(alert_body "$HOLDER_ID" TARGET_PRICE "$H1" ABOVE -1)"
    post_expect "step 7 POST accountId missing 400" 400 \
        "$(printf '{"type":"TARGET_PRICE","instrumentId":"%s","direction":"ABOVE","threshold":1}' "$H1")"
    post_expect "step 7 POST threshold missing 400" 400 \
        "$(printf '{"accountId":"%s","type":"TARGET_PRICE","instrumentId":"%s","direction":"ABOVE"}' "$HOLDER_ID" "$H1")"
    if [[ "$nh" =~ $UUID_RE ]]; then
        post_expect "step 7 POST PROFIT_LOSS not held 400" 400 \
            "$(alert_body "$EMPTY_ID" PROFIT_LOSS "$nh" ABOVE 1)"
    else
        fail "step 7 POST PROFIT_LOSS not held 400" "the empty account's listing ($(status_text)) shows no instrument with amount 0"
    fi

    post_expect "step 7 POST unknown account 404" 404 \
        "$(alert_body "$unknown" TARGET_PRICE "$H1" ABOVE 1)"
    post_expect "step 7 POST unknown instrument 404" 404 \
        "$(alert_body "$HOLDER_ID" TARGET_PRICE "$unknown" ABOVE 1)"
    http GET "$ALERTS_URL?accountId=$unknown"
    expect_status "step 7 GET alerts unknown account 404" 404
    http GET "$ALERTS_URL/notifications?accountId=$unknown"
    expect_status "step 7 GET notifications unknown account 404" 404
    http PATCH "$ALERTS_URL/$unknown" '{"enabled":true}'
    expect_status "step 7 PATCH unknown alert 404" 404
    http DELETE "$ALERTS_URL/$unknown"
    expect_status "step 7 DELETE unknown alert 404" 404
    http POST "$ALERTS_URL/$unknown/acknowledge"
    expect_status "step 7 POST acknowledge unknown alert 404" 404

    if ! create_alert "$HOLDER_ID" TARGET_PRICE "$H1" ABOVE "$MAX_THRESHOLD"; then
        fail "step 7 PATCH {} 400" "creating the temporary alert: $CREATE_ERROR"
        return 0
    fi
    http PATCH "$ALERTS_URL/$CREATED_ID" '{}'
    patch_status="$HTTP_STATUS"
    patch_body="$(body_snippet)"
    delete_alert "$CREATED_ID"
    if [[ "$patch_status" == "400" && "$HTTP_STATUS" == "204" ]]; then
        pass "step 7 PATCH {} 400"
    else
        fail "step 7 PATCH {} 400" "PATCH {} gave status $patch_status body [$patch_body], expected 400; the temporary alert's DELETE gave $(status_text), expected 204"
    fi
}

# ---------------------------------------------------------------------------------------------
# Step 8: CRUD for both types

CREATED_FILTER='if .enabled == true and .armingRevision == 1 and .triggeredAt == null
        and .triggerValue == null and .acknowledged == false then "ok"
    else "enabled [\(.enabled)] armingRevision [\(.armingRevision)] triggeredAt [\(.triggeredAt)] triggerValue [\(.triggerValue)] acknowledged [\(.acknowledged)]" end'

# create_checked CHECK TYPE: creates TYPE ABOVE the domain maximum on H1 and checks the 201.
# Leaves the id in CREATED_ID, empty when the create failed.
create_checked() {
    local reason="" verdict
    if ! create_alert "$HOLDER_ID" "$2" "$H1" ABOVE "$MAX_THRESHOLD"; then
        fail "$1" "$CREATE_ERROR"
        return 0
    fi
    verdict="$(jget "$CREATED_FILTER" "$HTTP_BODY")"
    if [[ "$verdict" != "ok" ]]; then
        reason="${verdict:-unreadable body}"
    fi
    if grep -qi '^location:' "$PRIVATE_DIR/headers"; then
        reason="${reason:+$reason; }a Location header was sent"
    fi
    if [[ -z "$reason" ]]; then
        pass "$1"
    else
        fail "$1" "$reason"
    fi
}

step8_crud() {
    local tp="" pl="" id type list
    create_checked "step 8 create TARGET_PRICE" TARGET_PRICE
    tp="$CREATED_ID"
    create_checked "step 8 create PROFIT_LOSS" PROFIT_LOSS
    pl="$CREATED_ID"

    http GET "$ALERTS_URL?accountId=$HOLDER_ID"
    if [[ -z "$tp" || -z "$pl" ]]; then
        fail "step 8 list newest first" "both alerts are needed and at least one create failed"
    else
        expect_json "step 8 list newest first" 200 \
            "(.results | map(.id | ascii_downcase)) as \$ids
             | (\$ids | index(\"$pl\")) as \$p | (\$ids | index(\"$tp\")) as \$t
             | if \$p == null or \$t == null then \"listed ids \(\$ids), expected both $pl and $tp\"
               elif \$p < \$t then \"ok\"
               else \"PROFIT_LOSS $pl is listed after TARGET_PRICE $tp\" end"
    fi

    for id in "$tp" "$pl"; do
        if [[ -z "$id" ]]; then
            continue
        fi
        if [[ "$id" == "$tp" ]]; then
            type="TARGET_PRICE"
        else
            type="PROFIT_LOSS"
        fi
        http PATCH "$ALERTS_URL/$id" '{"enabled":false}'
        expect_json "step 8 $type disable" 200 \
            'if .enabled == false then "ok" else "enabled [\(.enabled)], expected false" end'
        http PATCH "$ALERTS_URL/$id" '{"enabled":true}'
        expect_json "step 8 $type re-arm" 200 \
            'if .enabled == true and .armingRevision == 2 and .triggeredAt == null then "ok"
             else "enabled [\(.enabled)] armingRevision [\(.armingRevision)] triggeredAt [\(.triggeredAt)], expected true, 2 and null" end'
        delete_alert "$id"
        expect_status "step 8 $type delete" 204
        http GET "$ALERTS_URL?accountId=$HOLDER_ID"
        list="$HTTP_BODY"
        if [[ "$HTTP_STATUS" == "200" && "$(jcount "$id" "$list")" == "0" ]]; then
            pass "step 8 $type absent after delete"
        else
            fail "step 8 $type absent after delete" "$(status_text), alert listed $(jcount "$id" "$list") times"
        fi
        http DELETE "$ALERTS_URL/$id"
        expect_status "step 8 $type second delete 404" 404
    done
}


# ---------------------------------------------------------------------------------------------
# Step 9: a trigger within two evaluation cycles

# shellcheck disable=SC2329 # Invoked by pairs_notified, a poll command.
# pair_listed PAIR: whether a member of PAIR is in $RUN_DIR/listed.
pair_listed() {
    local id pair rest
    while read -r id pair rest; do
        if [[ "$pair" == "$1" ]] && grep -qxF "$id" "$RUN_DIR/listed"; then
            return 0
        fi
    done <"$RUN_DIR/pairs"
    return 1
}

# shellcheck disable=SC2329 # Invoked through poll.
# pairs_notified: poll command; true once every pair has a member among the notifications.
pairs_notified() {
    local pair missing=""
    http GET "$ALERTS_URL/notifications?accountId=$HOLDER_ID"
    if [[ "$HTTP_STATUS" != "200" ]]; then
        POLL_DETAIL="the last notifications request gave $(status_text)"
        return 1
    fi
    NOTIFICATIONS="$HTTP_BODY"
    jget '.results[]?.id' "$NOTIFICATIONS" | lower >"$RUN_DIR/listed"
    for pair in $PAIRS; do
        if ! pair_listed "$pair"; then
            missing="$missing $pair"
        fi
    done
    POLL_DETAIL="pairs without a notification:$missing"
    [[ -z "$missing" ]]
}

# skip_later_steps REASON: one FAIL line for each of steps 10 to 12, which need the pair alerts
# of step 9. Those steps then return at once, since PAIRS_READY stays 0.
skip_later_steps() {
    SKIP_REASON="$1"
    fail "step 10 no second notification" "skipped: $SKIP_REASON"
    fail "step 11 browser flag-on" "skipped: $SKIP_REASON"
    fail "step 12 untriggered acknowledge" "skipped: $SKIP_REASON"
}

step9_trigger() {
    local id close units chosen="" c="" t9 spec pair type direction threshold errors="" fields
    local revision triggered_at value value_units threshold_units cycles

    http GET "$B/v1/instrument?accountId=$HOLDER_ID"
    if [[ "$HTTP_STATUS" == "200" ]]; then
        while read -r id close; do
            if units="$(num_to_units "$close")" &&
                [[ $units -ge $MIN_CLOSE_UNITS && $units -le $MAX_CLOSE_UNITS ]]; then
                chosen="$id"
                c="$units"
                break
            fi
        done < <(jget '.results[]? | select(.amount >= 1) | "\(.id) \(.price.close)"' "$HTTP_BODY" | lower)
    fi
    if [[ -z "$chosen" ]]; then
        fail "step 9 instrument with a usable close" "no held instrument has a close from 0.00000002 to 9999999999.99999998 (listing $(status_text))"
        skip_later_steps "no held instrument with a usable close"
        return 0
    fi
    pass "step 9 instrument with a usable close"
    info "pair alerts on instrument [$chosen], listed close $(units_to_dec "$c")"

    # The window opens before the first create, so every later cycle and trigger line is new.
    t9="$(now_rfc3339)"
    LOG9_SINCE="$(log_since_now)"
    if read_window "$LOG9_SINCE"; then
        BASE9="$(window_cycles)"
    else
        BASE9=0
        info "broker-service logs unreadable at $t9 (see $RUN_DIR/compose.log)"
    fi
    info "creating the pair alerts at $t9; $BASE9 cycle lines already in the log window"
    for spec in \
        "target_price TARGET_PRICE ABOVE $(units_to_dec $((c - 1)))" \
        "target_price TARGET_PRICE BELOW $(units_to_dec $((c + 1)))" \
        "profit_loss PROFIT_LOSS ABOVE $PL_ABOVE_THRESHOLD" \
        "profit_loss PROFIT_LOSS BELOW $PL_BELOW_THRESHOLD"; do
        read -r pair type direction threshold <<<"$spec"
        if create_alert "$HOLDER_ID" "$type" "$chosen" "$direction" "$threshold"; then
            echo "$CREATED_ID $pair $type $direction $threshold" >>"$RUN_DIR/pairs"
        else
            errors="$errors $pair $direction $threshold: $CREATE_ERROR;"
        fi
    done
    if [[ -n "$errors" ]]; then
        fail "step 9 create pair alerts" "${errors# }"
        skip_later_steps "the pair alerts could not all be created"
        return 0
    fi
    pass "step 9 create pair alerts"
    PAIRS_READY=1

    NOTIFICATIONS='{"results":[]}'
    : >"$RUN_DIR/listed"
    if poll "step 9 each pair notified within two cycles" $((2 * INTERVAL + 30)) \
        "$NOTIFY_STEP_SECONDS" pairs_notified; then
        pass "step 9 each pair notified within two cycles"
    fi
    jcheck "step 9 notifications unique" \
        '[.results[]?.id | ascii_downcase]
         | if length == (unique | length) then "ok"
           else "listed more than once: \(group_by(.) | map(select(length > 1) | .[0]) | join(", "))" end' \
        "$NOTIFICATIONS"

    while read -r id pair type direction threshold; do
        if ! grep -qxF "$id" "$RUN_DIR/listed"; then
            continue
        fi
        fields="$(jitem "$id" "$NOTIFICATIONS" '"\(.armingRevision) \(.triggeredAt) \(.triggerValue)"')"
        read -r revision triggered_at value <<<"$fields"
        info "triggered $pair $direction $id revision $revision"
        echo "$id $revision $triggered_at $pair $direction" >>"$RUN_DIR/triggered"

        threshold_units="$(dec_to_units "$threshold")"
        if ! value_units="$(num_to_units "$value")"; then
            fail "step 9 $pair $direction trigger value" "triggerValue [$value] is not a readable decimal"
        elif [[ ("$direction" == "ABOVE" && $value_units -ge $threshold_units) ||
            ("$direction" == "BELOW" && $value_units -le $threshold_units) ]]; then
            pass "step 9 $pair $direction trigger value"
        else
            fail "step 9 $pair $direction trigger value" "triggerValue [$value] is not on the $direction side of threshold [$threshold]"
        fi

        if poll "step 9 $pair $direction trigger log line" "$LOG_LINE_TIMEOUT_SECONDS" \
            "$LOG_STEP_SECONDS" trigger_logged "$id" "$revision"; then
            cycles=$((TRIGGER_CYCLES - BASE9))
            if [[ -z "$LAST_TRIGGER_INDEX" || $TRIGGER_INDEX -gt $LAST_TRIGGER_INDEX ]]; then
                LAST_TRIGGER_INDEX=$TRIGGER_INDEX
            fi
            if [[ $cycles -le 2 ]]; then
                pass "step 9 $pair $direction trigger log line"
            else
                fail "step 9 $pair $direction trigger log line" "$cycles cycle lines between the creation and the trigger line, at most 2 allowed"
            fi
        fi
    done <"$RUN_DIR/pairs"
}

# ---------------------------------------------------------------------------------------------
# Step 10: no second notification

step10_no_repeat() {
    local id revision triggered_at pair direction problems="" count fields
    if [[ $PAIRS_READY -ne 1 ]]; then
        return 0
    fi
    if [[ ! -s "$RUN_DIR/triggered" ]]; then
        fail "step 10 no second notification" "no alert triggered in step 9"
        return 0
    fi
    if [[ -z "$LAST_TRIGGER_INDEX" ]]; then
        fail "step 10 a later cycle completed" "no trigger line was found in step 9 to count cycles from"
    elif poll "step 10 a later cycle completed" $((INTERVAL + 30)) "$LOG_STEP_SECONDS" later_cycles_seen; then
        pass "step 10 a later cycle completed"
    fi

    http GET "$ALERTS_URL/notifications?accountId=$HOLDER_ID"
    if [[ "$HTTP_STATUS" != "200" ]]; then
        fail "step 10 no second notification" "$(status_text); body [$(body_snippet)]"
        return 0
    fi
    while read -r id revision triggered_at pair direction; do
        count="$(jcount "$id" "$HTTP_BODY")"
        fields="$(jitem "$id" "$HTTP_BODY" '"\(.armingRevision) \(.triggeredAt)"')"
        if [[ "$count" != "1" ]]; then
            problems="$problems $pair $direction [$id] listed $count times;"
        elif [[ "$fields" != "$revision $triggered_at" ]]; then
            problems="$problems $pair $direction [$id] now revision and triggeredAt [$fields], was [$revision $triggered_at];"
        fi
    done <"$RUN_DIR/triggered"
    if [[ -z "$problems" ]]; then
        pass "step 10 no second notification"
    else
        fail "step 10 no second notification" "${problems# }"
    fi
}

# ---------------------------------------------------------------------------------------------
# Step 11: browser check with the flag on

step11_browser() {
    local id pair type direction threshold revision list missing="" alerts
    if [[ $PAIRS_READY -ne 1 ]]; then
        return 0
    fi
    http GET "$ALERTS_URL?accountId=$HOLDER_ID"
    list="$HTTP_BODY"
    if [[ "$HTTP_STATUS" != "200" ]]; then
        fail "step 11 browser flag-on" "listing the holder's alerts for the fixture gave $(status_text)"
        return 0
    fi
    : >"$RUN_DIR/fixture-alerts"
    while read -r id pair type direction threshold; do
        revision="$(jitem "$id" "$list" '.armingRevision')"
        if [[ ! "$revision" =~ ^[0-9]+$ ]]; then
            missing="$missing $id"
            continue
        fi
        jq -cn --arg id "$id" --arg pair "$pair" --arg type "$type" --arg direction "$direction" \
            --arg threshold "$threshold" --argjson armingRevision "$revision" \
            '{id: $id, pair: $pair, type: $type, direction: $direction, threshold: $threshold,
              armingRevision: $armingRevision}' >>"$RUN_DIR/fixture-alerts"
    done <"$RUN_DIR/pairs"
    if [[ -n "$missing" ]]; then
        fail "step 11 browser flag-on" "pair alerts missing from the holder's list:$missing"
        return 0
    fi
    alerts="$(jq -cs '.' "$RUN_DIR/fixture-alerts")"
    if ! write_fixture "$alerts"; then
        fail "step 11 browser flag-on" "could not write $FIXTURE"
        return 0
    fi
    run_browser_check flag-on "step 11 browser flag-on"

    # The check's live shutdown turns the flag off and on again; step 12 needs it on.
    http GET "$F"
    if [[ "$HTTP_STATUS" != "200" || "$(jget '.enabled' "$HTTP_BODY")" != "true" ]]; then
        info "flag $FLAG_ID is not on after the browser check ($(status_text)); switching it on for step 12"
        FLAG_TOUCHED=1
        http PUT "$F" '{"enabled": true}'
        info "PUT {\"enabled\": true} gave $(status_text)"
    fi
}

# ---------------------------------------------------------------------------------------------
# Step 12: acknowledging an untriggered alert changes nothing

step12_untriggered_ack() {
    local id before after evidence fields ack_id ack_revision
    if [[ $PAIRS_READY -ne 1 ]]; then
        return 0
    fi
    if ! create_alert "$HOLDER_ID" TARGET_PRICE "$H1" ABOVE "$MAX_THRESHOLD"; then
        fail "step 12 disabled untriggered alert" "$CREATE_ERROR"
        fail "step 12 acknowledge leaves an untriggered alert unchanged" "no alert to acknowledge"
    else
        id="$CREATED_ID"
        http PATCH "$ALERTS_URL/$id" '{"enabled":false}'
        if [[ "$HTTP_STATUS" != "200" ]]; then
            fail "step 12 disabled untriggered alert" "PATCH {\"enabled\":false} gave $(status_text); body [$(body_snippet)]"
        else
            http GET "$ALERTS_URL?accountId=$HOLDER_ID"
            before="$(jitem "$id" "$HTTP_BODY")"
            if [[ "$HTTP_STATUS" == "200" && "$(jitem "$id" "$HTTP_BODY" '"\(.enabled) \(.triggeredAt)"')" == "false null" ]]; then
                pass "step 12 disabled untriggered alert"
            else
                fail "step 12 disabled untriggered alert" "$(status_text), list row [$before], expected enabled false and triggeredAt null"
            fi
        fi
        http POST "$ALERTS_URL/$id/acknowledge"
        if [[ "$HTTP_STATUS" != "204" ]]; then
            fail "step 12 acknowledge leaves an untriggered alert unchanged" "$(status_text), expected 204; body [$(body_snippet)]"
        else
            http GET "$ALERTS_URL?accountId=$HOLDER_ID"
            after="$(jitem "$id" "$HTTP_BODY")"
            if [[ -n "${before:-}" && "$after" == "$before" ]]; then
                pass "step 12 acknowledge leaves an untriggered alert unchanged"
            else
                fail "step 12 acknowledge leaves an untriggered alert unchanged" "row before [${before:-}], after [$after]"
            fi
        fi
    fi

    evidence="$EVIDENCE_DIR/portfolio-insights-page-check-flag-on.json"
    if [[ ! -f "$evidence" ]]; then
        fail "step 12 browser acknowledgement persisted" "evidence file $evidence is missing"
        return 0
    fi
    fields="$(jq -r '.acknowledged | if type == "object" then "\(.id) \(.armingRevision)" else empty end' \
        "$evidence" 2>/dev/null | tr -d '\r' | lower || true)"
    read -r ack_id ack_revision <<<"$fields"
    if [[ ! "${ack_id:-}" =~ $UUID_RE || ! "${ack_revision:-}" =~ ^[0-9]+$ ]]; then
        fail "step 12 browser acknowledgement persisted" "$evidence has no acknowledged {id, armingRevision}"
        return 0
    fi
    http GET "$ALERTS_URL?accountId=$HOLDER_ID"
    fields="$(jitem "$ack_id" "$HTTP_BODY" '"\(.acknowledged) \(.armingRevision)"')"
    if [[ "$HTTP_STATUS" == "200" && "$fields" == "true $ack_revision" ]]; then
        pass "step 12 browser acknowledgement persisted"
    else
        fail "step 12 browser acknowledgement persisted" "$(status_text); alert [$ack_id] shows acknowledged and revision [$fields], expected [true $ack_revision]"
    fi
}

# ---------------------------------------------------------------------------------------------
# Step 13: clean up and disable

step13_cleanup_and_disable() {
    local id remaining problems=""
    remaining="$(remaining_owned)"
    while IFS= read -r id; do
        delete_alert "$id"
        if [[ "$HTTP_STATUS" != "204" ]]; then
            problems="$problems [$id] $(status_text);"
        fi
    done <"$RUN_DIR/to-delete"
    if [[ -z "$problems" ]]; then
        pass "step 13 delete owned alerts"
        info "deleted $remaining owned alerts"
    else
        fail "step 13 delete owned alerts" "expected 204 each:$problems"
    fi

    http GET "$ALERTS_URL/notifications?accountId=$HOLDER_ID"
    if [[ "$HTTP_STATUS" == "200" && "$(jget 'tojson' "$HTTP_BODY")" == '{"results":[]}' ]]; then
        pass "step 13 notifications empty"
    else
        fail "step 13 notifications empty" "$(status_text); body [$(body_snippet)], expected {\"results\":[]}"
    fi

    FLAG_TOUCHED=1
    http PUT "$F" '{"enabled": false}'
    if [[ "$HTTP_STATUS" == "200" && "$(jget '.enabled' "$HTTP_BODY")" == "false" ]]; then
        pass "step 13 disable flag"
    else
        fail "step 13 disable flag" "PUT {\"enabled\": false} gave $(status_text); body [$(body_snippet)]"
    fi
    check_forbidden_endpoints "step 13" "$HOLDER_ID" "$(random_guid)" "$(random_guid)"
}

# ---------------------------------------------------------------------------------------------
# Main

trap cleanup EXIT
trap on_signal INT TERM

info "run dir $RUN_DIR"
info "started $(now_rfc3339): project [$PROJECT], base url $BASE_URL, compose file $COMPOSE_FILE, evidence dir $EVIDENCE_DIR"
step1_ready
step2_flag_off
step3_fixture
step4_enable
step5_figures
step6_empty
step7_errors
step8_crud
step9_trigger
step10_no_repeat
step11_browser
step12_untriggered_ack
step13_cleanup_and_disable
if [[ $failed -gt 0 ]]; then
    exit 1
fi
exit 0

