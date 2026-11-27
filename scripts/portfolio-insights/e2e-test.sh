#!/usr/bin/env bash
# Unit tests for the helpers of scripts/portfolio-insights/e2e.sh, run without a stack:
#   - option parsing, in a child bash, the configuration a valid set of options gives, and the
#     new evidence directory each run makes;
#   - exact decimals (dec_to_units, num_to_units, units_to_dec) and the interval rule;
#   - broker log windows: the log read, which stays in the private directory, cycle lines and
#     their outcomes, trigger lines, alert ids and arming revisions; the trigger lines step 9
#     records and step 10's completed follow-up cycle after them;
#   - alert ownership: created ids, the journal of uncertain creates, the create guard,
#     interrupts, deletion and its limits, and an inventory that cannot be computed;
#   - the fixture the browser check reads, the browser check's exit code and output, and an
#     earlier run's report it leaves alone;
#   - step 12: the listings and untriggered state its acknowledge is compared on, the
#     diagnostic of a changed row, which keeps both rows off every jq command line, and the
#     provenance and persistence of the browser's acknowledgement;
#   - http's transport errors, the exact 403 oracle, the jq verdict and lookup helpers, and
#     random GUIDs;
#   - the EXIT cleanup's flag switching, restore and failure paths, its reconciliation of
#     uncertain creates and of an unusable inventory, and bounded polling.
# scripts/portfolio-insights/e2e-credentials-test.sh covers the passwords, the private directory
# that keeps them and the raw responses, the description of a body and their removal on exit;
# e2e-checks-test.sh the exact number comparisons and the step checks; harness-test.sh the
# origin and interval helpers and the bounds on every Docker call.
# It replaces each boundary the helpers reach, then sources e2e.sh, which runs main, and so its
# traps and steps, only when executed: sourced, it parses the options, checks its tools, makes
# its run and private directories and defines its functions, and runs nothing else. curl,
# node, date and sleep are bash functions: curl answers from a per-case response queue and
# records every request, node stands in for the browser check, and date and sleep run a fake
# clock. docker is a script first on PATH, because e2e.sh runs its log reads under timeout(1):
# it records each log read and serves a canned broker log. One step-12 case also puts first on
# PATH a jq that records its arguments. No request leaves the host, no call reaches a Docker
# engine and no time passes.
#
# Usage: scripts/portfolio-insights/e2e-test.sh
#   --help  Show this help and exit
#
# Needs bash, jq, coreutils, grep and sed only: no docker, node, network or running stack.
# Prints one PASS or FAIL line per case and a final SUMMARY line. Exits 0 when every case
# passes, 1 when any case fails, and 2 on a usage error or a missing tool. Every temporary file
# lives in one private directory, removed on exit.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
E2E="$TEST_DIR/e2e.sh"
# A reserved name (RFC 2606) that never resolves, so even a regression sends nothing anywhere.
TEST_BASE_URL="http://e2e-test.invalid:8080"
TEST_ACCOUNT="0f1e2d3c-4b5a-4968-8776-655443322110"
ID_A="aaaaaaaa-0000-4000-8000-00000000000a"
ID_B="bbbbbbbb-0000-4000-8000-00000000000b"
ID_UPPER="ABCDEF01-2345-4678-9ABC-DEF012345678"
ID_LOWER="abcdef01-2345-4678-9abc-def012345678"
CONNECT_ERROR="Failed to connect to e2e-test.invalid port 8080"
ESC=$'\033'

test_usage() {
    cat <<'EOF'
Usage: scripts/portfolio-insights/e2e-test.sh
  --help  Show this help and exit
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            test_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            test_usage >&2
            exit 2
            ;;
    esac
done

if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required on PATH." >&2
    exit 2
fi
if [[ ! -f "$E2E" ]]; then
    echo "The script under test is missing: $E2E" >&2
    exit 2
fi

if ! TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/e2e-test.XXXXXX")"; then
    echo "Could not create a temporary directory under ${TMPDIR:-/tmp}." >&2
    exit 2
fi
trap 'rm -rf "$TEST_TMP"' EXIT
trap 'exit 130' INT TERM
# The fake docker below goes on PATH, so the directory is used in the shell's own form, which
# has no drive colon.
TEST_TMP="$(cd "$TEST_TMP" && pwd)"
# e2e.sh creates its run directory under TMPDIR when it is sourced.
export TMPDIR="$TEST_TMP"

tests_passed=0
tests_failed=0
reasons=()
case_seq=0
CASE_DIR=""
BROKER_LOGS_RC=0
# The fake docker, a process of its own, reads both.
export CASE_DIR BROKER_LOGS_RC
FAKE_NOW=1700000000
SLEEP_OVERRUN=0
NODE_OUTPUT=""
NODE_RC=0
NODE_REPORT=""

# ---------------------------------------------------------------------------------------------
# Reporting. e2e.sh owns pass, fail and their counters, so the test's own have other names.

report_pass() {
    tests_passed=$((tests_passed + 1))
    echo "PASS $1"
}

report_fail() {
    tests_failed=$((tests_failed + 1))
    echo "FAIL $1: $2"
}

# conclude CASE: one PASS or FAIL line for CASE from the reasons its rows recorded.
conclude() {
    local joined
    if [[ ${#reasons[@]} -eq 0 ]]; then
        report_pass "$1"
    else
        joined="$(printf '%s; ' "${reasons[@]}")"
        report_fail "$1" "${joined%; }"
    fi
    reasons=()
}

# row_is ROW ACTUAL EXPECTED: records a reason when ACTUAL is not EXPECTED.
row_is() {
    if [[ "$2" != "$3" ]]; then
        reasons+=("$1: got [$2], expected [$3]")
    fi
}

# expect_outputs FUNCTION INPUT EXPECTED...: FUNCTION succeeds on each INPUT and prints EXPECTED.
expect_outputs() {
    local fn="$1" out rc
    shift
    while [[ $# -ge 2 ]]; do
        rc=0
        out="$("$fn" "$1")" || rc=$?
        if [[ $rc -ne 0 || "$out" != "$2" ]]; then
            reasons+=("$fn [$1]: status $rc, output [$out], expected [$2]")
        fi
        shift 2
    done
}

# expect_rejected FUNCTION INPUT...: FUNCTION fails on each INPUT and prints nothing.
expect_rejected() {
    local fn="$1" input out rc
    shift
    for input in "$@"; do
        rc=0
        out="$("$fn" "$input")" || rc=$?
        if [[ $rc -eq 0 || -n "$out" ]]; then
            reasons+=("$fn [$input]: status $rc, output [$out], expected a failure")
        fi
    done
}

# file_text FILE: the file's lines without their carriage returns (Windows jq writes CRLF),
# joined by newlines. Builtins only: every fork costs on Git Bash.
file_text() {
    local -a lines
    local IFS=$'\n'
    mapfile -t lines <"$1"
    lines=("${lines[@]%$'\r'}")
    printf '%s' "${lines[*]}"
}

# first_line FILE: the first line of FILE.
first_line() {
    local line=""
    IFS= read -r line <"$1" || true
    echo "$line"
}

# verdicts FILE: the PASS and FAIL lines of FILE, in order.
verdicts() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "PASS "* || "$line" == "FAIL "* ]]; then
            echo "$line"
        fi
    done <"$1"
}

# has_line FILE LINE: whether FILE holds LINE exactly.
has_line() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$2" ]]; then
            return 0
        fi
    done <"$1"
    return 1
}

# last_line FILE: the last line of FILE.
last_line() {
    local line last=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        last="$line"
    done <"$1"
    echo "$last"
}

# ---------------------------------------------------------------------------------------------
# Boundaries. Each is a function, so command -v finds it when e2e.sh checks for its tools,
# except docker, which timeout(1) has to find on PATH.

# new_run: a fresh case directory with an empty e2e.sh run directory and private directory,
# response queue, request log and broker log, and the state the helpers start from. Each case
# has a private directory of its own: http keeps every response there, and cleanup removes it.
new_run() {
    case_seq=$((case_seq + 1))
    CASE_DIR="$TEST_TMP/case-$case_seq"
    RUN_DIR="$CASE_DIR/run"
    PRIVATE_DIR="$CASE_DIR/private"
    mkdir -p "$RUN_DIR" "$PRIVATE_DIR"
    : >"$RUN_DIR/owned"
    : >"$RUN_DIR/deleted"
    : >"$RUN_DIR/pairs"
    : >"$RUN_DIR/triggered"
    : >"$RUN_DIR/uncertain-creates"
    : >"$RUN_DIR/trigger-lines"
    : >"$CASE_DIR/responses"
    : >"$CASE_DIR/requests"
    : >"$CASE_DIR/broker.log"
    : >"$CASE_DIR/docker.calls"
    : >"$CASE_DIR/sleeps"
    FIXTURE="$PRIVATE_DIR/fixture.json"
    PRIVATE_LEFT=""
    HOLDER_PASSWORD=""
    EMPTY_PASSWORD=""
    EVIDENCE_DIR="$RUN_DIR"
    BROKER_LOGS_RC=0
    FAKE_NOW=1700000000
    HTTP_STATUS=""
    HTTP_CTYPE=""
    HTTP_BODY=""
    HTTP_ERROR=""
    POLL_DETAIL=""
    CREATED_ID=""
    CREATE_ERROR=""
    IN_CREATE=0
    PENDING_EXIT=""
    UNJOURNALED_CREATES=0
    HOLDER_ID=""
    EMPTY_ID=""
}

# respond STATUS CONTENT_TYPE BODY: queues the answer to the next request. BODY is printf %b
# text, so \n stands for a newline. STATUS 000 makes curl fail with BODY as its message.
respond() {
    printf '%s\037%s\037%s\n' "$1" "$2" "$3" >>"$CASE_DIR/responses"
}

# curl ARGS...: the arguments e2e.sh's http passes. Records "METHOD URL[ BODY]" in the request
# log, then answers with the queued response of the same number: the body into the -o file, a
# header block into the -D file and "STATUS CONTENT_TYPE" on stdout, as -w prints them.
curl() {
    local method="GET" body_file="" header_file="" url="" data=0 sent="" status ctype body
    local -a queue requests
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -X)
                method="$2"
                shift 2
                ;;
            -o)
                body_file="$2"
                shift 2
                ;;
            -D)
                header_file="$2"
                shift 2
                ;;
            --data-binary)
                data=1
                shift 2
                ;;
            --max-time | -w | -H) shift 2 ;;
            -*) shift ;;
            *)
                url="$1"
                shift
                ;;
        esac
    done
    if [[ $data -eq 1 ]]; then
        IFS= read -r -d '' sent || true
    fi
    printf '%s %s%s\n' "$method" "$url" "${sent:+ $sent}" >>"$CASE_DIR/requests"
    mapfile -t requests <"$CASE_DIR/requests"
    mapfile -t queue <"$CASE_DIR/responses"
    if [[ ${#requests[@]} -gt ${#queue[@]} ]]; then
        echo "curl: (7) e2e-test: no response queued for request ${#requests[@]}: $method $url" >&2
        return 7
    fi
    IFS=$'\037' read -r status ctype body <<<"${queue[${#requests[@]} - 1]}"
    if [[ "$status" == "000" ]]; then
        echo "curl: (7) $body" >&2
        return 7
    fi
    printf '%b' "$body" >"$body_file"
    printf 'HTTP/1.1 %s\r\n' "$status" >"$header_file"
    if [[ -n "$ctype" ]]; then
        printf 'Content-Type: %s\r\n' "$ctype" >>"$header_file"
    fi
    printf '\r\n' >>"$header_file"
    printf '%s %s' "$status" "$ctype"
}

# docker ARGS...: a script first on PATH rather than a function, because e2e.sh reads the broker
# log through hard_timeout, which runs docker under timeout(1), and timeout(1) finds its program
# on PATH. compose version succeeds; compose logs records its arguments in $CASE_DIR/docker.calls
# and serves the case's broker log, or fails with BROKER_LOGS_RC when that is not 0. Anything
# else is a call no helper under test makes. No call reaches a Docker engine.
mkdir "$TEST_TMP/bin"
cat >"$TEST_TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" compose version "*) exit 0 ;;
    *" logs "*)
        printf '%s\n' "$*" >>"$CASE_DIR/docker.calls"
        if [[ $BROKER_LOGS_RC -ne 0 ]]; then
            echo "e2e-test: broker-service logs unavailable" >&2
            exit "$BROKER_LOGS_RC"
        fi
        cat "$CASE_DIR/broker.log"
        ;;
    *)
        echo "e2e-test: unexpected docker call: $*" >&2
        exit 1
        ;;
esac
EOF
chmod +x "$TEST_TMP/bin/docker"
export PATH="$TEST_TMP/bin:$PATH"

# node ARGS...: the browser check. Records its directory and arguments, prints NODE_OUTPUT
# (printf %b text), writes NODE_REPORT, when set, as the report of its --mode in its
# --evidence-dir, and exits with NODE_RC.
node() {
    local mode="" dir=""
    printf '%s\n%s\n' "$PWD" "$*" >"$CASE_DIR/node-call"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)
                mode="$2"
                shift 2
                ;;
            --evidence-dir)
                dir="$2"
                shift 2
                ;;
            *) shift ;;
        esac
    done
    if [[ -n "$NODE_REPORT" ]]; then
        printf '%s\n' "$NODE_REPORT" >"$dir/portfolio-insights-page-check-$mode.json"
    fi
    printf '%b' "$NODE_OUTPUT"
    return "$NODE_RC"
}

# date ARGS...: the fake clock for date -u +%s; any other format goes to the real date.
date() {
    if [[ "$*" == "-u +%s" ]]; then
        echo "$FAKE_NOW"
        return 0
    fi
    command date "$@"
}

# sleep SECONDS: advances the fake clock by SECONDS, and by SLEEP_OVERRUN more for a sleep that
# ends late, and records the step; no time passes.
sleep() {
    echo "$1" >>"$CASE_DIR/sleeps"
    FAKE_NOW=$((FAKE_NOW + $1 + SLEEP_OVERRUN))
}

# broker_log EVENT...: writes the broker log docker serves, one console-logger line per EVENT,
# coloured and CRLF-terminated as docker compose logs prints them: "C OUTCOME" is a cycle
# summary rendering OUTCOME, C one that completed, "T ID REVISION" a trigger line, and any
# other text an unrelated line with that message.
broker_log() {
    local event message id revision outcome
    : >"$CASE_DIR/broker.log"
    for event in "$@"; do
        case "$event" in
            C | "C "*)
                read -r _ outcome <<<"$event"
                message="Alert evaluation cycle finished: alerts [4] triggered [0] failed [0]"
                message="$message skipped [0] outcome [${outcome:-completed}] duration [7] ms"
                ;;
            "T "*)
                read -r _ id revision <<<"$event"
                message="Alert [$id] triggered for account [$TEST_ACCOUNT] type [TARGET_PRICE]"
                message="$message direction [ABOVE] threshold [1.5] value [2] revision [$revision]"
                ;;
            *) message="$event" ;;
        esac
        printf '%s[2026-11-25 10:00:00 | Information]%s %s        | AlertEvaluationService\r\n' \
            "${ESC}[32m" "${ESC}[39m" "$message" >>"$CASE_DIR/broker.log"
    done
}

# run_e2e_child ARGS...: runs e2e.sh directly in a child bash; sets CHILD_STATUS, and leaves its
# output in $CASE_DIR/child.out and $CASE_DIR/child.err.
run_e2e_child() {
    CHILD_STATUS=0
    "$BASH" "$E2E" "$@" >"$CASE_DIR/child.out" 2>"$CASE_DIR/child.err" </dev/null || CHILD_STATUS=$?
}

# run_cleanup STATUS: runs cleanup as the EXIT trap of a subshell that exits with STATUS, as
# e2e.sh ends. Its output goes to $CASE_DIR/out and its exit status to CLEANUP_STATUS.
run_cleanup() {
    CLEANUP_STATUS=0
    (
        trap cleanup EXIT
        exit "$1"
    ) >"$CASE_DIR/out" 2>&1 || CLEANUP_STATUS=$?
}

# ---------------------------------------------------------------------------------------------
# Load e2e.sh. Sourced, it parses the options, checks its tools, makes its run and private
# directories and defines its functions; main, which sets the EXIT trap and runs the steps, runs
# only when e2e.sh is executed. Every assignment e2e.sh makes at its top level is global, so
# sourcing it from a function leaves the same state as sourcing it here.

# load_e2e [OPTION...]: sources e2e.sh with the test's options, then OPTION....
load_e2e() {
    # shellcheck source-path=SCRIPTDIR source=e2e.sh
    source "$E2E" --project e2e-unit-test --compose-file compose.dev.yaml \
        --base-url "$TEST_BASE_URL/" "$@"
}

cd "$TEST_REPO_ROOT"
load_e2e
SOURCED_RUN_DIR="$RUN_DIR"
SOURCED_PRIVATE_DIR="$PRIVATE_DIR"
SOURCED_FIXTURE="$FIXTURE"
SOURCED_EVIDENCE_DIR="$EVIDENCE_DIR"
trap -p EXIT >"$TEST_TMP/exit-trap"

# ---------------------------------------------------------------------------------------------
# Options

test_options_help_exitsZeroWithUsage() {
    local args line
    # Help is honoured as soon as it is parsed, so a row after --project needs no other option.
    local -a rows=("-h" "--help" "--project e2e-unit-test -h")
    local -a lines=(
        "  -h, --help           Show this help and exit"
        "Each run creates two directories under \$TMPDIR (default: /tmp): the run directory"
        "  scripts/portfolio-insights/e2e.sh --project pi-dev-postgres --base-url http://localhost \\"
        "      --compose-file compose.dev.yaml"
    )
    new_run
    for args in "${rows[@]}"; do
        # shellcheck disable=SC2086 # The row's arguments are split on purpose.
        run_e2e_child $args
        row_is "[$args] status" "$CHILD_STATUS" "0"
        row_is "[$args] first line" "$(first_line "$CASE_DIR/child.out")" \
            "Usage: scripts/portfolio-insights/e2e.sh --project NAME [--base-url URL]"
        for line in "${lines[@]}"; do
            if ! has_line "$CASE_DIR/child.out" "$line"; then
                reasons+=("[$args] stdout lacks [$line]")
            fi
        done
        row_is "[$args] stderr" "$(file_text "$CASE_DIR/child.err")" ""
    done
    conclude "options_help_exitsZeroWithUsage"
}

test_options_invalid_exitTwoWithUsageError() {
    local row name message args stderr
    local project="--project e2e-unit-test" missing="e2e-test-missing.yaml"
    local origin="Option --base-url needs an http:// or https:// origin"
    # Every row that parses past --base-url names the unresolvable origin, so a regression that
    # let a row run the steps could reach nothing.
    local -a rows=(
        "no --project|Option --project is required.|"
        "unknown option|Unknown option: --bogus|$project --bogus"
        "value missing at the end|Option --project requires a value.|--project"
        "value is an option|Option --base-url requires a value.|--base-url $project"
        "base URL with a path|$origin|$project --base-url $TEST_BASE_URL/app"
        "base URL without a scheme|$origin|$project --base-url e2e-test.invalid"
        "compose file missing|Compose file not found: $missing|$project --base-url $TEST_BASE_URL --compose-file $missing"
    )
    new_run
    for row in "${rows[@]}"; do
        IFS='|' read -r name message args <<<"$row"
        # shellcheck disable=SC2086 # The row's arguments are split on purpose.
        run_e2e_child $args
        if [[ $CHILD_STATUS -ne 2 ]] || ! grep -qF -- "$message" "$CASE_DIR/child.err"; then
            stderr="$(file_text "$CASE_DIR/child.err")"
            reasons+=("$name: status $CHILD_STATUS, stderr [$stderr], expected 2 and [$message]")
        fi
    done
    message="Option --project requires a value."
    run_e2e_child --project ""
    if [[ $CHILD_STATUS -ne 2 ]] || ! grep -qF -- "$message" "$CASE_DIR/child.err"; then
        reasons+=("empty value: status $CHILD_STATUS, expected 2 and [$message]")
    fi
    conclude "options_invalid_exitTwoWithUsageError"
}

