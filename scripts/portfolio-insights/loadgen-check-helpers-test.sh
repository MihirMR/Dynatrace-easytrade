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
#   - the per-project run lock: taking it, refusing a run another run's lock stops, naming that
#     run from a regular owner file read within its time limit, and releasing it;
#   - the created, resolved and unresolved ids of loadgen's output, the ids it owns for cleanup,
#     and the count of visits between opening the page and their create outcome;
#   - the read-only Alerts count: SQL and client per dialect, refusal of non-canonical ids,
#     chunking, aggregation across chunks and client failures;
#   - run B's outcomes check, the per-family table, the end of the run and the cleanup run on
#     exit: owned alerts deleted, a DELETE retried after a transport error, owned and deleted
#     lists that cannot be read or written, the flag restored, and the exit status;
#   - the recovery record of a run directory and the --resume-cleanup run that deletes the owned
#     alerts a cleanup left, once Docker shows that --base-url reaches the project's reverse proxy,
#     under the project's run lock, which it releases however it ends.
# loadgen-check-test.sh covers the rest: run B's drain and owned-id audit, loadgen's log
# sanitizer, setup's restorability check, the drain of the loadgen found at start, the restore
# of loadgen and the flag-off window. harness-test.sh covers container_env, the time limits of
# the bounded Docker calls and the cleanup of a window still open.
# The script is sourced, which defines its functions without running it. docker, curl, date and
# sleep are then replaced by bash functions that record each call and answer from files the case
# writes: loadgen's output, a fake Alerts table, HTTP responses and a fake clock. timeout is
# replaced too, so the Docker calls the script bounds with timeout(1) reach the docker stub.
# The lock_refusal cases alone source the script in a fresh bash run under the real timeout(1),
# since the time limit of the owner read is what they test.
# Nothing reaches Docker, the network or a database, and no case waits in real time but the
# owner read that never ends, for the one second its lowered limit allows. The
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

for t_tool in jq awk sed grep sort comm paste tr wc mktemp cmp head timeout mkfifo ln chmod stat; do
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
# The flag as feature-flag-service serializes flag/model.go's Flag, off and on: every field, with
# enabledAt only while it is on, as SetEnabled sets it.
T_FLAG_OFF='{"id":"portfolio-insights-enabled","enabled":false,"name":"Portfolio insights","description":"When enabled, shows the simulated Portfolio Insights page and alerts and enables alert evaluation in broker-service. Demo feature, not financial advice.","isModifiable":true,"tag":"feature"}'
T_FLAG_ON='{"id":"portfolio-insights-enabled","enabled":true,"name":"Portfolio insights","description":"When enabled, shows the simulated Portfolio Insights page and alerts and enables alert evaluation in broker-service. Demo feature, not financial advice.","isModifiable":true,"tag":"feature","enabledAt":"2026-01-01T00:00:00Z"}'

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
    LOADGEN_IMAGE_AT_START=""
    LOADGEN_HASH_AT_START=""
    LOADGEN_CONFIG_AT_START=""
    LOADGEN_STARTED_AT=""
    LOADGEN_PAUSED=0
    RESTORE_ERROR=""
    LOADGEN_ID_AT_START=""
    LOADGEN_TWIN=""
    TWIN_ERROR=""
    TWIN_REMOVED=""
    TWIN_DETAIL=""
    LOADGEN_CID_AT_START=""
    AT_START_DRAINING=0
    RECOVER_ERROR=""
    WINDOW_OPEN=0
    WINDOW_UNREAD=0
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
    STUB_PS_STATUS=0
    STUB_PORT_STATUS=0
    STUB_UP_STATUS=0
    STUB_LOADGEN_WEIGHT=""
    STUB_VERSION_STATUS=0
    STARTED_DETAIL=""
    FAKE_NOW=1767225600
    # The run lock under this case's directory, never the shared /tmp the script's LOCK_ROOT names.
    LOCK_ROOT="$T_CASE_DIR"
    LOCK_DIR=""
    LOCK_HELD=0
    LOCK_ERROR=""
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

# The image every stub container runs, which its image reference names, and the config hash the
# stub's Compose gives loadgen and labels every container with: both invented, so every loadgen
# container is restorable (loadgen-check-test.sh covers the refusals).
T_STUB_IMAGE="sha256:0123456789ab0123456789ab0123456789ab0123456789ab0123456789ab0123"
T_STUB_HASH="fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

