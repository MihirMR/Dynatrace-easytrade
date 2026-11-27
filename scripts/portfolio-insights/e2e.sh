#!/usr/bin/env bash
# Portfolio Insights reachability and API end-to-end check against one running Compose project.
# It walks the feature's 13 end-to-end steps through the reverse proxy: the flag off, a fixture
# of two fresh accounts, enabling the flag, the insights figures, the empty account, every
# documented 400 and 404, alert CRUD for both types, a trigger within two evaluation cycles, no
# second notification, the browser check in both modes, an untriggered acknowledge, and cleanup.
# Run it from the repository root, once per dialect, against a project whose stack is up with
# the shipped defaults: step 1 stops the run, before any write, unless the flag starts disabled.
#
# Usage: scripts/portfolio-insights/e2e.sh --project NAME [--base-url URL]
#            [--compose-file FILE] [--evidence-dir DIR]
#   --project NAME       Compose project of the running stack (required)
#   --base-url URL       Reverse-proxy origin of that stack (default: http://localhost)
#   --compose-file FILE  Compose file of that project, relative to the current directory
#                        (default: compose.dev.yaml)
#   --evidence-dir DIR   Directory in which each run creates its own evidence directory,
#                        pi-e2e-evidence.XXXXXX, printed at start, for the browser check
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
# and end, keeps the working files the run derives, never a copy of a response body, and the
# browser evidence unless --evidence-dir is given. Each run's evidence directory is new and its
# own, so no run reads, overwrites or removes another run's evidence; it is printed at start,
# and at end too when it is not the run directory.

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
# Every broker-service log read runs under timeout(1), so a Docker call that never answers
# cannot hold the run. Inside poll it may take the time left to the poll's deadline; a read
# outside any poll may take this fixed bound. Either is a hard limit on the whole read, its
# termination included: TERM comes LOG_PROBE_KILL_SECONDS before the limit and KILL at it.
LOG_PROBE_TIMEOUT_SECONDS=60
LOG_PROBE_KILL_SECONDS=5
# Cleanup stops sending DELETEs after this many transport errors in a row.
MAX_CONSECUTIVE_TRANSPORT_ERRORS=5
# The threshold domain maximum (10 integer and 8 fractional digits), sent as the exact token.
MAX_THRESHOLD="9999999999.99999999"
# The trigger-value domain: at most 20 integer and 8 fractional digits once normalised, so
# |value| <= MAX_TRIGGER_VALUE, 28 significant digits.
MAX_TRIGGER_VALUE="99999999999999999999.99999999"
TRIGGER_INTEGER_DIGITS=20
TRIGGER_FRACTION_DIGITS=8
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
# "Alert evaluation cycle finished: alerts [n] triggered [n] failed [n] skipped [n] outcome
# [completed|failed] duration [n] ms", as AlertEvaluationService renders it.
CYCLE_RE='Alert evaluation cycle finished: alerts \[[0-9]+\] triggered \[[0-9]+\] failed \[[0-9]+\] skipped \[[0-9]+\] outcome \[(completed|failed)\] duration \[[0-9]+\] ms'
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
  --evidence-dir DIR   Directory in which each run creates its own evidence directory,
                       pi-e2e-evidence.XXXXXX, printed at start, for the browser check
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

# The origin helpers list their characters instead of using ranges, so no locale can widen a
# bracket expression beyond ASCII.
# scripts/portfolio-insights/harness-test.sh tests these helpers and this script's Docker probes.