test_options_sourced_setRunConfiguration() {
    new_run
    row_is "base url without the trailing slash" "$BASE_URL" "$TEST_BASE_URL"
    row_is "flag url" "$F" "$TEST_BASE_URL/feature-flag-service/v1/flags/portfolio-insights-enabled"
    row_is "alerts url" "$ALERTS_URL" "$TEST_BASE_URL/broker-service/v1/alerts"
    row_is "project and compose file" "$PROJECT $COMPOSE_FILE" "e2e-unit-test compose.dev.yaml"
    row_is "evidence dir defaults to the run dir" "$SOURCED_EVIDENCE_DIR" "$SOURCED_RUN_DIR"
    if [[ "$SOURCED_RUN_DIR" != "$TEST_TMP"/pi-e2e.* || ! -f "$SOURCED_RUN_DIR/owned" ||
        -s "$SOURCED_RUN_DIR/owned" ]]; then
        reasons+=("run dir [$SOURCED_RUN_DIR] is not a fresh pi-e2e.* directory under $TEST_TMP")
    fi
    if [[ "$SOURCED_PRIVATE_DIR" != "$TEST_TMP"/pi-e2e-private.* ||
        ! -d "$SOURCED_PRIVATE_DIR" ]]; then
        reasons+=("private dir [$SOURCED_PRIVATE_DIR] is not a pi-e2e-private.* dir under TMPDIR")
    fi
    row_is "fixture in the private dir" "$SOURCED_FIXTURE" "$SOURCED_PRIVATE_DIR/fixture.json"
    if grep -q cleanup "$TEST_TMP/exit-trap"; then
        reasons+=("the EXIT trap is [$(cat "$TEST_TMP/exit-trap")]: sourcing ran main")
    fi
    conclude "options_sourced_setRunConfiguration"
}

# A caller that turned Git Bash path conversion off would leave curl and node unable to open the
# /c/... paths e2e.sh hands them. The child stands in for the tools e2e.sh checks for, sources it
# with valid options and its own TMPDIR, and prints both settings as e2e.sh leaves them.
test_options_pathConversionOffInCaller_settingsUnset() {
    new_run
    mkdir -p "$CASE_DIR/tmp"
    CHILD_STATUS=0
    # shellcheck disable=SC2016 # Expanded by the child bash.
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' TMPDIR="$CASE_DIR/tmp" "$BASH" -c '
        curl() { :; }
        node() { :; }
        source "$1" --project e2e-unit-test --compose-file compose.dev.yaml --base-url "$2"
        printf "%s %s" "${MSYS_NO_PATHCONV-unset}" "${MSYS2_ARG_CONV_EXCL-unset}"' \
        e2e-test-child "$E2E" "$TEST_BASE_URL" >"$CASE_DIR/child.out" 2>"$CASE_DIR/child.err" \
        </dev/null || CHILD_STATUS=$?
    row_is "status and settings" "$CHILD_STATUS|$(file_text "$CASE_DIR/child.out")" "0|unset unset"
    conclude "options_pathConversionOffInCaller_settingsUnset"
}

# source_e2e_in_case REFUSED [OPTION...]: sources e2e.sh as load_e2e does, with the compose file
# by its absolute path and then OPTION..., in a subshell that runs from $CASE_DIR with TMPDIR at
# $CASE_DIR/tmp; there mktemp fails for a template that holds REFUSED, unless it is empty. Sets
# SOURCE_STATUS, and SOURCE_RUN_DIR and SOURCE_EVIDENCE_DIR to the directories the sourcing set,
# both empty when it exited. Its stderr goes to $CASE_DIR/source.err.
source_e2e_in_case() {
    local refused="$1" out
    local -a dirs
    shift
    mkdir -p "$CASE_DIR/tmp"
    SOURCE_STATUS=0
    out="$(
        exec 2>"$CASE_DIR/source.err"
        cd "$CASE_DIR"
        TMPDIR="$CASE_DIR/tmp"
        if [[ -n "$refused" ]]; then
            # shellcheck disable=SC2329 # Invoked by the sourced e2e.sh.
            mktemp() {
                if [[ "$*" == *"$refused"* ]]; then
                    return 1
                fi
                command mktemp "$@"
            }
        fi
        load_e2e --compose-file "$TEST_REPO_ROOT/compose.dev.yaml" "$@"
        printf '%s\n%s\n' "$RUN_DIR" "$EVIDENCE_DIR"
    )" || SOURCE_STATUS=$?
    mapfile -t dirs <<<"$out"
    SOURCE_RUN_DIR="${dirs[0]:-}"
    SOURCE_EVIDENCE_DIR="${dirs[1]:-}"
}

# evidence_dir_state RUN EVIDENCE PARENT: "the run dir" when EVIDENCE is RUN, "a new empty dir in
# the parent" when it is an empty pi-e2e-evidence.XXXXXX directory in PARENT, else [EVIDENCE].
evidence_dir_state() {
    if [[ "$2" == "$1" ]]; then
        echo "the run dir"
    elif [[ "${2%/*}" == "$3" && "${2##*/}" == pi-e2e-evidence.?????? && -d "$2" &&
        -z "$(ls -A "$2")" ]]; then
        echo "a new empty dir in the parent"
    else
        echo "[$2]"
    fi
}