# docker: records each call in STUB_DIR/docker.calls, its MSYS_NO_PATHCONV value and then one
# argument per line, ended by "--". docker inspect --format '{{json .Config.Env}}' cid-SERVICE
# prints the entries of STUB_DIR/env.SERVICE as the JSON array container_env and
# container_env_entry read, and --format '{{json .}}' the container as loadgen_identity reads it:
# T_STUB_IMAGE, created from et-test-SERVICE, labelled with T_STUB_HASH; any other format fails.
# docker image inspect prints T_STUB_IMAGE. The compose subcommand after the -p and -f options
# plays as follows: config --hash SERVICE prints SERVICE and T_STUB_HASH, config
# --no-interpolate the declaration of loadgen's weight, and any other config STUB_DIR/services;
# ps ... --services prints STUB_DIR/running and exits STUB_PS_STATUS, and ps ... SERVICE prints
# cid-SERVICE when STUB_DIR/env.SERVICE exists; port SERVICE PORT prints STUB_DIR/port.SERVICE,
# the published HOST:PORT, or, when STUB_PORT_STATUS is not 0, prints Compose's error and exits
# with it; logs prints STUB_DIR/loadgen.log and exits STUB_LOGS_STATUS; up records the
# PORTFOLIO_INSIGHTS_ALERT_WEIGHT it gets in STUB_DIR/up.env and exits STUB_UP_STATUS, giving
# loadgen that weight, or STUB_LOADGEN_WEIGHT when set, on success; stop, and the kill that ends
# a paused loadgen, exit STUB_STOP_STATUS; pause and unpause succeed; version exits
# STUB_VERSION_STATUS; exec runs the db client stub on its last argument; anything else succeeds
# without output. The twin the restorability check creates, up ... --scale loadgen=2, records its
# weight in STUB_DIR/twin.env and becomes container cid-loadgen-twin, answered as loadgen's own
# container is and listed after it by ps ... loadgen, until docker rm --force --volumes
# cid-loadgen-twin removes it.
docker() {
    local -a args=("$@")
    local i=1 last="${*: -1}" service
    {
        printf 'MSYS_NO_PATHCONV=%s\n' "${MSYS_NO_PATHCONV:-}"
        printf '%s\n' "$@"
        printf -- '--\n'
    } >>"$STUB_DIR/docker.calls"
    if [[ "${args[0]:-}" == "rm" ]]; then
        if [[ "$last" == "cid-loadgen-twin" ]]; then
            rm -f "$STUB_DIR/twin.loadgen"
        fi
        return 0
    fi
    if [[ "${args[0]:-} ${args[1]:-}" == "image inspect" ]]; then
        echo "$T_STUB_IMAGE"
        return 0
    fi
    if [[ "${args[0]:-}" == "inspect" ]]; then
        service="${last#cid-}"
        service="${service%-twin}"
        case "${args[2]:-}" in
            "{{json .Config.Env}}")
                t_print_file "$STUB_DIR/env.$service" | jq -c -R -s 'split("\n") | map(select(length > 0))'
                ;;
            "{{json .}}")
                jq -c -n --arg image "$T_STUB_IMAGE" --arg ref "et-test-$service" --arg hash "$T_STUB_HASH" \
                    '{Image: $image, Config: {Image: $ref, Labels: {"com.docker.compose.config-hash": $hash}},
                        State: {StartedAt: "2026-01-01T00:00:00.5Z"}}'
                ;;
            *)
                echo "stub docker: unexpected inspect format [${args[2]:-}]" >&2
                return 1
                ;;
        esac
        return 0
    fi
    while [[ $i -lt ${#args[@]} && ("${args[i]}" == "-p" || "${args[i]}" == "-f") ]]; do
        i=$((i + 2))
    done
    case "${args[i]:-}" in
        config)
            # shellcheck disable=SC2016 # Compose's declaration text, never expanded.
            case "${args[i + 1]:-}" in
                --hash) echo "$last $T_STUB_HASH" ;;
                --no-interpolate) echo '{"services":{"loadgen":{"environment":{"PORTFOLIO_INSIGHTS_ALERT_WEIGHT":"${PORTFOLIO_INSIGHTS_ALERT_WEIGHT:-0}"}}}}' ;;
                *) t_print_file "$STUB_DIR/services" ;;
            esac
            ;;
        ps)
            if [[ "$last" == "--services" ]]; then
                t_print_file "$STUB_DIR/running"
                return "$STUB_PS_STATUS"
            elif [[ -f "$STUB_DIR/env.$last" ]]; then
                echo "cid-$last"
                if [[ "$last" == loadgen && -f "$STUB_DIR/twin.loadgen" ]]; then
                    echo "cid-loadgen-twin"
                fi
            fi
            ;;
        port)
            if [[ $STUB_PORT_STATUS -ne 0 ]]; then
                echo "service \"${args[i + 1]:-}\" is not running" >&2
                return "$STUB_PORT_STATUS"
            fi
            t_print_file "$STUB_DIR/port.${args[i + 1]:-}"
            ;;
        logs)
            t_print_file "$STUB_DIR/loadgen.log"
            return "$STUB_LOGS_STATUS"
            ;;
        up)
            if [[ " ${args[*]} " == *" --scale loadgen=2 "* ]]; then
                printf 'PORTFOLIO_INSIGHTS_ALERT_WEIGHT=%s\n' "${PORTFOLIO_INSIGHTS_ALERT_WEIGHT-unset}" >>"$STUB_DIR/twin.env"
                : >"$STUB_DIR/twin.loadgen"
                return 0
            fi
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
# BODY @flag plays feature-flag-service: it answers T_FLAG_ON or T_FLAG_OFF for the state in
# STUB_DIR/flag.enabled, false while that file is absent, which a PUT first sets to the enabled
# value of its request body. Status 000, or no matching line, is a transport error. A request
# STUB_DIR/http.transient lists as METHOD URL is a transport error first, once per such line
# (t_respond_transient). Each request is recorded in STUB_DIR/http.calls as METHOD URL [BODY],
# and its --max-time in STUB_DIR/http.max-times.
curl() {
    local method="GET" out="" url="" body="" status="" reply="" r_method r_url r_status r_body
    local state=false flag_re='"enabled": (true|false)'
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
            -D | -w | -H)
                shift 2
                ;;
            --max-time)
                printf '%s\n' "$2" >>"$STUB_DIR/http.max-times"
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
    if [[ -s "$STUB_DIR/http.transient" ]] && t_take_transient "$method $url"; then
        echo "$T_CURL_REFUSED" >&2
        return 7
    fi
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
    if [[ "$reply" == "@flag" ]]; then
        if [[ "$method" == "PUT" && "$body" =~ $flag_re ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}" >"$STUB_DIR/flag.enabled"
        fi
        if [[ -f "$STUB_DIR/flag.enabled" ]]; then
            read -r state <"$STUB_DIR/flag.enabled"
        fi
        reply="$T_FLAG_OFF"
        if [[ "$state" == "true" ]]; then
            reply="$T_FLAG_ON"
        fi
    fi
    printf '%s' "$reply" >"$out"
    printf '%s' "$status"
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

# t_respond_transient METHOD URL COUNT: the next COUNT requests METHOD URL end in a transport
# error before the stub curl answers them from STUB_DIR/http.responses.
t_respond_transient() {
    local i
    for ((i = 0; i < $3; i++)); do
        printf '%s %s\n' "$1" "$2" >>"$STUB_DIR/http.transient"
    done
}

# t_take_transient KEY: removes the first line KEY from STUB_DIR/http.transient; fails when no
# line is KEY. The stub curl runs in http()'s command substitution, so the count lives in a file.
t_take_transient() {
    local i
    local -a lines=()
    mapfile -t lines <"$STUB_DIR/http.transient"
    for i in "${!lines[@]}"; do
        if [[ "${lines[i]}" == "$1" ]]; then
            unset 'lines[i]'
            if [[ ${#lines[@]} -gt 0 ]]; then
                printf '%s\n' "${lines[@]}" >"$STUB_DIR/http.transient"
            else
                : >"$STUB_DIR/http.transient"
            fi
            return 0
        fi
    done
    return 1
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

# t_attempt_lasting SECONDS STATUS: a poll attempt that takes SECONDS of the fake clock, leaves
# POLL_DETAIL and returns STATUS.
t_attempt_lasting() {
    t_attempts=$((t_attempts + 1))
    FAKE_NOW=$((FAKE_NOW + $1))
    POLL_DETAIL="attempt $t_attempts"
    return "$2"
}

# t_succeed_lasting N SECONDS: t_succeed_on N, whose succeeding Nth attempt takes SECONDS of the
# fake clock.
t_succeed_lasting() {
    t_succeed_on "$1" || return 1
    FAKE_NOW=$((FAKE_NOW + $2))
}

# t_poll_outcome TIMEOUT STEP COMMAND [ARGS...]: poll "readiness" TIMEOUT STEP COMMAND ARGS in a
# fresh case. Sets T_OUTCOME to STATUS|ATTEMPTS|SLEEPS|REPORT: the poll's status, the attempts
# COMMAND counted, the sleeps the poll took and the lines it printed.
t_poll_outcome() {
    local status=0
    t_new_case
    t_attempts=0
    poll "readiness" "$@" >"$T_CASE_DIR/poll.out" || status=$?
    T_OUTCOME="$status|$t_attempts|$(t_lines "$STUB_DIR/sleeps")|$(<"$T_CASE_DIR/poll.out")"
}

# t_readiness_outcome: readiness_once with the case's PROBE_DEADLINE. Sets T_OUTCOME to
# STATUS|MAX_TIMES|REQUESTS|DETAIL: its status, the --max-time of each request it sent, those
# requests and the POLL_DETAIL it left.
t_readiness_outcome() {
    local status=0
    : >"$STUB_DIR/http.calls"
    : >"$STUB_DIR/http.max-times"
    readiness_once || status=$?
    T_OUTCOME="$status|$(t_lines "$STUB_DIR/http.max-times")|$(t_lines "$STUB_DIR/http.calls")|$POLL_DETAIL"
}

# t_readiness_ticking: prints the T_OUTCOME of t_readiness_outcome under a clock that each
# date -u +%s moves on by 7 s, as when the broker-service request takes 7 s. Run it in a subshell,
# so that only the subshell keeps that clock.
t_readiness_ticking() {
    echo "$FAKE_NOW" >"$STUB_DIR/clock"
    # shellcheck disable=SC2329 # Invoked by readiness_once.
    date() {
        local now
        now="$(<"$STUB_DIR/clock")"
        echo $((now + 7)) >"$STUB_DIR/clock"
        echo "$now"
    }
    t_readiness_outcome
    echo "$T_OUTCOME"
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
    t_respond GET "$FLAG_URL" 200 "$T_FLAG_OFF"
}

# t_flag_body FILTER: T_FLAG_OFF after the jq FILTER, compact, with a string result printed raw,
# so a FILTER can also give a body that is no JSON object, or no JSON at all.
t_flag_body() {
    local body
    body="$(jq -r -c "$1" <<<"$T_FLAG_OFF")"
    printf '%s' "${body//$'\r'/}"
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
t_dash_refused="requires a value; the next argument starts with '-' and is not taken as one."
t_expect_usage_error "value is an option" "Option --minutes $t_dash_refused" --minutes --project et-test
t_expect_usage_error "empty value" "Option --out requires a value." --project et-test --out ""
t_expect_usage_error "dash-prefixed value" "Option --project $t_dash_refused" --project -x-not-shown-7d1e
t_expect_no_match "dash-prefixed value: not echoed" "$T_CASE_DIR/err" "not-shown-7d1e"
for option in --weight --minutes; do
    t_expect_usage_error "$option -x" "Option $option $t_dash_refused" --project et-test "$option" -x
    # A negative number is taken as the value, so the count rule names it.
    for value in -1 -5 0 1.5 1234567890; do
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

check="parseOptions_shortOrLongHelp_printsUsageWithExamplesAndExitsZero"
for option in -h --help; do
    t_new_case
    t_run_sub parse_options --project et-test "$option"
    first=""
    IFS= read -r first <"$T_CASE_DIR/out" || true
    t_expect "$option" "$T_STATUS|$first|$(<"$T_CASE_DIR/err")" \
        "0|Usage: scripts/portfolio-insights/loadgen-check.sh --project NAME [--base-url URL]|"
    t_expect_line "$option: both spellings listed" "$T_CASE_DIR/out" \
        "  -h, --help           Show this help and exit"
    t_expect_line "$option: examples heading" "$T_CASE_DIR/out" "Examples:"
    t_expect_line "$option: full run example" "$T_CASE_DIR/out" \
        "    scripts/portfolio-insights/loadgen-check.sh --project pi-dev-mssql"
    t_expect_line "$option: override file example" "$T_CASE_DIR/out" \
        "        --compose-file compose.dev.yaml --compose-file OVERRIDE.yaml --out FILE"
done
t_conclude "$check"

# t_resume_settings ARGS...: parse_options ARGS, then the run directory to resume.
t_resume_settings() {
    parse_options "$@"
    printf 'RESUME_RUN_DIR=%s\n' "$RESUME_RUN_DIR"
}

check="parseOptions_resumeCleanup_takesRunDirAndRefusesNewRunOptions"
t_new_case
: >"$T_CASE_DIR/compose.yaml"
t_run_sub t_resume_settings --project et-test --compose-file "$T_CASE_DIR/compose.yaml" \
    --resume-cleanup "$T_CASE_DIR/run dir"
t_expect "run dir taken" "$T_STATUS|$(<"$T_CASE_DIR/out")" "0|RESUME_RUN_DIR=$T_CASE_DIR/run dir"
t_run_sub t_resume_settings --project et-test --compose-file "$T_CASE_DIR/compose.yaml"
t_expect "a new run by default" "$T_STATUS|$(<"$T_CASE_DIR/out")" "0|RESUME_RUN_DIR="
t_expect_usage_error "value missing" "Option --resume-cleanup requires a value." \
    --project et-test --resume-cleanup
for t_name in --weight --minutes --out; do
    case "$t_name" in
        --weight) t_value=2 ;;
        --minutes) t_value=5 ;;
        --out) t_value="$T_CASE_DIR/table.md" ;;
    esac
    t_expect_usage_error "$t_name" \
        "Option $t_name cannot be combined with --resume-cleanup, which takes only --project, --base-url and --compose-file." \
        --project et-test --compose-file "$T_CASE_DIR/compose.yaml" --resume-cleanup "$RUN_DIR" \
        "$t_name" "$t_value"
done
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
# Run lock

# t_lock_dir: the lock directory of project et-test under the LOCK_ROOT t_new_case sets.
t_lock_dir() {
    printf '%s' "$T_CASE_DIR/pi-loadgen-check.et-test.lock"
}

# t_lock_presence PATH: present or absent.
t_lock_presence() {
    if [[ -e "$1" ]]; then
        echo present
    else
        echo absent
    fi
}

# t_setup_lock_state: setup, printing LOCK_HELD on the way out, whether setup returns or ends the
# run.
t_setup_lock_state() {
    trap 'echo "LOCK_HELD=$LOCK_HELD"' EXIT
    setup
}

# t_setup_through_cleanup: setup, ending through the script's EXIT trap as a run of the script ends.
t_setup_through_cleanup() {
    trap cleanup EXIT
    setup
}

# t_lock_through_cleanup [EXTRA]: acquire_run_lock, then the end of the run through the script's
# EXIT trap; with EXTRA, a file of that name is left in the lock directory first.
t_lock_through_cleanup() {
    trap cleanup EXIT
    acquire_run_lock
    if [[ -n "${1:-}" ]]; then
        : >"$LOCK_DIR/$1"
    fi
    exit 0
}

# t_lock_through_resume_exit [EXTRA]: acquire_run_lock, then the end of a --resume-cleanup run
# before cleanup takes over, through resume_exit; with EXTRA, a file of that name is left in the
# lock directory first.
t_lock_through_resume_exit() {
    trap resume_exit EXIT
    acquire_run_lock
    if [[ -n "${1:-}" ]]; then
        : >"$LOCK_DIR/$1"
    fi
    exit 0
}

# t_exit_through_resume_exit: the end of a --resume-cleanup run through resume_exit, without its
# run lock, as when the lock is refused.
t_exit_through_resume_exit() {
    trap resume_exit EXIT
    exit 0
}

# t_unrecordable_lock: acquire_run_lock with an mv that fails, ending through the EXIT trap.
t_unrecordable_lock() {
    mv() {
        echo "mv: simulated failure" >&2
        return 1
    }
    trap cleanup EXIT
    acquire_run_lock
}

# t_expect_refused LABEL HOLDER [ENDED_PID]: setup on a ready stack whose lock another run holds
# fails the run lock check naming the holder as HOLDER, saying the holder has ended when its pid
# ENDED_PID is given, reads and requests nothing more, and leaves that run's lock as it was.
t_expect_refused() {
    local dir hint before="none" after="none"
    dir="$(t_lock_dir)"
    if [[ -f "$dir/owner" ]]; then
        before="$(<"$dir/owner")"
    fi
    if [[ -n "${3:-}" ]]; then
        hint="Pid $3 no longer runs on this host, so that run has ended and left the lock stale: remove $dir once no run on the project is active, and start again."
    else
        hint="If no run on the project is active, as after a run killed before its cleanup, remove $dir and start again."
    fi
    t_ready_stack
    t_run_sub t_setup_through_cleanup
    t_expect "$1: exit status" "$T_STATUS" 1
    t_expect_line "$1: verdict" "$T_CASE_DIR/out" \
        "FAIL run lock: project [et-test] is in use by another run, which holds $dir ($2). One invocation per project runs at a time, so this run stops before it reads or changes anything. $hint"
    t_expect_line "$1: summary" "$T_CASE_DIR/out" "SUMMARY 1 passed, 1 failed"
    t_expect_no_match "$1: no later check" "$T_CASE_DIR/out" 'readiness|runtime facts|flag modifiable|released'
    t_expect "$1: no request" "$(<"$STUB_DIR/http.calls")" ""
    t_expect_no_match "$1: no container read" "$STUB_DIR/docker.calls" '^(ps|inspect)$'
    if [[ -f "$dir/owner" ]]; then
        after="$(<"$dir/owner")"
    fi
    t_expect "$1: holder's lock kept" "$(t_lock_presence "$dir")|$after" "present|$before"
}

check="acquireRunLock_lockFree_holdsLockRecordingThisRunBeforeReadiness"
t_new_case
t_ready_stack
t_run_sub t_setup_lock_state
first=""
IFS= read -r first <"$T_CASE_DIR/out" || true
t_expect "exit status and first check" "$T_STATUS|$first" "0|PASS run lock: $(t_lock_dir)"
t_expect_line "readiness follows" "$T_CASE_DIR/out" "PASS readiness"
t_expect_line "lock held" "$T_CASE_DIR/out" "LOCK_HELD=1"
t_expect "owner file" "$(<"$(t_lock_dir)/owner")" "pid=$$
host=$HOSTNAME
started=$STARTED_AT
run_dir=$RUN_DIR"
t_expect "no partial owner file" "$(t_lock_presence "$(t_lock_dir)/owner.new")" absent
t_conclude "$check"

check="acquireRunLock_lockHeld_failsNamingHolderAndLeavesItsLock"
# A pid that has just ended: a subshell, waited for.
(exit 0) &
t_ended_pid=$!
wait "$t_ended_pid" || true
# The first run is this test's shell: alive, on this host.
t_new_case
t_run_sub acquire_run_lock
t_expect "first run: exit status" "$T_STATUS" 0
t_expect_refused "holder running here" "started $STARTED_AT, pid $$, host $HOSTNAME, run dir $RUN_DIR"
t_new_case
mkdir "$(t_lock_dir)"
printf '%s\n' "pid=$t_ended_pid" "host=$HOSTNAME" "started=2026-01-01T00:00:00Z" \
    "run_dir=/tmp/pi-loadgen.AbC123" >"$(t_lock_dir)/owner"
t_expect_refused "holder ended here" \
    "started 2026-01-01T00:00:00Z, pid $t_ended_pid, host $HOSTNAME, run dir /tmp/pi-loadgen.AbC123" \
    "$t_ended_pid"
t_new_case
mkdir "$(t_lock_dir)"
printf '%s\n' "pid=$t_ended_pid" "host=other-host.invalid" "started=2026-01-01T00:00:00Z" \
    "run_dir=/tmp/pi-loadgen.AbC123" >"$(t_lock_dir)/owner"
t_expect_refused "holder on another host" \
    "started 2026-01-01T00:00:00Z, pid $t_ended_pid, host other-host.invalid, run dir /tmp/pi-loadgen.AbC123"
t_new_case
mkdir "$(t_lock_dir)"
printf '%s\n' "pid=1; touch probe-7d1e" $'host=\e[31mprobe-7d1e' "started=probe-7d1e" \
    $'run_dir=/tmp/a\tprobe-7d1e' "probe-7d1e" >"$(t_lock_dir)/owner"
t_expect_refused "owner fields in another form" \
    "started unknown, pid unknown, host unknown, run dir unknown"
t_expect_no_match "owner fields in another form: file text not shown" "$T_CASE_DIR/out" $'probe-7d1e|\e'
t_new_case
mkdir "$(t_lock_dir)"
t_expect_refused "no owner file" "started unknown, pid unknown, host unknown, run dir unknown"
t_conclude "$check"

# The bound of each lock_refusal run under the real timeout(1), far above the fraction of a
# second a run takes, so only an owner read that never ends reaches it. tests.md rules out sleeps
# and arbitrary timeouts as a way to wait for asynchronous work: this bound waits for nothing,
# and only turns a read that hangs into a failing case rather than a suite that never ends.
T_LOCK_BOUND_SECONDS=20

# t_owner_fields: the text of an owner file, as acquire_run_lock writes it, of a run on another
# host.
t_owner_fields() {
    printf '%s\n' "pid=1" "host=other-host.invalid" "started=2026-01-01T00:00:00Z" \
        "run_dir=/tmp/pi-loadgen.AbC123"
}

# t_entry_kind PATH: what PATH is, a symlink not followed: symlink, fifo, file, other or absent.
t_entry_kind() {
    if [[ -L "$1" ]]; then
        echo symlink
    elif [[ -p "$1" ]]; then
        echo fifo
    elif [[ -f "$1" ]]; then
        echo file
    elif [[ -e "$1" ]]; then
        echo other
    else
        echo absent
    fi
}

# t_refusal HOLDER: lock_refusal's text for project et-test over t_lock_dir, naming HOLDER, a run
# not known to have ended.
t_refusal() {
    printf '%s' "project [et-test] is in use by another run, which holds $(t_lock_dir) ($1). One invocation per project runs at a time, so this run stops before it reads or changes anything. If no run on the project is active, as after a run killed before its cleanup, remove $(t_lock_dir) and start again."
}

# t_lock_refusal_within READ_LIMIT [BIN_DIR]: lock_refusal for project et-test over t_lock_dir,
# with LOCK_READ_TIMEOUT_SECONDS at READ_LIMIT and BIN_DIR, when given, first on PATH. It runs in
# a fresh bash that sources the script, so hard_timeout reaches the real timeout(1) rather than
# the stub, and that bash runs under the real timeout(1) too, which kills it
# T_LOCK_BOUND_SECONDS after its start: T_STATUS is then 137, and each FIFO of the lock directory
# gets a writer, which ends a reader still blocked on it. Output goes to T_CASE_DIR/out.
t_lock_refusal_within() {
    local entry
    set +e
    # shellcheck disable=SC2016 # The fresh bash expands its own arguments.
    command timeout -s KILL "$T_LOCK_BOUND_SECONDS" bash -c '
        source "$1" || exit 2
        PROJECT=et-test
        LOCK_DIR="$2"
        LOCK_READ_TIMEOUT_SECONDS="$3"
        if [[ -n "$4" ]]; then
            PATH="$4:$PATH"
        fi
        lock_refusal' _ "$T_SCRIPT" "$(t_lock_dir)" "$1" "${2:-}" \
        >"$T_CASE_DIR/out" 2>"$T_CASE_DIR/err" </dev/null
    T_STATUS=$?
    set -e
    if [[ $T_STATUS -eq 137 ]]; then
        for entry in "$(t_lock_dir)"/*; do
            if [[ -p "$entry" ]]; then
                # shellcheck disable=SC2016 # The writer's bash expands its own argument.
                command timeout -s KILL 2 bash -c ': >"$1"' _ "$entry" || true
            fi
        done
    fi
}

# t_hanging_head DIR: a head in DIR that never answers within T_LOCK_BOUND_SECONDS. This is the
# stimulus, a read that never ends, as harness-test.sh's fake docker hangs: it outlasts the bound,
# so a broken read limit fails the case, and then ends by itself, so it leaves no process behind.
t_hanging_head() {
    mkdir -p "$1"
    printf '#!/usr/bin/env bash\nexec sleep %s\n' "$((T_LOCK_BOUND_SECONDS + 10))" >"$1/head"
    chmod +x "$1/head"
}

check="lockRefusal_ownerEntryKinds_namesHolderOnlyFromARegularFileAndKeepsTheLock"
# The read limit lies beyond the bound, so only the entry-type test can end in time a run whose
# owner is a FIFO. Under Git Bash, ln makes a real symlink only with winsymlinks:sys; other
# systems ignore MSYS.
for t_kind in "regular file" FIFO "symlink to a regular file" "symlink to a FIFO"; do
    t_new_case
    mkdir "$(t_lock_dir)"
    t_owner="$(t_lock_dir)/owner"
    t_holder="started unknown, pid unknown, host unknown, run dir unknown"
    t_made="symlink"
    case "$t_kind" in
        "regular file")
            t_owner_fields >"$t_owner"
            t_holder="started 2026-01-01T00:00:00Z, pid 1, host other-host.invalid, run dir /tmp/pi-loadgen.AbC123"
            t_made="file"
            ;;
        FIFO)
            mkfifo "$t_owner"
            t_made="fifo"
            ;;
        "symlink to a regular file")
            t_owner_fields >"$T_CASE_DIR/owner.target"
            MSYS=winsymlinks:sys ln -s "$T_CASE_DIR/owner.target" "$t_owner"
            ;;
        "symlink to a FIFO")
            mkfifo "$T_CASE_DIR/owner.target"
            MSYS=winsymlinks:sys ln -s "$T_CASE_DIR/owner.target" "$t_owner"
            ;;
    esac
    t_expect "[$t_kind]: entry made" "$(t_entry_kind "$t_owner")" "$t_made"
    t_lock_refusal_within $((T_LOCK_BOUND_SECONDS * 3))
    t_expect "[$t_kind]: status and refusal" "$T_STATUS|$(<"$T_CASE_DIR/out")" "0|$(t_refusal "$t_holder")"
    t_expect "[$t_kind]: lock kept" "$(t_lock_presence "$(t_lock_dir)")|$(t_entry_kind "$t_owner")" \
        "present|$t_made"
done
t_conclude "$check"

check="lockRefusal_ownerReadNeverEnds_namesUnknownHolderAtTheReadLimit"
t_new_case
mkdir "$(t_lock_dir)"
t_owner_fields >"$(t_lock_dir)/owner"
t_hanging_head "$T_CASE_DIR/bin"
t_lock_refusal_within 1 "$T_CASE_DIR/bin"
t_expect "status and refusal" "$T_STATUS|$(<"$T_CASE_DIR/out")" \
    "0|$(t_refusal "started unknown, pid unknown, host unknown, run dir unknown")"
t_expect "lock kept" "$(t_lock_presence "$(t_lock_dir)")|$(<"$(t_lock_dir)/owner")" "present|$(t_owner_fields)"
t_conclude "$check"

check="acquireRunLock_notComposeProjectName_failsWithoutTakingLock"
for t_name in Et-test _et et.test et/../x "et test"; do
    t_new_case
    PROJECT="$t_name"
    t_run_sub acquire_run_lock
    t_expect "[$t_name]: exit status" "$T_STATUS" 1
    t_expect_line "[$t_name]: verdict" "$T_CASE_DIR/out" \
        "FAIL run lock: project name [$(printf '%q' "$t_name")] is not a Compose project name (lower-case letters, digits, - and _, starting with a letter or digit), so no lock is taken for it"
    t_expect "[$t_name]: no lock" "$(compgen -G "$T_CASE_DIR/*.lock" || true)" ""
done
t_conclude "$check"

check="acquireRunLock_lockNotCreatable_failsNamingTheError"
t_new_case
LOCK_ROOT="$T_CASE_DIR/absent"
t_run_sub acquire_run_lock
first=""
IFS= read -r first <"$T_CASE_DIR/out" || true
t_expect "exit status" "$T_STATUS" 1
if [[ "$first" != "FAIL run lock: could not create $T_CASE_DIR/absent/pi-loadgen-check.et-test.lock: mkdir: "* ]]; then
    t_reasons+=("verdict: got [$(t_text "$first")]")
fi
t_conclude "$check"

check="acquireRunLock_ownerNotRecorded_failsAndCleanupRemovesTheLock"
t_new_case
t_run_sub t_unrecordable_lock
t_expect "exit status" "$T_STATUS" 1
t_expect_line "verdict" "$T_CASE_DIR/out" \
    "FAIL run lock: created $(t_lock_dir) but could not record this run in it: mv: simulated failure"
t_expect_line "released" "$T_CASE_DIR/out" "INFO cleanup: run lock $(t_lock_dir) released"
t_expect "lock removed" "$(t_lock_presence "$(t_lock_dir)")" absent
t_conclude "$check"

check="cleanup_runLock_releasesOnlyALockThisRunHolds"
t_new_case
t_run_sub t_lock_through_cleanup
t_expect "held: exit status" "$T_STATUS" 0
t_expect_line "held: released" "$T_CASE_DIR/out" "INFO cleanup: run lock $(t_lock_dir) released"
t_expect_line "held: cleanup passes" "$T_CASE_DIR/out" "PASS cleanup"
t_expect "held: lock removed" "$(t_lock_presence "$(t_lock_dir)")" absent
t_new_case
mkdir "$(t_lock_dir)"
echo "pid=1" >"$(t_lock_dir)/owner"
t_run_sub t_exit_through_cleanup 0
t_expect "not held: exit status" "$T_STATUS" 0
t_expect_no_match "not held: nothing released" "$T_CASE_DIR/out" 'run lock'
t_expect "not held: other run's lock kept" "$(<"$(t_lock_dir)/owner")" "pid=1"
t_new_case
t_run_sub t_lock_through_cleanup extra
t_expect "removal fails: exit status" "$T_STATUS" 1
t_expect_match "removal fails: verdict" "$T_CASE_DIR/out" \
    '^FAIL cleanup: run lock not released: removing .*/pi-loadgen-check[.]et-test[.]lock failed: rmdir: '
t_expect "removal fails: unknown file kept" "$(t_lock_presence "$(t_lock_dir)/extra")" present
t_conclude "$check"

check="resumeExit_runLock_releasesOnlyALockThisRunHolds"
# resume_exit ends a --resume-cleanup run that stops before cleanup takes over: it removes the
# lock the run took, fails the cleanup check when that removal fails, and prints the SUMMARY line.
t_new_case
t_run_sub t_lock_through_resume_exit
t_expect "held: exit status" "$T_STATUS" 0
t_expect_line "held: released" "$T_CASE_DIR/out" "INFO cleanup: run lock $(t_lock_dir) released"
t_expect_line "held: summary" "$T_CASE_DIR/out" "SUMMARY 1 passed, 0 failed"
t_expect "held: lock removed" "$(t_lock_presence "$(t_lock_dir)")" absent
t_new_case
mkdir "$(t_lock_dir)"
echo "pid=1" >"$(t_lock_dir)/owner"
t_run_sub t_exit_through_resume_exit
t_expect "not held: exit status" "$T_STATUS" 0
t_expect_no_match "not held: nothing released" "$T_CASE_DIR/out" 'run lock'
t_expect_line "not held: summary" "$T_CASE_DIR/out" "SUMMARY 0 passed, 0 failed"
t_expect "not held: other run's lock kept" "$(<"$(t_lock_dir)/owner")" "pid=1"
t_new_case
t_run_sub t_lock_through_resume_exit extra
t_expect "removal fails: exit status" "$T_STATUS" 1
t_expect_match "removal fails: verdict" "$T_CASE_DIR/out" \
    '^FAIL cleanup: run lock not released: removing .*/pi-loadgen-check[.]et-test[.]lock failed: rmdir: '
t_expect_line "removal fails: summary" "$T_CASE_DIR/out" "SUMMARY 1 passed, 1 failed"
t_expect "removal fails: unknown file kept" "$(t_lock_presence "$(t_lock_dir)/extra")" present
t_conclude "$check"

# ---------------------------------------------------------------------------------------------
# HTTP, polling and logs

check="http_responses_setsStatusAndBodyOrTransportError"
t_new_case
t_respond GET "$FLAG_URL" 200 "$T_FLAG_ON"
t_respond PUT "$FLAG_URL" 200 '@request'
http GET "$FLAG_URL"
t_expect "GET" "$HTTP_STATUS|$HTTP_BODY" "200|$T_FLAG_ON"
http PUT "$FLAG_URL" '{"enabled": false}'
t_expect "PUT body through stdin" "$HTTP_STATUS|$HTTP_BODY" '200|{"enabled": false}'
http DELETE "$ALERTS_URL/$ID1"
t_expect "transport error" "$HTTP_STATUS|$HTTP_BODY|$(status_text)" \
    "000||transport error ($T_CURL_REFUSED)"
t_conclude "$check"

check="flagReply_bodies_normalizesTheFlagOrNamesTheFirstBrokenRule"
# LABEL;FILTER;RESULT: the body is T_FLAG_OFF after FILTER (t_flag_body). RESULT is
# "ENABLED MODIFIABLE" for an accepted flag, otherwise the fixed reason.
for row in 'flag off;.;false true' \
    'flag on since a time;.enabled = true | .enabledAt = "2026-01-01T00:00:00Z";true true' \
    'flag on since a time in nanoseconds;.enabled = true | .enabledAt = "2026-11-26T19:42:31.989559443Z";true true' \
    'flag on since a time with an offset;.enabled = true | .enabledAt = "2026-11-26T19:42:31+01:00";true true' \
    'flag locked;.isModifiable = false;false false' \
    'enabled quoted true;.enabled = "true";enabled is not a boolean' \
    'enabled quoted false;.enabled = "false";enabled is not a boolean' \
    'enabled null;.enabled = null;enabled is not a boolean' \
    'enabled missing;del(.enabled);enabled is not a boolean' \
    'another id;.id = "db_not_responding";id is not portfolio-insights-enabled' \
    'id a number;.id = 7;id is not a string' \
    'id missing;del(.id);id is not a string' \
    'isModifiable quoted;.isModifiable = "true";isModifiable is not a boolean' \
    'name missing;del(.name);name is not a string' \
    'description missing;del(.description);description is not a string' \
    'tag missing;del(.tag);tag is not a string' \
    'enabledAt a number;.enabledAt = 1767225600;enabledAt is not a string' \
    'enabledAt null;.enabledAt = null;enabledAt is not a string' \
    'enabledAt not a time;.enabledAt = "not-a-time";enabledAt is not an RFC 3339 time' \
    'enabledAt a date only;.enabledAt = "2026-11-26";enabledAt is not an RFC 3339 time' \
    'enabledAt a space for T;.enabledAt = "2026-11-26 19:42:31Z";enabledAt is not an RFC 3339 time' \
    'enabledAt ten fraction digits;.enabledAt = "2026-11-26T19:42:31.1234567890Z";enabledAt is not an RFC 3339 time' \
    'enabledAt a trailing newline;.enabledAt = "2026-11-26T19:42:31Z\n";enabledAt is not an RFC 3339 time' \
    'enabledAt empty;.enabledAt = "";enabledAt is not an RFC 3339 time' \
    'two JSON values;., .;not one JSON value' \
    'empty body;empty;not one JSON value' \
    'array of the flag;[.];not a JSON object' \
    'bare boolean;"true";not a JSON object' \
    'invalid JSON;"{\"id\":";not valid JSON' \
    'trailing text;tojson + " x";not valid JSON'; do
    IFS=';' read -r t_label t_filter t_result <<<"$row"
    t_body="$(t_flag_body "$t_filter")"
    set +e
    flag_reply "$t_body"
    status=$?
    set -e
    if [[ "$t_result" == "true "* || "$t_result" == "false "* ]]; then
        t_expect "$t_label" "$status|$FLAG_ENABLED $FLAG_MODIFIABLE|$FLAG_REASON" "0|$t_result|"
    else
        t_expect "$t_label" "$status|$FLAG_ENABLED$FLAG_MODIFIABLE|$FLAG_REASON" "1||$t_result"
    fi
done
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
# The second attempt leaves 5 s, one step: the poll ends there rather than sleep into its deadline
# and start an attempt with no time left.
t_expect "deadline expired" \
    "$status|$t_attempts|$(t_lines "$STUB_DIR/sleeps")|$(<"$T_CASE_DIR/poll.out")" \
    "1|2|5|FAIL readiness: deadline 10 s expired; attempt 2"
t_conclude "$check"

check="poll_attemptEndingAtOrAfterDeadline_failsAsLateSuccess"
t_poll_outcome 10 5 t_attempt_lasting 20 0
t_expect "success 10 s late" "$T_OUTCOME" \
    "1|1||FAIL readiness: attempt succeeded at or after the deadline of 10 s, 10 s late"
# Seen in the deadline's second, a success may have ended up to a second past TIMEOUT.
t_poll_outcome 10 5 t_attempt_lasting 10 0
t_expect "success at the deadline" "$T_OUTCOME" \
    "1|1||FAIL readiness: attempt succeeded at or after the deadline of 10 s"
t_conclude "$check"

check="poll_lastAttemptAfterSteps_acceptsSuccessOnlyBeforeDeadlineSecond"
# Three 3 s steps start the fourth attempt 9 s into a 10 s poll, the last second before the
# deadline. A success seen in that second counts. The same attempt taking one second more is
# seen in the deadline's second, as a last request capped at the one second left ends.
t_poll_outcome 10 3 t_succeed_lasting 4 0
t_expect "success one second before the deadline" "$T_OUTCOME" "0|4|3 3 3|"
t_poll_outcome 10 3 t_succeed_lasting 4 1
t_expect "success at the deadline second" "$T_OUTCOME" \
    "1|4|3 3 3|FAIL readiness: attempt succeeded at or after the deadline of 10 s"
t_conclude "$check"

check="poll_noTimeLeft_startsNoAttemptAndNoSleep"
t_poll_outcome 0 5 t_succeed_on 1
t_expect "deadline already reached" "$T_OUTCOME" "1|0||FAIL readiness: deadline 0 s expired"
t_poll_outcome 10 5 t_attempt_lasting 7 1
t_expect "failed attempt leaving less than a step" "$T_OUTCOME" \
    "1|1||FAIL readiness: deadline 10 s expired; attempt 1"
t_conclude "$check"

check="readinessOnce_timeLeft_capsEachRequestAndSendsNoneWithoutTime"
t_new_case
t_respond GET "$BASE_URL/broker-service/readyz" 200 'ok'
t_respond GET "$BASE_URL/feature-flag-service/readyz" 200 'ok'
T_BROKER_READYZ="GET $BASE_URL/broker-service/readyz"
T_READYZ_CALLS="$T_BROKER_READYZ GET $BASE_URL/feature-flag-service/readyz"
T_READYZ_200="broker-service readyz gave status 200, feature-flag-service readyz gave status 200"
T_NO_TIME="readyz not requested: no time left before the readiness deadline"
t_readiness_outcome
t_expect "outside a poll" "$T_OUTCOME" "0|15 15|$T_READYZ_CALLS|$T_READYZ_200"
PROBE_DEADLINE=$((FAKE_NOW + 300))
t_readiness_outcome
t_expect "300 s left" "$T_OUTCOME" "0|15 15|$T_READYZ_CALLS|$T_READYZ_200"
PROBE_DEADLINE=$((FAKE_NOW + 7))
t_readiness_outcome
t_expect "7 s left" "$T_OUTCOME" "0|7 7|$T_READYZ_CALLS|$T_READYZ_200"
t_run_sub t_readiness_ticking
t_expect "time runs out during the first request" "$T_STATUS|$(<"$T_CASE_DIR/out")" \
    "0|1|7|$T_BROKER_READYZ|broker-service readyz gave status 200, feature-flag-service $T_NO_TIME"
PROBE_DEADLINE="$FAKE_NOW"
t_readiness_outcome
t_expect "no time left" "$T_OUTCOME" "1|||broker-service $T_NO_TIME"
PROBE_DEADLINE=""
: >"$STUB_DIR/http.max-times"
set +e
poll "readiness" 7 5 readiness_once >"$T_CASE_DIR/poll.out"
status=$?
set -e
t_expect "through a 7 s poll" "$status|$(t_lines "$STUB_DIR/http.max-times")|$PROBE_DEADLINE" "0|7 7|"
t_new_case
t_respond GET "$BASE_URL/broker-service/readyz" 503 'unhealthy'
t_respond GET "$BASE_URL/feature-flag-service/readyz" 200 'ok'
t_readiness_outcome
t_expect "broker-service not ready" "$T_OUTCOME" \
    "1|15 15|$T_READYZ_CALLS|broker-service readyz gave status 503, feature-flag-service readyz gave status 200"
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
t_expect "ready stack: loadgen's twin created with its weight at start, then removed" \
    "$(t_print_file "$STUB_DIR/twin.env")|$(t_lock_presence "$STUB_DIR/twin.loadgen")|$(t_print_file "$STUB_DIR/up.env")" \
    "PORTFOLIO_INSIGHTS_ALERT_WEIGHT=0|absent|"
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
t_respond GET "$FLAG_URL" 200 "$(t_flag_body '.isModifiable = false')"
t_ready_stack
t_run_sub t_setup_facts
t_expect "flag locked" "$T_STATUS" 1
t_expect_line "flag locked: verdict" "$T_CASE_DIR/out" \
    "FAIL flag modifiable: isModifiable is [false]; a deployment with ENABLE_MODIFY=false cannot be toggled"
# LABEL;FILTER;RULE;PROBE: the flag read answers T_FLAG_OFF after FILTER; setup fails naming RULE,
# and no line of its output matches PROBE, a value only the reply holds.
for row in 'not the flag;{error: "feature_disabled"};id is not a string;feature_disabled' \
    'quoted enabled;.enabled = "true";enabled is not a boolean;\[true\]|"true"' \
    'another id;.id = "probe-7d1e";id is not portfolio-insights-enabled;probe-7d1e' \
    'quoted isModifiable;.isModifiable = "true";isModifiable is not a boolean;\[true\]|"true"'; do
    IFS=';' read -r t_label t_filter t_rule t_probe <<<"$row"
    t_new_case
    t_respond GET "$FLAG_URL" 200 "$(t_flag_body "$t_filter")"
    t_ready_stack
    t_run_sub t_setup_facts
    t_expect "$t_label" "$T_STATUS" 1
    t_expect_line "$t_label: verdict" "$T_CASE_DIR/out" \
        "FAIL flag modifiable: GET $FLAG_ID gave status 200 with a reply that is not the flag: $t_rule"
    t_expect_no_match "$t_label: reply not echoed" "$T_CASE_DIR/out" "$t_probe"
done
t_conclude "$check"

check="setFlag_responses_passesOnReadBackOrEndsRunWithFlagTouched"
t_new_case
t_respond PUT "$FLAG_URL" 200 '@flag'
t_respond GET "$FLAG_URL" 200 '@flag'
t_run_sub t_set_flag_touch "run B flag true" true
t_expect "read back" "$T_STATUS|$(<"$T_CASE_DIR/out")|$(<"$STUB_DIR/http.calls")" "0|PASS run B flag true
FLAG_TOUCHED=1|PUT $FLAG_URL {\"enabled\": true}
GET $FLAG_URL"
# LABEL;PUT_STATUS;PUT_FILTER;GET_FILTER;CALLS;REASON: the PUT answers PUT_STATUS with T_FLAG_OFF
# after PUT_FILTER, and the read-back, if any, T_FLAG_OFF after GET_FILTER, or a transport error
# for an empty GET_FILTER. set_flag makes CALLS requests and ends the run with REASON.
for row in 'PUT refused;500;{error: "internal"};.;1;PUT {"enabled": true} gave status 500' \
    'PUT gives the flag off;200;.;.enabled = true;1;PUT {"enabled": true} gave status 200 with enabled=false, expected true' \
    'PUT gives a quoted boolean;200;.enabled = "true";.enabled = true;1;PUT {"enabled": true} gave status 200 with a reply that is not the flag: enabled is not a boolean' \
    'read back differs;200;.enabled = true;.;2;read-back gave status 200 with enabled=false, expected true' \
    'read back quoted;200;.enabled = true;.enabled = "true";2;read-back gave status 200 with a reply that is not the flag: enabled is not a boolean' \
    'read back of another flag;200;.enabled = true;.enabled = true | .id = "db_not_responding";2;read-back gave status 200 with a reply that is not the flag: id is not portfolio-insights-enabled' \
    "read back unreachable;200;.enabled = true;;2;read-back gave transport error ($T_CURL_REFUSED)"; do
    IFS=';' read -r t_label t_put_status t_put_filter t_get_filter t_calls t_reason <<<"$row"
    t_new_case
    t_respond PUT "$FLAG_URL" "$t_put_status" "$(t_flag_body "$t_put_filter")"
    if [[ -n "$t_get_filter" ]]; then
        t_respond GET "$FLAG_URL" 200 "$(t_flag_body "$t_get_filter")"
    fi
    t_run_sub t_set_flag_touch "run B flag true" true
    t_expect "$t_label" "$T_STATUS|$(<"$T_CASE_DIR/out")|$(t_count "$STUB_DIR/http.calls")" \
        "1|FAIL run B flag true: $t_reason
FLAG_TOUCHED=1|$t_calls"
done
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
    t_respond PUT "$FLAG_URL" 200 '@flag'
    t_respond GET "$FLAG_URL" 200 '@flag'
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
t_expect "temporary file renamed" "$(compgen -G "$OUT_FILE.*" || true)" ""
printf -v t_mode '%o' $((0666 & ~$(umask)))
t_expect "mode of a plain redirection" "$(stat -c '%a' "$OUT_FILE")" "$t_mode"
t_new_case
OUT_FILE="$T_CASE_DIR/absent/table.md"
write_table >"$T_CASE_DIR/out" 2>"$T_CASE_DIR/err"
t_expect "directory missing" "$(<"$T_CASE_DIR/out")" \
    "FAIL table: could not write $OUT_FILE (see $RUN_DIR/table-error.log)"
t_conclude "$check"

# t_with_fault FAULT COMMAND [ARGS...]: COMMAND with FAULT injected, failing one call as an I/O
# error would. Run it in a subshell, so that only the subshell gets the stub. FAULT is one of:
#   none            nothing injected;
#   verdicts-read   awk fails reading the verdicts file;
#   errors-read     awk fails reading run A's error counts;
#   breakdown-read  cat fails reading run A's breakdown;
#   full-disk       COMMAND writes to /dev/full, where every write fails;
#   copy            cat, copying the generated rows into the report, writes run A's rows and then
#                   fails, as a write to a full disk does;
#   mode            chmod fails setting the report's mode;
#   rename          mv fails publishing the report, as in a read-only directory;
#   rename-remove   mv fails publishing the report, and rm then fails removing it.
t_with_fault() {
    local fault="$1"
    shift
    case "$fault" in
        verdicts-read | errors-read)
            T_FAULT_FILE="$RUN_DIR/verdicts"
            if [[ "$fault" == "errors-read" ]]; then
                T_FAULT_FILE="$RUN_DIR/errors-A"
            fi
            # shellcheck disable=SC2329 # Invoked by the command under test.
            awk() {
                if [[ "${*: -1}" == "$T_FAULT_FILE" ]]; then
                    echo "awk: read error (Input/output error)" >&2
                    return 2
                fi
                command awk "$@"
            }
            ;;
        breakdown-read)
            # shellcheck disable=SC2329 # Invoked by the command under test.
            cat() {
                if [[ "${1:-}" == "$RUN_DIR/breakdown-A.json" ]]; then
                    echo "cat: $1: Input/output error" >&2
                    return 1
                fi
                command cat "$@"
            }
            ;;
        full-disk)
            "$@" >/dev/full
            return
            ;;
        copy)
            # shellcheck disable=SC2329 # Invoked by the command under test.
            cat() {
                if [[ "${1:-}" == "$RUN_DIR/table-A.rows" ]]; then
                    command cat "$1"
                    echo "cat: write error: No space left on device" >&2
                    return 1
                fi
                command cat "$@"
            }
            ;;
        mode)
            # shellcheck disable=SC2329 # Invoked by the command under test.
            chmod() {
                echo "chmod: changing permissions: Operation not permitted" >&2
                return 1
            }
            ;;
        rename | rename-remove)
            # shellcheck disable=SC2329 # Invoked by the command under test.
            mv() {
                echo "mv: cannot move to the table: Permission denied" >&2
                return 1
            }
            if [[ "$fault" == "rename-remove" ]]; then
                # shellcheck disable=SC2329 # Invoked by the command under test.
                rm() {
                    echo "rm: cannot remove: Permission denied" >&2
                    return 1
                }
            fi
            ;;
    esac
    "$@"
}

