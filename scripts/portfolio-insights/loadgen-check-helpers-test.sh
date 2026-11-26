#!/usr/bin/env bash
# Unit tests of the helpers in scripts/portfolio-insights/loadgen-check.sh that its own suite,
# scripts/portfolio-insights/loadgen-check-test.sh, and scripts/portfolio-insights/harness-test.sh
# leave uncovered, run without a stack:
#   - option parsing, the count rule of --weight and --minutes, and the tool check;
#   - the HTTP wrapper, the bounded poll and loadgen's output read through Compose;
#   - the stats-line parser, the visit-family rules applied to its breakdown, the family, failRate
#     and run A/B comparison checks built on them, and the per-minute progress lines;
#   - setup's stack checks, the flag switch, the weighted loadgen recreate, the wait for the
#     first visit and run A;
#   - the created, resolved and unresolved ids of loadgen's output, the ids it owns for cleanup,
#     and the count of visits between opening the page and their create outcome;
#   - the read-only Alerts count: SQL and client per dialect, refusal of non-canonical ids,
#     chunking, aggregation across chunks and client failures;
#   - run B's outcomes check, the per-family table, the end of the run and the cleanup run on
#     exit: owned alerts deleted, the flag restored, and the exit status.
# loadgen-check-test.sh covers the rest: run B's drain and owned-id audit, loadgen's log
# sanitizer, the restore of loadgen and the flag-off window. harness-test.sh covers
# container_env, the time limits of the bounded Docker calls and the cleanup of a window still
# open.
# The script is sourced, which defines its functions without running it. docker, curl, date and
# sleep are then replaced by bash functions that record each call and answer from files the case
# writes: loadgen's output, a fake Alerts table, HTTP responses and a fake clock. timeout is
# replaced too, so the Docker calls the script bounds with timeout(1) reach the docker stub.
# Nothing reaches Docker, the network or a database, and no case waits in real time. The
# harness itself starts as few processes as it can, since each one is slow to start under Git
# Bash.
#
# Usage: scripts/portfolio-insights/loadgen-check-helpers-test.sh [--help]
#   --help  Show this help and exit
#
# Needs bash, jq and coreutils. Prints one PASS or FAIL line per case, where a matrix case names
# each failing row, and a final SUMMARY line. Exits 0 when every case passes, 1 when any case
# fails, and 2 on a usage error, a missing tool or a loadgen-check.sh that cannot be sourced. The
# run's temporary directory is removed on exit.

set -euo pipefail

T_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T_SCRIPT="$T_DIR/loadgen-check.sh"

t_usage() {
    cat <<'EOF'
Usage: scripts/portfolio-insights/loadgen-check-helpers-test.sh [--help]
  --help  Show this help and exit
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            t_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            t_usage >&2
            exit 2
            ;;
    esac
done

for t_tool in jq awk sed grep sort comm paste tr wc mktemp cmp; do
    if ! command -v "$t_tool" >/dev/null 2>&1; then
        echo "$t_tool is required on PATH." >&2
        exit 2
    fi
done
if [[ ! -f "$T_SCRIPT" ]]; then
    echo "loadgen-check.sh not found next to this test: $T_SCRIPT" >&2
    exit 2
fi

T_TMP=""
t_cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$T_TMP" ]]; then
        rm -rf "$T_TMP"
    fi
    exit "$status"
}
trap t_cleanup EXIT
trap 'exit 130' INT TERM

if ! T_TMP="$(mktemp -d "${TMPDIR:-/tmp}/loadgen-check-helpers-test.XXXXXX")"; then
    echo "Could not create a temporary directory under ${TMPDIR:-/tmp}." >&2
    exit 2
fi
# The case directories, made in one process rather than one per case.
mkdir -p "$T_TMP"/case-{1..100}/{run,stub}

# shellcheck source-path=SCRIPTDIR source=loadgen-check.sh
if ! source "$T_SCRIPT"; then
    echo "Sourcing $T_SCRIPT failed." >&2
    exit 2
fi

# Bounds of the first-visit wait and of run B's drain, shortened so a case that never gets there
# takes two or three polls of the fake clock.
START_TIMEOUT_SECONDS=10
START_STEP_SECONDS=5
QUIESCE_TIMEOUT_SECONDS=5
QUIESCE_STEP_SECONDS=5

# Synthetic canonical alert ids.
ID1="00000001-0000-4000-8000-000000000001"
ID2="00000002-0000-4000-8000-000000000002"
ID3="00000003-0000-4000-8000-000000000003"
ID4="00000004-0000-4000-8000-000000000004"
ID5="00000005-0000-4000-8000-000000000005"
# 36 dashes: as long as a UUID, but not one.
printf -v T_DASHES '%36s' ''
T_DASHES="${T_DASHES// /-}"
# The message the stub curl prints on a transport error.
T_CURL_REFUSED="curl: (7) Failed to connect to stub.invalid port 80: Connection refused"

# ---------------------------------------------------------------------------------------------
# Reporting

cases_passed=0
cases_failed=0
t_reasons=()

# t_text TEXT: TEXT on one line, for a FAIL reason.
t_text() {
    local text="${1//$'\r'/\\r}"
    printf '%s' "${text//$'\n'/\\n}"
}

# t_expect WHAT ACTUAL EXPECTED: records a reason when ACTUAL is not EXPECTED.
t_expect() {
    if [[ "$2" != "$3" ]]; then
        t_reasons+=("$1: got [$(t_text "$2")], expected [$(t_text "$3")]")
    fi
}

# t_has_line FILE LINE: whether FILE holds LINE as a whole line.
t_has_line() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$2" ]]; then
            return 0
        fi
    done <"$1"
    return 1
}

# t_has_match FILE ERE: whether a line of FILE matches ERE.
t_has_match() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ $2 ]]; then
            return 0
        fi
    done <"$1"
    return 1
}

# t_expect_line WHAT FILE LINE: FILE holds LINE as a whole line.
t_expect_line() {
    if ! t_has_line "$2" "$3"; then
        t_reasons+=("$1: no line [$3] in ${2##*/} [$(t_text "$(<"$2")")]")
    fi
}

# t_expect_match WHAT FILE ERE: a line of FILE matches ERE.
t_expect_match() {
    if ! t_has_match "$2" "$3"; then
        t_reasons+=("$1: no line matching [$3] in ${2##*/} [$(t_text "$(<"$2")")]")
    fi
}

# t_expect_no_match WHAT FILE ERE: no line of FILE matches ERE.
t_expect_no_match() {
    if t_has_match "$2" "$3"; then
        t_reasons+=("$1: a line of ${2##*/} matches [$3]: [$(t_text "$(<"$2")")]")
    fi
}

# t_conclude CASE: one PASS or FAIL line for CASE from the reasons recorded since the last call.
t_conclude() {
    local joined
    if [[ ${#t_reasons[@]} -eq 0 ]]; then
        cases_passed=$((cases_passed + 1))
        echo "PASS $1"
    else
        printf -v joined '%s; ' "${t_reasons[@]}"
        cases_failed=$((cases_failed + 1))
        echo "FAIL $1: ${joined%; }"
    fi
    t_reasons=()
}

# t_count FILE: the number of lines in FILE.
t_count() {
    local -a lines=()
    mapfile -t lines <"$1"
    echo "${#lines[@]}"
}

# t_lines FILE: the lines of FILE separated by spaces.
t_lines() {
    local -a lines=()
    mapfile -t lines <"$1"
    echo "${lines[*]}"
}

# ---------------------------------------------------------------------------------------------
# Case state and stubs

T_CASE_NO=0

# t_new_case: a fresh run directory and stub directory, and the globals main and setup would
# have set, for the next case or matrix row.
t_new_case() {
    T_CASE_NO=$((T_CASE_NO + 1))
    T_CASE_DIR="$T_TMP/case-$T_CASE_NO"
    RUN_DIR="$T_CASE_DIR/run"
    STUB_DIR="$T_CASE_DIR/stub"
    if [[ ! -d "$RUN_DIR" || ! -d "$STUB_DIR" ]]; then
        mkdir -p "$RUN_DIR" "$STUB_DIR"
    fi
    : >"$RUN_DIR/owned"
    : >"$RUN_DIR/deleted"
    : >"$RUN_DIR/new-owned"
    : >"$RUN_DIR/verdicts"
    : >"$STUB_DIR/loadgen.log"
    : >"$STUB_DIR/alerts.rows"
    : >"$STUB_DIR/http.responses"
    : >"$STUB_DIR/http.calls"
    : >"$STUB_DIR/docker.calls"
    : >"$STUB_DIR/queries"
    : >"$STUB_DIR/sleeps"
    PROJECT="et-test"
    COMPOSE_FILES=("compose.dev.yaml")
    COMPOSE_ARGS=(-f compose.dev.yaml)
    BASE_URL="http://stub.invalid"
    FLAG_URL="$BASE_URL/feature-flag-service/v1/flags/$FLAG_ID"
    ALERTS_URL="$BASE_URL/broker-service/v1/alerts"
    DIALECT="postgres"
    WEIGHT="1"
    MINUTES="35"
    OUT_FILE="$RUN_DIR/loadgen-families.md"
    passed=0
    failed=0
    FLAG_INITIAL=""
    FLAG_TOUCHED=0
    LOADGEN_WAS_RUNNING=0
    LOADGEN_TOUCHED=0
    LOADGEN_AT_START=""
    LOADGEN_PAUSED=0
    RESTORE_ERROR=""
    WINDOW_OPEN=0
    WINDOW_LABEL="B"
    WINDOW_SINCE="2026-01-01T00:00:00Z"
    WINDOW_START="2026-01-01T00:00:30Z"
    WINDOW_START_EPOCH=1767225630
    TABLE_WRITTEN=0
    STARTED_AT="2026-01-01T00:00:00Z"
    PROBE_DEADLINE=""
    LOG_PROBE_DETAIL=""
    POLL_DETAIL=""
    DB_COUNT=""
    DB_ERROR=""
    CLEANUP_LEFT=""
    CLOSE_ERROR=""
    STUB_DB_FAIL_AT=0
    STUB_DB_OUTPUT=""
    STUB_LOGS_STATUS=0
    STUB_STOP_STATUS=0
    STUB_UP_STATUS=0
    STUB_LOADGEN_WEIGHT=""
    STUB_VERSION_STATUS=0
    STARTED_DETAIL=""
    FAKE_NOW=1767225600
}

# t_run_sub COMMAND [ARGS...]: runs COMMAND in a subshell with errexit on, as the script runs its
# steps, with stdout in T_CASE_DIR/out and stderr in T_CASE_DIR/err, and sets T_STATUS. A step
# that calls exit ends only the subshell.
t_run_sub() {
    set +e
    (
        set -e
        "$@"
    ) >"$T_CASE_DIR/out" 2>"$T_CASE_DIR/err"
    T_STATUS=$?
    set -e
}

# t_print_file FILE: the lines of FILE; nothing for an empty or missing FILE.
t_print_file() {
    local -a lines=()
    if [[ -f "$1" ]]; then
        mapfile -t lines <"$1"
    fi
    if [[ ${#lines[@]} -gt 0 ]]; then
        printf '%s\n' "${lines[@]}"
    fi
}

# docker: records each call in STUB_DIR/docker.calls, its MSYS_NO_PATHCONV value and then one
# argument per line, ended by "--". docker inspect --format '{{json .Config.Env}}' cid-SERVICE
# prints the entries of STUB_DIR/env.SERVICE as the JSON array container_env and
# container_env_entry read; any other format fails. The compose subcommand after the -p
# and -f options plays as follows: config prints STUB_DIR/services; ps ... --services prints
# STUB_DIR/running, and ps ... SERVICE prints cid-SERVICE when STUB_DIR/env.SERVICE exists; logs
# prints STUB_DIR/loadgen.log and exits STUB_LOGS_STATUS; up records the
# PORTFOLIO_INSIGHTS_ALERT_WEIGHT it gets in STUB_DIR/up.env and exits STUB_UP_STATUS, giving
# loadgen that weight, or STUB_LOADGEN_WEIGHT when set, on success; stop, and the kill that ends
# a paused loadgen, exit STUB_STOP_STATUS; pause and unpause succeed; version exits
# STUB_VERSION_STATUS; exec runs the db client stub on its last argument; anything else succeeds
# without output.
docker() {
    local -a args=("$@")
    local i=1 last="${*: -1}"
    {
        printf 'MSYS_NO_PATHCONV=%s\n' "${MSYS_NO_PATHCONV:-}"
        printf '%s\n' "$@"
        printf -- '--\n'
    } >>"$STUB_DIR/docker.calls"
    if [[ "${args[0]:-}" == "inspect" ]]; then
        if [[ "${args[2]:-}" != "{{json .Config.Env}}" ]]; then
            echo "stub docker: unexpected inspect format [${args[2]:-}]" >&2
            return 1
        fi
        t_print_file "$STUB_DIR/env.${last#cid-}" | jq -c -R -s 'split("\n") | map(select(length > 0))'
        return 0
    fi
    while [[ $i -lt ${#args[@]} && ("${args[i]}" == "-p" || "${args[i]}" == "-f") ]]; do
        i=$((i + 2))
    done
    case "${args[i]:-}" in
        config) t_print_file "$STUB_DIR/services" ;;
        ps)
            if [[ "$last" == "--services" ]]; then
                t_print_file "$STUB_DIR/running"
            elif [[ -f "$STUB_DIR/env.$last" ]]; then
                echo "cid-$last"
            fi
            ;;
        logs)
            t_print_file "$STUB_DIR/loadgen.log"
            return "$STUB_LOGS_STATUS"
            ;;
        up)
            printf 'PORTFOLIO_INSIGHTS_ALERT_WEIGHT=%s\n' "${PORTFOLIO_INSIGHTS_ALERT_WEIGHT-unset}" >>"$STUB_DIR/up.env"
            if [[ $STUB_UP_STATUS -ne 0 ]]; then
                return "$STUB_UP_STATUS"
            fi
            printf 'PATH=/usr/local/bin\nPORTFOLIO_INSIGHTS_ALERT_WEIGHT=%s\n' \
                "${STUB_LOADGEN_WEIGHT:-${PORTFOLIO_INSIGHTS_ALERT_WEIGHT:-0}}" >"$STUB_DIR/env.loadgen"
            ;;
        stop | kill) return "$STUB_STOP_STATUS" ;;
        pause | unpause) return 0 ;;
        version) return "$STUB_VERSION_STATUS" ;;
        exec) t_db_client "$last" ;;
        *) return 0 ;;
    esac
}