test_options_evidenceDir_newDirectoryPerRun() {
    local row name given refused expected parent report first message
    local -a args
    local earlier='{"mode":"flag-on","holder":{"username":"pi-e2e-1600000000-holder"}}'
    local new="a new empty dir in the parent"
    # Each row sources e2e.sh twice, as two runs with the same options, unless the first exits.
    # Its parent directory, $CASE_DIR/evidence, already holds an earlier run's flag-on report.
    # name|--evidence-dir ("" for none, @CASE@ the case dir)|template mktemp refuses|evidence
    # dir of each run ("" when the run exits)
    local -a rows=(
        "no --evidence-dir|||the run dir"
        "parent holding an earlier report|@CASE@/evidence||$new"
        "parent not yet created|@CASE@/evidence/new||$new"
        "parent relative to the current dir|evidence||$new"
        "evidence dir cannot be created|@CASE@/evidence|pi-e2e-evidence.|"
    )
    for row in "${rows[@]}"; do
        IFS='|' read -r name given refused expected <<<"$row"
        new_run
        mkdir -p "$CASE_DIR/evidence"
        report="$CASE_DIR/evidence/portfolio-insights-page-check-flag-on.json"
        printf '%s\n' "$earlier" >"$report"
        given="${given//@CASE@/$CASE_DIR}"
        parent="$given"
        args=()
        if [[ -n "$given" ]]; then
            args=(--evidence-dir "$given")
            if [[ "$given" != /* ]]; then
                parent="$CASE_DIR/$given"
            fi
        fi
        source_e2e_in_case "$refused" "${args[@]}"
        if [[ -z "$expected" ]]; then
            row_is "$name: status" "$SOURCE_STATUS" "2"
            message="Could not create the evidence directory: $given/pi-e2e-evidence.XXXXXX"
            if ! grep -qF -- "$message" "$CASE_DIR/source.err"; then
                reasons+=("$name: stderr [$(file_text "$CASE_DIR/source.err")], expected [$message]")
            fi
            row_is "$name: left in TMPDIR" "$(ls -A "$CASE_DIR/tmp")" ""
            row_is "$name: parent entries" "$(ls -A "$CASE_DIR/evidence")" \
                "portfolio-insights-page-check-flag-on.json"
        else
            row_is "$name: first run" \
                "$SOURCE_STATUS $(evidence_dir_state "$SOURCE_RUN_DIR" "$SOURCE_EVIDENCE_DIR" "$parent")" \
                "0 $expected"
            first="$SOURCE_EVIDENCE_DIR"
            source_e2e_in_case "$refused" "${args[@]}"
            row_is "$name: second run" \
                "$SOURCE_STATUS $(evidence_dir_state "$SOURCE_RUN_DIR" "$SOURCE_EVIDENCE_DIR" "$parent")" \
                "0 $expected"
            if [[ -z "$first" || "$SOURCE_EVIDENCE_DIR" == "$first" ]]; then
                reasons+=("$name: both runs got the evidence dir [$first]")
            fi
        fi
        row_is "$name: earlier report" "$(report_state "$report")" "$earlier"
    done
    conclude "options_evidenceDir_newDirectoryPerRun"
}

# ---------------------------------------------------------------------------------------------
# Exact decimals and the interval rule

test_decToUnits_plainTokens_matchUnits() {
    expect_outputs dec_to_units \
        "1" "100000000" \
        "0" "0" \
        "0.00000001" "1" \
        "1.5" "150000000" \
        "1.50000000" "150000000" \
        "0.000000014" "1" \
        "0.000000015" "2" \
        "0.0000000149999" "1" \
        "-0.000000015" "-2" \
        "-0.000000005" "-1" \
        "-1.25" "-125000000" \
        "-0" "0" \
        "-0.000000004" "0" \
        "007.5" "750000000" \
        "0000000000001" "100000000" \
        "9999999999.99999999" "999999999999999999" \
        "-9999999999.99999999" "-999999999999999999" \
        "9999999999.999999995" "1000000000000000000"
    conclude "decToUnits_plainTokens_matchUnits"
}

test_decToUnits_invalidText_rejected() {
    expect_rejected dec_to_units \
        "12345678901" "-12345678901" "abc" "" "1." ".5" "+1" "1e5" "1E-8" "1.2.3" " 1" "1 " \
        "0x10" "--1" "1,5"
    conclude "decToUnits_invalidText_rejected"
}

test_numToUnits_jqForms_matchUnits() {
    expect_outputs num_to_units \
        "1E-8" "1" \
        "1e-8" "1" \
        "1.5E+3" "150000000000" \
        "1.5e3" "150000000000" \
        "-2.5e-7" "-25" \
        "1E-0008" "1" \
        "5E-9" "1" \
        "-5E-9" "-1" \
        "1.23456789E-1" "12345679" \
        "1E+9" "100000000000000000" \
        "9.99999999999999999E+9" "999999999999999999" \
        "1E-100" "0" \
        "0E+5" "0" \
        "123.456" "12345600000" \
        "-0.00000001" "-1"
    conclude "numToUnits_jqForms_matchUnits"
}

test_numToUnits_invalidForms_rejected() {
    expect_rejected num_to_units \
        "1e1000" "1E-1000" "1E" "E5" "1e+" "1.5E+3.0" "abc" "" "null" "NaN" "Infinity" "+1E5"
    conclude "numToUnits_invalidForms_rejected"
}

test_unitsToDec_units_normalisedText() {
    expect_outputs units_to_dec \
        "150000000" "1.5" \
        "1" "0.00000001" \
        "-25" "-0.00000025" \
        "0" "0" \
        "-0" "0" \
        "100000000" "1" \
        "-100000000" "-1" \
        "1000000000" "10" \
        "007" "0.00000007" \
        "999999999999999999" "9999999999.99999999"
    expect_rejected units_to_dec "1.5" "abc" "" "+5" "1e8"
    conclude "unitsToDec_units_normalisedText"
}

# shellcheck disable=SC2317,SC2329 # Invoked through expect_outputs.
# round_trip TEXT: TEXT through dec_to_units or num_to_units, then units_to_dec.
round_trip() {
    local units
    if [[ "$1" == *[eE]* ]]; then
        units="$(num_to_units "$1")"
    else
        units="$(dec_to_units "$1")"
    fi
    units_to_dec "$units"
}

test_decimals_roundTrip_normaliseToken() {
    expect_outputs round_trip \
        "1.50000000" "1.5" \
        "-0.00000001" "-0.00000001" \
        "9999999999.99999999" "9999999999.99999999" \
        "-9999999999.99999999" "-9999999999.99999999" \
        "10.0" "10" \
        "-0" "0" \
        "0.000000015" "0.00000002" \
        "007.10" "7.1" \
        "1E-8" "0.00000001" \
        "1.5E+3" "1500" \
        "-2.5e-7" "-0.00000025"
    conclude "decimals_roundTrip_normaliseToken"
}

test_resolveInterval_setting_matchesBrokerRule() {
    expect_outputs resolve_interval \
        "" "60" \
        "abc" "60" \
        "0" "60" \
        "-5" "60" \
        "4294968" "60" \
        "1.5" "60" \
        "+0" "60" \
        "-0" "60" \
        "99999999999999999999" "60" \
        " 15 " "15" \
        "+15" "15" \
        "015" "15" \
        "15" "15" \
        $'\t15\n' "15" \
        "1" "1" \
        "4294967" "4294967" \
        "0004294967" "4294967"
    conclude "resolveInterval_setting_matchesBrokerRule"
}

# ---------------------------------------------------------------------------------------------
# Broker log windows

test_readWindow_brokerLog_recordsOnlyCycleAndTriggerLines() {
    local call="compose -p e2e-unit-test -f compose.dev.yaml logs --no-color --no-log-prefix"
    call+=" --since 2026-11-25T10:00:00Z broker-service"
    new_run
    broker_log \
        "Portfolio insights for account [$TEST_ACCOUNT] holdings [2]" \
        C \
        "T $ID_UPPER 3" \
        "Alert [$ID_LOWER] of account [$TEST_ACCOUNT] skipped: reason [no_price]" \
        "Alert evaluation cycle failed: reason [prices]" \
        "Alert evaluation cycle cancelled: alerts [2] triggered [0]" \
        "Alert [not-an-alert-id] triggered for account [$TEST_ACCOUNT] revision [1]" \
        "Alert [$ID_A] triggered for account [$TEST_ACCOUNT] type [PROFIT_LOSS] revision [x]" \
        C
    read_window "2026-11-25T10:00:00Z" || reasons+=("read_window failed")
    row_is "events" "$(file_text "$RUN_DIR/window.events")" \
        "$(printf 'C completed\nT %s 3\nC completed' "$ID_LOWER")"
    row_is "one log read of the project's broker-service" \
        "$(file_text "$CASE_DIR/docker.calls")" "$call"
    conclude "readWindow_brokerLog_recordsOnlyCycleAndTriggerLines"
}

test_brokerLogReads_rawOutput_keptOnlyInPrivateDir() {
    local name marker="unrelated broker line e2e-test-marker"
    local insights="Portfolio insights for account [$TEST_ACCOUNT] holdings [2] value [1.5]"
    insights+=" risk [LOW] duration [3] ms trace [0123456789abcdef0123456789abcdef]"
    new_run
    broker_log "$marker" C "T $ID_A 1" "$insights"
    read_window "2026-11-25T10:00:00Z" || reasons+=("read_window failed")
    insights_line_logged "2026-11-25T10:00:00Z" "$TEST_ACCOUNT" 2 1.5 LOW ||
        reasons+=("insights_line_logged missed the insights line: $POLL_DETAIL")
    if grep -rqF -e "$marker" -e "Portfolio insights" -e "triggered for account" "$RUN_DIR"; then
        reasons+=("the run directory holds broker output in [$(grep -rlF -e "$marker" -e "Portfolio insights" -e "triggered for account" "$RUN_DIR" | tr '\n' ' ')]")
    fi
    for name in window.log insights.log; do
        if ! grep -qF "$marker" "$PRIVATE_DIR/$name"; then
            reasons+=("$PRIVATE_DIR/$name does not hold the raw log read")
        fi
    done
    conclude "brokerLogReads_rawOutput_keptOnlyInPrivateDir"
}

test_readWindow_cycleLine_recordsOutcome() {
    local row name event expected
    local summary="Alert evaluation cycle finished: alerts [3] triggered [1] failed [0] skipped [0]"
    local unread="Alert evaluation cycle finished: alerts [x] triggered [1] failed [0] skipped [0]"
    local -a rows=(
        "completed|C|C completed"
        "failed|C failed|C failed"
        "outcome outside completed and failed|C pending|C unknown"
        "outcome without the duration|$summary outcome [completed]|C unknown"
        "no outcome rendered|Alert evaluation cycle finished: alerts [2] triggered [0]|C unknown"
        "count not a number|$unread outcome [completed] duration [7] ms|C unknown"
    )
    for row in "${rows[@]}"; do
        IFS='|' read -r name event expected <<<"$row"
        new_run
        broker_log "$event"
        read_window "2026-11-25T10:00:00Z" || reasons+=("$name: read_window failed")
        row_is "$name" "$(file_text "$RUN_DIR/window.events")" "$expected"
    done
    new_run
    broker_log "C failed" "T $ID_A 1" C "C pending"
    read_window "2026-11-25T10:00:00Z" || reasons+=("one per line: read_window failed")
    row_is "one outcome per cycle line, in log order" "$(file_text "$RUN_DIR/window.events")" \
        "$(printf 'C failed\nT %s 1\nC completed\nC unknown' "$ID_A")"
    conclude "readWindow_cycleLine_recordsOutcome"
}

test_windowCycles_window_countsCycleLines() {
    new_run
    read_window "2026-11-25T10:00:00Z" || reasons+=("read_window failed on the empty log")
    row_is "empty window" "$(window_cycles)" "0"
    broker_log C "T $ID_A 1" "unrelated line" C C
    read_window "2026-11-25T10:00:00Z" || reasons+=("read_window failed")
    row_is "three cycles around a trigger" "$(window_cycles)" "3"
    broker_log C "T $ID_A 1" "C failed" "C pending" C
    read_window "2026-11-25T10:00:00Z" || reasons+=("read_window failed")
    row_is "every outcome counted" "$(window_cycles)" "4"
    conclude "windowCycles_window_countsCycleLines"
}

# position ID REVISION: "STATUS INDEX CYCLES" of trigger_position on the current window.
position() {
    TRIGGER_INDEX="-"
    TRIGGER_CYCLES="-"
    if trigger_position "$1" "$2"; then
        echo "0 $TRIGGER_INDEX $TRIGGER_CYCLES"
    else
        echo "1 $TRIGGER_INDEX $TRIGGER_CYCLES"
    fi
}

test_triggerPosition_events_locateOwnArming() {
    new_run
    printf 'C completed\nC failed\nT %s 1\nC unknown\nT %s 2\n' "$ID_A" "$ID_B" \
        >"$RUN_DIR/window.events"
    row_is "after two cycles" "$(position "$ID_A" 1)" "0 3 2"
    row_is "after three cycles" "$(position "$ID_B" 2)" "0 5 3"
    row_is "other revision" "$(position "$ID_A" 2)" "1 - -"
    row_is "unknown id" "$(position "$ID_UPPER" 1)" "1 - -"
    printf 'T %s 1\nC completed\nC completed\n' "$ID_A" >"$RUN_DIR/window.events"
    row_is "before any cycle" "$(position "$ID_A" 1)" "0 1 0"
    conclude "triggerPosition_events_locateOwnArming"
}

# outcome COMMAND ARGS...: "STATUS POLL_DETAIL" of a poll command.
outcome() {
    local rc=0
    POLL_DETAIL=""
    "$@" || rc=$?
    echo "$rc $POLL_DETAIL"
}

test_triggerLogged_brokerLog_findsArmingByLowercaseId() {
    new_run
    LOG9_SINCE="2026-11-25T10:00:00Z"
    broker_log C "T $ID_UPPER 2" C
    row_is "upper-case id in the log" "$(outcome trigger_logged "$ID_LOWER" 2)" "0 "
    row_is "other revision" "$(outcome trigger_logged "$ID_LOWER" 3)" \
        "1 no line [Alert [$ID_LOWER] triggered for account [...] ... revision [3]] since $LOG9_SINCE"
    BROKER_LOGS_RC=1
    row_is "logs unreadable" "$(outcome trigger_logged "$ID_LOWER" 2)" \
        "1 broker-service logs unreadable, exit 1 (see $RUN_DIR/compose.log)"
    conclude "triggerLogged_brokerLog_findsArmingByLowercaseId"
}

# trigger_lines ID REVISION...: the step-9 trigger lines run file, one "ID REVISION" per pair.
trigger_lines() {
    : >"$RUN_DIR/trigger-lines"
    while [[ $# -ge 2 ]]; do
        echo "$1 $2" >>"$RUN_DIR/trigger-lines"
        shift 2
    done
}

test_laterCyclesSeen_window_needsCompletedCycleAfterTriggeringCycle() {
    local own="only the triggering cycle's own summary after the last trigger line; a completed follow-up cycle is needed"
    local none="no cycle line after the last trigger line; the triggering cycle's own summary and a completed follow-up cycle are needed"
    local open="no follow-up cycle after the last trigger line completed:"
    local need="a completed one is needed"
    local unread="Alert evaluation cycle finished: alerts [2] triggered [0]"
    new_run
    LOG9_SINCE="2026-11-25T10:00:00Z"
    trigger_lines "$ID_A" 1
    broker_log C "T $ID_A 1" C C
    row_is "completed cycle after the triggering cycle's own" "$(outcome later_cycles_seen)" "0 "
    broker_log C "T $ID_A 1" C
    row_is "only the triggering cycle's own" "$(outcome later_cycles_seen)" "1 $own"
    broker_log C "T $ID_A 1"
    row_is "no cycle after the trigger" "$(outcome later_cycles_seen)" "1 $none"
    broker_log C C "T $ID_A 1" C
    row_is "cycles before the trigger" "$(outcome later_cycles_seen)" "1 $own"
    broker_log C "T $ID_A 1" C "C failed"
    row_is "follow-up cycle failed only" "$(outcome later_cycles_seen)" \
        "1 $open 1 failed, 0 without a rendered outcome; $need"
    broker_log C "T $ID_A 1" C "C failed" C
    row_is "failed then completed" "$(outcome later_cycles_seen)" "0 "
    broker_log C "T $ID_A 1" C "C pending" "$unread"
    row_is "follow-ups without a readable outcome" "$(outcome later_cycles_seen)" \
        "1 $open 0 failed, 2 without a rendered outcome; $need"
    broker_log C C C "T $ID_A 1" C
    row_is "trigger later in a reread window than in step 9's" "$(outcome later_cycles_seen)" \
        "1 $own"
    trigger_lines "$ID_A" 1 "$ID_B" 1
    broker_log "T $ID_A 1" C "T $ID_B 1" C
    row_is "cycle between two triggers" "$(outcome later_cycles_seen)" "1 $own"
    trigger_lines "$ID_B" 1 "$ID_A" 1
    broker_log "T $ID_A 1" C "T $ID_B 1" C C
    row_is "last trigger in the log, not in the run file" "$(outcome later_cycles_seen)" "0 "
    trigger_lines "$ID_A" 1 "$ID_B" 2
    broker_log C "T $ID_A 1" C C "T $ID_B 1"
    row_is "trigger line gone from a reread window" "$(outcome later_cycles_seen)" \
        "1 the step-9 trigger line of alert [$ID_B] revision [2] is no longer in the log window since $LOG9_SINCE"
    trigger_lines
    broker_log C "T $ID_A 1" C C
    row_is "no trigger line recorded" "$(outcome later_cycles_seen)" \
        "1 no step-9 trigger line was recorded to count cycles from"
    trigger_lines "$ID_A" 1
    BROKER_LOGS_RC=1
    row_is "logs unreadable" "$(outcome later_cycles_seen)" \
        "1 broker-service logs unreadable, exit 1 (see $RUN_DIR/compose.log)"
    conclude "laterCyclesSeen_window_needsCompletedCycleAfterTriggeringCycle"
}

# notification ID REVISION VALUE: one notifications item, triggered at a fixed time.
notification() {
    printf '{"id":"%s","armingRevision":%s,"triggeredAt":"2026-11-25T10:00:05Z","triggerValue":%s}' \
        "$1" "$2" "$3"
}

test_step9Trigger_triggerLines_recordLoggedArmingsOnly() {
    local first="aaaaaaaa-0000-4000-8000-000000000001" last="aaaaaaaa-0000-4000-8000-000000000004"
    local instrument="cccccccc-0000-4000-8000-00000000000c" id
    new_run
    respond 200 "application/json" \
        "{\"results\":[{\"id\":\"$instrument\",\"amount\":1,\"price\":{\"close\":12.5}}]}"
    for id in "$first" aaaaaaaa-0000-4000-8000-000000000002 aaaaaaaa-0000-4000-8000-000000000003 \
        "$last"; do
        respond 201 "application/json" "{\"id\":\"$id\"}"
    done
    respond 200 "application/json" \
        "{\"results\":[$(notification "$first" 1 12.5),$(notification "$last" 1 0)]}"
    broker_log C "T $(tr '[:lower:]' '[:upper:]' <<<"$first") 1" C
    (
        HOLDER_ID="$TEST_ACCOUNT"
        step9_trigger
    ) >"$CASE_DIR/out" 2>&1 || reasons+=("step9_trigger exited non-zero")
    row_is "only the logged arming recorded, by id and revision" \
        "$(file_text "$RUN_DIR/trigger-lines")" "$first 1"
    has_line "$CASE_DIR/out" "PASS step 9 target_price ABOVE trigger log line" ||
        reasons+=("no PASS for the logged trigger line")
    grep -q '^FAIL step 9 profit_loss BELOW trigger log line: ' "$CASE_DIR/out" ||
        reasons+=("no FAIL for the trigger line missing from the log")
    conclude "step9Trigger_triggerLines_recordLoggedArmingsOnly"
}

# run_step10 INTERVAL: runs step10_no_repeat for the holder with the step-9 alerts ready, its
# output in $CASE_DIR/out and its PASS and FAIL lines in $CASE_DIR/verdicts.
run_step10() {
    (
        PAIRS_READY=1
        INTERVAL="$1"
        HOLDER_ID="$TEST_ACCOUNT"
        step10_no_repeat
    ) >"$CASE_DIR/out" 2>&1 || reasons+=("step10_no_repeat exited non-zero")
    verdicts "$CASE_DIR/out" >"$CASE_DIR/verdicts"
}

test_step10NoRepeat_followUpCycle_passesOnlyOnceCompleted() {
    local check="step 10 a later cycle completed" unchanged="PASS step 10 no second notification"
    local detail="no follow-up cycle after the last trigger line completed: 1 failed, 0 without a rendered outcome; a completed one is needed"
    local listed
    local -a lines
    listed="{\"results\":[$(notification "$ID_A" 1 2)]}"

    new_run
    echo "$ID_A 1 2026-11-25T10:00:05Z target_price ABOVE" >"$RUN_DIR/triggered"
    respond 200 "application/json" "$listed"
    run_step10 1
    row_is "no trigger line recorded" "$(file_text "$CASE_DIR/verdicts")|$(file_text "$CASE_DIR/docker.calls")" \
        "FAIL $check: no trigger line was found in step 9 to count cycles from"$'\n'"$unchanged|"

    new_run
    echo "$ID_A 1 2026-11-25T10:00:05Z target_price ABOVE" >"$RUN_DIR/triggered"
    trigger_lines "$ID_A" 1
    broker_log "T $ID_A 1" C "C failed"
    respond 200 "application/json" "$listed"
    run_step10 1
    mapfile -t lines <"$CASE_DIR/verdicts"
    row_is "follow-up cycle failed only: verdict lines" "${#lines[@]}" "2"
    if [[ "${lines[0]:-}" != "FAIL $check: "*"; $detail" ]]; then
        reasons+=("follow-up cycle failed only: got [${lines[0]:-}], expected FAIL $check ending [; $detail]")
    fi
    row_is "follow-up cycle failed only: notifications" "${lines[1]:-}" "$unchanged"

    new_run
    echo "$ID_A 1 2026-11-25T10:00:05Z target_price ABOVE" >"$RUN_DIR/triggered"
    trigger_lines "$ID_A" 1
    broker_log "T $ID_A 1" C "C failed" C
    respond 200 "application/json" "$listed"
    run_step10 1
    row_is "failed then completed" "$(file_text "$CASE_DIR/verdicts")" "PASS $check"$'\n'"$unchanged"
    conclude "step10NoRepeat_followUpCycle_passesOnlyOnceCompleted"
}

# ---------------------------------------------------------------------------------------------
# Alert ownership

# A 201 with a readable id is owned and any 4xx refused; every other outcome journals the
# account the request body names, read from its text even when it is not valid JSON, as
# settled after a 2xx, which shows the request finished, and as unsettled after anything else.
test_ownIfCreated_response_ownsCreatedAndJournalsUncertain() {
    local row status body request owned journaled
    local named="{\"accountId\":\"$TEST_ACCOUNT\",\"threshold\":1}"
    local -a rows=(
        "201|{\"id\":\"$ID_UPPER\"}|$named|$ID_LOWER|"
        "201|{}|$named||$TEST_ACCOUNT settled"
        "201|{\"id\":\"not-a-uuid\"}|$named||$TEST_ACCOUNT settled"
        "201|not json|$named||$TEST_ACCOUNT settled"
        "400|{\"id\":\"$ID_UPPER\"}|$named||"
        "403|{\"error\":\"feature_disabled\"}|$named||"
        "404|{}|$named||"
        "200|{\"id\":\"$ID_UPPER\"}|$named||$TEST_ACCOUNT settled"
        "204||$named||$TEST_ACCOUNT settled"
        "101||$named||$TEST_ACCOUNT unsettled"
        "302||$named||$TEST_ACCOUNT unsettled"
        "500|boom|$named||$TEST_ACCOUNT unsettled"
        "000||$named||$TEST_ACCOUNT unsettled"
        "000||{\"accountId\" : \"$ID_UPPER\",\"threshold\":1||$ID_LOWER unsettled"
        "000||{\"threshold\":1}||unknown unsettled"
        "201|{}|{\"accountId\":\"not-a-guid\"}||unknown settled"
    )
    for row in "${rows[@]}"; do
        new_run
        IFS='|' read -r status body request owned journaled <<<"$row"
        HTTP_STATUS="$status"
        HTTP_BODY="$body"
        own_if_created "$request"
        row_is "$status $body, request $request" \
            "$(file_text "$RUN_DIR/owned")|$(file_text "$RUN_DIR/uncertain-creates")" \
            "$owned|$journaled"
    done
    conclude "ownIfCreated_response_ownsCreatedAndJournalsUncertain"
}

test_postAlert_nonTokenThreshold_rejectedBeforeRequest() {
    local threshold rc
    new_run
    for threshold in "1e5" '"12"' "abc" "1." ".5" "+1" "" "1 " "00" "-"; do
        rc=0
        post_alert "$TEST_ACCOUNT" TARGET_PRICE "$ID_A" ABOVE "$threshold" || rc=$?
        row_is "[$threshold] status" "$rc" "1"
        row_is "[$threshold] error" "$CREATE_ERROR" "threshold [$threshold] is not a plain decimal token"
    done
    row_is "requests sent" "$(file_text "$CASE_DIR/requests")" ""
    conclude "postAlert_nonTokenThreshold_rejectedBeforeRequest"
}

# A refusal (4xx) is not journaled; every uncertain outcome journals the account, once. The
# reason a transport error gives is status_text's, which the expectation reads as http left it.
test_postAlert_unusableResponse_failsJournalingOnlyUncertain() {
    local row status body reason journaled rc expected
    local uncertain="the alert may exist without an id this run knows, so the create is"
    uncertain+=" journaled for reconciliation on exit"
    local -a rows=(
        "000|$CONNECT_ERROR|transport|$TEST_ACCOUNT unsettled"
        "400|{\"error\":\"invalid\"}|status 400; body [19 bytes, JSON object with 1 key [error]]|"
        "404|{\"error\":\"unknown\"}|status 404; body [19 bytes, JSON object with 1 key [error]]|"
        "201|{}|201 without a readable id; $uncertain|$TEST_ACCOUNT settled"
        "201|{\"id\":\"xyz\"}|201 without a readable id; $uncertain|$TEST_ACCOUNT settled"
        "200|{\"id\":\"$ID_A\"}|status 200; body [45 bytes, JSON object with 1 key [id]]; $uncertain|$TEST_ACCOUNT settled"
        "500|boom|status 500; body [4 bytes, not JSON]; $uncertain|$TEST_ACCOUNT unsettled"
    )
    for row in "${rows[@]}"; do
        new_run
        IFS='|' read -r status body reason journaled <<<"$row"
        respond "$status" "application/json" "$body"
        rc=0
        post_alert "$TEST_ACCOUNT" TARGET_PRICE "$ID_A" ABOVE 1 || rc=$?
        expected="$reason"
        if [[ "$reason" == "transport" ]]; then
            expected="$(status_text); $uncertain"
        fi
        row_is "$status $body" \
            "$rc|$CREATE_ERROR|$CREATED_ID|$(file_text "$RUN_DIR/owned")|$(file_text "$RUN_DIR/uncertain-creates")" \
            "1|$expected|||$journaled"
    done
    conclude "postAlert_unusableResponse_failsJournalingOnlyUncertain"
}

# A 201 whose id cannot be recorded as owned is journaled instead; an uncertain create whose
# journal line cannot be written is counted, which fails the cleanup check.
test_postAlert_recordUnwritable_journalsOrCountsCreate() {
    local uncertain="the alert may exist without an id this run knows"
    new_run
    break_step "owned not a file"
    respond 201 "application/json" "{\"id\":\"$ID_UPPER\"}"
    post_alert "$TEST_ACCOUNT" TARGET_PRICE "$ID_A" ABOVE 1 2>/dev/null || true
    row_is "owned unwritable" \
        "$CREATE_ERROR|$CREATED_ID|$(file_text "$RUN_DIR/uncertain-creates")|$UNJOURNALED_CREATES" \
        "201 with id [$ID_LOWER], which could not be recorded as owned; $uncertain, so the create is journaled for reconciliation on exit||$TEST_ACCOUNT settled|0"

    new_run
    break_step "uncertain-creates not a file"
    respond 500 "text/plain" "boom"
    post_alert "$TEST_ACCOUNT" TARGET_PRICE "$ID_A" ABOVE 1 2>/dev/null || true
    row_is "journal unwritable" "$CREATE_ERROR|$UNJOURNALED_CREATES" \
        "status 500; body [4 bytes, not JSON]; $uncertain, and the create could not be journaled, so the cleanup check fails|1"
    conclude "postAlert_recordUnwritable_journalsOrCountsCreate"
}

test_postAlert_created_ownsLowercaseId() {
    local rc=0
    new_run
    respond 201 "application/json; charset=utf-8" "{\"id\":\"$ID_UPPER\",\"armingRevision\":1}"
    post_alert "$TEST_ACCOUNT" TARGET_PRICE "$ID_A" ABOVE 1 || rc=$?
    row_is "status, id and owned ids" "$rc|$CREATED_ID|$(file_text "$RUN_DIR/owned")" \
        "0|$ID_LOWER|$ID_LOWER"
    conclude "postAlert_created_ownsLowercaseId"
}

test_postAlert_token_sentVerbatim() {
    local token rc expected
    for token in "0.00000001" "-0.00000001" "9999999999.99999999" "1.500000000" "0"; do
        new_run
        respond 201 "application/json" "{\"id\":\"$ID_A\"}"
        rc=0
        post_alert "$TEST_ACCOUNT" PROFIT_LOSS "$ID_B" BELOW "$token" || rc=$?
        expected="0 POST $ALERTS_URL {\"accountId\":\"$TEST_ACCOUNT\",\"type\":\"PROFIT_LOSS\","
        expected+="\"instrumentId\":\"$ID_B\",\"direction\":\"BELOW\",\"threshold\":$token}"
        row_is "$token" "$rc $(file_text "$CASE_DIR/requests")" "$expected"
    done
    conclude "postAlert_token_sentVerbatim"
}

# Each test that interrupts itself traps and sends TERM, never INT: a shell started in the
# background ignores INT on entry and cannot trap it, and e2e.sh traps INT and TERM alike.
# interrupt_when_answered: in the calling subshell, http answers each request and the subshell
# then sends itself TERM, so the interrupt arrives while the create that sent it holds the exit.
interrupt_when_answered() {
    eval "answered_$(declare -f http)"
    http() {
        local rc=0
        answered_http "$@" || rc=$?
        kill -TERM "$BASHPID"
        return "$rc"
    }
}

test_onSignal_interrupt_heldOnlyWhileCreating() {
    local status between="FAIL interrupted: signal received between steps;"
    between+=" any step not yet started did not run"
    new_run
    status=0
    (
        IN_CREATE=0
        on_signal
        echo "continued"
    ) >"$CASE_DIR/out" 2>&1 || status=$?
    row_is "outside a create" "$status|$(file_text "$CASE_DIR/out")" "130|$between"

    new_run
    respond 201 "application/json" "{\"id\":\"$ID_UPPER\"}"
    status=0
    (
        trap on_signal TERM
        interrupt_when_answered
        create_alert "$TEST_ACCOUNT" TARGET_PRICE "$ID_A" ABOVE 1
        echo "continued"
    ) >"$CASE_DIR/out" 2>&1 || status=$?
    row_is "during the POST" "$status|$(file_text "$CASE_DIR/out")|$(file_text "$RUN_DIR/owned")" \
        "130|$between|$ID_LOWER"

    new_run
    respond 201 "application/json" "{\"id\":\"$ID_UPPER\"}"
    status=0
    (
        trap on_signal TERM
        create_alert "$TEST_ACCOUNT" TARGET_PRICE "$ID_A" ABOVE 1
        echo "continued"
    ) >"$CASE_DIR/out" 2>&1 || status=$?
    row_is "no interrupt" "$status|$(file_text "$CASE_DIR/out")|$(file_text "$RUN_DIR/owned")" \
        "0|continued|$ID_LOWER"
    conclude "onSignal_interrupt_heldOnlyWhileCreating"
}

# The innermost step function on the call stack is named, past helpers whose names only start
# like one. A second interrupt while a create holds the exit (IN_CREATE=1, as create_alert sets
# it) prints no second line and leaves the exit held.
test_onSignal_interruptInStep_failsOnceNamingStep() {
    local status line
    new_run
    status=0
    (
        trap on_signal TERM
        step_interrupt() {
            kill -TERM "$BASHPID"
            echo "continued"
        }
        step13_cleanup_and_disable() {
            step_interrupt
        }
        step13_cleanup_and_disable
    ) >"$CASE_DIR/out" 2>&1 || status=$?
    line="FAIL interrupted: signal received during step 13; step 13 did not finish"
    row_is "step 13, outside a create" "$status|$(file_text "$CASE_DIR/out")" \
        "130|$line and the steps after it did not run"

    new_run
    status=0
    (
        received=0
        trap 'received=$((received + 1)); on_signal' TERM
        held_create() {
            IN_CREATE=1
            kill -TERM "$BASHPID"
            kill -TERM "$BASHPID"
            echo "held for exit $PENDING_EXIT after $received interrupts"
        }
        step9_trigger() {
            held_create
        }
        step9_trigger
    ) >"$CASE_DIR/out" 2>&1 || status=$?
    line="FAIL interrupted: signal received during step 9; step 9 did not finish"
    row_is "step 9, two interrupts in a held create" "$status|$(file_text "$CASE_DIR/out")" \
        "0|$line and the steps after it did not run"$'\n'"held for exit 130 after 2 interrupts"
    conclude "onSignal_interruptInStep_failsOnceNamingStep"
}

# shellcheck disable=SC2317,SC2329 # Invoked in a subshell of the test below.
# interrupt_redirected SITE: runs as main runs, with the run's stdout saved on descriptor 9 and
# both traps set. Step 9 makes SITE's call, whose stdout is a working file, and the interrupt
# arrives inside it: in the log read of read_window and insights_line_logged, and in own_alert
# once the id is written to owned.
interrupt_redirected() {
    lower_interrupts=0
    if [[ "$1" == "own_alert" ]]; then
        lower_interrupts=1
    fi
    exec 9>&1
    RUN_STDOUT_SAVED=1
    trap cleanup EXIT
    trap on_signal INT TERM
    broker_logs() {
        echo "broker line before the interrupt"
        kill -TERM "$BASHPID"
    }
    lower() {
        command tr '[:upper:]' '[:lower:]'
        if [[ $lower_interrupts -eq 1 ]]; then
            lower_interrupts=0
            kill -TERM "$BASHPID"
        fi
    }
    step9_trigger() {
        case "$1" in
            read_window) read_window "2026-11-25T10:00:00Z" ;;
            insights_line_logged)
                insights_line_logged "2026-11-25T10:00:00Z" "$TEST_ACCOUNT" 2 1.5 LOW
                ;;
            own_alert) own_alert "$ID_UPPER" ;;
        esac
    }
    step9_trigger "$1"
    echo "INFO not reached"
}

# bash runs a trap inside the call it interrupts, under that call's redirections. With the run's
# stdout saved, the FAIL line, cleanup's output and the SUMMARY line still reach the run's stdout
# and none of them the working file: owned keeps only the id, and the raw log reads go with the
# private directory.
test_onSignal_interruptInRedirectedCall_verdictOnRunStdout() {
    local site status expected owned requests
    local interrupted="FAIL interrupted: signal received during step 9; step 9 did not finish"
    interrupted+=" and the steps after it did not run"
    for site in read_window insights_line_logged own_alert; do
        new_run
        cleanup_state true 0 0 0
        expected="$interrupted"
        owned=""
        requests=""
        if [[ "$site" == "own_alert" ]]; then
            respond 200 "application/json" '{"id":"portfolio-insights-enabled","enabled":true}'
            respond 204 "" ""
            expected+=$'\n'"INFO cleanup: 1 of 1 remaining owned alerts deleted or already absent"
            owned="$ID_LOWER"
            requests="GET $F"$'\n'"DELETE $ALERTS_URL/$ID_LOWER"
        fi
        expected+=$'\n'"INFO cleanup: fixture and private working files removed"
        expected+=$'\n'"PASS cleanup"$'\n'"INFO run dir $RUN_DIR"$'\n'"SUMMARY 1 passed, 1 failed"
        status=0
        (interrupt_redirected "$site") >"$CASE_DIR/out" 2>&1 || status=$?
        row_is "$site: status and run output" "$status|$(file_text "$CASE_DIR/out")" \
            "130|$expected"
        row_is "$site: owned and requests" \
            "$(file_text "$RUN_DIR/owned")|$(file_text "$CASE_DIR/requests")" "$owned|$requests"
        if [[ -e "$PRIVATE_DIR" ]]; then
            reasons+=("$site: the private directory, with the raw log read, remains")
        fi
    done
    conclude "onSignal_interruptInRedirectedCall_verdictOnRunStdout"
}

# shellcheck disable=SC2317,SC2329 # Invoked in a subshell of the test below.
# signal_as_cleanup_starts CASE: an interrupt as the EXIT trap starts, with the run's stdout
# saved and both traps set as main sets them. secondAfterExit: step 9 is interrupted, and a
# second interrupt arrives right after on_signal's exit, before cleanup could set its own trap.
# insideCleanup: the run exits 0 and the interrupt arrives inside cleanup, before cleanup sets
# its own trap. Nothing can run inside e2e.sh's cleanup before that line, so a stand-in named
# cleanup takes its place.
signal_as_cleanup_starts() {
    exec 9>&1
    RUN_STDOUT_SAVED=1
    trap on_signal INT TERM
    case "$1" in
        secondAfterExit)
            exit_trap_start() {
                kill -TERM "$BASHPID"
                cleanup
            }
            trap exit_trap_start EXIT
            step9_trigger() {
                kill -TERM "$BASHPID"
            }
            step9_trigger
            ;;
        insideCleanup)
            cleanup() {
                kill -TERM "$BASHPID"
                echo "INFO cleanup went on"
            }
            trap cleanup EXIT
            exit 0
            ;;
    esac
    echo "INFO not reached"
}

# An interrupt as the EXIT trap starts is on_cleanup_signal's: the run still ends with the
# cleanup verdict, the SUMMARY line and exit status 130, and the private directory is removed,
# where an exit inside the EXIT trap would end it with none of them.
test_onSignal_signalAsCleanupStarts_endsRunThroughCleanupSignal() {
    local name status expected
    local first="FAIL interrupted: signal received during step 9; step 9 did not finish and the"
    first+=" steps after it did not run"
    local abandoned="FAIL cleanup: interrupted before it finished: owned alerts may be left in"
    abandoned+=" place and flag $FLAG_ID may not be restored"
    for name in secondAfterExit insideCleanup; do
        new_run
        cleanup_state true 0 0 0
        case "$name" in
            secondAfterExit)
                expected="$first"$'\n'"$abandoned"$'\n'"INFO run dir $RUN_DIR"
                expected+=$'\n'"SUMMARY 0 passed, 2 failed"
                ;;
            insideCleanup)
                expected="$abandoned"$'\n'"INFO run dir $RUN_DIR"$'\n'"SUMMARY 0 passed, 1 failed"
                ;;
        esac
        status=0
        (signal_as_cleanup_starts "$name") >"$CASE_DIR/out" 2>&1 || status=$?
        row_is "$name: status and run output" "$status|$(file_text "$CASE_DIR/out")" \
            "130|$expected"
        if [[ -e "$PRIVATE_DIR" ]]; then
            reasons+=("$name: the private directory remains")
        fi
    done
    conclude "onSignal_signalAsCleanupStarts_endsRunThroughCleanupSignal"
}

# Closed stdout leaves main nothing to save on descriptor 9. It goes on unsaved, its first line
# then ends the run under errexit, and the EXIT trap still removes the private directory.
test_main_stdoutClosed_runsUnsavedAndRemovesPrivateDir() {
    local run_dirs private_dirs
    new_run
    mkdir -p "$CASE_DIR/tmp"
    CHILD_STATUS=0
    # shellcheck disable=SC2016 # Expanded by the child bash.
    TMPDIR="$CASE_DIR/tmp" "$BASH" -c '
        curl() { :; }
        node() { :; }
        source "$1" --project e2e-unit-test --compose-file compose.dev.yaml --base-url "$2"
        main' e2e-test-child "$E2E" "$TEST_BASE_URL" >&- 2>"$CASE_DIR/child.err" </dev/null ||
        CHILD_STATUS=$?
    run_dirs="$(compgen -G "$CASE_DIR/tmp/pi-e2e.*" || true)"
    private_dirs="$(compgen -G "$CASE_DIR/tmp/pi-e2e-private.*" || true)"
    row_is "status" "$CHILD_STATUS" "1"
    if [[ -z "$run_dirs" ]]; then
        reasons+=("no run directory, so the run ended before main")
    fi
    row_is "private directories left" "$private_dirs" ""
    conclude "main_stdoutClosed_runsUnsavedAndRemovesPrivateDir"
}

test_remainingOwned_ownedAndDeleted_listsUndeleted() {
    new_run
    row_is "nothing owned" "$(remaining_owned)|$(file_text "$RUN_DIR/to-delete")" "0|"
    printf '%s\n' "$ID_B" "$ID_A" "$ID_LOWER" "$ID_A" >"$RUN_DIR/owned"
    echo "$ID_LOWER" >"$RUN_DIR/deleted"
    row_is "one deleted, one owned twice" "$(remaining_owned)|$(file_text "$RUN_DIR/to-delete")" \
        "2|$(printf '%s\n%s' "$ID_A" "$ID_B")"
    printf '%s\n' "$ID_A" "$ID_B" >>"$RUN_DIR/deleted"
    row_is "all deleted" "$(remaining_owned)|$(file_text "$RUN_DIR/to-delete")" "0|"
    conclude "remainingOwned_ownedAndDeleted_listsUndeleted"
}

# shellcheck disable=SC2317,SC2329 # Invoked by remaining_owned and delete_alert in a subshell.
# break_step STEP: makes STEP fail in the calling subshell: sort, comm or wc fails as a command
# that writes nothing, "wc garbage" prints no number, "owned missing" removes $RUN_DIR/owned,
# "owned not a file", "deleted not a file" and "uncertain-creates not a file" replace that file
# with a directory.
break_step() {
    case "$1" in
        sort) sort() { return 2; } ;;
        comm) comm() { return 1; } ;;
        wc) wc() { return 1; } ;;
        "wc garbage") wc() { echo "wc: ?"; } ;;
        "owned missing") rm -f "$RUN_DIR/owned" ;;
        "owned not a file" | "deleted not a file" | "uncertain-creates not a file")
            rm -f "$RUN_DIR/${1%% *}"
            mkdir "$RUN_DIR/${1%% *}"
            ;;
    esac
}

test_remainingOwned_stepFails_failsPrintingNothing() {
    local step status out
    for step in sort comm wc "wc garbage" "owned missing" "deleted not a file"; do
        new_run
        echo "$ID_A" >"$RUN_DIR/owned"
        status=0
        out="$(
            break_step "$step"
            remaining_owned 2>/dev/null
        )" || status=$?
        row_is "$step: status and output" "$status|$out" "1|"
    done
    conclude "remainingOwned_stepFails_failsPrintingNothing"
}

test_deleteAlert_recordUnwritable_failsKeepingStatus() {
    local row name status record expected rc
    local -a rows=(
        "204 recorded|204|file|0 204 $ID_A"
        "404 recorded|404|file|0 404 $ID_A"
        "204 not recordable|204|directory|1 204 "
        "500, nothing to record|500|directory|0 500 "
    )
    for row in "${rows[@]}"; do
        IFS='|' read -r name status record expected <<<"$row"
        new_run
        if [[ "$record" == "directory" ]]; then
            break_step "deleted not a file"
        fi
        respond "$status" "" ""
        rc=0
        delete_alert "$ID_A" 2>/dev/null || rc=$?
        if [[ -f "$RUN_DIR/deleted" ]]; then
            row_is "$name" "$rc $HTTP_STATUS $(file_text "$RUN_DIR/deleted")" "$expected"
        else
            row_is "$name" "$rc $HTTP_STATUS " "$expected"
        fi
    done
    conclude "deleteAlert_recordUnwritable_failsKeepingStatus"
}

test_deleteRemaining_statuses_mark204And404Deleted() {
    new_run
    printf '%s\n' "$ID_A" "$ID_B" "$ID_LOWER" >"$RUN_DIR/owned"
    respond 204 "" ""
    respond 404 "application/json" "{}"
    respond 500 "text/plain" "boom"
    delete_remaining >"$CASE_DIR/out"
    row_is "left" "$CLEANUP_LEFT" "1"
    row_is "deleted" "$(file_text "$RUN_DIR/deleted")" "$(printf '%s\n%s' "$ID_A" "$ID_LOWER")"
    row_is "requests" "$(file_text "$CASE_DIR/requests")" \
        "$(printf 'DELETE %s\n' "$ALERTS_URL/$ID_A" "$ALERTS_URL/$ID_LOWER" "$ALERTS_URL/$ID_B")"
    if ! has_line "$CASE_DIR/out" "INFO cleanup left alert $ID_B: status 500"; then
        reasons+=("no INFO line names the alert left in place: [$(file_text "$CASE_DIR/out")]")
    fi
    conclude "deleteRemaining_statuses_mark204And404Deleted"
}

test_deleteRemaining_transportErrors_stopAfterMaxConsecutive() {
    local row name statuses expected status k requests
    local -a rows=(
        "every DELETE unreachable|000 000 000 000 000 000 000|$MAX_CONSECUTIVE_TRANSPORT_ERRORS 7"
        "a 204 resets the run|000 000 000 000 204 000 000|7 6"
        "a 500 resets the run|000 000 000 000 500 000 000|7 7"
    )
    for row in "${rows[@]}"; do
        IFS='|' read -r name statuses expected <<<"$row"
        new_run
        for k in 1 2 3 4 5 6 7; do
            echo "0000000$k-0000-4000-8000-000000000000" >>"$RUN_DIR/owned"
        done
        for status in $statuses; do
            if [[ "$status" == "000" ]]; then
                respond 000 "" "$CONNECT_ERROR"
            else
                respond "$status" "" ""
            fi
        done
        delete_remaining >"$CASE_DIR/out"
        mapfile -t requests <"$CASE_DIR/requests"
        row_is "$name: requests and left" "${#requests[@]} $CLEANUP_LEFT" "$expected"
    done
    conclude "deleteRemaining_transportErrors_stopAfterMaxConsecutive"
}

# delete_ids reads the owned file directly when the inventory cannot be computed: each distinct
# id gets one DELETE, and an entry that is not a canonical id gets none and is left in place.
# The last line is an entry whether or not a newline ends it.
test_deleteIds_rawOwnedList_deletesEachCanonicalIdOnce() {
    local ending rc
    for ending in "final newline" "no final newline"; do
        new_run
        printf '%s\n' "$ID_A" "not-an-id" "$ID_A" "" >"$RUN_DIR/owned"
        if [[ "$ending" == "final newline" ]]; then
            echo "$ID_B" >>"$RUN_DIR/owned"
        else
            printf '%s' "$ID_B" >>"$RUN_DIR/owned"
        fi
        respond 204 "" ""
        respond 204 "" ""
        rc=0
        delete_ids "$RUN_DIR/owned" >"$CASE_DIR/out" || rc=$?
        row_is "$ending: status, distinct entries and left" "$rc $CLEANUP_IDS $CLEANUP_LEFT" "0 4 2"
        row_is "$ending: requests" "$(file_text "$CASE_DIR/requests")" \
            "$(printf 'DELETE %s\n' "$ALERTS_URL/$ID_A" "$ALERTS_URL/$ID_B")"
        if ! has_line "$CASE_DIR/out" "INFO cleanup left an owned entry that is not a canonical alert id"; then
            reasons+=("$ending: no INFO line names the entry left in place: [$(file_text "$CASE_DIR/out")]")
        fi
    done
    conclude "deleteIds_rawOwnedList_deletesEachCanonicalIdOnce"
}

test_deleteRemaining_transportError_infoCarriesFixedReason() {
    new_run
    echo "$ID_A" >"$RUN_DIR/owned"
    respond 000 "" "Failed writing body to $PRIVATE_DIR/body"
    delete_remaining >"$CASE_DIR/out"
    row_is "cleanup output" "$(file_text "$CASE_DIR/out")" \
        "INFO cleanup left alert $ID_A: transport error (curl exit 7: could not connect)"
    conclude "deleteRemaining_transportError_infoCarriesFixedReason"
}

# ---------------------------------------------------------------------------------------------
# The fixture and the browser check

# The browser check's fixture reader, readFixture in
# src/loadgen/verification/portfolio-insights-page-check.mjs, as the jq function read(MODE):
# "ok" or what it would reject. flag-off needs the holder and reads empty only when present;
# flag-on needs both accounts and exactly one ABOVE and one BELOW alert of each pair.
FIXTURE_READER='
    def uuid: type == "string"
        and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"; "i");
    def integer: type == "number" and . == floor;
    def account: type == "object" and (.username | type == "string" and length > 0)
        and (.password | type == "string" and length > 0) and (.accountId | uuid);
    def pair_types: {target_price: "TARGET_PRICE", profit_loss: "PROFIT_LOSS"};
    def alert: type == "object" and (.id | uuid)
        and (.pair | IN("target_price", "profit_loss")) and .type == pair_types[.pair]
        and (.direction | IN("ABOVE", "BELOW"))
        and (.threshold | type == "string" and test("^-?(0|[1-9][0-9]*)(\\.[0-9]+)?$"))
        and (.armingRevision | integer and . >= 1);
    def read(mode):
        if type != "object" then "the fixture is not an object"
        elif (if .evaluationIntervalSeconds == null then 60 else .evaluationIntervalSeconds end
            | integer and . > 0 | not) then "evaluationIntervalSeconds is not a positive integer"
        elif (.holder | account | not) then "holder is not an account"
        elif mode == "flag-off" then
            if has("empty") and (.empty | account | not) then "empty is not an account"
            else "ok" end
        elif (.empty | account | not) then "empty is not an account"
        elif (.alerts | type != "array" or length != 4) then "alerts are not four"
        elif any(.alerts[]; alert | not) then "an alert is malformed"
        elif (.alerts | map(.id | ascii_downcase) | unique | length) != 4 then "alert ids repeat"
        elif (.alerts | map("\(.pair) \(.direction)") | unique | length) != 4 then
            "a pair lacks its ABOVE or BELOW member"
        else "ok" end;'

# pair_alert ID PAIR TYPE DIRECTION THRESHOLD REVISION: one fixture alert as step 11 builds it,
# the threshold a string and the revision an integer.
pair_alert() {
    jq -cn --arg id "$1" --arg pair "$2" --arg type "$3" --arg direction "$4" \
        --arg threshold "$5" --argjson armingRevision "$6" \
        '{id: $id, pair: $pair, type: $type, direction: $direction, threshold: $threshold,
          armingRevision: $armingRevision}' | tr -d '\r'
}

test_writeFixture_alerts_matchBrowserCheckShape() {
    local row mode alerts verdict four written expected
    local id_c="cccccccc-0000-4000-8000-00000000000c"
    new_run
    INTERVAL=45
    HOLDER_USER="pi-e2e-1700000000-holder"
    HOLDER_PASSWORD="unit-test-holder-pass"
    HOLDER_ID="$TEST_ACCOUNT"
    EMPTY_USER="pi-e2e-1700000000-empty"
    EMPTY_PASSWORD="unit-test-empty-pass"
    EMPTY_ID="$ID_B"
    # Step 3 writes no alerts for flag-off; step 11 writes both pairs, around a close of 1.5.
    four="[$(pair_alert "$ID_A" target_price TARGET_PRICE ABOVE 1.49999999 1),"
    four+="$(pair_alert "$ID_LOWER" target_price TARGET_PRICE BELOW 1.50000001 1),"
    four+="$(pair_alert "$id_c" profit_loss PROFIT_LOSS ABOVE -0.00000001 2),"
    four+="$(pair_alert "$ID_B" profit_loss PROFIT_LOSS BELOW 9999999999.99999999 1)]"
    for row in "flag-off|[]" "flag-on|$four"; do
        IFS='|' read -r mode alerts <<<"$row"
        if ! write_fixture "$alerts"; then
            reasons+=("$mode: write_fixture failed")
            continue
        fi
        verdict="$(jq -r "$FIXTURE_READER read(\"$mode\")" "$FIXTURE")"
        row_is "$mode fixture: reader" "${verdict//$'\r'/}" "ok"
        written="$(jq -cS '.' "$FIXTURE")"
        expected="$(jq -cnS --argjson alerts "$alerts" \
            '{evaluationIntervalSeconds: 45,
              holder: {username: "pi-e2e-1700000000-holder", password: "unit-test-holder-pass",
                       accountId: "0f1e2d3c-4b5a-4968-8776-655443322110"},
              empty: {username: "pi-e2e-1700000000-empty", password: "unit-test-empty-pass",
                      accountId: "bbbbbbbb-0000-4000-8000-00000000000b"},
              alerts: $alerts}')"
        row_is "$mode fixture: content" "${written//$'\r'/}" "${expected//$'\r'/}"
    done
    conclude "writeFixture_alerts_matchBrowserCheckShape"
}

test_prefixLines_browserOutput_infoPrefixedAndLogged() {
    new_run
    printf 'PASS fixture read\r\nFAIL toast: none\nlast line without a newline' \
        | prefix_lines "browser flag-on" "$CASE_DIR/browser.log" >"$CASE_DIR/out"
    row_is "printed" "$(file_text "$CASE_DIR/out")" \
        "$(printf 'INFO browser flag-on: %s\n' "PASS fixture read" "FAIL toast: none" \
            "last line without a newline")"
    row_is "logged" "$(cat "$CASE_DIR/browser.log")" \
        "$(printf '%s\n' "PASS fixture read" "FAIL toast: none" "last line without a newline")"
    conclude "prefixLines_browserOutput_infoPrefixedAndLogged"
}

# browser_check MODE PUPPETEER: run_browser_check against a repository root of this case, with
# puppeteer installed when PUPPETEER is 1. The output goes to $CASE_DIR/out.
browser_check() {
    local saved_root="$REPO_ROOT"
    REPO_ROOT="$CASE_DIR/repo"
    mkdir -p "$REPO_ROOT/src/loadgen/node_modules"
    if [[ "$2" -eq 1 ]]; then
        mkdir -p "$REPO_ROOT/src/loadgen/node_modules/puppeteer"
    fi
    run_browser_check "$1" "step 11 browser $1" >"$CASE_DIR/out"
    REPO_ROOT="$saved_root"
}

test_runBrowserCheck_exitCode_reportsPassOrFail() {
    local rc expected codes="(1: a check failed, 2: a usage or fixture error)"
    for rc in 0 1 2; do
        new_run
        NODE_OUTPUT='PASS a browser check\nSUMMARY 1 passed, 0 failed\n'
        NODE_RC="$rc"
        browser_check flag-on 1
        expected="PASS step 11 browser flag-on"
        if [[ $rc -ne 0 ]]; then
            expected="FAIL step 11 browser flag-on: exit code $rc $codes; see"
            expected+=" $RUN_DIR/browser-flag-on.log and $RUN_DIR"
        fi
        row_is "node exit $rc" "$(last_line "$CASE_DIR/out")" "$expected"
    done
    new_run
    browser_check flag-on 0
    row_is "puppeteer missing, node not run" \
        "$(file_text "$CASE_DIR/out")|$([[ -f "$CASE_DIR/node-call" ]] && echo called)" \
        "FAIL step 11 browser flag-on: run npm ci in src/loadgen|"
    NODE_OUTPUT=""
    NODE_RC=0
    conclude "runBrowserCheck_exitCode_reportsPassOrFail"
}

test_runBrowserCheck_invocation_passesModeAndFixture() {
    local args
    new_run
    NODE_OUTPUT=""
    NODE_RC=0
    browser_check flag-off 1
    args="verification/portfolio-insights-page-check.mjs --base-url $TEST_BASE_URL"
    args+=" --mode flag-off --fixture $FIXTURE --evidence-dir $EVIDENCE_DIR"
    row_is "directory and arguments" "$(file_text "$CASE_DIR/node-call")" \
        "$(printf '%s\n%s' "$CASE_DIR/repo/src/loadgen" "$args")"
    conclude "runBrowserCheck_invocation_passesModeAndFixture"
}

# With the run's stdout saved on descriptor 9, as main saves it, the browser check, and so the
# browser it starts, runs without that descriptor and cannot hold the run's output open.
test_runBrowserCheck_runStdoutSaved_descriptorClosedForCheck() {
    new_run
    (
        exec 9>&1
        RUN_STDOUT_SAVED=1
        node() {
            if { true >&9; } 2>/dev/null; then
                echo "descriptor 9 open"
            else
                echo "descriptor 9 closed"
            fi
        }
        node >"$CASE_DIR/control"
        browser_check flag-on 1
    ) >"$CASE_DIR/subshell.out" 2>&1
    row_is "outside the check, then inside it" \
        "$(file_text "$CASE_DIR/control")|$(file_text "$RUN_DIR/browser-flag-on.log")" \
        "descriptor 9 open|descriptor 9 closed"
    conclude "runBrowserCheck_runStdoutSaved_descriptorClosedForCheck"
}

# report_state FILE: "absent", "a directory", or the text FILE holds.
report_state() {
    if [[ -d "$1" ]]; then
        echo "a directory"
    elif [[ -f "$1" ]]; then
        file_text "$1"
    else
        echo "absent"
    fi
}

# evidence_in_parent REPORT: EVIDENCE_DIR as e2e.sh's setup leaves it for --evidence-dir
# $CASE_DIR/evidence: a new directory inside that parent, which already holds REPORT ("" for
# none) as an earlier run's flag-on report, at EARLIER_REPORT.
evidence_in_parent() {
    EARLIER_REPORT="$CASE_DIR/evidence/portfolio-insights-page-check-flag-on.json"
    EVIDENCE_DIR="$CASE_DIR/evidence/pi-e2e-evidence.case$case_seq"
    mkdir -p "$EVIDENCE_DIR"
    if [[ -n "$1" ]]; then
        printf '%s\n' "$1" >"$EARLIER_REPORT"
    fi
}

test_runBrowserCheck_earlierReport_neitherReadNorDeleted() {
    local row name earlier puppeteer rc written last called left kept expected ran
    local stale='{"mode":"flag-on","holder":{"username":"pi-e2e-1600000000-holder"}}'
    local fresh='{"mode":"flag-on","holder":{"username":"pi-e2e-1700000000-holder"}}'
    # e2e.sh's fail counts in the global failed, so no local here may take that name.
    local exited="FAIL step 11 browser flag-on: exit code 1 (1: a check failed, 2: a usage or"
    exited+=" fixture error); see @RUN@/browser-flag-on.log and @EVIDENCE@"
    # The earlier run's report sits in the --evidence-dir parent, beside this run's directory.
    # name|earlier report|puppeteer|node exit|report node writes|last line|node run|this run's
    # report after|earlier report after
    local -a rows=(
        "no earlier report||1|0|$fresh|PASS step 11 browser flag-on|yes|$fresh|absent"
        "earlier report, check writes its own|$stale|1|0|$fresh|PASS step 11 browser flag-on|yes|$fresh|$stale"
        "earlier report, check fails without one|$stale|1|1||$exited|yes|absent|$stale"
        "earlier report, puppeteer missing|$stale|0|0|$fresh|FAIL step 11 browser flag-on: run npm ci in src/loadgen|no|absent|$stale"
    )
    for row in "${rows[@]}"; do
        IFS='|' read -r name earlier puppeteer rc written last called left kept <<<"$row"
        new_run
        evidence_in_parent "$earlier"
        NODE_OUTPUT=""
        NODE_RC="$rc"
        NODE_REPORT="$written"
        browser_check flag-on "$puppeteer"
        expected="${last//@RUN@/$RUN_DIR}"
        row_is "$name: last line" "$(last_line "$CASE_DIR/out")" \
            "${expected//@EVIDENCE@/$EVIDENCE_DIR}"
        ran="no"
        if [[ -f "$CASE_DIR/node-call" ]]; then
            ran="yes"
        fi
        row_is "$name: browser check run" "$ran" "$called"
        row_is "$name: this run's report after" \
            "$(report_state "$EVIDENCE_DIR/portfolio-insights-page-check-flag-on.json")" "$left"
        row_is "$name: earlier report after" "$(report_state "$EARLIER_REPORT")" "$kept"
    done
    NODE_RC=0
    NODE_REPORT=""
    conclude "runBrowserCheck_earlierReport_neitherReadNorDeleted"
}

# ---------------------------------------------------------------------------------------------
# Step 12: acknowledging an untriggered alert, and the browser's acknowledgement

STEP12_ID="dddddddd-0000-4000-8000-00000000000d"
STEP12_INSTRUMENT="eeeeeeee-0000-4000-8000-00000000000e"
STEP12_PAIR_ID="cccccccc-0000-4000-8000-00000000000c"
STEP12_DISABLED="step 12 disabled untriggered alert"
STEP12_UNCHANGED="step 12 acknowledge leaves an untriggered alert unchanged"
STEP12_PERSISTED="step 12 browser acknowledgement persisted"
STEP12_METHODS=""

# step12_row FILTER: the step-12 alert as a listing shows it once disabled, through the jq
# FILTER; "." keeps it as it is.
step12_row() {
    jq -cn --arg id "$STEP12_ID" --arg account "$TEST_ACCOUNT" --arg instrument "$STEP12_INSTRUMENT" \
        '{id: $id, accountId: $account, type: "TARGET_PRICE", instrumentId: $instrument,
          direction: "ABOVE", threshold: 9999999999.99999999, enabled: false, armingRevision: 1,
          triggeredAt: null, triggerValue: null, acknowledged: false,
          createdAt: "2026-11-25T10:00:00Z"}' | jq -c "$1" | tr -d '\r'
}

# step12_listing FILTER: a listing of the holder's alerts that holds only step12_row FILTER.
step12_listing() {
    printf '{"results":[%s]}' "$(step12_row "$1")"
}

# step12_state: a fresh case in the run state step 12 starts from: the pair alerts ready, the
# holder signed up, and the four pair alerts of step 9 in $RUN_DIR/pairs, one of them by an id
# whose uppercase form is ID_UPPER.
step12_state() {
    new_run
    PAIRS_READY=1
    HOLDER_ID="$TEST_ACCOUNT"
    HOLDER_USER="pi-e2e-1700000000-holder"
    H1="$STEP12_INSTRUMENT"
    printf '%s\n' "$ID_A target_price TARGET_PRICE ABOVE 1.49999999" \
        "$ID_LOWER target_price TARGET_PRICE BELOW 1.50000001" \
        "$ID_B profit_loss PROFIT_LOSS ABOVE -0.00000001" \
        "$STEP12_PAIR_ID profit_loss PROFIT_LOSS BELOW 0.00000001" >"$RUN_DIR/pairs"
}

# step12_run PATCH BEFORE_STATUS BEFORE_BODY AFTER_STATUS AFTER_BODY [CHECK_STATUS CHECK_BODY]:
# runs step12_untriggered_ack against a 201 for its create, PATCH for its PATCH (an empty body:
# the step reads none), BEFORE_* for the listing of the disabled row, asked only after a 200
# PATCH, a 204 for the acknowledge, AFTER_* for the listing after it and CHECK_* for the listing
# that checks the browser's acknowledgement. Its PASS and FAIL lines go to $CASE_DIR/verdicts,
# and the methods of its requests, in order, to STEP12_METHODS.
step12_run() {
    local line
    respond 201 application/json "$(step12_row .)"
    respond "$1" application/json ""
    if [[ "$1" == "200" ]]; then
        respond "$2" application/json "$3"
    fi
    respond 204 "" ""
    respond "$4" application/json "$5"
    if [[ $# -ge 7 ]]; then
        respond "$6" application/json "$7"
    fi
    step12_untriggered_ack >"$CASE_DIR/out"
    verdicts "$CASE_DIR/out" >"$CASE_DIR/verdicts"
    STEP12_METHODS=""
    while IFS= read -r line; do
        STEP12_METHODS="${STEP12_METHODS:+$STEP12_METHODS }${line%% *}"
    done <"$CASE_DIR/requests"
}

# step12_verdict CHECK REASON: the line e2e.sh prints for CHECK: PASS when REASON is "ok",
# otherwise FAIL with REASON.
step12_verdict() {
    if [[ "$2" == "ok" ]]; then
        echo "PASS $1"
    else
        echo "FAIL $1: $2"
    fi
}

test_step12UntriggeredAck_listings_passOnlyUnchangedUntriggeredRow() {
    local row name patch before_status before_body after_status after_body methods
    local disabled unchanged expected good
    local unready="no disabled, untriggered row to compare"
    local patched="PATCH {\"enabled\":false} gave status 500"
    local compared="POST PATCH GET POST GET" uncompared="POST PATCH GET POST"
    good="$(step12_listing .)"
    # name|PATCH|before status|before body|after status|after body|methods|disabled|unchanged
    local -a rows=(
        "unchanged untriggered row|200|200|$good|200|$good|$compared|ok|ok"
        "PATCH refused|500|||200|$good|POST PATCH POST|$patched; body [empty]|$unready: $patched"
        "listing before answers 500|200|500|$good|200|$good|$uncompared|the listing gave status 500, expected 200|$unready: the listing gave status 500, expected 200"
        "listing before without results|200|200|{\"items\":[$(step12_row .)]}|200|$good|$uncompared|the listing has no results array|$unready: the listing has no results array"
        "listing before without the alert|200|200|{\"results\":[]}|200|$good|$uncompared|the listing does not list the alert|$unready: the listing does not list the alert"
        "triggeredAt absent|200|200|$(step12_listing 'del(.triggeredAt)')|200|$good|$uncompared|triggeredAt is absent, expected null|$unready: triggeredAt is absent, expected null"
        "triggerValue absent|200|200|$(step12_listing 'del(.triggerValue)')|200|$good|$uncompared|triggerValue is absent, expected null|$unready: triggerValue is absent, expected null"
        "triggeredAt set|200|200|$(step12_listing '.triggeredAt = "2026-11-25T10:01:00Z"')|200|$good|$uncompared|triggeredAt is a string, expected null|$unready: triggeredAt is a string, expected null"
        "acknowledged before|200|200|$(step12_listing '.acknowledged = true')|200|$good|$uncompared|acknowledged is true, expected false|$unready: acknowledged is true, expected false"
        "enabled true|200|200|$(step12_listing '.enabled = true')|200|$good|$uncompared|enabled is true, expected false|$unready: enabled is true, expected false"
        "enabled the string false|200|200|$(step12_listing '.enabled = "false"')|200|$good|$uncompared|enabled is a string, expected false|$unready: enabled is a string, expected false"
        "listing after answers 500 with the same row|200|200|$good|500|$good|$compared|ok|the listing after acknowledging gave status 500, expected 200"
        "listing after without results|200|200|$good|200|{\"items\":[$(step12_row .)]}|$compared|ok|after acknowledging, the listing has no results array"
        "row acknowledged after|200|200|$good|200|$(step12_listing '.acknowledged = true')|$compared|ok|acknowledging changed the row: acknowledged"
    )
    for row in "${rows[@]}"; do
        IFS='|' read -r name patch before_status before_body after_status after_body methods \
            disabled unchanged <<<"$row"
        step12_state
        step12_run "$patch" "$before_status" "$before_body" "$after_status" "$after_body"
        expected="$(step12_verdict "$STEP12_DISABLED" "$disabled")"
        expected+=$'\n'"$(step12_verdict "$STEP12_UNCHANGED" "$unchanged")"
        expected+=$'\n'"FAIL $STEP12_PERSISTED: evidence file"
        expected+=" $EVIDENCE_DIR/portfolio-insights-page-check-flag-on.json is missing"
        row_is "$name: verdicts" "$(file_text "$CASE_DIR/verdicts")" "$expected"
        row_is "$name: requests" "$STEP12_METHODS" "$methods"
    done
    conclude "step12UntriggeredAck_listings_passOnlyUnchangedUntriggeredRow"
}

# A jq that records its command lines, for the changed-row case, which puts its directory first
# on PATH: it appends each of its arguments, one per line, to $CASE_DIR/jq.argv, then runs the
# real jq. The process list shows a jq's arguments, so no response row may be one of them.
REAL_JQ="$(command -v jq)"
export REAL_JQ
mkdir "$TEST_TMP/argv-jq"
cat >"$TEST_TMP/argv-jq/jq" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$CASE_DIR/jq.argv"
exec "$REAL_JQ" "$@"
EOF
chmod +x "$TEST_TMP/argv-jq/jq"

test_step12UntriggeredAck_changedRow_namesFieldsWithoutRowsInJqArguments() {
    local row name before_body after_body unchanged expected argv path="$PATH"
    local marker="argv-marker-5c1f0e" changed="acknowledging changed the row"
    # Each row carries the marker in a key AlertDTO does not have, and some in AlertDTO fields.
    # name|before body|after body|unchanged
    local -a rows=(
        "a known and an unexpected field changed|$(step12_listing .)|$(step12_listing ".createdAt = \"$marker\" | .note = \"$marker\"")|$changed: createdAt, 1 other key"
        "a known field changed beside a kept key|$(step12_listing ".note = \"$marker\"")|$(step12_listing ".note = \"$marker\" | .acknowledged = true")|$changed: acknowledged"
        "known fields and other keys changed|$(step12_listing ".note = \"$marker\"")|$(step12_listing "del(.direction) | .note = \"$marker-after\" | .extra = \"$marker\" | .triggerValue = \"$marker\"")|$changed: direction, triggerValue, 2 other keys"
        "a number written differently beside a kept key|$(step12_listing ".note = \"$marker\"")|$(step12_listing ".note = \"$marker\" | .threshold = 9999999999.999999990")|$changed: a number is written differently"
    )
    for row in "${rows[@]}"; do
        IFS='|' read -r name before_body after_body unchanged <<<"$row"
        step12_state
        : >"$CASE_DIR/jq.argv"
        PATH="$TEST_TMP/argv-jq:$path"
        step12_run 200 200 "$before_body" 200 "$after_body"
        PATH="$path"
        expected="PASS $STEP12_DISABLED"$'\n'"FAIL $STEP12_UNCHANGED: $unchanged"
        expected+=$'\n'"FAIL $STEP12_PERSISTED: evidence file"
        expected+=" $EVIDENCE_DIR/portfolio-insights-page-check-flag-on.json is missing"
        row_is "$name: verdicts" "$(file_text "$CASE_DIR/verdicts")" "$expected"
        row_is "$name: requests" "$STEP12_METHODS" "POST PATCH GET POST GET"
        argv="$(file_text "$CASE_DIR/jq.argv")"
        # Only the changed-row diagnostic's filter says "other key".
        if [[ "$argv" != *" other key"* ]]; then
            reasons+=("$name: the changed-row diagnostic did not run through the recording jq")
        fi
        if [[ "$argv" == *"$marker"* ]]; then
            reasons+=("$name: a listed row reached a jq command line")
        fi
    done
    conclude "step12UntriggeredAck_changedRow_namesFieldsWithoutRowsInJqArguments"
}

# step12_report FILTER: the flag-on report of this run's browser check, through the jq FILTER:
# this run's holder, and the acknowledgement of the pair alert ID_LOWER under revision 2.
step12_report() {
    jq -cn --arg account "$TEST_ACCOUNT" --arg acknowledged "$ID_LOWER" \
        '{mode: "flag-on", baseUrl: "http://e2e-test.invalid:8080",
          startedAt: "2026-11-25T10:00:00.000Z",
          holder: {username: "pi-e2e-1700000000-holder", accountId: $account},
          acknowledged: {id: $acknowledged, armingRevision: 2}}' | jq -c "$1" | tr -d '\r'
}

# step12_acknowledged_listing FILTER: the holder's alerts once the browser acknowledged
# ID_LOWER, listed under its uppercase form ID_UPPER and changed by the jq FILTER, after the
# step-12 alert.
step12_acknowledged_listing() {
    printf '{"results":[%s,%s]}' "$(step12_row .)" "$(jq -cn --arg id "$ID_UPPER" \
        --arg account "$TEST_ACCOUNT" --arg instrument "$STEP12_INSTRUMENT" \
        '{id: $id, accountId: $account, type: "TARGET_PRICE", instrumentId: $instrument,
          direction: "BELOW", threshold: 1.50000001, enabled: true, armingRevision: 2,
          triggeredAt: "2026-11-25T10:02:00Z", triggerValue: 1.5, acknowledged: true,
          createdAt: "2026-11-25T09:59:00Z"}' | jq -c "$1" | tr -d '\r')"
}

test_step12UntriggeredAck_browserReport_acceptsOnlyThisRunsAcknowledgement() {
    local row name via rc report status listing methods persisted expected good acked stale fresh
    local in_report="evidence file @E@" alert="alert [$ID_LOWER]"
    local checked="POST PATCH GET POST GET GET" unchecked="POST PATCH GET POST GET"
    local revision="its acknowledged.armingRevision is not an integer from 1 to 2147483647"
    good="$(step12_listing .)"
    acked="$(step12_acknowledged_listing .)"
    fresh="$(step12_report .)"
    # An earlier run's report: another fresh holder, who acknowledged an alert of its own.
    stale="$(step12_report ".holder = {username: \"pi-e2e-1600000000-holder\", accountId: \"$ID_B\"}
        | .acknowledged.id = \"$ID_A\"")"
    # name|via|node exit|report|listing status|listing body|methods|persisted
    # via "file": the report is in the evidence directory as step 12 starts ("none": no file).
    # via "check": the earlier run's report is in the --evidence-dir parent of this run's own
    # evidence directory, then run_browser_check runs a check that writes the report given (""
    # writes none) and exits with the node exit given.
    local -a rows=(
        "this run's report|file|0|$fresh|200|$acked|$checked|ok"
        "holder id in uppercase|file|0|$(step12_report '.holder.accountId |= ascii_upcase')|200|$acked|$checked|ok"
        "acknowledged id in uppercase|file|0|$(step12_report ".acknowledged.id = \"$ID_UPPER\"")|200|$acked|$checked|ok"
        "no report|file|0|none|200|$acked|$unchecked|evidence file @E@ is missing"
        "another holder's id|file|0|$(step12_report ".holder.accountId = \"$ID_B\"")|200|$acked|$unchecked|$in_report: its holder.accountId is not the holder of this run"
        "another holder's username|file|0|$(step12_report '.holder.username = "pi-e2e-1600000000-holder"')|200|$acked|$unchecked|$in_report: its holder.username is not the holder of this run"
        "flag-off report|file|0|$(step12_report '.mode = "flag-off"')|200|$acked|$unchecked|$in_report: its mode is not flag-on"
        "no acknowledgement|file|0|$(step12_report '.acknowledged = null')|200|$acked|$unchecked|$in_report: its acknowledged is not an object: the check acknowledged no alert"
        "acknowledged id outside the pairs|file|0|$(step12_report ".acknowledged.id = \"$STEP12_ID\"")|200|$acked|$unchecked|$in_report: its acknowledged.id is not one of the pair alerts of this run"
        "revision a string|file|0|$(step12_report '.acknowledged.armingRevision = "2"')|200|$acked|$unchecked|$in_report: $revision"
        "revision fractional|file|0|$(step12_report '.acknowledged.armingRevision = 2.5')|200|$acked|$unchecked|$in_report: $revision"
        "two reports in one file|file|0|$fresh $fresh|200|$acked|$unchecked|$in_report: it is not one JSON object"
        "report not JSON|file|0|{\"mode\":|200|$acked|$unchecked|$in_report: it is not JSON"
        "listing answers 500|file|0|$fresh|500|$acked|$checked|the listing gave status 500, expected 200"
        "listing without results|file|0|$fresh|200|{\"items\":[]}|$checked|$alert: the listing has no results array"
        "acknowledged alert not listed|file|0|$fresh|200|$good|$checked|$alert: the listing does not list the alert"
        "acknowledged the string true|file|0|$fresh|200|$(step12_acknowledged_listing '.acknowledged = "true"')|$checked|$alert: acknowledged is a string, expected true"
        "acknowledged false|file|0|$fresh|200|$(step12_acknowledged_listing '.acknowledged = false')|$checked|$alert: acknowledged is false, expected true"
        "revision moved on|file|0|$fresh|200|$(step12_acknowledged_listing '.armingRevision = 3')|$checked|$alert: armingRevision is 3, expected 2"
        "earlier run's report, check fails without one|check|1||200|$acked|$unchecked|evidence file @E@ is missing"
        "earlier run's report, check writes this run's|check|0|$fresh|200|$acked|$checked|ok"
    )
    for row in "${rows[@]}"; do
        IFS='|' read -r name via rc report status listing methods persisted <<<"$row"
        step12_state
        evidence="$EVIDENCE_DIR/portfolio-insights-page-check-flag-on.json"
        if [[ "$via" == "check" ]]; then
            evidence_in_parent "$stale"
            evidence="$EVIDENCE_DIR/portfolio-insights-page-check-flag-on.json"
            NODE_OUTPUT=""
            NODE_RC="$rc"
            NODE_REPORT="$report"
            browser_check flag-on 1
        elif [[ "$report" != "none" ]]; then
            printf '%s\n' "$report" >"$evidence"
        fi
        step12_run 200 200 "$good" 200 "$good" "$status" "$listing"
        expected="PASS $STEP12_DISABLED"$'\n'"PASS $STEP12_UNCHANGED"$'\n'
        expected+="$(step12_verdict "$STEP12_PERSISTED" "${persisted//@E@/$evidence}")"
        row_is "$name: verdicts" "$(file_text "$CASE_DIR/verdicts")" "$expected"
        row_is "$name: requests" "$STEP12_METHODS" "$methods"
    done
    NODE_RC=0
    NODE_REPORT=""
    conclude "step12UntriggeredAck_browserReport_acceptsOnlyThisRunsAcknowledgement"
}

# ---------------------------------------------------------------------------------------------
# Response oracles

# Whatever curl prints, the reason is fixed by its exit status, and curl's own bytes stay in
# $PRIVATE_DIR/curl-error.
test_http_transportError_reportsStatus000WithFixedReason() {
    local row name stderr code expected status
    local debug="WARNING: this libcurl is Debug-enabled, do not use in production"
    local private="/tmp/pi-e2e-private.Ab12Cd/body"
    local -a rows=(
        "empty curl stderr||7|curl exit 7: could not connect"
        "only a Debug-enabled line|$debug\\n|7|curl exit 7: could not connect"
        "a message|curl: (7) $CONNECT_ERROR\\n|7|curl exit 7: could not connect"
        "a multi-line message with a private path|curl: (23) Failure writing output to destination, passed 5 returned 0\\ncurl: (23) $private\\n|23|curl exit 23: could not write the response locally"
        "a Debug-enabled line, then a CRLF message|$debug\\r\\ncurl: (28) timed out\\r\\n|28|curl exit 28: timed out"
        "unresolvable host|curl: (6) Could not resolve host: e2e-test.invalid\\n|6|curl exit 6: could not resolve the host"
        "unreadable request body|curl: (26) read error\\n|26|curl exit 26: could not read the request body"
        "TLS connect error|curl: (35) schannel: failed\\n|35|curl exit 35: TLS connection failed"
        "empty reply|curl: (52) Empty reply from server\\n|52|curl exit 52: empty reply from the server"
        "send failure|curl: (55) Send failure\\n|55|curl exit 55: could not send the request"
        "receive failure|curl: (56) Recv failure\\n|56|curl exit 56: could not receive the response"
        "untrusted certificate|curl: (60) SSL certificate problem\\n|60|curl exit 60: TLS certificate not trusted"
        "an exit status without a named reason|curl: (3) URL rejected\\n|3|curl exit 3"
    )
    for row in "${rows[@]}"; do
        IFS='|' read -r name stderr code expected <<<"$row"
        new_run
        # The subshell keeps errexit on, as e2e.sh runs http: a failing pipeline in http ends it
        # before its last line prints.
        set +e
        (
            set -e
            # shellcheck disable=SC2317,SC2329 # Invoked by http.
            curl() {
                printf '%b' "$stderr" >&2
                return "$code"
            }
            http GET "$INSIGHTS_URL/$TEST_ACCOUNT"
            printf '%s|%s|%s|still running' "$HTTP_STATUS" "$HTTP_CTYPE" "$HTTP_ERROR"
        ) >"$CASE_DIR/out" 2>"$CASE_DIR/err"
        status=$?
        set -e
        row_is "$name" "$status|$(file_text "$CASE_DIR/out")" "0|000||$expected|still running"
        if ! printf '%b' "$stderr" | cmp -s - "$PRIVATE_DIR/curl-error"; then
            reasons+=("$name: $PRIVATE_DIR/curl-error does not hold curl's own message")
        fi
    done
    conclude "http_transportError_reportsStatus000WithFixedReason"
}

test_http_pollDeadline_boundsRequestOrSendsNothing() {
    local row name left expected
    local sent="status 200, error [], body [{}], files [{}]"
    local unsent="status 000, error [not sent: no time left before the poll deadline], body [], files []"
    # name|seconds left to PROBE_DEADLINE, empty outside a poll|requests and what http leaves
    local -a rows=(
        "outside a poll||--max-time 15; $sent"
        "deadline far ahead|100|--max-time 15; $sent"
        "15 s left|15|--max-time 15; $sent"
        "14 s left|14|--max-time 14; $sent"
        "1 s left|1|--max-time 1; $sent"
        "no time left|0|; $unsent"
        "deadline passed|-5|; $unsent"
    )
    for row in "${rows[@]}"; do
        IFS='|' read -r name left expected <<<"$row"
        new_run
        printf 'stale' >"$PRIVATE_DIR/body"
        printf 'stale' >"$PRIVATE_DIR/headers"
        (
            # shellcheck disable=SC2317,SC2329 # Invoked by http.
            curl() {
                local max="" body_file=""
                while [[ $# -gt 0 ]]; do
                    case "$1" in
                        --max-time)
                            max="$2"
                            shift 2
                            ;;
                        -o)
                            body_file="$2"
                            shift 2
                            ;;
                        -D | -X | -w | -H) shift 2 ;;
                        *) shift ;;
                    esac
                done
                echo "--max-time $max" >>"$CASE_DIR/requests"
                printf '{}' >"$body_file"
                printf '200 application/json'
            }
            PROBE_DEADLINE=""
            if [[ -n "$left" ]]; then
                PROBE_DEADLINE=$((FAKE_NOW + left))
            fi
            http GET "$INSIGHTS_URL/$TEST_ACCOUNT"
            printf 'status %s, error [%s], body [%s], files [%s]' "$HTTP_STATUS" "$HTTP_ERROR" \
                "$HTTP_BODY" "$(file_text "$PRIVATE_DIR/body")$(file_text "$PRIVATE_DIR/headers")"
        ) >"$CASE_DIR/out"
        row_is "$name" "$(file_text "$CASE_DIR/requests"); $(file_text "$CASE_DIR/out")" "$expected"
    done
    conclude "http_pollDeadline_boundsRequestOrSendsNothing"
}

test_expectForbidden_response_passesOnlyExact403() {
    local row name status ctype body expected shown
    # name|status|content type|body|PASS or FAIL|for a FAIL, the media type its reason shows
    local -a rows=(
        "exact|403|application/json; charset=utf-8|{\"error\":\"feature_disabled\"}|PASS"
        "exact, bare type|403|application/json|{\"error\":\"feature_disabled\"}|PASS"
        "exact, mixed case and blanks|403| Application/JSON ; charset=utf-8|{\"error\":\"feature_disabled\"}|PASS"
        "json padding type|403|application/jsonp|{\"error\":\"feature_disabled\"}|FAIL|application/jsonp"
        "json sequence type|403|application/json-seq; charset=utf-8|{\"error\":\"feature_disabled\"}|FAIL|application/json-seq"
        "trailing newline|403|application/json|{\"error\":\"feature_disabled\"}\\n|FAIL"
        "space after colon|403|application/json|{\"error\": \"feature_disabled\"}|FAIL"
        "leading space|403|application/json| {\"error\":\"feature_disabled\"}|FAIL"
        "other error|403|application/json|{\"error\":\"forbidden\"}|FAIL"
        "problem json|403|application/problem+json|{\"error\":\"feature_disabled\"}|FAIL"
        "text/plain|403|text/plain|{\"error\":\"feature_disabled\"}|FAIL"
        "no content type|403||{\"error\":\"feature_disabled\"}|FAIL"
        "status 200|200|application/json|{\"error\":\"feature_disabled\"}|FAIL"
        "status 404|404|application/json|{\"error\":\"feature_disabled\"}|FAIL"
        "transport error|000||$CONNECT_ERROR|FAIL"
    )
    for row in "${rows[@]}"; do
        IFS='|' read -r name status ctype body expected shown <<<"$row"
        new_run
        respond "$status" "$ctype" "$body"
        expect_forbidden "$name" GET "$INSIGHTS_URL/$TEST_ACCOUNT" >"$CASE_DIR/out"
        if [[ "$expected" == "PASS" ]]; then
            row_is "$name" "$(file_text "$CASE_DIR/out")" "PASS $name"
        elif [[ "$(file_text "$CASE_DIR/out")" != "FAIL $name: "* ]]; then
            reasons+=("$name: got [$(file_text "$CASE_DIR/out")], expected a FAIL line")
        elif [[ -n "$shown" && "$(file_text "$CASE_DIR/out")" != *", content type [$shown], "* ]]; then
            reasons+=("$name: got [$(file_text "$CASE_DIR/out")], expected content type [$shown]")
        fi
    done
    conclude "expectForbidden_response_passesOnlyExact403"
}

test_expectForbidden_createdInstead_failsAndOwnsId() {
    local verdict
    new_run
    respond 201 "application/json" "{\"id\":\"$ID_UPPER\"}"
    expect_forbidden "POST accepted" POST "$ALERTS_URL" '{"threshold":1}' >"$CASE_DIR/out"
    verdict="$(first_line "$CASE_DIR/out")"
    row_is "verdict and owned ids" "${verdict%%,*}|$(file_text "$RUN_DIR/owned")" \
        "FAIL POST accepted: status 201|$ID_LOWER"
    conclude "expectForbidden_createdInstead_failsAndOwnsId"
}

# Only a POST to /v1/alerts is a create: its uncertain outcome is journaled, and an interrupt
# during it is held until then. A lost GET, PATCH, DELETE or acknowledge journals nothing.
test_expectForbidden_postUncertain_heldAndJournaled() {
    local row method url journaled status
    local body="{\"accountId\":\"$TEST_ACCOUNT\",\"threshold\":1}"
    local -a rows=(
        "POST|$ALERTS_URL|$TEST_ACCOUNT unsettled"
        "GET|$ALERTS_URL?accountId=$TEST_ACCOUNT|"
        "PATCH|$ALERTS_URL/$ID_A|"
        "DELETE|$ALERTS_URL/$ID_A|"
        "POST|$ALERTS_URL/$ID_A/acknowledge|"
    )
    for row in "${rows[@]}"; do
        IFS='|' read -r method url journaled <<<"$row"
        new_run
        respond 000 "" "$CONNECT_ERROR"
        if [[ "$method" == "GET" || "$method" == "DELETE" || "$url" == */acknowledge ]]; then
            expect_forbidden "lost" "$method" "$url" >"$CASE_DIR/out"
        else
            expect_forbidden "lost" "$method" "$url" "$body" >"$CASE_DIR/out"
        fi
        row_is "$method $url: verdict and journal" \
            "$(first_line "$CASE_DIR/out" | cut -c1-10)|$(file_text "$RUN_DIR/uncertain-creates")" \
            "FAIL lost:|$journaled"
    done

    new_run
    respond 000 "" "$CONNECT_ERROR"
    status=0
    (
        trap on_signal TERM
        interrupt_when_answered
        expect_forbidden "interrupted" POST "$ALERTS_URL" "$body"
        echo "continued"
    ) >"$CASE_DIR/out" 2>&1 || status=$?
    row_is "interrupt during the POST: status, journal, continued" \
        "$status|$(file_text "$RUN_DIR/uncertain-creates")|$(has_line "$CASE_DIR/out" continued && echo yes)" \
        "130|$TEST_ACCOUNT unsettled|"
    conclude "expectForbidden_postUncertain_heldAndJournaled"
}