# t_write_table_failed: write_table, then the failed count it leaves.
t_write_table_failed() {
    write_table
    echo "failed=$failed"
}

check="verdictOf_verdictsFile_printsNotCheckedOrFailsWhenUnreadable"
# ROW:VERDICTS:FAULT:STATUS:OUTPUT. A family without a verdict is "not checked"; a verdicts file
# that is missing, a directory, which awk would skip with status 0, or unreadable fails the
# lookup.
for row in "no verdict of the family:file:none:0:not checked" "verdicts missing:missing:none:1:" \
    "verdicts a directory:directory:none:1:" "verdicts unreadable:file:verdicts-read:1:"; do
    IFS=: read -r t_label t_verdicts t_fault t_status t_output <<<"$row"
    t_new_case
    record_verdict A long_sell PASS
    case "$t_verdicts" in
        missing) rm -f "$RUN_DIR/verdicts" ;;
        directory) rm -f "$RUN_DIR/verdicts" && mkdir "$RUN_DIR/verdicts" ;;
    esac
    t_run_sub t_with_fault "$t_fault" verdict_of A deposit_and_buy
    t_expect "$t_label" "$T_STATUS|$(<"$T_CASE_DIR/out")" "$t_status|$t_output"
done
t_conclude "$check"

check="tableRows_failedStep_failsWithoutRows"
# ROW;FAULT: each row fails one step of run A's rows: jq on a breakdown that does not parse or a
# total it cannot multiply, reading the breakdown, the error counts or the verdicts, and writing
# a row. Before, the jq rows printed every family as missing and returned 0.
for row in "breakdown does not parse;none" "total is null;none" "breakdown not read;breakdown-read" \
    "error counts not read;errors-read" "verdicts missing;none" "verdicts unreadable;verdicts-read" \
    "row not written;full-disk"; do
    IFS=';' read -r t_label t_fault <<<"$row"
    t_new_case
    printf '%s\n' "$RUN_A_JSON" >"$RUN_DIR/breakdown-A.json"
    case "$t_label" in
        "breakdown does not parse") printf '%s\n' '{"long_sell_error":' >"$RUN_DIR/breakdown-A.json" ;;
        "total is null")
            printf '%s\n' '{"long_sell_error":{"total":null,"avgDurationMs":1,"failRate":0}}' \
                >"$RUN_DIR/breakdown-A.json"
            ;;
        "error counts not read") echo "1 order_credit_card" >"$RUN_DIR/errors-A" ;;
        "verdicts missing") rm -f "$RUN_DIR/verdicts" ;;
    esac
    t_run_sub t_with_fault "$t_fault" table_rows A
    t_expect "$t_label" "$T_STATUS|$(<"$T_CASE_DIR/out")" "1|"
