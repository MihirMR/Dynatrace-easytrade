#!/usr/bin/env bash
# Measures the two Portfolio Insights limits against one running Compose dev project:
#   - insights p95 below 500 ms for an account that holds 15 instruments;
#   - one alert evaluation cycle below 10 s for 1,000 armed alerts.
# Run it from the repository root, once per dialect, against a project whose stack is up.
# The script enables the portfolio-insights-enabled flag itself and restores it on exit.
#
# Usage: scripts/portfolio-insights/perf.sh --project NAME [--base-url URL] [--compose-file FILE]
#   --project NAME       Compose project of the running stack (required)
#   --base-url URL       Reverse-proxy URL of that stack (default: http://localhost)
#   --compose-file FILE  Compose file of that project, relative to the current directory
#                        (default: compose.dev.yaml)
#   --help               Show this help and exit
#
# One project per invocation. Never run it alongside e2e.sh or loadgen-check.sh: all three
# toggle the same flag and work on the same preset accounts.
#
# What it touches: it reads the 25 PRESET accounts without trading on them, creates 1,000
# alerts of its own on them, stops loadgen while it measures, and runs read-only SELECTs
# through the db container's own client. On exit, normal or not, it deletes every alert it
# created by id, restores the flag to the value it read at start, and starts loadgen again
# only if loadgen was running at start.
#
# Prints one PASS or FAIL line per check, a REPORT block and a final SUMMARY line. Exits 0
# when every check passes, 1 when any check fails, and 2 on a usage error or a missing tool.
# Working files stay in the run directory printed at start and end.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

FLAG_ID="portfolio-insights-enabled"
# The readiness set plus pricing-service and user-service: the measured insights call reaches
# pricing and the preset listing is user-service's, so either one down would only surface later
# as a confusing 5xx. loadgen is handled separately.
REQUIRED_SERVICES="broker-service db db-adapter feature-flag-service pricing-service reverse-proxy user-service"
READY_TIMEOUT_SECONDS=300
READY_STEP_SECONDS=5
HTTP_TIMEOUT_SECONDS=15
LOG_STEP_SECONDS=5
# Log windows start this far back so a host clock ahead of the Docker engine's loses no line;
# lines already present when a window opens are counted and skipped, never read as new.
LOG_SKEW_MARGIN_SECONDS=30
PRESET_COUNT=25
HOLDINGS_EXPECTED=15
ALERTS_PER_ACCOUNT=40
TARGET_PRICE_PER_ACCOUNT=20
ALERTS_EXPECTED=$((PRESET_COUNT * ALERTS_PER_ACCOUNT))
# The threshold domain maximum (10 integer and 8 fractional digits), sent as the exact token.
MAX_THRESHOLD="9999999999.99999999"
WARMUP_REQUESTS=10
TIMED_REQUESTS=200
INSIGHTS_LIMIT_SECONDS="0.5"
CYCLE_LIMIT_MS="10000"
MAX_REJECTED_SAMPLES=3
FOLLOW_UP_CYCLES=2
# The broker's interval rule: a whole number from 1 to 4294967 seconds, otherwise 60.
DEFAULT_INTERVAL_SECONDS=60
MAX_INTERVAL_SECONDS=4294967
# Cleanup stops sending DELETEs after this many transport errors in a row.
MAX_CONSECUTIVE_TRANSPORT_ERRORS=5

CYCLE_MARKER="Alert evaluation cycle finished"
CYCLE_RE='alerts \[([0-9]+)\] triggered \[([0-9]+)\] failed \[([0-9]+)\] skipped \[([0-9]+)\] outcome \[([A-Za-z_]+)\] duration \[([0-9]+(\.[0-9]+)?)\] ms'
INSIGHTS_DURATION_RE='duration \[([0-9]+(\.[0-9]+)?)\] ms'
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