test_jcheck_verdict_passesOnlyOk() {
    local filter='if .a == 1 then "ok" else "a is \(.a)" end'
    new_run
    row_is "ok" "$(jcheck "check" "$filter" '{"a":1}')" "PASS check"
    row_is "reason" "$(jcheck "check" "$filter" '{"a":2}')" "FAIL check: a is 2"
    row_is "not JSON" "$(jcheck "check" "$filter" 'not json')" \
        "FAIL check: unreadable JSON [8 bytes, not JSON]"
    row_is "empty" "$(jcheck "check" "$filter" '')" "FAIL check: unreadable JSON [empty]"
    row_is "ok then garbage" "$(jcheck "check" "$filter" '{"a":1}garbage')" \
        "FAIL check: unreadable JSON [14 bytes, not JSON]"
    row_is "ok twice" "$(jcheck "check" "$filter" '{"a":1}{"a":1}')" \
        "FAIL check: unreadable JSON [14 bytes, not JSON]"
    conclude "jcheck_verdict_passesOnlyOk"
}

test_jitemJcount_mixedCaseIds_matchLowercaseId() {
    local list="{\"results\":[{\"id\":\"$ID_UPPER\",\"enabled\":true,\"armingRevision\":2},"
    list+="{\"id\":\"$ID_LOWER\",\"armingRevision\":3},{\"id\":null}]}"
    new_run
    row_is "count" "$(jcount "$ID_LOWER" "$list")" "2"
    row_is "first item's field" "$(jitem "$ID_LOWER" "$list" '.armingRevision')" "2"
    row_is "first item, keys sorted" "$(jitem "$ID_LOWER" "$list")" \
        "{\"armingRevision\":2,\"enabled\":true,\"id\":\"$ID_UPPER\"}"
    row_is "unknown id count" "$(jcount "$ID_A" "$list")" "0"
    row_is "unknown id item" "$(jitem "$ID_A" "$list")" ""
    row_is "not JSON count" "$(jcount "$ID_LOWER" 'not json')" ""
    conclude "jitemJcount_mixedCaseIds_matchLowercaseId"
}

