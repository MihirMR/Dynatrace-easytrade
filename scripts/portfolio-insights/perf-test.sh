#!/usr/bin/env bash
# Unit tests for the helpers of scripts/portfolio-insights/perf.sh. perf.sh runs its checks in
# main(), which it calls only when it is executed. Sourced, it parses its options, checks its
# tools and makes its run directory, and runs nothing else: no trap, no step. These cases source
# it and call its functions, and every outside effect is a stub:
#   - docker and curl are shell functions that record each call and answer with canned output,
#     and timeout is one that records the hard limit perf.sh's hard_timeout gives a Docker call
#     and runs that call through the docker function, so no container, stack, database or
#     network is reached. docker and curl program files ahead of the real ones on PATH fail any
#     case whose calls go around the functions. The armed-set query runs against real SQL Server
#     and PostgreSQL databases in scripts/portfolio-insights/harness-sql-test.sh; the stub cases
#     cover perf.sh's own handling of it: the exact query text per dialect, refusal before any
#     query, the id,revision rows and the one time row it reads back through the container
#     client's output, an answer without exactly one readable time row, and the propagation of
#     the client's exit status;
#   - sleep advances SECONDS instead of waiting, and date prints one fixed time.
# Covered: the command line, direct execution running main, exact decimals, the nearest-rank
# percentile, cycle-line parsing, sample eligibility and bounded log polling, the armed-set
# query on both dialects including client failures and unexpected answers, the owned-set
# comparison, re-arming after a rejected sample, alert creation outcomes, and every cleanup and
# exit path, the bounded start of loadgen included. Covered elsewhere: sourcing that runs
# nothing and the recording of a created alert by perf-inputs-test.sh; each time-row format
# read into ARMED_AT and the sample and follow-up selection built on the armed set by
# perf-cycle-test.sh; the insights p95 measurement by perf-insights-test.sh; hard_timeout and
# broker_logs themselves by harness-test.sh.
#
# Usage: scripts/portfolio-insights/perf-test.sh
#   --help  Show this help and exit
#
# Needs bash, jq and coreutils only. Prints one PASS or FAIL line per case and a final SUMMARY
# line. Exits 0 when every case passes, 1 when any case fails, and 2 on a usage error or a
# missing tool. The run's temporary files are removed on exit.

set -euo pipefail

test_usage() {
    cat <<'EOF'
Usage: scripts/portfolio-insights/perf-test.sh
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

for test_tool in jq sed awk sort comm cut wc tr head tail mv mktemp uname; do
    if ! command -v "$test_tool" >/dev/null 2>&1; then
        echo "$test_tool is required on PATH." >&2
        exit 2
    fi
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# perf.sh resolves its compose file from the current directory, as it does when run.
cd "$REPO_ROOT"
PERF_SH="scripts/portfolio-insights/perf.sh"

TEST_TMP="$(mktemp -d -t perf-test.XXXXXX)"
trap 'rm -rf "$TEST_TMP"' EXIT
trap 'exit 130' INT TERM
# perf.sh creates its run directory under TMPDIR, so everything it writes stays in TEST_TMP.
export TMPDIR="$TEST_TMP"
STUB="$TEST_TMP/stub"
CASE_RUN_DIR="$TEST_TMP/run"
TEST_OUT="$TEST_TMP/out"
mkdir "$STUB" "$CASE_RUN_DIR"

# Synthetic fixture values; none of them exists in any deployment.
ACCOUNT_ID="a0000000-0000-4000-8000-000000000001"
INSTRUMENT_ID="c0000000-0000-4000-8000-000000000001"
ALERT_ID="d0000000-0000-4000-8000-0000000000ab"
ALERTS_ENDPOINT="http://localhost/broker-service/v1/alerts"
FLAG_ENDPOINT="http://localhost/feature-flag-service/v1/flags/portfolio-insights-enabled"
COMPOSE_ARGS=(compose -p unit-test -f compose.dev.yaml)
COMPOSE_PREFIX="${COMPOSE_ARGS[*]}"
CONNECT_ERROR="curl: (7) Failed to connect to localhost port 80"

# ---------------------------------------------------------------------------------------------
# Stubs. docker, curl and timeout are defined before perf.sh is sourced, because its tool check
# runs then. Like the helpers below they use builtins only: every fork is slow under Git Bash.

STUB_EXEC_OUT=""
STUB_EXEC_ERR=""
STUB_EXEC_RC=0
STUB_LOGS_RC=0
STUB_LOG_POLLS=0
STUB_START_RC=0
STUB_SIGNAL_PID=""
STUB_TIMEOUT_RC=""

# reset_stubs: empty call records and default answers.
reset_stubs() {
    local file
    for file in docker.calls logs.calls requests responses sleeps exec.args timeouts; do
        : >"$STUB/$file"
    done
    STUB_EXEC_OUT=""
    STUB_EXEC_ERR=""
    STUB_EXEC_RC=0
    STUB_LOGS_RC=0
    STUB_LOG_POLLS=0
    STUB_START_RC=0
    STUB_SIGNAL_PID=""
    STUB_TIMEOUT_RC=""
}

# The program files docker and curl, ahead of the real ones on PATH, record each call in
# external.calls and fail. The shell functions below answer every call perf.sh makes by name,
# so a call that reaches these went around the stubs: run_case fails its case, whichever of its
# rows made the call, and no case reaches a Docker engine or the network.
: >"$STUB/external.calls"
mkdir "$TEST_TMP/bin"
for test_tool in docker curl; do
    cat >"$TEST_TMP/bin/$test_tool" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >>"$STUB/external.calls"
exit 97
EOF
    chmod +x "$TEST_TMP/bin/$test_tool"
done
export STUB
export PATH="$TEST_TMP/bin:$PATH"

# docker: `docker compose version` succeeds. Every other call is recorded in docker.calls and
# must be `compose -p P -f F <command> ...`: exec writes the MSYS_NO_PATHCONV value it ran with
# and its arguments, one per line, to exec.args and answers STUB_EXEC_OUT, STUB_EXEC_ERR and
# STUB_EXEC_RC; the Nth logs call prints logs.N, capped at STUB_LOG_POLLS, and exits
# STUB_LOGS_RC; start and stop exit STUB_START_RC.
docker() {
    local calls=() n line
    if [[ "$*" == "compose version" ]]; then
        return 0
    fi
    printf '%s\n' "$*" >>"$STUB/docker.calls"
    if [[ $# -lt 6 || "$1" != "compose" ]]; then
        echo "docker stub: unexpected call: $*" >&2
        return 97
    fi
    case "$6" in
        exec)
            {
                echo "MSYS_NO_PATHCONV=${MSYS_NO_PATHCONV:-}"
                printf '%s\n' "$@"
            } >"$STUB/exec.args"
            printf '%s' "$STUB_EXEC_OUT"
            if [[ -n "$STUB_EXEC_ERR" ]]; then
                echo "$STUB_EXEC_ERR" >&2
            fi
            return "$STUB_EXEC_RC"
            ;;
        logs)
            echo "$*" >>"$STUB/logs.calls"
            mapfile -t calls <"$STUB/logs.calls"
            n=${#calls[@]}
            if [[ $n -gt $STUB_LOG_POLLS ]]; then
                n=$STUB_LOG_POLLS
            fi
            if [[ $n -ge 1 ]]; then
                while IFS= read -r line; do
                    printf '%s\n' "$line"
                done <"$STUB/logs.$n"
            fi
            return "$STUB_LOGS_RC"
            ;;
        start | stop)
            return "$STUB_START_RC"
            ;;
        *)
            echo "docker stub: unexpected compose command: $*" >&2
            return 97
            ;;
    esac
}

# timeout: stands in for timeout(1), under which perf.sh's hard_timeout runs the broker log
# reads and cleanup's start of loadgen. The program timeout(1) would exec is the program file on
# PATH, never the docker function; this one appends its options and limit ("-k GRACE LIMIT" or
# "-s SIGNAL LIMIT") as one line to timeouts and runs the rest of its arguments in this shell,
# so the docker stub answers. It exits with that status, or with STUB_TIMEOUT_RC when that is
# set: the limit cut the call off, as timeout(1) reports it with 124 after TERM and 137 after
# KILL.
timeout() {
    local limits=() rc=0
    while [[ "$1" == -* ]]; do
        limits+=("$1" "$2")
        shift 2
    done
    limits+=("$1")
    shift
    echo "${limits[*]}" >>"$STUB/timeouts"
    "$@" || rc=$?
    if [[ -n "$STUB_TIMEOUT_RC" ]]; then
        return "$STUB_TIMEOUT_RC"
    fi
    return "$rc"
}