usage() {
    cat <<'EOF'
Usage: scripts/portfolio-insights/perf.sh --project NAME [--base-url URL] [--compose-file FILE]
  --project NAME       Compose project of the running stack (required)
  --base-url URL       Reverse-proxy URL of that stack (default: http://localhost)
  --compose-file FILE  Compose file of that project, relative to the current directory
                       (default: compose.dev.yaml)
  --help               Show this help and exit
Run one project at a time, never alongside e2e.sh or loadgen-check.sh.
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
while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-url | --compose-file | --project)
            if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
                usage_error "Option $1 requires a value."
            fi
            case "$1" in
                --base-url) BASE_URL="$2" ;;
                --compose-file) COMPOSE_FILE="$2" ;;
                --project) PROJECT="$2" ;;
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
if [[ ! "$BASE_URL" =~ ^https?://[^[:space:]]+$ ]]; then
    usage_error "Option --base-url needs an http:// or https:// URL, got: $BASE_URL"
fi
BASE_URL="${BASE_URL%/}"
if [[ ! -f "$COMPOSE_FILE" ]]; then
    usage_error "Compose file not found: $COMPOSE_FILE (resolved from $(pwd); the repository root is $REPO_ROOT)"
fi

missing_tools=""
for tool in bash curl jq docker; do
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

if ! RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pi-perf.XXXXXX")"; then
    echo "Could not create a run directory under ${TMPDIR:-/tmp}." >&2
    exit 2
fi
: >"$RUN_DIR/owned"
: >"$RUN_DIR/expected"
: >"$RUN_DIR/deleted"

FLAG_URL="$BASE_URL/feature-flag-service/v1/flags/$FLAG_ID"
ALERTS_URL="$BASE_URL/broker-service/v1/alerts"
INSIGHTS_URL="$BASE_URL/broker-service/v1/portfolio/insights"

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
EVAL_INTERVAL=""
STARTED_AT=""

# Report values; "n/a" until measured.
R_INSIGHTS_ACCOUNT="n/a"
R_INSIGHTS_P95="n/a"
R_INSIGHTS_VERDICT="not measured"
R_SERVER_SHARE="n/a"
R_CYCLE_DURATION="n/a"
R_CYCLE_VERDICT="not measured"
R_CYCLE_REJECTIONS="0"
R_FOLLOW_UPS="n/a"

# ---------------------------------------------------------------------------------------------
# Reporting

pass() {
    passed=$((passed + 1))
    echo "PASS $1"
}

fail() {
    failed=$((failed + 1))
    echo "FAIL $1: $2"
}

info() {
    echo "INFO $*"
}

# Fails the check and ends the run through finish, so cleanup still runs.
abort() {
    fail "$1" "$2"
    finish
}

# ---------------------------------------------------------------------------------------------
# HTTP and JSON

# http METHOD URL [BODY]: sets HTTP_STATUS (000 on a transport error), HTTP_CTYPE, HTTP_BODY
# and HTTP_ERROR (curl's message on a transport error). Never trips set -e.
http() {
    local method="$1" url="$2" out rc=0
    local args=(-sS --max-time "$HTTP_TIMEOUT_SECONDS" -X "$method"
        -o "$RUN_DIR/body" -D "$RUN_DIR/headers" -w '%{http_code} %{content_type}'
        -H 'Accept: application/json')
    if [[ $# -ge 3 ]]; then
        args+=(-H 'Content-Type: application/json' --data-binary "$3")
    fi
    : >"$RUN_DIR/body"
    out="$(curl "${args[@]}" "$url" 2>"$RUN_DIR/curl-error")" || rc=$?
    if [[ $rc -ne 0 ]]; then
        HTTP_STATUS="000"
        HTTP_CTYPE=""
        HTTP_ERROR="$(tr -d '\r' <"$RUN_DIR/curl-error" | head -c 300)"
    else
        HTTP_STATUS="${out%% *}"
        HTTP_CTYPE="${out#* }"
        HTTP_ERROR=""
    fi
    HTTP_BODY="$(cat "$RUN_DIR/body")"
}

# jget FILTER JSON: prints jq's raw output, or nothing when the JSON does not parse.
jget() {
    jq -r "$1" 2>/dev/null <<<"$2" | tr -d '\r' || true
}

# Status text for a failure reason, with curl's message on a transport error.
status_text() {
    if [[ "$HTTP_STATUS" == "000" ]]; then
        echo "transport error (${HTTP_ERROR:-no response})"
    else
        echo "status $HTTP_STATUS"
    fi
}

# ---------------------------------------------------------------------------------------------
# Exact decimals. Bash has no floating point, so durations and limits are compared as integer
# units of 1e-8.

# dec_to_units TEXT: plain decimal text to units of 1e-8, rounding half away from zero beyond
# the eighth fractional digit. Fails on anything else or on more than 10 integer digits.
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

# seconds_to_ms SECONDS: decimal seconds as decimal milliseconds.
seconds_to_ms() {
    local units
    units="$(dec_to_units "$1")" || return 1
    units_to_dec $((units * 1000))
}

# nearest_rank PERCENT FILE: the nearest-rank percentile of the numbers in FILE, one per line.
nearest_rank() {
    local count rank
    count=$(($(wc -l <"$2")))
    if [[ $count -eq 0 ]]; then
        return 1
    fi
    rank=$(((${1} * count + 99) / 100))
    LC_ALL=C sort -n "$2" | sed -n "${rank}p"
}

# ---------------------------------------------------------------------------------------------
# Alerts

# create_alert ACCOUNT TYPE INSTRUMENT DIRECTION THRESHOLD: POST /v1/alerts with the threshold
# written into the body as the exact JSON number token, never converted. On 201 the id is
# recorded as owned at once, so cleanup deletes it whatever happens next, and id,revision is
# appended to the expected armed set. Sets CREATE_ERROR on failure.
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
    local body id revision fields
    if [[ ! "$5" =~ ^-?(0|[1-9][0-9]*)(\.[0-9]+)?$ ]]; then
        CREATE_ERROR="threshold [$5] is not a plain decimal token"
        return 1
    fi
    body="$(printf '{"accountId":"%s","type":"%s","instrumentId":"%s","direction":"%s","threshold":%s}' \
        "$1" "$2" "$3" "$4" "$5")"
    http POST "$ALERTS_URL" "$body"
    if [[ "$HTTP_STATUS" == "000" ]]; then
        CREATE_ERROR="$(status_text); the alert may exist without an id this run knows"
        return 1
    fi
    if [[ "$HTTP_STATUS" != "201" ]]; then
        CREATE_ERROR="$(status_text)"
        return 1
    fi
    fields="$(jget '"\(.id // "") \(.armingRevision // "")"' "$HTTP_BODY")"
    id="$(tr '[:upper:]' '[:lower:]' <<<"${fields%% *}")"
    revision="${fields#* }"
    if [[ ! "$id" =~ $UUID_RE ]]; then
        CREATE_ERROR="201 without a readable id; the created alert cannot be deleted by this run"
        return 1
    fi
    echo "$id" >>"$RUN_DIR/owned"
    if [[ ! "$revision" =~ ^[0-9]+$ ]]; then
        CREATE_ERROR="201 for alert [$id] without a readable armingRevision"
        return 1
    fi
    echo "$id,$revision" >>"$RUN_DIR/expected"
}

# ---------------------------------------------------------------------------------------------
# Docker, times and logs

# Arguments such as /opt/mssql-tools/... must reach docker unchanged: Git Bash would rewrite
# them to Windows paths. Only docker gets this; curl still needs the rewrite of its file paths.
# stdin is detached so docker never consumes the input of a surrounding read loop.
compose() {
    MSYS_NO_PATHCONV=1 docker compose -p "$PROJECT" -f "$COMPOSE_FILE" "$@" </dev/null
}

now_rfc3339() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# epoch_to_rfc3339 EPOCH: GNU date first, then BSD date.
epoch_to_rfc3339() {
    date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

# broker_logs SINCE: broker-service output since SINCE, without colour codes or carriage
# returns. The custom console logger pads each line and ends it with " | <CallerName>", so
# callers match substrings only.
broker_logs() {
    compose logs --no-color --no-log-prefix --since "$1" broker-service 2>>"$RUN_DIR/compose.log" \
        | sed "s/$(printf '\033')\[[0-9;]*m//g" | tr -d '\r'
}

# open_log_window: starts a cycle-log window. LOG_SINCE is now minus the skew margin and
# LOG_BASE counts the cycle lines already inside it, which later reads skip.
open_log_window() {
    LOG_SINCE="$(epoch_to_rfc3339 $(($(date -u +%s) - LOG_SKEW_MARGIN_SECONDS)))"
    LOG_BASE=0
    if broker_logs "$LOG_SINCE" >"$RUN_DIR/broker.log"; then
        LOG_BASE="$(grep -cF "$CYCLE_MARKER" "$RUN_DIR/broker.log" || true)"
        return 0
    fi
    return 1
}

# parse_cycle_line LINE: sets C_ALERTS, C_TRIGGERED, C_FAILED, C_SKIPPED, C_OUTCOME and
# C_DURATION from a cycle summary line. The duration is whole milliseconds today; a decimal
# is accepted as well.
parse_cycle_line() {
    if [[ ! "$1" =~ $CYCLE_RE ]]; then
        return 1
    fi
    C_ALERTS="${BASH_REMATCH[1]}"
    C_TRIGGERED="${BASH_REMATCH[2]}"
    C_FAILED="${BASH_REMATCH[3]}"
    C_SKIPPED="${BASH_REMATCH[4]}"
    C_OUTCOME="${BASH_REMATCH[5]}"
    C_DURATION="${BASH_REMATCH[6]}"
}

cycle_is_clean() {
    [[ "$C_ALERTS" == "$ALERTS_EXPECTED" && "$C_TRIGGERED" == 0 && "$C_FAILED" == 0 &&
        "$C_SKIPPED" == 0 && "$C_OUTCOME" == "completed" ]]
}

cycle_summary_text() {
    echo "alerts [$C_ALERTS] triggered [$C_TRIGGERED] failed [$C_FAILED] skipped [$C_SKIPPED] outcome [$C_OUTCOME] duration [$C_DURATION] ms"
}

# wait_cycle_line AFTER TIMEOUT [ALERTS]: bounded poll, every LOG_STEP_SECONDS for at most
# TIMEOUT seconds, for the first cycle line of the current window after the AFTER-th one. With
# ALERTS, lines rendering another alert count are cycles that began during setup and are
# skipped. Sets CYCLE_INDEX and CYCLE_LINE.
wait_cycle_line() {
    local after="$1" deadline=$((SECONDS + $2)) wanted="${3:-}" reported="$1" index line
    while :; do
        if broker_logs "$LOG_SINCE" >"$RUN_DIR/broker.log"; then
            index=0
            while IFS= read -r line; do
                index=$((index + 1))
                if [[ $index -le $after ]] || ! parse_cycle_line "$line"; then
                    continue
                fi
                if [[ -n "$wanted" && "$C_ALERTS" != "$wanted" ]]; then
                    if [[ $index -gt $reported ]]; then
                        info "ignoring a cycle that began during setup: $(cycle_summary_text)"
                        reported=$index
                    fi
                    continue
                fi
                CYCLE_INDEX=$index
                CYCLE_LINE="$line"
                return 0
            done < <(grep -F "$CYCLE_MARKER" "$RUN_DIR/broker.log" || true)
        fi
        if [[ $((SECONDS + LOG_STEP_SECONDS)) -gt $deadline ]]; then
            return 1
        fi
        sleep "$LOG_STEP_SECONDS"
    done
}

# ---------------------------------------------------------------------------------------------
# Database (read only)

# db_query SQL: runs one read-only query through the db container's own client and prints one
# line per row, lower-cased, without carriage returns or blank lines. A SQL error exits
# non-zero. The SA password expands inside the container from its own SA_PASSWORD, so it never
# appears on the host, in this script or in its output; PostgreSQL uses the container's local
# postgres role.
db_query() {
    case "$DIALECT" in
        mssql)
            # shellcheck disable=SC2016 # $SA_PASSWORD and $1 expand in the container's shell.
            compose exec -T db sh -c \
                '/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -d TradeManagement -b -h -1 -W -Q "$1"' \
                sh "SET NOCOUNT ON; $1"
            ;;
        postgres)
            compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d TradeManagement -At -F , -c "$1"
            ;;
        *)
            echo "unknown dialect [$DIALECT]" >&2
            return 1
            ;;
    esac 2>>"$RUN_DIR/db-error.log" | tr -d '\r' | tr '[:upper:]' '[:lower:]' | sed '/^[[:space:]]*$/d'
}

# armed_sql: every armed alert as one "id,revision" column, identical on both dialects.
armed_sql() {
    if [[ "$DIALECT" == "mssql" ]]; then
        echo "SELECT LOWER(CONVERT(varchar(36), [Id])) + ',' + CONVERT(varchar(12), [ArmingRevision]) FROM [dbo].[Alerts] WHERE [Enabled] = 1 AND [TriggeredAt] IS NULL ORDER BY 1"
    else
        echo "SELECT lower(\"Id\"::text) || ',' || \"ArmingRevision\" FROM \"Alerts\" WHERE \"Enabled\" = true AND \"TriggeredAt\" IS NULL ORDER BY 1"
    fi
}

# read_armed_set: writes the sorted armed set to $RUN_DIR/armed. Sets ARMED_ERROR on failure.
read_armed_set() {
    local rows
    if ! rows="$(db_query "$(armed_sql)")"; then
        ARMED_ERROR="armed-set query failed: $(tail -n 3 "$RUN_DIR/db-error.log" | tr '\n' ' ')$(head -n 3 <<<"$rows" | tr '\n' ' ')"
        return 1
    fi
    if [[ -n "$rows" ]]; then
        LC_ALL=C sort <<<"$rows" >"$RUN_DIR/armed"
    else
        : >"$RUN_DIR/armed"
    fi
}

# armed_set_difference: the number of id,revision lines in only one of the expected and
# armed sets.
armed_set_difference() {
    LC_ALL=C sort "$RUN_DIR/expected" >"$RUN_DIR/expected.sorted"
    LC_ALL=C comm -3 "$RUN_DIR/expected.sorted" "$RUN_DIR/armed" | wc -l | tr -d ' '
}


# ---------------------------------------------------------------------------------------------
# Runtime facts, read from the project's containers rather than from any input

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

# ---------------------------------------------------------------------------------------------
# Cleanup. Every step is idempotent, so an interrupted cleanup resumes when it runs again.

add_cleanup_problem() {
    CLEANUP_PROBLEMS="${CLEANUP_PROBLEMS:+$CLEANUP_PROBLEMS; }$1"
}

# delete_owned_alerts: DELETEs every owned id not yet deleted. 204 and 404 are clean; any
# other outcome is printed with its id and listed in $RUN_DIR/left-in-place.
delete_owned_alerts() {
    local id deleted=0 absent=0 left=0 skipped=0 transport=0
    LC_ALL=C sort -u "$RUN_DIR/owned" >"$RUN_DIR/owned.sorted"
    LC_ALL=C sort -u "$RUN_DIR/deleted" >"$RUN_DIR/deleted.sorted"
    LC_ALL=C comm -23 "$RUN_DIR/owned.sorted" "$RUN_DIR/deleted.sorted" >"$RUN_DIR/to-delete"
    : >"$RUN_DIR/left-in-place"
    while IFS= read -r id; do
        if [[ $transport -ge $MAX_CONSECUTIVE_TRANSPORT_ERRORS ]]; then
            echo "$id not attempted" >>"$RUN_DIR/left-in-place"
            skipped=$((skipped + 1))
            continue
        fi
        http DELETE "$ALERTS_URL/$id"
        case "$HTTP_STATUS" in
            204)
                deleted=$((deleted + 1))
                transport=0
                echo "$id" >>"$RUN_DIR/deleted"
                ;;
            404)
                absent=$((absent + 1))
                transport=0
                echo "$id" >>"$RUN_DIR/deleted"
                ;;
            *)
                left=$((left + 1))
                if [[ "$HTTP_STATUS" == "000" ]]; then
                    transport=$((transport + 1))
                else
                    transport=0
                fi
                echo "$id $(status_text)" >>"$RUN_DIR/left-in-place"
                info "cleanup: alert [$id] left in place: $(status_text)"
                ;;
        esac
    done <"$RUN_DIR/to-delete"
    info "cleanup: $deleted alerts deleted, $absent already absent, $left left in place, $skipped not attempted"
    if [[ $((left + skipped)) -gt 0 ]]; then
        add_cleanup_problem "$((left + skipped)) owned alerts left in place, ids in $RUN_DIR/left-in-place"
    fi
}