# Each row: an input and what jget (a filter beginning with def and ending with a comment),
# jitem and jcount print for it, joined by "|". Only exactly one complete JSON document, with
# or without whitespace after it, has figures.
test_jgetJitemJcount_input_printOnlyForOneDocument() {
    local list="{\"results\":[{\"id\":\"$ID_UPPER\",\"armingRevision\":2}]}" k input actual
    local -a names=(oneDocument oneDocumentThenWhitespace documentThenGarbage twoDocuments empty
        notJson)
    local -a inputs=("$list" "$list"$' \n\t\n' "${list}garbage" "$list$list" "" "not json")
    local -a expected=("array|2|1" "array|2|1" "||" "||" "||" "||")
    new_run
    for k in "${!names[@]}"; do
        input="${inputs[$k]}"
        actual="$(jget 'def kind: .results | type; kind # the type' "$input")"
        actual+="|$(jitem "$ID_LOWER" "$input" '.armingRevision')|$(jcount "$ID_LOWER" "$input")"
        row_is "${names[$k]}" "$actual" "${expected[$k]}"
    done
    row_is "filter fails after output" \
        "$(jget '.results[] | if . == 2 then error("two") else . end' '{"results":[1,2]}')" ""
    conclude "jgetJitemJcount_input_printOnlyForOneDocument"
}

