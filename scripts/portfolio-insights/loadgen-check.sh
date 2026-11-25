#!/usr/bin/env bash
# Loadgen live run of the Portfolio Insights demo feature, against one running Compose project.
# Run it from the repository root. On one build it makes three loadgen windows:
#   - run A: flag portfolio-insights-enabled off, PORTFOLIO_INSIGHTS_ALERT_WEIGHT 0, M minutes;
#   - run B: flag on, weight N, M minutes, then an audit of every alert the visit created;
#   - flag off at weight N, for at least 5 minutes.
# Both runs must complete every existing visit family (deposit_and_buy, deposit_and_long_buy,
# long_sell, sell_and_withdraw, order_credit_card). Run B must also complete
# portfolio_insights_alert without a failure, fail no existing visit name that run A did not
# fail, and leave none of its alerts in the database. With the flag off the visit must skip.
# The whole run takes roughly 2 x M + 20 minutes; the default M of 35 covers the rare
# order_credit_card visit, which loadgen schedules every 30 minutes.
#
# Usage: scripts/portfolio-insights/loadgen-check.sh --project NAME [--base-url URL]
#            [--compose-file FILE]... [--weight N] [--minutes M] [--out FILE]
#   --project NAME       Compose project of the running stack (required)
#   --base-url URL       Reverse-proxy URL of that stack (default: http://localhost)
#   --compose-file FILE  Compose file of that project, relative to the current directory
#                        (default: compose.dev.yaml); repeat it for override files
#   --weight N           Visit weight of run B and the flag-off phase (default: 1)
#   --minutes M          Length of runs A and B in minutes (default: 35)
#   --out FILE           Per-family markdown table (default: loadgen-families.md in the run dir)
#   --help               Show this help and exit
#
# One project per invocation. Never run it alongside e2e.sh or perf.sh: all three toggle the same
# flag, and perf.sh stops loadgen to measure with no visit running.
#
# What it touches: it toggles only portfolio-insights-enabled and restores it. It recreates
# loadgen with the weight passed through Compose interpolation of the existing
# PORTFOLIO_INSIGHTS_ALERT_WEIGHT declaration, set on that one command and never exported. It
# deletes, by id, only alerts loadgen logged as created and did not delete itself, and reads the
# Alerts table read-only through the db container's own client. On exit, normal or not, it
# restores the flag and recreates loadgen with its configured weight, running or stopped as it
# was at start. Run B's stop waits until no visit is between opening the page and its create
# outcome. A create cut off before loadgen logs its id by any other stop, such as an interrupt,
# cannot be tied to an id and is not deleted; an unconfirmed create is printed with its
# threshold marker.
#
# Prints one PASS or FAIL line per check, writes the per-family table to --out and ends with a
# SUMMARY line. Exits 0 when every check passes, 1 when any check fails, 2 on a usage error or a
# missing tool, and 130 on an interrupt. Working files stay in the run directory printed at
# start and end.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

FLAG_ID="portfolio-insights-enabled"
VISIT="portfolio_insights_alert"
# A visit name belongs to family f when it is f or starts with f_, so deposit_and_buy never
# takes in deposit_and_long_buy_*.
EXISTING_FAMILIES="deposit_and_buy deposit_and_long_buy long_sell sell_and_withdraw order_credit_card"
# The flag-off window lasts about 5 minutes, too short to wait for the 30-minute rare visit.
FLAG_OFF_FAMILIES="deposit_and_buy deposit_and_long_buy long_sell sell_and_withdraw"
# Always required on top of every service the compose files define besides loadgen.
CORE_SERVICES="broker-service db db-adapter feature-flag-service reverse-proxy"
READY_TIMEOUT_SECONDS=300
READY_STEP_SECONDS=5
HTTP_TIMEOUT_SECONDS=15
START_TIMEOUT_SECONDS=120
START_STEP_SECONDS=5
PROGRESS_STEP_SECONDS=60
BREAKDOWN_TIMEOUT_SECONDS=360
BREAKDOWN_STEP_SECONDS=15
QUIESCE_TIMEOUT_SECONDS=180
QUIESCE_STEP_SECONDS=5
FLAG_OFF_MIN_SECONDS=300
FLAG_OFF_TIMEOUT_SECONDS=900
FLAG_OFF_STEP_SECONDS=15
# Log windows open this far before T so a host clock ahead of the Docker engine loses no line.
# Each window follows a recreate of loadgen, whose new container holds no earlier output, so the
# margin never pulls in a line of another phase.
LOG_SKEW_MARGIN_SECONDS=30
# Cleanup stops sending DELETEs after this many transport errors in a row.
MAX_CONSECUTIVE_TRANSPORT_ERRORS=5
ID_CHUNK_SIZE=100
# Keeps minutes x 60 within shell arithmetic and a weight within loadgen's safe-integer check.
MAX_COUNT_DIGITS=9

# loadgen-core 1.3.36 line fragments. Lines read
# [YYYY-MM-DD HH:mm:ss+00:00][worker:..][visit:<name>][id:..][LEVEL]: message, and are matched
# by substring only.
STATS_MARKER="The loadgen has been running since ["
TIMEFRAME_MARKER="In the last ["
RUNNING_MARKER="Running visit ["
ERROR_MARKER="Worker had error when running visit"
SKIP_LINE="Flag [portfolio-insights-enabled] is off, skipping portfolio insights visit"
CREATED_MARKER="Created alert ["
LEFT_MARKER="] left in place: "
UNKNOWN_MARKER="outcome unknown"
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# ---------------------------------------------------------------------------------------------
# Options