cleanup_all() {
    local remaining
    CLEANUP_PROBLEMS=""
    LC_ALL=C sort -u "$RUN_DIR/owned" >"$RUN_DIR/owned.sorted"
    LC_ALL=C sort -u "$RUN_DIR/deleted" >"$RUN_DIR/deleted.sorted"
    remaining=$(($(LC_ALL=C comm -23 "$RUN_DIR/owned.sorted" "$RUN_DIR/deleted.sorted" | wc -l)))
    if [[ $remaining -gt 0 ]]; then
        # DELETE answers 403 while the flag is off, so the flag is switched on to delete.
        http GET "$FLAG_URL"
        if [[ "$HTTP_STATUS" == "200" && "$(jget '.enabled' "$HTTP_BODY")" == "false" ]]; then
            FLAG_TOUCHED=1
            http PUT "$FLAG_URL" '{"enabled": true}'
            if [[ "$HTTP_STATUS" != "200" ]]; then
                add_cleanup_problem "flag could not be switched on for deletion: $(status_text)"
            fi
        fi
        info "cleanup: deleting $remaining owned alerts"
        delete_owned_alerts
    fi
    if [[ $FLAG_TOUCHED -eq 1 && -n "$FLAG_INITIAL" ]]; then
        http PUT "$FLAG_URL" "{\"enabled\": $FLAG_INITIAL}"
        if [[ "$HTTP_STATUS" == "200" ]]; then
            info "cleanup: flag $FLAG_ID restored to enabled=$FLAG_INITIAL"
        else
            add_cleanup_problem "flag $FLAG_ID not restored to enabled=$FLAG_INITIAL: $(status_text)"
        fi
    fi
    if [[ $LOADGEN_STOPPED -eq 1 ]]; then
        if compose start loadgen >>"$RUN_DIR/compose.log" 2>&1; then
            info "cleanup: loadgen started again"
        else
            add_cleanup_problem "loadgen was running at start and could not be started again (see $RUN_DIR/compose.log)"
        fi
    fi
    CLEANUP_DONE=1
}