done
t_conclude "$check"

check="writeTable_failedStep_failsTableCheckAndLeavesOutFileAsItWas"
# ROW;BEFORE;FAULT;LOG: BEFORE is what OUT_FILE is when write_table starts (absent, an earlier
# table, or a directory holding one), and must still be after it; LOG is a line the step that
# failed leaves in table-error.log. Only a temporary file rm could not remove may stay beside
# OUT_FILE, and the verdict then names it.
for row in "rows not generated;absent;none;^jq: " \
    "verdict not read;file;none;^verdict_of: .* is not a regular file$" \
    "mode not set;absent;mode;^chmod: " \
    "write fails mid-table;absent;copy;^cat: write error" \
    "out file is a directory;directory;none;^mv: " \
    "rename refused;file;rename;^mv: cannot move" \
    "partial file not removed;file;rename-remove;^rm: cannot remove"; do
    IFS=';' read -r t_label t_before t_fault t_log <<<"$row"
    t_new_case
    printf '%s\n' "$RUN_A_JSON" >"$RUN_DIR/breakdown-A.json"
    case "$t_label" in
        "rows not generated") printf '%s\n' '{"long_sell_error":' >"$RUN_DIR/breakdown-B.json" ;;
        "verdict not read") rm -f "$RUN_DIR/verdicts" ;;
        "out file is a directory") OUT_FILE="$T_CASE_DIR/table.md" ;;
    esac
    case "$t_before" in
        file) echo "earlier table" >"$OUT_FILE" ;;
        directory) mkdir "$OUT_FILE" && echo "earlier table" >"$OUT_FILE/kept.md" ;;
    esac
    t_run_sub t_with_fault "$t_fault" t_write_table_failed
    t_left="$(compgen -G "$OUT_FILE.*" || true)"
    t_left_expected=""
    case "$t_label" in
        "rows not generated") t_reason="could not generate the rows of run B" ;;
        "verdict not read") t_reason="could not generate the rows of run A" ;;
        "mode not set" | "write fails mid-table") t_reason="could not write $OUT_FILE" ;;
        "out file is a directory" | "rename refused") t_reason="could not publish $OUT_FILE" ;;
        "partial file not removed")
            t_left_expected="$t_left"
            t_reason="could not publish $OUT_FILE; partial file $t_left not removed"
            t_expect "$t_label: one partial file" \
                "$([[ "$t_left" == "$OUT_FILE".* && "$t_left" != *$'\n'* ]] && echo one)" one
            ;;
    esac
    t_expect "$t_label: verdict" "$T_STATUS|$(<"$T_CASE_DIR/out")" \
        "0|FAIL table: $t_reason (see $RUN_DIR/table-error.log)