# timeout: stands in for timeout(1), which hard_timeout runs for every bounded Docker call and
# which would start the docker binary instead of the stub. It takes the two forms hard_timeout
# uses, -k GRACE LIMIT and -s KILL LIMIT, and runs the command at once without a time limit, so
# the stub docker answers it with the MSYS_NO_PATHCONV value hard_timeout set. Any other form
# fails with 125, timeout(1)'s status for its own failure. harness-test.sh runs hard_timeout
# under the real timeout(1).
timeout() {
    local call="$*"
    if [[ "${1:-}" == "-k" && "${2:-}" =~ ^[0-9]+$ ]] || [[ "${1:-}" == "-s" && "${2:-}" == "KILL" ]]; then
        shift 2
    fi
    if [[ $# -lt 2 || ! "$1" =~ ^[0-9]+$ ]]; then
        echo "stub timeout: unexpected arguments [$call]" >&2
        return 125
    fi
    shift
    "$@"
}

# t_db_client SQL: the db container's client. Appends SQL to STUB_DIR/queries and prints, with a
# carriage return and a blank line, how many of the quoted ids in SQL the fake Alerts table
# STUB_DIR/alerts.rows holds. Query number STUB_DB_FAIL_AT fails with a client error, which is a
# non-empty STUB_DB_OUTPUT printed on stdout, as sqlcmd prints SQL errors, or else a line on
# stderr; on any other query a non-empty STUB_DB_OUTPUT is printed instead of the count.
# It stands in for the database. The same count query runs against real SQL Server and
# PostgreSQL databases in scripts/portfolio-insights/harness-sql-test.sh; these cases, which need
# no stack, cover the script's own handling of it: the query text per dialect, chunking, refusal
# before any query and the propagation of the client's exit status and error text.
t_db_client() {
    local rest="$1" row count=0
    local -a queries=()
    local -A table=()
    printf '%s\n' "$1" >>"$STUB_DIR/queries"
    mapfile -t queries <"$STUB_DIR/queries"
    if [[ ${#queries[@]} -eq $STUB_DB_FAIL_AT ]]; then
        if [[ -n "$STUB_DB_OUTPUT" ]]; then
            printf '%s\r\n' "$STUB_DB_OUTPUT"
        else
            echo "stub client: query ${#queries[@]} failed" >&2
        fi
        return 1
    fi
    if [[ -n "$STUB_DB_OUTPUT" ]]; then
        printf '\r\n%s\r\n\r\n' "$STUB_DB_OUTPUT"
        return 0
    fi
    while IFS= read -r row; do
        if [[ -n "$row" ]]; then
            table["$row"]=1
        fi
    done <"$STUB_DIR/alerts.rows"
    while [[ "$rest" =~ \'([0-9a-f-]{36})\' ]]; do
        if [[ -n "${table[${BASH_REMATCH[1]}]:-}" ]]; then
            count=$((count + 1))
        fi
        rest="${rest#*"${BASH_REMATCH[0]}"}"
    done
    printf '%s\r\n\r\n' "$count"
}

# curl: answers http()'s request from STUB_DIR/http.responses, lines METHOD<TAB>URL<TAB>STATUS
# <TAB>BODY whose first match on METHOD and URL answers; BODY @request echoes the request body.
# Status 000, or no matching line, is a transport error. Each request is recorded in
# STUB_DIR/http.calls as METHOD URL [BODY].
curl() {
    local method="GET" out="" url="" body="" status="" reply="" r_method r_url r_status r_body
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -X)
                method="$2"
                shift 2
                ;;
            -o)
                out="$2"
                shift 2
                ;;
            -D | -w | -H | --max-time)
                shift 2
                ;;
            --data-binary)
                IFS= read -r -d '' body || true
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
    printf '%s %s%s\n' "$method" "$url" "${body:+ $body}" >>"$STUB_DIR/http.calls"
    while IFS=$'\t' read -r r_method r_url r_status r_body; do
        if [[ "$r_method" == "$method" && "$r_url" == "$url" ]]; then
            status="$r_status"
            reply="$r_body"
            break
        fi
    done <"$STUB_DIR/http.responses"
    if [[ -z "$status" || "$status" == "000" ]]; then
        echo "$T_CURL_REFUSED" >&2
        return 7
    fi
    if [[ "$reply" == "@request" ]]; then
        reply="$body"
    fi
    printf '%s' "$reply" >"$out"
    printf '%s application/json' "$status"
}

# date: the fake clock FAKE_NOW for date -u +%s, the system date for anything else.
date() {
    if [[ $# -eq 2 && "$1" == "-u" && "$2" == "+%s" ]]; then
        echo "$FAKE_NOW"
    else
        command date "$@"
    fi
}

# sleep: advances the fake clock by its argument instead of waiting, and records the step.
sleep() {
    printf '%s\n' "$1" >>"$STUB_DIR/sleeps"
    FAKE_NOW=$((FAKE_NOW + $1))
}

# t_respond METHOD URL STATUS [BODY]: the stub curl's answer to METHOD URL.
t_respond() {
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >>"$STUB_DIR/http.responses"
}

# t_query_sizes: the number of quoted ids in each recorded query, separated by spaces.
t_query_sizes() {
    local query quotes
    local -a sizes=()
    while IFS= read -r query; do
        quotes="${query//[^\']/}"
        sizes+=("$((${#quotes} / 2))")
    done <"$STUB_DIR/queries"
    echo "${sizes[*]}"
}

# t_ids FIRST LAST: canonical lower-case alert ids numbered FIRST to LAST, one per line.
t_ids() {
    local i
    for ((i = $1; i <= $2; i++)); do
        printf '%08x-0000-4000-8000-%012x\n' "$i" "$i"
    done
}

# t_visit_line vN MESSAGE [VISIT_NAME]: a loadgen-core line of visit number N, by default of
# portfolio_insights_alert. Its worker tag and canonical visit id are the tags loadgen_logs keeps.
t_visit_line() {
    printf '[2026-01-01 00:01:00+00:00][worker:1][visit:%s][id:5e1f2a3b-0000-4000-9000-%012d][INFO]: %s\n' \
        "${3:-portfolio_insights_alert}" "${1#v}" "$2"
}

# t_resolved_visit vN ID: the lines of visit number N that created alert ID and deleted it via
# the UI.
t_resolved_visit() {
    t_visit_line "$1" "Opening portfolio insights page"
    t_visit_line "$1" "Created alert [$2] threshold [1000000.12345671]"
    t_visit_line "$1" "Deleted alert [$2] via ui"
}

# t_stats_line JSON: a cumulative loadgen-core stats line whose detailed breakdown is JSON.
t_stats_line() {
    printf '[2026-01-01 00:35:00+00:00][stats:runner][INFO]: The loadgen has been running since [Thu, 01 Jan 2026 00:00:00 GMT] and generated [7] visits with fail rate [0.14] and a rate of [0.20/m], detailed breakdown [%s]\n' "$1"
}

# t_timeframe_line SPAN JSON: a loadgen-core stats line of the last SPAN, with breakdown JSON.
t_timeframe_line() {
    printf '[2026-01-01 00:35:00+00:00][stats:runner][INFO]: In the last [%s] loadgen has generated [9] visits with fail rate [0.00] and a rate of [1.80/m], detailed breakdown [%s]\n' "$1" "$2"
}

# t_settings ARGS...: parse_options ARGS, then the settings it leaves, one NAME=VALUE per line.
t_settings() {
    parse_options "$@"
    printf 'BASE_URL=%s\nPROJECT=%s\nWEIGHT=%s\nMINUTES=%s\nOUT_FILE=%s\nCOMPOSE_ARGS=%s\n' \
        "$BASE_URL" "$PROJECT" "$WEIGHT" "$MINUTES" "$OUT_FILE" "${COMPOSE_ARGS[*]}"
}

# t_settings_in DIR ARGS...: t_settings ARGS from the directory DIR.
t_settings_in() {
    cd "$1"
    shift
    t_settings "$@"
}

# t_expect_usage_error ROW MESSAGE ARGS...: parse_options ARGS exits 2 with stderr starting with
# MESSAGE.
t_expect_usage_error() {
    local row="$1" message="$2" first=""
    shift 2
    t_run_sub parse_options "$@"
    IFS= read -r first <"$T_CASE_DIR/err" || true
    if [[ $T_STATUS -ne 2 || "$first" != "$message"* ]]; then
        t_reasons+=("$row: exit $T_STATUS with [$(t_text "$first")], expected 2 with [$message...]")
    fi
}

# t_succeed_on N: a poll attempt that fails, leaving POLL_DETAIL, until its Nth call.
t_attempts=0
t_succeed_on() {
    t_attempts=$((t_attempts + 1))
    POLL_DETAIL="attempt $t_attempts"
    [[ $t_attempts -ge $1 ]]
}

# t_exit_through_cleanup STATUS: ends a subshell with STATUS through the script's EXIT trap, as
# a run of the script ends.
t_exit_through_cleanup() {
    trap cleanup EXIT
    exit "$1"
}

# t_check_tools_without_path: check_tools with a PATH of one missing directory, where only the
# stub functions resolve, without the timeout stub: timeout(1) is a program check_tools requires.
# Run it in a subshell, so that only the subshell loses the stub.
t_check_tools_without_path() {
    local PATH="$T_TMP/no-tools"
    unset -f timeout
    check_tools
}

# t_ready_stack: the stub answers of a ready PostgreSQL stack whose services, loadgen included,
# all run, with the flag modifiable and off. Answers a row adds before calling it take precedence.
t_ready_stack() {
    printf '%s\n' broker-service db db-adapter feature-flag-service frontend loadgen offer-service \
        reverse-proxy >"$STUB_DIR/services"
    cp "$STUB_DIR/services" "$STUB_DIR/running"
    printf '%s\n' "PATH=/usr/local/bin" "DB_TYPE=postgres" >"$STUB_DIR/env.db-adapter"
    printf '%s\n' "PATH=/usr/local/bin" "PORTFOLIO_INSIGHTS_ALERT_WEIGHT=0" >"$STUB_DIR/env.loadgen"
    t_respond GET "$BASE_URL/broker-service/readyz" 200 'ok'
    t_respond GET "$BASE_URL/feature-flag-service/readyz" 200 'ok'
    t_respond GET "$FLAG_URL" 200 '{"id":"portfolio-insights-enabled","enabled":false,"isModifiable":true}'
}

# t_setup_facts: setup, then the dialect and initial flag value it gathered.
t_setup_facts() {
    setup
    printf 'DIALECT=%s FLAG_INITIAL=%s\n' "$DIALECT" "$FLAG_INITIAL"
}

# t_set_flag_touch ARGS...: set_flag ARGS, printing FLAG_TOUCHED on the way out, whether set_flag
# returns or ends the run.
t_set_flag_touch() {
    trap 'echo "FLAG_TOUCHED=$FLAG_TOUCHED"' EXIT
    set_flag "$@"
}

# t_open_window_state ARGS...: open_window ARGS, printing on the way out whether the window is
# open, whether loadgen was touched, and the shell's own PORTFOLIO_INSIGHTS_ALERT_WEIGHT.
t_open_window_state() {
    trap 'echo "WINDOW_OPEN=$WINDOW_OPEN LOADGEN_TOUCHED=$LOADGEN_TOUCHED shell weight ${PORTFOLIO_INSIGHTS_ALERT_WEIGHT-unset}"' EXIT
    open_window "$@"
}

# ---------------------------------------------------------------------------------------------
# Options

check="isCount_candidates_acceptsPositiveIntegersOfAtMostNineDigits"
for value in 1 35 999999999; do
    if ! is_count "$value"; then
        t_reasons+=("[$value] rejected")
    fi
done
for value in 0 01 -1 +1 1.5 "" " 1" 1a 1234567890; do
    if is_count "$value"; then
        t_reasons+=("[$value] accepted")
    fi
done
t_conclude "$check"

check="parseOptions_invalidArguments_exitsTwoWithUsageError"
t_new_case
: >"$T_CASE_DIR/compose.yaml"
t_expect_usage_error "missing --project" "Option --project is required." --weight 2
t_expect_usage_error "unknown option" "Unknown option: --bogus" --project et-test --bogus
t_expect_usage_error "value missing at the end" "Option --project requires a value." --project
t_expect_usage_error "value is an option" "Option --minutes requires a value." --minutes --project et-test
t_expect_usage_error "empty value" "Option --out requires a value." --project et-test --out ""
for option in --weight --minutes; do
    t_expect_usage_error "$option -1" "Option $option requires a value." --project et-test "$option" -1
    for value in 0 1.5 1234567890; do
        t_expect_usage_error "$option $value" \
            "Option $option needs a positive integer of at most 9 digits, got: $value" \
            --project et-test "$option" "$value"
    done
done
t_expect_usage_error "missing compose file" "Compose file not found: $T_CASE_DIR/absent.yaml" \
    --project et-test --compose-file "$T_CASE_DIR/absent.yaml"
t_expect_usage_error "--out in a missing directory" \
    "Directory of --out is missing or not writable: $T_CASE_DIR/absent" \
    --project et-test --compose-file "$T_CASE_DIR/compose.yaml" --out "$T_CASE_DIR/absent/table.md"
t_conclude "$check"

check="parseOptions_repeatedComposeFile_layersFilesInOrder"
t_new_case
: >"$T_CASE_DIR/a.yaml"
: >"$T_CASE_DIR/b.yaml"
t_run_sub t_settings --project et-test --compose-file "$T_CASE_DIR/a.yaml" --compose-file "$T_CASE_DIR/b.yaml"
t_expect "exit status" "$T_STATUS" 0
t_expect_line "compose args" "$T_CASE_DIR/out" "COMPOSE_ARGS=-f $T_CASE_DIR/a.yaml -f $T_CASE_DIR/b.yaml"
t_conclude "$check"

check="parseOptions_projectOnly_appliesDefaults"
t_new_case
: >"$T_CASE_DIR/compose.dev.yaml"
t_run_sub t_settings_in "$T_CASE_DIR" --project et-test
t_expect "settings" "$T_STATUS|$(<"$T_CASE_DIR/out")" "0|BASE_URL=http://localhost
PROJECT=et-test
WEIGHT=1
MINUTES=35
OUT_FILE=
COMPOSE_ARGS=-f compose.dev.yaml"
t_conclude "$check"

check="parseOptions_help_printsUsageAndExitsZero"
t_new_case
t_run_sub parse_options --help
first=""
IFS= read -r first <"$T_CASE_DIR/out" || true
t_expect "help" "$T_STATUS|$first" \
    "0|Usage: scripts/portfolio-insights/loadgen-check.sh --project NAME [--base-url URL]"
t_conclude "$check"

check="checkTools_toolsAndComposePlugin_exitsTwoWhenOneIsMissing"
t_new_case
t_run_sub check_tools
t_expect "all present" "$T_STATUS|$(<"$T_CASE_DIR/err")" "0|"
t_run_sub t_check_tools_without_path
t_expect "tools missing" "$T_STATUS|$(<"$T_CASE_DIR/err")" "2|Missing required tools: bash jq timeout"
STUB_VERSION_STATUS=1
t_run_sub check_tools
t_expect "compose plugin missing" "$T_STATUS|$(<"$T_CASE_DIR/err")" \
    "2|The docker compose plugin is required (docker compose version failed)."
t_conclude "$check"

# ---------------------------------------------------------------------------------------------
# HTTP, polling and logs

check="http_responses_setsStatusTypeAndBodyOrTransportError"
t_new_case
t_respond GET "$FLAG_URL" 200 '{"id":"portfolio-insights-enabled","enabled":true}'
t_respond PUT "$FLAG_URL" 200 '@request'
http GET "$FLAG_URL"
t_expect "GET" "$HTTP_STATUS|$HTTP_CTYPE|$HTTP_BODY" \
    '200|application/json|{"id":"portfolio-insights-enabled","enabled":true}'
http PUT "$FLAG_URL" '{"enabled": false}'
t_expect "PUT body through stdin" "$HTTP_STATUS|$HTTP_BODY" '200|{"enabled": false}'
http DELETE "$ALERTS_URL/$ID1"
t_expect "transport error" "$HTTP_STATUS|$HTTP_CTYPE|$HTTP_BODY|$(status_text)" \
    "000|||transport error ($T_CURL_REFUSED)"
t_conclude "$check"

check="poll_attempts_returnsOnSuccessOrFailsAtDeadlineWithoutWaiting"
t_new_case
t_attempts=0
set +e
poll "readiness" 60 5 t_succeed_on 3 >"$T_CASE_DIR/poll.out"
status=$?
set -e
t_expect "success on the third attempt" \
    "$status|$t_attempts|$(t_lines "$STUB_DIR/sleeps")|$(<"$T_CASE_DIR/poll.out")" "0|3|5 5|"
t_new_case
t_attempts=0
set +e
poll "readiness" 10 5 t_succeed_on 99 >"$T_CASE_DIR/poll.out"
status=$?
set -e
t_expect "deadline expired" \
    "$status|$t_attempts|$(t_lines "$STUB_DIR/sleeps")|$(<"$T_CASE_DIR/poll.out")" \
    "1|3|5 5|FAIL readiness: deadline 10 s expired; attempt 3"
t_conclude "$check"

check="loadgenLogs_colouredCrlfOutput_printsPlainLines"
t_new_case
t_line_1="$(t_visit_line v1 "Running visit [long_sell_success]" long_sell_success)"
t_line_2="$(t_timeframe_line 5m '{"long_sell_success":{"total":1,"avgDurationMs":900,"failRate":0}}')"
# A single and a multi-parameter colour code around lines that loadgen_logs keeps.
printf '\033[32m%s\033[39m\r\n\033[1;33m%s\033[0m\r\n' "$t_line_1" "$t_line_2" >"$STUB_DIR/loadgen.log"
t_expect "output" "$(loadgen_logs "$WINDOW_SINCE")" "$t_line_1"$'\n'"$t_line_2"
t_conclude "$check"

# ---------------------------------------------------------------------------------------------
# Stats breakdowns and visit families

J_FIRST='{"deposit_and_buy_success":{"total":1,"avgDurationMs":900,"failRate":0}}'
J_LAST='{"deposit_and_buy_success":{"total":4,"avgDurationMs":900,"failRate":0.25},"long_sell_error":{"total":2,"avgDurationMs":300,"failRate":1}}'
J_TIMEFRAME='{"deposit_and_buy_success":{"total":9,"avgDurationMs":900,"failRate":0}}'

check="extractBreakdown_statsLines_printsLastCumulativeBreakdownAndItsLine"
t_new_case
{
    t_stats_line "$J_FIRST"
    t_timeframe_line 5m "$J_TIMEFRAME"
    t_visit_line v1 "Running visit [deposit_and_buy_success]" deposit_and_buy_success
    t_stats_line "$J_LAST"
    t_timeframe_line 5m "$J_TIMEFRAME"
    t_timeframe_line 1h "$J_TIMEFRAME"
} >"$T_CASE_DIR/stats.log"
t_stats_line "$J_LAST" >"$T_CASE_DIR/expected.line"
status=0
json="$(extract_breakdown "$T_CASE_DIR/stats.log" "$T_CASE_DIR/stats.line")" || status=$?
t_expect "breakdown" "$status|$json" "0|$J_LAST"
t_expect "line file" "$(<"$T_CASE_DIR/stats.line")" "$(<"$T_CASE_DIR/expected.line")"
t_conclude "$check"

check="extractBreakdown_noUsableLastLine_failsWithoutLineFile"
t_new_case
t_row=0
# t_expect_no_breakdown ROW: extract_breakdown over T_CASE_DIR/row.log fails and writes no line
# file.
t_expect_no_breakdown() {
    local status=0 json line_file="none"
    t_row=$((t_row + 1))
    json="$(extract_breakdown "$T_CASE_DIR/row.log" "$T_CASE_DIR/row-$t_row.line")" || status=$?
    if [[ -e "$T_CASE_DIR/row-$t_row.line" ]]; then
        line_file="written"
    fi
    t_expect "$1" "$status|$json|$line_file" "1||none"
}
t_visit_line v1 "Opening portfolio insights page" >"$T_CASE_DIR/row.log"
t_expect_no_breakdown "no stats line"
{
    t_timeframe_line 5m "$J_TIMEFRAME"
    t_timeframe_line 1h "$J_TIMEFRAME"
} >"$T_CASE_DIR/row.log"
t_expect_no_breakdown "timeframe lines only"
t_stats_line '{"deposit_and_buy_success":{"total":1,' >"$T_CASE_DIR/row.log"
t_expect_no_breakdown "malformed JSON"
t_stats_line '[1,2]' >"$T_CASE_DIR/row.log"
t_expect_no_breakdown "array"
t_stats_line '{"deposit_and_buy_success":3}' >"$T_CASE_DIR/row.log"
t_expect_no_breakdown "entry not an object"
t_stats_line '{"deposit_and_buy_success":{"total":"3","avgDurationMs":1,"failRate":0}}' >"$T_CASE_DIR/row.log"
t_expect_no_breakdown "total not a number"
t_stats_line '{"deposit_and_buy_success":{"total":3,"avgDurationMs":1}}' >"$T_CASE_DIR/row.log"
t_expect_no_breakdown "failRate missing"
t_stats_line '{"deposit_and_buy_success":{"total":3,"avgDurationMs":1,"failRate":null}}' >"$T_CASE_DIR/row.log"
t_expect_no_breakdown "failRate null"
{
    t_stats_line "$J_FIRST"
    t_stats_line '{"a":'
} >"$T_CASE_DIR/row.log"
t_expect_no_breakdown "malformed after a valid line"
echo "[2026-01-01 00:35:00+00:00][stats:runner][INFO]: The loadgen has been running since [Thu, 01 Jan 2026 00:00:00 GMT] and generated [0] visits" \
    >"$T_CASE_DIR/row.log"
t_expect_no_breakdown "no breakdown"
t_conclude "$check"

FAMILY_JSON='{"deposit_and_buy_success":{"total":2,"avgDurationMs":1,"failRate":0},"deposit_and_long_buy_success":{"total":5,"avgDurationMs":1,"failRate":0},"deposit_and_long_buy_error":{"total":4,"avgDurationMs":1,"failRate":0.25},"long_sell_success":{"total":3,"avgDurationMs":1,"failRate":0},"long_sell_timeout":{"total":2,"avgDurationMs":1,"failRate":0.5},"long_sell_error":{"total":4,"avgDurationMs":1,"failRate":1},"order_credit_card":{"total":1,"avgDurationMs":1,"failRate":0},"portfolio_insights_alert":{"total":1,"avgDurationMs":1,"failRate":2.220446049250313e-16}}'

check="familyNames_breakdown_listsNamesEqualToFamilyOrPrefixedByIt"
t_expect "deposit_and_buy never takes deposit_and_long_buy_*" \
    "$(family_names deposit_and_buy "$FAMILY_JSON")" "deposit_and_buy_success"
t_expect "deposit_and_long_buy" "$(family_names deposit_and_long_buy "$FAMILY_JSON")" \
    $'deposit_and_long_buy_error\ndeposit_and_long_buy_success'
t_expect "long_sell" "$(family_names long_sell "$FAMILY_JSON")" \
    $'long_sell_error\nlong_sell_success\nlong_sell_timeout'
t_expect "exact name" "$(family_names order_credit_card "$FAMILY_JSON")" "order_credit_card"
t_expect "family absent" "$(family_names sell_and_withdraw "$FAMILY_JSON")" ""
t_expect "malformed JSON" "$(family_names long_sell '{')" ""
t_conclude "$check"

check="familyCompletions_breakdown_sumsRoundedCompletionsPerFamily"
t_expect "deposit_and_buy never takes deposit_and_long_buy_*" \
    "$(family_completions deposit_and_buy "$FAMILY_JSON")" 2
t_expect "deposit_and_long_buy 5 + 4 x 0.75" "$(family_completions deposit_and_long_buy "$FAMILY_JSON")" 8
t_expect "long_sell 3 + 1 + 0" "$(family_completions long_sell "$FAMILY_JSON")" 4
t_expect "0.9999999999999998 rounds to 1" "$(family_completions portfolio_insights_alert "$FAMILY_JSON")" 1
t_expect "6.999999999999999 rounds to 7" \
    "$(family_completions long_sell '{"long_sell_success":{"total":10,"avgDurationMs":1,"failRate":0.30000000000000004}}')" 7
t_expect "every visit failed" \
    "$(family_completions long_sell '{"long_sell_error":{"total":3,"avgDurationMs":1,"failRate":1}}')" 0
t_expect "family absent" "$(family_completions sell_and_withdraw "$FAMILY_JSON")" 0
t_conclude "$check"

check="familyFailing_breakdown_listsSortedNamesWithPositiveFailRate"
t_expect "long_sell" "$(family_failing long_sell "$FAMILY_JSON")" $'long_sell_error\nlong_sell_timeout'
t_expect "deposit_and_buy never takes deposit_and_long_buy_*" "$(family_failing deposit_and_buy "$FAMILY_JSON")" ""
t_expect "deposit_and_long_buy" "$(family_failing deposit_and_long_buy "$FAMILY_JSON")" \
    "deposit_and_long_buy_error"
t_expect "failRate 0" "$(family_failing order_credit_card "$FAMILY_JSON")" ""
t_conclude "$check"

check="failRate_visitName_printsItsRateOrNothing"
t_expect "failRate 0" "$(fail_rate order_credit_card "$FAMILY_JSON")" 0
t_expect "failRate 0.5" "$(fail_rate long_sell_timeout "$FAMILY_JSON")" 0.5
t_expect "name absent" "$(fail_rate sell_and_withdraw_success "$FAMILY_JSON")" ""
t_conclude "$check"

check="familyOf_visitNames_mapsToExpectedFamilyOrOther"
for row in deposit_and_buy_success:deposit_and_buy deposit_and_long_buy_timeout:deposit_and_long_buy \
    long_sell_error:long_sell sell_and_withdraw_success:sell_and_withdraw \
    order_credit_card:order_credit_card portfolio_insights_alert:portfolio_insights_alert \
    long_sellx:other deposit_and:other unknown_visit:other; do
    t_expect "${row%%:*}" "$(family_of "${row%%:*}")" "${row#*:}"
done
t_conclude "$check"

check="errorCountsFile_visitErrorLines_countsLinesPerVisitName"
t_new_case
{
    t_visit_line v1 "Worker had error when running visit: [Error: timeout]" long_sell_error
    t_visit_line v2 "Running visit [long_sell_success]" long_sell_success
    t_visit_line v3 "Worker had error when running visit: [TimeoutError: waiting for selector]"
    t_visit_line v4 "Worker had error getting browser context [Error: closed]" deposit_and_buy_success
    t_visit_line v5 "Worker had error when running visit: [Error: 500]" long_sell_error
} >"$T_CASE_DIR/errors.log"
: >"$T_CASE_DIR/empty.log"
t_expect "error lines" "$(error_counts_file "$T_CASE_DIR/errors.log")" \
    $'2 long_sell_error\n1 portfolio_insights_alert'
t_expect "no error line" "$(error_counts_file "$T_CASE_DIR/empty.log")" ""
t_conclude "$check"

check="errorCounts_loadgenOutputSince_printsErrorCountsOrFailsWhenLogsFail"
t_new_case
{
    t_visit_line v1 "Worker had error when running visit: [Error: timeout]" long_sell_error
    t_visit_line v2 "Running visit [long_sell_success]" long_sell_success
    t_visit_line v3 "Worker had error when running visit: [TimeoutError: waiting for selector]"
    t_visit_line v4 "Worker had error when running visit: [Error: 500]" long_sell_error
} >"$STUB_DIR/loadgen.log"
status=0
out="$(error_counts "$WINDOW_SINCE")" || status=$?
t_expect "counts" "$status|$out" $'0|2 long_sell_error\n1 portfolio_insights_alert'
t_expect "loadgen logs since SINCE" "$(<"$STUB_DIR/docker.calls")" "MSYS_NO_PATHCONV=1
compose
-p
et-test
-f
compose.dev.yaml
logs
--no-color
--no-log-prefix
--since
$WINDOW_SINCE
loadgen
--"
t_new_case
t_visit_line v1 "Worker had error when running visit: [Error: timeout]" long_sell_error >"$STUB_DIR/loadgen.log"
STUB_LOGS_STATUS=1
status=0
out="$(error_counts "$WINDOW_SINCE")" || status=$?
t_expect "loadgen logs fail" "$status|$out" "1|"
t_conclude "$check"

# ---------------------------------------------------------------------------------------------
# Checks on breakdowns

check="checkFamilies_breakdown_passesOnlyFamiliesWithACompletion"
t_new_case
check_families "run B" B "$FAMILY_JSON" long_sell sell_and_withdraw >"$T_CASE_DIR/out"
check_families "run A" A '{"long_sell_error":{"total":3,"avgDurationMs":1,"failRate":1}}' long_sell \
    >>"$T_CASE_DIR/out"
t_expect "verdict lines" "$(<"$T_CASE_DIR/out")" \
    "PASS run B family long_sell: 4 completed visits (names: long_sell_error long_sell_success long_sell_timeout)
FAIL run B family sell_and_withdraw: 0 completed visits (names: none)
FAIL run A family long_sell: 0 completed visits (names: long_sell_error)"
t_expect "recorded verdicts" "$(<"$RUN_DIR/verdicts")" \
    $'B\tlong_sell\tPASS\nB\tsell_and_withdraw\tFAIL\nA\tlong_sell\tFAIL'
t_conclude "$check"

check="checkVisitFailRate_breakdown_passesOnlyAZeroFailRate"
t_new_case
check_visit_fail_rate "run B" B '{"portfolio_insights_alert":{"total":3,"avgDurationMs":1,"failRate":0}}' \
    >"$T_CASE_DIR/out"
check_visit_fail_rate "run B" B '{"portfolio_insights_alert":{"total":4,"avgDurationMs":1,"failRate":0.25}}' \
    >>"$T_CASE_DIR/out"
check_visit_fail_rate "run B" B "$J_FIRST" >>"$T_CASE_DIR/out"
t_expect "verdict lines" "$(<"$T_CASE_DIR/out")" "PASS run B portfolio_insights_alert failRate: 0 over 3 visits
FAIL run B portfolio_insights_alert failRate: failRate [0.25]
FAIL run B portfolio_insights_alert failRate: visit not drawn"
check_visit_fail_rate "run B" B "$FAMILY_JSON" >"$T_CASE_DIR/tiny.out"
t_expect_match "failRate 2.2e-16" "$T_CASE_DIR/tiny.out" '^FAIL run B portfolio_insights_alert failRate: failRate \['
t_conclude "$check"

check="compareFailures_runBreakdowns_failsOnlyNamesNewlyFailingInRunB"
t_new_case
printf '%s\n' "$FAMILY_JSON" >"$RUN_DIR/breakdown-A.json"
printf '%s\n' '{"long_sell_error":{"total":1,"avgDurationMs":1,"failRate":1},"long_sell_success":{"total":2,"avgDurationMs":1,"failRate":0}}' \
    >"$RUN_DIR/breakdown-B.json"
compare_failures >"$T_CASE_DIR/out"
t_expect_no_match "failing names a subset of run A's" "$T_CASE_DIR/out" '^FAIL '
t_expect "one check per existing family" "$(t_count "$T_CASE_DIR/out")" 5
t_new_case
printf '%s\n' '{"long_sell_error":{"total":1,"avgDurationMs":1,"failRate":1}}' >"$RUN_DIR/breakdown-A.json"
printf '%s\n' '{"long_sell_error":{"total":1,"avgDurationMs":1,"failRate":1},"long_sell_timeout":{"total":2,"avgDurationMs":1,"failRate":0.5},"deposit_and_buy_success":{"total":5,"avgDurationMs":1,"failRate":0.2}}' \
    >"$RUN_DIR/breakdown-B.json"
compare_failures >"$T_CASE_DIR/out"
t_expect_line "new long_sell failure" "$T_CASE_DIR/out" \
    "FAIL run B no new failures long_sell: failing in run B but not in run A: long_sell_timeout"
t_expect_line "new deposit_and_buy failure" "$T_CASE_DIR/out" \
    "FAIL run B no new failures deposit_and_buy: failing in run B but not in run A: deposit_and_buy_success"
t_expect_line "family without failures" "$T_CASE_DIR/out" \
    "PASS run B no new failures order_credit_card: failing [none], run A failing [none]"
t_new_case
printf '%s\n' "$FAMILY_JSON" >"$RUN_DIR/breakdown-B.json"
compare_failures >"$T_CASE_DIR/out"
t_expect "run A without breakdown" "$(<"$T_CASE_DIR/out")" \
    "FAIL run B comparison: run A has no breakdown to compare with"
t_conclude "$check"

check="watchProgress_untilDeadline_printsTotalsAndErrorLinesEachMinute"
t_new_case
WINDOW_START_EPOCH="$FAKE_NOW"
{
    t_stats_line "$J_LAST"
    t_visit_line v1 "Worker had error when running visit: [Error: 500]" long_sell_error
} >"$STUB_DIR/loadgen.log"
# A window of 150 s: reads at minutes 1 and 2, then a last step of the 30 s left, at whose end
# the due read is skipped.
watch_progress A $((FAKE_NOW + 150)) >"$T_CASE_DIR/out"
t_expect "progress lines and steps" "$(<"$T_CASE_DIR/out")|$(t_lines "$STUB_DIR/sleeps")" \
    "INFO run A progress 1/35 min: totals [deposit_and_buy_success=4 long_sell_error=2] error lines [long_sell_error=1]
INFO run A progress 2/35 min: totals [deposit_and_buy_success=4 long_sell_error=2] error lines [long_sell_error=1]
INFO run A progress 2/35 min: read skipped at the window end; the breakdown and the window's closing read follow|60 60 30"
t_conclude "$check"

# ---------------------------------------------------------------------------------------------
# Alerts loadgen created

check="createdIds_createdLines_printsCanonicalLowerCaseUniqueIds"
t_new_case
{
    t_visit_line v1 "Created alert [ABCDEF01-0000-4000-8000-00000000000A] threshold [1000000.12345671]"
    t_visit_line v2 "Created alert [$ID2] threshold [1000000.12345672]"
    t_visit_line v2 "Created alert [$ID2] threshold [1000000.12345672]"
    t_visit_line v3 "Created alert [{$ID3}] threshold [1000000.12345673]"
    t_visit_line v4 "Created alert [$T_DASHES] threshold [1000000.12345674]"
    t_visit_line v5 "Created alert [00000005000040008000000000000005abcd] threshold [1000000.12345675]"
    t_visit_line v6 "Created alert output for threshold [1000000.12345676] unreadable, retrying"
    t_visit_line v7 "Deleted alert [$ID4] via ui"
    t_visit_line v8 "Create unconfirmed threshold [1000000.12345678], outcome unknown"
} >"$T_CASE_DIR/loadgen.log"
t_expect "created ids" "$(created_ids "$T_CASE_DIR/loadgen.log")" \
    "$ID2"$'\n'"abcdef01-0000-4000-8000-00000000000a"
t_conclude "$check"

check="resolvedIds_resolutionLines_printsIdsDeletedViaUiOrApiOrAlreadyAbsent"
t_new_case
{
    t_visit_line v1 "Deleted alert [$ID1] via ui"
    t_visit_line v2 "Deleted alert [$ID2] via api"
    t_visit_line v3 "Alert [$ID3] already absent"
    t_visit_line v4 "Alert [$ID4] left in place: 500"
    t_visit_line v5 "Deleted alert [$ID5] via smoke"
    t_visit_line v6 "Deleted alert [ABCDEF01-0000-4000-8000-00000000000A] via ui"
} >"$T_CASE_DIR/loadgen.log"
t_expect "resolved ids" "$(resolved_ids "$T_CASE_DIR/loadgen.log")" \
    "$ID1"$'\n'"$ID2"$'\n'"$ID3"$'\n'"abcdef01-0000-4000-8000-00000000000a"
t_conclude "$check"

check="unresolvedIds_log_printsCreatedIdsWithoutResolution"
t_new_case
{
    t_resolved_visit v1 "$ID1"
    t_visit_line v2 "Created alert [$ID2] threshold [1000000.12345672]"
    t_visit_line v2 "Alert [$ID2] left in place: 500"
    t_visit_line v3 "Created alert [$ID3] threshold [1000000.12345673]"
    t_visit_line v3 "Alert [$ID3] already absent"
    t_visit_line v4 "Deleted alert [$ID4] via api"
} >"$T_CASE_DIR/loadgen.log"
t_expect "unresolved ids" "$(unresolved_ids "$T_CASE_DIR/loadgen.log")" "$ID2"
t_conclude "$check"

check="ownUnresolved_ownedList_addsOnlyNewUnresolvedIds"
t_new_case
printf '%s\n' "$ID2" >"$RUN_DIR/owned"
{
    t_resolved_visit v1 "$ID1"
    t_visit_line v2 "Created alert [$ID2] threshold [1000000.12345672]"
    t_visit_line v4 "Created alert [$ID4] threshold [1000000.12345674]"
} >"$T_CASE_DIR/loadgen.log"
own_unresolved "$T_CASE_DIR/loadgen.log"
t_expect "owned and new-owned" "$(t_lines "$RUN_DIR/owned")|$(t_lines "$RUN_DIR/new-owned")" "$ID2 $ID4|$ID4"
t_conclude "$check"

# ---------------------------------------------------------------------------------------------
# Database (read only)

check="dbQuery_dialects_runsDialectClientInDbContainer"
t_new_case
DIALECT="mssql"
STUB_DB_OUTPUT="7"
t_expect "mssql output" "$(db_query "SELECT 1")" 7
# shellcheck disable=SC2016 # The client command is expected unexpanded, as the container gets it.
t_expect "mssql client" "$(<"$STUB_DIR/docker.calls")" 'MSYS_NO_PATHCONV=1
compose
-p
et-test
-f
compose.dev.yaml
exec
-T
db
sh
-c
/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -d TradeManagement -b -h -1 -W -Q "$1"
sh
SET NOCOUNT ON; SELECT 1
--'
t_new_case
STUB_DB_OUTPUT="7"
t_expect "postgres output" "$(db_query "SELECT 1")" 7
t_expect "postgres client" "$(<"$STUB_DIR/docker.calls")" 'MSYS_NO_PATHCONV=1
compose
-p
et-test
-f
compose.dev.yaml
exec
-T
db
psql
-v
ON_ERROR_STOP=1
-U
postgres
-d
TradeManagement
-At
-F
,
-c
SELECT 1
--'
t_conclude "$check"

check="dbQuery_clientFails_exitsNonZeroWithClientError"
for dialect in mssql postgres; do
    t_new_case
    DIALECT="$dialect"
    STUB_DB_FAIL_AT=1
    status=0
    db_query "SELECT 1" >/dev/null || status=$?
    if [[ $status -ne 0 ]]; then
        status="non-zero"
    fi
    t_expect "$dialect" "$status|$(<"$RUN_DIR/db-error.log")" "non-zero|stub client: query 1 failed"
done
t_new_case
DIALECT="sqlite"
status=0
db_query "SELECT 1" >/dev/null || status=$?
t_expect "unknown dialect" "$status|$(<"$RUN_DIR/db-error.log")|$(t_count "$STUB_DIR/docker.calls")" \
    "1|unknown dialect [sqlite]|0"
t_conclude "$check"

check="dbCountChunk_dialects_countsWithExactDialectSql"
t_new_case
DIALECT="mssql"
printf '%s\n' "$ID2" >"$STUB_DIR/alerts.rows"
t_expect "mssql" "$(db_count_chunk "'$ID1'" "'$ID2'")|$(<"$STUB_DIR/queries")" \
    "1|SET NOCOUNT ON; SELECT COUNT(*) FROM [dbo].[Alerts] WHERE [Id] IN ('$ID1','$ID2')"
t_new_case
printf '%s\n' "$ID2" >"$STUB_DIR/alerts.rows"
t_expect "postgres" "$(db_count_chunk "'$ID1'" "'$ID2'")|$(<"$STUB_DIR/queries")" \
    "1|SELECT COUNT(*) FROM \"Alerts\" WHERE \"Id\" IN ('$ID1','$ID2')"
t_conclude "$check"

check="dbCountChunk_nonNumericOutput_failsWithDbErrorLine"
for row in "Msg 208, Level 16:msg 208, level 16" $'3\r\n4:3\n4'; do
    t_new_case
    STUB_DB_OUTPUT="${row%%:*}"
    status=0
    out="$(db_count_chunk "'$ID1'")" || status=$?
    t_expect "$(t_text "${row%%:*}")" "$status|$out|$(<"$RUN_DIR/db-error.log")" \
        "1||unexpected count output [${row#*:}]"
done
t_conclude "$check"

check="dbCountIds_noId_countsZeroWithoutQuery"
for row in "empty file" "blank lines"; do
    t_new_case
    if [[ "$row" == "empty file" ]]; then
        : >"$T_CASE_DIR/ids"
    else
        printf '\n\n\n' >"$T_CASE_DIR/ids"
    fi
    set +e
    db_count_ids "$T_CASE_DIR/ids"
    status=$?
    set -e
    t_expect "$row" "$status|$DB_COUNT|$DB_ERROR|$(t_count "$STUB_DIR/queries")" "0|0||0"
done
t_conclude "$check"

check="dbCountIds_populatedFile_countsMatchingRowsInOneQuery"
t_new_case
printf '%s\n\n%s\n\n%s' "$ID1" "$ID2" "$ID3" >"$T_CASE_DIR/ids"
printf '%s\n' "$ID1" "$ID3" "$ID5" >"$STUB_DIR/alerts.rows"
set +e
db_count_ids "$T_CASE_DIR/ids"
status=$?
set -e
t_expect "count" "$status|$DB_COUNT|$DB_ERROR|$(t_query_sizes)" "0|2||3"
t_conclude "$check"

check="dbCountIds_nonCanonicalId_refusesWithoutQuery"
for bad in "ABCDEF01-0000-4000-8000-00000000000A" "{$ID1}" "${ID1%?}" "${ID1%?}'" "x') OR 1=1 --" \
    "$ID1 " "$ID1"$'\r'; do
    t_new_case
    printf '%s\n' "$ID2" "$bad" "$ID3" >"$T_CASE_DIR/ids"
    set +e
    db_count_ids "$T_CASE_DIR/ids"
    status=$?
    set -e
    t_expect "$(t_text "$bad")" "$status|$DB_ERROR|$(t_count "$STUB_DIR/queries")" \
        "1|refusing id [$bad]: not a canonical UUID|0"
done
t_conclude "$check"

check="dbCountIds_chunkBoundaries_queriesAtMostChunkSizeIdsEach"
for row in "1:1" "99:99" "100:100" "101:100 1" "200:100 100"; do
    t_new_case
    t_ids 1 "${row%%:*}" >"$T_CASE_DIR/ids"
    set +e
    db_count_ids "$T_CASE_DIR/ids"
    status=$?
    set -e
    t_expect "${row%%:*} ids" "$status|$(t_query_sizes)" "0|${row#*:}"
done
t_conclude "$check"

check="dbCountIds_rowsInSeveralChunks_sumsChunkCounts"
t_new_case
t_ids 1 150 >"$T_CASE_DIR/ids"
{
    t_ids 1 1
    t_ids 100 101
    t_ids 150 150
    t_ids 999 999
} >"$STUB_DIR/alerts.rows"
set +e
db_count_ids "$T_CASE_DIR/ids"
status=$?
set -e
t_expect "count" "$status|$DB_COUNT|$(t_query_sizes)" "0|4|100 50"
t_conclude "$check"

check="dbCountIds_clientFailure_failsWithoutCountingAsSuccess"
for row in "only chunk:5:1:" "first full chunk:150:1:" "full chunk after a counted one:200:2:" \
    "last chunk after a counted one:150:2:" "non-numeric output:5:0:error" \
    "error on stdout:5:1:Invalid object name 'dbo.Alerts'."; do
    IFS=: read -r t_label t_n t_fail_at t_output <<<"$row"
    t_new_case
    t_ids 1 "$t_n" >"$T_CASE_DIR/ids"
    t_ids 1 1 >"$STUB_DIR/alerts.rows"
    STUB_DB_FAIL_AT="$t_fail_at"
    STUB_DB_OUTPUT="$t_output"
    set +e
    db_count_ids "$T_CASE_DIR/ids"
    status=$?
    set -e
    if [[ $t_fail_at -gt 0 && -n "$t_output" ]]; then
        # db_query lower-cases the client's output.
        expected="count query failed: ${t_output,,}"
    elif [[ -n "$t_output" ]]; then
        expected="count query failed: unexpected count output [$t_output]"
    else
        expected="count query failed: stub client: query $t_fail_at failed"
    fi
    t_expect "$t_label" "$status|$DB_ERROR" "1|$expected"
done
t_conclude "$check"

# ---------------------------------------------------------------------------------------------
# Setup, flag and loadgen windows

check="setup_stackStates_passesReadyStackAndEndsRunOtherwise"
t_new_case
t_ready_stack
t_run_sub t_setup_facts
t_expect "ready stack" "$T_STATUS" 0
t_expect_no_match "ready stack: no failure" "$T_CASE_DIR/out" '^FAIL '
t_expect_line "ready stack: facts" "$T_CASE_DIR/out" "DIALECT=postgres FLAG_INITIAL=false"
t_new_case
t_ready_stack
grep -vxF offer-service "$STUB_DIR/services" >"$STUB_DIR/running"
t_run_sub t_setup_facts
t_expect "service stopped" "$T_STATUS" 1
t_expect_line "service stopped: verdict" "$T_CASE_DIR/out" \
    "FAIL readiness: services not running in project [et-test]: offer-service"
t_new_case
t_ready_stack
grep -vxF loadgen "$STUB_DIR/running" >"$STUB_DIR/services"
t_run_sub t_setup_facts
t_expect "no loadgen service" "$T_STATUS" 1
t_expect_line "no loadgen service: verdict" "$T_CASE_DIR/out" "FAIL readiness: the compose files define no loadgen service"
t_new_case
t_ready_stack
printf '%s\n' "DB_TYPE=sqlite" >"$STUB_DIR/env.db-adapter"
t_run_sub t_setup_facts
t_expect "unknown dialect" "$T_STATUS" 1
t_expect_line "unknown dialect: verdict" "$T_CASE_DIR/out" \
    "FAIL runtime facts: db-adapter DB_TYPE is [sqlite], expected mssql or postgres"
t_new_case
t_respond GET "$FLAG_URL" 200 '{"id":"portfolio-insights-enabled","enabled":false,"isModifiable":false}'
t_ready_stack
t_run_sub t_setup_facts
t_expect "flag locked" "$T_STATUS" 1
t_expect_line "flag locked: verdict" "$T_CASE_DIR/out" \
    "FAIL flag modifiable: isModifiable is [false]; a deployment with ENABLE_MODIFY=false cannot be toggled"
t_new_case
t_respond GET "$FLAG_URL" 200 '{"error":"feature_disabled"}'
t_ready_stack
t_run_sub t_setup_facts
t_expect "not the flag" "$T_STATUS" 1
t_expect_line "not the flag: verdict" "$T_CASE_DIR/out" \
    "FAIL flag modifiable: GET $FLAG_ID answered id [null] enabled [null] as application/json"
t_conclude "$check"

check="setFlag_responses_passesOnReadBackOrEndsRunWithFlagTouched"
t_new_case
t_respond PUT "$FLAG_URL" 200 '@request'
t_respond GET "$FLAG_URL" 200 '{"id":"portfolio-insights-enabled","enabled":true}'
t_run_sub t_set_flag_touch "run B flag true" true
t_expect "read back" "$T_STATUS|$(<"$T_CASE_DIR/out")|$(<"$STUB_DIR/http.calls")" "0|PASS run B flag true
FLAG_TOUCHED=1|PUT $FLAG_URL {\"enabled\": true}
GET $FLAG_URL"
t_new_case
t_respond PUT "$FLAG_URL" 500 '{"error":"internal"}'
t_run_sub t_set_flag_touch "run B flag true" true
t_expect "PUT refused" "$T_STATUS|$(<"$T_CASE_DIR/out")" "1|FAIL run B flag true: PUT {\"enabled\": true} gave status 500
FLAG_TOUCHED=1"
t_new_case
t_respond PUT "$FLAG_URL" 200 '@request'
t_respond GET "$FLAG_URL" 200 '{"id":"portfolio-insights-enabled","enabled":false}'
t_run_sub t_set_flag_touch "run B flag true" true
t_expect "read back differs" "$T_STATUS|$(<"$T_CASE_DIR/out")" \
    "1|FAIL run B flag true: read-back gave status 200 with enabled [false], expected true
FLAG_TOUCHED=1"
t_new_case
t_respond PUT "$FLAG_URL" 200 '@request'
t_run_sub t_set_flag_touch "run B flag true" true
t_expect "read back unreachable" "$T_STATUS|$(<"$T_CASE_DIR/out")" \
    "1|FAIL run B flag true: read-back gave transport error ($T_CURL_REFUSED) with enabled [], expected true
FLAG_TOUCHED=1"
t_conclude "$check"

check="openWindow_recreatedWeights_passesOnlyTheRequestedWeight"
t_new_case
t_run_sub t_open_window_state "run B" B 3
t_expect "weight applied" "$T_STATUS|$(<"$T_CASE_DIR/out")|$(<"$STUB_DIR/up.env")" "0|PASS run B loadgen weight: 3
WINDOW_OPEN=1 LOADGEN_TOUCHED=1 shell weight unset|PORTFOLIO_INSIGHTS_ALERT_WEIGHT=3"
t_expect_line "loadgen recreated alone" "$STUB_DIR/docker.calls" "--no-deps"
t_new_case
STUB_LOADGEN_WEIGHT=1
t_run_sub t_open_window_state "run B" B 3
t_expect "weight overridden" "$T_STATUS|$(<"$T_CASE_DIR/out")" \
    "1|FAIL run B loadgen weight: the recreated container has PORTFOLIO_INSIGHTS_ALERT_WEIGHT [1], expected [3]
WINDOW_OPEN=1 LOADGEN_TOUCHED=1 shell weight unset"
t_new_case
STUB_UP_STATUS=1
t_run_sub t_open_window_state "run B" B 3
t_expect "recreate failed" "$T_STATUS|$(<"$T_CASE_DIR/out")" \
    "1|FAIL run B loadgen weight: recreating loadgen with weight 3 failed (see $RUN_DIR/compose.log)
WINDOW_OPEN=1 LOADGEN_TOUCHED=1 shell weight unset"
t_conclude "$check"

check="windowStarted_loadgenLogs_succeedsOnFirstRunningVisit"
t_new_case
t_visit_line v1 "Setting up page for user [pi-user|10.0.0.1]" long_sell_success >"$STUB_DIR/loadgen.log"
set +e
window_started
status=$?
set -e
t_expect "no visit yet" "$status|$POLL_DETAIL" "1|no line contains [Running visit [] since $WINDOW_START"
t_new_case
{
    t_visit_line v1 "Running visit [long_sell_success]" long_sell_success
    t_visit_line v2 "Running visit [deposit_and_buy_success]" deposit_and_buy_success
} >"$STUB_DIR/loadgen.log"
set +e
window_started
status=$?
set -e
t_expect "first visit" "$status|$STARTED_DETAIL" "0|first visit [long_sell_success]"
t_conclude "$check"

check="breakdownSince_statsLines_savesBreakdownAndItsLineOrWaits"
t_new_case
{
    t_visit_line v1 "Running visit [deposit_and_buy_success]" deposit_and_buy_success
    t_stats_line "$J_LAST"
} >"$STUB_DIR/loadgen.log"
t_stats_line "$J_LAST" >"$T_CASE_DIR/expected.line"
set +e
breakdown_since "2026-01-01T00:35:00Z" "$RUN_DIR/breakdown-B.json"
status=$?
set -e
t_expect "stats line" "$status|$(<"$RUN_DIR/breakdown-B.json")" "0|$J_LAST"
t_expect "stats line file" "$(<"$RUN_DIR/breakdown-B.line")" "$(<"$T_CASE_DIR/expected.line")"
t_new_case
t_visit_line v1 "Running visit [deposit_and_buy_success]" deposit_and_buy_success >"$STUB_DIR/loadgen.log"
set +e
breakdown_since "2026-01-01T00:35:00Z" "$RUN_DIR/breakdown-B.json"
status=$?
set -e
saved="none"
if [[ -e "$RUN_DIR/breakdown-B.json" ]]; then
    saved="written"
fi
t_expect "no stats line" "$status|$POLL_DETAIL|$saved" \
    "1|no cumulative stats line stamped at or after 2026-01-01T00:35:00Z|none"
t_conclude "$check"

RUN_A_JSON='{"deposit_and_buy_success":{"total":2,"avgDurationMs":1,"failRate":0},"deposit_and_long_buy_success":{"total":1,"avgDurationMs":1,"failRate":0},"long_sell_success":{"total":1,"avgDurationMs":1,"failRate":0},"sell_and_withdraw_success":{"total":1,"avgDurationMs":1,"failRate":0},"order_credit_card":{"total":1,"avgDurationMs":1,"failRate":0}}'
RUN_A_VISIT_JSON='{"deposit_and_buy_success":{"total":2,"avgDurationMs":1,"failRate":0},"deposit_and_long_buy_success":{"total":1,"avgDurationMs":1,"failRate":0},"long_sell_success":{"total":1,"avgDurationMs":1,"failRate":0},"sell_and_withdraw_success":{"total":1,"avgDurationMs":1,"failRate":0},"order_credit_card":{"total":1,"avgDurationMs":1,"failRate":0},"portfolio_insights_alert":{"total":1,"avgDurationMs":1,"failRate":0}}'

# t_run_a_stack JSON: the stub answers of run A: the flag set off, and loadgen logging a first visit
# and then a cumulative breakdown JSON, or no visit for an empty JSON.
t_run_a_stack() {
    MINUTES=1
    t_respond PUT "$FLAG_URL" 200 '@request'
    t_respond GET "$FLAG_URL" 200 '{"id":"portfolio-insights-enabled","enabled":false}'
    if [[ -n "$1" ]]; then
        {
            t_visit_line v1 "Running visit [deposit_and_buy_success]" deposit_and_buy_success
            t_stats_line "$1"
        } >"$STUB_DIR/loadgen.log"
    fi
}

check="runA_breakdowns_checksExistingFamiliesAndNoVisitAtWeightZero"
t_new_case
t_run_a_stack "$RUN_A_JSON"
t_run_sub run_a
t_expect "visit absent: exit status" "$T_STATUS" 0
t_expect_no_match "visit absent: no failure" "$T_CASE_DIR/out" '^FAIL '
for family in $EXISTING_FAMILIES; do
    t_expect_match "visit absent: family $family" "$T_CASE_DIR/out" "^PASS run A family $family: "
done
t_expect_line "visit absent: verdict" "$T_CASE_DIR/out" "PASS run A no $VISIT"
t_new_case
t_run_a_stack "$RUN_A_VISIT_JSON"
t_run_sub run_a
t_expect "visit drawn: exit status" "$T_STATUS" 0
t_expect_line "visit drawn: verdict" "$T_CASE_DIR/out" "FAIL run A no $VISIT: entries [$VISIT] at weight 0"
t_new_case
t_run_a_stack ""
t_run_sub run_a
t_expect "never started: exit status" "$T_STATUS" 0
t_expect_match "never started: verdict" "$T_CASE_DIR/out" '^FAIL run A started: deadline 10 s expired; '
t_expect_no_match "never started: no family check" "$T_CASE_DIR/out" '^(PASS|FAIL) run A family '
t_expect_line "never started: loadgen stopped" "$T_CASE_DIR/out" "PASS run A loadgen stopped"
t_conclude "$check"

# ---------------------------------------------------------------------------------------------
# Visits in flight and run B's outcome lines

OPEN1="$(t_visit_line v1 "Opening portfolio insights page")"
OPEN2="$(t_visit_line v2 "Opening portfolio insights page")"

check="createsInFlight_visitLogs_countsVisitsOpenedWithoutCreateOutcome"
t_new_case
# t_expect_in_flight ROW EXPECTED [MESSAGE...]: creates_in_flight prints EXPECTED over visit v1
# opening the page and then logging each MESSAGE.
t_expect_in_flight() {
    local row="$1" expected="$2" message
    shift 2
    printf '%s\n' "$OPEN1" >"$T_CASE_DIR/flight.log"
    for message in "$@"; do
        t_visit_line v1 "$message" >>"$T_CASE_DIR/flight.log"
    done
    t_expect "$row" "$(creates_in_flight "$T_CASE_DIR/flight.log")" "$expected"
}
t_expect_in_flight "page opened, no outcome" 1
t_expect_in_flight "created" 0 "Created alert [$ID1] threshold [1000000.12345671]"
t_expect_in_flight "unconfirmed" 0 "Create unconfirmed threshold [1000000.12345671], outcome unknown"
t_expect_in_flight "no instrument options" 0 "Alert instrument options did not load, no alert created"
t_expect_in_flight "visit error" 0 "Worker had error when running visit: [Error: x]"
{
    printf '%s\n%s\n' "$OPEN1" "$OPEN2"
    t_visit_line v1 "Created alert [$ID1] threshold [1000000.12345671]"
} >"$T_CASE_DIR/two.log"
t_expect "one of two visits open" "$(creates_in_flight "$T_CASE_DIR/two.log")" 1
t_visit_line v3 "Opening portfolio insights page" deposit_and_buy_success >"$T_CASE_DIR/other.log"
t_expect "another visit's line" "$(creates_in_flight "$T_CASE_DIR/other.log")" 0
: >"$T_CASE_DIR/empty.log"
t_expect "empty log" "$(creates_in_flight "$T_CASE_DIR/empty.log")" 0
t_conclude "$check"

check="auditOwnedIds_outcomeLines_failsOutcomesCheck"
# The unknown outcome closes its visit, so the drain reaches Q; the alert left in place stays
# unresolved, so the drain stops loadgen at its deadline. Either way the final output holds the
# outcome line.
for row in "outcome unknown" "left in place"; do
    t_new_case
    {
        t_resolved_visit v1 "$ID1"
        printf '%s\n' "$OPEN2"
        if [[ "$row" == "outcome unknown" ]]; then
            t_visit_line v2 "Create unconfirmed threshold [1000000.12345672], outcome unknown"
        else
            t_visit_line v2 "Created alert [$ID2] threshold [1000000.12345672]"
            t_visit_line v2 "Alert [$ID2] left in place: 500"
        fi
    } >"$STUB_DIR/loadgen.log"
    t_run_sub audit_owned_ids
    t_expect "$row exit status" "$T_STATUS" 0
    t_expect_line "$row" "$T_CASE_DIR/out" \
        "FAIL owned-id outcomes: 1 lines report an alert left in place or an unknown outcome since $WINDOW_START"
done
t_conclude "$check"

# ---------------------------------------------------------------------------------------------
# Table and end of run

check="tableRows_breakdowns_printsOneRowPerVisitNameAndUncheckedFamily"
t_new_case
printf '%s\n' '{"long_sell_error":{"total":2,"avgDurationMs":1,"failRate":0.5},"deposit_and_buy_success":{"total":3,"avgDurationMs":1,"failRate":0}}' \
    >"$RUN_DIR/breakdown-A.json"
echo "1 long_sell_error" >"$RUN_DIR/errors-A"
record_verdict A long_sell PASS
record_verdict A deposit_and_buy PASS
record_verdict A deposit_and_buy FAIL
t_expect "run A" "$(table_rows A)" "| A | long_sell | long_sell_error | 2 | 0.5 | 1 | 1 | PASS |
| A | deposit_and_buy | deposit_and_buy_success | 3 | 0 | 3 | 0 | FAIL |
| A | deposit_and_long_buy | - | 0 | - | 0 | 0 | not checked |
| A | sell_and_withdraw | - | 0 | - | 0 | 0 | not checked |
| A | order_credit_card | - | 0 | - | 0 | 0 | not checked |"
printf '%s\n' "{\"$VISIT\":{\"total\":1,\"avgDurationMs\":1,\"failRate\":0}}" >"$RUN_DIR/breakdown-B.json"
rows="$(table_rows B)"
t_expect "run B without error counts" "${rows%%$'\n'*}" "| B | $VISIT | $VISIT | 1 | 0 | 1 | ? | not checked |"
t_expect "no breakdown" "$(table_rows B-flag-off)" "| B-flag-off | - | - | - | - | - | - | no breakdown |"
t_conclude "$check"

check="writeTable_outFile_writesTableOrFailsTableCheck"
t_new_case
printf '%s\n' "$RUN_A_JSON" >"$RUN_DIR/breakdown-A.json"
write_table >"$T_CASE_DIR/out"
t_expect "written" "$(<"$T_CASE_DIR/out")" "PASS table: $OUT_FILE"
t_expect_line "title" "$OUT_FILE" "# Loadgen live run"
t_expect_line "settings" "$OUT_FILE" \
    "Project \`et-test\`, db type postgres, weight 1, runs of 35 minutes, started 2026-01-01T00:00:00Z."
t_expect_line "header" "$OUT_FILE" "| run | family | visit name | total | failRate | completions | error lines | verdict |"
t_expect_line "run A row" "$OUT_FILE" "| A | order_credit_card | order_credit_card | 1 | 0 | 1 | ? | not checked |"
t_expect_line "run B row" "$OUT_FILE" "| B | - | - | - | - | - | - | no breakdown |"
t_new_case
OUT_FILE="$T_CASE_DIR/absent/table.md"
write_table >"$T_CASE_DIR/out" 2>"$T_CASE_DIR/err"
t_expect "directory missing" "$(<"$T_CASE_DIR/out")" \
    "FAIL table: could not write $OUT_FILE (see $RUN_DIR/table-error.log)"
t_conclude "$check"

check="finishRun_endOfRun_writesTableAndRestoresFlagOrEndsRun"
t_new_case
FLAG_INITIAL="true"
t_respond PUT "$FLAG_URL" 200 '@request'
t_respond GET "$FLAG_URL" 200 '{"id":"portfolio-insights-enabled","enabled":true}'
t_run_sub finish_run
t_expect "restored: exit status" "$T_STATUS" 0
t_expect_line "restored: table" "$T_CASE_DIR/out" "PASS table: $OUT_FILE"
t_expect_line "restored: flag" "$T_CASE_DIR/out" "PASS flag restored"
t_new_case
FLAG_INITIAL="true"
t_respond PUT "$FLAG_URL" 500 '{"error":"internal"}'
t_run_sub finish_run
t_expect "restore refused: exit status" "$T_STATUS" 1
t_expect_line "restore refused: verdict" "$T_CASE_DIR/out" \
    "FAIL flag restored: PUT {\"enabled\": true} gave status 500"
t_conclude "$check"

# ---------------------------------------------------------------------------------------------
# Cleanup

check="deleteRemaining_statuses_deletes204And404AndLeavesOthers"
t_new_case
printf '%s\n' "$ID1" "$ID2" "$ID3" "$ID4" "$ID5" >"$RUN_DIR/to-delete"
t_respond DELETE "$ALERTS_URL/$ID1" 204
t_respond DELETE "$ALERTS_URL/$ID2" 404 '{"error":"not_found"}'
t_respond DELETE "$ALERTS_URL/$ID3" 500 '{"error":"internal"}'
t_respond DELETE "$ALERTS_URL/$ID5" 403 '{"error":"feature_disabled"}'
delete_remaining >"$T_CASE_DIR/out"
t_expect "deleted and left" "$(t_lines "$RUN_DIR/deleted")|$CLEANUP_LEFT" "$ID1 $ID2|3"
t_expect "left lines" "$(<"$T_CASE_DIR/out")" "INFO cleanup left alert $ID3: status 500
INFO cleanup left alert $ID4: transport error ($T_CURL_REFUSED)
INFO cleanup left alert $ID5: status 403"
t_conclude "$check"

check="deleteRemaining_consecutiveTransportErrors_stopsAttemptingAtLimit"
t_new_case
t_ids 1 7 >"$RUN_DIR/to-delete"
delete_remaining >"$T_CASE_DIR/out"
t_expect "seven transport errors" "$(t_count "$STUB_DIR/http.calls")|$CLEANUP_LEFT" "5|7"
for t_n in 6 7; do
    printf -v t_line 'INFO cleanup left alert %08x-0000-4000-8000-%012x: not attempted after 5 transport errors in a row' \
        "$t_n" "$t_n"
    t_expect_line "alert $t_n not attempted" "$T_CASE_DIR/out" "$t_line"
done
t_new_case
t_ids 1 14 >"$RUN_DIR/to-delete"
t_respond DELETE "$ALERTS_URL/$ID5" 204
t_respond DELETE "$ALERTS_URL/$(t_ids 10 10)" 500 '{"error":"internal"}'
delete_remaining >"$T_CASE_DIR/out"
t_expect "four errors, a 204, four errors, a 500, four errors" \
    "$(t_count "$STUB_DIR/http.calls")|$CLEANUP_LEFT" "14|13"
t_conclude "$check"

check="cleanup_flagOffWithOwnedAlerts_enablesFlagToDeleteThenRestoresIt"
t_new_case
FLAG_INITIAL="false"
printf '%s\n' "$ID1" >"$RUN_DIR/owned"
t_respond GET "$FLAG_URL" 200 '{"id":"portfolio-insights-enabled","enabled":false}'
t_respond PUT "$FLAG_URL" 200 '@request'
t_respond DELETE "$ALERTS_URL/$ID1" 204
t_run_sub t_exit_through_cleanup 0
t_expect "requests" "$(<"$STUB_DIR/http.calls")" "GET $FLAG_URL
PUT $FLAG_URL {\"enabled\": true}
DELETE $ALERTS_URL/$ID1
PUT $FLAG_URL {\"enabled\": false}"
t_expect "exit status" "$T_STATUS" 0
t_expect_line "cleanup verdict" "$T_CASE_DIR/out" "PASS cleanup"
t_conclude "$check"

check="cleanup_failures_failsCleanupAndExitsOne"
t_new_case
FLAG_TOUCHED=1
FLAG_INITIAL="false"
t_respond PUT "$FLAG_URL" 500 '{"error":"internal"}'
t_run_sub t_exit_through_cleanup 0
t_expect "flag restore refused: exit status" "$T_STATUS" 1
t_expect_line "flag restore refused" "$T_CASE_DIR/out" \
    "FAIL cleanup: flag $FLAG_ID not restored to enabled=false: status 500"
t_new_case
FLAG_TOUCHED=1
FLAG_INITIAL="false"
t_run_sub t_exit_through_cleanup 0
t_expect "flag service unreachable: exit status" "$T_STATUS" 1
t_expect_line "flag service unreachable" "$T_CASE_DIR/out" \
    "FAIL cleanup: flag $FLAG_ID not restored to enabled=false: transport error ($T_CURL_REFUSED)"
t_new_case
FLAG_TOUCHED=1
FLAG_INITIAL="false"
t_respond PUT "$FLAG_URL" 200 '{"id":"portfolio-insights-enabled","enabled":true}'
t_run_sub t_exit_through_cleanup 0
t_expect "flag read back differs: exit status" "$T_STATUS" 1
t_expect_line "flag read back differs" "$T_CASE_DIR/out" \
    "FAIL cleanup: flag $FLAG_ID not restored to enabled=false: status 200"
t_new_case
FLAG_INITIAL="true"
printf '%s\n' "$ID1" "$ID2" >"$RUN_DIR/owned"
t_respond GET "$FLAG_URL" 200 '{"id":"portfolio-insights-enabled","enabled":true}'
t_respond DELETE "$ALERTS_URL/$ID1" 500 '{"error":"internal"}'
t_run_sub t_exit_through_cleanup 0
t_expect "alerts left in place: exit status" "$T_STATUS" 1
t_expect_line "alerts left in place" "$T_CASE_DIR/out" "FAIL cleanup: 2 owned alerts left in place"
t_new_case
WINDOW_OPEN=1
STUB_STOP_STATUS=1
t_run_sub t_exit_through_cleanup 0
t_expect "loadgen not stopped: exit status" "$T_STATUS" 1
t_expect_line "loadgen not stopped" "$T_CASE_DIR/out" \
    "FAIL cleanup: loadgen not confirmed stopped: compose stop loadgen failed, exit 1 (see $RUN_DIR/compose.log)"
t_conclude "$check"

check="cleanup_runStatus_exitsWithRunStatusOrOneAfterAFailedCheck"
for row in "clean run:0:0:0" "earlier check failed:0:1:1" "aborted run:1:1:1" "interrupt:130:0:130"; do
    IFS=: read -r t_label t_exit t_failed t_expected <<<"$row"
    t_new_case
    passed=2
    failed="$t_failed"
    t_run_sub t_exit_through_cleanup "$t_exit"
    t_expect "$t_label: exit status" "$T_STATUS" "$t_expected"
    t_expect_line "$t_label: cleanup verdict" "$T_CASE_DIR/out" "PASS cleanup"
    t_expect_line "$t_label: summary" "$T_CASE_DIR/out" "SUMMARY 3 passed, $t_failed failed"
done
t_conclude "$check"

echo "SUMMARY ${cases_passed} passed, ${cases_failed} failed"
if [[ $cases_failed -ne 0 ]]; then
    exit 1
fi