usage() {
    cat <<'EOF'
Usage: scripts/portfolio-insights/loadgen-check.sh --project NAME [--base-url URL]
           [--compose-file FILE]... [--weight N] [--minutes M] [--out FILE]
  --project NAME       Compose project of the running stack (required)
  --base-url URL       Reverse-proxy URL of that stack (default: http://localhost)
  --compose-file FILE  Compose file of that project, relative to the current directory
                       (default: compose.dev.yaml). Repeat it, as with docker compose -f,
                       when the project was started with override files: loadgen is
                       recreated from exactly these files.
  --weight N           PORTFOLIO_INSIGHTS_ALERT_WEIGHT of run B and the flag-off phase, a
                       positive integer (default: 1); run A always uses 0
  --minutes M          Length of runs A and B in minutes, a positive integer (default: 35)
  --out FILE           Per-family markdown table (default: loadgen-families.md in the run dir)
  --help               Show this help and exit
Takes roughly 2 x M + 20 minutes. Run one project at a time, never alongside e2e.sh or perf.sh.
EOF
}

usage_error() {
    echo "$1" >&2
    usage >&2
    exit 2
}

# is_count TEXT: a positive integer of at most MAX_COUNT_DIGITS digits.
is_count() {
    [[ "$1" =~ ^[1-9][0-9]*$ && ${#1} -le $MAX_COUNT_DIGITS ]]
}

parse_options() {
    local file out_dir
    BASE_URL="http://localhost"
    COMPOSE_FILES=()
    PROJECT=""
    WEIGHT="1"
    MINUTES="35"
    OUT_FILE=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base-url | --compose-file | --project | --weight | --minutes | --out)
                if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
                    usage_error "Option $1 requires a value."
                fi
                case "$1" in
                    --base-url) BASE_URL="$2" ;;
                    --compose-file) COMPOSE_FILES+=("$2") ;;
                    --project) PROJECT="$2" ;;
                    --weight) WEIGHT="$2" ;;
                    --minutes) MINUTES="$2" ;;
                    --out) OUT_FILE="$2" ;;
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
    if ! is_count "$WEIGHT"; then
        usage_error "Option --weight needs a positive integer of at most $MAX_COUNT_DIGITS digits, got: $WEIGHT"
    fi
    if ! is_count "$MINUTES"; then
        usage_error "Option --minutes needs a positive integer of at most $MAX_COUNT_DIGITS digits, got: $MINUTES"
    fi
    # Several files are layered as docker compose -f layers them. A recreate from fewer files
    # than the project was started with would drop its overrides, its published ports included.
    if [[ ${#COMPOSE_FILES[@]} -eq 0 ]]; then
        COMPOSE_FILES=("compose.dev.yaml")
    fi
    COMPOSE_ARGS=()
    for file in "${COMPOSE_FILES[@]}"; do
        if [[ ! -f "$file" ]]; then
            usage_error "Compose file not found: $file (resolved from $(pwd); the repository root is $REPO_ROOT)"
        fi
        COMPOSE_ARGS+=(-f "$file")
    done
    if [[ -n "$OUT_FILE" ]]; then
        out_dir="$(dirname "$OUT_FILE")"
        if [[ ! -d "$out_dir" || ! -w "$out_dir" ]]; then
            usage_error "Directory of --out is missing or not writable: $out_dir"
        fi
    fi
}

check_tools() {
    local tool missing=""
    for tool in bash curl jq docker; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing="$missing $tool"
        fi
    done
    if [[ -n "$missing" ]]; then
        echo "Missing required tools:$missing" >&2
        exit 2
    fi
    if ! docker compose version >/dev/null 2>&1 </dev/null; then
        echo "The docker compose plugin is required (docker compose version failed)." >&2
        exit 2
    fi
}

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

# Fails a prerequisite check and ends the run; the EXIT trap still cleans up.
abort() {
    fail "$1" "$2"
    exit 1
}

# record_verdict LABEL FAMILY PASS|FAIL: the result of one check of FAMILY in phase LABEL, for
# the verdict column of the table.
record_verdict() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$RUN_DIR/verdicts"
}

# check_result PREFIX LABEL FAMILY CHECK OK DETAIL: PASS or FAIL "PREFIX CHECK" (just CHECK
# with an empty PREFIX), recorded as a verdict of FAMILY in phase LABEL. OK is 1 for a pass.
check_result() {
    local name="${1:+$1 }$4"
    if [[ "$5" == "1" ]]; then
        pass "$name${6:+: $6}"
        record_verdict "$2" "$3" PASS
    else
        fail "$name" "$6"
        record_verdict "$2" "$3" FAIL
    fi
}

# ---------------------------------------------------------------------------------------------
# HTTP and JSON

# http METHOD URL [BODY]: sets HTTP_STATUS (000 on a transport error), HTTP_CTYPE, HTTP_BODY and
# HTTP_ERROR (curl's message on a transport error). Never trips set -e. BODY goes through stdin.
http() {
    local method="$1" url="$2" out rc=0
    local args=(-sS --max-time "$HTTP_TIMEOUT_SECONDS" -X "$method"
        -o "$RUN_DIR/body" -D "$RUN_DIR/headers" -w '%{http_code} %{content_type}'
        -H 'Accept: application/json')
    : >"$RUN_DIR/body"
    : >"$RUN_DIR/headers"
    if [[ $# -ge 3 ]]; then
        args+=(-H 'Content-Type: application/json' --data-binary @-)
        out="$(printf '%s' "$3" | curl "${args[@]}" "$url" 2>"$RUN_DIR/curl-error")" || rc=$?
    else
        if [[ "$method" != "GET" && "$method" != "DELETE" ]]; then
            args+=(-H 'Content-Length: 0')
        fi
        out="$(curl "${args[@]}" "$url" 2>"$RUN_DIR/curl-error" </dev/null)" || rc=$?
    fi
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

lower() {
    tr '[:upper:]' '[:lower:]'
}

# join_lines: the lines of stdin on one line, separated by spaces.
join_lines() {
    paste -s -d ' ' - | tr -d '\r'
}

# ---------------------------------------------------------------------------------------------
# Docker, times and logs

# Arguments must reach docker unchanged: Git Bash would rewrite path-like ones to Windows paths.
# stdin is detached so docker never consumes the input of a surrounding read loop.
compose() {
    MSYS_NO_PATHCONV=1 docker compose -p "$PROJECT" "${COMPOSE_ARGS[@]}" "$@" </dev/null
}

# recreate_loadgen WEIGHT: recreates loadgen alone with PORTFOLIO_INSIGHTS_ALERT_WEIGHT=WEIGHT.
# The value reaches only this command, where it overrides the shell and .env for Compose's
# interpolation of the declaration both compose files carry.
recreate_loadgen() {
    PORTFOLIO_INSIGHTS_ALERT_WEIGHT="$1" MSYS_NO_PATHCONV=1 \
        docker compose -p "$PROJECT" "${COMPOSE_ARGS[@]}" up -d --no-deps --force-recreate loadgen \
        </dev/null >>"$RUN_DIR/compose.log" 2>&1
}

# restore_loadgen: recreates loadgen from the script's unmodified environment, so the weight the
# operator configured in the shell or in .env applies again, and leaves it running or stopped as
# it was at start. A loadgen stopped at start is recreated without being started rather than
# started and stopped: a visit run in between could create an alert and be cut off.
restore_loadgen() {
    if [[ $LOADGEN_WAS_RUNNING -eq 1 ]]; then
        compose up -d --no-deps --force-recreate loadgen >>"$RUN_DIR/compose.log" 2>&1
    else
        compose up --no-start --no-deps --force-recreate loadgen >>"$RUN_DIR/compose.log" 2>&1
    fi
}

# stop_loadgen: stops loadgen without a grace period. On SIGTERM Puppeteer closes the browser
# while node keeps running, so during the default 10 s grace every worker logs a browser-context
# error in a tight loop: hundreds of thousands of lines, enough to rotate the run's own lines out
# of compose.yaml's json-file logs. The visits a grace period would let finish are covered by the
# owned-id rules instead.
stop_loadgen() {
    compose stop --timeout 0 loadgen >>"$RUN_DIR/compose.log" 2>&1
}

running_services() {
    compose ps --status running --services 2>>"$RUN_DIR/compose.log" | tr -d '\r'
}

# container_env SERVICE NAME: the value of NAME in the service container's environment.
# Prints nothing when it is unset.
container_env() {
    local cid
    cid="$(compose ps -a -q "$1" 2>>"$RUN_DIR/compose.log" | tr -d '\r' | sed -n '1p')" || return 1
    if [[ -z "$cid" ]]; then
        return 1
    fi
    MSYS_NO_PATHCONV=1 docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$cid" </dev/null \
        | tr -d '\r' | sed -n "/^$2=/{s/^$2=//p;q;}"
}

now_rfc3339() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# epoch_to_rfc3339 EPOCH: GNU date first, then BSD date.
epoch_to_rfc3339() {
    date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

# loadgen_logs SINCE: loadgen output since SINCE, without colour codes or carriage returns.
loadgen_logs() {
    compose logs --no-color --no-log-prefix --since "$1" loadgen 2>>"$RUN_DIR/compose.log" \
        | sed "s/$(printf '\033')\[[0-9;]*m//g" | tr -d '\r'
}

# poll CHECK TIMEOUT STEP COMMAND [ARGS...]: runs COMMAND every STEP seconds until it succeeds or
# the deadline TIMEOUT seconds from now passes. On expiry it reports FAIL CHECK, with the
# POLL_DETAIL the last attempt left, and fails. STEP is the poll's only sleep; every wait in this
# script is such a fixed step under an explicit deadline.
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
# Stats breakdowns and visit families

# extract_breakdown FILE [LINE_FILE]: the detailed-breakdown JSON of the last cumulative stats
# line in FILE, {"<visit>":{"total":n,"avgDurationMs":ms,"failRate":f}}; that line itself goes
# to LINE_FILE. The "In the last [5m]" and "[1h]" timeframe lines are ignored. Fails when there
# is no such line or its JSON is not that shape.
extract_breakdown() {
    local line json
    line="$(grep -F "$STATS_MARKER" "$1" | grep -vF "$TIMEFRAME_MARKER" | tail -n 1)" || true
    if [[ -z "$line" ]]; then
        return 1
    fi
    json="$(sed -n 's/.*detailed breakdown \[\(.*\)\][[:space:]]*$/\1/p' <<<"$line")"
    if [[ -z "$json" ]] || ! jq -e 'type == "object" and all(.[];
            type == "object" and (.total | type) == "number" and (.failRate | type) == "number")' \
        >/dev/null 2>&1 <<<"$json"; then
        return 1
    fi
    if [[ -n "${2:-}" ]]; then
        printf '%s\n' "$line" >"$2"
    fi
    printf '%s\n' "$json" | tr -d '\r'
}

# latest_breakdown SINCE [LINE_FILE]: extract_breakdown over the loadgen output since SINCE.
latest_breakdown() {
    loadgen_logs "$1" >"$RUN_DIR/stats.log" || return 1
    extract_breakdown "$RUN_DIR/stats.log" "${2:-}"
}

# shellcheck disable=SC2329 # Invoked through poll.
# breakdown_since SINCE FILE: writes to FILE (NAME.json) the breakdown of a cumulative stats line
# stamped at or after SINCE, and that line to NAME.line.
breakdown_since() {
    local json
    if ! json="$(latest_breakdown "$1" "$RUN_DIR/stats.line")"; then
        POLL_DETAIL="no cumulative stats line stamped at or after $1"
        return 1
    fi
    printf '%s\n' "$json" >"$2"
    cp "$RUN_DIR/stats.line" "${2%.json}.line"
}

# The jq test of family membership, with the family in $f.
# shellcheck disable=SC2016 # $f is a jq variable, bound by --arg.
FAMILY_JQ='(. == $f or startswith($f + "_"))'

# family_names FAMILY JSON: the breakdown's visit names in FAMILY, one per line, sorted.
family_names() {
    jq -r --arg f "$1" "keys[] | select($FAMILY_JQ)" 2>/dev/null <<<"$2" | tr -d '\r' || true
}

# family_completions FAMILY JSON: completed visits of FAMILY. Per name, total x (1 - failRate) is
# rounded to the nearest integer, so a float such as 0.9999999999999998 counts as 1.
family_completions() {
    jq -r --arg f "$1" "[to_entries[] | select(.key | $FAMILY_JQ)
        | (.value.total * (1 - .value.failRate) + 0.5 | floor)] | add // 0" \
        2>/dev/null <<<"$2" | tr -d '\r' || true
}

# family_failing FAMILY JSON: the visit names of FAMILY with failRate > 0, one per line, sorted.
family_failing() {
    jq -r --arg f "$1" "to_entries[] | select((.key | $FAMILY_JQ) and .value.failRate > 0) | .key" \
        2>/dev/null <<<"$2" | tr -d '\r' | LC_ALL=C sort || true
}

# fail_rate NAME JSON: the failRate of visit NAME, or nothing when the breakdown lacks it.
fail_rate() {
    jq -r --arg n "$1" '.[$n].failRate // empty' 2>/dev/null <<<"$2" | tr -d '\r' || true
}

# family_of NAME: the expected family NAME belongs to, or "other".
family_of() {
    local family
    for family in $EXISTING_FAMILIES $VISIT; do
        if [[ "$1" == "$family" || "$1" == "${family}_"* ]]; then
            echo "$family"
            return 0
        fi
    done
    echo "other"
}

# error_counts_file FILE: "<count> <visit name>" per visit name, for the lines in FILE that record
# a visit error. They carry the visit's [visit:<name>] tag.
error_counts_file() {
    { grep -F "$ERROR_MARKER" "$1" || true; } | sed -n 's/.*\[visit:\([^]]*\)\].*/\1/p' \
        | LC_ALL=C sort | uniq -c | sed 's/^[[:space:]]*//'
}

# error_counts SINCE: error_counts_file over the loadgen output since SINCE.
error_counts() {
    loadgen_logs "$1" >"$RUN_DIR/errors.log" || return 1
    error_counts_file "$RUN_DIR/errors.log"
}

# ---------------------------------------------------------------------------------------------
# Alerts loadgen created

# created_ids FILE: ids of the "Created alert [<id>] threshold [..]" lines, lower-cased, sorted.
created_ids() {
    sed -nE 's/.*Created alert \[([0-9a-fA-F-]{36})\].*/\1/p' "$1" | lower | canonical_ids
}

# resolved_ids FILE: ids loadgen reported deleted through the UI or the API, or already absent.
resolved_ids() {
    sed -nE -e 's/.*Deleted alert \[([0-9a-fA-F-]{36})\] via (ui|api).*/\1/p' \
        -e 's/.*Alert \[([0-9a-fA-F-]{36})\] already absent.*/\1/p' "$1" | lower | canonical_ids
}

# canonical_ids: the canonical UUIDs of stdin, sorted and unique.
canonical_ids() {
    { grep -E "$UUID_RE" || true; } | LC_ALL=C sort -u
}

# unresolved_ids FILE: created ids in FILE with no resolution line in FILE.
unresolved_ids() {
    created_ids "$1" >"$RUN_DIR/ids.created"
    resolved_ids "$1" >"$RUN_DIR/ids.resolved"
    LC_ALL=C comm -23 "$RUN_DIR/ids.created" "$RUN_DIR/ids.resolved"
}

# own_unresolved FILE: adds every unresolved created id of FILE that is not owned yet to the owned
# list, which cleanup deletes through REST, and writes those ids to $RUN_DIR/new-owned.
own_unresolved() {
    unresolved_ids "$1" >"$RUN_DIR/ids.unresolved"
    LC_ALL=C sort -u "$RUN_DIR/owned" >"$RUN_DIR/owned.sorted"
    LC_ALL=C comm -23 "$RUN_DIR/ids.unresolved" "$RUN_DIR/owned.sorted" >"$RUN_DIR/new-owned"
    cat "$RUN_DIR/new-owned" >>"$RUN_DIR/owned"
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
    esac 2>>"$RUN_DIR/db-error.log" | tr -d '\r' | lower | sed '/^[[:space:]]*$/d'
}

# db_count_chunk 'ID'...: the number of Alerts rows whose Id is one of the quoted ids.
db_count_chunk() {
    local list sql out
    list="$(IFS=,; echo "$*")"
    if [[ "$DIALECT" == "mssql" ]]; then
        sql="SELECT COUNT(*) FROM [dbo].[Alerts] WHERE [Id] IN ($list)"
    else
        sql="SELECT COUNT(*) FROM \"Alerts\" WHERE \"Id\" IN ($list)"
    fi
    out="$(db_query "$sql")" || return 1
    if [[ ! "$out" =~ ^[0-9]+$ ]]; then
        echo "unexpected count output [$out]" >>"$RUN_DIR/db-error.log"
        return 1
    fi
    echo "$out"
}

# db_count_ids FILE: sets DB_COUNT to the number of Alerts rows carrying one of the ids in FILE,
# one id per line, counted ID_CHUNK_SIZE ids per query. Each id must be a canonical lower-case
# UUID before it is written into the SQL as a quoted literal. Sets DB_ERROR on failure.
db_count_ids() {
    local id n
    local -a chunk=()
    DB_COUNT=0
    DB_ERROR=""
    while IFS= read -r id || [[ -n "$id" ]]; do
        if [[ -z "$id" ]]; then
            continue
        fi
        if [[ ! "$id" =~ $UUID_RE ]]; then
            DB_ERROR="refusing id [$id]: not a canonical UUID"
            return 1
        fi
        chunk+=("'$id'")
        if [[ ${#chunk[@]} -ge $ID_CHUNK_SIZE ]]; then
            if ! n="$(db_count_chunk "${chunk[@]}")"; then
                DB_ERROR="count query failed: $(tail -n 3 "$RUN_DIR/db-error.log" | join_lines)"
                return 1
            fi
            DB_COUNT=$((DB_COUNT + n))
            chunk=()
        fi
    done <"$1"
    if [[ ${#chunk[@]} -gt 0 ]]; then
        if ! n="$(db_count_chunk "${chunk[@]}")"; then
            DB_ERROR="count query failed: $(tail -n 3 "$RUN_DIR/db-error.log" | join_lines)"
            return 1
        fi
        DB_COUNT=$((DB_COUNT + n))
    fi
}


# ---------------------------------------------------------------------------------------------
# Flag and loadgen windows

# set_flag CHECK VALUE: PUTs {"enabled": VALUE} and reads the flag back. PASS CHECK when the
# read-back equals VALUE; otherwise the run ends.
set_flag() {
    local check="$1" value="$2" read_back
    FLAG_TOUCHED=1
    http PUT "$FLAG_URL" "{\"enabled\": $value}"
    if [[ "$HTTP_STATUS" != "200" ]]; then
        abort "$check" "PUT {\"enabled\": $value} gave $(status_text)"
    fi
    http GET "$FLAG_URL"
    read_back="$(jget '.enabled' "$HTTP_BODY")"
    if [[ "$HTTP_STATUS" != "200" || "$read_back" != "$value" ]]; then
        abort "$check" "read-back gave $(status_text) with enabled [$read_back], expected $value"
    fi
    pass "$check"
}

# open_window PREFIX LABEL WEIGHT: recreates loadgen with WEIGHT and opens the log window of
# phase LABEL at T = now (WINDOW_START, WINDOW_START_EPOCH). PASS "PREFIX loadgen weight" once
# the new container carries WEIGHT.
open_window() {
    local prefix="$1" label="$2" weight="$3" actual
    WINDOW_LABEL="$label"
    WINDOW_START_EPOCH="$(date -u +%s)"
    WINDOW_START="$(epoch_to_rfc3339 "$WINDOW_START_EPOCH")"
    WINDOW_SINCE="$(epoch_to_rfc3339 $((WINDOW_START_EPOCH - LOG_SKEW_MARGIN_SECONDS)))"
    LOADGEN_TOUCHED=1
    WINDOW_OPEN=1
    if ! recreate_loadgen "$weight"; then
        abort "$prefix loadgen weight" "recreating loadgen with weight $weight failed (see $RUN_DIR/compose.log)"
    fi
    actual="$(container_env loadgen PORTFOLIO_INSIGHTS_ALERT_WEIGHT)" || actual=""
    if [[ "$actual" != "$weight" ]]; then
        abort "$prefix loadgen weight" "the recreated container has PORTFOLIO_INSIGHTS_ALERT_WEIGHT [$actual], expected [$weight]"
    fi
    pass "$prefix loadgen weight: $weight"
}

# close_window: stops loadgen, keeps the phase's whole output in $RUN_DIR/LABEL.log, writes the
# error-line counts of the stretch its breakdown covers to $RUN_DIR/errors-LABEL, and owns every
# alert the phase logged as created and never resolved, so cleanup deletes it. Sets CLOSE_ERROR
# on failure.
close_window() {
    local label="$WINDOW_LABEL" covered=""
    CLOSE_ERROR=""
    if ! stop_loadgen; then
        CLOSE_ERROR="compose stop loadgen failed (see $RUN_DIR/compose.log)"
        return 1
    fi
    WINDOW_OPEN=0
    if ! loadgen_logs "$WINDOW_SINCE" >"$RUN_DIR/$label.log"; then
        CLOSE_ERROR="loadgen logs since $WINDOW_SINCE unreadable (see $RUN_DIR/compose.log)"
        return 1
    fi
    # Error lines up to the breakdown's stats line, so the table's error column and its totals
    # describe the same stretch; without a breakdown, the whole window.
    if [[ -s "$RUN_DIR/breakdown-$label.line" ]]; then
        covered="$(grep -n -x -F -f "$RUN_DIR/breakdown-$label.line" "$RUN_DIR/$label.log" |
            sed -n '1s/:.*//p')" || covered=""
    fi
    if [[ -n "$covered" ]]; then
        head -n "$covered" "$RUN_DIR/$label.log" >"$RUN_DIR/$label.covered.log"
    else
        cp "$RUN_DIR/$label.log" "$RUN_DIR/$label.covered.log"
    fi
    error_counts_file "$RUN_DIR/$label.covered.log" >"$RUN_DIR/errors-$label"
    own_unresolved "$RUN_DIR/$label.log"
}

# close_or_abort PREFIX: close_window as the check "PREFIX loadgen stopped".
close_or_abort() {
    if ! close_window; then
        abort "$1 loadgen stopped" "$CLOSE_ERROR"
    fi
    pass "$1 loadgen stopped"
}

# report_new_owned PREFIX: one INFO line per id close_window has just owned.
report_new_owned() {
    local id
    while IFS= read -r id; do
        info "$1: alert [$id] was logged as created and never resolved by loadgen; it is deleted on exit"
    done <"$RUN_DIR/new-owned"
}

# shellcheck disable=SC2329 # Invoked through poll.
# window_started: whether loadgen logged a "Running visit [" line in the open window.
window_started() {
    local line
    if ! loadgen_logs "$WINDOW_SINCE" >"$RUN_DIR/start.log"; then
        POLL_DETAIL="loadgen logs unreadable (see $RUN_DIR/compose.log)"
        return 1
    fi
    line="$(grep -F "$RUNNING_MARKER" "$RUN_DIR/start.log" | head -n 1)" || true
    if [[ -z "$line" ]]; then
        POLL_DETAIL="no line contains [$RUNNING_MARKER] since $WINDOW_START"
        return 1
    fi
    STARTED_DETAIL="first visit [$(sed -n 's/.*Running visit \[\([^]]*\)\].*/\1/p' <<<"$line")]"
}

# watch_progress LABEL DEADLINE: until DEADLINE (epoch seconds), every PROGRESS_STEP_SECONDS,
# prints the latest cumulative breakdown's total per visit name and the error lines per name.
watch_progress() {
    local label="$1" deadline="$2" remaining elapsed json totals errors
    while :; do
        remaining=$((deadline - $(date -u +%s)))
        if [[ $remaining -le 0 ]]; then
            return 0
        fi
        sleep $((remaining < PROGRESS_STEP_SECONDS ? remaining : PROGRESS_STEP_SECONDS))
        elapsed=$((($(date -u +%s) - WINDOW_START_EPOCH) / 60))
        if ! loadgen_logs "$WINDOW_SINCE" >"$RUN_DIR/progress.log"; then
            info "run $label progress $elapsed/$MINUTES min: loadgen logs unreadable (see $RUN_DIR/compose.log)"
            continue
        fi
        totals="no stats line yet"
        if json="$(extract_breakdown "$RUN_DIR/progress.log")"; then
            totals="$(jget 'to_entries | map("\(.key)=\(.value.total)") | join(" ")' "$json")"
        fi
        errors="$(error_counts_file "$RUN_DIR/progress.log" |
            awk '{ printf "%s%s=%s", (NR > 1 ? " " : ""), $2, $1 }')"
        info "run $label progress $elapsed/$MINUTES min: totals [${totals:-none}] error lines [${errors:-none}]"
    done
}

# ---------------------------------------------------------------------------------------------
# Checks on breakdowns

# check_families PREFIX LABEL JSON FAMILY...: one check per FAMILY, PASS when it completed at
# least one visit.
check_families() {
    local prefix="$1" label="$2" json="$3" family completions names ok
    shift 3
    for family in "$@"; do
        completions="$(family_completions "$family" "$json")"
        names="$(family_names "$family" "$json" | join_lines)"
        ok=0
        if [[ "$completions" =~ ^[0-9]+$ && $completions -ge 1 ]]; then
            ok=1
        fi
        check_result "$prefix" "$label" "$family" "family $family" "$ok" \
            "${completions:-0} completed visits (names: ${names:-none})"
    done
}

# check_visit_fail_rate PREFIX LABEL JSON: PASS when portfolio_insights_alert ran with failRate 0.
check_visit_fail_rate() {
    local prefix="$1" label="$2" json="$3" rate
    rate="$(fail_rate "$VISIT" "$json")"
    if [[ -z "$rate" ]]; then
        check_result "$prefix" "$label" "$VISIT" "$VISIT failRate" 0 "visit not drawn"
    elif jq -e --arg n "$VISIT" '.[$n].failRate == 0' >/dev/null 2>&1 <<<"$json"; then
        check_result "$prefix" "$label" "$VISIT" "$VISIT failRate" 1 \
            "0 over $(jget ".$VISIT.total" "$json") visits"
    else
        check_result "$prefix" "$label" "$VISIT" "$VISIT failRate" 0 "failRate [$rate]"
    fi
}

# compare_failures: per existing family, the run B visit names with failRate > 0 must be a
# subset of run A's for that family.
compare_failures() {
    local a_json b_json family a_failing b_failing extra
    if [[ ! -s "$RUN_DIR/breakdown-A.json" ]]; then
        fail "run B comparison" "run A has no breakdown to compare with"
        return 0
    fi
    a_json="$(cat "$RUN_DIR/breakdown-A.json")"
    b_json="$(cat "$RUN_DIR/breakdown-B.json")"
    for family in $EXISTING_FAMILIES; do
        family_failing "$family" "$a_json" >"$RUN_DIR/failing-A"
        family_failing "$family" "$b_json" >"$RUN_DIR/failing-B"
        a_failing="$(join_lines <"$RUN_DIR/failing-A")"
        b_failing="$(join_lines <"$RUN_DIR/failing-B")"
        extra="$(LC_ALL=C comm -13 "$RUN_DIR/failing-A" "$RUN_DIR/failing-B" | join_lines)"
        if [[ -z "$extra" ]]; then
            check_result "run B" B "$family" "no new failures $family" 1 \
                "failing [${b_failing:-none}], run A failing [${a_failing:-none}]"
        else
            check_result "run B" B "$family" "no new failures $family" 0 \
                "failing in run B but not in run A: $extra"
        fi
    done
}


# ---------------------------------------------------------------------------------------------
# Setup

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

setup() {
    local defined required running missing="" service flag_id modifiable enabled
    if ! defined="$(compose config --services 2>>"$RUN_DIR/compose.log" | tr -d '\r')"; then
        abort "readiness" "docker compose config failed for project [$PROJECT] (see $RUN_DIR/compose.log)"
    fi
    if ! grep -qxF loadgen <<<"$defined"; then
        abort "readiness" "the compose files define no loadgen service"
    fi
    # Every service besides loadgen, not only the core five: the visits drive the whole
    # application, so a stopped service would fail families for a reason this run does not
    # measure.
    required="$( {
        grep -vxF loadgen <<<"$defined" || true
        tr ' ' '\n' <<<"$CORE_SERVICES"
    } | LC_ALL=C sort -u | join_lines)"
    running="$(running_services)" || running=""
    for service in $required; do
        if ! grep -qxF "$service" <<<"$running"; then
            missing="$missing $service"
        fi
    done
    if [[ -n "$missing" ]]; then
        abort "readiness" "services not running in project [$PROJECT]:$missing"
    fi
    if grep -qxF loadgen <<<"$running"; then
        LOADGEN_WAS_RUNNING=1
    fi
    if ! poll "readiness" "$READY_TIMEOUT_SECONDS" "$READY_STEP_SECONDS" readiness_once; then
        exit 1
    fi
    pass "readiness"

    DIALECT="$(container_env db-adapter DB_TYPE)" || DIALECT=""
    if [[ "$DIALECT" != "mssql" && "$DIALECT" != "postgres" ]]; then
        abort "runtime facts" "db-adapter DB_TYPE is [$DIALECT], expected mssql or postgres"
    fi
    pass "runtime facts"
    info "db type $DIALECT; loadgen running at start: $([[ $LOADGEN_WAS_RUNNING -eq 1 ]] && echo yes || echo no)"

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
}

# ---------------------------------------------------------------------------------------------
# Runs A and B

# run_window LABEL FLAG WEIGHT: run LABEL with the flag at FLAG and loadgen at WEIGHT for MINUTES
# minutes. Returns 0 with $RUN_DIR/breakdown-LABEL.json saved, 1 without a final breakdown, and
# 2 when loadgen never started a visit. The window stays open for the caller to close.
run_window() {
    local label="$1" flag="$2" weight="$3" prefix="run $1" deadline
    set_flag "$prefix flag $flag" "$flag"
    open_window "$prefix" "$label" "$weight"
    deadline=$((WINDOW_START_EPOCH + MINUTES * 60))
    info "$prefix: flag $flag, weight $weight, T $WINDOW_START, deadline $(epoch_to_rfc3339 "$deadline")"
    if ! poll "$prefix started" "$START_TIMEOUT_SECONDS" "$START_STEP_SECONDS" window_started; then
        info "$prefix: its remaining checks are skipped"
        return 2
    fi
    pass "$prefix started: $STARTED_DETAIL"
    watch_progress "$label" "$deadline"
    # Stats lines are cumulative since the container started, so the first one stamped at or
    # after the deadline covers the whole run.
    if ! poll "$prefix breakdown" "$BREAKDOWN_TIMEOUT_SECONDS" "$BREAKDOWN_STEP_SECONDS" \
        breakdown_since "$(epoch_to_rfc3339 "$deadline")" "$RUN_DIR/breakdown-$label.json"; then
        return 1
    fi
    pass "$prefix breakdown: saved to $RUN_DIR/breakdown-$label.json"
}

run_a() {
    local rc=0 json names ok=1
    run_window A false 0 || rc=$?
    if [[ $rc -eq 0 ]]; then
        json="$(cat "$RUN_DIR/breakdown-A.json")"
        # shellcheck disable=SC2086 # The family list splits into one argument per family.
        check_families "run A" A "$json" $EXISTING_FAMILIES
        names="$(family_names "$VISIT" "$json" | join_lines)"
        if [[ -n "$names" ]]; then
            ok=0
        fi
        check_result "run A" A "$VISIT" "no $VISIT" "$ok" "${names:+entries [$names] at weight 0}"
    fi
    close_or_abort "run A"
    report_new_owned "run A"
}

run_b() {
    local rc=0 json
    run_window B true "$WEIGHT" || rc=$?
    if [[ $rc -eq 0 ]]; then
        json="$(cat "$RUN_DIR/breakdown-B.json")"
        # shellcheck disable=SC2086 # The family list splits into one argument per family.
        check_families "run B" B "$json" $EXISTING_FAMILIES $VISIT
        compare_failures
        check_visit_fail_rate "run B" B "$json"
    fi
    if [[ $rc -eq 2 ]]; then
        close_or_abort "run B"
        report_new_owned "run B"
        return 0
    fi
    audit_owned_ids
}

# creates_in_flight FILE: how many portfolio_insights_alert visits in FILE have opened the page
# but logged no create outcome yet (created, unconfirmed, no instrument options, or a visit
# error). Stopping loadgen inside that stretch could leave an alert whose id was never logged.
creates_in_flight() {
    awk '
        index($0, "[visit:portfolio_insights_alert][id:") && match($0, /\[id:[^]]*\]/) {
            id = substr($0, RSTART, RLENGTH)
            if (index($0, "Opening portfolio insights page")) {
                open[id] = 1
            } else if (index($0, "Created alert [") || index($0, "Create unconfirmed threshold [") ||
                index($0, "Alert instrument options did not load") ||
                index($0, "Worker had error when running visit")) {
                open[id] = 0
            }
        }
        END { n = 0; for (id in open) if (open[id]) n++; print n }
    ' "$1"
}

# quiescent: whether every alert created in run B so far is resolved in loadgen's output and no
# visit is between opening the page and its create outcome. The created ids seen are written to
# $RUN_DIR/audited.
quiescent() {
    local in_flight
    if ! loadgen_logs "$WINDOW_SINCE" >"$RUN_DIR/quiesce.log"; then
        POLL_DETAIL="loadgen logs unreadable (see $RUN_DIR/compose.log)"
        return 1
    fi
    created_ids "$RUN_DIR/quiesce.log" >"$RUN_DIR/audited"
    unresolved_ids "$RUN_DIR/quiesce.log" >"$RUN_DIR/quiesce.unresolved"
    in_flight="$(creates_in_flight "$RUN_DIR/quiesce.log")"
    if [[ -s "$RUN_DIR/quiesce.unresolved" ]]; then
        POLL_DETAIL="unresolved: $(join_lines <"$RUN_DIR/quiesce.unresolved")"
        return 1
    fi
    if [[ "$in_flight" != "0" ]]; then
        POLL_DETAIL="$in_flight visits between opening the page and their create outcome"
        return 1
    fi
}

# audit_owned_ids: run B's owned-id audit. The audited set is fixed at the instant Q when every
# create seen so far is resolved, and loadgen stops right after Q. Q also waits for no visit to
# be between opening the page and its create outcome, so the stop cannot cut off a create whose
# id loadgen never logged.
audit_owned_ids() {
    local deadline quiet=0 id line count unresolved lines ok
    : >"$RUN_DIR/audited"
    POLL_DETAIL=""
    deadline=$(($(date -u +%s) + QUIESCE_TIMEOUT_SECONDS))
    while :; do
        if quiescent; then
            quiet=1
            break
        fi
        if [[ $(($(date -u +%s) + QUIESCE_STEP_SECONDS)) -gt $deadline ]]; then
            break
        fi
        sleep "$QUIESCE_STEP_SECONDS"
    done
    count=$(($(wc -l <"$RUN_DIR/audited")))
    if [[ $quiet -eq 1 ]]; then
        info "owned-id audit: Q at $(now_rfc3339) with $count created alerts, all resolved and no create in flight; stopping loadgen"
    else
        info "owned-id audit: not quiescent within ${QUIESCE_TIMEOUT_SECONDS}s (${POLL_DETAIL:-no detail}); stopping loadgen"
    fi
    close_or_abort "run B"

    # Creates logged after Q are excluded from the audit; close_window owned the unresolved ones.
    created_ids "$RUN_DIR/B.log" >"$RUN_DIR/ids.created.all"
    resolved_ids "$RUN_DIR/B.log" >"$RUN_DIR/ids.resolved.all"
    while IFS= read -r id; do
        if grep -qxF "$id" "$RUN_DIR/ids.resolved.all"; then
            info "created after Q and resolved before the stop, excluded: $id"
        else
            info "interrupted at stop $id"
        fi
    done < <(LC_ALL=C comm -13 "$RUN_DIR/audited" "$RUN_DIR/ids.created.all")

    unresolved="$(LC_ALL=C comm -23 "$RUN_DIR/audited" "$RUN_DIR/ids.resolved.all" | join_lines)"
    if [[ -z "$unresolved" ]]; then
        check_result "" B "$VISIT" "owned-id audit" 1 \
            "$count created alerts, each deleted via ui, via api or already absent"
    else
        check_result "" B "$VISIT" "owned-id audit" 0 \
            "not resolved by loadgen, deleted on exit: $unresolved"
    fi

    { grep -F -e "$LEFT_MARKER" -e "$UNKNOWN_MARKER" "$RUN_DIR/B.log" || true; } >"$RUN_DIR/outcomes"
    while IFS= read -r line; do
        info "outcome line: $line"
    done <"$RUN_DIR/outcomes"
    lines=$(($(wc -l <"$RUN_DIR/outcomes")))
    ok=0
    if [[ $lines -eq 0 ]]; then
        ok=1
    fi
    check_result "" B "$VISIT" "owned-id outcomes" "$ok" \
        "$lines lines report an alert left in place or an unknown outcome since $WINDOW_START"

    ok=0
    if [[ $count -ge 1 ]]; then
        ok=1
    fi
    check_result "" B "$VISIT" "owned-id created" "$ok" \
        "$count alerts created in run B$([[ $ok -eq 0 ]] && echo "; the visit never created an alert")"

    if [[ $count -eq 0 ]]; then
        info "owned-id rows: skipped, no audited id to count"
    elif ! db_count_ids "$RUN_DIR/audited"; then
        check_result "" B "$VISIT" "owned-id rows" 0 "$DB_ERROR"
    elif [[ $DB_COUNT -eq 0 ]]; then
        check_result "" B "$VISIT" "owned-id rows" 1 "no Alerts row carries any of the $count audited ids"
    else
        cat "$RUN_DIR/audited" >>"$RUN_DIR/owned"
        check_result "" B "$VISIT" "owned-id rows" 0 \
            "$DB_COUNT of $count audited ids still have an Alerts row; they are deleted on exit"
    fi
}

# ---------------------------------------------------------------------------------------------
# Flag off at weight N

flag_off_window() {
    local prefix="flag-off" label="B-flag-off" since remaining have=0 json skips created ok
    set_flag "$prefix flag false" false
    open_window "$prefix" "$label" "$WEIGHT"
    since="$(epoch_to_rfc3339 $((WINDOW_START_EPOCH + FLAG_OFF_MIN_SECONDS)))"
    remaining=$((WINDOW_START_EPOCH + FLAG_OFF_TIMEOUT_SECONDS - $(date -u +%s)))
    info "$prefix: flag false, weight $WEIGHT, T $WINDOW_START; waiting for a cumulative stats line stamped at or after $since"
    if poll "$prefix breakdown" "$remaining" "$FLAG_OFF_STEP_SECONDS" \
        breakdown_since "$since" "$RUN_DIR/breakdown-$label.json"; then
        pass "$prefix breakdown: saved to $RUN_DIR/breakdown-$label.json"
        have=1
    fi
    close_or_abort "$prefix"
    report_new_owned "$prefix"

    skips="$(grep -cF "$SKIP_LINE" "$RUN_DIR/$label.log" || true)"
    ok=0
    if [[ "${skips:-0}" -ge 1 ]]; then
        ok=1
    fi
    check_result "$prefix" "$label" "$VISIT" "skip line" "$ok" "${skips:-0} lines [$SKIP_LINE]"

    created="$(grep -cF "$CREATED_MARKER" "$RUN_DIR/$label.log" || true)"
    ok=0
    if [[ "${created:-0}" -eq 0 ]]; then
        ok=1
    fi
    check_result "$prefix" "$label" "$VISIT" "no alert created" "$ok" "${created:-0} lines [$CREATED_MARKER]"

    if [[ $have -eq 1 ]]; then
        json="$(cat "$RUN_DIR/breakdown-$label.json")"
        check_visit_fail_rate "$prefix" "$label" "$json"
        # shellcheck disable=SC2086 # The family list splits into one argument per family.
        check_families "$prefix" "$label" "$json" $FLAG_OFF_FAMILIES
    else
        info "$prefix: failRate and family checks skipped without a breakdown"
    fi
}

# ---------------------------------------------------------------------------------------------
# Table

# verdict_of LABEL FAMILY: FAIL when a check of FAMILY in phase LABEL failed, PASS when one
# passed and none failed, "not checked" otherwise.
verdict_of() {
    local results
    results="$(awk -F '\t' -v l="$1" -v f="$2" '$1 == l && $2 == f { print $3 }' "$RUN_DIR/verdicts")"
    if grep -qx FAIL <<<"$results"; then
        echo "FAIL"
    elif grep -qx PASS <<<"$results"; then
        echo "PASS"
    else
        echo "not checked"
    fi
}

# phase_families LABEL: the families phase LABEL is checked on.
phase_families() {
    case "$1" in
        A) echo "$EXISTING_FAMILIES" ;;
        B) echo "$EXISTING_FAMILIES $VISIT" ;;
        *) echo "$FLAG_OFF_FAMILIES $VISIT" ;;
    esac
}

# table_rows LABEL: one row per visit name of phase LABEL's breakdown, plus one per checked family
# the breakdown has no name of.
table_rows() {
    local label="$1" file="$RUN_DIR/breakdown-$1.json" json name total rate completions family errors
    if [[ ! -s "$file" ]]; then
        echo "| $label | - | - | - | - | - | - | no breakdown |"
        return 0
    fi
    json="$(cat "$file")"
    while IFS=$'\t' read -r name total rate completions; do
        family="$(family_of "$name")"
        errors="?"
        if [[ -f "$RUN_DIR/errors-$label" ]]; then
            errors="$(awk -v n="$name" '$2 == n { print $1 }' "$RUN_DIR/errors-$label")"
        fi
        echo "| $label | $family | $name | $total | $rate | $completions | ${errors:-0} | $(verdict_of "$label" "$family") |"
    done < <(jq -r 'to_entries[] | [.key, .value.total, .value.failRate,
        (.value.total * (1 - .value.failRate) + 0.5 | floor)] | @tsv' <<<"$json" | tr -d '\r')
    for family in $(phase_families "$label"); do
        if [[ -z "$(family_names "$family" "$json")" ]]; then
            echo "| $label | $family | - | 0 | - | 0 | 0 | $(verdict_of "$label" "$family") |"
        fi
    done
}

write_table() {
    local label
    TABLE_WRITTEN=1
    if {
        echo "# Loadgen live run"
        echo
        echo "Project \`$PROJECT\`, db type ${DIALECT:-unknown}, weight $WEIGHT, runs of $MINUTES minutes, started $STARTED_AT."
        echo
        echo "| run | family | visit name | total | failRate | completions | error lines | verdict |"
        echo "| --- | --- | --- | --- | --- | --- | --- | --- |"
        for label in A B B-flag-off; do
            table_rows "$label"
        done
    } >"$OUT_FILE" 2>>"$RUN_DIR/table-error.log"; then
        pass "table: $OUT_FILE"
    else
        fail "table" "could not write $OUT_FILE (see $RUN_DIR/table-error.log)"
    fi
}

finish_run() {
    write_table
    set_flag "flag restored" "$FLAG_INITIAL"
    exit 0
}

# ---------------------------------------------------------------------------------------------
# Cleanup. Every step is idempotent and runs on any exit, normal or not.

# remaining_owned: writes the owned ids not yet deleted to $RUN_DIR/to-delete and prints their
# number.
remaining_owned() {
    LC_ALL=C sort -u "$RUN_DIR/owned" >"$RUN_DIR/owned.sorted"
    LC_ALL=C sort -u "$RUN_DIR/deleted" >"$RUN_DIR/deleted.sorted"
    LC_ALL=C comm -23 "$RUN_DIR/owned.sorted" "$RUN_DIR/deleted.sorted" >"$RUN_DIR/to-delete"
    wc -l <"$RUN_DIR/to-delete" | tr -d ' '
}

# delete_remaining: DELETEs every owned id not yet deleted. 204 and 404 are clean; any other
# outcome is printed with its id and status. Sets CLEANUP_LEFT to the number left in place.
delete_remaining() {
    local id transport=0
    CLEANUP_LEFT=0
    while IFS= read -r id; do
        if [[ $transport -ge $MAX_CONSECUTIVE_TRANSPORT_ERRORS ]]; then
            info "cleanup left alert $id: not attempted after $transport transport errors in a row"
            CLEANUP_LEFT=$((CLEANUP_LEFT + 1))
            continue
        fi
        http DELETE "$ALERTS_URL/$id"
        case "$HTTP_STATUS" in
            204 | 404)
                transport=0
                echo "$id" >>"$RUN_DIR/deleted"
                ;;
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

# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() {
    local rc=$? remaining problems=""
    trap - EXIT
    set +e
    if [[ $WINDOW_OPEN -eq 1 ]]; then
        # A run ended mid-phase: loadgen stops first, so no visit runs while the flag is switched
        # for deletion, and whatever the phase created and did not resolve is owned.
        if close_window; then
            report_new_owned "cleanup"
        else
            problems="loadgen not stopped: $CLOSE_ERROR"
        fi
    fi
    if [[ $LOADGEN_TOUCHED -eq 1 && $TABLE_WRITTEN -eq 0 ]]; then
        write_table
    fi
    remaining="$(remaining_owned)"
    if [[ "$remaining" -gt 0 ]]; then
        # DELETE answers 403 while the flag is off, so the flag is switched on to delete.
        http GET "$FLAG_URL"
        if [[ "$HTTP_STATUS" == "200" && "$(jget '.enabled' "$HTTP_BODY")" == "false" ]]; then
            FLAG_TOUCHED=1
            http PUT "$FLAG_URL" '{"enabled": true}'
            info "cleanup: flag $FLAG_ID switched on to delete $remaining owned alerts ($(status_text))"
        fi
        delete_remaining
        info "cleanup: $((remaining - CLEANUP_LEFT)) of $remaining owned alerts deleted or already absent"
        if [[ $CLEANUP_LEFT -gt 0 ]]; then
            problems="${problems:+$problems; }$CLEANUP_LEFT owned alerts left in place"
        fi
    fi
    if [[ $FLAG_TOUCHED -eq 1 && -n "$FLAG_INITIAL" ]]; then
        http PUT "$FLAG_URL" "{\"enabled\": $FLAG_INITIAL}"
        if [[ "$HTTP_STATUS" == "200" && "$(jget '.enabled' "$HTTP_BODY")" == "$FLAG_INITIAL" ]]; then
            info "cleanup: flag $FLAG_ID restored to enabled=$FLAG_INITIAL"
        else
            problems="${problems:+$problems; }flag $FLAG_ID not restored to enabled=$FLAG_INITIAL: $(status_text)"
        fi
    fi
    if [[ $LOADGEN_TOUCHED -eq 1 ]]; then
        if restore_loadgen; then
            info "cleanup: loadgen recreated with its configured weight [$(container_env loadgen PORTFOLIO_INSIGHTS_ALERT_WEIGHT)], $([[ $LOADGEN_WAS_RUNNING -eq 1 ]] && echo running || echo "not started"), as at start"
        else
            problems="${problems:+$problems; }loadgen not restored (see $RUN_DIR/compose.log)"
        fi
    fi
    # A check of its own, as in perf.sh and e2e.sh: an alert left behind, a flag left changed or
    # loadgen left at a test weight fails the run even when every other check passed.
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

# ---------------------------------------------------------------------------------------------
# Main

main() {
    parse_options "$@"
    check_tools
    if ! RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pi-loadgen.XXXXXX")"; then
        echo "Could not create a run directory under ${TMPDIR:-/tmp}." >&2
        exit 2
    fi
    : >"$RUN_DIR/owned"
    : >"$RUN_DIR/deleted"
    : >"$RUN_DIR/new-owned"
    : >"$RUN_DIR/verdicts"
    OUT_FILE="${OUT_FILE:-$RUN_DIR/loadgen-families.md}"
    FLAG_URL="$BASE_URL/feature-flag-service/v1/flags/$FLAG_ID"
    ALERTS_URL="$BASE_URL/broker-service/v1/alerts"
    passed=0
    failed=0
    FLAG_INITIAL=""
    FLAG_TOUCHED=0
    LOADGEN_WAS_RUNNING=0
    LOADGEN_TOUCHED=0
    DIALECT=""
    WINDOW_OPEN=0
    WINDOW_LABEL=""
    WINDOW_SINCE=""
    TABLE_WRITTEN=0
    STARTED_AT="$(now_rfc3339)"

    trap cleanup EXIT
    trap 'exit 130' INT TERM
    info "run dir $RUN_DIR"
    info "started $STARTED_AT: project [$PROJECT], base url $BASE_URL, compose files [${COMPOSE_FILES[*]}], weight $WEIGHT, runs of $MINUTES minutes, table $OUT_FILE"
    setup
    run_a
    run_b
    flag_off_window
    finish_run
}

# Sourcing the file defines its functions without running it.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