failed=1"
    if [[ -d "$OUT_FILE" ]]; then
        t_after="directory $(compgen -G "$OUT_FILE/*" || true) $(<"$OUT_FILE/kept.md")"
        t_expected="directory $OUT_FILE/kept.md earlier table"
    elif [[ -f "$OUT_FILE" ]]; then
        t_after="file $(<"$OUT_FILE")"
        t_expected="file earlier table"
    else
        t_after="absent"
        t_expected="absent"
    fi
    t_expect "$t_label: out file" "$t_after" "$t_expected"
    t_expect "$t_label: partial file" "$t_left" "$t_left_expected"
    t_expect_match "$t_label: error log" "$RUN_DIR/table-error.log" "$t_log"
done
t_conclude "$check"

check="finishRun_endOfRun_writesTableAndRestoresFlagOrEndsRun"
t_new_case
FLAG_INITIAL="true"
t_respond PUT "$FLAG_URL" 200 '@flag'
t_respond GET "$FLAG_URL" 200 '@flag'
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

# t_finish_through_cleanup: finish_run, ended through the script's EXIT trap as a run ends.
t_finish_through_cleanup() {
    trap cleanup EXIT
    finish_run
}

check="finishRun_tableNotGenerated_failsTableAndExitsOne"
t_new_case
FLAG_INITIAL="true"
printf '%s\n' '{"long_sell_error":' >"$RUN_DIR/breakdown-B.json"
t_respond PUT "$FLAG_URL" 200 '@flag'
t_respond GET "$FLAG_URL" 200 '@flag'
t_run_sub t_finish_through_cleanup
t_expect "exit status" "$T_STATUS" 1
t_expect_line "table verdict" "$T_CASE_DIR/out" \
    "FAIL table: could not generate the rows of run B (see $RUN_DIR/table-error.log)"
t_expect_line "flag still restored" "$T_CASE_DIR/out" "PASS flag restored"
t_expect_line "summary" "$T_CASE_DIR/out" "SUMMARY 2 passed, 1 failed"
t_expect "no table" "$([[ -e "$OUT_FILE" ]] && echo present || echo absent)" "absent"
t_conclude "$check"

# ---------------------------------------------------------------------------------------------
# Cleanup

# t_remaining_owned_with_wc OUTPUT STATUS: remaining_owned with a wc that prints OUTPUT and
# returns STATUS, as a full disk or a broken tool would leave it. Run it in a subshell, so that
# only the subshell gets the stub.
t_remaining_owned_with_wc() {
    local output="$1" status="$2"
    # shellcheck disable=SC2329 # Invoked by remaining_owned.
    wc() {
        printf '%s' "$output"
        return "$status"
    }
    remaining_owned
}

check="remainingOwned_ledgerSteps_printsCountOrFailsWithoutOne"
# ROW|STATUS|OUTPUT: the lists of the run directory, or the wc, of ROW, and the status and output
# of remaining_owned. A list it cannot read or write and a count it cannot take each fail it with
# no number, so an unread owned list never passes for an empty one.
for row in "nothing owned|0|0" "one deleted, one owned twice|0|1" "all deleted|0|0" \
    "owned list a directory|1|" "deleted list a directory|1|" "sorted owned list not writable|1|" \
    "sorted deleted list not writable|1|" "to-delete not writable|1|" "count fails|1|" \
    "count not a number|1|"; do
    IFS='|' read -r t_label t_status t_output <<<"$row"
    t_new_case
    case "$t_label" in
        "one deleted, one owned twice")
            printf '%s\n' "$ID2" "$ID1" "$ID2" >"$RUN_DIR/owned"
            printf '%s\n' "$ID1" >"$RUN_DIR/deleted"
            ;;
        "all deleted")
            printf '%s\n' "$ID1" >"$RUN_DIR/owned"
            printf '%s\n' "$ID1" >"$RUN_DIR/deleted"
            ;;
        "owned list a directory") rm -f "$RUN_DIR/owned" && mkdir "$RUN_DIR/owned" ;;
        "deleted list a directory") rm -f "$RUN_DIR/deleted" && mkdir "$RUN_DIR/deleted" ;;
        "sorted owned list not writable") mkdir "$RUN_DIR/owned.sorted" ;;
        "sorted deleted list not writable") mkdir "$RUN_DIR/deleted.sorted" ;;
        "to-delete not writable") mkdir "$RUN_DIR/to-delete" ;;
    esac
    case "$t_label" in
        "count fails") t_run_sub t_remaining_owned_with_wc "" 1 ;;
        "count not a number") t_run_sub t_remaining_owned_with_wc "lines: 1" 0 ;;
        *) t_run_sub remaining_owned ;;
    esac
    t_expect "$t_label: status and output" "$T_STATUS|$(<"$T_CASE_DIR/out")" "$t_status|$t_output"
    if [[ "$t_label" == "one deleted, one owned twice" ]]; then
        t_expect "$t_label: to-delete" "$(t_lines "$RUN_DIR/to-delete")" "$ID2"
    fi
done
t_conclude "$check"

check="deleteRemaining_statuses_deletes204And404AndLeavesOthers"
t_new_case
printf '%s\n' "$ID1" "$ID2" "$ID3" "$ID4" "$ID5" >"$RUN_DIR/to-delete"
t_respond DELETE "$ALERTS_URL/$ID1" 204
t_respond DELETE "$ALERTS_URL/$ID2" 404 '{"error":"not_found"}'
t_respond DELETE "$ALERTS_URL/$ID3" 500 '{"error":"internal"}'
t_respond DELETE "$ALERTS_URL/$ID5" 403 '{"error":"feature_disabled"}'
delete_remaining 5 >"$T_CASE_DIR/out"
t_expect "deleted and left" "$(t_lines "$RUN_DIR/deleted")|$CLEANUP_LEFT" "$ID1 $ID2|3"
t_expect "left lines" "$(<"$T_CASE_DIR/out")" "INFO cleanup left alert $ID3: status 500
INFO cleanup left alert $ID4: transport error ($T_CURL_REFUSED)
INFO cleanup left alert $ID5: status 403"
t_conclude "$check"

check="deleteRemaining_consecutiveTransportErrors_stopsAttemptingAtLimit"
# Each id that meets only transport errors gets three attempts two seconds apart, so five such
# ids make 15 requests and 10 waits.
t_new_case
t_ids 1 7 >"$RUN_DIR/to-delete"
delete_remaining 7 >"$T_CASE_DIR/out"
t_expect "seven transport errors" "$(t_count "$STUB_DIR/http.calls")|$CLEANUP_LEFT" "15|7"
t_expect "waits" "$(t_lines "$STUB_DIR/sleeps")" "2 2 2 2 2 2 2 2 2 2"
for t_n in 6 7; do
    printf -v t_line 'INFO cleanup left alert %08x-0000-4000-8000-%012x: not attempted after 5 transport errors in a row' \
        "$t_n" "$t_n"
    t_expect_line "alert $t_n not attempted" "$T_CASE_DIR/out" "$t_line"
done
t_new_case
t_ids 1 14 >"$RUN_DIR/to-delete"
t_respond DELETE "$ALERTS_URL/$ID5" 204
t_respond DELETE "$ALERTS_URL/$(t_ids 10 10)" 500 '{"error":"internal"}'
delete_remaining 14 >"$T_CASE_DIR/out"
t_expect "four errors, a 204, four errors, a 500, four errors" \
    "$(t_count "$STUB_DIR/http.calls")|$CLEANUP_LEFT" "38|13"
t_conclude "$check"

check="deleteRemaining_transportErrorThenAnswer_retriesUntilAnsweredWithinAttempts"
# ROW:ERRORS:STATUS:CALLS:WAITS:LEFT: ERRORS transport errors come before the answer STATUS. A
# transport error is retried two seconds later, up to three attempts; any answer is final.
for row in "one error then 204:1:204:2:2:0" "two errors then 404:2:404:3:2 2:0" \
    "one error then 500:1:500:2:2:1" "500 at once:0:500:1::1" "errors on every attempt:3:204:3:2 2:1"; do
    IFS=: read -r t_label t_errors t_status t_calls t_waits t_left <<<"$row"
    t_new_case
    printf '%s\n' "$ID1" >"$RUN_DIR/to-delete"
    t_respond_transient DELETE "$ALERTS_URL/$ID1" "$t_errors"
    t_respond DELETE "$ALERTS_URL/$ID1" "$t_status" '{}'
    delete_remaining 1 >"$T_CASE_DIR/out"
    t_expect "$t_label: requests, waits, left" \
        "$(t_count "$STUB_DIR/http.calls")|$(t_lines "$STUB_DIR/sleeps")|$CLEANUP_LEFT" \
        "$t_calls|$t_waits|$t_left"
    case "$t_label" in
        "one error then 500" | "500 at once") t_expected="INFO cleanup left alert $ID1: status 500" ;;
        "errors on every attempt") t_expected="INFO cleanup left alert $ID1: transport error ($T_CURL_REFUSED)" ;;
        *) t_expected="" ;;
    esac
    t_expect "$t_label: output" "$(<"$T_CASE_DIR/out")" "$t_expected"
    if [[ "$t_left" == "0" ]]; then
        t_expect "$t_label: deleted" "$(t_lines "$RUN_DIR/deleted")" "$ID1"
    else
        t_expect "$t_label: deleted" "$(t_lines "$RUN_DIR/deleted")" ""
    fi
done
t_conclude "$check"

check="deleteRemaining_nonCanonicalLines_refusesThemWithoutRequest"
# Only an edited run directory can hold such lines; none may reach a URL.
t_new_case
printf '%s\n' "$ID1" "$T_DASHES" "../../feature-flag-service/v1/flags/$FLAG_ID" \
    "ABCDEF01-0000-4000-8000-000000000001" "" "$ID2" >"$RUN_DIR/to-delete"
t_respond DELETE "$ALERTS_URL/$ID1" 204
t_respond DELETE "$ALERTS_URL/$ID2" 404 '{"error":"not_found"}'
delete_remaining 6 >"$T_CASE_DIR/out"
t_expect "requests" "$(<"$STUB_DIR/http.calls")" "DELETE $ALERTS_URL/$ID1
DELETE $ALERTS_URL/$ID2"
t_expect "deleted, left, refused" "$(t_lines "$RUN_DIR/deleted")|$CLEANUP_LEFT|$CLEANUP_REFUSED" \
    "$ID1 $ID2|4|4"
for t_n in 2 3 4 5; do
    t_expect_line "line $t_n refused" "$T_CASE_DIR/out" \
        "INFO cleanup refused line $t_n of $RUN_DIR/to-delete: not a canonical alert id, never sent"
done
t_conclude "$check"

check="deleteRemaining_receiptNotRecorded_countsGoneIdAsLeft"
# The deleted list takes no line, here because it is a directory: an id a 204 or a 404 shows gone
# still counts as left, so the check fails and a resume sends its DELETE again.
t_new_case
rm -f "$RUN_DIR/deleted"
mkdir "$RUN_DIR/deleted"
printf '%s\n' "$ID1" "$ID2" >"$RUN_DIR/to-delete"
t_respond DELETE "$ALERTS_URL/$ID1" 204
t_respond DELETE "$ALERTS_URL/$ID2" 404 '{"error":"not_found"}'
delete_remaining 2 >"$T_CASE_DIR/out" 2>"$T_CASE_DIR/err"
t_expect "requests and left" "$(t_count "$STUB_DIR/http.calls")|$CLEANUP_LEFT|$CLEANUP_REFUSED" "2|2|0"
t_expect "left lines" "$(<"$T_CASE_DIR/out")" "INFO cleanup left alert $ID1: gone (status 204), but $RUN_DIR/deleted could not record it; a resume DELETEs it again
INFO cleanup left alert $ID2: gone (status 404), but $RUN_DIR/deleted could not record it; a resume DELETEs it again"
t_conclude "$check"

check="deleteRemaining_toDeleteNotReadToItsEnd_countsUnreadIdsAsLeft"
# ROW|REQUESTS|READ: remaining_owned counted 3 ids, but the read of to-delete fails at once, here
# because it is a directory, or ends after READ lines; every id it never reached counts as left.
for row in "to-delete unreadable|0|0" "to-delete ends after one id|1|1"; do
    IFS='|' read -r t_label t_calls t_read <<<"$row"
    t_new_case
    case "$t_label" in
        "to-delete unreadable") mkdir "$RUN_DIR/to-delete" ;;
        *) printf '%s\n' "$ID1" >"$RUN_DIR/to-delete" ;;
    esac
    t_respond DELETE "$ALERTS_URL/$ID1" 204
    delete_remaining 3 >"$T_CASE_DIR/out" 2>"$T_CASE_DIR/err"
    t_expect "$t_label: requests and left" "$(t_count "$STUB_DIR/http.calls")|$CLEANUP_LEFT" \
        "$t_calls|$((3 - t_read))"
    t_expect_line "$t_label: left line" "$T_CASE_DIR/out" \
        "INFO cleanup left $((3 - t_read)) owned alerts: $RUN_DIR/to-delete could not be read past line $t_read"
done
t_conclude "$check"

check="cleanup_flagOffWithOwnedAlerts_enablesFlagToDeleteThenRestoresIt"
t_new_case
FLAG_INITIAL="false"
printf '%s\n' "$ID1" >"$RUN_DIR/owned"
t_respond GET "$FLAG_URL" 200 '@flag'
t_respond PUT "$FLAG_URL" 200 '@flag'
t_respond DELETE "$ALERTS_URL/$ID1" 204
t_run_sub t_exit_through_cleanup 0
t_expect "requests" "$(<"$STUB_DIR/http.calls")" "GET $FLAG_URL
PUT $FLAG_URL {\"enabled\": true}
GET $FLAG_URL
DELETE $ALERTS_URL/$ID1
PUT $FLAG_URL {\"enabled\": false}
GET $FLAG_URL"
t_expect "exit status" "$T_STATUS" 0
t_expect_line "switched on" "$T_CASE_DIR/out" \
    "INFO cleanup: flag $FLAG_ID switched on to delete 1 owned alerts (status 200)"
t_expect_line "restored" "$T_CASE_DIR/out" "INFO cleanup: flag $FLAG_ID restored to enabled=false"
t_expect_line "cleanup verdict" "$T_CASE_DIR/out" "PASS cleanup"
t_conclude "$check"

check="cleanup_preDeleteFlagReplies_switchesFlagOnOnlyWhenTheFlagReadsOff"
# LABEL;GET_FILTER;PUT_FILTER;STATUS;METHODS;LINE: with one owned alert, the flag read answers
# T_FLAG_OFF after GET_FILTER and every PUT T_FLAG_OFF after PUT_FILTER. Cleanup exits STATUS
# after requests of METHODS in order, and reports INFO "cleanup: flag portfolio-insights-enabled
# LINE".
for row in 'quoted enabled;.enabled = "false";.;0;GET DELETE;not read before deleting 1 owned alerts: GET portfolio-insights-enabled gave status 200 with a reply that is not the flag: enabled is not a boolean' \
    'another flag;.id = "db_not_responding";.;0;GET DELETE;not read before deleting 1 owned alerts: GET portfolio-insights-enabled gave status 200 with a reply that is not the flag: id is not portfolio-insights-enabled' \
    'switch answered with a quoted boolean;.;.enabled = "true";1;GET PUT DELETE PUT;not confirmed switched on to delete 1 owned alerts: PUT {"enabled": true} gave status 200 with a reply that is not the flag: enabled is not a boolean'; do
    IFS=';' read -r t_label t_get_filter t_put_filter t_expected t_methods t_line <<<"$row"
    t_new_case
    FLAG_INITIAL="false"
    printf '%s\n' "$ID1" >"$RUN_DIR/owned"
    t_respond GET "$FLAG_URL" 200 "$(t_flag_body "$t_get_filter")"
    t_respond PUT "$FLAG_URL" 200 "$(t_flag_body "$t_put_filter")"
    t_respond DELETE "$ALERTS_URL/$ID1" 204
    t_run_sub t_exit_through_cleanup 0
    mapfile -t t_requests <"$STUB_DIR/http.calls"
    t_expect "$t_label" "$T_STATUS|${t_requests[*]%% *}" "$t_expected|$t_methods"
    t_expect_line "$t_label: flag line" "$T_CASE_DIR/out" "INFO cleanup: flag $FLAG_ID $t_line"
done
t_conclude "$check"

check="cleanup_flagRestore_restoresOnlyWhenPutAndReadBackGiveInitialValue"
# LABEL;PUT_STATUS;PUT_FILTER;GET_FILTER;REASON: the restore PUT answers PUT_STATUS with T_FLAG_OFF
# after PUT_FILTER, 000 being a transport error, and the read-back T_FLAG_OFF after GET_FILTER, or a
# transport error for an empty GET_FILTER. An empty REASON is a restore; any other fails cleanup.
for row in 'restored;200;.;.;' \
    'PUT refused;500;{error: "internal"};.;PUT {"enabled": false} gave status 500' \
    "flag service unreachable;000;.;;PUT {\"enabled\": false} gave transport error ($T_CURL_REFUSED)" \
    'PUT gives the flag on;200;.enabled = true;.;PUT {"enabled": false} gave status 200 with enabled=true, expected false' \
    'PUT gives a quoted boolean;200;.enabled = "false";.;PUT {"enabled": false} gave status 200 with a reply that is not the flag: enabled is not a boolean' \
    'read back differs;200;.;.enabled = true;read-back gave status 200 with enabled=true, expected false' \
    'read back quoted;200;.;.enabled = "false";read-back gave status 200 with a reply that is not the flag: enabled is not a boolean' \
    'read back of another flag;200;.;.id = "db_not_responding";read-back gave status 200 with a reply that is not the flag: id is not portfolio-insights-enabled' \
    "read back unreachable;200;.;;read-back gave transport error ($T_CURL_REFUSED)"; do
    IFS=';' read -r t_label t_put_status t_put_filter t_get_filter t_reason <<<"$row"
    t_new_case
    FLAG_TOUCHED=1
    FLAG_INITIAL="false"
    t_respond PUT "$FLAG_URL" "$t_put_status" "$(t_flag_body "$t_put_filter")"
    if [[ -n "$t_get_filter" ]]; then
        t_respond GET "$FLAG_URL" 200 "$(t_flag_body "$t_get_filter")"
    fi
    t_run_sub t_exit_through_cleanup 0
    if [[ -z "$t_reason" ]]; then
        t_expect "$t_label: exit status" "$T_STATUS" 0
        t_expect_line "$t_label: flag line" "$T_CASE_DIR/out" "INFO cleanup: flag $FLAG_ID restored to enabled=false"
        t_expect_line "$t_label: verdict" "$T_CASE_DIR/out" "PASS cleanup"
    else
        t_expect "$t_label: exit status" "$T_STATUS" 1
        t_expect_line "$t_label: verdict" "$T_CASE_DIR/out" \
            "FAIL cleanup: flag $FLAG_ID not restored to enabled=false: $t_reason"
        t_expect_no_match "$t_label: no restored line" "$T_CASE_DIR/out" '^INFO cleanup: flag .* restored to '
    fi
done
t_conclude "$check"

check="cleanup_failures_failsCleanupAndExitsOne"
t_new_case
FLAG_INITIAL="true"
printf '%s\n' "$ID1" "$ID2" >"$RUN_DIR/owned"
t_respond GET "$FLAG_URL" 200 "$T_FLAG_ON"
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

check="cleanup_ownedListUnreadable_failsWithoutDeletingAndRestoresFlagAndLoadgen"
# The owned list is a directory, so which owned alerts are left is unknown: no flag switch and no
# DELETE, the check fails and prints the resume command, and the flag and loadgen are restored.
t_new_case
rm -f "$RUN_DIR/owned"
mkdir "$RUN_DIR/owned"
FLAG_TOUCHED=1
FLAG_INITIAL="false"
t_respond PUT "$FLAG_URL" 200 '@flag'
t_respond GET "$FLAG_URL" 200 '@flag'
LOADGEN_TOUCHED=1
TABLE_WRITTEN=1
LOADGEN_WAS_RUNNING=1
LOADGEN_AT_START="running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=0"
echo loadgen >"$STUB_DIR/running"
# loadgen's container at start, with the image ID, config hash and effective configuration that
# check_loadgen_restorable records for restore_loadgen to verify.
printf '%s\n' "PATH=/usr/local/bin" "PORTFOLIO_INSIGHTS_ALERT_WEIGHT=0" >"$STUB_DIR/env.loadgen"
t_identity=""
if ! t_identity="$(loadgen_identity "$RUN_DIR/loadgen-at-start.config.json")" || [[ -z "$t_identity" ]]; then
    t_reasons+=("loadgen at start: loadgen_identity read no container")
fi
IFS=$'\t' read -r LOADGEN_IMAGE_AT_START LOADGEN_HASH_AT_START _ <<<"$t_identity"
LOADGEN_CONFIG_AT_START="$RUN_DIR/loadgen-at-start.config.json"
t_run_sub t_exit_through_cleanup 0
t_expect "exit status and requests" "$T_STATUS|$(<"$STUB_DIR/http.calls")" \
    "1|PUT $FLAG_URL {\"enabled\": false}
GET $FLAG_URL"
t_expect_line "verdict" "$T_CASE_DIR/out" \
    "FAIL cleanup: owned-alert lists of the run dir could not be read or written, owned alerts not deleted"
t_expect_line "flag restored" "$T_CASE_DIR/out" "INFO cleanup: flag $FLAG_ID restored to enabled=false"
t_expect "loadgen recreated" "$(t_lines "$STUB_DIR/up.env")" "PORTFOLIO_INSIGHTS_ALERT_WEIGHT=0"
t_expect_line "loadgen restored" "$T_CASE_DIR/out" \
    "INFO cleanup: loadgen restored as at start: running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=0, image ID 0123456789ab, config hash fedcba987654, effective configuration verified as recorded at start"
printf -v t_line '%s --resume-cleanup %q' \
    "INFO cleanup: to delete the owned alerts left, and only those, run: scripts/portfolio-insights/loadgen-check.sh --project et-test --base-url http://stub.invalid --compose-file compose.dev.yaml" \
    "$RUN_DIR"
t_expect_line "resume command" "$T_CASE_DIR/out" "$t_line"
t_expect_line "summary" "$T_CASE_DIR/out" "SUMMARY 0 passed, 1 failed"
t_conclude "$check"

check="cleanup_receiptNotRecorded_failsWithIdLeftAndRestoresFlag"
# The DELETE answers 204, but the read-only deleted list cannot record it: the id counts as left,
# the check fails and prints the resume command, and the flag is still restored.
t_new_case
FLAG_INITIAL="false"
printf '%s\n' "$ID1" >"$RUN_DIR/owned"
t_respond GET "$FLAG_URL" 200 '@flag'
t_respond PUT "$FLAG_URL" 200 '@flag'
t_respond DELETE "$ALERTS_URL/$ID1" 204
chmod a-w "$RUN_DIR/deleted"
# A user who can write a read-only file, as root can, cannot set up this case.
if [[ -w "$RUN_DIR/deleted" ]]; then
    t_reasons+=("chmod a-w left $RUN_DIR/deleted writable")
fi
t_run_sub t_exit_through_cleanup 0
chmod u+w "$RUN_DIR/deleted"
t_expect "exit status and requests" "$T_STATUS|$(<"$STUB_DIR/http.calls")" "1|GET $FLAG_URL
PUT $FLAG_URL {\"enabled\": true}
GET $FLAG_URL
DELETE $ALERTS_URL/$ID1
PUT $FLAG_URL {\"enabled\": false}
GET $FLAG_URL"
t_expect "deleted list" "$(t_count "$RUN_DIR/deleted")" 0
t_expect_line "id left" "$T_CASE_DIR/out" \
    "INFO cleanup left alert $ID1: gone (status 204), but $RUN_DIR/deleted could not record it; a resume DELETEs it again"
t_expect_line "count" "$T_CASE_DIR/out" "INFO cleanup: 0 of 1 owned alerts deleted or already absent"
t_expect_line "flag restored" "$T_CASE_DIR/out" "INFO cleanup: flag $FLAG_ID restored to enabled=false"
printf -v t_line '%s --resume-cleanup %q' \
    "INFO cleanup: to delete the owned alerts left, and only those, run: scripts/portfolio-insights/loadgen-check.sh --project et-test --base-url http://stub.invalid --compose-file compose.dev.yaml" \
    "$RUN_DIR"
t_expect_line "resume command" "$T_CASE_DIR/out" "$t_line"
t_expect_line "verdict" "$T_CASE_DIR/out" "FAIL cleanup: 1 owned alerts left in place"
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

# ---------------------------------------------------------------------------------------------
# Recovery record and --resume-cleanup

# t_main_in DIR ARGS...: main ARGS with TMPDIR set to DIR, where main creates its run directory.
t_main_in() {
    TMPDIR="$1"
    shift
    main "$@"
}

# t_main_in_without_jq DIR ARGS...: t_main_in DIR ARGS with a jq that fails, as on a full disk.
# Run it in a subshell, so that only the subshell gets the stub.
t_main_in_without_jq() {
    # shellcheck disable=SC2329 # Invoked by write_recovery_record.
    jq() {
        echo "jq: error: No space left on device" >&2
        return 2
    }
    t_main_in "$@"
}

check="main_newRun_writesRecoveryRecordOrExitsTwo"
t_new_case
mkdir -p "$T_CASE_DIR/tmp"
: >"$T_CASE_DIR/compose.yaml"
t_run_sub t_main_in "$T_CASE_DIR/tmp" --project et-test --base-url http://stub.invalid/ \
    --compose-file "$T_CASE_DIR/compose.yaml"
t_run_dirs=("$T_CASE_DIR"/tmp/pi-loadgen.*)
t_expect "run directories" "${#t_run_dirs[@]}" 1
t_expect "record" "$(jq -c . "${t_run_dirs[0]}/recovery" 2>&1 | tr -d '\r')" \
    "{\"project\":\"et-test\",\"baseUrl\":\"http://stub.invalid\",\"composeFiles\":[\"$T_CASE_DIR/compose.yaml\"]}"
t_expect "owned and deleted lists" \
    "$(t_count "${t_run_dirs[0]}/owned") $(t_count "${t_run_dirs[0]}/deleted")" "0 0"
t_new_case
mkdir -p "$T_CASE_DIR/tmp"
: >"$T_CASE_DIR/compose.yaml"
t_run_sub t_main_in_without_jq "$T_CASE_DIR/tmp" --project et-test --base-url http://stub.invalid \
    --compose-file "$T_CASE_DIR/compose.yaml"
t_expect "record not written: exit status and requests" "$T_STATUS|$(<"$STUB_DIR/http.calls")" "2|"
t_expect_match "record not written: message" "$T_CASE_DIR/err" \
    '^Could not write the recovery record .*/pi-loadgen\.[^/]+/recovery\.$'