# curl: records "METHOD URL[ BODY]" in requests and answers the Nth request with line N of
# responses, "RC<TAB>STATUS<TAB>PAYLOAD". RC 0 writes PAYLOAD as the body and prints what
# -w '%{http_code} %{content_type}' prints; any other RC prints PAYLOAD as curl's error and
# fails with RC. A request without a queued answer fails as a transport error. With
# STUB_SIGNAL_PID set, that process gets SIGTERM while the request is in flight.
curl() {
    local method="GET" body_file="" data="" url="" sent=() answers=() response rc status payload
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
            --data-binary)
                data="$2"
                shift 2
                ;;
            -D | -H | -w | --max-time)
                shift 2
                ;;
            -*)
                shift
                ;;
            *)
                url="$1"
                shift
                ;;
        esac
    done
    printf '%s %s%s\n' "$method" "$url" "${data:+ $data}" >>"$STUB/requests"
    if [[ -n "$STUB_SIGNAL_PID" ]]; then
        kill -TERM "$STUB_SIGNAL_PID"
    fi
    mapfile -t sent <"$STUB/requests"
    mapfile -t answers <"$STUB/responses"
    response="${answers[${#sent[@]} - 1]:-}"
    if [[ -z "$response" ]]; then
        echo "curl: (7) no answer queued for request ${#sent[@]}" >&2
        return 7
    fi
    IFS=$'\t' read -r rc status payload <<<"$response"
    if [[ "$rc" != "0" ]]; then
        echo "$payload" >&2
        return "$rc"
    fi
    printf '%s' "$payload" >"$body_file"
    printf '%s application/json' "$status"
}

# respond RC STATUS [PAYLOAD]: queues the answer to the next curl request.
respond() {
    printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >>"$STUB/responses"
}

# slurp FILE: sets REPLY to FILE's text without its trailing newlines, or to a marker when FILE
# does not exist.
slurp() {
    REPLY=""
    if [[ ! -f "$1" ]]; then
        REPLY="<no file $1>"
        return 0
    fi
    IFS= read -r -d '' REPLY <"$1" || true
    while [[ "$REPLY" == *$'\n' ]]; do
        REPLY="${REPLY%$'\n'}"
    done
}

# Loads perf.sh: its options are parsed, its tools checked and a run directory made. Sourced,
# perf.sh does not call main, so it sets no trap and runs no step. Every assignment perf.sh
# makes at its top level is global, so sourcing it from a function defines the same state as
# sourcing it here.
load_perf() {
    # shellcheck source-path=SCRIPTDIR source=perf.sh
    source "$PERF_SH" --project unit-test --compose-file compose.dev.yaml
}

reset_stubs
load_perf

# From here on SECONDS is an ordinary variable that only the sleep stub advances.
unset SECONDS
SECONDS=0

# sleep: never waits; it records the step and advances SECONDS by it.
sleep() {
    echo "$1" >>"$STUB/sleeps"
    SECONDS=$((SECONDS + $1))
}

# date: one fixed synthetic time, as epoch seconds for +%s and as RFC 3339 otherwise.
date() {
    case " $* " in
        *" +%s "*)
            echo 1767225600
            ;;
        *)
            echo "2026-01-01T00:00:00Z"
            ;;
    esac
}

# ---------------------------------------------------------------------------------------------
# Cases and expectations

t_passed=0
t_failed=0
case_reasons=()

# fresh_state: empty stubs, an empty run directory and perf.sh's state as it is before setup.
fresh_state() {
    local file
    reset_stubs
    RUN_DIR="$CASE_RUN_DIR"
    for file in owned expected deleted armed left-in-place db-error.log compose.log; do
        : >"$RUN_DIR/$file"
    done
    passed=0
    failed=0
    FINISHED=0
    IN_CREATE=0
    PENDING_EXIT=""
    CLEANUP_DONE=0
    CLEANUP_PROBLEMS=""
    FLAG_INITIAL=""
    FLAG_TOUCHED=0
    LOADGEN_WAS_RUNNING=0
    LOADGEN_STOPPED=0
    DIALECT=""
    ARMED_ERROR=""
    OWNED_ERROR=""
    REARM_ERROR=""
    CREATE_ERROR=""
    LOG_SINCE="2026-01-01T00:00:00Z"
    CYCLE_INDEX=""
    CYCLE_LINE=""
    SECONDS=0
}