test_randomGuid_generated_matchUuidPattern() {
    local guid k
    local -a guids
    new_run
    for ((k = 0; k < 20; k++)); do
        random_guid
    done >"$CASE_DIR/guids"
    mapfile -t guids <"$CASE_DIR/guids"
    row_is "generated" "${#guids[@]}" "20"
    for guid in "${guids[@]}"; do
        if [[ ! "$guid" =~ $UUID_RE ]]; then
            reasons+=("[$guid] does not match $UUID_RE")
        fi
    done
    conclude "randomGuid_generated_matchUuidPattern"
}

# ---------------------------------------------------------------------------------------------
# Cleanup and polling

# cleanup_state FLAG_INITIAL FLAG_TOUCHED PASSED FAILED: the run state cleanup starts from.
cleanup_state() {
    FLAG_INITIAL="$1"
    FLAG_TOUCHED="$2"
    passed="$3"
    failed="$4"
    HOLDER_USER=""
    EMPTY_USER=""
}

test_cleanup_noOwnedAlerts_passesAndKeepsExitStatus() {
    local status
    for status in 0 3 130; do
        new_run
        cleanup_state true 0 0 0
        run_cleanup "$status"
        row_is "exit $status: status" "$CLEANUP_STATUS" "$status"
        row_is "exit $status: requests" "$(file_text "$CASE_DIR/requests")" ""
        if ! has_line "$CASE_DIR/out" "PASS cleanup" ||
            ! has_line "$CASE_DIR/out" "SUMMARY 1 passed, 0 failed"; then
            reasons+=("exit $status: output [$(tr '\n' ' ' <"$CASE_DIR/out")]")
        fi
    done
    conclude "cleanup_noOwnedAlerts_passesAndKeepsExitStatus"
}

test_cleanup_ownedAlerts_switchFlagOnOnlyWhileOff() {
    local body
    new_run
    cleanup_state false 0 0 0
    echo "$ID_A" >"$RUN_DIR/owned"
    respond 200 "application/json" '{"id":"portfolio-insights-enabled","enabled":false}'
    respond 200 "application/json" '{"id":"portfolio-insights-enabled","enabled":true}'
    respond 204 "" ""
    respond 200 "application/json" '{"id":"portfolio-insights-enabled","enabled":false}'
    run_cleanup 0
    row_is "flag off: status, verdict and requests" \
        "$CLEANUP_STATUS|$(verdicts "$CASE_DIR/out")|$(file_text "$CASE_DIR/requests")" \
        "0|PASS cleanup|$(printf '%s\n' "GET $F" "PUT $F {\"enabled\": true}" \
            "DELETE $ALERTS_URL/$ID_A" "PUT $F {\"enabled\": false}")"
    if ! has_line "$CASE_DIR/out" "INFO cleanup: flag $FLAG_ID switched on to delete 1 owned alerts"; then
        reasons+=("flag off: no confirmed switch-on line in [$(tr '\n' ' ' <"$CASE_DIR/out")]")
    fi

    new_run
    cleanup_state true 0 0 0
    echo "$ID_A" >"$RUN_DIR/owned"
    respond 200 "application/json" '{"id":"portfolio-insights-enabled","enabled":true}'
    respond 204 "" ""
    run_cleanup 0
    row_is "flag on: status, verdict and requests" \
        "$CLEANUP_STATUS|$(verdicts "$CASE_DIR/out")|$(file_text "$CASE_DIR/requests")" \
        "0|PASS cleanup|$(printf '%s\n' "GET $F" "DELETE $ALERTS_URL/$ID_A")"

    # Only this flag's JSON boolean false reads as off: a string "false" or another flag's state
    # switches nothing.
    for body in '{"id":"portfolio-insights-enabled","enabled":"false"}' \
        '{"id":"db_not_responding","enabled":false}'; do
        new_run
        cleanup_state false 0 0 0
        echo "$ID_A" >"$RUN_DIR/owned"
        respond 200 "application/json" "$body"
        respond 204 "" ""
        run_cleanup 0
        row_is "flag read $body: status, verdict and requests" \
            "$CLEANUP_STATUS|$(verdicts "$CASE_DIR/out")|$(file_text "$CASE_DIR/requests")" \
            "0|PASS cleanup|$(printf '%s\n' "GET $F" "DELETE $ALERTS_URL/$ID_A")"
    done
    conclude "cleanup_ownedAlerts_switchFlagOnOnlyWhileOff"
}