t_conclude "$check"

# The base URL of the resume cases: the reverse proxy of project et-test publishes its port 80
# there, on every address, as docker compose port prints it.
T_RESUME_BASE="http://localhost:20480"
T_RESUME_PUBLISHED="0.0.0.0:20480"

# t_resumable_run_dir [BASE [PUBLISHED]]: the case's run directory as a run of project et-test
# against BASE (default T_RESUME_BASE) leaves it when its cleanup deleted ID1 of the owned ID1,
# ID2 and ID3; BASE_URL, FLAG_URL and ALERTS_URL as main derives them from BASE; and the stub
# answers of that project's stack, whose running reverse-proxy has its port 80 published at
# PUBLISHED (default T_RESUME_PUBLISHED).
t_resumable_run_dir() {
    BASE_URL="${1:-$T_RESUME_BASE}"
    FLAG_URL="$BASE_URL/feature-flag-service/v1/flags/$FLAG_ID"
    ALERTS_URL="$BASE_URL/broker-service/v1/alerts"
    : >"$T_CASE_DIR/compose.yaml"
    COMPOSE_FILES=("$T_CASE_DIR/compose.yaml")
    write_recovery_record
    printf '%s\n' "$ID3" "$ID1" "$ID2" "$ID1" >"$RUN_DIR/owned"
    printf '%s\n' "$ID1" >"$RUN_DIR/deleted"
    printf '%s\n' broker-service db db-adapter feature-flag-service reverse-proxy >"$STUB_DIR/running"
    printf '%s\n' "${2:-$T_RESUME_PUBLISHED}" >"$STUB_DIR/port.reverse-proxy"
}