# ---------------------------------------------------------------------------------------------
# Report and exit

print_report() {
    echo "REPORT"
    printf '  %-24s %s\n' \
        "project" "$PROJECT" \
        "base url" "$BASE_URL" \
        "db type" "${DIALECT:-n/a}" \
        "host" "$(uname -n)" \
        "evaluation interval" "${EVAL_INTERVAL:-n/a}${EVAL_INTERVAL:+ s}" \
        "insights account" "$R_INSIGHTS_ACCOUNT" \
        "insights p95" "$R_INSIGHTS_P95 ($R_INSIGHTS_VERDICT)" \
        "insights server share" "$R_SERVER_SHARE" \
        "cycle duration" "$R_CYCLE_DURATION ($R_CYCLE_VERDICT)" \
        "rejected cycle samples" "$R_CYCLE_REJECTIONS" \
        "follow-up cycles" "$R_FOLLOW_UPS" \
        "started" "${STARTED_AT:-n/a}" \
        "finished" "$(now_rfc3339)" \
        "run dir" "$RUN_DIR"
}

# Reports, cleans up as a check of its own, and exits: 1 on any FAIL, otherwise 0.
finish() {
    print_report
    set +e
    cleanup_all
    if [[ -z "$CLEANUP_PROBLEMS" ]]; then
        pass "cleanup"
    else
        fail "cleanup" "$CLEANUP_PROBLEMS"
    fi
    FINISHED=1
    echo "SUMMARY $passed passed, $failed failed"
    if [[ $failed -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

# Runs when the script ends anywhere but finish: an interrupt or an unexpected error.
# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
on_exit() {
    local status=$?
    trap - EXIT
    if [[ $FINISHED -eq 1 ]]; then
        exit "$status"
    fi
    set +e
    info "run ended early with status $status; cleaning up"
    if [[ $CLEANUP_DONE -eq 0 ]]; then
        cleanup_all
        if [[ -n "$CLEANUP_PROBLEMS" ]]; then
            fail "cleanup" "$CLEANUP_PROBLEMS"
        else
            pass "cleanup"
        fi
    fi
    info "run dir $RUN_DIR"
    echo "SUMMARY $passed passed, $failed failed"
    if [[ $status -eq 0 ]]; then
        status=1
    fi
    exit "$status"
}

# ---------------------------------------------------------------------------------------------
# Setup

setup() {
    local running missing="" service deadline broker_ready flag_ready raw_interval flag_id modifiable enabled

    running="$(running_services)" || running=""
    for service in $REQUIRED_SERVICES; do
        if ! grep -qxF "$service" <<<"$running"; then
            missing="$missing $service"
        fi
    done
    if [[ -n "$missing" ]]; then
        abort "readiness" "services not running in project [$PROJECT]:$missing"
    fi
    if grep -qxF "loadgen" <<<"$running"; then
        LOADGEN_WAS_RUNNING=1
    fi
    deadline=$((SECONDS + READY_TIMEOUT_SECONDS))
    while :; do
        http GET "$BASE_URL/broker-service/readyz"
        broker_ready="$(status_text)"
        http GET "$BASE_URL/feature-flag-service/readyz"
        flag_ready="$(status_text)"
        if [[ "$broker_ready" == "status 200" && "$flag_ready" == "status 200" ]]; then
            break
        fi
        if [[ $((SECONDS + READY_STEP_SECONDS)) -gt $deadline ]]; then
            abort "readiness" "after ${READY_TIMEOUT_SECONDS}s broker-service readyz gave $broker_ready, feature-flag-service readyz gave $flag_ready"
        fi
        sleep "$READY_STEP_SECONDS"
    done
    pass "readiness"

    DIALECT="$(container_env db-adapter DB_TYPE)" || DIALECT=""
    if [[ "$DIALECT" != "mssql" && "$DIALECT" != "postgres" ]]; then
        abort "runtime facts" "db-adapter DB_TYPE is [$DIALECT], expected mssql or postgres"
    fi
    raw_interval="$(container_env broker-service ALERT_EVALUATION_INTERVAL_SECONDS)" || raw_interval=""
    EVAL_INTERVAL="$(resolve_interval "$raw_interval")"
    pass "runtime facts"
    info "db type $DIALECT; evaluation interval ${EVAL_INTERVAL}s (ALERT_EVALUATION_INTERVAL_SECONDS [$raw_interval]); loadgen running at start: $([[ $LOADGEN_WAS_RUNNING -eq 1 ]] && echo yes || echo no)"

    http GET "$FLAG_URL"
    if [[ "$HTTP_STATUS" != "200" ]]; then
        abort "flag modifiable" "GET $FLAG_ID gave $(status_text)"
    fi
    flag_id="$(jget '.id' "$HTTP_BODY")"
    modifiable="$(jget '.isModifiable' "$HTTP_BODY")"
    enabled="$(jget '.enabled' "$HTTP_BODY")"
    if [[ "$flag_id" != "$FLAG_ID" || ("$enabled" != "true" && "$enabled" != "false") ]]; then
        abort "flag modifiable" "GET $FLAG_ID answered id [$flag_id] enabled [$enabled] as ${HTTP_CTYPE:-untyped content}"
    fi
    if [[ "$modifiable" != "true" ]]; then
        abort "flag modifiable" "isModifiable is [$modifiable]; a deployment with ENABLE_MODIFY=false cannot be toggled"
    fi
    FLAG_INITIAL="$enabled"
    pass "flag modifiable"
    info "flag $FLAG_ID initially enabled=$FLAG_INITIAL"

    if [[ $LOADGEN_WAS_RUNNING -eq 1 ]]; then
        # Recorded first, so an interrupted stop still restores loadgen on exit.
        LOADGEN_STOPPED=1
        if ! compose stop loadgen >>"$RUN_DIR/compose.log" 2>&1; then
            abort "loadgen isolation" "compose stop loadgen failed (see $RUN_DIR/compose.log)"
        fi
        info "loadgen stopped, so no visit trades on the measured accounts or adds alerts; it is started again on exit"
    else
        info "loadgen was not running and stays stopped"
    fi
    pass "loadgen isolation"

    FLAG_TOUCHED=1
    http PUT "$FLAG_URL" '{"enabled": true}'
    if [[ "$HTTP_STATUS" != "200" || "$(jget '.enabled' "$HTTP_BODY")" != "true" ]]; then
        abort "flag enabled" "PUT {\"enabled\": true} gave $(status_text)"
    fi
    pass "flag enabled"
}

# fetch_presets: the first PRESET_COUNT preset account ids, in the service's order, into
# $RUN_DIR/presets. Sets PRESETS_STATUS.
fetch_presets() {
    : >"$RUN_DIR/presets"
    http GET "$BASE_URL/user-service/api/accounts/presets?limit=$PRESET_COUNT"
    PRESETS_STATUS="$(status_text)"
    if [[ "$HTTP_STATUS" == "200" ]]; then
        jget '.results[]?.id' "$HTTP_BODY" | tr '[:upper:]' '[:lower:]' | sed '/^$/d' >"$RUN_DIR/presets"
    fi
}

# insights_profile ACCOUNT: GETs the account's insights. Sets PROFILE_STATUS,
# PROFILE_ALLOCATIONS and PROFILE_HELD (allocations with quantity > 0), and writes the held
# instrument ids, sorted, to $RUN_DIR/held-ACCOUNT. Succeeds when the account holds exactly
# HOLDINGS_EXPECTED instruments.
insights_profile() {
    local counts
    : >"$RUN_DIR/held-$1"
    PROFILE_ALLOCATIONS="?"
    PROFILE_HELD="?"
    http GET "$INSIGHTS_URL/$1"
    PROFILE_STATUS="$(status_text)"
    if [[ "$HTTP_STATUS" != "200" ]]; then
        return 1
    fi
    counts="$(jget '(.allocations // []) | "\(length) \([.[] | select(.quantity > 0)] | length)"' "$HTTP_BODY")"
    if [[ ! "$counts" =~ ^[0-9]+\ [0-9]+$ ]]; then
        PROFILE_STATUS="status 200 with an unreadable ${HTTP_CTYPE:-untyped} body"
        return 1
    fi
    PROFILE_ALLOCATIONS="${counts% *}"
    PROFILE_HELD="${counts#* }"
    jget '(.allocations // [])[] | select(.quantity > 0) | .instrumentId' "$HTTP_BODY" \
        | tr '[:upper:]' '[:lower:]' | sed '/^$/d' | LC_ALL=C sort -u >"$RUN_DIR/held-$1"
    if [[ "$PROFILE_ALLOCATIONS" != "$HOLDINGS_EXPECTED" || "$PROFILE_HELD" != "$HOLDINGS_EXPECTED" ]]; then
        return 1
    fi
    return 0
}


# ---------------------------------------------------------------------------------------------
# Limit 1: insights p95 < 500 ms for 15 holdings

measure_insights() {
    local account="" id seen="" since i total out status seconds non200=0 timed p95 p95_ms
    local line lines median_ms server_p95_ms

    if [[ ! -s "$RUN_DIR/presets" ]]; then
        fail "insights p95 account" "GET presets gave $PRESETS_STATUS with no account ids"
        return 0
    fi
    while IFS= read -r id; do
        if insights_profile "$id"; then
            account="$id"
            break
        fi
        seen="$seen [$id] $PROFILE_STATUS, $PROFILE_ALLOCATIONS allocations, $PROFILE_HELD held;"
    done <"$RUN_DIR/presets"
    if [[ -z "$account" ]]; then
        fail "insights p95 account" "no preset account has exactly $HOLDINGS_EXPECTED allocations with quantity > 0:$seen"
        return 0
    fi
    R_INSIGHTS_ACCOUNT="$account"
    pass "insights p95 account"

    total=$((WARMUP_REQUESTS + TIMED_REQUESTS))
    info "timing insights of account [$account]: $WARMUP_REQUESTS warm-up then $TIMED_REQUESTS sequential requests"
    since="$(epoch_to_rfc3339 $(($(date -u +%s) - LOG_SKEW_MARGIN_SECONDS)))"
    : >"$RUN_DIR/insights-times"
    for ((i = 1; i <= total; i++)); do
        out="$(curl -sS --max-time "$HTTP_TIMEOUT_SECONDS" -o "$RUN_DIR/insights-body" \
            -w '%{http_code} %{time_total}' "$INSIGHTS_URL/$account" 2>>"$RUN_DIR/curl-error.log")" || true
        status="${out%% *}"
        seconds="${out#* }"
        if [[ "$status" != "200" ]]; then
            non200=$((non200 + 1))
        fi
        if [[ $i -gt $WARMUP_REQUESTS && "$seconds" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            echo "$seconds" >>"$RUN_DIR/insights-times"
        fi
    done

    timed=$(($(wc -l <"$RUN_DIR/insights-times")))
    p95="$(nearest_rank 95 "$RUN_DIR/insights-times")" || p95=""
    if [[ -z "$p95" ]] || ! p95_ms="$(seconds_to_ms "$p95")"; then
        R_INSIGHTS_VERDICT="FAIL"
        fail "insights p95 < 500 ms" "no request timing was recorded; $non200 of $total responses were not 200"
    else
        R_INSIGHTS_P95="$p95_ms ms"
        info "insights p95 $p95_ms ms over $timed timed requests (curl time_total through the reverse proxy)"
        if [[ $non200 -gt 0 ]]; then
            R_INSIGHTS_VERDICT="FAIL"
            fail "insights p95 < 500 ms" "$non200 of $total responses were not 200 (p95 $p95_ms ms)"
        elif [[ $(dec_to_units "$p95") -lt $(dec_to_units "$INSIGHTS_LIMIT_SECONDS") ]]; then
            R_INSIGHTS_VERDICT="PASS"
            pass "insights p95 < 500 ms"
        else
            R_INSIGHTS_VERDICT="FAIL"
            fail "insights p95 < 500 ms" "p95 $p95_ms ms is not below 500 ms"
        fi
    fi

    # Server-side share: the durations the broker logged for the last TIMED_REQUESTS requests.
    if ! broker_logs "$since" >"$RUN_DIR/insights.log"; then
        info "insights server share: broker-service logs unreadable (see $RUN_DIR/compose.log)"
        return 0
    fi
    : >"$RUN_DIR/insights-server-all"
    while IFS= read -r line; do
        if [[ "$line" =~ $INSIGHTS_DURATION_RE ]]; then
            echo "${BASH_REMATCH[1]}" >>"$RUN_DIR/insights-server-all"
        fi
    done < <(grep -F "Portfolio insights for account [$account]" "$RUN_DIR/insights.log" || true)
    lines=$(($(wc -l <"$RUN_DIR/insights-server-all")))
    tail -n "$TIMED_REQUESTS" "$RUN_DIR/insights-server-all" >"$RUN_DIR/insights-server"
    if [[ $lines -eq 0 ]]; then
        info "insights server share: no insights log line found for account [$account]"
        return 0
    fi
    median_ms="$(nearest_rank 50 "$RUN_DIR/insights-server")"
    server_p95_ms="$(nearest_rank 95 "$RUN_DIR/insights-server")"
    R_SERVER_SHARE="median $median_ms ms, p95 $server_p95_ms ms over $(($(wc -l <"$RUN_DIR/insights-server"))) logged requests"
    info "insights server share: $lines log lines, last $(($(wc -l <"$RUN_DIR/insights-server"))) used: median $median_ms ms, p95 $server_p95_ms ms"
}

# ---------------------------------------------------------------------------------------------
# Limit 2: one evaluation cycle < 10 s for 1,000 alerts

# rearm_missing: PATCHes {"enabled":true} on every owned alert missing from the armed set and
# records the returned armingRevision in the expected set. Sets REARM_ERROR on failure.
rearm_missing() {
    local id revision rearmed=0
    cut -d, -f1 "$RUN_DIR/expected" | LC_ALL=C sort >"$RUN_DIR/expected.ids"
    cut -d, -f1 "$RUN_DIR/armed" | LC_ALL=C sort >"$RUN_DIR/armed.ids"
    LC_ALL=C comm -23 "$RUN_DIR/expected.ids" "$RUN_DIR/armed.ids" >"$RUN_DIR/missing"
    while IFS= read -r id; do
        http PATCH "$ALERTS_URL/$id" '{"enabled":true}'
        revision="$(jget '.armingRevision // empty' "$HTTP_BODY")"
        if [[ "$HTTP_STATUS" != "200" || ! "$revision" =~ ^[0-9]+$ ]]; then
            REARM_ERROR="PATCH alert [$id] gave $(status_text)"
            return 1
        fi
        awk -F, -v id="$id" -v rev="$revision" 'BEGIN { OFS = "," } $1 == id { $2 = rev } { print }' \
            "$RUN_DIR/expected" >"$RUN_DIR/expected.new"
        mv "$RUN_DIR/expected.new" "$RUN_DIR/expected"
        rearmed=$((rearmed + 1))
    done <"$RUN_DIR/missing"
    info "re-armed $rearmed owned alerts missing from the armed set"
}

# verify_owned_set: the armed set must equal the expected owned set. Sets OWNED_ERROR.
verify_owned_set() {
    local difference
    if ! read_armed_set; then
        OWNED_ERROR="$ARMED_ERROR"
        return 1
    fi
    difference="$(armed_set_difference)"
    if [[ "$difference" != "0" ]]; then
        OWNED_ERROR="the armed set and the $(($(wc -l <"$RUN_DIR/expected"))) owned alerts differ in $difference id,revision rows"
        return 1
    fi
}

measure_cycle() {
    local count id problem listed shortfalls="" armed created=0 k type instrument held
    local instruments revisions rejected=0 reasons="" reason timeout units limit n after follow=""

    # Inputs: all presets hold every instrument, and every instrument is listed with a price.
    count=$(($(wc -l <"$RUN_DIR/presets")))
    if [[ $count -lt $PRESET_COUNT ]]; then
        fail "cycle inputs" "GET presets gave $PRESETS_STATUS with $count accounts, $PRESET_COUNT needed"
        return 0
    fi
    while IFS= read -r id; do
        problem=""
        if ! insights_profile "$id"; then
            problem="insights $PROFILE_STATUS, $PROFILE_ALLOCATIONS allocations, $PROFILE_HELD held"
        fi
        http GET "$BASE_URL/broker-service/v1/instrument?accountId=$id"
        listed="$(jget '(.results // []) | length' "$HTTP_BODY")"
        if [[ "$HTTP_STATUS" != "200" || "$listed" != "$HOLDINGS_EXPECTED" ]]; then
            problem="${problem:+$problem, }instrument listing $(status_text) with ${listed:-?} results"
        fi
        if [[ -n "$problem" ]]; then
            shortfalls="$shortfalls [$id] $problem;"
        fi
    done <"$RUN_DIR/presets"
    if [[ -n "$shortfalls" ]]; then
        fail "cycle inputs" "every preset must hold and list $HOLDINGS_EXPECTED instruments:$shortfalls"
        return 0
    fi
    pass "cycle inputs"

    if ! read_armed_set; then
        fail "cycle precondition" "$ARMED_ERROR"
        return 0
    fi
    armed=$(($(wc -l <"$RUN_DIR/armed")))
    if [[ $armed -ne 0 ]]; then
        fail "cycle precondition" "$armed armed alerts already exist; the measurement needs none besides its own"
        return 0
    fi
    pass "cycle precondition"

    # Workload: per account, 20 TARGET_PRICE then 20 PROFIT_LOSS alerts, round-robin over its
    # held instruments, all ABOVE the domain maximum.
    info "creating $ALERTS_EXPECTED alerts ($ALERTS_PER_ACCOUNT on each of $PRESET_COUNT accounts)"
    while IFS= read -r id; do
        instruments=()
        while IFS= read -r instrument; do
            instruments+=("$instrument")
        done <"$RUN_DIR/held-$id"
        held=${#instruments[@]}
        if [[ $held -ne $HOLDINGS_EXPECTED ]]; then
            fail "cycle workload" "account [$id] lists $held held instruments, $HOLDINGS_EXPECTED expected"
            return 0
        fi
        for ((k = 0; k < ALERTS_PER_ACCOUNT; k++)); do
            if [[ $k -lt $TARGET_PRICE_PER_ACCOUNT ]]; then
                type="TARGET_PRICE"
            else
                type="PROFIT_LOSS"
            fi
            instrument="${instruments[$((k % held))]}"
            if ! create_alert "$id" "$type" "$instrument" "ABOVE" "$MAX_THRESHOLD"; then
                fail "cycle workload" "alert $((created + 1)) of $ALERTS_EXPECTED ($type ABOVE $MAX_THRESHOLD on [$instrument] for account [$id]): $CREATE_ERROR"
                return 0
            fi
            created=$((created + 1))
            if [[ $((created % 100)) -eq 0 ]]; then
                info "created $created of $ALERTS_EXPECTED alerts"
            fi
        done
    done <"$RUN_DIR/presets"
    pass "cycle workload"

    revisions="$(cut -d, -f2 "$RUN_DIR/expected" | LC_ALL=C sort -u | tr '\n' ' ')"
    if ! verify_owned_set; then
        fail "cycle owned set" "$OWNED_ERROR"
        return 0
    fi
    if [[ "$revisions" != "1 " ]]; then
        fail "cycle owned set" "owned alerts carry revisions [${revisions% }], all must be 1"
        return 0
    fi
    pass "cycle owned set"

    # Samples: the first cycle over exactly the owned set. A sample with a trigger, skip,
    # failure or another outcome, or one after which the set changed, is rejected; triggered
    # alerts are re-armed and the next cycle is read. The workload itself never changes.
    timeout=$((2 * EVAL_INTERVAL + 30))
    while :; do
        CYCLE_T="$(now_rfc3339)"
        if ! open_log_window; then
            R_CYCLE_VERDICT="FAIL"
            fail "cycle < 10 s" "broker-service logs unreadable (see $RUN_DIR/compose.log)"
            return 0
        fi
        info "owned set verified at $CYCLE_T; waiting up to ${timeout}s for a cycle over $ALERTS_EXPECTED alerts"
        if ! wait_cycle_line "$LOG_BASE" "$timeout" "$ALERTS_EXPECTED"; then
            R_CYCLE_VERDICT="FAIL"
            fail "cycle < 10 s" "no cycle line rendered alerts [$ALERTS_EXPECTED] within ${timeout}s after $CYCLE_T${reasons:+; rejected: $reasons}"
            return 0
        fi
        parse_cycle_line "$CYCLE_LINE"
        reason=""
        if ! cycle_is_clean; then
            reason="cycle line shows $(cycle_summary_text)"
        fi
        if ! verify_owned_set; then
            reason="${reason:+$reason, }$OWNED_ERROR"
        fi
        if [[ -z "$reason" ]]; then
            break
        fi
        rejected=$((rejected + 1))
        R_CYCLE_REJECTIONS="$rejected"
        reasons="${reasons:+$reasons; }sample $rejected: $reason"
        info "cycle sample $rejected rejected: $reason"
        if [[ $rejected -ge $MAX_REJECTED_SAMPLES ]]; then
            R_CYCLE_VERDICT="FAIL"
            fail "cycle < 10 s" "no clean sample: $reasons"
            return 0
        fi
        if ! read_armed_set; then
            R_CYCLE_VERDICT="FAIL"
            fail "cycle < 10 s" "no clean sample: $ARMED_ERROR; $reasons"
            return 0
        fi
        if ! rearm_missing; then
            R_CYCLE_VERDICT="FAIL"
            fail "cycle < 10 s" "no clean sample: re-arming failed, $REARM_ERROR; $reasons"
            return 0
        fi
        if ! verify_owned_set; then
            R_CYCLE_VERDICT="FAIL"
            fail "cycle < 10 s" "no clean sample: after re-arming $OWNED_ERROR; $reasons"
            return 0
        fi
    done

    R_CYCLE_DURATION="$C_DURATION ms"
    info "accepted cycle sample: $(cycle_summary_text)"
    if ! units="$(dec_to_units "$C_DURATION")" || ! limit="$(dec_to_units "$CYCLE_LIMIT_MS")"; then
        R_CYCLE_VERDICT="FAIL"
        fail "cycle < 10 s" "unreadable duration [$C_DURATION]"
    elif [[ $units -lt $limit ]]; then
        R_CYCLE_VERDICT="PASS"
        pass "cycle < 10 s"
    else
        R_CYCLE_VERDICT="FAIL"
        fail "cycle < 10 s" "duration $C_DURATION ms is not below $CYCLE_LIMIT_MS ms"
    fi

    # Follow-ups: the next cycles after the accepted one, recorded but not judged.
    after="$CYCLE_INDEX"
    for ((n = 1; n <= FOLLOW_UP_CYCLES; n++)); do
        if ! wait_cycle_line "$after" $((EVAL_INTERVAL + 30)); then
            info "follow-up cycle $n: no cycle line within $((EVAL_INTERVAL + 30))s"
            follow="${follow:+$follow, }none"
            break
        fi
        after="$CYCLE_INDEX"
        parse_cycle_line "$CYCLE_LINE"
        if cycle_is_clean; then
            info "follow-up cycle $n: $C_DURATION ms"
            follow="${follow:+$follow, }$C_DURATION ms"
        else
            info "follow-up cycle $n not clean: $(cycle_summary_text)"
            follow="${follow:+$follow, }not clean"
        fi
    done
    R_FOLLOW_UPS="${follow:-n/a}"
}

# ---------------------------------------------------------------------------------------------
# Main

# shellcheck disable=SC2329 # Invoked by the INT and TERM traps below.
on_signal() {
    if [[ $IN_CREATE -eq 1 ]]; then
        PENDING_EXIT=130
        return 0
    fi
    exit 130
}

trap on_exit EXIT
trap on_signal INT TERM

STARTED_AT="$(now_rfc3339)"
info "run dir $RUN_DIR"
info "started $STARTED_AT: project [$PROJECT], base url $BASE_URL, compose file $COMPOSE_FILE"
setup
fetch_presets
measure_insights
measure_cycle
finish