# A switch-on counts only as a 200 with this flag's JSON boolean true. Anything else is a cleanup
# problem of its own, naming the status or the answer's JSON types, never what the server sent;
# the DELETE still runs, its answer deciding the alert, and the flag is still restored.
test_cleanup_switchOnUnconfirmed_failsCleanupAndStillDeletes() {
    local row name status ctype body delete expected
    local unconfirmed="flag portfolio-insights-enabled could not be switched on to delete 1 owned alerts"
    local -a rows=(
        "answers 500|500|text/plain|boom|204|status 500"
        "answers another flag|200|application/json|{\"id\":\"db_not_responding\",\"enabled\":true}|204|answered [id is another string, enabled is true]"
        "answers a string true|200|application/json|{\"id\":\"portfolio-insights-enabled\",\"enabled\":\"true\"}|204|answered [id is portfolio-insights-enabled, enabled is a JSON string]"
        "leaves the flag off|200|application/json|{\"id\":\"portfolio-insights-enabled\",\"enabled\":false}|204|answered [false]"
        "answers no JSON|200|text/plain|ok|204|answered [not JSON]"
        "unreachable|000||$CONNECT_ERROR|204|transport error (curl exit 7: could not connect)"
        "answers 500, delete 403|500|text/plain|boom|403|status 500; 1 owned alerts left in place"
    )
    for row in "${rows[@]}"; do
        IFS='|' read -r name status ctype body delete expected <<<"$row"
        new_run
        cleanup_state false 0 0 0
        echo "$ID_A" >"$RUN_DIR/owned"
        respond 200 "application/json" '{"id":"portfolio-insights-enabled","enabled":false}'
        respond "$status" "$ctype" "$body"
        if [[ "$delete" == "204" ]]; then
            respond 204 "" ""
        else
            respond "$delete" "application/json" '{"error":"feature_disabled"}'
        fi
        respond 200 "application/json" '{"id":"portfolio-insights-enabled","enabled":false}'
        run_cleanup 0
        row_is "switch-on $name: status, verdict and requests" \
            "$CLEANUP_STATUS|$(verdicts "$CASE_DIR/out")|$(file_text "$CASE_DIR/requests")" \
            "1|FAIL cleanup: $unconfirmed: $expected|$(printf '%s\n' "GET $F" \
                "PUT $F {\"enabled\": true}" "DELETE $ALERTS_URL/$ID_A" "PUT $F {\"enabled\": false}")"
        if has_line "$CASE_DIR/out" "INFO cleanup: flag $FLAG_ID switched on to delete 1 owned alerts" ||
            grep -qE 'db_not_responding|boom' "$CASE_DIR/out"; then
            reasons+=("switch-on $name: output claims the switch-on or repeats server text: [$(tr '\n' ' ' <"$CASE_DIR/out")]")
        fi
    done
    conclude "cleanup_switchOnUnconfirmed_failsCleanupAndStillDeletes"
}

test_cleanup_deleteLeftInPlace_failsAndExitsOne() {
    local row status ctype body
    local -a rows=(
        "500|text/plain|boom"
        "403|application/json|{\"error\":\"feature_disabled\"}"
        "000||$CONNECT_ERROR"
    )
    for row in "${rows[@]}"; do
        IFS='|' read -r status ctype body <<<"$row"
        new_run
        cleanup_state true 0 4 0
        echo "$ID_A" >"$RUN_DIR/owned"
        respond 200 "application/json" '{"id":"portfolio-insights-enabled","enabled":true}'
        respond "$status" "$ctype" "$body"
        run_cleanup 0
        row_is "DELETE $status" \
            "$CLEANUP_STATUS|$(verdicts "$CASE_DIR/out")|$(file_text "$CASE_DIR/requests")" \
            "1|FAIL cleanup: 1 owned alerts left in place|$(printf '%s\n%s' "GET $F" \
                "DELETE $ALERTS_URL/$ID_A")"
    done
    conclude "cleanup_deleteLeftInPlace_failsAndExitsOne"
}

test_cleanup_flagNotRestored_failsCleanup() {
    local row name status body expected
    local unrestored="flag portfolio-insights-enabled not restored to enabled=false"
    local -a rows=(
        "restore answers 500|500|{}|status 500"
        "restore leaves the flag on|200|{\"id\":\"portfolio-insights-enabled\",\"enabled\":true}|status 200"
        "restore answers a string false|200|{\"id\":\"portfolio-insights-enabled\",\"enabled\":\"false\"}|status 200"
        "restore answers another flag|200|{\"id\":\"db_not_responding\",\"enabled\":false}|status 200"
        "restore unreachable|000|$CONNECT_ERROR|transport error (curl exit 7: could not connect)"
    )
    for row in "${rows[@]}"; do
        IFS='|' read -r name status body expected <<<"$row"
        new_run
        cleanup_state false 1 4 0
        respond "$status" "application/json" "$body"
        run_cleanup 0
        row_is "$name" "$CLEANUP_STATUS|$(verdicts "$CASE_DIR/out")" \
            "1|FAIL cleanup: $unrestored: $expected"
    done

    new_run
    cleanup_state false 0 4 0
    echo "$ID_A" >"$RUN_DIR/owned"
    respond 200 "application/json" '{"id":"portfolio-insights-enabled","enabled":false}'
    respond 200 "application/json" '{"id":"portfolio-insights-enabled","enabled":true}'
    respond 500 "text/plain" "boom"
    respond 500 "text/plain" "boom"
    run_cleanup 0
    row_is "alert left and flag not restored" "$CLEANUP_STATUS|$(verdicts "$CASE_DIR/out")" \
        "1|FAIL cleanup: 1 owned alerts left in place; $unrestored: status 500"
    conclude "cleanup_flagNotRestored_failsCleanup"
}

test_cleanup_earlierFailure_neverExitsZero() {
    new_run
    cleanup_state true 0 5 2
    run_cleanup 0
    row_is "exit 0 after failures" "$CLEANUP_STATUS|$(last_line "$CASE_DIR/out")" \
        "1|SUMMARY 6 passed, 2 failed"
    new_run
    cleanup_state true 0 5 2
    run_cleanup 3
    row_is "exit 3 after failures" "$CLEANUP_STATUS|$(last_line "$CASE_DIR/out")" \
        "3|SUMMARY 6 passed, 2 failed"
    conclude "cleanup_earlierFailure_neverExitsZero"
}

# shellcheck disable=SC2317,SC2329 # Invoked by delete_alert in a subshell.
# unrecordable_deletes: in the calling subshell, each DELETE http sends turns $RUN_DIR/deleted
# into a directory once it is answered, so delete_alert cannot record it.
unrecordable_deletes() {
    eval "answered_$(declare -f http)"
    http() {
        answered_http "$@"
        if [[ "$1" == "DELETE" && -f "$RUN_DIR/deleted" ]]; then
            rm -f "$RUN_DIR/deleted"
            mkdir "$RUN_DIR/deleted"
        fi
    }
}

# shellcheck disable=SC2317,SC2329 # Invoked by cleanup in a subshell.
# lost_deletes: in the calling subshell, delete_alert sends its DELETE, records nothing and
# reports success, as an append that failed unnoticed would.
lost_deletes() {
    delete_alert() {
        http DELETE "$ALERTS_URL/$1"
    }
}

# Owned A, B and A again, nothing deleted, the flag on; every DELETE answers 204.
test_cleanup_inventoryUnusable_failsAndExitsOne() {
    local fault expected requests
    local both
    both="$(printf '%s\n' "GET $F" "DELETE $ALERTS_URL/$ID_A" "DELETE $ALERTS_URL/$ID_B")"
    for fault in sort comm "owned not a file" unrecordable lost; do
        new_run
        cleanup_state true 0 0 0
        printf '%s\n' "$ID_A" "$ID_B" "$ID_A" >"$RUN_DIR/owned"
        respond 200 "application/json" '{"id":"portfolio-insights-enabled","enabled":true}'
        respond 204 "" ""
        respond 204 "" ""
        requests="$both"
        case "$fault" in
            sort | comm)
                expected="the owned-alert inventory could not be reconciled, so nothing confirms"
                expected+=" the owned alerts are gone (0 of 2 owned ids left in place)"
                ;;
            "owned not a file")
                expected="the owned alerts cannot be read from $RUN_DIR/owned: none was deleted"
                requests="GET $F"
                ;;
            unrecordable)
                expected="the owned-alert inventory could not be recomputed after the deletes"
                ;;
            lost)
                expected="the owned-alert inventory still lists 2 alerts after the deletes, 0 left"
                expected+=" in place"
                ;;
        esac
        CLEANUP_STATUS=0
        (
            case "$fault" in
                unrecordable) unrecordable_deletes ;;
                lost) lost_deletes ;;
                *) break_step "$fault" ;;
            esac
            trap cleanup EXIT
            exit 0
        ) >"$CASE_DIR/out" 2>&1 || CLEANUP_STATUS=$?
        row_is "$fault: status, verdict and requests" \
            "$CLEANUP_STATUS|$(verdicts "$CASE_DIR/out")|$(file_text "$CASE_DIR/requests")" \
            "1|FAIL cleanup: $expected|$requests"
    done
    conclude "cleanup_inventoryUnusable_failsAndExitsOne"
}

# Step 13 runs under errexit, as main runs it: a failing inventory or record is a FAIL line of its
# own, and the step goes on to its other checks.
test_step13_inventoryUnusable_failsAndContinues() {
    local fault expected status
    for fault in sort unrecordable; do
        new_run
        echo "$ID_A" >"$RUN_DIR/owned"
        respond 204 "" ""
        case "$fault" in
            sort)
                expected="the owned-alert inventory cannot be computed from $RUN_DIR/owned and"
                expected+=" $RUN_DIR/deleted, so no alert was deleted here; the exit cleanup sends a"
                expected+=" DELETE to every owned id"
                ;;
            unrecordable) expected="expected 204 each: [$ID_A] status 204, not recorded as deleted;" ;;
        esac
        set +e
        (
            set -e
            HOLDER_ID="$TEST_ACCOUNT"
            case "$fault" in
                unrecordable) unrecordable_deletes ;;
                *) break_step "$fault" ;;
            esac
            step13_cleanup_and_disable
            echo "continued"
        ) >"$CASE_DIR/out" 2>/dev/null
        status=$?
        set -e
        row_is "$fault: status, first verdict and last line" \
            "$status|$(first_line "$CASE_DIR/out")|$(last_line "$CASE_DIR/out")" \
            "0|FAIL step 13 delete owned alerts: $expected|continued"
        if [[ "$fault" == sort ]] && has_line "$CASE_DIR/requests" "DELETE $ALERTS_URL/$ID_A"; then
            reasons+=("$fault: step 13 sent a DELETE without an inventory")
        fi
    done
    conclude "step13_inventoryUnusable_failsAndContinues"
}

# shellcheck disable=SC2317,SC2329 # Invoked by the steps in a subshell.
# routed_alerts: in the calling subshell, http answers by route instead of from the queue: a
# create at the domain-maximum threshold gets 201 with ID_A, then ID_B; a DELETE gets 204; any
# other request gets a 400 ErrorResponse.
routed_alerts() {
    ROUTED_POSTS=0
    http() {
        local status=400 body='{"statusCode":400,"message":"routed"}'
        echo "$1 $2" >>"$CASE_DIR/requests"
        if [[ "$1 $2" == "POST $ALERTS_URL" && "${3-}" == *"$MAX_THRESHOLD"* ]]; then
            ROUTED_POSTS=$((ROUTED_POSTS + 1))
            status=201
            body="{\"id\":\"$ID_A\"}"
            if [[ $ROUTED_POSTS -gt 1 ]]; then
                body="{\"id\":\"$ID_B\"}"
            fi
        elif [[ "$1" == "DELETE" ]]; then
            status=204
            body=""
        fi
        HTTP_STATUS="$status"
        HTTP_CTYPE="application/json"
        HTTP_BODY="$body"
        HTTP_ERROR=""
        printf '%s' "$body" >"$PRIVATE_DIR/body"
        : >"$PRIVATE_DIR/headers"
    }
}

# A step's own DELETE that answers 204 but cannot be recorded fails that step's delete check;
# the step goes on under errexit, as main runs it.
test_stepDeletes_deletionUnrecordable_failsCheckAndContinues() {
    local step status line
    local -a expected
    for step in step7_errors step8_crud; do
        new_run
        HOLDER_ID="$TEST_ACCOUNT"
        EMPTY_ID="$ID_LOWER"
        H1="$ID_B"
        case "$step" in
            step7_errors)
                expected=("FAIL step 7 DELETE temporary alert 204: status 204 for the temporary alert [$ID_A], but its deletion could not be recorded in $RUN_DIR/deleted")
                ;;
            step8_crud)
                expected=(
                    "FAIL step 8 TARGET_PRICE delete: status 204, but the deletion could not be recorded in $RUN_DIR/deleted"
                    "FAIL step 8 PROFIT_LOSS delete: status 204, but the deletion could not be recorded in $RUN_DIR/deleted"
                )
                ;;
        esac
        set +e
        (
            set -e
            routed_alerts
            break_step "deleted not a file"
            "$step"
            echo "continued"
        ) >"$CASE_DIR/out" 2>/dev/null
        status=$?
        set -e
        row_is "$step: status and last line" "$status|$(last_line "$CASE_DIR/out")" "0|continued"
        for line in "${expected[@]}"; do
            if ! has_line "$CASE_DIR/out" "$line"; then
                reasons+=("$step: no line [$line]")
            fi
        done
    done
    conclude "stepDeletes_deletionUnrecordable_failsCheckAndContinues"
}

# Two creates on the holder, each answered with CREATES' status in turn: 201 without an id
# (settled) or a transport error (000, unsettled). The run owns ID_A. The flag starts off, so
# cleanup switches it on to list and delete, then restores it. Every listed alert bound to the
# holder, whatever the case of its accountId, is owned and deleted, so cleanup passes when both
# creates settled; an unsettled one fails it, with the listing empty or not, since it may commit
# an alert after the listing. A switch-on the PUT does not confirm is a problem of its own, named
# for the reconciliation, and the listing's problems are added to it, never put in its place.
test_cleanup_uncertainFixtureCreate_deletesListedAndFailsUnlessSettled() {
    local flag_off='{"id":"portfolio-insights-enabled","enabled":false}'
    local flag_on='{"id":"portfolio-insights-enabled","enabled":true}'
    local settlement="are unsettled (no response, or a status neither 2xx nor 4xx), so an alert"
    settlement+=" such a create may still commit after this listing cannot be ruled out"
    local refused="flag portfolio-insights-enabled could not be switched on to reconcile uncertain"
    refused+=" creates and delete owned alerts: status 500"
    local row name switch creates list deletes counts expected status upper id requests create
    upper="$(tr '[:lower:]' '[:upper:]' <<<"$TEST_ACCOUNT")"
    # name|PUT answer: on, or 500|creates|listed alerts|DELETEs|INFO counts|verdict
    local -a rows=(
        "settled|on|201 201|{\"id\":\"$ID_UPPER\",\"accountId\":\"$upper\"},{\"id\":\"$ID_A\",\"accountId\":\"$TEST_ACCOUNT\"}|$ID_A $ID_LOWER|2 alerts (status 200); 2|PASS cleanup"
        "unsettled, list empty|on|000 201||$ID_A|0 alerts (status 200); 0|FAIL cleanup: 1 uncertain creates on fixture account [$TEST_ACCOUNT] $settlement"
        "unsettled, alert listed|on|000 000|{\"id\":\"$ID_UPPER\",\"accountId\":\"$TEST_ACCOUNT\"}|$ID_A $ID_LOWER|1 alerts (status 200); 1|FAIL cleanup: 2 uncertain creates on fixture account [$TEST_ACCOUNT] $settlement"
        "unsettled, switch-on refused|500|000 201||$ID_A|0 alerts (status 200); 0|FAIL cleanup: $refused; 1 uncertain creates on fixture account [$TEST_ACCOUNT] $settlement"
    )
    for row in "${rows[@]}"; do
        IFS='|' read -r name switch creates list deletes counts expected <<<"$row"
        new_run
        cleanup_state false 0 0 0
        HOLDER_ID="$TEST_ACCOUNT"
        EMPTY_ID="$ID_B"
        for create in $creates; do
            if [[ "$create" == "000" ]]; then
                respond 000 "" "$CONNECT_ERROR"
            else
                respond "$create" "application/json" "{}"
            fi
            post_alert "$TEST_ACCOUNT" TARGET_PRICE "$ID_B" ABOVE 1 2>/dev/null || true
        done
        # The creates' requests are not under test here: the log and queue start over.
        : >"$CASE_DIR/requests"
        : >"$CASE_DIR/responses"
        echo "$ID_A" >"$RUN_DIR/owned"
        respond 200 "application/json" "$flag_off"
        if [[ "$switch" == "on" ]]; then
            respond 200 "application/json" "$flag_on"
        else
            respond "$switch" "text/plain" "boom"
        fi
        respond 200 "application/json; charset=utf-8" "{\"results\":[$list]}"
        requests="$(printf '%s\n' "GET $F" "PUT $F {\"enabled\": true}" \
            "GET $ALERTS_URL?accountId=$TEST_ACCOUNT")"
        for id in $deletes; do
            respond 204 "" ""
            requests+=$'\n'"DELETE $ALERTS_URL/$id"
        done
        respond 200 "application/json" "$flag_off"
        requests+=$'\n'"PUT $F {\"enabled\": false}"
        status=1
        if [[ "$expected" == "PASS cleanup" ]]; then
            status=0
        fi
        run_cleanup 0
        row_is "$name: status, verdict and requests" \
            "$CLEANUP_STATUS|$(verdicts "$CASE_DIR/out")|$(file_text "$CASE_DIR/requests")" \
            "$status|$expected|$requests"
        if ! has_line "$CASE_DIR/out" \
            "INFO cleanup: fixture account [$TEST_ACCOUNT] lists $counts owned for deletion"; then
            reasons+=("$name: no INFO line reports the reconciliation: [$(file_text "$CASE_DIR/out")]")
        fi
    done
    conclude "cleanup_uncertainFixtureCreate_deletesListedAndFailsUnlessSettled"
}