# t_resume ARGS...: main ARGS --resume-cleanup RUN_DIR, with the case's compose file.
t_resume() {
    main --compose-file "$T_CASE_DIR/compose.yaml" "$@" --resume-cleanup "$RUN_DIR"
}

check="main_resumeCleanupRefused_exitsTwoBeforeAnyRequest"
for row in "another project" "another base URL" "no record" "record not JSON" "two records" \
    "record field mistyped" "owned list missing" "deleted list missing" "deleted list read-only"; do
    t_new_case
    t_resumable_run_dir
    t_project="et-test"
    t_base="$T_RESUME_BASE"
    t_reason="its recovery record is not one this script writes"
    case "$row" in
        "another project")
            t_project="et-other"
            t_reason="its run was against another Compose project than --project"
            ;;
        "another base URL")
            t_base="http://other.invalid"
            t_reason="its run was against another base URL than --base-url"
            ;;
        "no record")
            rm -f "$RUN_DIR/recovery"
            t_reason="it holds no readable recovery record"
            ;;
        "record not JSON") echo "project=et-test" >"$RUN_DIR/recovery" ;;
        "two records")
            cat "$RUN_DIR/recovery" "$RUN_DIR/recovery" >"$RUN_DIR/recovery.twice"
            mv "$RUN_DIR/recovery.twice" "$RUN_DIR/recovery"
            ;;
        "record field mistyped")
            printf '%s\n' '{"project":"et-test","baseUrl":"http://stub.invalid","composeFiles":[1]}' \
                >"$RUN_DIR/recovery"
            ;;
        "owned list missing")
            rm -f "$RUN_DIR/owned"
            t_reason="its owned list is missing or unreadable"
            ;;
        "deleted list missing")
            rm -f "$RUN_DIR/deleted"
            t_reason="its deleted list is missing or unreadable"
            ;;
        "deleted list read-only")
            chmod a-w "$RUN_DIR/deleted"
            t_reason="it is not writable, so no deletion could be recorded"
            # A user who can write a read-only file, as root can, cannot set up this row.
            if [[ -w "$RUN_DIR/deleted" ]]; then
                t_reasons+=("$row: chmod a-w left $RUN_DIR/deleted writable")
            fi
            ;;
    esac
    t_run_sub t_resume --project "$t_project" --base-url "$t_base"
    t_expect "$row" "$T_STATUS|$(<"$T_CASE_DIR/err")|$(<"$STUB_DIR/http.calls")" \
        "2|Cannot resume the cleanup of $RUN_DIR: $t_reason.|"
    if [[ -f "$RUN_DIR/deleted" ]]; then
        chmod u+w "$RUN_DIR/deleted"
    fi
done
t_conclude "$check"