# run_case NAME BODY: runs the function BODY on a fresh state and prints PASS NAME, or FAIL NAME
# with every reason BODY recorded.
run_case() {
    local name="$1" body="$2" status=0 all
    case_reasons=()
    : >"$STUB/external.calls"
    fresh_state
    "$body" || status=$?
    if [[ $status -ne 0 ]]; then
        case_reasons+=("the case body ended with status $status")
    fi
    slurp "$STUB/external.calls"
    if [[ -n "$REPLY" ]]; then
        case_reasons+=("calls went around the stubs to the program files: $REPLY")
    fi
    if [[ ${#case_reasons[@]} -eq 0 ]]; then
        t_passed=$((t_passed + 1))
        echo "PASS $name"
    else
        printf -v all '%s; ' "${case_reasons[@]}"
        all="${all%; }"
        t_failed=$((t_failed + 1))
        echo "FAIL $name: ${all//$'\n'/\\n}"
    fi
}

# expect ROW EXPECTED ACTUAL: records a reason when the two differ.
expect() {
    if [[ "$2" != "$3" ]]; then
        case_reasons+=("$1: expected [$2], got [$3]")
    fi
}

# joined TEXT...: sets REPLY to the texts joined by newlines.
joined() {
    printf -v REPLY '%s\n' "$@"
    REPLY="${REPLY%$'\n'}"
}

# expect_file ROW FILE LINE...: FILE must hold exactly the given lines.
expect_file() {
    local row="$1" file="$2" want
    shift 2
    joined "$@"
    want="$REPLY"
    slurp "$file"
    expect "$row" "$want" "$REPLY"
}

# count_lines FILE: sets REPLY to the number of lines in FILE.
count_lines() {
    local all=()
    mapfile -t all <"$1"
    REPLY="${#all[@]}"
}

# capture COMMAND...: runs COMMAND in this shell with its output in TEST_OUT and sets OUTCOME
# to "rc=STATUS" followed by that output, if any.
capture() {
    local rc=0
    "$@" >"$TEST_OUT" || rc=$?
    slurp "$TEST_OUT"
    OUTCOME="rc=$rc${REPLY:+ $REPLY}"
}

# alert_id N: sets REPLY to the Nth synthetic alert id.
alert_id() {
    printf -v REPLY 'd0000000-0000-4000-8000-%012d' "$1"
}

# own N...: appends the Nth synthetic alert ids to the owned set.
own() {
    local n
    for n in "$@"; do
        alert_id "$n"
        echo "$REPLY" >>"$RUN_DIR/owned"
    done
}

# ---------------------------------------------------------------------------------------------
# The command line and direct execution

# command_row ROW STATUS STREAM TEXT ARGS...: runs perf.sh as its own process with ARGS and
# expects exit STATUS with TEXT on STREAM (out or err).
command_row() {
    local row="$1" status="$2" stream="$3" text="$4" rc=0
    shift 4
    "$BASH" "$PERF_SH" "$@" >"$RUN_DIR/child.out" 2>"$RUN_DIR/child.err" </dev/null || rc=$?
    expect "$row: exit status" "$status" "$rc"
    slurp "$RUN_DIR/child.$stream"
    if [[ "$REPLY" != *"$text"* ]]; then
        case_reasons+=("$row: std$stream lacks [$text]: $REPLY")
    fi
}

command_line_case() {
    command_row "--help" 0 out "Usage: scripts/portfolio-insights/perf.sh --project NAME" --help
    command_row "no arguments" 2 err "Option --project is required."
    command_row "unknown option" 2 err "Unknown option: --bogus" --project unit-test --bogus
    command_row "--project without a value" 2 err "Option --project requires a value." --project
    command_row "--compose-file followed by an option" 2 err "Option --compose-file requires a value." \
        --project unit-test --compose-file --base-url http://localhost
    command_row "ftp base URL" 2 err "Option --base-url" --project unit-test --base-url ftp://localhost
    command_row "missing compose file" 2 err "Compose file not found: no-such-compose.yaml" \
        --project unit-test --compose-file no-such-compose.yaml
}

# Run directly, perf.sh calls main, whose first step, setup's readiness check, asks docker for
# the running services. The stub knows no such call, so readiness fails, cleanup runs and the
# run ends with its SUMMARY and status 1, with nothing reached outside the stubs.
executed_case() {
    local status=0 calls=() out=()
    (
        export STUB_EXEC_OUT STUB_EXEC_ERR STUB_EXEC_RC STUB_LOGS_RC STUB_LOG_POLLS \
            STUB_START_RC STUB_SIGNAL_PID STUB_TIMEOUT_RC
        export -f docker curl timeout
        "$BASH" "$PERF_SH" --project unit-test --compose-file compose.dev.yaml
    ) >"$RUN_DIR/child.out" 2>"$RUN_DIR/child.err" </dev/null || status=$?
    mapfile -t calls <"$STUB/docker.calls"
    mapfile -t out <"$RUN_DIR/child.out"
    expect "exit status" 1 "$status"
    expect "first docker call" "$COMPOSE_PREFIX ps --status running --services" "${calls[0]:-}"
    if [[ "${out[${#out[@]} - 1]:-}" != "SUMMARY "* ]]; then
        case_reasons+=("last line [${out[${#out[@]} - 1]:-}] is not a SUMMARY")
    fi
}

# ---------------------------------------------------------------------------------------------
# Exact decimals and the percentile

dec_to_units_case() {
    local row
    for row in "1 100000000" "0 0" "0.5 50000000" "12.3456789 1234567890" \
        "0.000000014 1" "0.000000015 2" "0.000000005 1" "0.0000000049 0" \
        "-1.5 -150000000" "-0.000000015 -2" "-0.000000004 0" \
        "0009999999999.99999999 999999999999999999" \
        "9999999999.999999995 1000000000000000000"; do
        capture dec_to_units "${row% *}"
        expect "[${row% *}]" "rc=0 ${row#* }" "$OUTCOME"
    done
}

dec_to_units_rejects_case() {
    local text
    for text in "12345678901" "-12345678901" "" "abc" "1." ".5" "+1" "1e5" "1,5" " 1" \
        "0x10" "1.2.3"; do
        capture dec_to_units "$text"
        expect "[$text]" "rc=1" "$OUTCOME"
    done
}

units_to_dec_case() {
    local row
    for row in "100000000 1" "150000000 1.5" "1 0.00000001" "-150000000 -1.5" \
        "-1 -0.00000001" "0 0" "-0 0" "007 0.00000007" \
        "999999999999999999 9999999999.99999999" "1000000000000000000 10000000000"; do
        capture units_to_dec "${row% *}"
        expect "[${row% *}]" "rc=0 ${row#* }" "$OUTCOME"
    done
}

units_to_dec_rejects_case() {
    local text
    for text in "1.5" "abc" "" "+1" "1 2"; do
        capture units_to_dec "$text"
        expect "[$text]" "rc=1" "$OUTCOME"
    done
}

seconds_to_ms_case() {
    local row
    for row in "0.025289 25.289" "0.5 500" "1 1000" "0 0" "10.0001 10000.1" \
        "0.000000005 0.00001" "0.123456785 123.45679"; do
        capture seconds_to_ms "${row% *}"
        expect "[${row% *}]" "rc=0 ${row#* }" "$OUTCOME"
    done
    for row in "abc" "" "1e-3"; do
        capture seconds_to_ms "$row"
        expect "[$row]" "rc=1" "$OUTCOME"
    done
}

# rank_row ROW EXPECTED PERCENT FILE
rank_row() {
    capture nearest_rank "$3" "$4"
    expect "$1" "rc=0 $2" "$OUTCOME"
}

nearest_rank_case() {
    local i
    : >"$RUN_DIR/two-hundred"
    # 37 is coprime with 200, so this is 0.001 to 0.200 in shuffled order.
    for ((i = 0; i < 200; i++)); do
        printf '0.%03d\n' $(((i * 37) % 200 + 1)) >>"$RUN_DIR/two-hundred"
    done
    printf '%s\n' 0.042 >"$RUN_DIR/one"
    printf '%s\n' 3 1 2 >"$RUN_DIR/three"
    printf '%s\n' 4 1 3 2 >"$RUN_DIR/four"
    printf '%s\n' 100 9 10 >"$RUN_DIR/widths"
    rank_row "95th of 200 is the 190th" 0.190 95 "$RUN_DIR/two-hundred"
    rank_row "50th of 200" 0.100 50 "$RUN_DIR/two-hundred"
    rank_row "100th of 200" 0.200 100 "$RUN_DIR/two-hundred"
    rank_row "1st of 200" 0.002 1 "$RUN_DIR/two-hundred"
    rank_row "95th of 1" 0.042 95 "$RUN_DIR/one"
    rank_row "95th of 3" 3 95 "$RUN_DIR/three"
    rank_row "50th of 4" 2 50 "$RUN_DIR/four"
    rank_row "50th of 100 9 10 sorts numerically" 10 50 "$RUN_DIR/widths"
}

nearest_rank_empty_case() {
    : >"$RUN_DIR/empty"
    capture nearest_rank 95 "$RUN_DIR/empty"
    expect "empty file" "rc=1" "$OUTCOME"
}

# ---------------------------------------------------------------------------------------------
# Cycle lines, sample eligibility and log polling

# cycle_text ALERTS TRIGGERED FAILED SKIPPED OUTCOME DURATION: sets REPLY to the broker's cycle
# summary as broker_logs returns it, padded and ending with the caller name.
cycle_text() {
    printf -v REPLY '[2026-01-01 00:00:00 | Information] Alert evaluation cycle finished: alerts [%s] triggered [%s] failed [%s] skipped [%s] outcome [%s] duration [%s] ms          | AlertEvaluationService' "$@"
}

INSIGHTS_TEXT="[2026-01-01 00:00:00 | Information] Portfolio insights for account [$ACCOUNT_ID]: holdings [15] duration [12] ms          | PortfolioInsightsService"
CANCELLED_TEXT="[2026-01-01 00:00:00 | Information] Alert evaluation cycle cancelled: alerts [1000] triggered [0]          | AlertEvaluationService"

# log_poll N TEXT...: the broker log the Nth logs call prints, each line as the console writes
# it: a coloured level prefix and a carriage return, both of which broker_logs strips.
log_poll() {
    local n="$1" text
    shift
    : >"$STUB/logs.$n"
    for text in "$@"; do
        printf '\033[32m%s\033[0m%s\r\n' "${text%%]*}]" "${text#*]}" >>"$STUB/logs.$n"
    done
    if [[ $n -gt $STUB_LOG_POLLS ]]; then
        STUB_LOG_POLLS=$n
    fi
}

# parse_row ROW LINE EXPECTED: EXPECTED is "rc=N" and the six C_* fields.
parse_row() {
    local rc=0
    C_ALERTS="unset"
    C_TRIGGERED="unset"
    C_FAILED="unset"
    C_SKIPPED="unset"
    C_OUTCOME="unset"
    C_DURATION="unset"
    parse_cycle_line "$2" || rc=$?
    expect "$1" "$3" "rc=$rc $C_ALERTS $C_TRIGGERED $C_FAILED $C_SKIPPED $C_OUTCOME $C_DURATION"
}

parse_cycle_line_case() {
    cycle_text 1000 0 0 0 completed 812
    parse_row "whole milliseconds" "$REPLY" "rc=0 1000 0 0 0 completed 812"
    cycle_text 1000 0 0 0 completed 812.25
    parse_row "decimal duration" "$REPLY" "rc=0 1000 0 0 0 completed 812.25"
    cycle_text 40 2 1 3 failed 5
    parse_row "failed cycle" "$REPLY" "rc=0 40 2 1 3 failed 5"
}

parse_cycle_line_malformed_case() {
    local untouched="rc=1 unset unset unset unset unset unset"
    parse_row "empty" "" "$untouched"
    parse_row "cancelled cycle" "$CANCELLED_TEXT" "$untouched"
    parse_row "insights line" "$INSIGHTS_TEXT" "$untouched"
    parse_row "no duration" "Alert evaluation cycle finished: alerts [1000] triggered [0] failed [0] skipped [0] outcome [completed]" "$untouched"
    cycle_text x 0 0 0 completed 812
    parse_row "non-numeric count" "$REPLY" "$untouched"
    cycle_text 1000 0 0 0 "" 812
    parse_row "empty outcome" "$REPLY" "$untouched"
    cycle_text 1000 0 0 0 completed 812.
    parse_row "duration without fraction digits" "$REPLY" "$untouched"
    cycle_text 1000 0 0 0 completed -5
    parse_row "negative duration" "$REPLY" "$untouched"
}

# clean_row ROW EXPECTED_RC ALERTS TRIGGERED FAILED SKIPPED OUTCOME
clean_row() {
    local rc=0
    C_ALERTS="$3"
    C_TRIGGERED="$4"
    C_FAILED="$5"
    C_SKIPPED="$6"
    C_OUTCOME="$7"
    C_DURATION=812
    cycle_is_clean || rc=$?
    expect "$1" "$2" "$rc"
}

cycle_is_clean_case() {
    clean_row "1000 alerts, nothing triggered, failed or skipped, completed" 0 1000 0 0 0 completed
    clean_row "fewer alerts" 1 999 0 0 0 completed
    clean_row "more alerts" 1 1001 0 0 0 completed
    clean_row "a trigger" 1 1000 1 0 0 completed
    clean_row "a failure" 1 1000 0 1 0 completed
    clean_row "a skip" 1 1000 0 0 1 completed
    clean_row "failed outcome" 1 1000 0 0 0 failed
    clean_row "outcome in another case" 1 1000 0 0 0 Completed
}

wait_after_case() {
    local rc=0 c700 c800 c812 c900
    cycle_text 1000 0 0 0 completed 700
    c700="$REPLY"
    cycle_text 1000 0 0 0 completed 800
    c800="$REPLY"
    cycle_text 1000 1 0 0 completed 812
    c812="$REPLY"
    cycle_text 1000 0 0 0 completed 900
    c900="$REPLY"
    log_poll 1 "$INSIGHTS_TEXT" "$c700" "$CANCELLED_TEXT" "$c800" "$INSIGHTS_TEXT" "$c812" "$c900"
    wait_cycle_line 2 60 >"$TEST_OUT" || rc=$?
    expect "status" 0 "$rc"
    expect "index" 3 "$CYCLE_INDEX"
    expect "line" "$c812" "$CYCLE_LINE"
    expect_file "sleeps" "$STUB/sleeps"
}

wait_other_count_case() {
    local rc=0 c40 c960 c1000
    cycle_text 40 0 0 0 completed 50
    c40="$REPLY"
    cycle_text 960 0 0 0 completed 700
    c960="$REPLY"
    cycle_text 1000 0 0 0 completed 812
    c1000="$REPLY"
    log_poll 1 "$c40"
    log_poll 2 "$c40" "$c960"
    log_poll 3 "$c40" "$c960" "$c1000"
    wait_cycle_line 0 60 1000 >"$TEST_OUT" || rc=$?
    expect "status" 0 "$rc"
    expect "index" 3 "$CYCLE_INDEX"
    expect_file "reports" "$TEST_OUT" \
        "INFO ignoring a cycle that began during setup: alerts [40] triggered [0] failed [0] skipped [0] outcome [completed] duration [50] ms" \
        "INFO ignoring a cycle that began during setup: alerts [960] triggered [0] failed [0] skipped [0] outcome [completed] duration [700] ms"
}

# deadline_row ROW AFTER ALERTS LOGS_RC TEXT...: a 10 s wait with LOG_STEP_SECONDS 5 reads the
# logs at 0 s, bounded by the 10 s left (TERM at 5 s, KILL at 10 s), and at 5 s, bounded by the
# 5 s left (KILL alone). At 10 s no time is left, so no read starts, and the wait gives up,
# having slept only through the stub.
deadline_row() {
    local row="$1" after="$2" wanted="$3" rc=0 steps=() limits=() polls
    fresh_state
    STUB_LOGS_RC="$4"
    shift 4
    log_poll 1 "$@"
    wait_cycle_line "$after" 10 "$wanted" >"$TEST_OUT" || rc=$?
    count_lines "$STUB/logs.calls"
    polls="$REPLY"
    mapfile -t steps <"$STUB/sleeps"
    mapfile -t limits <"$STUB/timeouts"
    printf -v REPLY '%s;' "${limits[@]}"
    expect "$row" "rc=1 polls=2 limits=-k 5 5;-s KILL 5; sleeps=5 5 elapsed=10" \
        "rc=$rc polls=$polls limits=$REPLY sleeps=${steps[*]} elapsed=$SECONDS"
}

wait_deadline_case() {
    cycle_text 1000 0 0 0 completed 700
    deadline_row "only lines up to AFTER" 1 "" 0 "$REPLY"
    cycle_text 40 0 0 0 completed 50
    deadline_row "only another alert count" 0 1000 0 "$REPLY"
    deadline_row "no cycle line" 0 "" 0 "$INSIGHTS_TEXT" "$CANCELLED_TEXT"
    deadline_row "logs unreadable" 0 1000 1
}

# ---------------------------------------------------------------------------------------------
# The armed set

# The whole statement per dialect: the id,revision column of the armed alerts, then the one
# "at," row with the database's UTC time of the statement.
armed_sql_case() {
    DIALECT=mssql
    capture armed_sql
    expect "mssql" \
        "rc=0 SELECT LOWER(CONVERT(varchar(36), [Id])) + ',' + CONVERT(varchar(12), [ArmingRevision]) FROM [dbo].[Alerts] WHERE [Enabled] = 1 AND [TriggeredAt] IS NULL UNION ALL SELECT 'at,' + CONVERT(varchar(27), SYSUTCDATETIME(), 126) ORDER BY 1" \
        "$OUTCOME"
    DIALECT=postgres
    capture armed_sql
    expect "postgres" \
        "rc=0 SELECT lower(\"Id\"::text) || ',' || \"ArmingRevision\" FROM \"Alerts\" WHERE \"Enabled\" = true AND \"TriggeredAt\" IS NULL UNION ALL SELECT 'at,' || to_char(statement_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US') ORDER BY 1" \
        "$OUTCOME"
}

db_query_case() {
    DIALECT=mssql
    db_query "SELECT 1" >"$TEST_OUT" || true
    # shellcheck disable=SC2016 # $SA_PASSWORD and $1 are expanded by the container's shell.
    expect_file "mssql" "$STUB/exec.args" MSYS_NO_PATHCONV=1 "${COMPOSE_ARGS[@]}" exec -T db sh -c \
        '/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -d TradeManagement -b -h -1 -W -Q "$1"' \
        sh "SET NOCOUNT ON; SELECT 1"
    DIALECT=postgres
    db_query "SELECT 1" >"$TEST_OUT" || true
    expect_file "postgres" "$STUB/exec.args" MSYS_NO_PATHCONV=1 "${COMPOSE_ARGS[@]}" exec -T db psql \
        -v ON_ERROR_STOP=1 -U postgres -d TradeManagement -At -F , -c "SELECT 1"
}

# The time row each client prints for the armed-set query, before db_query lower-cases it:
# SQL Server's style-126 text with seven fraction digits, PostgreSQL's to_char text with six.
MSSQL_TIME_ROW="at,2026-01-01T00:00:00.1234567"
POSTGRES_TIME_ROW="at,2026-01-01T00:00:00.123456"

# time_row DIALECT: sets REPLY to the time row of DIALECT's client.
time_row() {
    if [[ "$1" == "mssql" ]]; then
        REPLY="$MSSQL_TIME_ROW"
    else
        REPLY="$POSTGRES_TIME_ROW"
    fi
}

# client_answer DIALECT LINE...: sets REPLY to the LINEs as DIALECT's client answer, each line
# ending in CR LF for mssql and in LF for postgres, so both line ends pass through db_query.
client_answer() {
    local line end=$'\n'
    if [[ "$1" == "mssql" ]]; then
        end=$'\r\n'
    fi
    shift
    REPLY=""
    for line in "$@"; do
        REPLY="$REPLY$line$end"
    done
}

# With no armed alert the answer is the time row alone, and the empty set replaces the one an
# earlier read left.
read_armed_empty_case() {
    local dialect rc emptied
    for dialect in mssql postgres; do
        rc=0
        DIALECT="$dialect"
        time_row "$dialect"
        client_answer "$dialect" "$REPLY"
        STUB_EXEC_OUT="$REPLY"
        echo "a0000000-0000-4000-8000-000000000009,1" >"$RUN_DIR/armed"
        read_armed_set || rc=$?
        emptied="yes"
        if [[ -s "$RUN_DIR/armed" ]]; then
            emptied="no"
        fi
        expect "$dialect" "rc=0 emptied=yes" "rc=$rc emptied=$emptied"
    done
}

# The id,revision rows arrive neither in C order nor in lower case, between blank and white-space
# lines and the time row; the set holds exactly those rows, lower-cased and in C order.
read_armed_populated_case() {
    local dialect rc
    for dialect in mssql postgres; do
        rc=0
        DIALECT="$dialect"
        time_row "$dialect"
        client_answer "$dialect" B0000000-0000-4000-8000-000000000002,1 "" "$REPLY" \
            A0000000-0000-4000-8000-000000000001,3 "  " c0000000-0000-4000-8000-000000000003,1
        STUB_EXEC_OUT="$REPLY"
        read_armed_set || rc=$?
        expect "$dialect status" 0 "$rc"
        expect_file "$dialect set" "$RUN_DIR/armed" a0000000-0000-4000-8000-000000000001,3 \
            b0000000-0000-4000-8000-000000000002,1 c0000000-0000-4000-8000-000000000003,1
    done
}

# armed_failure_row ROW DIALECT RC STDOUT STDERR ERROR: the client exits RC printing STDOUT and
# STDERR. The read fails with an ARMED_ERROR that reports ERROR, clears the ARMED_AT of an
# earlier read and writes no set: a failed read never stands for an armed set, an empty one
# included.
armed_failure_row() {
    local rc=0 written="no"
    DIALECT="$2"
    STUB_EXEC_RC="$3"
    STUB_EXEC_OUT="$4"
    STUB_EXEC_ERR="$5"
    ARMED_ERROR=""
    ARMED_AT="2025-12-31T23:59:59Z"
    : >"$RUN_DIR/db-error.log"
    rm -f "$RUN_DIR/armed"
    read_armed_set || rc=$?
    if [[ -e "$RUN_DIR/armed" ]]; then
        written="yes"
    fi
    expect "$1 status, time and set" "rc=1 at=[] set written=no" \
        "rc=$rc at=[$ARMED_AT] set written=$written"
    if [[ "$ARMED_ERROR" != *"$6"* ]]; then
        case_reasons+=("$1: ARMED_ERROR [$ARMED_ERROR] does not report [$6]")
    fi
}

# client_failure_row ROW DIALECT RC STDOUT STDERR: the client's exit status RC fails the read,
# whatever it printed, and the reason carries the client's STDERR.
client_failure_row() {
    armed_failure_row "$@" "armed-set query failed: $5"
}

read_armed_failure_case() {
    client_failure_row "sqlcmd error" mssql 1 "" \
        "Msg 208, Level 16, State 1, Server db, Line 1 Invalid object name 'dbo.Alerts'."
    time_row mssql
    client_answer mssql a0000000-0000-4000-8000-000000000001,1 "$REPLY"
    client_failure_row "sqlcmd failure after a complete-looking answer" mssql 1 "$REPLY" \
        "Sqlcmd: Error: Microsoft ODBC Driver 17 for SQL Server : Communication link failure."
    client_failure_row "psql error" postgres 1 "" 'ERROR:  relation "Alerts" does not exist'
    client_failure_row "psql connection failure" postgres 2 "" \
        'psql: error: connection to server on socket "/var/run/postgresql/.s.PGSQL.5432" failed'
    client_failure_row "db container not running" mssql 1 "" 'service "db" is not running'
}

# A client that exits 0 without exactly one readable time row has not answered the armed-set
# query: blank lines alone, which would otherwise read as no armed alert; the id rows of a query
# without the time row; a time row in SQL Server's default style instead of style 126.
read_armed_unexpected_case() {
    client_answer mssql "" "   "
    armed_failure_row "blank lines only" mssql 0 "$REPLY" "" \
        "armed-set query returned 0 time rows instead of 1"
    client_answer postgres a0000000-0000-4000-8000-000000000001,1 b0000000-0000-4000-8000-000000000002,1
    armed_failure_row "id rows without the time row" postgres 0 "$REPLY" "" \
        "armed-set query returned 0 time rows instead of 1"
    client_answer mssql a0000000-0000-4000-8000-000000000001,1 "at,Jan  1 2026 12:00AM"
    armed_failure_row "time row in another style" mssql 0 "$REPLY" "" \
        "armed-set query returned an unreadable time row [at,jan  1 2026 12:00am]"
}

read_armed_unknown_dialect_case() {
    local dialect rc
    for dialect in "" sqlite; do
        rc=0
        DIALECT="$dialect"
        ARMED_ERROR=""
        read_armed_set || rc=$?
        count_lines "$STUB/docker.calls"
        expect "[$dialect] status and docker calls" "rc=1 calls=0" "rc=$rc calls=$REPLY"
        if [[ "$ARMED_ERROR" != *"unknown dialect [$dialect]"* ]]; then
            case_reasons+=("[$dialect]: ARMED_ERROR [$ARMED_ERROR] does not name the dialect")
        fi
    done
}

# difference_row ROW EXPECTED EXPECTED_ROWS ARMED_ROWS: rows are separated by spaces; armed rows
# are sorted, as read_armed_set writes them, and expected rows are in creation order.
difference_row() {
    local owned_rows=() armed_rows=()
    read -r -a owned_rows <<<"$3"
    read -r -a armed_rows <<<"$4"
    : >"$RUN_DIR/expected"
    : >"$RUN_DIR/armed"
    if [[ ${#owned_rows[@]} -gt 0 ]]; then
        printf '%s\n' "${owned_rows[@]}" >"$RUN_DIR/expected"
    fi
    if [[ ${#armed_rows[@]} -gt 0 ]]; then
        printf '%s\n' "${armed_rows[@]}" >"$RUN_DIR/armed"
    fi
    capture armed_set_difference
    expect "$1" "rc=0 $2" "$OUTCOME"
}

armed_set_difference_case() {
    local a b c d
    alert_id 1
    a="$REPLY"
    alert_id 2
    b="$REPLY"
    alert_id 3
    c="$REPLY"
    alert_id 4
    d="$REPLY"
    difference_row "identical sets" 0 "$b,1 $a,1" "$a,1 $b,1"
    difference_row "both empty" 0 "" ""
    difference_row "one owned alert not armed" 1 "$a,1 $b,1" "$a,1"
    difference_row "one extra armed alert" 1 "$a,1" "$a,1 $c,1"
    difference_row "one revision changed" 2 "$a,1 $b,1" "$a,2 $b,1"
    difference_row "missing, extra and changed" 4 "$a,1 $b,1 $c,1" "$a,2 $b,1 $d,1"
}

# owned_set_row ROW RC ERROR CLIENT_RC CLIENT_STDERR LINE...: two owned alerts, A and B, at
# revision 1 against the PostgreSQL client's answer LINE..., in which A and B stand for their
# ids. OWNED_ERROR must start with ERROR, or be empty when ERROR is.
owned_set_row() {
    local row="$1" want_rc="$2" want_error="$3" rc=0 a b
    fresh_state
    alert_id 1
    a="$REPLY"
    alert_id 2
    b="$REPLY"
    printf '%s\n' "$a,1" "$b,1" >"$RUN_DIR/expected"
    DIALECT=postgres
    STUB_EXEC_RC="$4"
    STUB_EXEC_ERR="$5"
    shift 5
    client_answer postgres "$@"
    STUB_EXEC_OUT="${REPLY//A/$a}"
    STUB_EXEC_OUT="${STUB_EXEC_OUT//B/$b}"
    OWNED_ERROR=""
    verify_owned_set || rc=$?
    expect "$row status" "$want_rc" "$rc"
    if [[ -z "$want_error" && -n "$OWNED_ERROR" ]] ||
        [[ -n "$want_error" && "$OWNED_ERROR" != "$want_error"* ]]; then
        case_reasons+=("$row: OWNED_ERROR [$OWNED_ERROR] does not start with [$want_error]")
    fi
}

verify_owned_set_case() {
    owned_set_row "armed set equals the owned set" 0 "" 0 "" "$POSTGRES_TIME_ROW" A,1 B,1
    owned_set_row "one owned alert no longer armed" 1 \
        "the armed set and the 2 owned alerts differ in 1 id,revision rows" 0 "" \
        "$POSTGRES_TIME_ROW" A,1
    owned_set_row "armed-set query fails" 1 "armed-set query failed: ERROR:  canceling statement" \
        1 "ERROR:  canceling statement"
}

# rearm_fixture: three owned alerts at revision 1, of which only the first is still armed.
rearm_fixture() {
    local a b c
    alert_id 1
    a="$REPLY"
    alert_id 2
    b="$REPLY"
    alert_id 3
    c="$REPLY"
    printf '%s\n' "$a,1" "$b,1" "$c,1" >"$RUN_DIR/expected"
    printf '%s\n' "$a,1" >"$RUN_DIR/armed"
}

rearm_missing_case() {
    local rc=0 a b c
    rearm_fixture
    alert_id 1
    a="$REPLY"
    alert_id 2
    b="$REPLY"
    alert_id 3
    c="$REPLY"
    respond 0 200 "{\"id\":\"$b\",\"enabled\":true,\"armingRevision\":2}"
    respond 0 200 "{\"id\":\"$c\",\"enabled\":true,\"armingRevision\":2}"
    rearm_missing >"$TEST_OUT" || rc=$?
    expect "status" 0 "$rc"
    expect_file "requests" "$STUB/requests" "PATCH $ALERTS_ENDPOINT/$b {\"enabled\":true}" \
        "PATCH $ALERTS_ENDPOINT/$c {\"enabled\":true}"
    expect_file "expected set" "$RUN_DIR/expected" "$a,1" "$b,2" "$c,2"
    expect_file "report" "$TEST_OUT" "INFO re-armed 2 owned alerts missing from the armed set"
}

# rearm_failure_row ROW RC STATUS BODY ERROR: the first PATCH fails; nothing is re-armed and
# the expected set keeps its revisions.
rearm_failure_row() {
    local rc=0 a b c
    fresh_state
    rearm_fixture
    alert_id 1
    a="$REPLY"
    alert_id 2
    b="$REPLY"
    alert_id 3
    c="$REPLY"
    respond "$2" "$3" "$4"
    REARM_ERROR=""
    rearm_missing >"$TEST_OUT" || rc=$?
    expect "$1 status and error" "rc=1 error=[PATCH alert [$b] gave $5]" "rc=$rc error=[$REARM_ERROR]"
    expect_file "$1 expected set" "$RUN_DIR/expected" "$a,1" "$b,1" "$c,1"
}

rearm_missing_failure_case() {
    rearm_failure_row "alert gone" 0 404 '{"error":"not_found"}' "status 404"
    rearm_failure_row "200 without a revision" 0 200 '{"enabled":true}' "status 200"
    rearm_failure_row "transport error" 7 000 "$CONNECT_ERROR" "transport error ($CONNECT_ERROR)"
}

# ---------------------------------------------------------------------------------------------
# Alert creation

# post_row THRESHOLD: post_alert for the fixture account and instrument on a fresh state; sets
# POST_RC, POST_OWNED and POST_EXPECTED.
post_row() {
    POST_RC=0
    post_alert "$ACCOUNT_ID" TARGET_PRICE "$INSTRUMENT_ID" ABOVE "$1" || POST_RC=$?
    slurp "$RUN_DIR/owned"
    POST_OWNED="$REPLY"
    slurp "$RUN_DIR/expected"
    POST_EXPECTED="$REPLY"
}

# expect_post ROW RC OWNED EXPECTED ERROR: the outcome of the last post_row.
expect_post() {
    expect "$1" "rc=$2 owned=[$3] expected=[$4] error=[$5]" \
        "rc=$POST_RC owned=[$POST_OWNED] expected=[$POST_EXPECTED] error=[$CREATE_ERROR]"
}

post_threshold_case() {
    local threshold
    for threshold in "1e5" "abc" "01.5" "1." ".5" "+1" "" "1.5 " '1,"enabled":false' "--1" "0x1F"; do
        fresh_state
        post_row "$threshold"
        expect_post "[$threshold]" 1 "" "" "threshold [$threshold] is not a plain decimal token"
        count_lines "$STUB/requests"
        expect "[$threshold] requests" 0 "$REPLY"
    done
}

post_token_case() {
    local threshold
    for threshold in "9999999999.99999999" "-0.5" "1.500000000"; do
        fresh_state
        respond 0 201 "{\"id\":\"$ALERT_ID\",\"armingRevision\":1}"
        post_row "$threshold"
        expect_file "[$threshold]" "$STUB/requests" \
            "POST $ALERTS_ENDPOINT {\"accountId\":\"$ACCOUNT_ID\",\"type\":\"TARGET_PRICE\",\"instrumentId\":\"$INSTRUMENT_ID\",\"direction\":\"ABOVE\",\"threshold\":$threshold}"
    done
}

# transport_row ROW CURL_RC MESSAGE
transport_row() {
    fresh_state
    respond "$2" 000 "$3"
    post_row 1.5
    expect_post "$1" 1 "" "" "transport error ($3); the alert may exist without an id this run knows"
}

post_transport_case() {
    transport_row "connection refused" 7 \
        "curl: (7) Failed to connect to localhost port 80 after 0 ms: Could not connect to server"
    transport_row "timeout" 28 \
        "curl: (28) Operation timed out after 15000 milliseconds with 0 bytes received"
}

post_status_case() {
    local status
    for status in 200 400 403 500; do
        fresh_state
        respond 0 "$status" '{"error":"rejected"}'
        post_row 1.5
        expect_post "$status" 1 "" "" "status $status"
    done
}

post_no_id_case() {
    local body
    for body in '{}' '{"id":"not-a-uuid","armingRevision":1}' \
        '{"id":"d0000000-0000-4000-8000-0000000000a","armingRevision":1}' 'not json' ''; do
        fresh_state
        respond 0 201 "$body"
        post_row 1.5
        expect_post "[$body]" 1 "" "" \
            "201 without a readable id; the created alert cannot be deleted by this run"
    done
}

post_no_revision_case() {
    local body
    for body in '{"id":"D0000000-0000-4000-8000-0000000000AB"}' \
        '{"id":"d0000000-0000-4000-8000-0000000000ab","armingRevision":null}' \
        '{"id":"d0000000-0000-4000-8000-0000000000ab","armingRevision":"x"}' \
        '{"id":"d0000000-0000-4000-8000-0000000000ab","armingRevision":1.5}'; do
        fresh_state
        respond 0 201 "$body"
        post_row 1.5
        expect_post "[$body]" 1 "$ALERT_ID" "" "201 for alert [$ALERT_ID] without a readable armingRevision"
    done
}

# An interrupt while the POST is in flight is held until the returned id is recorded, so
# cleanup can still delete the alert; the run then exits 130.
create_interrupt_case() {
    local status=0
    respond 0 201 "{\"id\":\"$ALERT_ID\",\"armingRevision\":1}"
    (
        trap on_signal INT TERM
        STUB_SIGNAL_PID="$BASHPID"
        create_alert "$ACCOUNT_ID" TARGET_PRICE "$INSTRUMENT_ID" ABOVE 1.5
        echo "create_alert returned"
    ) >"$TEST_OUT" 2>&1 || status=$?
    expect "exit status" 130 "$status"
    expect_file "output" "$TEST_OUT"
    expect_file "owned" "$RUN_DIR/owned" "$ALERT_ID"
    expect_file "expected" "$RUN_DIR/expected" "$ALERT_ID,1"
}

# ---------------------------------------------------------------------------------------------
# Cleanup and exit

# delete_fixture: owned ids 3, 1, 2, 4, 5, 1 again and 6, where 6 is already deleted; the five
# remaining ids get 204, 404, 500, 403 and a transport error, in sorted order.
delete_fixture() {
    own 3 1 2 4 5 1 6
    alert_id 6
    echo "$REPLY" >"$RUN_DIR/deleted"
    respond 0 204
    respond 0 404 '{"error":"not_found"}'
    respond 0 500 '{"error":"internal"}'
    respond 0 403 '{"error":"feature_disabled"}'
    respond 7 000 "$CONNECT_ERROR"
    delete_owned_alerts >"$TEST_OUT"
}

delete_requests_case() {
    local ids=() n
    delete_fixture
    for n in 1 2 3 4 5; do
        alert_id "$n"
        ids+=("DELETE $ALERTS_ENDPOINT/$REPLY")
    done
    expect_file "requests" "$STUB/requests" "${ids[@]}"
}

delete_statuses_case() {
    local out=() i1 i2 i3 i4 i5 i6
    delete_fixture
    alert_id 1
    i1="$REPLY"
    alert_id 2
    i2="$REPLY"
    alert_id 3
    i3="$REPLY"
    alert_id 4
    i4="$REPLY"
    alert_id 5
    i5="$REPLY"
    alert_id 6
    i6="$REPLY"
    expect_file "deleted" "$RUN_DIR/deleted" "$i6" "$i1" "$i2"
    expect_file "left in place" "$RUN_DIR/left-in-place" "$i3 status 500" "$i4 status 403" \
        "$i5 transport error ($CONNECT_ERROR)"
    expect "problems" "3 owned alerts left in place, ids in $RUN_DIR/left-in-place" "$CLEANUP_PROBLEMS"
    mapfile -t out <"$TEST_OUT"
    expect "summary" "INFO cleanup: 1 alerts deleted, 1 already absent, 3 left in place, 0 not attempted" \
        "${out[${#out[@]} - 1]:-}"
}

# cutoff_row ROW EXPECTED STATUS...: owned ids 1 to MAX_CONSECUTIVE_TRANSPORT_ERRORS + 2, each
# STATUS answering one DELETE in order (000 is a transport error).
cutoff_row() {
    local row="$1" expected="$2" status i requests left=() skipped=0
    shift 2
    fresh_state
    for ((i = 1; i <= MAX_CONSECUTIVE_TRANSPORT_ERRORS + 2; i++)); do
        own "$i"
    done
    for status in "$@"; do
        if [[ "$status" == "000" ]]; then
            respond 7 000 "$CONNECT_ERROR"
        else
            respond 0 "$status"
        fi
    done
    delete_owned_alerts >"$TEST_OUT"
    count_lines "$STUB/requests"
    requests="$REPLY"
    mapfile -t left <"$RUN_DIR/left-in-place"
    for i in "${left[@]}"; do
        if [[ "$i" == *" not attempted" ]]; then
            skipped=$((skipped + 1))
        fi
    done
    expect "$row" "$expected" \
        "requests=$requests not attempted=$skipped problems=${CLEANUP_PROBLEMS//$RUN_DIR/RUN}"
}

delete_cutoff_case() {
    local max="$MAX_CONSECUTIVE_TRANSPORT_ERRORS" total errors=() i
    total=$((max + 2))
    for ((i = 1; i < max; i++)); do
        errors+=(000)
    done
    cutoff_row "only transport errors" \
        "requests=$max not attempted=2 problems=$total owned alerts left in place, ids in RUN/left-in-place" \
        "${errors[@]}" 000 000 000
    cutoff_row "an HTTP status resets the count" \
        "requests=$total not attempted=0 problems=$total owned alerts left in place, ids in RUN/left-in-place" \
        "${errors[@]}" 500 000 000
    cutoff_row "a 404 resets the count" \
        "requests=$total not attempted=0 problems=$((total - 1)) owned alerts left in place, ids in RUN/left-in-place" \
        "${errors[@]}" 404 000 000
}

# cleanup_row_start OWNED FLAG_TOUCHED FLAG_INITIAL: one owned id when OWNED is 1, and a
# problem left over from an earlier cleanup, which a new cleanup must not report again.
cleanup_row_start() {
    fresh_state
    if [[ "$1" -eq 1 ]]; then
        own 1
    fi
    FLAG_TOUCHED="$2"
    FLAG_INITIAL="$3"
    CLEANUP_PROBLEMS="a problem from an earlier cleanup"
}

# cleanup_row_end ROW REQUEST...: cleanup_all sends exactly the REQUESTs, reports no problem
# and marks cleanup done.
cleanup_row_end() {
    local row="$1"
    shift
    cleanup_all >"$TEST_OUT"
    expect_file "$row requests" "$STUB/requests" "$@"
    expect "$row problems and done" "problems=[] done=1" "problems=[$CLEANUP_PROBLEMS] done=$CLEANUP_DONE"
}

FLAG_ON='{"id":"portfolio-insights-enabled","enabled":true,"isModifiable":true}'
FLAG_OFF='{"id":"portfolio-insights-enabled","enabled":false,"isModifiable":true}'

cleanup_flag_case() {
    local delete
    alert_id 1
    delete="DELETE $ALERTS_ENDPOINT/$REPLY"

    cleanup_row_start 0 0 ""
    cleanup_row_end "nothing owned, flag untouched"

    cleanup_row_start 0 1 false
    respond 0 200 "$FLAG_OFF"
    cleanup_row_end "nothing owned, flag touched" "PUT $FLAG_ENDPOINT {\"enabled\": false}"

    cleanup_row_start 1 1 false
    respond 0 200 "$FLAG_OFF"
    respond 0 200 "$FLAG_ON"
    respond 0 204
    respond 0 200 "$FLAG_OFF"
    cleanup_row_end "owned alert, flag off" "GET $FLAG_ENDPOINT" \
        "PUT $FLAG_ENDPOINT {\"enabled\": true}" "$delete" "PUT $FLAG_ENDPOINT {\"enabled\": false}"

    cleanup_row_start 1 0 false
    respond 0 200 "$FLAG_OFF"
    respond 0 200 "$FLAG_ON"
    respond 0 204
    respond 0 200 "$FLAG_OFF"
    cleanup_row_end "owned alert, flag off and not yet touched" "GET $FLAG_ENDPOINT" \
        "PUT $FLAG_ENDPOINT {\"enabled\": true}" "$delete" "PUT $FLAG_ENDPOINT {\"enabled\": false}"

    cleanup_row_start 1 1 true
    respond 0 200 "$FLAG_ON"
    respond 0 204
    respond 0 200 "$FLAG_ON"
    cleanup_row_end "owned alert, flag on" "GET $FLAG_ENDPOINT" "$delete" \
        "PUT $FLAG_ENDPOINT {\"enabled\": true}"

    cleanup_row_start 1 0 false
    respond 7 000 "$CONNECT_ERROR"
    respond 0 204
    cleanup_row_end "owned alert, flag unreadable and untouched" "GET $FLAG_ENDPOINT" "$delete"

    cleanup_row_start 0 1 ""
    cleanup_row_end "flag touched before its value was read"
}

cleanup_flag_not_on_case() {
    own 1
    FLAG_TOUCHED=1
    FLAG_INITIAL=false
    respond 0 200 "$FLAG_OFF"
    respond 0 503 '{"error":"unavailable"}'
    respond 0 403 '{"error":"feature_disabled"}'
    respond 0 200 "$FLAG_OFF"
    cleanup_all >"$TEST_OUT"
    expect "problems" \
        "flag could not be switched on for deletion: status 503; 1 owned alerts left in place, ids in $RUN_DIR/left-in-place" \
        "$CLEANUP_PROBLEMS"
}

cleanup_restore_fails_case() {
    FLAG_TOUCHED=1
    FLAG_INITIAL=false
    respond 0 500 '{"error":"internal"}'
    cleanup_all >"$TEST_OUT"
    expect "status 500" "flag portfolio-insights-enabled not restored to enabled=false: status 500" \
        "$CLEANUP_PROBLEMS"
    fresh_state
    FLAG_TOUCHED=1
    FLAG_INITIAL=true
    respond 7 000 "$CONNECT_ERROR"
    cleanup_all >"$TEST_OUT"
    expect "transport error" \
        "flag portfolio-insights-enabled not restored to enabled=true: transport error ($CONNECT_ERROR)" \
        "$CLEANUP_PROBLEMS"
}

# loadgen_row ROW STOPPED START_RC CUT_RC CALL LIMIT PROBLEMS: CUT_RC is the status with which
# the call's hard limit cuts it off, "-" when it ends by itself; LIMIT is the bound the start
# runs under, as the timeout stub records it.
loadgen_row() {
    local calls
    fresh_state
    LOADGEN_STOPPED="$2"
    STUB_START_RC="$3"
    if [[ "$4" != "-" ]]; then
        STUB_TIMEOUT_RC="$4"
    fi
    cleanup_all >"$TEST_OUT"
    slurp "$STUB/docker.calls"
    calls="$REPLY"
    slurp "$STUB/timeouts"
    expect "$1" "calls=[$5] limit=[$6] problems=[$7]" \
        "calls=[$calls] limit=[$REPLY] problems=[${CLEANUP_PROBLEMS//$RUN_DIR/RUN}]"
}

LOADGEN_NOT_STARTED="loadgen was running at start and could not be started again"

# The start of loadgen has ended, killed if need be, by DOCKER_CALL_TIMEOUT_SECONDS: TERM comes
# at 55 s and KILL at 60 s.
cleanup_loadgen_case() {
    loadgen_row "stopped, starts again" 1 0 - "$COMPOSE_PREFIX start loadgen" "-k 5 55" ""
    loadgen_row "stopped, start fails" 1 1 - "$COMPOSE_PREFIX start loadgen" "-k 5 55" \
        "$LOADGEN_NOT_STARTED: compose start loadgen failed, exit 1 (see RUN/compose.log)"
    loadgen_row "stopped, start cut off by TERM at the limit" 1 0 124 \
        "$COMPOSE_PREFIX start loadgen" "-k 5 55" \
        "$LOADGEN_NOT_STARTED: compose start loadgen timed out after 60 s (Docker did not answer)"
    loadgen_row "stopped, start cut off by KILL at the limit" 1 0 137 \
        "$COMPOSE_PREFIX start loadgen" "-k 5 55" \
        "$LOADGEN_NOT_STARTED: compose start loadgen timed out after 60 s (Docker did not answer)"
    loadgen_row "never stopped" 0 0 - "" "" ""
}

# exit_lines FILE: sets REPLY to the PASS, FAIL and SUMMARY lines of FILE joined by |, with the
# run directory written as RUN.
exit_lines() {
    local all=() line
    REPLY=""
    mapfile -t all <"$1"
    for line in "${all[@]}"; do
        if [[ "$line" == "PASS "* || "$line" == "FAIL "* || "$line" == "SUMMARY "* ]]; then
            REPLY="$REPLY${line//$RUN_DIR/RUN}|"
        fi
    done
}

# finish_row ROW PASSED FAILED START_RC EXPECTED: START_RC "-" means loadgen was not stopped.
finish_row() {
    local status=0
    fresh_state
    passed="$2"
    failed="$3"
    if [[ "$4" != "-" ]]; then
        LOADGEN_STOPPED=1
        STUB_START_RC="$4"
    fi
    (finish) >"$TEST_OUT" 2>&1 || status=$?
    exit_lines "$TEST_OUT"
    expect "$1" "$5" "status=$status $REPLY"
}

finish_case() {
    finish_row "clean run" 2 0 - "status=0 PASS cleanup|SUMMARY 3 passed, 0 failed|"
    finish_row "cleanup problem" 2 0 1 \
        "status=1 FAIL cleanup: $LOADGEN_NOT_STARTED: compose start loadgen failed, exit 1 (see RUN/compose.log)|SUMMARY 2 passed, 1 failed|"
    finish_row "earlier failure" 1 1 - "status=1 PASS cleanup|SUMMARY 2 passed, 1 failed|"
}

abort_case() {
    local status=0
    (abort "readiness" "services not running in project [unit-test]: db") >"$TEST_OUT" 2>&1 ||
        status=$?
    exit_lines "$TEST_OUT"
    expect "abort" \
        "status=1 FAIL readiness: services not running in project [unit-test]: db|PASS cleanup|SUMMARY 1 passed, 1 failed|" \
        "status=$status $REPLY"
}

# on_exit_row ROW EXIT_STATUS FINISHED CLEANUP_DONE OWNED START_RC EXPECTED: the run exits
# with EXIT_STATUS anywhere but finish; OWNED 1 leaves one owned id, START_RC as in finish_row.
on_exit_row() {
    local status=0 requests
    fresh_state
    FINISHED="$3"
    CLEANUP_DONE="$4"
    if [[ "$5" -eq 1 ]]; then
        own 1
    fi
    if [[ "$6" != "-" ]]; then
        LOADGEN_STOPPED=1
        STUB_START_RC="$6"
    fi
    (
        trap on_exit EXIT
        exit "$2"
    ) >"$TEST_OUT" 2>&1 || status=$?
    count_lines "$STUB/requests"
    requests="$REPLY"
    exit_lines "$TEST_OUT"
    expect "$1" "$7" "status=$status requests=$requests $REPLY"
}

on_exit_case() {
    on_exit_row "error status kept" 3 0 0 0 - \
        "status=3 requests=0 PASS cleanup|SUMMARY 1 passed, 0 failed|"
    on_exit_row "status 0 becomes 1" 0 0 0 0 - \
        "status=1 requests=0 PASS cleanup|SUMMARY 1 passed, 0 failed|"
    on_exit_row "interrupt with a cleanup problem" 130 0 0 0 1 \
        "status=130 requests=0 FAIL cleanup: $LOADGEN_NOT_STARTED: compose start loadgen failed, exit 1 (see RUN/compose.log)|SUMMARY 0 passed, 1 failed|"
    on_exit_row "cleanup already done" 4 0 1 1 - "status=4 requests=0 SUMMARY 0 passed, 0 failed|"
    on_exit_row "after finish" 0 1 1 0 - "status=0 requests=0 "
    on_exit_row "after finish with a failure" 1 1 1 0 - "status=1 requests=0 "
}

# ---------------------------------------------------------------------------------------------
# The evaluation interval

interval_row() {
    capture resolve_interval "$2"
    expect "$1" "rc=0 $3" "$OUTCOME"
}

resolve_interval_case() {
    interval_row "unset" "" 60
    interval_row "abc" "abc" 60
    interval_row "0" "0" 60
    interval_row "-5" "-5" 60
    interval_row "4294968" "4294968" 60
    interval_row "[ 15 ]" " 15 " 15
    interval_row "4294967" "4294967" 4294967
    interval_row "+15" "+15" 15
    interval_row "015" "015" 15
    interval_row "000" "000" 60
    interval_row "-0" "-0" 60
    interval_row "1.5" "1.5" 60
    interval_row "20 digits" "99999999999999999999" 60
    interval_row "tab and newline" $'\t30\n' 30
}

# ---------------------------------------------------------------------------------------------
# Main

run_case "perfSh_commandLine_exitsWithUsageStatus" command_line_case
run_case "perfSh_executedDirectly_runsMainFlow" executed_case
run_case "decToUnits_plainDecimal_roundsHalfAwayFromZero" dec_to_units_case
run_case "decToUnits_outsideDomain_returnsOne" dec_to_units_rejects_case
run_case "unitsToDec_integerUnits_printsNormalisedDecimal" units_to_dec_case
run_case "unitsToDec_nonInteger_returnsOne" units_to_dec_rejects_case
run_case "secondsToMs_decimalSeconds_printsExactMilliseconds" seconds_to_ms_case
run_case "nearestRank_percentOfSet_returnsNearestRankValue" nearest_rank_case
run_case "nearestRank_emptyFile_returnsOne" nearest_rank_empty_case
run_case "parseCycleLine_summaryLine_setsCycleFields" parse_cycle_line_case
run_case "parseCycleLine_malformedLine_returnsOneWithoutFields" parse_cycle_line_malformed_case
run_case "cycleIsClean_cycleFields_cleanOnlyForExpectedCompletedCycle" cycle_is_clean_case
run_case "waitCycleLine_linesAfterBase_returnsFirstLaterCycleAndIndex" wait_after_case
run_case "waitCycleLine_otherAlertCount_skipsAndReportsEachOnce" wait_other_count_case
run_case "waitCycleLine_noQualifyingLine_returnsOneAtDeadline" wait_deadline_case
run_case "armedSql_dialect_rendersExactQuery" armed_sql_case
run_case "dbQuery_dialect_sendsContainerClientInvocation" db_query_case
run_case "readArmedSet_emptyResult_writesEmptySet" read_armed_empty_case
run_case "readArmedSet_populatedRows_writesSortedLowerCaseSet" read_armed_populated_case
run_case "readArmedSet_clientFails_returnsOneWithErrorAndNoSet" read_armed_failure_case
run_case "readArmedSet_unexpectedClientOutput_returnsOneWithoutSet" read_armed_unexpected_case
run_case "readArmedSet_unknownDialect_returnsOneWithoutQuery" read_armed_unknown_dialect_case
run_case "armedSetDifference_expectedAndArmed_countsUnmatchedRows" armed_set_difference_case
run_case "verifyOwnedSet_armedSet_passesOnlyWhenEqual" verify_owned_set_case
run_case "rearmMissing_triggeredOwnedAlerts_patchesAndRecordsNewRevision" rearm_missing_case
run_case "rearmMissing_patchFails_returnsOneKeepingRevisions" rearm_missing_failure_case
run_case "postAlert_thresholdNotPlainToken_rejectsBeforeRequest" post_threshold_case
run_case "postAlert_plainToken_sendsThresholdUnconverted" post_token_case
run_case "postAlert_transportError_reportsUnknownOutcome" post_transport_case
run_case "postAlert_non201Status_returnsOneWithStatus" post_status_case
run_case "postAlert_201WithoutUuid_returnsOneNotOwned" post_no_id_case
run_case "postAlert_201WithoutRevision_ownsIdWithoutExpectingIt" post_no_revision_case
run_case "createAlert_interruptDuringPost_exitsAfterRecordingId" create_interrupt_case
run_case "deleteOwnedAlerts_ownedIds_deletesEachUndeletedIdOnce" delete_requests_case
run_case "deleteOwnedAlerts_responseStatuses_recordsCleanAndLeftInPlace" delete_statuses_case
run_case "deleteOwnedAlerts_consecutiveTransportErrors_stopsAtCutoff" delete_cutoff_case
run_case "cleanupAll_flagAndOwnedAlerts_switchesFlagOnlyToDeleteThenRestores" cleanup_flag_case
run_case "cleanupAll_flagNotSwitchedOn_recordsProblem" cleanup_flag_not_on_case
run_case "cleanupAll_flagRestoreFails_recordsProblem" cleanup_restore_fails_case
run_case "cleanupAll_loadgenStopped_startsLoadgenOrRecordsProblem" cleanup_loadgen_case
run_case "finish_cleanupOutcome_reportsCleanupAndExitStatus" finish_case
run_case "abort_failedCheck_failsCheckThenFinishes" abort_case
run_case "onExit_runEndsEarly_cleansUpOnceAndKeepsFailureStatus" on_exit_case
run_case "resolveInterval_rawSetting_appliesBrokerRule" resolve_interval_case

echo "SUMMARY ${t_passed} passed, ${t_failed} failed"
if [[ $t_failed -ne 0 ]]; then
    exit 1
fi