# is_port_number TEXT: 1 to 5 decimal digits whose value is from 1 to 65535.
is_port_number() {
    local re='^[0123456789]{1,5}$'
    [[ "$1" =~ $re ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

# is_ipv4_address TEXT: a dotted quad of four decimal octets from 0 to 255, none with a leading
# zero, which a WHATWG URL parser would read as octal.
is_ipv4_address() {
    local octet='(0|[123456789][0123456789]{0,2})' i
    local re="^${octet}\\.${octet}\\.${octet}\\.${octet}\$"
    [[ "$1" =~ $re ]] || return 1
    for i in 1 2 3 4; do
        ((10#${BASH_REMATCH[i]} <= 255)) || return 1
    done
}

# is_dns_name TEXT: labels of 1 to 63 letters, digits and inner hyphens joined by dots, with one
# optional trailing dot for a rooted name and at most 253 characters without it. The last label
# is not a number (all digits, or 0x and hex digits), since a WHATWG URL parser reads a host that
# ends in one as an IPv4 address.
is_dns_name() {
    local alnum='0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
    local label="[${alnum}]([${alnum}-]{0,61}[${alnum}])?"
    local re="^${label}(\\.${label})*\$"
    local number='^([0123456789]+|0[xX][0123456789ABCDEFabcdef]*)$'
    local name="${1%.}"
    ((${#name} <= 253)) && [[ "$name" =~ $re && ! "${name##*.}" =~ $number ]]
}

# is_ipv6_address TEXT: an unbracketed IPv6 address in RFC 4291 text form. That is one to eight
# groups of 1 to 4 hex digits, at most one "::" standing for one or more zero groups, and an
# optional trailing dotted quad that counts as two groups. A zone id is refused.
is_ipv6_address() {
    local hex='[0123456789ABCDEFabcdef]{1,4}'
    local re="^${hex}(:${hex})*\$"
    local text="$1" head tail quad part colons groups=0
    if [[ "$text" == *.* ]]; then
        quad="${text##*:}"
        is_ipv4_address "$quad" || return 1
        text="${text%"$quad"}0:0"
    fi
    head="$text"
    tail=""
    if [[ "$text" == *::* ]]; then
        head="${text%%::*}"
        tail="${text#*::}"
        [[ "$tail" != *::* ]] || return 1
    fi
    for part in "$head" "$tail"; do
        if [[ -n "$part" ]]; then
            [[ "$part" =~ $re ]] || return 1
            colons="${part//[!:]/}"
            groups=$((groups + ${#colons} + 1))
        fi
    done
    if [[ "$text" == *::* ]]; then
        ((groups < 8))
    else
        ((groups == 8))
    fi
}

# is_base_origin TEXT: an http:// or https:// origin, that is a host (a DNS name, an IPv4 address
# or a bracketed IPv6 literal) and an optional port, with at most one trailing slash. It refuses
# credentials, a path, a query, a fragment, whitespace and control characters, so an accepted
# origin is safe to print and to build every request URL from. A WHATWG URL parser, as the browser
# check uses, reads every origin it accepts as an origin.
is_base_origin() {
    local authority host port
    # No origin is longer than 269 characters: https://, a 253-character name and its root dot, a
    # five-digit port and a slash. Longer text is refused before any pattern runs on it.
    ((${#1} <= 269)) || return 1
    case "$1" in
        http://* | https://*) authority="${1#*://}" ;;
        *) return 1 ;;
    esac
    authority="${authority%/}"
    if [[ "$authority" == \[* ]]; then
        [[ "$authority" == *\]* ]] || return 1
        host="${authority%%\]*}"
        port="${authority#*\]}"
        is_ipv6_address "${host#\[}" || return 1
    else
        host="${authority%%:*}"
        port="${authority#"$host"}"
        is_ipv4_address "$host" || is_dns_name "$host" || return 1
    fi
    [[ -z "$port" ]] || { [[ "$port" == :* ]] && is_port_number "${port#:}"; }
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
            # Only a bare option name is echoed: a stray value or a --name=value argument can be
            # a URL that holds credentials.
            if [[ "$1" =~ ^--?[A-Za-z][A-Za-z0-9-]*$ ]]; then
                usage_error "Unknown option: $1"
            fi
            usage_error "Unknown argument (not shown): each option takes its value as the next argument."
            ;;
    esac
done

if [[ -z "$PROJECT" ]]; then
    usage_error "Option --project is required."
fi
# The browser check serves the app from the origin's root, so a path is refused here as well.
# The refused value is never echoed, since it can hold credentials.
if ! is_base_origin "$BASE_URL"; then
    usage_error "Option --base-url needs an http:// or https:// origin: a host and optional port, without credentials, path, query or fragment."
fi
BASE_URL="${BASE_URL%/}"
if [[ ! -f "$COMPOSE_FILE" ]]; then
    usage_error "Compose file not found: $COMPOSE_FILE (resolved from $(pwd); the repository root is $REPO_ROOT)"
fi

missing_tools=""
for tool in bash curl jq docker node timeout; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing_tools="$missing_tools $tool"
    fi
done
if [[ -n "$missing_tools" ]]; then
    echo "Missing required tools:$missing_tools" >&2
    exit 2
fi
# Trigger values and closes are read as the number literal jq prints for the unmodified value.
# jq before 1.7 reads every number as a double and prints MAX_TRIGGER_VALUE as 1e+20, so a jq
# that changes the literal, printed directly, interpolated or through tojson, is refused.
if [[ "$(jq -c '[.v, "\(.v)", (.v | tojson)]' <<<"{\"v\":$MAX_TRIGGER_VALUE}" 2>/dev/null | tr -d '\r')" != \
    "[$MAX_TRIGGER_VALUE,\"$MAX_TRIGGER_VALUE\",\"$MAX_TRIGGER_VALUE\"]" ]]; then
    echo "jq must keep number literals exact (jq 1.7 or later); $(jq --version 2>/dev/null | tr -d '\r') changes $MAX_TRIGGER_VALUE." >&2
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
# The browser check runs from src/loadgen, so every path handed to it is absolute. Its reports
# have fixed names, so each run gets an evidence directory no other run writes to: the run
# directory, or a new pi-e2e-evidence.XXXXXX directory inside the --evidence-dir one. A report
# step 12 reads can then only be this run's, and no earlier run's evidence is replaced.
evidence_parent="$EVIDENCE_DIR"
if [[ -z "$evidence_parent" ]]; then
    EVIDENCE_DIR="$RUN_DIR"
elif ! mkdir -p "$evidence_parent" || ! EVIDENCE_DIR="$(cd "$evidence_parent" && pwd)" ||
    ! EVIDENCE_DIR="$(mktemp -d "$EVIDENCE_DIR/pi-e2e-evidence.XXXXXX")"; then
    echo "Could not create the evidence directory: $evidence_parent/pi-e2e-evidence.XXXXXX" >&2
    rmdir "$RUN_DIR" "$PRIVATE_DIR"
    exit 2
fi
FIXTURE="$PRIVATE_DIR/fixture.json"
PRIVATE_LEFT=""
: >"$RUN_DIR/owned"
: >"$RUN_DIR/deleted"
: >"$RUN_DIR/pairs"
: >"$RUN_DIR/triggered"
: >"$RUN_DIR/trigger-lines"

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
PAIRS_READY=0
SKIP_REASON=""
POLL_DETAIL=""
# The absolute deadline (epoch seconds) of the poll running now, empty outside a poll, and why
# the last log read failed.
PROBE_DEADLINE=""
LOG_PROBE_DETAIL=""

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
        HTTP_ERROR="$(tr -d '\r' <"$PRIVATE_DIR/curl-error" | { grep -v 'Debug-enabled' || true; } | head -c 300)"
    else
        HTTP_STATUS="${out%% *}"
        HTTP_CTYPE="${out#* }"
        HTTP_ERROR=""
    fi
    # A shell variable cannot hold NUL, so a body's NUL bytes are dropped here, without bash's
    # warning; the exact bytes stay in the file.
    HTTP_BODY="$(tr -d '\000' <"$PRIVATE_DIR/body")"
}

# jget FILTER JSON [JQ-OPTION...]: jq's raw output for FILTER, run on JSON with the options, or
# nothing unless JSON is exactly one complete JSON document and jq succeeds. Reading a document
# at a time, jq prints FILTER's output for a valid first document before it fails on the bytes
# after it, and runs FILTER again on a second document, so a valid body followed by anything
# would pass as that body. Slurped, FILTER runs only once all of JSON parses, and only on a lone
# document. FILTER keeps lines of its own, so it may begin with def and end with a comment.
# Carriage returns and NUL bytes, which no shell variable holds, are dropped from the output.
jget() {
    local out nl=$'\n'
    local program="if length == 1 then .[0] | ($nl$1$nl) else empty end"
    out="$(
        set -o pipefail
        MSYS_NO_PATHCONV=1 jq -r -s "${@:3}" "$program" 2>/dev/null <<<"$2" | tr -d '\r\000' &&
            printf x
    )" || return 0
    printf '%s' "${out%x}"
}

# jitem ID JSON [FILTER]: FILTER (default: the item itself, keys sorted, compact) applied to the
# first .results item whose id is ID. Prints nothing when there is none, or when JSON is not
# exactly one JSON document, as jget.
jitem() {
    jget "first(.results[]? | select((.id // \"\" | ascii_downcase) == \$id)) | ${3:-.}" "$2" \
        -S -c --arg id "$1"
}

# jcount ID JSON: how many .results items carry the id ID; nothing when JSON is not exactly one
# JSON document, as jget.
jcount() {
    jget '[.results[]? | select((.id // "" | ascii_downcase) == $id)] | length' "$2" --arg id "$1"
}

# flag_enabled JSON: the enabled state of a flag response, as feature-flag-service's Flag
# defines one (id a string, enabled a boolean): true or false only when JSON is one object whose
# id is exactly $FLAG_ID and whose enabled is a JSON boolean, never from jq -r's text, which
# reads a string "true" as true. Anything else prints what JSON holds instead, such as "id is
# portfolio-insights-enabled, enabled is a JSON string": the id only when it is $FLAG_ID and
# otherwise each field's JSON type, so no server text reaches a failure reason and no comparison
# with true or false passes on it.
flag_enabled() {
    local state
    state="$(jq -r -s --arg id "$FLAG_ID" '
        def kind: "a JSON \(type)";
        if length != 1 or (.[0] | type) != "object" then "not one JSON object"
        else .[0]
          | if .id == $id and (.enabled | type) == "boolean" then .enabled | tostring
            else "id is \(if .id == $id then $id elif (.id | type) == "string" then "another string"
                          else .id | kind end), enabled is \(if (.enabled | type) == "boolean"
                          then .enabled | tostring else .enabled | kind end)"
            end
        end' 2>/dev/null <<<"$1" | tr -d '\r')" || state=""
    echo "${state:-not JSON}"
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

# media_type: the media type of the last response, compared as RFC 9110 compares one: its
# Content-Type up to the first ";", without the spaces and tabs around it, in lower case. So
# parameters such as "; charset=utf-8" are not part of it, while application/jsonp and
# application/json-seq stay types of their own, never application/json.
media_type() {
    local type="${HTTP_CTYPE%%;*}"
    type="${type#"${type%%[![:blank:]]*}"}"
    type="${type%"${type##*[![:blank:]]}"}"
    printf '%s' "$type" | lower
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
# {"error":"feature_disabled"} and whose media type is exactly application/json, with or without
# parameters. read stops at the first NUL, so the body's size must also be the expected body's
# (ASCII, one byte a character).
expect_forbidden() {
    local check="$1" content="" size media
    shift
    http "$@"
    own_if_created
    IFS= read -r -d '' content <"$PRIVATE_DIR/body" || true
    size="$(wc -c <"$PRIVATE_DIR/body" | tr -d ' \r')" || size=""
    media="$(media_type)"
    if [[ "$HTTP_STATUS" == "403" && "$size" == "${#FORBIDDEN_BODY}" && "$content" == "$FORBIDDEN_BODY" &&
        "$media" == "application/json" ]]; then
        pass "$check"
    else
        fail "$check" "$(status_text), content type [$media], body [$(body_snippet)]; expected 403 application/json $FORBIDDEN_BODY"
    fi
}

# ---------------------------------------------------------------------------------------------
# Exact decimals. jq compares numbers as doubles and prints small ones in exponent form
# (0.00000001 comes out as 1E-8), so thresholds and closes are compared here as bash integers
# in units of 1e-8. Trigger values reach 20 integer digits, beyond int64 units, so they are
# compared as digit strings instead.

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

# num_split TEXT: a number as jq prints it, exponent form included (-1E-8, 1.5E+3), read
# exactly at any length. Sets NUM_SIGN ("-" or empty), NUM_DIGITS (the significant digits,
# without leading or trailing zeros), NUM_POINT (the decimal point's place in NUM_DIGITS: 0 is
# before the first digit, and it may lie outside them), and NUM_INTEGERS and NUM_FRACTIONS (the
# digit counts of the normalised value). Zero, -0 included, has an empty sign and no digits.
# Fails on anything that is not a JSON number.
num_split() {
    local int frac exp_sign exp lead
    if [[ ! "$1" =~ ^(-?)([0-9]+)(\.([0-9]+))?([eE]([+-]?)([0-9]+))?$ ]]; then
        return 1
    fi
    NUM_SIGN="${BASH_REMATCH[1]}"
    int="${BASH_REMATCH[2]}"
    frac="${BASH_REMATCH[4]}"
    exp_sign="${BASH_REMATCH[6]}"
    exp="${BASH_REMATCH[7]}"
    NUM_DIGITS="$int$frac"
    lead="${NUM_DIGITS%%[!0]*}"
    NUM_DIGITS="${NUM_DIGITS#"$lead"}"
    NUM_DIGITS="${NUM_DIGITS%"${NUM_DIGITS##*[!0]}"}"
    NUM_POINT=0
    NUM_INTEGERS=0
    NUM_FRACTIONS=0
    if [[ -z "$NUM_DIGITS" ]]; then
        NUM_SIGN=""
        return 0
    fi
    exp="${exp#"${exp%%[!0]*}"}"
    # An exponent of 18 or more digits moves the point past any text, so it is capped at 10^17:
    # the arithmetic stays inside int64 and the value stays outside every domain.
    if [[ ${#exp} -gt 17 ]]; then
        exp=100000000000000000
    fi
    NUM_POINT=$((${#int} - ${#lead}))
    if [[ "$exp_sign" == "-" ]]; then
        NUM_POINT=$((NUM_POINT - 10#${exp:-0}))
    else
        NUM_POINT=$((NUM_POINT + 10#${exp:-0}))
    fi
    if [[ $NUM_POINT -gt 0 ]]; then
        NUM_INTEGERS=$NUM_POINT
    fi
    if [[ $((${#NUM_DIGITS} - NUM_POINT)) -gt 0 ]]; then
        NUM_FRACTIONS=$((${#NUM_DIGITS} - NUM_POINT))
    fi
}

# magnitude_cmp DIGITS_A POINT_A DIGITS_B POINT_B: compares two magnitudes as num_split gives
# them. Prints -1, 0 or 1 as A is below, equal to or above B.
magnitude_cmp() {
    local a="$1" b="$3" zeros i x y
    if [[ -z "$a" || -z "$b" ]]; then
        if [[ -z "$a" && -z "$b" ]]; then
            echo 0
        elif [[ -z "$a" ]]; then
            echo -1
        else
            echo 1
        fi
        return 0
    fi
    # Both lead with a nonzero digit, so the later decimal point is the larger magnitude.
    if [[ $2 -ne $4 ]]; then
        if [[ $2 -lt $4 ]]; then
            echo -1
        else
            echo 1
        fi
        return 0
    fi
    printf -v zeros '%*s' "$((${#a} > ${#b} ? ${#a} - ${#b} : ${#b} - ${#a}))" ''
    if [[ ${#a} -lt ${#b} ]]; then
        a="$a${zeros// /0}"
    else
        b="$b${zeros// /0}"
    fi
    # Equal-length digit strings, compared 18 digits at a time so each part fits int64.
    for ((i = 0; i < ${#a}; i += 18)); do
        x=$((10#${a:i:18}))
        y=$((10#${b:i:18}))
        if [[ $x -ne $y ]]; then
            if [[ $x -lt $y ]]; then
                echo -1
            else
                echo 1
            fi
            return 0
        fi
    done
    echo 0
}

# num_cmp A B: exact comparison of two numbers as jq prints them, at any length. Prints -1, 0
# or 1 as A is below, equal to or above B. Fails when either is not a number.
num_cmp() {
    local a_sign a_digits a_point order
    num_split "$1" || return 1
    a_sign="$NUM_SIGN"
    a_digits="$NUM_DIGITS"
    a_point="$NUM_POINT"
    num_split "$2" || return 1
    # Zero has no sign, so differing signs alone decide: the negative number is the lower.
    if [[ "$a_sign" != "$NUM_SIGN" ]]; then
        if [[ "$a_sign" == "-" ]]; then
            echo -1
        else
            echo 1
        fi
        return 0
    fi
    order="$(magnitude_cmp "$a_digits" "$a_point" "$NUM_DIGITS" "$NUM_POINT")"
    if [[ "$a_sign" == "-" ]]; then
        order=$((-order))
    fi
    echo "$order"
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
# COMMAND's log reads see the deadline as PROBE_DEADLINE, local to this call, so it ends with
# the poll.
poll() {
    local check="$1" timeout="$2" step="$3" deadline
    shift 3
    deadline=$(($(date -u +%s) + timeout))
    local PROBE_DEADLINE="$deadline"
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

# hard_timeout LIMIT PROGRAM [ARGS...]: runs PROGRAM under timeout(1) so that it has ended,
# killed if need be, LIMIT seconds after it started. TERM comes LOG_PROBE_KILL_SECONDS before
# LIMIT, so a program that honours it can end cleanly, and KILL at LIMIT; with LIMIT no longer
# than that grace, KILL alone comes at LIMIT. Exits 124 or 137 when the limit cut PROGRAM off,
# otherwise with PROGRAM's status. Arguments reach docker unchanged, as in compose().
hard_timeout() {
    local limit="$1"
    shift
    if [[ $limit -gt $LOG_PROBE_KILL_SECONDS ]]; then
        MSYS_NO_PATHCONV=1 timeout -k "$LOG_PROBE_KILL_SECONDS" "$((limit - LOG_PROBE_KILL_SECONDS))" "$@"
    else
        MSYS_NO_PATHCONV=1 timeout -s KILL "$limit" "$@"
    fi
}

running_services() {
    compose ps --status running --services 2>>"$RUN_DIR/compose.log" | tr -d '\r'
}

# container_env SERVICE NAME: the value of NAME (which holds no "=") in the service container's
# environment, byte for byte: line feeds and carriage returns inside it and at its end included.
# The first entry named exactly NAME wins. jq hands the value over as base64, because jq on
# Windows writes text with CRLF line ends. Prints nothing when NAME is unset; fails when the
# service has no container. Capture it as "$(container_env S N && printf x)" and drop the x, so
# command substitution keeps any trailing line feed.
container_env() {
    local cid encoded value
    cid="$(compose ps -q "$1" 2>>"$RUN_DIR/compose.log" | tr -d '\r' | sed -n '1p')" || return 1
    if [[ -z "$cid" ]]; then
        return 1
    fi
    encoded="$(MSYS_NO_PATHCONV=1 docker inspect --format '{{json .Config.Env}}' "$cid" </dev/null \
        | jq -r --arg name "$2" 'first(.[]? | select(startswith($name + "="))) | ltrimstr($name + "=") | @base64')" \
        || return 1
    value="$(printf '%s' "$encoded" | tr -d '\r\n' | base64 -d && printf x)" || return 1
    printf '%s' "${value%x}"
}

# resolve_interval RAW: the broker's interval rule, RAW read as int.TryParse with
# NumberStyles.Integer and the invariant culture reads it: an optional + or - sign and ASCII
# digits, with optional white space around them that is only tab, line feed, vertical tab, form
# feed, carriage return and space. A whole number from 1 to MAX_INTERVAL_SECONDS is used;
# anything else, unset included, gives the default. Both sets are spelled out because
# [[:space:]] and [0-9] follow the locale: in a UTF-8 locale [[:space:]] also matches Unicode
# spaces .NET rejects. The anchors of =~ hold for the whole of RAW, line feeds included.
resolve_interval() {
    local ws=$' \t\n\v\f\r' re digits
    re="^[$ws]*([+-]?)([0123456789]+)[$ws]*\$"
    if [[ "$1" =~ $re && "${BASH_REMATCH[1]}" != "-" ]]; then
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
# callers match substrings only. The read has ended, killed if need be, probe_limit seconds
# after it started (hard_timeout), and is never started once the poll's deadline has passed. On
# failure LOG_PROBE_DETAIL tells a read Docker did not answer in time from one that failed.
broker_logs() {
    local limit rc=0
    if ! limit="$(probe_limit)"; then
        # Only poll sets a deadline, and its last attempt can start just as the deadline passes.
        # That attempt fails at once and keeps the POLL_DETAIL of the attempt before it.
        LOG_PROBE_DETAIL="${POLL_DETAIL:-broker-service logs probe not started: no time left before the poll deadline}"
        return 1
    fi
    LOG_PROBE_DETAIL=""
    # compose() cannot run under timeout(1), which needs a program, so its settings are repeated.
    hard_timeout "$limit" docker compose -p "$PROJECT" -f "$COMPOSE_FILE" \
        logs --no-color --no-log-prefix --since "$1" broker-service </dev/null 2>>"$RUN_DIR/compose.log" \
        | sed "s/$(printf '\033')\[[0-9;]*m//g" | tr -d '\r' || rc=$?
    case "$rc" in
        0) return 0 ;;
        124 | 137) LOG_PROBE_DETAIL="broker-service logs probe timed out after $limit s (Docker did not answer)" ;;
        *) LOG_PROBE_DETAIL="broker-service logs unreadable, exit $rc (see $RUN_DIR/compose.log)" ;;
    esac
    return 1
}

# probe_limit: the seconds a log read may take now, the time left to PROBE_DEADLINE inside a
# poll and LOG_PROBE_TIMEOUT_SECONDS outside one. Fails when the deadline has passed.
probe_limit() {
    local left
    if [[ -z "$PROBE_DEADLINE" ]]; then
        echo "$LOG_PROBE_TIMEOUT_SECONDS"
        return 0
    fi
    left=$((PROBE_DEADLINE - $(date -u +%s)))
    if [[ $left -le 0 ]]; then
        return 1
    fi
    echo "$left"
}

# read_window SINCE: the broker's cycle summary and trigger lines since SINCE, in log order,
# into $RUN_DIR/window.events as "C <outcome>" for a cycle line or "T <alert id> <revision>".
# The outcome is completed or failed as CYCLE_RE reads it, and unknown for a cycle line that
# does not render the whole summary, so a line whose outcome cannot be read never counts as
# completed.
read_window() {
    local line id
    broker_logs "$1" >"$RUN_DIR/window.log" || return 1
    : >"$RUN_DIR/window.events"
    while IFS= read -r line; do
        if [[ "$line" == *"$CYCLE_MARKER"* ]]; then
            if [[ "$line" =~ $CYCLE_RE ]]; then
                echo "C ${BASH_REMATCH[1]}" >>"$RUN_DIR/window.events"
            else
                echo "C unknown" >>"$RUN_DIR/window.events"
            fi
        elif [[ "$line" =~ $TRIGGER_RE ]]; then
            id="$(lower <<<"${BASH_REMATCH[1]}")"
            echo "T $id ${BASH_REMATCH[2]}" >>"$RUN_DIR/window.events"
        fi
    done < <(grep -F -e "$CYCLE_MARKER" -e "$TRIGGER_MARKER" "$RUN_DIR/window.log" || true)
}

# window_cycles: the cycle lines in the current window, whatever their outcome.
window_cycles() {
    grep -c '^C ' "$RUN_DIR/window.events" || true
}

# shellcheck disable=SC2329 # Invoked by trigger_logged and later_cycles_seen, poll commands.
# trigger_position ID REVISION: sets TRIGGER_INDEX, the event number of the trigger line of
# that alert arming in the current window, and TRIGGER_CYCLES, the cycle lines before it,
# whatever their outcome. Fails when the window holds no such line.
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
        POLL_DETAIL="$LOG_PROBE_DETAIL"
        return 1
    fi
    if trigger_position "$1" "$2"; then
        return 0
    fi
    POLL_DETAIL="no line [Alert [$1] triggered for account [...] ... revision [$2]] since $LOG9_SINCE"
    return 1
}

# shellcheck disable=SC2329 # Invoked through poll.
# later_cycles_seen: poll command; true once, in a fresh read of the step-9 window, a cycle line
# with outcome completed follows the last of the trigger lines step 9 found, listed in
# $RUN_DIR/trigger-lines, beyond the first cycle line after it, the triggering cycle's own
# summary. A failed cycle evaluates no alert and an unknown one may not have, so neither counts.
# Every read locates each trigger line by its alert id and revision, never by its place in an
# earlier read, and the attempt fails when one of them is no longer in the window.
later_cycles_seen() {
    local id revision kind outcome last=0 index=0 own=0 failed=0 unknown=0
    if ! read_window "$LOG9_SINCE"; then
        POLL_DETAIL="$LOG_PROBE_DETAIL"
        return 1
    fi
    if [[ ! -s "$RUN_DIR/trigger-lines" ]]; then
        POLL_DETAIL="no step-9 trigger line was recorded to count cycles from"
        return 1
    fi
    while read -r id revision; do
        if ! trigger_position "$id" "$revision"; then
            POLL_DETAIL="the step-9 trigger line of alert [$id] revision [$revision] is no longer in the log window since $LOG9_SINCE"
            return 1
        fi
        if [[ $TRIGGER_INDEX -gt $last ]]; then
            last=$TRIGGER_INDEX
        fi
    done <"$RUN_DIR/trigger-lines"
    while read -r kind outcome _; do
        index=$((index + 1))
        if [[ $index -le $last || "$kind" != "C" ]]; then
            continue
        fi
        if [[ $own -eq 0 ]]; then
            own=1
        elif [[ "$outcome" == "completed" ]]; then
            POLL_DETAIL=""
            return 0
        elif [[ "$outcome" == "failed" ]]; then
            failed=$((failed + 1))
        else
            unknown=$((unknown + 1))
        fi
    done <"$RUN_DIR/window.events"
    if [[ $own -eq 0 ]]; then
        POLL_DETAIL="no cycle line after the last trigger line; the triggering cycle's own summary and a completed follow-up cycle are needed"
    elif [[ $((failed + unknown)) -eq 0 ]]; then
        POLL_DETAIL="only the triggering cycle's own summary after the last trigger line; a completed follow-up cycle is needed"
    else
        POLL_DETAIL="no follow-up cycle after the last trigger line completed: $failed failed, $unknown without a rendered outcome; a completed one is needed"
    fi
    return 1
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

# alert_body ACCOUNT TYPE INSTRUMENT DIRECTION THRESHOLD: the create body. The four strings are
# JSON-encoded, whatever they hold, so none can change the body's shape. THRESHOLD follows as an
# unquoted token written in exactly as given: it never passes through a number type, and an
# invalid one reaches the broker unchanged.
alert_body() {
    local strings
    # Git Bash would rewrite a path-like argument, so the strings reach jq unchanged.
    strings="$(MSYS_NO_PATHCONV=1 jq -cn --arg accountId "$1" --arg type "$2" \
        --arg instrumentId "$3" --arg direction "$4" \
        '{accountId: $accountId, type: $type, instrumentId: $instrumentId, direction: $direction}' |
        tr -d '\r')" || return 1
    printf '%s,"threshold":%s}' "${strings%\}}" "$5"
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

# check_reserved_notifications_routes STEP: PATCH, with a valid body, and DELETE on
# /v1/alerts/notifications, where the notifications literal stands in an alert id's place.
# Routing answers both with its plain 404 and no Allow header before the feature gate runs, so
# the answer is the same whether the flag is on or off: never the gate's 403, nor the 405 with
# Allow: GET that the literal's GET route would draw.
check_reserved_notifications_routes() {
    local step="$1" method check
    for method in PATCH DELETE; do
        check="$step $method notifications path 404"
        if [[ "$method" == "PATCH" ]]; then
            http PATCH "$ALERTS_URL/notifications" '{"enabled":true}'
        else
            http DELETE "$ALERTS_URL/notifications"
        fi
        if grep -qi '^allow:' "$PRIVATE_DIR/headers"; then
            fail "$check" "$(status_text) with an Allow header; expected 404 with no route and no Allow header"
        else
            expect_error "$check" 404 no_route
        fi
    done
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
# It writes to this run's own evidence directory, which held no report when the run began, so a
# report found there later can only be this invocation's, and nothing is removed first.
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
    if [[ "$EVIDENCE_DIR" != "$RUN_DIR" ]]; then
        info "evidence dir $EVIDENCE_DIR"
    fi
    echo "SUMMARY $passed passed, $failed failed"
    exit 130
}

# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() {
    local rc=$? remaining problems="" switched
    trap - EXIT
    # A second interrupt abandons the remaining requests, but never leaves the passwords behind
    # and still ends the run with a cleanup verdict and the SUMMARY line.
    trap on_cleanup_signal INT TERM
    set +e
    remaining="$(remaining_owned)"
    if [[ "$remaining" -gt 0 ]]; then
        # DELETE answers 403 while the flag is off, so the flag is switched on to delete. Only a
        # 200 with this flag's JSON boolean true confirms it; otherwise the deletes still run,
        # each answer deciding its id, and the switch-on is a cleanup problem of its own.
        http GET "$F"
        if [[ "$HTTP_STATUS" == "200" && "$(flag_enabled "$HTTP_BODY")" == "false" ]]; then
            FLAG_TOUCHED=1
            http PUT "$F" '{"enabled": true}'
            switched="$(flag_enabled "$HTTP_BODY")"
            if [[ "$HTTP_STATUS" != "200" ]]; then
                problems="flag $FLAG_ID could not be switched on to delete $remaining owned alerts: $(status_text)"
            elif [[ "$switched" != "true" ]]; then
                problems="flag $FLAG_ID could not be switched on to delete $remaining owned alerts: answered [$switched]"
            else
                info "cleanup: flag $FLAG_ID switched on to delete $remaining owned alerts"
            fi
        fi
        delete_remaining
        info "cleanup: $((remaining - CLEANUP_LEFT)) of $remaining remaining owned alerts deleted or already absent"
        if [[ $CLEANUP_LEFT -gt 0 ]]; then
            problems="${problems:+$problems; }$CLEANUP_LEFT owned alerts left in place"
        fi
    fi
    if [[ $FLAG_TOUCHED -eq 1 && -n "$FLAG_INITIAL" ]]; then
        http PUT "$F" "{\"enabled\": $FLAG_INITIAL}"
        if [[ "$HTTP_STATUS" == "200" && "$(flag_enabled "$HTTP_BODY")" == "$FLAG_INITIAL" ]]; then
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
    if [[ "$EVIDENCE_DIR" != "$RUN_DIR" ]]; then
        info "evidence dir $EVIDENCE_DIR"
    fi
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

# startup_flag_default RAW: the flag's startup value for an ENABLE_PORTFOLIO_INSIGHTS of RAW, by
# feature-flag-service's getEnvBool rule. strconv.ParseBool's true spellings give true; its false
# spellings, an empty or unset value and anything unparsable give the shipped default, false.
startup_flag_default() {
    case "$1" in
        1 | t | T | TRUE | true | True) echo true ;;
        *) echo false ;;
    esac
}

step1_ready() {
    local running missing="" service modifiable enabled raw_default startup_default raw_interval
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
    enabled="$(flag_enabled "$HTTP_BODY")"
    if [[ "$enabled" != "true" && "$enabled" != "false" ]]; then
        abort "step 1 flag modifiable" "GET $FLAG_ID answered [$enabled]; expected id $FLAG_ID and a boolean enabled"
    fi
    # The body is one JSON object now. Only the JSON boolean true is modifiable: a string "true"
    # shows as its type.
    modifiable="$(jget '.isModifiable | if type == "boolean" then tostring else "a JSON \(type)" end' "$HTTP_BODY")"
    if [[ "$modifiable" != "true" ]]; then
        abort "step 1 flag modifiable" "isModifiable is [$modifiable]: a deployment with ENABLE_MODIFY=false cannot be toggled"
    fi
    FLAG_INITIAL="$enabled"
    pass "step 1 flag modifiable"

    # The run certifies a stack on the shipped defaults, so nothing writes the flag before both
    # the flag and feature-flag-service's startup setting show it starts disabled. The value is
    # read byte for byte, as the service's strconv.ParseBool reads it untrimmed: the x keeps a
    # trailing line feed, and printf %q prints a value with control characters on one line.
    if ! raw_default="$(container_env feature-flag-service ENABLE_PORTFOLIO_INSIGHTS && printf x)"; then
        abort "step 1 flag default disabled" "ENABLE_PORTFOLIO_INSIGHTS could not be read from the feature-flag-service container of project [$PROJECT]; the run needs the shipped default, disabled"
    fi
    raw_default="${raw_default%x}"
    startup_default="$(startup_flag_default "$raw_default")"
    if [[ "$FLAG_INITIAL" != "false" || "$startup_default" != "false" ]]; then
        abort "step 1 flag default disabled" "the flag reads enabled [$FLAG_INITIAL] and ENABLE_PORTFOLIO_INSIGHTS [${raw_default:+$(printf '%q' "$raw_default")}] gives startup default enabled [$startup_default]; the run needs the shipped default, disabled, on both"
    fi
    pass "step 1 flag default disabled"
    info "flag $FLAG_ID initially enabled=$FLAG_INITIAL; ENABLE_PORTFOLIO_INSIGHTS [${raw_default:+$(printf '%q' "$raw_default")}]"

    # The x keeps a trailing line feed of the value; printf %q prints a value with control
    # characters on one line, as $'...'.
    DIALECT="$(container_env db-adapter DB_TYPE && printf x)" || DIALECT=""
    DIALECT="${DIALECT%x}"
    if [[ "$DIALECT" != "mssql" && "$DIALECT" != "postgres" ]]; then
        abort "step 1 runtime facts" "db-adapter DB_TYPE is [${DIALECT:+$(printf '%q' "$DIALECT")}], expected mssql or postgres"
    fi
    raw_interval="$(container_env broker-service ALERT_EVALUATION_INTERVAL_SECONDS && printf x)" || raw_interval=""
    raw_interval="${raw_interval%x}"
    INTERVAL="$(resolve_interval "$raw_interval")"
    pass "step 1 runtime facts"
    info "db type $DIALECT; evaluation interval ${INTERVAL}s (ALERT_EVALUATION_INTERVAL_SECONDS [${raw_interval:+$(printf '%q' "$raw_interval")}])"
}

# ---------------------------------------------------------------------------------------------
# Step 2: flag off

step2_flag_off() {
    http GET "$F"
    # jq's == compares types too, so a string "false" is not false. A field that differs shows as
    # its JSON type, or as a boolean's value, never as the server's text.
    expect_json "step 2 flag reads disabled" 200 \
        'def seen($want): if . == $want or type == "boolean" then tostring else "a JSON \(type)" end;
         if .id == "portfolio-insights-enabled" and .enabled == false and .tag == "feature" then "ok"
         else "id [\(.id | seen("portfolio-insights-enabled"))] enabled [\(.enabled | seen(false))] tag [\(.tag | seen("feature"))], expected portfolio-insights-enabled, false and feature" end'

    http GET "$BASE_URL/feature-flag-service/v1/flags?tag=problem_pattern"
    expect_json "step 2 flag not listed as a problem pattern" 200 \
        'if (.results | type) != "array" then "no results array"
         elif any(.results[]; .id == "portfolio-insights-enabled") then "listed under tag problem_pattern"
         else "ok" end'

    check_forbidden_endpoints "step 2" "$(random_guid)" "$(random_guid)" "$(random_guid)"
    check_reserved_notifications_routes "step 2"
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
    local epoch body ids id results_type count amount_type n=0
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
    if [[ "$HTTP_STATUS" != "200" ]]; then
        abort "step 3 buy instrument 1" "the holder's instrument listing gave $(status_text), expected 200"
    fi
    results_type="$(jget '.results | type' "$HTTP_BODY")"
    if [[ "$results_type" != "array" ]]; then
        abort "step 3 buy instrument 1" "the holder's instrument listing has results of JSON type [${results_type:-unreadable}], expected an array; body [$(body_snippet)]"
    fi
    ids="$(jget '[.results[].id] | .[0:2] | join(" ")' "$HTTP_BODY" | lower)"
    # Both ids go into request bodies and run files, so each must be a distinct canonical id.
    if [[ ! "${ids%% *}" =~ $UUID_RE || ! "${ids#* }" =~ $UUID_RE || "${ids%% *}" == "${ids#* }" ]]; then
        abort "step 3 buy instrument 1" "the holder's instrument listing does not begin with two distinct canonical instrument ids"
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
        abort "step 3 holdings" "the holder's instrument listing gave $(status_text), expected 200"
    fi
    results_type="$(jget '.results | type' "$HTTP_BODY")"
    if [[ "$results_type" != "array" ]]; then
        abort "step 3 holdings" "the holder's instrument listing has results of JSON type [${results_type:-unreadable}], expected an array; body [$(body_snippet)]"
    fi
    # An amount is a decimal, so a JSON number. jq orders strings, arrays and objects above
    # every number, so its type is checked before its value.
    for id in $ids; do
        count="$(jcount "$id" "$HTTP_BODY")"
        if [[ "$count" != "1" ]]; then
            abort "step 3 holdings" "instrument [$id] is listed ${count:-an unreadable number of} times, expected once"
        fi
        amount_type="$(jitem "$id" "$HTTP_BODY" '.amount | type')"
        if [[ "$amount_type" != "number" ]]; then
            abort "step 3 holdings" "instrument [$id] shows an amount of JSON type [${amount_type:-unreadable}], expected a number"
        fi
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
    if [[ "$HTTP_STATUS" != "200" || "$(flag_enabled "$HTTP_BODY")" != "true" ]]; then
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

# "Portfolio insights for account [<id>] holdings [<n>] value [<decimal>] risk [<level>]
# duration [<n>] ms trace [<trace id>]", as PortfolioInsightsService renders it.
INSIGHTS_LINE_RE='Portfolio insights for account \[([^]]*)\] holdings \[([^]]*)\] value \[([^]]*)\] risk \[([^]]*)\] duration \[([^]]*)\] ms trace \[([^]]*)\]'

# shellcheck disable=SC2329 # Invoked through poll.
# insights_line_logged SINCE ACCOUNT HOLDINGS VALUE RISK: poll command; whether the broker logged,
# since SINCE, the rendered insights event of ACCOUNT with HOLDINGS holdings, a value equal to
# VALUE, risk RISK, a whole-millisecond duration and a W3C trace id. VALUE is the number as jq
# prints it (1E-8) and the line renders a C# decimal (1.50), so num_cmp compares the two exactly
# whatever their form. On a miss, POLL_DETAIL names every field the last line of ACCOUNT got wrong.
insights_line_logged() {
    local line holdings value risk duration trace order wrong detail=""
    if ! broker_logs "$1" >"$RUN_DIR/insights.log"; then
        POLL_DETAIL="$LOG_PROBE_DETAIL"
        return 1
    fi
    while IFS= read -r line; do
        if [[ ! "$line" =~ $INSIGHTS_LINE_RE ]]; then
            detail="the line for account [$2] does not render holdings, value, risk, duration and trace"
            continue
        fi
        holdings="${BASH_REMATCH[2]}"
        value="${BASH_REMATCH[3]}"
        risk="${BASH_REMATCH[4]}"
        duration="${BASH_REMATCH[5]}"
        trace="${BASH_REMATCH[6]}"
        wrong=""
        if [[ "$holdings" != "$3" ]]; then
            wrong="$wrong; holdings [$holdings], expected [$3]"
        fi
        if ! order="$(num_cmp "$value" "$4")" || [[ "$order" != "0" ]]; then
            wrong="$wrong; value [$value], expected [$4]"
        fi
        if [[ "$risk" != "$5" ]]; then
            wrong="$wrong; risk [$risk], expected [$5]"
        fi
        if [[ ! "$duration" =~ ^[0-9]+$ ]]; then
            wrong="$wrong; duration [$duration], expected whole milliseconds"
        fi
        if [[ ! "$trace" =~ ^[0-9a-f]{32}$ || "$trace" =~ ^0+$ ]]; then
            wrong="$wrong; trace [$trace], expected a W3C trace id of 32 lowercase hex digits, not all zero"
        fi
        if [[ -z "$wrong" ]]; then
            return 0
        fi
        detail="the line for account [$2] has${wrong#;}"
    done < <(grep -iF "Portfolio insights for account [$2]" "$RUN_DIR/insights.log" || true)
    POLL_DETAIL="${detail:-no broker-service line renders insights for account [$2]} (log window since $1)"
    return 1
}

step5_figures() {
    local j="$HOLDER_INSIGHTS" holdings total risk zero_total entry_jq
    # Prices are signed, so two holdings' values can net to a totalValue of exactly 0. The
    # calculator then makes every percent 0 and the allocation with the ordinally lowest
    # lowercase id the largest, whatever its value, so the risk is LOW. The response's own
    # totalValue, a JSON number equal to 0, selects those checks.
    # largestPosition is the very allocation entry the calculator selects, so it must equal
    # that entry in every field. same_entry($entry; $which) prints "ok" when it does, otherwise
    # which fields differ, with both values of a number, and never either whole object.
    entry_jq='def same_entry($entry; $which):
        . as $got
        | if $got == $entry then "ok"
          else [("instrumentId", "name", "quantity", "value", "percent") as $key
                | select(($got | has($key)) != ($entry | has($key)) or $got[$key] != $entry[$key])
                | if ($got[$key] | type) == "number" and ($entry[$key] | type) == "number"
                  then "\($key) \($got[$key]), expected \($entry[$key])"
                  else "\($key) differs" end]
              + (if ($got | del(.instrumentId, .name, .quantity, .value, .percent))
                    != ($entry | del(.instrumentId, .name, .quantity, .value, .percent))
                 then ["other fields differ"] else [] end)
            | "largestPosition differs from \($which): \(join("; "))" end;
    '
    zero_total="$(jget '.totalValue | if type == "number" and . == 0 then "yes" else "no" end' "$j")"
    jcheck "step 5 two allocations" \
        'if (.allocations | length) == 2 then "ok" else "\(.allocations | length) allocations, expected 2" end' "$j"
    if [[ "$zero_total" == "yes" ]]; then
        jcheck "step 5 percents are 0 at a zero total" \
            '[.allocations[].percent] as $percents
             | if all($percents[]; type == "number" and . == 0) then "ok"
               else "allocation percents \($percents), expected the number 0 each at a totalValue of 0" end' "$j"
    else
        jcheck "step 5 percents sum to 100" \
            '([.allocations[].percent] | add) as $sum
             | if $sum != null and (($sum - 100) | fabs) <= 1e-6 then "ok"
               else "allocation percents sum to \($sum)" end' "$j"
    fi
    jcheck "step 5 totalValue is the sum of the values" \
        '([.allocations[].value] | add) as $sum
         | if $sum != null and ((.totalValue - $sum) | fabs) <= 1e-6 then "ok"
           else "totalValue \(.totalValue), values sum to \($sum)" end' "$j"
    if [[ "$zero_total" == "yes" ]]; then
        jcheck "step 5 largest position" "$entry_jq"'
            ([.allocations[].instrumentId | ascii_downcase] | min) as $lowest
             | ([.allocations[]] | min_by(.instrumentId | ascii_downcase)) as $entry
             | if .largestPosition == null then "largestPosition is null"
               elif (.largestPosition.instrumentId | ascii_downcase) != $lowest then
                 "largestPosition [\(.largestPosition.instrumentId)], expected [\($lowest)], the lowest id, as totalValue is 0"
               else .largestPosition | same_entry($entry; "the lowest-id allocation, as totalValue is 0") end' "$j"
        jcheck "step 5 risk level" \
            'if .riskLevel == "LOW" then "ok"
             else "riskLevel [\(.riskLevel)], a totalValue of 0 gives LOW" end' "$j"
    else
        jcheck "step 5 largest position" "$entry_jq"'
            ([.allocations[].value] | max) as $max
             | ([.allocations[] | select(.value == $max) | .instrumentId | ascii_downcase] | min) as $lowest
             | ([.allocations[] | select(.value == $max)] | min_by(.instrumentId | ascii_downcase)) as $entry
             | if .largestPosition == null then "largestPosition is null"
               elif .largestPosition.value != $max then
                 "largestPosition value \(.largestPosition.value), highest value \($max)"
               elif (.largestPosition.instrumentId | ascii_downcase) != $lowest then
                 "largestPosition [\(.largestPosition.instrumentId)], expected [\($lowest)], the lowest id among the highest values"
               else .largestPosition | same_entry($entry; "the highest-value allocation with the lowest id") end' "$j"
        jcheck "step 5 risk level" \
            '.largestPosition.percent as $share
             | (if $share == null then null elif $share < 25 then "LOW"
                elif $share <= 50 then "MEDIUM" else "HIGH" end) as $expected
             | if $expected == null then "largestPosition has no percent"
               elif .riskLevel == $expected then "ok"
               else "riskLevel [\(.riskLevel)], a largest share of \($share) % gives \($expected)" end' "$j"
    fi
    # The line must carry this response's own figures, so they are read from it first.
    holdings="$(jget '.allocations | if type == "array" then length else empty end' "$j")"
    total="$(jget '.totalValue | if type == "number" then . else empty end' "$j")"
    risk="$(jget '.riskLevel | select(. == "LOW" or . == "MEDIUM" or . == "HIGH")' "$j")"
    if [[ -z "$holdings" || -z "$risk" ]] || ! num_split "$total"; then
        fail "step 5 insights log line" "the response lacks an allocations array, a numeric totalValue or a LOW, MEDIUM or HIGH riskLevel to match the line against"
    elif poll "step 5 insights log line" "$LOG_LINE_TIMEOUT_SECONDS" "$LOG_STEP_SECONDS" \
        insights_line_logged "$LOG4_SINCE" "$HOLDER_ID" "$holdings" "$total" "$risk"; then
        pass "step 5 insights log line"
    fi
}

# ---------------------------------------------------------------------------------------------
# Step 6: the empty account

# jq definitions for the property checks of steps 6 and 8. want(KEY; OK; EXPECTED) yields nothing
# when the object has KEY and its value passes OK, otherwise why not: has() keeps an absent
# property from passing as null. verdict(REASONS) prints "ok" or every reason, as jcheck needs.
WANT_JQ='def show: tojson | if length > 60 then .[0:60] + "..." else . end;
    def want($key; ok; $expected):
        if has($key) | not then "\($key) missing, expected \($expected)"
        elif .[$key] | ok then empty
        else "\($key) [\(.[$key] | show)], expected \($expected)" end;
    def verdict(reasons):
        if type != "object" then "the body is a JSON \(type), expected an object"
        else [reasons] | if length == 0 then "ok" else join("; ") end end;
'

step6_empty() {
    http GET "$INSIGHTS_URL/$EMPTY_ID"
    expect_json "step 6 empty account insights" 200 "$WANT_JQ"'verdict(
        (("totalValue", "totalInvested", "unrealizedPnl", "unrealizedPnlPercent") as $key
            | want($key; type == "number" and . == 0; "the number 0")),
        want("allocations"; . == []; "[]"),
        (("largestPosition", "riskLevel") as $key | want($key; . == null; "null")))'
}

# ---------------------------------------------------------------------------------------------
# Step 7: every documented 400 and 404

# response_kind: the kind of the last response's body, never the body itself.
#   error_response  the broker's ErrorResponse {"statusCode": n, "message": "..."}, n the status
#   problem         the automatic [ApiController] validation response: an object with a numeric
#                   status equal to the HTTP status and a non-empty errors object
#   empty, json or text otherwise, and "... with another statusCode" or "... with another status"
#   when an ErrorResponse or a validation problem names a code other than the HTTP status.
response_kind() {
    local kind=""
    kind="$(jq -r -s --arg status "$HTTP_STATUS" '
        if length == 0 then "empty"
        elif length > 1 or (.[0] | type) != "object" then "json"
        else .[0]
          | if (.statusCode | type) == "number" and (.message | type) == "string" then
              (if (.statusCode | tostring) == $status then "error_response"
               else "error_response with another statusCode" end)
            elif (.status | type) == "number" and (.errors | type) == "object"
                and (.errors | length) > 0 then
              (if (.status | tostring) == $status then "problem"
               else "problem with another status" end)
            else "json" end
        end' <"$PRIVATE_DIR/body" 2>/dev/null | tr -d '\r')" || kind=""
    echo "${kind:-text}"
}

# expect_error CHECK STATUS KIND: PASS when the last response has STATUS and a body of KIND:
#   error_response  a rule violation, through BrokerExceptionFilter, as application/json
#   problem         a body or query that cannot bind, as application/problem+json
#   no_route        a non-GUID path segment, which matches no route: neither of the two above
# Each media type must be exactly the one named, with or without parameters. The failure reason
# names the status, the body's kind and the media type, never the body.
expect_error() {
    local check="$1" status="$2" want="$3" kind ok=0 expected media
    kind="$(response_kind)"
    media="$(media_type)"
    case "$want" in
        error_response)
            expected="an ErrorResponse with statusCode $status as application/json"
            if [[ "$kind" == "error_response" && "$media" == "application/json" ]]; then
                ok=1
            fi
            ;;
        problem)
            expected="a validation problem with status $status as application/problem+json"
            if [[ "$kind" == "problem" && "$media" == "application/problem+json" ]]; then
                ok=1
            fi
            ;;
        no_route)
            expected="no route, so neither an ErrorResponse nor a validation problem"
            if [[ "$kind" != error_response* && "$kind" != problem* ]]; then
                ok=1
            fi
            ;;
        *)
            fail "$check" "unknown expected response kind [$want]"
            return 0
            ;;
    esac
    if [[ "$HTTP_STATUS" == "$status" && $ok -eq 1 ]]; then
        pass "$check"
    else
        fail "$check" "$(status_text), body kind [$kind], content type [${media:-none}]; expected $status: $expected"
    fi
}

# post_error CHECK STATUS KIND BODY: POST BODY, sent verbatim, to /v1/alerts, then expect_error.
# A 201 is owned at once, and an interrupt during the POST waits for that as in create_alert, so
# a request the broker wrongly accepts still leaves nothing behind.
post_error() {
    IN_CREATE=1
    http POST "$ALERTS_URL" "$4"
    own_if_created
    IN_CREATE=0
    if [[ -n "$PENDING_EXIT" ]]; then
        exit "$PENDING_EXIT"
    fi
    expect_error "$1" "$2" "$3"
}

# One request per 400 and 404 case, each asserting its status and the response kind that
# answers it. Every other input of a request is valid, so only the tested one is wrong; creates
# start from the holder, its held instrument H1, TARGET_PRICE, ABOVE and threshold 1.
step7_errors() {
    local nh unknown valid temp reason
    unknown="$(random_guid)"
    valid="$(alert_body "$HOLDER_ID" TARGET_PRICE "$H1" ABOVE 1)"

    http GET "$B/v1/instrument?accountId=$EMPTY_ID"
    nh="$(jget 'first(.results[]? | select(.amount == 0) | .id) // empty' "$HTTP_BODY" | lower)"

    post_error "step 7 POST type target_price 400" 400 error_response \
        "$(alert_body "$HOLDER_ID" target_price "$H1" ABOVE 1)"
    post_error "step 7 POST type missing 400" 400 error_response \
        "$(printf '{"accountId":"%s","instrumentId":"%s","direction":"ABOVE","threshold":1}' "$HOLDER_ID" "$H1")"
    post_error "step 7 POST direction UP 400" 400 error_response \
        "$(alert_body "$HOLDER_ID" TARGET_PRICE "$H1" UP 1)"
    post_error "step 7 POST direction missing 400" 400 error_response \
        "$(printf '{"accountId":"%s","type":"TARGET_PRICE","instrumentId":"%s","threshold":1}' "$HOLDER_ID" "$H1")"
    post_error "step 7 POST quoted threshold \"abc\" 400" 400 problem \
        "$(alert_body "$HOLDER_ID" TARGET_PRICE "$H1" ABOVE '"abc"')"
    post_error "step 7 POST quoted threshold \"12\" 400" 400 problem \
        "$(alert_body "$HOLDER_ID" TARGET_PRICE "$H1" ABOVE '"12"')"
    # The exact-token rule: no exponent, at most 10 integer and 8 fractional digits, nothing
    # rounded into the domain.
    post_error "step 7 POST threshold exponent 1e5 400" 400 problem \
        "$(alert_body "$HOLDER_ID" TARGET_PRICE "$H1" ABOVE 1e5)"
    post_error "step 7 POST threshold 10000000000 400" 400 problem \
        "$(alert_body "$HOLDER_ID" TARGET_PRICE "$H1" ABOVE 10000000000)"
    post_error "step 7 POST threshold 0.000000010000000000000000000001 400" 400 problem \
        "$(alert_body "$HOLDER_ID" TARGET_PRICE "$H1" ABOVE 0.000000010000000000000000000001)"
    post_error "step 7 POST threshold 0.000000001 400" 400 problem \
        "$(alert_body "$HOLDER_ID" TARGET_PRICE "$H1" ABOVE 0.000000001)"
    # The valid body without its closing brace.
    post_error "step 7 POST malformed JSON 400" 400 problem "${valid%\}}"
    post_error "step 7 POST TARGET_PRICE threshold 0 400" 400 error_response \
        "$(alert_body "$HOLDER_ID" TARGET_PRICE "$H1" ABOVE 0)"
    post_error "step 7 POST TARGET_PRICE threshold -1 400" 400 error_response \
        "$(alert_body "$HOLDER_ID" TARGET_PRICE "$H1" ABOVE -1)"
    post_error "step 7 POST accountId missing 400" 400 error_response \
        "$(printf '{"type":"TARGET_PRICE","instrumentId":"%s","direction":"ABOVE","threshold":1}' "$H1")"
    post_error "step 7 POST instrumentId missing 400" 400 error_response \
        "$(printf '{"accountId":"%s","type":"TARGET_PRICE","direction":"ABOVE","threshold":1}' "$HOLDER_ID")"
    post_error "step 7 POST threshold missing 400" 400 error_response \
        "$(printf '{"accountId":"%s","type":"TARGET_PRICE","instrumentId":"%s","direction":"ABOVE"}' "$HOLDER_ID" "$H1")"
    if [[ "$nh" =~ $UUID_RE ]]; then
        post_error "step 7 POST PROFIT_LOSS not held 400" 400 error_response \
            "$(alert_body "$EMPTY_ID" PROFIT_LOSS "$nh" ABOVE 1)"
    else
        fail "step 7 POST PROFIT_LOSS not held 400" "the empty account's listing ($(status_text)) shows no instrument with amount 0"
    fi

    post_error "step 7 POST unknown account 404" 404 error_response \
        "$(alert_body "$unknown" TARGET_PRICE "$H1" ABOVE 1)"
    post_error "step 7 POST unknown instrument 404" 404 error_response \
        "$(alert_body "$HOLDER_ID" TARGET_PRICE "$unknown" ABOVE 1)"
    http GET "$INSIGHTS_URL/$unknown"
    expect_error "step 7 GET insights unknown account 404" 404 error_response
    http GET "$INSIGHTS_URL/not-a-guid"
    expect_error "step 7 GET insights non-GUID account 404" 404 no_route
    http GET "$ALERTS_URL?accountId=$unknown"
    expect_error "step 7 GET alerts unknown account 404" 404 error_response
    http GET "$ALERTS_URL"
    expect_error "step 7 GET alerts accountId missing 400" 400 problem
    http GET "$ALERTS_URL?accountId=not-a-guid"
    expect_error "step 7 GET alerts non-GUID accountId 400" 400 problem
    http GET "$ALERTS_URL/notifications?accountId=$unknown"
    expect_error "step 7 GET notifications unknown account 404" 404 error_response
    http GET "$ALERTS_URL/notifications"
    expect_error "step 7 GET notifications accountId missing 400" 400 problem
    http GET "$ALERTS_URL/notifications?accountId=not-a-guid"
    expect_error "step 7 GET notifications non-GUID accountId 400" 400 problem
    http GET "$ALERTS_URL/notifications?accountId=$HOLDER_ID&unacknowledged=maybe"
    expect_error "step 7 GET notifications unacknowledged maybe 400" 400 problem
    http PATCH "$ALERTS_URL/$unknown" '{"enabled":true}'
    expect_error "step 7 PATCH unknown alert 404" 404 error_response
    http PATCH "$ALERTS_URL/not-a-guid" '{"enabled":true}'
    expect_error "step 7 PATCH non-GUID alert 404" 404 no_route
    http DELETE "$ALERTS_URL/$unknown"
    expect_error "step 7 DELETE unknown alert 404" 404 error_response
    http DELETE "$ALERTS_URL/not-a-guid"
    expect_error "step 7 DELETE non-GUID alert 404" 404 no_route
    http POST "$ALERTS_URL/$unknown/acknowledge"
    expect_error "step 7 POST acknowledge unknown alert 404" 404 error_response
    http POST "$ALERTS_URL/not-a-guid/acknowledge"
    expect_error "step 7 POST acknowledge non-GUID alert 404" 404 no_route
    check_reserved_notifications_routes "step 7"

    # Each PATCH body case targets a real alert, so only the body is wrong: a missing or null
    # enabled breaks the service's rule, while malformed JSON and a quoted enabled cannot bind.
    if ! create_alert "$HOLDER_ID" TARGET_PRICE "$H1" ABOVE "$MAX_THRESHOLD"; then
        reason="creating the temporary alert gave $(status_text), body kind [$(response_kind)]; expected 201 with an id"
        fail "step 7 PATCH {} 400" "$reason"
        fail "step 7 PATCH enabled null 400" "$reason"
        fail "step 7 PATCH malformed JSON 400" "$reason"
        fail "step 7 PATCH quoted enabled \"true\" 400" "$reason"
        fail "step 7 DELETE temporary alert 204" "not attempted: $reason"
        return 0
    fi
    temp="$CREATED_ID"
    http PATCH "$ALERTS_URL/$temp" '{}'
    expect_error "step 7 PATCH {} 400" 400 error_response
    http PATCH "$ALERTS_URL/$temp" '{"enabled":null}'
    expect_error "step 7 PATCH enabled null 400" 400 error_response
    # The valid body without its closing brace.
    http PATCH "$ALERTS_URL/$temp" '{"enabled":true'
    expect_error "step 7 PATCH malformed JSON 400" 400 problem
    # A JSON string, not a boolean.
    http PATCH "$ALERTS_URL/$temp" '{"enabled":"true"}'
    expect_error "step 7 PATCH quoted enabled \"true\" 400" 400 problem
    delete_alert "$temp"
    if [[ "$HTTP_STATUS" == "204" ]]; then
        pass "step 7 DELETE temporary alert 204"
    else
        fail "step 7 DELETE temporary alert 204" "$(status_text) for the temporary alert [$temp], expected 204"
    fi
}

# ---------------------------------------------------------------------------------------------
# Step 8: CRUD for both types

# alert(ENABLED; REVISION; KEPT): the AlertDTO check. Every property must be present with its
# type, enabled ENABLED, armingRevision REVISION and the alert not acknowledged. triggeredAt and
# triggerValue must both be null, as a create or a re-arm answers. With KEPT true, a trigger of
# the current arming passes as well, since a disable keeps it: an ISO-8601 triggeredAt with a
# numeric triggerValue, never one without the other.
# alert_as(WANT; ENABLED; REVISION; KEPT): alert(ENABLED; REVISION; KEPT) for the alert a request
# named. Each of id, accountId, instrumentId, type and direction that the object WANT carries
# must hold that value, not only a value of its kind; GUIDs match in any letter case. jq
# compares numbers as doubles, so the exact threshold is alert_verdict's to compare.
ALERT_JQ="$WANT_JQ"'def guid: type == "string"
        and test("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$");
    def stamp: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}");
    def trigger($kept):
        if $kept and (.triggeredAt != null or .triggerValue != null) then
            want("triggeredAt"; stamp; "an ISO-8601 string in a kept trigger"),
            want("triggerValue"; type == "number"; "a number in a kept trigger")
        else
            (("triggeredAt", "triggerValue") as $key
                | want($key; . == null; if $kept then "null or a kept trigger" else "null" end))
        end;
    def alert_as($want; $enabled; $revision; $kept): verdict(
        (("id", "accountId", "instrumentId") as $key
            | if $want | has($key) then
                want($key; guid and ascii_downcase == ($want[$key] | ascii_downcase); $want[$key])
              else want($key; guid; "a GUID string") end),
        (if $want | has("type") then want("type"; . == $want.type; $want.type)
         else want("type"; . == "TARGET_PRICE" or . == "PROFIT_LOSS"; "TARGET_PRICE or PROFIT_LOSS")
         end),
        (if $want | has("direction") then want("direction"; . == $want.direction; $want.direction)
         else want("direction"; . == "ABOVE" or . == "BELOW"; "ABOVE or BELOW") end),
        want("threshold"; type == "number"; "a number"),
        want("enabled"; . == $enabled; $enabled),
        want("armingRevision"; . == $revision; $revision),
        trigger($kept),
        want("acknowledged"; . == false; false),
        want("createdAt"; stamp; "an ISO-8601 string"));
    def alert($enabled; $revision; $kept): alert_as({}; $enabled; $revision; $kept);
'
# The checks of a 201 and of the disable and re-arm answers, $want being the alert the request
# named. A trigger value can exceed the domain-maximum threshold, so the evaluator may trigger
# revision 1 before the disable, which keeps that trigger. The re-arm clears it.
CREATED_FILTER="$ALERT_JQ"'alert_as($want; true; 1; false)'
DISABLED_FILTER="$ALERT_JQ"'alert_as($want; false; 1; true)'
REARMED_FILTER="$ALERT_JQ"'alert_as($want; true; 2; false)'

# alert_want ID ACCOUNT INSTRUMENT TYPE DIRECTION: the WANT object of alert_as for the alert a
# request named, every value encoded by jq. An empty ID is left out, since a create's id is new.
alert_want() {
    MSYS_NO_PATHCONV=1 jq -cn --arg id "$1" --arg accountId "$2" --arg instrumentId "$3" \
        --arg type "$4" --arg direction "$5" \
        '{accountId: $accountId, instrumentId: $instrumentId, type: $type, direction: $direction}
         + (if $id == "" then {} else {id: $id} end)' | tr -d '\r'
}

# alert_verdict FILTER WANT THRESHOLD: FILTER, an ALERT_JQ program ending in an alert_as($want;
# ...) call, run on the last response body with $want bound to WANT, and the body's threshold
# held to THRESHOLD, the token the create sent. jq compares numbers as doubles, which would pass
# a rounded threshold, so the threshold is read as jq prints it, its literal kept, and num_cmp
# compares it exactly; a threshold that is no number is alert_as's to report. Prints "ok" or
# every reason, each naming a field, the value it holds and the value expected, or "unreadable
# JSON" when the body is not exactly one JSON document, which jget requires.
alert_verdict() {
    local verdict threshold order reason
    verdict="$(jget "$1" "$HTTP_BODY" --argjson want "$2")"
    if [[ -z "$verdict" ]]; then
        echo "unreadable JSON [$(body_snippet)]"
        return 0
    fi
    threshold="$(jget 'select(type == "object") | .threshold | numbers' "$HTTP_BODY")"
    if [[ -n "$threshold" ]]; then
        if ! order="$(num_cmp "$threshold" "$3")" || [[ "$order" != "0" ]]; then
            if [[ ${#threshold} -gt 60 ]]; then
                threshold="${threshold:0:60}..."
            fi
            reason="threshold [$threshold], expected $3"
            if [[ "$verdict" == "ok" ]]; then
                verdict="$reason"
            else
                verdict="$verdict; $reason"
            fi
        fi
    fi
    echo "$verdict"
}

# expect_alert CHECK STATUS FILTER WANT THRESHOLD: the last response has STATUS and
# alert_verdict FILTER WANT THRESHOLD prints "ok".
expect_alert() {
    local verdict
    if [[ "$HTTP_STATUS" != "$2" ]]; then
        fail "$1" "$(status_text), expected $2; body [$(body_snippet)]"
        return 0
    fi
    verdict="$(alert_verdict "$3" "$4" "$5")"
    if [[ "$verdict" == "ok" ]]; then
        pass "$1"
    else
        fail "$1" "$verdict"
    fi
}

# create_checked CHECK TYPE: creates TYPE ABOVE the domain maximum on H1 and checks that the 201
# is that alert as created. Leaves the id in CREATED_ID, empty when the create failed.
create_checked() {
    local reason="" verdict
    if ! create_alert "$HOLDER_ID" "$2" "$H1" ABOVE "$MAX_THRESHOLD"; then
        fail "$1" "$CREATE_ERROR"
        return 0
    fi
    verdict="$(alert_verdict "$CREATED_FILTER" "$(alert_want "" "$HOLDER_ID" "$H1" "$2" ABOVE)" \
        "$MAX_THRESHOLD")"
    if [[ "$verdict" != "ok" ]]; then
        reason="$verdict"
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

# listing(F), the check of each step-8 listing: F run on the listed ids, lowercased, once the
# body is the {"results": [...]} envelope and every entry is an alert object whose id is a GUID
# string; otherwise why not. A malformed entry is named by its position from 1, never its value.
LISTING_JQ="$ALERT_JQ"'def listing(f):
    verdict(want("results"; type == "array"; "an array")) as $envelope
    | if $envelope != "ok" then $envelope
      else [.results | range(length) as $i
              | select(.[$i] | type == "object" and (.id | guid) | not) | $i + 1 | tostring]
          as $bad
        | ($bad | length) as $n
        | if $n == 0 then .results | map(.id | ascii_downcase) | f
          elif $n == 1 then
              "results entry \($bad[0]) of \(.results | length) is not an alert with a GUID id"
          else "results entries \($bad[0:5] | join(", "))"
              + (if $n > 5 then " and \($n - 5) more" else "" end)
              + " of \(.results | length) are not alerts with a GUID id" end
      end;
'

step8_crud() {
    local tp="" pl="" id type want
    create_checked "step 8 create TARGET_PRICE" TARGET_PRICE
    tp="$CREATED_ID"
    create_checked "step 8 create PROFIT_LOSS" PROFIT_LOSS
    pl="$CREATED_ID"

    # Each listing must be the {"results": [...]} envelope of alerts with GUID ids before any id
    # is looked for in it.
    http GET "$ALERTS_URL?accountId=$HOLDER_ID"
    if [[ -z "$tp" || -z "$pl" ]]; then
        fail "step 8 list newest first" "both alerts are needed and at least one create failed"
    else
        expect_json "step 8 list newest first" 200 "$LISTING_JQ
            listing(index(\"$pl\") as \$p | index(\"$tp\") as \$t
                | if \$p == null or \$t == null then \"listed ids \(.), expected both $pl and $tp\"
                  elif \$p < \$t then \"ok\"
                  else \"PROFIT_LOSS $pl is listed after TARGET_PRICE $tp\" end)"
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
        # Each PATCH answers the snapshot of this alert's update, so it must be this alert.
        want="$(alert_want "$id" "$HOLDER_ID" "$H1" "$type" ABOVE)"
        http PATCH "$ALERTS_URL/$id" '{"enabled":false}'
        expect_alert "step 8 $type disable" 200 "$DISABLED_FILTER" "$want" "$MAX_THRESHOLD"
        http PATCH "$ALERTS_URL/$id" '{"enabled":true}'
        expect_alert "step 8 $type re-arm" 200 "$REARMED_FILTER" "$want" "$MAX_THRESHOLD"
        delete_alert "$id"
        expect_status "step 8 $type delete" 204
        http GET "$ALERTS_URL?accountId=$HOLDER_ID"
        expect_json "step 8 $type absent after delete" 200 "$LISTING_JQ
            listing(map(select(. == \"$id\")) | length
                | if . == 0 then \"ok\" else \"alert $id listed \(.) times, expected 0\" end)"
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

# pick_close_instrument LISTING: the first held instrument of the instrument listing LISTING whose
# close suits the step-9 pairs. Sets CHOSEN_ID, lower case, and CHOSEN_UNITS, its close in units
# of 1e-8, from MIN_CLOSE_UNITS to MAX_CLOSE_UNITS; fails, both empty, when none qualifies.
pick_close_instrument() {
    local quoted close id units
    CHOSEN_ID=""
    CHOSEN_UNITS=""
    # Only a quantity and a close that are JSON numbers count. Each id arrives JSON-encoded, so
    # no listed text can forge a line or a field, and only a canonical id is chosen: it goes
    # into request bodies and run files.
    while read -r quoted close; do
        id=""
        if [[ "$quoted" =~ ^\"(.*)\"$ ]]; then
            id="${BASH_REMATCH[1]}"
        fi
        if [[ "$id" =~ $UUID_RE ]] && units="$(num_to_units "$close")" &&
            [[ $units -ge $MIN_CLOSE_UNITS && $units -le $MAX_CLOSE_UNITS ]]; then
            CHOSEN_ID="$id"
            CHOSEN_UNITS="$units"
            return 0
        fi
    done < <(jget '.results[]?
        | select((.amount | type) == "number" and .amount >= 1 and (.price.close | type) == "number")
        | "\(.id | tojson) \(.price.close)"' "$1" | lower)
    return 1
}

# trigger_value_verdict DIRECTION THRESHOLD TYPE VALUE: the check of a notification's
# triggerValue, of JSON type TYPE and VALUE as jq prints it, against its alert's DIRECTION and
# THRESHOLD. Prints "ok" when it is a number inside the trigger-value domain and on the
# DIRECTION side of THRESHOLD or equal to it (rounding), otherwise the reason it is not.
trigger_value_verdict() {
    local order
    if [[ "$3" != "number" ]]; then
        echo "triggerValue has JSON type ${3:-unknown}, expected number"
    elif ! num_split "$4"; then
        echo "triggerValue is a JSON number in a form this script cannot read"
    elif [[ $NUM_INTEGERS -gt $TRIGGER_INTEGER_DIGITS || $NUM_FRACTIONS -gt $TRIGGER_FRACTION_DIGITS ]]; then
        echo "triggerValue has $NUM_INTEGERS integer and $NUM_FRACTIONS fractional digits, outside the trigger-value domain of at most $TRIGGER_INTEGER_DIGITS and $TRIGGER_FRACTION_DIGITS"
    elif ! order="$(num_cmp "$4" "$2")"; then
        echo "threshold [$2] of this run is not a readable decimal"
    elif [[ ("$1" == "ABOVE" && $order -ge 0) || ("$1" == "BELOW" && $order -le 0) ]]; then
        echo "ok"
    else
        echo "triggerValue $4 is not on the $1 side of threshold $2"
    fi
}

step9_trigger() {
    local id chosen="" c="" t9 spec pair type direction threshold errors="" fields
    local revision triggered_at value_type value verdict cycles

    http GET "$B/v1/instrument?accountId=$HOLDER_ID"
    if [[ "$HTTP_STATUS" == "200" ]] && pick_close_instrument "$HTTP_BODY"; then
        chosen="$CHOSEN_ID"
        c="$CHOSEN_UNITS"
    fi
    if [[ -z "$chosen" ]]; then
        fail "step 9 instrument with a usable close" "no held instrument with a canonical id has a close from 0.00000002 to 9999999999.99999998 (listing $(status_text))"
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
        info "log window baseline at $t9: $LOG_PROBE_DETAIL"
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
        # triggerValue is the literal jq prints for the unmodified number, never arithmetic.
        fields="$(jitem "$id" "$NOTIFICATIONS" \
            '"\(.armingRevision) \(.triggeredAt) \(.triggerValue | type) \(.triggerValue | tojson)"')"
        read -r revision triggered_at value_type value <<<"$fields"
        info "triggered $pair $direction $id revision $revision"
        echo "$id $revision $triggered_at $pair $direction" >>"$RUN_DIR/triggered"

        verdict="$(trigger_value_verdict "$direction" "$threshold" "$value_type" "$value")"
        if [[ "$verdict" == "ok" ]]; then
            pass "step 9 $pair $direction trigger value"
        else
            fail "step 9 $pair $direction trigger value" "$verdict"
        fi

        if poll "step 9 $pair $direction trigger log line" "$LOG_LINE_TIMEOUT_SECONDS" \
            "$LOG_STEP_SECONDS" trigger_logged "$id" "$revision"; then
            cycles=$((TRIGGER_CYCLES - BASE9))
            # Step 10 finds this line again by its id and revision on each of its own reads,
            # since a place in this read can point at another line once the log is reread.
            echo "$id $revision" >>"$RUN_DIR/trigger-lines"
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
    if [[ ! -s "$RUN_DIR/trigger-lines" ]]; then
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
    local id pair type direction threshold revision list missing="" alerts ack
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

    # The check's live shutdown turns the flag off and on again; step 12 needs it on. Switching it
    # on is a check of its own, confirmed only by a 200 with this flag's JSON boolean true.
    http GET "$F"
    if [[ "$HTTP_STATUS" != "200" || "$(flag_enabled "$HTTP_BODY")" != "true" ]]; then
        info "flag $FLAG_ID is not on after the browser check ($(status_text)); switching it on for step 12"
        FLAG_TOUCHED=1
        http PUT "$F" '{"enabled": true}'
        ack="$(flag_enabled "$HTTP_BODY")"
        if [[ "$HTTP_STATUS" != "200" ]]; then
            fail "step 11 flag on for step 12" "PUT {\"enabled\": true} gave $(status_text)"
        elif [[ "$ack" != "true" ]]; then
            fail "step 11 flag on for step 12" "PUT {\"enabled\": true} answered [$ack]; expected id $FLAG_ID and enabled true"
        else
            pass "step 11 flag on for step 12"
        fi
    fi
}

# ---------------------------------------------------------------------------------------------
# Step 12: acknowledging an untriggered alert changes nothing

step12_untriggered_ack() {
    local id before="" after unready="" changed evidence fields ack_id ack_revision
    # A listing's verdict on alert $id, from jq -S -c -r -s over its body: the listed row, keys
    # sorted and compact, or why the listing cannot serve, a text that never starts with "{".
    # Each field of the object $want must be present in the row with exactly that JSON value:
    # the string "false" is not false, and an absent triggeredAt is not null. A reason names
    # fields, JSON kinds and numbers, never another value it was sent.
    local listed_jq='
        def kind: if type == "boolean" or type == "null" or type == "number" then tojson
            elif type == "object" or type == "array" then "an \(type)" else "a \(type)" end;
        if length != 1 or (.[0] | type) != "object" then "the listing is not one JSON object"
        elif (.[0].results | type) != "array" then "the listing has no results array"
        else [.[0].results[] | select(type == "object" and (.id | type) == "string"
                and (.id | ascii_downcase) == $id)]
            | if length == 0 then "the listing does not list the alert"
              else .[0] as $row
                | [$want | to_entries[] | .key as $name | .value as $value
                    | if ($row | has($name) | not) then "\($name) is absent, expected \($value | tojson)"
                      elif $row[$name] != $value then
                          "\($name) is \($row[$name] | kind), expected \($value | tojson)"
                      else empty end]
                | if length == 0 then $row else join("; ") end
              end
        end'
    # The state a disabled alert that never triggered shows (AlertDTO).
    local untriggered='{"enabled":false,"triggeredAt":null,"triggerValue":null,"acknowledged":false}'
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
            unready="PATCH {\"enabled\":false} gave $(status_text)"
            fail "step 12 disabled untriggered alert" "$unready; body [$(body_snippet)]"
        else
            http GET "$ALERTS_URL?accountId=$HOLDER_ID"
            if [[ "$HTTP_STATUS" != "200" ]]; then
                unready="the listing gave $(status_text), expected 200"
            else
                before="$(jq -S -c -r -s --arg id "$id" --argjson want "$untriggered" "$listed_jq" \
                    2>/dev/null <<<"$HTTP_BODY" | tr -d '\r' || true)"
                if [[ "$before" != "{"* ]]; then
                    unready="${before:-the listing is not JSON}"
                    before=""
                fi
            fi
            if [[ -z "$unready" ]]; then
                pass "step 12 disabled untriggered alert"
            else
                fail "step 12 disabled untriggered alert" "$unready"
            fi
        fi
        http POST "$ALERTS_URL/$id/acknowledge"
        if [[ "$HTTP_STATUS" != "204" ]]; then
            fail "step 12 acknowledge leaves an untriggered alert unchanged" "$(status_text), expected 204; body [$(body_snippet)]"
        elif [[ -n "$unready" ]]; then
            # Only a row shown disabled and untriggered can prove that acknowledging changed nothing.
            fail "step 12 acknowledge leaves an untriggered alert unchanged" "no disabled, untriggered row to compare: $unready"
        else
            http GET "$ALERTS_URL?accountId=$HOLDER_ID"
            if [[ "$HTTP_STATUS" != "200" ]]; then
                fail "step 12 acknowledge leaves an untriggered alert unchanged" "the listing after acknowledging gave $(status_text), expected 200"
            else
                after="$(jq -S -c -r -s --arg id "$id" --argjson want '{}' "$listed_jq" \
                    2>/dev/null <<<"$HTTP_BODY" | tr -d '\r' || true)"
                if [[ "$after" != "{"* ]]; then
                    fail "step 12 acknowledge leaves an untriggered alert unchanged" "after acknowledging, ${after:-the listing is not JSON}"
                elif [[ "$after" == "$before" ]]; then
                    pass "step 12 acknowledge leaves an untriggered alert unchanged"
                else
                    # Named: the AlertDTO fields that differ; any other key is only counted. Both
                    # rows reach jq on stdin, never as arguments, so no process list shows them.
                    changed="$(printf '%s\n%s\n' "$before" "$after" | jq -n -r '
                        input as $before | input as $after
                        | ["id", "accountId", "type", "instrumentId", "direction", "threshold",
                            "enabled", "armingRevision", "triggeredAt", "triggerValue",
                            "acknowledged", "createdAt"] as $known
                        | [[$before, $after | keys[]] | unique[] | . as $k
                            | select(($before | has($k)) != ($after | has($k))
                                or $before[$k] != $after[$k])] as $diff
                        | [$diff[] | select(IN($known[]))] as $named
                        | (($diff | length) - ($named | length)) as $other
                        | if ($diff | length) == 0 then "a number is written differently"
                          else ($named + (if $other == 0 then []
                                else ["\($other) other key\(if $other == 1 then "" else "s" end)"] end))
                            | join(", ") end' 2>/dev/null | tr -d '\r' || true)"
                    fail "step 12 acknowledge leaves an untriggered alert unchanged" "acknowledging changed the row: ${changed:-its fields differ}"
                fi
            fi
        fi
    fi

    # Only this run's report counts: the flag-on mode, this run's fresh holder, and an
    # acknowledgement of one of the pair alerts in the fixture this run handed the check. A
    # reason names the fact that does not match, never a value the report holds.
    evidence="$EVIDENCE_DIR/portfolio-insights-page-check-flag-on.json"
    if [[ ! -f "$evidence" ]]; then
        fail "step 12 browser acknowledgement persisted" "evidence file $evidence is missing"
        return 0
    fi
    fields="$(jq -r -s --rawfile pairs "$RUN_DIR/pairs" --arg holderUser "$HOLDER_USER" \
        --arg holderId "$HOLDER_ID" '
        ($pairs | [splits("\r?\n") | select(length > 0) | split(" ")[0] | ascii_downcase]) as $ids
        | if length != 1 or (.[0] | type) != "object" then "it is not one JSON object"
          else .[0]
            | if .mode != "flag-on" then "its mode is not flag-on"
              elif (.holder | type) != "object" or (.holder.accountId | type) != "string"
                  or (.holder.accountId | ascii_downcase) != ($holderId | ascii_downcase) then
                  "its holder.accountId is not the holder of this run"
              elif .holder.username != $holderUser then
                  "its holder.username is not the holder of this run"
              elif (.acknowledged | type) != "object" then
                  "its acknowledged is not an object: the check acknowledged no alert"
              elif (.acknowledged.id | type) != "string"
                  or (.acknowledged.id | ascii_downcase | IN($ids[]) | not) then
                  "its acknowledged.id is not one of the pair alerts of this run"
              elif (.acknowledged.armingRevision | type) != "number"
                  or (.acknowledged.armingRevision | . != floor or . < 1 or . > 2147483647) then
                  "its acknowledged.armingRevision is not an integer from 1 to 2147483647"
              else "ok \(.acknowledged.id | ascii_downcase) \(.acknowledged.armingRevision | floor)"
              end
          end' "$evidence" 2>/dev/null | tr -d '\r' || true)"
    read -r _ ack_id ack_revision <<<"$fields"
    if [[ "$fields" != "ok "* || ! "${ack_id:-}" =~ $UUID_RE || ! "${ack_revision:-}" =~ ^[1-9][0-9]*$ ]]; then
        fail "step 12 browser acknowledgement persisted" "evidence file $evidence: ${fields:-it is not JSON}"
        return 0
    fi
    http GET "$ALERTS_URL?accountId=$HOLDER_ID"
    if [[ "$HTTP_STATUS" != "200" ]]; then
        fail "step 12 browser acknowledgement persisted" "the listing gave $(status_text), expected 200"
        return 0
    fi
    fields="$(jq -S -c -r -s --arg id "$ack_id" \
        --argjson want "{\"acknowledged\":true,\"armingRevision\":$ack_revision}" "$listed_jq" \
        2>/dev/null <<<"$HTTP_BODY" | tr -d '\r' || true)"
    if [[ "$fields" == "{"* ]]; then
        pass "step 12 browser acknowledgement persisted"
    else
        fail "step 12 browser acknowledgement persisted" "alert [$ack_id]: ${fields:-the listing is not JSON}"
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
    if [[ "$HTTP_STATUS" == "200" && "$(flag_enabled "$HTTP_BODY")" == "false" ]]; then
        pass "step 13 disable flag"
    else
        fail "step 13 disable flag" "PUT {\"enabled\": false} gave $(status_text); body [$(body_snippet)]"
    fi
    check_forbidden_endpoints "step 13" "$HOLDER_ID" "$(random_guid)" "$(random_guid)"
}

# ---------------------------------------------------------------------------------------------
# Main

main() {
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
}

# Sourcing the file defines its functions without running them. The options, tool checks and
# run directory above still apply, so a test sources it with valid options and its own TMPDIR.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