check="main_resumeCleanup_deletesOnlyOwnedIdsNotDeletedAndRestoresFlag"
t_new_case
t_resumable_run_dir
echo "earlier verdict" >"$RUN_DIR/verdicts"
t_respond GET "$FLAG_URL" 200 '@flag'
t_respond PUT "$FLAG_URL" 200 '@flag'
t_respond DELETE "$ALERTS_URL/$ID2" 204
t_respond DELETE "$ALERTS_URL/$ID3" 404 '{"error":"not_found"}'
# A trailing slash on --base-url is the origin the record holds.
t_run_sub t_resume --project et-test --base-url "$T_RESUME_BASE/"
t_expect "exit status" "$T_STATUS" 0
t_expect "requests" "$(<"$STUB_DIR/http.calls")" "GET $FLAG_URL
GET $FLAG_URL
PUT $FLAG_URL {\"enabled\": true}
GET $FLAG_URL
DELETE $ALERTS_URL/$ID2
DELETE $ALERTS_URL/$ID3
PUT $FLAG_URL {\"enabled\": false}
GET $FLAG_URL"
t_expect_line "flag read" "$T_CASE_DIR/out" "PASS resume flag: enabled=false"
t_expect_line "ids left" "$T_CASE_DIR/out" \
    "INFO resume: 2 owned alerts of this run directory are not deleted yet"
t_expect_line "ids deleted" "$T_CASE_DIR/out" "INFO cleanup: 2 of 2 owned alerts deleted or already absent"
t_expect_line "flag restored" "$T_CASE_DIR/out" "INFO cleanup: flag $FLAG_ID restored to enabled=false"
t_expect_line "cleanup verdict" "$T_CASE_DIR/out" "PASS cleanup"
t_expect_line "summary" "$T_CASE_DIR/out" "SUMMARY 3 passed, 0 failed"
t_expect "deleted list" "$(t_lines "$RUN_DIR/deleted")" "$ID1 $ID2 $ID3"
# Besides check_tools's docker compose version, the only Docker calls are the two reads that bind
# --base-url to the project: no loadgen or database call.
t_calls="$(<"$STUB_DIR/docker.calls")"
t_expect "docker calls: the origin's two reads alone" "${t_calls#*$'\n'version$'\n'--$'\n'}" "MSYS_NO_PATHCONV=1
compose
-p
et-test
-f
$T_CASE_DIR/compose.yaml
ps
--status
running
--services
--
MSYS_NO_PATHCONV=1
compose
-p
et-test
-f
$T_CASE_DIR/compose.yaml
port
reverse-proxy
80
--"
t_expect_line "origin bound" "$T_CASE_DIR/out" \
    "INFO resume: --base-url reaches reverse-proxy of project [et-test], port 80 published at $T_RESUME_PUBLISHED"
t_expect "earlier evidence" \
    "$(<"$RUN_DIR/verdicts")|$([[ -e "$RUN_DIR/loadgen-families.md" ]] && echo table || echo no table)" \
    "earlier verdict|no table"
# A second resume goes on from the deleted list: nothing is left, so it only reads the flag.
: >"$STUB_DIR/http.calls"
t_run_sub t_resume --project et-test --base-url "$T_RESUME_BASE"
t_expect "second resume: exit status and requests" "$T_STATUS|$(<"$STUB_DIR/http.calls")" \
    "0|GET $FLAG_URL"
t_expect_line "second resume: ids left" "$T_CASE_DIR/out" \
    "INFO resume: 0 owned alerts of this run directory are not deleted yet"
t_expect_line "second resume: cleanup verdict" "$T_CASE_DIR/out" "PASS cleanup"
t_conclude "$check"

check="main_resumeCleanupFlagUnreadable_exitsOneWithoutDeleting"
# ROW|ANSWER|REASON: the flag read's status and body, a 200 body being T_FLAG_OFF with one rule
# broken (t_flag_body), and the reason the check gives.
for row in "flag service fails|500 {\"error\":\"internal\"}|GET $FLAG_ID gave status 500" \
    "enabled a string|200 $(t_flag_body '.enabled = "false"')|GET $FLAG_ID gave status 200 with a reply that is not the flag: enabled is not a boolean" \
    "another flag|200 $(t_flag_body '.id = "other"')|GET $FLAG_ID gave status 200 with a reply that is not the flag: id is not $FLAG_ID"; do
    IFS='|' read -r t_label t_answer t_reason <<<"$row"
    t_new_case
    t_resumable_run_dir
    t_respond GET "$FLAG_URL" "${t_answer%% *}" "${t_answer#* }"
    t_respond DELETE "$ALERTS_URL/$ID2" 204
    t_run_sub t_resume --project et-test --base-url "$T_RESUME_BASE"
    t_expect "$t_label: exit status and requests" "$T_STATUS|$(<"$STUB_DIR/http.calls")" "1|GET $FLAG_URL"
    t_expect_line "$t_label: verdict" "$T_CASE_DIR/out" "FAIL resume flag: $t_reason; nothing was deleted"
    t_expect_line "$t_label: summary" "$T_CASE_DIR/out" "SUMMARY 1 passed, 1 failed"
    t_expect "$t_label: deleted list" "$(t_lines "$RUN_DIR/deleted")" "$ID1"
done
t_conclude "$check"

check="main_resumeCleanupLedgerUnwritable_printsNoCountAndFailsCleanup"
# The sorted owned list cannot be written, here because it is a directory, so remaining_owned
# fails: the resume prints no count of the ids left, and cleanup deletes none, switches no flag
# and fails on the lists, printing the resume command again.
t_new_case
t_resumable_run_dir
mkdir "$RUN_DIR/owned.sorted"
t_respond GET "$FLAG_URL" 200 '@flag'
t_respond PUT "$FLAG_URL" 200 '@flag'
t_respond DELETE "$ALERTS_URL/$ID2" 204
t_respond DELETE "$ALERTS_URL/$ID3" 204
t_run_sub t_resume --project et-test --base-url "$T_RESUME_BASE"
t_expect "exit status and requests" "$T_STATUS|$(<"$STUB_DIR/http.calls")" "1|GET $FLAG_URL"
t_expect_line "flag read" "$T_CASE_DIR/out" "PASS resume flag: enabled=false"
t_expect_no_match "no count of the ids left" "$T_CASE_DIR/out" '^INFO resume: .*owned alerts'
t_expect_line "cleanup verdict" "$T_CASE_DIR/out" \
    "FAIL cleanup: owned-alert lists of the run dir could not be read or written, owned alerts not deleted"
printf -v t_line 'INFO cleanup: to delete the owned alerts left, and only those, run: %s --project %q --base-url %q --compose-file %q --resume-cleanup %q' \
    scripts/portfolio-insights/loadgen-check.sh et-test "$T_RESUME_BASE" "$T_CASE_DIR/compose.yaml" \
    "$RUN_DIR"
t_expect_line "resume command" "$T_CASE_DIR/out" "$t_line"
t_expect_line "summary" "$T_CASE_DIR/out" "SUMMARY 2 passed, 1 failed"
t_expect "deleted list" "$(t_lines "$RUN_DIR/deleted")" "$ID1"
t_conclude "$check"

check="main_resumeCleanupOriginServedByProject_proceeds"
# ROW|BASE|PUBLISHED: --base-url, and where the project's reverse-proxy has its port 80 published
# as docker compose port prints it, IPv6 hosts unbracketed.
for row in "wildcard binding, localhost|http://localhost:20480|0.0.0.0:20480" \
    "IPv6 wildcard binding, [::1]|http://[::1]:20480|:::20480" \
    "IPv4 wildcard binding, [::1]|http://[::1]:20480|0.0.0.0:20480" \
    "IPv6 wildcard binding, 127.0.0.1|http://127.0.0.1:20480|:::20480" \
    "loopback binding, localhost|http://localhost:20480|127.0.0.1:20480" \
    "IPv6 loopback binding, localhost in capitals|http://LOCALHOST:20480|::1:20480" \
    "binding on the address the base URL names|http://192.0.2.10:20480|192.0.2.10:20480" \
    "default http port|http://127.0.0.1|0.0.0.0:80" \
    "default https port|https://localhost|0.0.0.0:443"; do
    IFS='|' read -r t_label t_base t_published <<<"$row"
    t_new_case
    t_resumable_run_dir "$t_base" "$t_published"
    t_respond GET "$FLAG_URL" 200 "$T_FLAG_ON"
    t_respond DELETE "$ALERTS_URL/$ID2" 204
    t_respond DELETE "$ALERTS_URL/$ID3" 204
    t_run_sub t_resume --project et-test --base-url "$t_base"
    t_expect "$t_label: exit status and deleted list" "$T_STATUS|$(t_lines "$RUN_DIR/deleted")" \
        "0|$ID1 $ID2 $ID3"
    t_expect_line "$t_label: origin bound" "$T_CASE_DIR/out" \
        "INFO resume: --base-url reaches reverse-proxy of project [et-test], port 80 published at $t_published"
done
t_conclude "$check"

check="main_resumeCleanupOriginNotShownToBeProjects_exitsTwoBeforeAnyRequest"
for row in "reverse-proxy not running in --project" "running services unreadable" \
    "port call fails" "port call cut off" "no HOST:PORT printed" "published host not an address" \
    "published port differs" "default port differs" "non-loopback base URL host, wildcard binding" \
    "IPv4 loopback base URL, IPv6 loopback binding" "binding on another host address"; do
    t_new_case
    t_base="$T_RESUME_BASE"
    t_published="$T_RESUME_PUBLISHED"
    t_reason="port 80 of reverse-proxy in --project is published on a host address that --base-url is not shown to reach"
    case "$row" in
        "published host not an address") t_published="localhost:20480" ;;
        "published port differs") t_published="0.0.0.0:20481" ;;
        "default port differs") t_base="http://localhost" ;;
        "non-loopback base URL host, wildcard binding") t_base="http://192.0.2.10:20480" ;;
        "IPv4 loopback base URL, IPv6 loopback binding")
            t_base="http://127.0.0.1:20480"
            t_published="::1:20480"
            ;;
        "binding on another host address") t_published="192.0.2.10:20480" ;;
    esac
    t_resumable_run_dir "$t_base" "$t_published"
    t_respond GET "$FLAG_URL" 200 "$T_FLAG_ON"
    t_respond DELETE "$ALERTS_URL/$ID2" 204
    t_respond DELETE "$ALERTS_URL/$ID3" 204
    case "$row" in
        "reverse-proxy not running in --project")
            # The origin is another project's: this one runs no reverse proxy.
            printf '%s\n' broker-service db db-adapter feature-flag-service >"$STUB_DIR/running"
            t_reason="reverse-proxy is not running in --project, so the stack at --base-url may be another project's"
            ;;
        "running services unreadable")
            STUB_PS_STATUS=1
            t_reason="listing the running services of --project failed, exit 1 (see $RUN_DIR/compose.log)"
            ;;
        "port call fails")
            STUB_PORT_STATUS=1
            t_reason="reading where --project publishes port 80 of reverse-proxy failed, exit 1 (see $RUN_DIR/compose.log)"
            ;;
        "port call cut off")
            STUB_PORT_STATUS=124
            t_reason="reading where --project publishes port 80 of reverse-proxy timed out after $DOCKER_CALL_TIMEOUT_SECONDS s (Docker did not answer)"
            ;;
        "no HOST:PORT printed" | "published host not an address")
            if [[ "$row" == "no HOST:PORT printed" ]]; then
                : >"$STUB_DIR/port.reverse-proxy"
            fi
            t_reason="docker compose port printed no HOST:PORT for port 80 of reverse-proxy in --project"
            ;;
        "published port differs" | "default port differs")
            t_reason="port 80 of reverse-proxy in --project is published on another port than --base-url names"
            ;;
    esac
    t_run_sub t_resume --project et-test --base-url "$t_base"
    t_expect "$row" "$T_STATUS|$(<"$T_CASE_DIR/err")|$(<"$STUB_DIR/http.calls")|$(t_lines "$RUN_DIR/deleted")" \
        "2|Cannot resume the cleanup of $RUN_DIR: $t_reason.||$ID1"
    if [[ "$row" == "port call fails" ]]; then
        t_expect_line "$row: Docker's error kept in compose.log" "$RUN_DIR/compose.log" \
            'service "reverse-proxy" is not running'
    fi
done
t_conclude "$check"

check="main_resumeCleanupRunLockHeld_failsBeforeFlagReadAndKeepsTheLock"
# Another run on the project holds its lock, with an owner file as acquire_run_lock writes it: the
# resume stops at the lock, before it reads the flag or deletes anything, and leaves that run's
# lock as it was.
t_new_case
t_resumable_run_dir
mkdir "$(t_lock_dir)"
t_owner_fields >"$(t_lock_dir)/owner"
t_respond GET "$FLAG_URL" 200 "$T_FLAG_OFF"
t_respond PUT "$FLAG_URL" 200 '@flag'
t_respond DELETE "$ALERTS_URL/$ID2" 204
t_respond DELETE "$ALERTS_URL/$ID3" 204
t_run_sub t_resume --project et-test --base-url "$T_RESUME_BASE"
t_expect "exit status and requests" "$T_STATUS|$(<"$STUB_DIR/http.calls")" "1|"
t_expect_line "verdict" "$T_CASE_DIR/out" \
    "FAIL run lock: $(t_refusal "started 2026-01-01T00:00:00Z, pid 1, host other-host.invalid, run dir /tmp/pi-loadgen.AbC123")"
t_expect_line "summary" "$T_CASE_DIR/out" "SUMMARY 0 passed, 1 failed"
t_expect_no_match "no flag read, cleanup or release" "$T_CASE_DIR/out" '^PASS |^INFO cleanup|resume flag'
t_expect "deleted list" "$(t_lines "$RUN_DIR/deleted")" "$ID1"
t_expect "holder's lock kept" "$(t_lock_presence "$(t_lock_dir)")|$(<"$(t_lock_dir)/owner")" \
    "present|$(t_owner_fields)"
t_conclude "$check"

check="main_resumeCleanup_runLock_releasedOnEveryEnd"
# ROW|STATUS|BODY|EXIT: the flag read answers STATUS with BODY, @flag being the flag off, so that
# cleanup takes over and deletes, and the resume exits EXIT. Either way the resume takes the
# project's lock under the case's LOCK_ROOT, never under the /tmp the script names, and releases
# it: through cleanup, or through resume_exit when it ends at the flag read.
for row in "cleanup ran|200|@flag|0" "flag read failed|500|{\"error\":\"internal\"}|1"; do
    IFS='|' read -r t_label t_status t_body t_exit <<<"$row"
    t_new_case
    t_resumable_run_dir
    t_respond GET "$FLAG_URL" "$t_status" "$t_body"
    t_respond PUT "$FLAG_URL" 200 '@flag'
    t_respond DELETE "$ALERTS_URL/$ID2" 204
    t_respond DELETE "$ALERTS_URL/$ID3" 204
    t_run_sub t_resume --project et-test --base-url "$T_RESUME_BASE"
    t_expect "$t_label: exit status" "$T_STATUS" "$t_exit"
    t_expect_line "$t_label: lock taken under LOCK_ROOT" "$T_CASE_DIR/out" \
        "PASS run lock: $T_CASE_DIR/pi-loadgen-check.et-test.lock"
    t_expect_line "$t_label: released" "$T_CASE_DIR/out" "INFO cleanup: run lock $(t_lock_dir) released"
    t_expect "$t_label: lock removed" "$(t_lock_presence "$(t_lock_dir)")" absent
    t_expect "$t_label: no lock under /tmp" "$(t_lock_presence /tmp/pi-loadgen-check.et-test.lock)" absent
done
t_conclude "$check"

check="cleanup_alertsLeft_printsResumeCommandOnlyForIdsLeft"
# ROW: which owned alerts cleanup leaves, and the Compose files of the run.
for row in "one left" "one left, compose file with a space" "only a refused line left" "none left"; do
    t_new_case
    FLAG_INITIAL="true"
    t_respond GET "$FLAG_URL" 200 "$T_FLAG_ON"
    t_respond DELETE "$ALERTS_URL/$ID1" 500 '{"error":"internal"}'
    t_respond DELETE "$ALERTS_URL/$ID2" 204
    t_extra=""
    case "$row" in
        "one left") printf '%s\n' "$ID1" "$ID2" >"$RUN_DIR/owned" ;;
        "one left, compose file with a space")
            printf '%s\n' "$ID1" "$ID2" >"$RUN_DIR/owned"
            COMPOSE_FILES=("compose.dev.yaml" "my override.yaml")
            t_extra=" --compose-file my\\ override.yaml"
            ;;
        "only a refused line left") printf '%s\n' "not-an-id" "$ID2" >"$RUN_DIR/owned" ;;
        "none left") printf '%s\n' "$ID2" >"$RUN_DIR/owned" ;;
    esac
    t_run_sub t_exit_through_cleanup 0
    printf -v t_line '%s%s --resume-cleanup %q' \
        "INFO cleanup: to delete the owned alerts left, and only those, run: scripts/portfolio-insights/loadgen-check.sh --project et-test --base-url http://stub.invalid --compose-file compose.dev.yaml" \
        "$t_extra" "$RUN_DIR"
    case "$row" in
        "one left"*)
            t_expect_line "$row: command" "$T_CASE_DIR/out" "$t_line"
            t_expect_line "$row: verdict" "$T_CASE_DIR/out" "FAIL cleanup: 1 owned alerts left in place"
            ;;
        "only a refused line left")
            t_expect_no_match "$row: command" "$T_CASE_DIR/out" '^INFO cleanup: to delete'
            t_expect_line "$row: verdict" "$T_CASE_DIR/out" "FAIL cleanup: 1 owned alerts left in place"
            ;;
        "none left")
            t_expect_no_match "$row: command" "$T_CASE_DIR/out" '^INFO cleanup: to delete'
            t_expect_line "$row: verdict" "$T_CASE_DIR/out" "PASS cleanup"
            ;;
    esac
done
t_conclude "$check"

check="cleanup_leftThenResumed_resumeDeletesOnlyTheIdLeft"
# A run's cleanup leaves ID1 while the broker fails; the resume after the broker recovers sends
# one DELETE, of ID1, and passes.
t_new_case
t_resumable_run_dir
: >"$RUN_DIR/deleted"
printf '%s\n' "$ID1" "$ID2" >"$RUN_DIR/owned"
FLAG_INITIAL="true"
t_respond GET "$FLAG_URL" 200 "$T_FLAG_ON"
t_respond DELETE "$ALERTS_URL/$ID2" 204
t_respond_transient DELETE "$ALERTS_URL/$ID1" 3
t_respond DELETE "$ALERTS_URL/$ID1" 204
t_run_sub t_exit_through_cleanup 0
t_expect "run: exit status and deleted list" "$T_STATUS|$(t_lines "$RUN_DIR/deleted")" "1|$ID2"
: >"$STUB_DIR/http.calls"
t_run_sub t_resume --project et-test --base-url "$T_RESUME_BASE"
t_expect "resume: exit status and requests" "$T_STATUS|$(<"$STUB_DIR/http.calls")" "0|GET $FLAG_URL
GET $FLAG_URL
DELETE $ALERTS_URL/$ID1"
t_expect "resume: deleted list" "$(t_lines "$RUN_DIR/deleted")" "$ID2 $ID1"
t_expect_line "resume: cleanup verdict" "$T_CASE_DIR/out" "PASS cleanup"
t_conclude "$check"

echo "SUMMARY ${cases_passed} passed, ${cases_failed} failed"
if [[ $cases_failed -ne 0 ]]; then
    exit 1
fi
