#!/usr/bin/env bash
# Unit tests for the helpers of scripts/portfolio-insights/e2e.sh, run without a stack:
#   - option parsing, in a child bash, and the configuration a valid set of options gives;
#   - exact decimals (dec_to_units, num_to_units, units_to_dec) and the interval rule;
#   - broker log windows: the log read, cycle and trigger lines, alert ids and arming revisions;
#   - alert ownership: created ids, the create guard, interrupts, deletion and its limits;
#   - the fixture the browser check reads, the browser check's exit code and output;
#   - http's transport errors, the exact 403 oracle, the jq verdict and lookup helpers, and
#     random GUIDs;
#   - the EXIT cleanup's flag switching, restore and failure paths, and bounded polling.
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
# it records each log read and serves a canned broker log. No request leaves the host, no call
# reaches a Docker engine and no time passes.
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
NODE_OUTPUT=""
NODE_RC=0
SIGNAL_PID=""

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
    SIGNAL_PID=""
    HTTP_STATUS=""
    HTTP_CTYPE=""
    HTTP_BODY=""
    HTTP_ERROR=""
    POLL_DETAIL=""
    CREATED_ID=""
    CREATE_ERROR=""
    IN_CREATE=0
    PENDING_EXIT=""
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
    if [[ -n "$SIGNAL_PID" ]]; then
        kill -INT "$SIGNAL_PID"
    fi
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
# (printf %b text) and exits with NODE_RC.
node() {
    printf '%s\n%s\n' "$PWD" "$*" >"$CASE_DIR/node-call"
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

# sleep SECONDS: advances the fake clock and records the step; no time passes.
sleep() {
    echo "$1" >>"$CASE_DIR/sleeps"
    FAKE_NOW=$((FAKE_NOW + $1))
}

# broker_log EVENT...: writes the broker log docker serves, one console-logger line per EVENT,
# coloured and CRLF-terminated as docker compose logs prints them: C is a cycle summary,
# "T ID REVISION" a trigger line, and any other text an unrelated line with that message.
broker_log() {
    local event message id revision
    : >"$CASE_DIR/broker.log"
    for event in "$@"; do
        case "$event" in
            C)
                message="Alert evaluation cycle finished: alerts [4] triggered [0] failed [0]"
                message="$message skipped [0] outcome [completed] duration [7] ms"
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

load_e2e() {
    # shellcheck source-path=SCRIPTDIR source=e2e.sh
    source "$E2E" --project e2e-unit-test --compose-file compose.dev.yaml \
        --base-url "$TEST_BASE_URL/"
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
    new_run
    run_e2e_child --help
    row_is "status" "$CHILD_STATUS" "0"
    row_is "first line" "$(first_line "$CASE_DIR/child.out")" \
        "Usage: scripts/portfolio-insights/e2e.sh --project NAME [--base-url URL]"
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
    row_is "events" "$(file_text "$RUN_DIR/window.events")" "$(printf 'C\nT %s 3\nC' "$ID_LOWER")"
    row_is "one log read of the project's broker-service" \
        "$(file_text "$CASE_DIR/docker.calls")" "$call"
    conclude "readWindow_brokerLog_recordsOnlyCycleAndTriggerLines"
}

test_windowCycles_window_countsCycleLines() {
    new_run
    read_window "2026-11-25T10:00:00Z" || reasons+=("read_window failed on the empty log")
    row_is "empty window" "$(window_cycles)" "0"
    broker_log C "T $ID_A 1" "unrelated line" C C
    read_window "2026-11-25T10:00:00Z" || reasons+=("read_window failed")
    row_is "three cycles around a trigger" "$(window_cycles)" "3"
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
    printf 'C\nC\nT %s 1\nC\nT %s 2\n' "$ID_A" "$ID_B" >"$RUN_DIR/window.events"
    row_is "after two cycles" "$(position "$ID_A" 1)" "0 3 2"
    row_is "after three cycles" "$(position "$ID_B" 2)" "0 5 3"
    row_is "other revision" "$(position "$ID_A" 2)" "1 - -"
    row_is "unknown id" "$(position "$ID_UPPER" 1)" "1 - -"
    printf 'T %s 1\nC\nC\n' "$ID_A" >"$RUN_DIR/window.events"
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

test_laterCyclesSeen_window_needsTwoCyclesAfterLastTrigger() {
    local need="cycle lines after the last trigger line, 2 needed (the triggering cycle's own and the next)"
    new_run
    LOG9_SINCE="2026-11-25T10:00:00Z"
    broker_log C "T $ID_A 1" C C
    LAST_TRIGGER_INDEX=2
    row_is "two cycles after" "$(outcome later_cycles_seen)" "0 2 $need"
    broker_log C "T $ID_A 1" C
    row_is "one cycle after" "$(outcome later_cycles_seen)" "1 1 $need"
    broker_log C C "T $ID_A 1" C
    LAST_TRIGGER_INDEX=3
    row_is "cycles before the trigger" "$(outcome later_cycles_seen)" "1 1 $need"
    broker_log "T $ID_A 1" C "T $ID_B 1" C
    LAST_TRIGGER_INDEX=3
    row_is "cycle between two triggers" "$(outcome later_cycles_seen)" "1 1 $need"
    BROKER_LOGS_RC=1
    row_is "logs unreadable" "$(outcome later_cycles_seen)" \
        "1 broker-service logs unreadable, exit 1 (see $RUN_DIR/compose.log)"
    conclude "laterCyclesSeen_window_needsTwoCyclesAfterLastTrigger"
}

# ---------------------------------------------------------------------------------------------
# Alert ownership

test_ownIfCreated_response_ownsOnlyCreatedUuid() {
    local row status body expected
    local -a rows=(
        "201|{\"id\":\"$ID_UPPER\"}|$ID_LOWER"
        "201|{}|"
        "201|{\"id\":\"not-a-uuid\"}|"
        "201|not json|"
        "400|{\"id\":\"$ID_UPPER\"}|"
        "200|{\"id\":\"$ID_UPPER\"}|"
    )
    for row in "${rows[@]}"; do
        new_run
        IFS='|' read -r status body expected <<<"$row"
        HTTP_STATUS="$status"
        HTTP_BODY="$body"
        own_if_created
        row_is "$status $body" "$(file_text "$RUN_DIR/owned")" "$expected"
    done
    conclude "ownIfCreated_response_ownsOnlyCreatedUuid"
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

test_postAlert_unusableResponse_failsAndOwnsNothing() {
    local row status body expected rc transport="transport error (curl: (7) $CONNECT_ERROR)"
    local -a rows=(
        "000|$CONNECT_ERROR|$transport; the alert may exist without an id this run knows"
        "400|{\"error\":\"invalid\"}|status 400; body [19 bytes, JSON object with 1 key [error]]"
        "201|{}|201 without a readable id; the created alert cannot be deleted by this run"
        "201|{\"id\":\"xyz\"}|201 without a readable id; the created alert cannot be deleted by this run"
    )
    for row in "${rows[@]}"; do
        new_run
        IFS='|' read -r status body expected <<<"$row"
        respond "$status" "application/json" "$body"
        rc=0
        post_alert "$TEST_ACCOUNT" TARGET_PRICE "$ID_A" ABOVE 1 || rc=$?
        row_is "$status $body" "$rc|$CREATE_ERROR|$CREATED_ID|$(file_text "$RUN_DIR/owned")" \
            "1|$expected||"
    done
    conclude "postAlert_unusableResponse_failsAndOwnsNothing"
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

test_onSignal_interrupt_heldOnlyWhileCreating() {
    local status
    new_run
    status=0
    (
        IN_CREATE=0
        on_signal
        echo "continued"
    ) >"$CASE_DIR/out" 2>&1 || status=$?
    row_is "outside a create" "$status|$(file_text "$CASE_DIR/out")" "130|"

    new_run
    respond 201 "application/json" "{\"id\":\"$ID_UPPER\"}"
    status=0
    (
        trap on_signal INT
        SIGNAL_PID="$BASHPID"
        create_alert "$TEST_ACCOUNT" TARGET_PRICE "$ID_A" ABOVE 1
        echo "continued"
    ) >"$CASE_DIR/out" 2>&1 || status=$?
    row_is "during the POST" "$status|$(file_text "$CASE_DIR/out")|$(file_text "$RUN_DIR/owned")" \
        "130||$ID_LOWER"

    new_run
    respond 201 "application/json" "{\"id\":\"$ID_UPPER\"}"
    status=0
    (
        trap on_signal INT
        create_alert "$TEST_ACCOUNT" TARGET_PRICE "$ID_A" ABOVE 1
        echo "continued"
    ) >"$CASE_DIR/out" 2>&1 || status=$?
    row_is "no interrupt" "$status|$(file_text "$CASE_DIR/out")|$(file_text "$RUN_DIR/owned")" \
        "0|continued|$ID_LOWER"
    conclude "onSignal_interrupt_heldOnlyWhileCreating"
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

# ---------------------------------------------------------------------------------------------
# Response oracles

test_http_transportErrorWithoutMessage_reportsStatus000() {
    local row name stderr expected status
    local debug="WARNING: this libcurl is Debug-enabled, do not use in production"
    local -a rows=(
        "empty curl stderr||"
        "only a Debug-enabled line|$debug\\n|"
        "a message|curl: (7) $CONNECT_ERROR\\n|curl: (7) $CONNECT_ERROR"
        "a Debug-enabled line, then a CRLF message|$debug\\r\\ncurl: (28) timed out\\r\\n|curl: (28) timed out"
    )
    for row in "${rows[@]}"; do
        IFS='|' read -r name stderr expected <<<"$row"
        new_run
        # The subshell keeps errexit on, as e2e.sh runs http: a failing pipeline in http ends it
        # before its last line prints.
        set +e
        (
            set -e
            # shellcheck disable=SC2317,SC2329 # Invoked by http.
            curl() {
                printf '%b' "$stderr" >&2
                return 7
            }
            http GET "$INSIGHTS_URL/$TEST_ACCOUNT"
            printf '%s|%s|%s|still running' "$HTTP_STATUS" "$HTTP_CTYPE" "$HTTP_ERROR"
        ) >"$CASE_DIR/out" 2>"$CASE_DIR/err"
        status=$?
        set -e
        row_is "$name" "$status|$(file_text "$CASE_DIR/out")" "0|000||$expected|still running"
    done
    conclude "http_transportErrorWithoutMessage_reportsStatus000"
}

test_expectForbidden_response_passesOnlyExact403() {
    local row name status ctype body expected
    local -a rows=(
        "exact|403|application/json; charset=utf-8|{\"error\":\"feature_disabled\"}|PASS"
        "exact, bare type|403|application/json|{\"error\":\"feature_disabled\"}|PASS"
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
        IFS='|' read -r name status ctype body expected <<<"$row"
        new_run
        respond "$status" "$ctype" "$body"
        expect_forbidden "$name" GET "$INSIGHTS_URL/$TEST_ACCOUNT" >"$CASE_DIR/out"
        if [[ "$expected" == "PASS" ]]; then
            row_is "$name" "$(file_text "$CASE_DIR/out")" "PASS $name"
        elif [[ "$(file_text "$CASE_DIR/out")" != "FAIL $name: "* ]]; then
            reasons+=("$name: got [$(file_text "$CASE_DIR/out")], expected a FAIL line")
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

test_jcheck_verdict_passesOnlyOk() {
    local filter='if .a == 1 then "ok" else "a is \(.a)" end'
    new_run
    row_is "ok" "$(jcheck "check" "$filter" '{"a":1}')" "PASS check"
    row_is "reason" "$(jcheck "check" "$filter" '{"a":2}')" "FAIL check: a is 2"
    row_is "not JSON" "$(jcheck "check" "$filter" 'not json')" \
        "FAIL check: unreadable JSON [8 bytes, not JSON]"
    row_is "empty" "$(jcheck "check" "$filter" '')" "FAIL check: unreadable JSON [empty]"
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

    new_run
    cleanup_state true 0 0 0
    echo "$ID_A" >"$RUN_DIR/owned"
    respond 200 "application/json" '{"id":"portfolio-insights-enabled","enabled":true}'
    respond 204 "" ""
    run_cleanup 0
    row_is "flag on: status, verdict and requests" \
        "$CLEANUP_STATUS|$(verdicts "$CASE_DIR/out")|$(file_text "$CASE_DIR/requests")" \
        "0|PASS cleanup|$(printf '%s\n' "GET $F" "DELETE $ALERTS_URL/$ID_A")"
    conclude "cleanup_ownedAlerts_switchFlagOnOnlyWhileOff"
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
        "restore leaves the flag on|200|{\"enabled\":true}|status 200"
        "restore unreachable|000|$CONNECT_ERROR|transport error (curl: (7) $CONNECT_ERROR)"
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
    respond 200 "application/json" '{"enabled":false}'
    respond 200 "application/json" '{"enabled":true}'
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
    row_is "detail" "$(run_poll 10 5 0 "last attempt said no")" \
        "1 3 [5 5] 10 | FAIL step x: deadline 10 s expired; last attempt said no"
    row_is "uneven deadline" "$(run_poll 12 5 0 "no")" \
        "1 3 [5 5] 10 | FAIL step x: deadline 12 s expired; no"
    row_is "no detail" "$(run_poll 0 5 0 "")" "1 1 [] 0 | FAIL step x: deadline 0 s expired"
    conclude "poll_deadline_failsWithDetail"
}

# ---------------------------------------------------------------------------------------------
# Main

test_options_help_exitsZeroWithUsage
test_options_invalid_exitTwoWithUsageError
test_options_sourced_setRunConfiguration
test_decToUnits_plainTokens_matchUnits
test_decToUnits_invalidText_rejected
test_numToUnits_jqForms_matchUnits
test_numToUnits_invalidForms_rejected
test_unitsToDec_units_normalisedText
test_decimals_roundTrip_normaliseToken
test_resolveInterval_setting_matchesBrokerRule
test_readWindow_brokerLog_recordsOnlyCycleAndTriggerLines
test_windowCycles_window_countsCycleLines
test_triggerPosition_events_locateOwnArming
test_triggerLogged_brokerLog_findsArmingByLowercaseId
test_laterCyclesSeen_window_needsTwoCyclesAfterLastTrigger
test_ownIfCreated_response_ownsOnlyCreatedUuid
test_postAlert_nonTokenThreshold_rejectedBeforeRequest
test_postAlert_unusableResponse_failsAndOwnsNothing
test_postAlert_created_ownsLowercaseId
test_postAlert_token_sentVerbatim
test_onSignal_interrupt_heldOnlyWhileCreating
test_remainingOwned_ownedAndDeleted_listsUndeleted
test_deleteRemaining_statuses_mark204And404Deleted
test_deleteRemaining_transportErrors_stopAfterMaxConsecutive
test_writeFixture_alerts_matchBrowserCheckShape
test_prefixLines_browserOutput_infoPrefixedAndLogged
test_runBrowserCheck_exitCode_reportsPassOrFail
test_runBrowserCheck_invocation_passesModeAndFixture
test_http_transportErrorWithoutMessage_reportsStatus000
test_expectForbidden_response_passesOnlyExact403
test_expectForbidden_createdInstead_failsAndOwnsId
test_jcheck_verdict_passesOnlyOk
test_jitemJcount_mixedCaseIds_matchLowercaseId
test_randomGuid_generated_matchUuidPattern
test_cleanup_noOwnedAlerts_passesAndKeepsExitStatus
test_cleanup_ownedAlerts_switchFlagOnOnlyWhileOff
test_cleanup_deleteLeftInPlace_failsAndExitsOne
test_cleanup_flagNotRestored_failsCleanup
test_cleanup_earlierFailure_neverExitsZero
test_poll_commandSucceeds_returnsWithoutFurtherSleep
test_poll_deadline_failsWithDetail

echo "SUMMARY $tests_passed passed, $tests_failed failed"
if [[ $tests_failed -gt 0 ]]; then
    exit 1
fi
exit 0