# The holder is TEST_ACCOUNT and the empty account ID_B; OTHER is neither. Each row journals one
# create, settled or unsettled. The flag is on and nothing is owned, so the only requests are
# the flag read and the list, never a DELETE, and no listed alert becomes owned: a listing that
# is no single valid document, a fixture alert bound to another account and any alert on
# another account all fail the check instead. On another account a 404 ErrorResponse settles
# any create, and an empty list only a settled one; a line without its state counts as unsettled.
test_cleanup_uncertainCreate_settlesByAccountNeverDeletingOthers() {
    local name journal status ctype body expected requests
    local other="cccccccc-0000-4000-8000-00000000000c" undetermined="ownership cannot be determined"
    local listing="200 with one JSON object whose results array holds only objects with a string id"
    listing+=" and a string accountId"
    local -a rows=(
        "fixture list fails|$ID_B settled|500|text/plain|boom"
        "fixture list without results|$ID_B settled|200|application/json|{\"results\":{}}"
        "fixture list forbidden|$ID_B settled|403|application/json|$FORBIDDEN_BODY"
        "fixture list with trailing text|$TEST_ACCOUNT settled|200|application/json|{\"results\":[{\"id\":\"$ID_A\",\"accountId\":\"$TEST_ACCOUNT\"}]} trailing"
        "fixture list of two documents|$TEST_ACCOUNT settled|200|application/json|{\"results\":[]}\n{\"results\":[{\"id\":\"$ID_A\",\"accountId\":\"$TEST_ACCOUNT\"}]}"
        "fixture items without string id and accountId|$TEST_ACCOUNT settled|200|application/json|{\"results\":[{\"id\":\"$ID_A\"},{\"id\":5,\"accountId\":\"$TEST_ACCOUNT\"},7]}"
        "fixture ids not canonical|$TEST_ACCOUNT settled|200|application/json|{\"results\":[{\"id\":\"x\",\"accountId\":\"$TEST_ACCOUNT\"},{\"id\":\"$ID_A x\",\"accountId\":\"$TEST_ACCOUNT\"},{\"id\":\"\",\"accountId\":\"$other\"}]}"
        "fixture alert bound to another account|$TEST_ACCOUNT settled|200|application/json|{\"results\":[{\"id\":\"$ID_A\",\"accountId\":\"$other\"}]}"
        "fixture alert unrecordable|$TEST_ACCOUNT settled|200|application/json|{\"results\":[{\"id\":\"$ID_A\",\"accountId\":\"$TEST_ACCOUNT\"}]}"
        "other account unknown, unsettled|$other unsettled|404|application/json|{\"statusCode\":404,\"message\":\"Account not found\"}"
        "other account empty, settled|$other settled|200|application/json|{\"results\":[]}"
        "other account empty, settled, journal without a final newline|$other settled|200|application/json|{\"results\":[]}"
        "other account empty, unsettled|$other unsettled|200|application/json|{\"results\":[]}"
        "other account empty, state missing|$other|200|application/json|{\"results\":[]}"
        "other account lists alerts|$other settled|200|application/json|{\"results\":[{\"id\":\"$ID_A\",\"accountId\":\"$other\"}]}"
        "other account list with trailing text|$other settled|200|application/json|{\"results\":[]}x"
        "other account routing 404|$other settled|404|text/plain|not found"
        "other account list fails|$other settled|503|text/plain|down"
        "no readable account|unknown unsettled|||"
        "create not journaled||||"
        "journal unreadable||||"
    )
    local row account
    for row in "${rows[@]}"; do
        IFS='|' read -r name journal status ctype body <<<"$row"
        account="${journal%% *}"
        new_run
        cleanup_state true 0 0 0
        HOLDER_ID="$TEST_ACCOUNT"
        EMPTY_ID="$ID_B"
        respond 200 "application/json" '{"id":"portfolio-insights-enabled","enabled":true}'
        if [[ -n "$status" ]]; then
            respond "$status" "$ctype" "$body"
        fi
        requests="$(printf '%s\n' "GET $F" "GET $ALERTS_URL?accountId=$account")"
        case "$name" in
            "fixture list"* | "fixture items"*)
                expected="FAIL cleanup: $undetermined on fixture account [$account]: its alert list"
                expected+=" gave status $status, not $listing"
                ;;
            "fixture ids not canonical")
                expected="FAIL cleanup: $undetermined on fixture account [$TEST_ACCOUNT]: it lists 3"
                expected+=" alerts without a canonical id"
                ;;
            "fixture alert bound to another account")
                expected="FAIL cleanup: $undetermined on fixture account [$TEST_ACCOUNT]: it lists 1"
                expected+=" alerts bound to another account, none owned or deleted"
                ;;
            "fixture alert unrecordable")
                break_step "owned not a file"
                expected="FAIL cleanup: alert $ID_A of fixture account [$TEST_ACCOUNT] could not be"
                expected+=" recorded as owned; the owned alerts cannot be read from $RUN_DIR/owned:"
                expected+=" none was deleted"
                ;;
            "other account unknown"* | "other account empty, settled"*) expected="PASS cleanup" ;;
            "other account empty"*)
                expected="FAIL cleanup: $undetermined on account [$other], which is not this run's:"
                expected+=" it lists no alerts, but 1 uncertain creates there are unsettled (no"
                expected+=" response, or a status neither 2xx nor 4xx), so an alert such a create"
                expected+=" may still commit cannot be ruled out"
                ;;
            "other account lists alerts")
                expected="FAIL cleanup: $undetermined on account [$other], which is not this run's:"
                expected+=" it lists 1 alerts, none deleted"
                ;;
            "other account"*)
                expected="FAIL cleanup: $undetermined on account [$other]: its alert list gave status"
                expected+=" $status, neither a 404 ErrorResponse nor $listing"
                ;;
            "no readable account")
                expected="FAIL cleanup: 1 uncertain creates named no readable account: $undetermined"
                requests="GET $F"
                ;;
            "create not journaled")
                UNJOURNALED_CREATES=2
                expected="FAIL cleanup: 2 uncertain creates could not be journaled: $undetermined"
                requests=""
                ;;
            "journal unreadable")
                break_step "uncertain-creates not a file"
                expected="FAIL cleanup: the journal of uncertain creates cannot be read from"
                expected+=" $RUN_DIR/uncertain-creates: $undetermined"
                requests="any"
                ;;
        esac
        if [[ "$name" == *"without a final newline" ]]; then
            printf '%s' "$journal" >"$RUN_DIR/uncertain-creates"
        elif [[ -n "$journal" ]]; then
            echo "$journal" >"$RUN_DIR/uncertain-creates"
        fi
        run_cleanup 0
        row_is "$name: verdict" "$(verdicts "$CASE_DIR/out")" "$expected"
        if [[ "$expected" == "PASS cleanup" ]]; then
            row_is "$name: status" "$CLEANUP_STATUS" "0"
        else
            row_is "$name: status" "$CLEANUP_STATUS" "1"
        fi
        if [[ "$requests" != "any" ]]; then
            row_is "$name: requests" "$(file_text "$CASE_DIR/requests")" "$requests"
        elif grep -q '^DELETE ' "$CASE_DIR/requests"; then
            reasons+=("$name: a DELETE was sent")
        fi
        if [[ -f "$RUN_DIR/owned" ]]; then
            row_is "$name: owned" "$(file_text "$RUN_DIR/owned")" ""
        fi
    done
    conclude "cleanup_uncertainCreate_settlesByAccountNeverDeletingOthers"
}

# shellcheck disable=SC2317,SC2329 # Invoked through poll.
# exit_after SECONDS: a poll command that takes SECONDS of fake time, then ends the run, as an
# abort or an interrupt inside a poll does.
exit_after() {
    FAKE_NOW=$((FAKE_NOW + $1))
    exit 1
}

test_cleanup_exitInsideExpiredPoll_stillSendsItsRequests() {
    new_run
    cleanup_state false 1 0 0
    respond 200 "application/json" '{"id":"portfolio-insights-enabled","enabled":false}'
    CLEANUP_STATUS=0
    (
        trap cleanup EXIT
        poll "step x" 10 5 exit_after 20
    ) >"$CASE_DIR/out" 2>&1 || CLEANUP_STATUS=$?
    row_is "status, verdict and requests" \
        "$CLEANUP_STATUS|$(verdicts "$CASE_DIR/out")|$(file_text "$CASE_DIR/requests")" \
        "1|PASS cleanup|PUT $F {\"enabled\": false}"
    conclude "cleanup_exitInsideExpiredPoll_stillSendsItsRequests"
}

test_cleanup_evidenceDir_printedAfterRunDirWhenSeparate() {
    local row name end separate status lines expected
    # name|end: cleanup, or a second interrupt while it runs|evidence dir of its own|exit status|
    # the lines from the run dir line on, \n between them
    local -a rows=(
        "cleanup, evidence in the run dir|cleanup|0|0|INFO run dir @RUN@\nSUMMARY 1 passed, 0 failed"
        "cleanup, evidence dir of its own|cleanup|1|0|INFO run dir @RUN@\nINFO evidence dir @EVIDENCE@\nSUMMARY 1 passed, 0 failed"
        "interrupted, evidence in the run dir|interrupted|0|130|INFO run dir @RUN@\nSUMMARY 0 passed, 1 failed"
        "interrupted, evidence dir of its own|interrupted|1|130|INFO run dir @RUN@\nINFO evidence dir @EVIDENCE@\nSUMMARY 0 passed, 1 failed"
    )
    for row in "${rows[@]}"; do
        IFS='|' read -r name end separate status lines <<<"$row"
        new_run
        cleanup_state true 0 0 0
        if [[ "$separate" -eq 1 ]]; then
            evidence_in_parent ""
        fi
        if [[ "$end" == "cleanup" ]]; then
            run_cleanup 0
        else
            CLEANUP_STATUS=0
            (on_cleanup_signal) >"$CASE_DIR/out" 2>&1 || CLEANUP_STATUS=$?
        fi
        expected="$(printf '%b' "$lines")"
        expected="${expected//@RUN@/$RUN_DIR}"
        row_is "$name" "$CLEANUP_STATUS|$(sed -n '/^INFO run dir /,$p' "$CASE_DIR/out" | tr -d '\r')" \
            "$status|${expected//@EVIDENCE@/$EVIDENCE_DIR}"
    done
    conclude "cleanup_evidenceDir_printedAfterRunDirWhenSeparate"
}

POLL_ATTEMPTS=0
SUCCEED_AT=1
POLL_REASON=""

# shellcheck disable=SC2317,SC2329 # Invoked through poll.
# attempt: a poll command that succeeds on attempt SUCCEED_AT, 0 meaning never, and otherwise
# leaves POLL_REASON as its POLL_DETAIL.
attempt() {
    POLL_ATTEMPTS=$((POLL_ATTEMPTS + 1))
    if [[ $SUCCEED_AT -gt 0 && $POLL_ATTEMPTS -ge $SUCCEED_AT ]]; then
        return 0
    fi
    POLL_DETAIL="$POLL_REASON"
    return 1
}

# run_poll TIMEOUT STEP SUCCEED_AT REASON: polls attempt; prints "STATUS ATTEMPTS SLEEPS SECONDS
# | OUTPUT", SECONDS being the fake time that passed.
run_poll() {
    local rc=0 start="$FAKE_NOW"
    local -a sleeps
    POLL_ATTEMPTS=0
    SUCCEED_AT="$3"
    POLL_REASON="$4"
    : >"$CASE_DIR/sleeps"
    poll "step x" "$1" "$2" attempt >"$CASE_DIR/out" || rc=$?
    mapfile -t sleeps <"$CASE_DIR/sleeps"
    echo "$rc $POLL_ATTEMPTS [${sleeps[*]}] $((FAKE_NOW - start)) | $(file_text "$CASE_DIR/out")"
}

test_poll_commandSucceeds_returnsWithoutFurtherSleep() {
    new_run
    row_is "first attempt" "$(run_poll 10 5 1 "")" "0 1 [] 0 | "
    row_is "third attempt" "$(run_poll 30 5 3 "not yet")" "0 3 [5 5] 10 | "
    conclude "poll_commandSucceeds_returnsWithoutFurtherSleep"
}

test_poll_deadline_failsWithDetail() {
    new_run
    # A third attempt would start at the deadline, so the poll gives up without sleeping into
    # it, and the second attempt's detail stands.
    row_is "detail" "$(run_poll 10 5 0 "last attempt said no")" \
        "1 2 [5] 5 | FAIL step x: deadline 10 s expired; last attempt said no"
    row_is "uneven deadline" "$(run_poll 12 5 0 "no")" \
        "1 3 [5 5] 10 | FAIL step x: deadline 12 s expired; no"
    row_is "no detail" "$(run_poll 3 5 0 "")" "1 1 [] 0 | FAIL step x: deadline 3 s expired"
    conclude "poll_deadline_failsWithDetail"
}

test_poll_zeroBudget_failsWithoutAttempt() {
    new_run
    row_is "command that would succeed" "$(run_poll 0 5 1 "")" \
        "1 0 [] 0 | FAIL step x: deadline 0 s expired"
    row_is "command that would fail" "$(run_poll 0 5 0 "no")" \
        "1 0 [] 0 | FAIL step x: deadline 0 s expired"
    conclude "poll_zeroBudget_failsWithoutAttempt"
}

# An 11 s poll with 5 s steps whose first sleep ends late: an attempt starts after it only while
# the clock reads less than the deadline.
test_poll_deadlinePassesDuringSleep_startsNoFurtherAttempt() {
    local row name overrun expected
    local miss="FAIL step x: deadline 11 s expired; no"
    # name|seconds the sleep ends late|what run_poll prints
    local -a rows=(
        "sleep ends in the last second|5|1 2 [5] 10 | $miss"
        "sleep ends at the deadline|6|1 1 [5] 11 | $miss"
        "sleep ends after the deadline|9|1 1 [5] 14 | $miss"
    )
    for row in "${rows[@]}"; do
        IFS='|' read -r name overrun expected <<<"$row"
        new_run
        row_is "$name" "$(SLEEP_OVERRUN="$overrun" run_poll 11 5 0 "no")" "$expected"
    done
    conclude "poll_deadlinePassesDuringSleep_startsNoFurtherAttempt"
}

# shellcheck disable=SC2317,SC2329 # Invoked through poll.
# late_success SECONDS: a poll command whose attempt takes SECONDS of fake time and succeeds.
late_success() {
    FAKE_NOW=$((FAKE_NOW + $1))
}

# The clock reads whole seconds and the start second is rounded down, so a success seen while it
# reads the deadline's own second may have come after the true deadline.
test_poll_successAtOrAfterDeadline_failsAsLate() {
    local row name seconds expected rc
    local late="FAIL step x: deadline 10 s expired; the result arrived at or after the deadline"
    local -a rows=(
        "result in the last second before the deadline|9|0 []"
        "result in the deadline's own second|10|1 [$late]"
        "result 3 s after the deadline|13|1 [$late]"
    )
    for row in "${rows[@]}"; do
        IFS='|' read -r name seconds expected <<<"$row"
        new_run
        rc=0
        poll "step x" 10 5 late_success "$seconds" >"$CASE_DIR/out" || rc=$?
        row_is "$name" "$rc [$(file_text "$CASE_DIR/out")]" "$expected"
    done
    conclude "poll_successAtOrAfterDeadline_failsAsLate"
}

# shellcheck disable=SC2317,SC2329 # Invoked through poll.
# request_after SECONDS: a poll command that takes SECONDS of fake time, then sends one request;
# it succeeds on a 200 and otherwise leaves the request's status and error as its POLL_DETAIL.
request_after() {
    FAKE_NOW=$((FAKE_NOW + $1))
    http GET "$INSIGHTS_URL/$TEST_ACCOUNT"
    if [[ "$HTTP_STATUS" == "200" ]]; then
        return 0
    fi
    POLL_DETAIL="status $HTTP_STATUS, error [$HTTP_ERROR]"
    return 1
}

# A 10 s poll hands its deadline to http: a request takes no longer than the time left, and
# none is sent once the clock reads the deadline.
test_poll_requestNearDeadline_boundedToTimeLeftOrNotSent() {
    local row name seconds expected rc
    local unsent="status 000, error [not sent: no time left before the poll deadline]"
    # name|seconds the attempt takes before its request|--max-time sent; poll status [output]
    local -a rows=(
        "request 6 s before the deadline|4|--max-time 6; 0 []"
        "request in the last second|9|--max-time 1; 0 []"
        "request at the deadline|10|; 1 [FAIL step x: deadline 10 s expired; $unsent]"
    )
    for row in "${rows[@]}"; do
        IFS='|' read -r name seconds expected <<<"$row"
        new_run
        rc=0
        (
            # shellcheck disable=SC2317,SC2329 # Invoked by http.
            curl() {
                while [[ $# -gt 0 && "$1" != "--max-time" ]]; do
                    shift
                done
                echo "--max-time ${2:-none}" >>"$CASE_DIR/requests"
                printf '200 application/json'
            }
            poll "step x" 10 5 request_after "$seconds"
        ) >"$CASE_DIR/out" || rc=$?
        row_is "$name" "$(file_text "$CASE_DIR/requests"); $rc [$(file_text "$CASE_DIR/out")]" \
            "$expected"
    done
    conclude "poll_requestNearDeadline_boundedToTimeLeftOrNotSent"
}

# ---------------------------------------------------------------------------------------------
# Main

test_options_help_exitsZeroWithUsage
test_options_invalid_exitTwoWithUsageError
test_options_sourced_setRunConfiguration
test_options_pathConversionOffInCaller_settingsUnset
test_options_evidenceDir_newDirectoryPerRun
test_decToUnits_plainTokens_matchUnits
test_decToUnits_invalidText_rejected
test_numToUnits_jqForms_matchUnits
test_numToUnits_invalidForms_rejected
test_unitsToDec_units_normalisedText
test_decimals_roundTrip_normaliseToken
test_resolveInterval_setting_matchesBrokerRule
test_readWindow_brokerLog_recordsOnlyCycleAndTriggerLines
test_readWindow_cycleLine_recordsOutcome
test_brokerLogReads_rawOutput_keptOnlyInPrivateDir
test_windowCycles_window_countsCycleLines
test_triggerPosition_events_locateOwnArming
test_triggerLogged_brokerLog_findsArmingByLowercaseId
test_laterCyclesSeen_window_needsCompletedCycleAfterTriggeringCycle
test_step9Trigger_triggerLines_recordLoggedArmingsOnly
test_step10NoRepeat_followUpCycle_passesOnlyOnceCompleted
test_ownIfCreated_response_ownsCreatedAndJournalsUncertain
test_postAlert_nonTokenThreshold_rejectedBeforeRequest
test_postAlert_unusableResponse_failsJournalingOnlyUncertain
test_postAlert_recordUnwritable_journalsOrCountsCreate
test_postAlert_created_ownsLowercaseId
test_postAlert_token_sentVerbatim
test_onSignal_interrupt_heldOnlyWhileCreating
test_onSignal_interruptInStep_failsOnceNamingStep
test_onSignal_interruptInRedirectedCall_verdictOnRunStdout
test_onSignal_signalAsCleanupStarts_endsRunThroughCleanupSignal
test_main_stdoutClosed_runsUnsavedAndRemovesPrivateDir
test_remainingOwned_ownedAndDeleted_listsUndeleted
test_remainingOwned_stepFails_failsPrintingNothing
test_deleteAlert_recordUnwritable_failsKeepingStatus
test_deleteRemaining_statuses_mark204And404Deleted
test_deleteRemaining_transportErrors_stopAfterMaxConsecutive
test_deleteRemaining_transportError_infoCarriesFixedReason
test_deleteIds_rawOwnedList_deletesEachCanonicalIdOnce
test_writeFixture_alerts_matchBrowserCheckShape
test_prefixLines_browserOutput_infoPrefixedAndLogged
test_runBrowserCheck_exitCode_reportsPassOrFail
test_runBrowserCheck_invocation_passesModeAndFixture
test_runBrowserCheck_runStdoutSaved_descriptorClosedForCheck
test_runBrowserCheck_earlierReport_neitherReadNorDeleted
test_step12UntriggeredAck_listings_passOnlyUnchangedUntriggeredRow
test_step12UntriggeredAck_changedRow_namesFieldsWithoutRowsInJqArguments
test_step12UntriggeredAck_browserReport_acceptsOnlyThisRunsAcknowledgement
test_http_transportError_reportsStatus000WithFixedReason
test_http_pollDeadline_boundsRequestOrSendsNothing
test_expectForbidden_response_passesOnlyExact403
test_expectForbidden_createdInstead_failsAndOwnsId
test_expectForbidden_postUncertain_heldAndJournaled
test_jcheck_verdict_passesOnlyOk
test_jitemJcount_mixedCaseIds_matchLowercaseId
test_jgetJitemJcount_input_printOnlyForOneDocument
test_randomGuid_generated_matchUuidPattern
test_cleanup_noOwnedAlerts_passesAndKeepsExitStatus
test_cleanup_ownedAlerts_switchFlagOnOnlyWhileOff
test_cleanup_switchOnUnconfirmed_failsCleanupAndStillDeletes
test_cleanup_deleteLeftInPlace_failsAndExitsOne
test_cleanup_flagNotRestored_failsCleanup
test_cleanup_earlierFailure_neverExitsZero
test_cleanup_inventoryUnusable_failsAndExitsOne
test_step13_inventoryUnusable_failsAndContinues
test_stepDeletes_deletionUnrecordable_failsCheckAndContinues
test_cleanup_uncertainFixtureCreate_deletesListedAndFailsUnlessSettled
test_cleanup_uncertainCreate_settlesByAccountNeverDeletingOthers
test_cleanup_exitInsideExpiredPoll_stillSendsItsRequests
test_cleanup_evidenceDir_printedAfterRunDirWhenSeparate
test_poll_commandSucceeds_returnsWithoutFurtherSleep
test_poll_deadline_failsWithDetail
test_poll_zeroBudget_failsWithoutAttempt
test_poll_deadlinePassesDuringSleep_startsNoFurtherAttempt
test_poll_successAtOrAfterDeadline_failsAsLate
test_poll_requestNearDeadline_boundedToTimeLeftOrNotSent

echo "SUMMARY $tests_passed passed, $tests_failed failed"
if [[ $tests_failed -gt 0 ]]; then
    exit 1
fi
exit 0
