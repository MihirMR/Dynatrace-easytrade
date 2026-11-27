#!/usr/bin/env bash
# Loadgen live run of the Portfolio Insights demo feature, against one running Compose project.
# Run it from the repository root. On one build it makes three loadgen windows:
#   - run A: flag portfolio-insights-enabled off, PORTFOLIO_INSIGHTS_ALERT_WEIGHT 0, M minutes;
#   - run B: flag on, weight N, M minutes, then an audit of every alert the visit created;
#   - flag off at weight N, for at least 5 minutes.
# Every window must complete every existing visit family (deposit_and_buy, deposit_and_long_buy,
# long_sell, sell_and_withdraw, order_credit_card). Run B must also complete
# portfolio_insights_alert without a failure, fail no existing visit name that run A did not
# fail, and leave none of its alerts in the database. With the flag off the visit must skip.
# The whole run takes roughly 2 x M + 20 minutes. Each window recreates loadgen, and a fresh
# container draws the rare order_credit_card visit first and then every 30 minutes, so the
# default M of 35 covers two of its draws and the flag-off window one.
#
# Usage: scripts/portfolio-insights/loadgen-check.sh --project NAME [--base-url URL]
#            [--compose-file FILE]... [--weight N] [--minutes M] [--out FILE]
#        scripts/portfolio-insights/loadgen-check.sh --project NAME [--base-url URL]
#            [--compose-file FILE]... --resume-cleanup DIR
#   --project NAME       Compose project of the running stack (required)
#   --base-url URL       Reverse-proxy origin of that stack (default: http://localhost)
#   --compose-file FILE  Compose file of that project, relative to the current directory
#                        (default: compose.dev.yaml); repeat it for override files
#   --weight N           Visit weight of run B and the flag-off phase (default: 1)
#   --minutes M          Length of runs A and B in minutes (default: 35)
#   --out FILE           Per-family markdown table (default: loadgen-families.md in the run dir)
#   --resume-cleanup DIR Resume the owned-alert cleanup of the earlier run with run directory DIR
#                        instead of making a run (see Recovery below)
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
# restores the flag and puts loadgen back as it was at start: recreated with the
# PORTFOLIO_INSIGHTS_ALERT_WEIGHT its container had (set on that one command, or unset when it
# was unset), running or stopped as it was, or removed when the project had no loadgen
# container; the cleanup check fails unless the restored container matches. Run B ends at an
# instant Q when every alert it logged as created is resolved and no visit is between opening
# the page and its create outcome: loadgen is paused, its frozen output checked again, and
# killed while paused, so it logs and does nothing after Q. Run B's owned-id checks judge every
# create seen in any read of run B's output, and fail when the final output lost one, as log
# rotation can. A create cut off before loadgen logs its id by any other stop, such as an
# interrupt while loadgen runs, cannot be tied to an id and is not deleted; an unconfirmed
# create is printed with its threshold marker.
#
# Recovery: cleanup sends a DELETE that ends in a transport error up to three times, two seconds
# apart, and after five ids in a row with nothing but transport errors it stops sending them.
# Whatever it leaves stays recorded in the run directory: the file recovery names the project,
# base URL and Compose files of the run, owned lists every alert id the run owned and deleted
# every one a cleanup deleted or found absent. A cleanup that leaves alerts prints the command
# that resumes it, with --resume-cleanup and the run directory. That command, given the same
# --project and --base-url, checks them against the record and, through Docker, that the
# project's running reverse-proxy has its port 80 published where --base-url points, both before
# any request, so it never reaches another stack. It then reads the flag and DELETEs by id only
# the owned ids not yet deleted, switching the flag on while it is off and restoring it after,
# and adds each id it deletes to the deleted list, so it can be repeated until its cleanup check
# passes. It never creates an alert, never deletes by account, touches no loadgen and writes no
# table.
#
# Prints one PASS or FAIL line per check, writes the per-family table to --out and ends with a
# SUMMARY line. Exits 0 when every check passes, 1 when any check fails, 2 on a usage error, a
# missing tool or a run directory or stack --resume-cleanup refuses, and 130 on an interrupt.
# Working files stay in the run directory printed at start and end. The loadgen output kept there
# is reduced to the validated lines the checks read, so no DEBUG line, typed value or error detail
# is retained.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

FLAG_ID="portfolio-insights-enabled"
VISIT="portfolio_insights_alert"
# A visit name belongs to family f when it is f or starts with f_, so deposit_and_buy never
# takes in deposit_and_long_buy_*.
EXISTING_FAMILIES="deposit_and_buy deposit_and_long_buy long_sell sell_and_withdraw order_credit_card"
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
# A paused loadgen's output is read again every QUIESCE_FLUSH_STEP_SECONDS until two reads in a
# row match, so the log driver has stored every line written before the freeze.
QUIESCE_FLUSH_TIMEOUT_SECONDS=10
QUIESCE_FLUSH_STEP_SECONDS=1
FLAG_OFF_MIN_SECONDS=300
FLAG_OFF_TIMEOUT_SECONDS=900
FLAG_OFF_STEP_SECONDS=15
# Log windows open this far before T so a host clock ahead of the Docker engine loses no line.
# Each window follows a recreate of loadgen, whose new container holds no earlier output, so the
# margin never pulls in a line of another phase.
LOG_SKEW_MARGIN_SECONDS=30
# Every loadgen log read runs under timeout(1), so a Docker call that never answers cannot hold
# the run. Inside a poll or the quiescence wait it may take the time left to that wait's
# deadline; the closing read of a window may take this fixed bound, sized for a whole run's
# output, and a progress read the smaller of the two: this bound or the time left in its window.
# Each is a hard limit on the whole read, its termination included: TERM comes
# LOG_PROBE_KILL_SECONDS before the limit and KILL at it.
LOG_PROBE_TIMEOUT_SECONDS=120
LOG_PROBE_KILL_SECONDS=5
# The hard limit, termination included as for log reads, of every other Docker call the run B
# drain and the EXIT cleanup make: pausing, unpausing, stopping and killing loadgen
# (pause_loadgen, unpause_loadgen, stop_loadgen, kill_loadgen), restoring it (restore_loadgen)
# and reading container state (running_services, container_env, container_env_entry,
# loadgen_state), wherever those functions run. Inside the run B drain a pause, unpause or kill
# takes the time left before the drain's deadline instead when that is shorter, and none starts
# with no time left, so the drain ends by QUIESCE_TIMEOUT_SECONDS; the stop that follows it and
# the EXIT cleanup's calls each keep this bound of their own. Each takes seconds on a healthy
# engine. A call cut off is reported, and cleanup carries on with its other steps.
DOCKER_CALL_TIMEOUT_SECONDS=60
# Cleanup sends a DELETE that ends in a transport error again, CLEANUP_RETRY_STEP_SECONDS later,
# until it has made CLEANUP_RETRY_ATTEMPTS attempts; any answer is final. It stops sending DELETEs
# after MAX_CONSECUTIVE_TRANSPORT_ERRORS ids in a row whose every attempt ended in a transport
# error. One id takes at most CLEANUP_RETRY_ATTEMPTS x HTTP_TIMEOUT_SECONDS plus
# (CLEANUP_RETRY_ATTEMPTS - 1) x CLEANUP_RETRY_STEP_SECONDS, 49 s. The ids left stay owned in the
# run directory for --resume-cleanup.
CLEANUP_RETRY_ATTEMPTS=3
CLEANUP_RETRY_STEP_SECONDS=2
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
# The visit's other messages, which sanitize_loadgen_log also keeps.
OPENING_LINE="Opening portfolio insights page"
NO_OPTIONS_LINE="Alert instrument options did not load, no alert created"
# The visit's other no-create outcomes: the page did not open, or the feature was lost before
# submit, each while the feature is verifiably lost.
PAGE_UNAVAILABLE_LINE="Portfolio insights page unavailable, no alert created"
FEATURE_LOST_LINE="Portfolio insights feature lost before submit, no alert created"
UNCONFIRMED_MARKER="Create unconfirmed threshold ["
DELETED_MARKER="Deleted alert ["
ALERT_MARKER="Alert ["
ABSENT_TAIL="] already absent"
# The two outcome lines run B reports, as sanitize_loadgen_log keeps them: the id and status
# token of an alert left in place, and the threshold marker of an unconfirmed create.
LEFT_RE='\]: Alert \[([0-9a-fA-F-]{36})\] left in place: ([0-9]{3}|timeout|error)$'
UNCONFIRMED_RE='\]: Create unconfirmed threshold \[([0-9]+\.[0-9]+)\], outcome unknown$'

# ---------------------------------------------------------------------------------------------
# Options

usage() {
    cat <<'EOF'
Usage: scripts/portfolio-insights/loadgen-check.sh --project NAME [--base-url URL]
           [--compose-file FILE]... [--weight N] [--minutes M] [--out FILE]
       scripts/portfolio-insights/loadgen-check.sh --project NAME [--base-url URL]
           [--compose-file FILE]... --resume-cleanup DIR
  --project NAME       Compose project of the running stack (required)
  --base-url URL       Reverse-proxy origin of that stack (default: http://localhost)
  --compose-file FILE  Compose file of that project, relative to the current directory
                       (default: compose.dev.yaml). Repeat it, as with docker compose -f,
                       when the project was started with override files: loadgen is
                       recreated from exactly these files.
  --weight N           PORTFOLIO_INSIGHTS_ALERT_WEIGHT of run B and the flag-off phase, a
                       positive integer (default: 1); run A always uses 0
  --minutes M          Length of runs A and B in minutes, a positive integer (default: 35)
  --out FILE           Per-family markdown table (default: loadgen-families.md in the run dir)
  --resume-cleanup DIR Instead of a run, delete by id only the alerts that the earlier run with
                       run directory DIR owned and its cleanup left in place, then end. DIR must
                       be a run against the same --project and --base-url, and that project's
                       running reverse-proxy must have its port 80 published where --base-url
                       points; --weight, --minutes and --out are refused. No loadgen is touched
                       and no table written. A cleanup that leaves alerts prints this command;
                       repeat it until it passes.
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

parse_options() {
    local file out_dir run_option=""
    BASE_URL="http://localhost"
    COMPOSE_FILES=()
    PROJECT=""
    WEIGHT="1"
    MINUTES="35"
    OUT_FILE=""
    RESUME_RUN_DIR=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base-url | --compose-file | --project | --weight | --minutes | --out | --resume-cleanup)
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
                    --resume-cleanup) RESUME_RUN_DIR="$2" ;;
                esac
                # The first option that only a new run takes.
                case "$1" in
                    --weight | --minutes | --out) run_option="${run_option:-$1}" ;;
                esac
                shift 2
                ;;
            --help)
                usage
                exit 0
                ;;
            *)
                # Only a bare option name is echoed: a stray value or a --name=value argument can
                # be a URL that holds credentials.
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
    if [[ -n "$RESUME_RUN_DIR" && -n "$run_option" ]]; then
        usage_error "Option $run_option cannot be combined with --resume-cleanup, which takes only --project, --base-url and --compose-file."
    fi
    # The refused value is never echoed, since it can hold credentials.
    if ! is_base_origin "$BASE_URL"; then
        usage_error "Option --base-url needs an http:// or https:// origin: a host and optional port, without credentials, path, query or fragment."
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
    for tool in bash curl jq docker timeout; do
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

# docker_problem WHAT STATUS LIMIT: why the Docker call WHAT, run by hard_timeout with LIMIT,
# ended with STATUS, telling a call Docker did not answer in time from one that failed.
docker_problem() {
    case "$2" in
        124 | 137) echo "$1 timed out after $3 s (Docker did not answer)" ;;
        *) echo "$1 failed, exit $2 (see $RUN_DIR/compose.log)" ;;
    esac
}

# compose_within LIMIT ARGS...: compose ARGS run by hard_timeout, so the call has ended within
# LIMIT seconds, with status 124 or 137 when the limit cut it off. compose() cannot run under
# timeout(1), which needs a program, so its settings are repeated.
compose_within() {
    local limit="$1"
    shift
    hard_timeout "$limit" docker compose -p "$PROJECT" "${COMPOSE_ARGS[@]}" "$@" </dev/null
}

# recreate_loadgen WEIGHT [START [LIMIT]]: recreates loadgen alone with
# PORTFOLIO_INSIGHTS_ALERT_WEIGHT=WEIGHT, started when START is -d (the default) and only created
# when it is --no-start. The value reaches only this command, where it overrides the shell and
# .env for Compose's interpolation of the declaration both compose files carry. With LIMIT the
# call has ended within LIMIT seconds (compose_within), with status 124 or 137 when cut off.
# Without it, as when a window opens and Compose may first have to build or pull the image, the
# call is not bounded.
recreate_loadgen() {
    if [[ -n "${3:-}" ]]; then
        PORTFOLIO_INSIGHTS_ALERT_WEIGHT="$1" compose_within "$3" up "${2:--d}" --no-deps --force-recreate loadgen \
            >>"$RUN_DIR/compose.log" 2>&1
    else
        PORTFOLIO_INSIGHTS_ALERT_WEIGHT="$1" compose up "${2:--d}" --no-deps --force-recreate loadgen \
            >>"$RUN_DIR/compose.log" 2>&1
    fi
}

# restore_loadgen: puts loadgen back as setup recorded it in LOADGEN_AT_START and verifies the
# result; on failure it sets RESTORE_ERROR. A container that existed is recreated alone with the
# PORTFOLIO_INSIGHTS_ALERT_WEIGHT it had, set or unset on that one command, so neither this shell
# nor .env replaces a weight the operator set elsewhere. Its other settings come from the same
# --compose-file files, so the weight is the only interpolated value this run overrides. A loadgen
# stopped at start is recreated without being started rather than started and stopped: a visit
# run in between could create an alert and be cut off. Without a container at start, the one this
# run created is removed. Each Docker call has ended within DOCKER_CALL_TIMEOUT_SECONDS
# (hard_timeout), and RESTORE_ERROR tells a call Docker did not answer in time from one that failed.
restore_loadgen() {
    local start=-d entry actual rc=0
    RESTORE_ERROR=""
    if [[ "$LOADGEN_AT_START" == "no container" ]]; then
        compose_within "$DOCKER_CALL_TIMEOUT_SECONDS" rm --force --stop loadgen >>"$RUN_DIR/compose.log" 2>&1 ||
            rc=$?
        if [[ $rc -ne 0 ]]; then
            RESTORE_ERROR="$(docker_problem "removing the loadgen container this run created" "$rc" "$DOCKER_CALL_TIMEOUT_SECONDS")"
            return 1
        fi
    else
        if [[ $LOADGEN_WAS_RUNNING -eq 0 ]]; then
            start=--no-start
        fi
        entry="${LOADGEN_AT_START#*, }"
        if [[ "$entry" == PORTFOLIO_INSIGHTS_ALERT_WEIGHT=* ]]; then
            recreate_loadgen "${entry#PORTFOLIO_INSIGHTS_ALERT_WEIGHT=}" "$start" "$DOCKER_CALL_TIMEOUT_SECONDS" ||
                rc=$?
        else
            # Unset in a subshell, so only this command runs without it.
            (
                unset PORTFOLIO_INSIGHTS_ALERT_WEIGHT
                compose_within "$DOCKER_CALL_TIMEOUT_SECONDS" up "$start" --no-deps --force-recreate loadgen \
                    >>"$RUN_DIR/compose.log" 2>&1
            ) || rc=$?
        fi
        if [[ $rc -ne 0 ]]; then
            RESTORE_ERROR="$(docker_problem "recreating loadgen as [$(loadgen_state_text "$LOADGEN_AT_START")]" "$rc" "$DOCKER_CALL_TIMEOUT_SECONDS")"
            return 1
        fi
    fi
    # The x keeps a trailing line feed of the weight.
    actual="$(loadgen_state && printf x)" || rc=$?
    if [[ $rc -ne 0 ]]; then
        RESTORE_ERROR="$(docker_problem "reading loadgen's state after the restore" "$rc" "$DOCKER_CALL_TIMEOUT_SECONDS")"
        return 1
    fi
    actual="${actual%x}"
    if [[ "$actual" != "$LOADGEN_AT_START" ]]; then
        RESTORE_ERROR="expected [$(loadgen_state_text "$LOADGEN_AT_START")] as at start, got [$(loadgen_state_text "$actual")]"
        return 1
    fi
}

# stop_loadgen: stops loadgen without a grace period. On SIGTERM Puppeteer closes the browser
# while node keeps running, so during the default 10 s grace every worker logs a browser-context
# error in a tight loop: hundreds of thousands of lines, enough to rotate the run's own lines out
# of compose.yaml's json-file logs. The visits a grace period would let finish are covered by the
# owned-id rules instead. A paused loadgen is killed: compose stop thaws it to deliver SIGTERM, and
# it then logs, and acts, once more. The call has ended within DOCKER_CALL_TIMEOUT_SECONDS
# (hard_timeout), with status 124 or 137 when cut off.
stop_loadgen() {
    if [[ $LOADGEN_PAUSED -eq 1 ]]; then
        kill_loadgen
    else
        compose_within "$DOCKER_CALL_TIMEOUT_SECONDS" stop --timeout 0 loadgen >>"$RUN_DIR/compose.log" 2>&1
    fi
}

# pause_loadgen [LIMIT]: freezes every loadgen process, so loadgen neither logs nor acts until it
# is unpaused or killed. LOADGEN_PAUSED is set first, so a stop that cuts the pause short kills
# loadgen rather than thawing it. Bounded as stop_loadgen is, or by LIMIT seconds when given.
pause_loadgen() {
    LOADGEN_PAUSED=1
    compose_within "${1:-$DOCKER_CALL_TIMEOUT_SECONDS}" pause loadgen >>"$RUN_DIR/compose.log" 2>&1
}

# unpause_loadgen [LIMIT]: lets a paused loadgen run on. Bounded as stop_loadgen is, or by LIMIT
# seconds when given.
unpause_loadgen() {
    compose_within "${1:-$DOCKER_CALL_TIMEOUT_SECONDS}" unpause loadgen >>"$RUN_DIR/compose.log" 2>&1 || return
    LOADGEN_PAUSED=0
}

# kill_loadgen [LIMIT]: ends loadgen with SIGKILL. A paused loadgen dies without being thawed, so
# it logs nothing after the freeze. Killing a loadgen that no longer runs succeeds. Bounded as
# stop_loadgen is, or by LIMIT seconds when given.
kill_loadgen() {
    compose_within "${1:-$DOCKER_CALL_TIMEOUT_SECONDS}" kill -s SIGKILL loadgen >>"$RUN_DIR/compose.log" 2>&1 || return
    LOADGEN_PAUSED=0
}

# running_services: the project's running services, one per line. The call has ended within
# DOCKER_CALL_TIMEOUT_SECONDS (hard_timeout); one cut off fails the function with 124 or 137.
running_services() {
    compose_within "$DOCKER_CALL_TIMEOUT_SECONDS" ps --status running --services 2>>"$RUN_DIR/compose.log" |
        tr -d '\r'
}

# container_env SERVICE NAME: the value of NAME (which holds no "=") in the service container's
# environment, byte for byte: line feeds and carriage returns inside it and at its end included.
# The first entry named exactly NAME wins. jq hands the value over as base64, because jq on
# Windows writes text with CRLF line ends. Prints nothing when NAME is unset; fails when the
# service has no container. Capture it as "$(container_env S N && printf x)" and drop the x, so
# command substitution keeps any trailing line feed. Each Docker call has ended within
# DOCKER_CALL_TIMEOUT_SECONDS (hard_timeout); one cut off fails the function with 124 or 137.
container_env() {
    local cid encoded value
    cid="$(compose_within "$DOCKER_CALL_TIMEOUT_SECONDS" ps -a -q "$1" 2>>"$RUN_DIR/compose.log" |
        tr -d '\r' | sed -n '1p')" || return
    if [[ -z "$cid" ]]; then
        return 1
    fi
    encoded="$(hard_timeout "$DOCKER_CALL_TIMEOUT_SECONDS" docker inspect --format '{{json .Config.Env}}' "$cid" </dev/null \
        | jq -r --arg name "$2" 'first(.[]? | select(startswith($name + "="))) | ltrimstr($name + "=") | @base64')" \
        || return
    value="$(printf '%s' "$encoded" | tr -d '\r\n' | base64 -d && printf x)" || return 1
    printf '%s' "${value%x}"
}

# container_env_entry SERVICE NAME: the NAME=VALUE entry of the service container's environment,
# byte for byte, read from docker inspect's JSON and handed over as base64 as container_env does,
# so NAME set to an empty value still prints NAME=. Prints nothing when NAME is unset; fails when
# the service has no container or a Docker call fails. Capture it as
# "$(container_env_entry S N && printf x)" and drop the x. Each Docker call has ended within
# DOCKER_CALL_TIMEOUT_SECONDS (hard_timeout); one cut off fails the function with 124 or 137.
container_env_entry() {
    local cid encoded entry
    cid="$(compose_within "$DOCKER_CALL_TIMEOUT_SECONDS" ps -a -q "$1" 2>>"$RUN_DIR/compose.log" |
        tr -d '\r' | sed -n '1p')" || return
    if [[ -z "$cid" ]]; then
        return 1
    fi
    encoded="$(hard_timeout "$DOCKER_CALL_TIMEOUT_SECONDS" docker inspect --format '{{json .Config.Env}}' "$cid" \
        </dev/null 2>>"$RUN_DIR/compose.log" |
        jq -r --arg prefix "$2=" '(. // []) | map(select(startswith($prefix))) | .[0] // empty | @base64' \
            2>>"$RUN_DIR/compose.log")" || return
    entry="$(printf '%s' "$encoded" | tr -d '\r\n' | base64 -d && printf x)" || return 1
    printf '%s' "${entry%x}"
}

# loadgen_state: loadgen's container as setup records it and restore_loadgen verifies it, either
# "no container" or "running" or "stopped" followed by ", PORTFOLIO_INSIGHTS_ALERT_WEIGHT=VALUE"
# or ", PORTFOLIO_INSIGHTS_ALERT_WEIGHT unset", with VALUE byte for byte and no line feed after
# it. Capture it as "$(loadgen_state && printf x)" and drop the x; print it with
# loadgen_state_text. Fails when a Compose or docker inspect call fails, with 124 or 137 when
# DOCKER_CALL_TIMEOUT_SECONDS cut one off.
loadgen_state() {
    local cid running entry state="stopped"
    cid="$(compose_within "$DOCKER_CALL_TIMEOUT_SECONDS" ps -a -q loadgen 2>>"$RUN_DIR/compose.log" |
        tr -d '\r' | sed -n '1p')" || return
    if [[ -z "$cid" ]]; then
        printf '%s' "no container"
        return 0
    fi
    running="$(running_services)" || return
    entry="$(container_env_entry loadgen PORTFOLIO_INSIGHTS_ALERT_WEIGHT && printf x)" || return
    entry="${entry%x}"
    if grep -qxF loadgen <<<"$running"; then
        state="running"
    fi
    printf '%s, %s' "$state" "${entry:-PORTFOLIO_INSIGHTS_ALERT_WEIGHT unset}"
}

# loadgen_state_text STATE: STATE, a loadgen_state result, for a report line: the weight's value
# as printf %q writes it, so a value with control characters stays on one line, as $'...'.
loadgen_state_text() {
    if [[ "$1" != *", PORTFOLIO_INSIGHTS_ALERT_WEIGHT="* ]]; then
        printf '%s' "$1"
        return 0
    fi
    printf '%s, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=%q' "${1%%, *}" "${1#*, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=}"
}

now_rfc3339() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# epoch_to_rfc3339 EPOCH: GNU date first, then BSD date.
epoch_to_rfc3339() {
    date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

# loadgen_logs SINCE: loadgen output since SINCE, without colour codes or carriage returns,
# reduced by sanitize_loadgen_log to the lines this script reads. The read has ended, killed if
# need be, probe_limit seconds after it started (compose_within), and is never started once the
# wait's deadline has passed. On failure LOG_PROBE_DETAIL tells a read Docker did not answer in
# time from one that failed.
loadgen_logs() {
    local limit rc=0
    if ! limit="$(probe_limit)"; then
        # Only a poll, the run B drain or the progress watch sets a deadline, and its last
        # attempt can start just as the deadline passes. That attempt fails at once and keeps the
        # POLL_DETAIL of the attempt before it.
        LOG_PROBE_DETAIL="${POLL_DETAIL:-loadgen logs probe not started: no time left before the wait deadline}"
        return 1
    fi
    LOG_PROBE_DETAIL=""
    compose_within "$limit" logs --no-color --no-log-prefix --since "$1" loadgen 2>>"$RUN_DIR/compose.log" \
        | sed "s/$(printf '\033')\[[0-9;]*m//g" | tr -d '\r' | sanitize_loadgen_log || rc=$?
    case "$rc" in
        0) return 0 ;;
        124 | 137) LOG_PROBE_DETAIL="loadgen logs probe timed out after $limit s (Docker did not answer)" ;;
        *) LOG_PROBE_DETAIL="loadgen logs unreadable, exit $rc (see $RUN_DIR/compose.log)" ;;
    esac
    return 1
}

# probe_limit: the seconds a log read may take now, the time left to PROBE_DEADLINE inside a
# bounded wait and LOG_PROBE_TIMEOUT_SECONDS outside one. Fails when the deadline has passed.
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

# sanitize_loadgen_log: keeps only the stdin lines this script reads, each rebuilt from validated
# fields, and drops every other line. Raw loadgen output must never reach the run directory or
# the report: at DEBUG, loadgen-core logs every value a visit types, the preset users' login
# passwords included, and visit errors carry free text. A kept line has a validated timestamp,
# the tags [worker:<n>] with an optional [visit:<name>][id:<uuid>], or [stats:<name>], the level
# INFO, WARN or ERROR, and one of these messages:
#   - Running visit [<name>], or Worker had error when running visit without its error detail;
#   - the visit's skip, opening, no-options, page-unavailable, feature-lost, created,
#     unconfirmed, deleted and already-absent lines, or Alert [<id>] left in place: <status>, a
#     status other than a 3-digit HTTP status or timeout becoming error;
#   - the cumulative or timeframe stats line, whose breakdown holds numeric fields per visit name.
# Anything else in a kept line is unchanged byte for byte, so a stats line reads the same in
# every file.
sanitize_loadgen_log() {
    LC_ALL=C awk -v stats="$STATS_MARKER" -v timeframe="$TIMEFRAME_MARKER" \
        -v running="$RUNNING_MARKER" -v visit_error="$ERROR_MARKER" -v skip="$SKIP_LINE" \
        -v created="$CREATED_MARKER" -v left="$LEFT_MARKER" -v unknown="$UNKNOWN_MARKER" \
        -v opening="$OPENING_LINE" -v no_options="$NO_OPTIONS_LINE" \
        -v page_unavailable="$PAGE_UNAVAILABLE_LINE" -v feature_lost="$FEATURE_LOST_LINE" \
        -v unconfirmed="$UNCONFIRMED_MARKER" -v deleted="$DELETED_MARKER" \
        -v alert="$ALERT_MARKER" -v absent="$ABSENT_TAIL" '
        # rep(s, n): s repeated n times. Patterns avoid interval operators, which some awks lack.
        function rep(s, n,   r) {
            r = ""
            while (n-- > 0) {
                r = r s
            }
            return r
        }
        function starts(s, p) {
            return substr(s, 1, length(p)) == p
        }
        # after(s, p): s without its first length(p) characters.
        function after(s, p) {
            return substr(s, length(p) + 1)
        }
        # worker_message(m): m, or its projection, when it is a visit message this script reads.
        function worker_message(m,   rest, id, status) {
            if (m == skip || m == opening || m == no_options || m == page_unavailable ||
                m == feature_lost || m == visit_error) {
                return m
            }
            if (starts(m, visit_error ":")) {
                return visit_error
            }
            if (starts(m, running)) {
                return after(m, running) ~ ("^" name "[]]$") ? m : ""
            }
            if (starts(m, created)) {
                return after(m, created) ~ ("^" uuid "[]] threshold [[]" marker "[]]$") ? m : ""
            }
            if (starts(m, unconfirmed)) {
                rest = after(m, unconfirmed)
                if (match(rest, "^" marker "[]], ") && substr(rest, RLENGTH + 1) == unknown) {
                    return m
                }
                return ""
            }
            if (starts(m, deleted)) {
                return after(m, deleted) ~ ("^" uuid "[]] via (ui|api)$") ? m : ""
            }
            if (starts(m, alert) && match(after(m, alert), "^" uuid)) {
                rest = after(m, alert)
                id = substr(rest, 1, RLENGTH)
                rest = substr(rest, RLENGTH + 1)
                if (rest == absent) {
                    return m
                }
                if (starts(rest, left)) {
                    status = after(rest, left)
                    if (status !~ ("^" d d d "$") && status != "timeout") {
                        status = "error"
                    }
                    return alert id left status
                }
            }
            return ""
        }
        # stats_line(m, rest, head): m when rest is head, then a valid breakdown and "]".
        function stats_line(m, rest, head,   json) {
            if (!match(rest, head)) {
                return ""
            }
            json = substr(rest, RLENGTH + 1)
            if (substr(json, length(json)) != "]") {
                return ""
            }
            return substr(json, 1, length(json) - 1) ~ breakdown ? m : ""
        }
        function stats_message(m) {
            if (starts(m, stats)) {
                return stats_line(m, after(m, stats), cumulative)
            }
            if (starts(m, timeframe)) {
                return stats_line(m, after(m, timeframe), last)
            }
            return ""
        }
        BEGIN {
            d = "[0-9]"
            h = "[0-9a-fA-F]"
            uuid = rep(h, 8) "-" rep(h, 4) "-" rep(h, 4) "-" rep(h, 4) "-" rep(h, 12)
            name = "[a-z0-9_]+"
            marker = d "+[.]" d "+"
            level = "[[](INFO|WARN|ERROR)[]]: "
            stamp = "^[[]" rep(d, 4) "-" rep(d, 2) "-" rep(d, 2) " " rep(d, 2) ":" rep(d, 2) ":" \
                rep(d, 2) "[-+]" rep(d, 2) ":" rep(d, 2) "[]]"
            worker_tags = "^[[]worker:" d "+[]]([[]visit:" name "[]][[]id:" uuid "[]])?" level
            stats_tags = "^[[]stats:[a-z]+[]]" level
            number = "-?(0|[1-9]" d "*)([.]" d "+)?([eE][-+]?" d "+)?"
            field = "\"[A-Za-z]+\":" number
            entry = "\"" name "\":[{]" field "(," field ")*[}]"
            breakdown = "^[{](" entry "(," entry ")*)?[}]$"
            counts = d "+[]] visits with fail rate [[]" d "+[.]" d "+[]] and a rate of [[]" \
                d "+[.]" d "+/[a-z]+[]], detailed breakdown [[]"
            cumulative = "^[A-Z][a-z][a-z], " d d " [A-Z][a-z][a-z] " d "+ " d d ":" d d ":" d d \
                " GMT[]] and generated [[]" counts
            last = "^" d "+([.]" d "+)?[a-z]+[]] loadgen has generated [[]" counts
        }
        {
            if (!match($0, stamp)) {
                next
            }
            prefix = substr($0, 1, RLENGTH)
            rest = substr($0, RLENGTH + 1)
            if (match(rest, worker_tags)) {
                tags = substr(rest, 1, RLENGTH)
                out = worker_message(substr(rest, RLENGTH + 1))
            } else if (match(rest, stats_tags)) {
                tags = substr(rest, 1, RLENGTH)
                out = stats_message(substr(rest, RLENGTH + 1))
            } else {
                next
            }
            if (out != "") {
                print prefix tags out
            }
        }
    '
}

# report_outcomes FILE: one INFO line per line of FILE, an outcome line of run B. Only parsed
# fields are printed: the id and status token of an alert left in place, or the threshold marker
# of an unconfirmed create. A line in neither form gets a fixed notice, never its text.
report_outcomes() {
    local line id status
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ $LEFT_RE ]]; then
            status="${BASH_REMATCH[2]}"
            id="$(lower <<<"${BASH_REMATCH[1]}")"
            if [[ "$id" =~ $UUID_RE ]]; then
                info "outcome: alert [$id] left in place: $status"
                continue
            fi
        elif [[ "$line" =~ $UNCONFIRMED_RE ]]; then
            info "outcome: unconfirmed create, threshold [${BASH_REMATCH[1]}], outcome unknown"
            continue
        fi
        info "outcome: a line in no known outcome form, not printed"
    done <"$1"
}

# poll CHECK TIMEOUT STEP COMMAND [ARGS...]: runs COMMAND every STEP seconds until it succeeds or
# the deadline TIMEOUT seconds from now passes. An attempt starts only while time is left before
# the deadline, and a success seen in the deadline's second or later does not count. The clock is
# whole epoch seconds, rounded down, so the deadline, the start's second plus TIMEOUT, is at most
# TIMEOUT after the real start, and a success seen before that second ended within TIMEOUT. On
# expiry it reports FAIL CHECK, with the POLL_DETAIL the last attempt left, and fails, as it does
# for a late success. STEP is the poll's only sleep, never taken when no time would be left after
# it; every wait in this script is such a fixed step under an explicit deadline. COMMAND's log
# reads and readiness requests see the deadline as PROBE_DEADLINE, local to this call, so it ends
# with the poll.
poll() {
    local check="$1" timeout="$2" step="$3" deadline now late
    shift 3
    deadline=$(($(date -u +%s) + timeout))
    local PROBE_DEADLINE="$deadline"
    POLL_DETAIL=""
    while :; do
        if [[ $(date -u +%s) -ge $deadline ]]; then
            fail "$check" "deadline $timeout s expired${POLL_DETAIL:+; $POLL_DETAIL}"
            return 1
        fi
        if "$@"; then
            now="$(date -u +%s)"
            if [[ $now -ge $deadline ]]; then
                late=""
                if [[ $now -gt $deadline ]]; then
                    late=", $((now - deadline)) s late"
                fi
                fail "$check" "attempt succeeded at or after the deadline of $timeout s$late"
                return 1
            fi
            return 0
        fi
        # After the sleep no time would be left for an attempt.
        if [[ $(($(date -u +%s) + step)) -ge $deadline ]]; then
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
# stamped at or after SINCE, and that line to NAME.line. The breakdown goes through a file, not
# a command substitution, so the probe's LOG_PROBE_DETAIL reaches POLL_DETAIL.
breakdown_since() {
    if ! latest_breakdown "$1" "$RUN_DIR/stats.line" >"$RUN_DIR/stats.json"; then
        POLL_DETAIL="${LOG_PROBE_DETAIL:-no cumulative stats line stamped at or after $1}"
        return 1
    fi
    cp "$RUN_DIR/stats.json" "$2"
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

# canonical_ids: the canonical UUIDs of stdin, sorted and unique. Fails when stdin cannot be read:
# grep exits 1 when no line matches, and above 1 when it fails.
canonical_ids() {
    { grep -E "$UUID_RE" || [[ $? -eq 1 ]]; } | LC_ALL=C sort -u
}

# unresolved_ids FILE: created ids in FILE with no resolution line in FILE.
unresolved_ids() {
    created_ids "$1" >"$RUN_DIR/ids.created"
    resolved_ids "$1" >"$RUN_DIR/ids.resolved"
    LC_ALL=C comm -23 "$RUN_DIR/ids.created" "$RUN_DIR/ids.resolved"
}

# owned_id_violations FILE: where FILE, one read of a window's output, breaks the visit's
# one-to-one ownership, as "<id> <reason>" lines in log order. A visit logging with the tags
# [visit:portfolio_insights_alert][id:<visit id>] owns the one alert it logged as created, and
# that visit alone resolves it, once and after the create. The reasons: created without the
# visit tag, created again, second create of its visit, resolved without the visit tag, resolved
# again, resolved by another visit, resolved before its create, resolved without a create. Alert
# and visit ids compare lower-cased. A line whose alert id is not a canonical UUID is not read, as
# created_ids and resolved_ids skip it. Only canonical ids and those fixed reasons are printed,
# never a line's text.
owned_id_violations() {
    LC_ALL=C awk -v tag="[visit:$VISIT][id:" '
        # rep(s, n): s repeated n times. Patterns avoid interval operators, which some awks lack.
        function rep(s, n,   r) {
            r = ""
            while (n-- > 0) {
                r = r s
            }
            return r
        }
        # id_at(s, p): the 36 characters of s from position p, lower-cased, when they are a
        # canonical UUID followed by "]"; otherwise "".
        function id_at(s, p,   id) {
            id = tolower(substr(s, p, 36))
            if (id ~ uuid && substr(s, p + 36, 1) == "]") {
                return id
            }
            return ""
        }
        # breach(id, reason): a violation, kept in log order. An empty reason is settled at the
        # end, once every create is known.
        function breach(id, reason) {
            n++
            ids[n] = id
            reasons[n] = reason
        }
        BEGIN {
            h = "[0-9a-f]"
            uuid = "^" rep(h, 8) "-" rep(h, 4) "-" rep(h, 4) "-" rep(h, 4) "-" rep(h, 12) "$"
            n = 0
        }
        {
            kind = ""
            id = ""
            if ((p = index($0, "Created alert [")) > 0) {
                kind = "created"
                id = id_at($0, p + 15)
            } else if ((p = index($0, "Deleted alert [")) > 0) {
                rest = substr($0, p + 51)
                if (substr(rest, 1, 8) == "] via ui" || substr(rest, 1, 9) == "] via api") {
                    kind = "resolved"
                    id = id_at($0, p + 15)
                }
            } else if ((p = index($0, "Alert [")) > 0) {
                if (substr($0, p + 43, 16) == "] already absent") {
                    kind = "resolved"
                    id = id_at($0, p + 7)
                }
            }
            if (id == "") {
                next
            }
            visit = ""
            if ((t = index($0, tag)) > 0) {
                visit = id_at($0, t + length(tag))
            }
            if (kind == "created") {
                if (visit == "") {
                    breach(id, "created without the visit tag")
                } else if (id in creator) {
                    breach(id, "created again")
                } else if (visit in creates) {
                    breach(id, "second create of its visit")
                }
                if (!(id in creator)) {
                    creator[id] = visit
                }
                if (visit != "") {
                    creates[visit] = 1
                }
                next
            }
            if (visit == "") {
                breach(id, "resolved without the visit tag")
            } else if (id in resolved) {
                breach(id, "resolved again")
            } else if (!(id in creator)) {
                breach(id, "")
            } else if (creator[id] != "" && creator[id] != visit) {
                # A create without the visit tag is already a violation of its own.
                breach(id, "resolved by another visit")
            }
            resolved[id] = 1
        }
        END {
            for (i = 1; i <= n; i++) {
                if (reasons[i] == "") {
                    if (ids[i] in creator) {
                        reasons[i] = "resolved before its create"
                    } else {
                        reasons[i] = "resolved without a create"
                    }
                }
                print ids[i] " " reasons[i]
            }
        }
    ' "$1"
}

# observe_window FILE: adds the created and resolved ids of FILE, one read of the open window's
# output, to the window's observed sets, so an id stays known after log rotation drops its lines
# from a later read. The first read holding a line records that line as the window's first line.
# Fails when a step fails, so a read whose ids went unrecorded never passes for an observed one.
observe_window() {
    local first="$RUN_DIR/observed-first-$WINDOW_LABEL"
    created_ids "$1" >>"$RUN_DIR/observed-created-$WINDOW_LABEL" || return 1
    resolved_ids "$1" >>"$RUN_DIR/observed-resolved-$WINDOW_LABEL" || return 1
    if [[ ! -s "$first" ]]; then
        head -n 1 "$1" >"$first" || return 1
    fi
}

# observed_ids created|resolved: the ids of that kind any read of the open window's output saw,
# sorted and unique; none when no read was observed. Fails when the observed set exists but
# cannot be read.
observed_ids() {
    local file="$RUN_DIR/observed-$1-$WINDOW_LABEL"
    if [[ -e "$file" ]]; then
        canonical_ids <"$file"
    fi
}

# read_window FILE: the open window's output since WINDOW_SINCE into FILE, observed by
# observe_window. Fails, with LOG_PROBE_DETAIL, when the output is unreadable or recording its
# ids fails.
read_window() {
    loadgen_logs "$WINDOW_SINCE" >"$1" || return 1
    if ! observe_window "$1"; then
        LOG_PROBE_DETAIL="recording the alert ids of this read of loadgen's output in $RUN_DIR failed"
        return 1
    fi
}

# window_ids FILE: writes the ids created in FILE, the open window's final output, or in any
# earlier read of it to $RUN_DIR/ids.created.union, and the ids resolved there to
# $RUN_DIR/ids.resolved.union. Fails when a step fails, so a union file it leaves may be
# incomplete and must not be read as the window's ids.
window_ids() {
    { created_ids "$1" && observed_ids created; } | canonical_ids >"$RUN_DIR/ids.created.union" ||
        return 1
    { resolved_ids "$1" && observed_ids resolved; } | canonical_ids >"$RUN_DIR/ids.resolved.union" ||
        return 1
}

# own_unresolved FILE: adds to the owned list, which cleanup deletes through REST, every id not
# owned yet that FILE, the open window's final output, or an earlier read of that window logged
# as created and none logged as resolved, and writes those ids to $RUN_DIR/new-owned. Fails when
# a step fails, so close_window leaves the window to cleanup, which owns them again; owning
# again adds no id that is owned already.
own_unresolved() {
    : >"$RUN_DIR/new-owned" || return 1
    window_ids "$1" || return 1
    LC_ALL=C comm -23 "$RUN_DIR/ids.created.union" "$RUN_DIR/ids.resolved.union" \
        >"$RUN_DIR/ids.unresolved" || return 1
    LC_ALL=C sort -u "$RUN_DIR/owned" >"$RUN_DIR/owned.sorted" || return 1
    LC_ALL=C comm -23 "$RUN_DIR/ids.unresolved" "$RUN_DIR/owned.sorted" >"$RUN_DIR/new-owned" ||
        return 1
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
    if ! out="$(db_query "$sql")"; then
        # sqlcmd reports SQL errors on stdout, so a failed query's output joins the error log.
        if [[ -n "$out" ]]; then
            printf '%s\n' "$out" >>"$RUN_DIR/db-error.log"
        fi
        return 1
    fi
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
    # The x keeps a trailing line feed of the value; printf %q prints a value with control
    # characters on one line, as $'...'.
    actual="$(container_env loadgen PORTFOLIO_INSIGHTS_ALERT_WEIGHT && printf x)" || actual=""
    actual="${actual%x}"
    if [[ "$actual" != "$weight" ]]; then
        abort "$prefix loadgen weight" "the recreated container has PORTFOLIO_INSIGHTS_ALERT_WEIGHT [${actual:+$(printf '%q' "$actual")}], expected [$weight]"
    fi
    pass "$prefix loadgen weight: $weight"
}

# close_window [STOPPED]: stops loadgen, unless STOPPED is 1 because the caller has already
# killed it, keeps the phase's whole output in $RUN_DIR/LABEL.log, writes the error-line counts of
# the stretch its breakdown covers to $RUN_DIR/errors-LABEL, and owns every alert the phase logged
# as created and never resolved, in that output or an earlier read of it, so cleanup deletes it.
# The lines after the breakdown's stats line, through the stop, are the phase's late stretch:
# visits the breakdown does not count. When that output holds the stats line, they go to
# $RUN_DIR/LABEL.late.log and their error-line counts to $RUN_DIR/errors-late-LABEL; otherwise,
# or when a step extracting them fails, the stretch stays unknown (late_known). A failed step for
# the covered stretch leaves $RUN_DIR/errors-LABEL absent, its counts unknown.
# It owns those alerts, and writes the ids it has just owned to $RUN_DIR/new-owned, on every
# outcome: when the stop fails, from the earlier reads alone, since loadgen may still run; when
# the final read fails, from those reads and whatever lines the failed read gave. Fails with
# CLOSE_ERROR when the stop, the read or recording the owned ids failed. The stop and the read
# are tracked apart: WINDOW_OPEN stays 1 while the stop is not confirmed, and WINDOW_UNREAD stays
# 1 until the final output has been read and its alerts owned. An exit before then, as on INT or
# TERM, leaves the window to cleanup, which reads the stopped loadgen's output again and owns
# them; owning again adds no id that is owned already.
close_window() {
    local label="$WINDOW_LABEL" covered="" rc=0 stop_call="compose stop loadgen" found=1
    local stretches="covered late" stretch part counts status unknown=""
    local err="$RUN_DIR/close-error.log"
    CLOSE_ERROR=""
    WINDOW_UNREAD=1
    rm -f "$RUN_DIR/$label.late.log" "$RUN_DIR/errors-late-$label" "$RUN_DIR/errors-$label"
    if [[ "${1:-0}" != "1" ]]; then
        if [[ $LOADGEN_PAUSED -eq 1 ]]; then
            stop_call="compose kill loadgen"
        fi
        stop_loadgen || rc=$?
        if [[ $rc -ne 0 ]]; then
            CLOSE_ERROR="$(docker_problem "$stop_call" "$rc" "$DOCKER_CALL_TIMEOUT_SECONDS")"
            own_unresolved /dev/null
            return 1
        fi
    fi
    WINDOW_OPEN=0
    if ! loadgen_logs "$WINDOW_SINCE" >"$RUN_DIR/$label.log"; then
        CLOSE_ERROR="reading the window since $WINDOW_SINCE: $LOG_PROBE_DETAIL"
        # A cut-off read keeps only lines the sanitizer validated, so each create it holds is real.
        own_unresolved "$RUN_DIR/$label.log"
        return 1
    fi
    # Error lines up to the breakdown's stats line, so the table's error column and its totals
    # describe the same stretch; without a breakdown, the whole window. The lines after it make
    # the late stretch, which the verdicts read too, so each judges its run through the stop.
    # close_or_abort runs this with errexit off, so each step's status is checked. A stretch's
    # lines and counts are written beside their place and moved there, the counts last, once
    # every step for that stretch has succeeded. A failed step leaves the stretch absent, so the
    # table shows its error lines as unknown and the late verdicts fail (late_known) rather than
    # read a cut-off stretch as one without errors. INFO says so; close-error.log holds why.
    if [[ -s "$RUN_DIR/breakdown-$label.line" ]]; then
        # grep exits 1 when no line matches, and above 1 when it fails.
        found=0
        covered="$(grep -n -x -F -f "$RUN_DIR/breakdown-$label.line" "$RUN_DIR/$label.log" \
            2>>"$err" | sed -n '1s/:.*//p')" || found=$?
        if [[ $found -eq 0 && ! "$covered" =~ ^[0-9]+$ ]]; then
            found=2
        fi
    fi
    case $found in
        0)
            head -n "$covered" "$RUN_DIR/$label.log" >"$RUN_DIR/$label.covered.part" 2>>"$err" ||
                unknown="covered"
            tail -n "+$((covered + 1))" "$RUN_DIR/$label.log" >"$RUN_DIR/$label.late.part" \
                2>>"$err" || unknown="${unknown:+$unknown }late"
            ;;
        1)
            # No breakdown, or its stats line is not in this output: the whole window is the
            # covered stretch, and the late one stays unknown unless there is no breakdown.
            stretches="covered"
            cp "$RUN_DIR/$label.log" "$RUN_DIR/$label.covered.part" 2>>"$err" || unknown="covered"
            ;;
        *)
            unknown="covered late"
            ;;
    esac
    for stretch in $stretches; do
        if [[ " $unknown " == *" $stretch "* ]]; then
            continue
        fi
        part="$RUN_DIR/$label.$stretch"
        counts="$RUN_DIR/errors-$label"
        if [[ "$stretch" == "late" ]]; then
            counts="$RUN_DIR/errors-late-$label"
        fi
        # error_counts_file's counts, with grep's "no error line" (1) told apart from a failure.
        status=0
        grep -F "$ERROR_MARKER" "$part.part" >"$part.errors" 2>>"$err" || status=$?
        if [[ $status -le 1 ]]; then
            status=0
            { sed -n 's/.*\[visit:\([^]]*\)\].*/\1/p' "$part.errors" | LC_ALL=C sort | uniq -c |
                sed 's/^[[:space:]]*//' >"$part.counts"; } 2>>"$err" || status=$?
        fi
        if [[ $status -eq 0 ]]; then
            mv -f "$part.part" "$part.log" 2>>"$err" || status=$?
        fi
        if [[ $status -eq 0 ]]; then
            mv -f "$part.counts" "$counts" 2>>"$err" || status=$?
        fi
        if [[ $status -ne 0 ]]; then
            rm -f "$part.log" "$counts"
            unknown="${unknown:+$unknown }$stretch"
        fi
    done
    if [[ " $unknown " == *" covered "* ]]; then
        info "window $label: its error-line counts for the table are unknown: extracting them from its final output failed (see $err)"
    fi
    if [[ " $unknown " == *" late "* ]]; then
        info "window $label: the visits after the breakdown, through the stop, are unknown: extracting them from its final output failed (see $err)"
    fi
    if ! own_unresolved "$RUN_DIR/$label.log"; then
        CLOSE_ERROR="recording the window's unresolved alert ids in $RUN_DIR/owned failed"
        return 1
    fi
    # Last, once its alerts are owned: until here an exit leaves the window to cleanup.
    WINDOW_UNREAD=0
}

# close_or_abort PREFIX [STOPPED]: close_window STOPPED as the check "PREFIX loadgen stopped". On
# failure the ids close_window has just owned are reported before the run ends.
close_or_abort() {
    if ! close_window "${2:-0}"; then
        report_new_owned "$1"
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
    if ! read_window "$RUN_DIR/start.log"; then
        POLL_DETAIL="$LOG_PROBE_DETAIL"
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
# The window ends at DEADLINE, and the breakdown poll and close_window read its final state right
# after, each under its own bound. So every progress read ends by DEADLINE: it may take
# LOG_PROBE_TIMEOUT_SECONDS, or the time left before DEADLINE when that is shorter. A read due
# with no time left, as the last one usually is, is skipped with an INFO line and no failure.
watch_progress() {
    local label="$1" deadline="$2" remaining now elapsed json totals errors
    # A read's cap is PROBE_DEADLINE, local to this call so it ends with the watch. POLL_DETAIL is
    # local and empty, so a read that finds no time left says so rather than echo a poll's detail.
    local PROBE_DEADLINE="" POLL_DETAIL=""
    while :; do
        remaining=$((deadline - $(date -u +%s)))
        if [[ $remaining -le 0 ]]; then
            return 0
        fi
        sleep $((remaining < PROGRESS_STEP_SECONDS ? remaining : PROGRESS_STEP_SECONDS))
        now="$(date -u +%s)"
        elapsed=$(((now - WINDOW_START_EPOCH) / 60))
        if [[ $now -ge $deadline ]]; then
            info "run $label progress $elapsed/$MINUTES min: read skipped at the window end; the breakdown and the window's closing read follow"
            return 0
        fi
        PROBE_DEADLINE=$((now + LOG_PROBE_TIMEOUT_SECONDS < deadline ? now + LOG_PROBE_TIMEOUT_SECONDS : deadline))
        if ! read_window "$RUN_DIR/progress.log"; then
            info "run $label progress $elapsed/$MINUTES min: $LOG_PROBE_DETAIL"
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

# A breakdown is the last stats snapshot before the deadline, and loadgen runs on until its
# window closes. Each visit that fails logs one worker error line, so the failures after the
# snapshot are the error lines of the late stretch close_window records. The checks below judge a
# run through its stop, and fail with LATE_UNKNOWN when that stretch is unknown.
LATE_UNKNOWN="the visits after the breakdown, through the stop, are unknown: the window's final output lacks the breakdown's stats line, or they could not be extracted from it"
# The checks fail with LATE_UNREAD when close_window recorded that stretch but reading its record
# failed, so a failed read never passes for a stretch without errors.
LATE_UNREAD="the visits after the breakdown, through the stop, are unknown: reading the record close_window kept of them failed"

# late_known LABEL: whether phase LABEL's late stretch is known: close_window read the window's
# final output, found the breakdown's stats line in it and recorded the lines after it and their
# error-line counts, every step succeeding. A phase without a breakdown has no late stretch.
late_known() {
    [[ ! -s "$RUN_DIR/breakdown-$1.line" || -f "$RUN_DIR/errors-late-$1" ]]
}

# late_error_count LABEL NAME: the error lines visit NAME logged in phase LABEL's late stretch.
# Fails, printing nothing, when the recorded counts cannot be read.
late_error_count() {
    local count=""
    if [[ -f "$RUN_DIR/errors-late-$1" ]]; then
        count="$(awk -v n="$2" '$2 == n { print $1 }' "$RUN_DIR/errors-late-$1")" || return 1
    fi
    echo "${count:-0}"
}

# late_failing LABEL FAMILY: the visit names of FAMILY with an error line in phase LABEL's late
# stretch, one per line, sorted. Fails when the recorded counts cannot be read.
late_failing() {
    if [[ -f "$RUN_DIR/errors-late-$1" ]]; then
        awk -v f="$2" '$2 == f || index($2, f "_") == 1 { print $2 }' "$RUN_DIR/errors-late-$1" |
            LC_ALL=C sort -u
    fi
}

# check_visit_fail_rate PREFIX LABEL JSON: PASS when portfolio_insights_alert ran with failRate 0
# in phase LABEL's breakdown JSON and logged no visit error after it, through the stop.
check_visit_fail_rate() {
    local prefix="$1" label="$2" json="$3" rate total late
    rate="$(fail_rate "$VISIT" "$json")"
    if [[ -z "$rate" ]]; then
        check_result "$prefix" "$label" "$VISIT" "$VISIT failRate" 0 "visit not drawn"
    elif ! jq -e --arg n "$VISIT" '.[$n].failRate == 0' >/dev/null 2>&1 <<<"$json"; then
        check_result "$prefix" "$label" "$VISIT" "$VISIT failRate" 0 "failRate [$rate]"
    else
        total="$(jget ".$VISIT.total" "$json")"
        if ! late_known "$label"; then
            check_result "$prefix" "$label" "$VISIT" "$VISIT failRate" 0 \
                "failRate 0 over $total visits at the breakdown, but $LATE_UNKNOWN"
        elif ! late="$(late_error_count "$label" "$VISIT")"; then
            check_result "$prefix" "$label" "$VISIT" "$VISIT failRate" 0 \
                "failRate 0 over $total visits at the breakdown, but $LATE_UNREAD"
        elif [[ "$late" != "0" ]]; then
            check_result "$prefix" "$label" "$VISIT" "$VISIT failRate" 0 \
                "failRate 0 over $total visits at the breakdown, but $late visit errors after it, through the stop"
        elif [[ -f "$RUN_DIR/errors-late-$label" ]]; then
            check_result "$prefix" "$label" "$VISIT" "$VISIT failRate" 1 \
                "0 over $total visits, and no visit error after the breakdown, through the stop"
        else
            check_result "$prefix" "$label" "$VISIT" "$VISIT failRate" 1 "0 over $total visits"
        fi
    fi
}

# compare_failures: per existing family, the run B visit names that failed must be a subset of
# run A's for that family. Both runs are judged through their stop: a name failed when its
# breakdown failRate is above 0 or it logged a visit error in the run's late stretch. While
# either run's late stretch is unknown, every family's check fails, and a family's check fails
# when reading either run's late record for it fails.
compare_failures() {
    local a_json b_json family a_failing b_failing extra late_a late_b late unknown="" unread
    if [[ ! -s "$RUN_DIR/breakdown-A.json" ]]; then
        fail "run B comparison" "run A has no breakdown to compare with"
        return 0
    fi
    a_json="$(cat "$RUN_DIR/breakdown-A.json")"
    b_json="$(cat "$RUN_DIR/breakdown-B.json")"
    if ! late_known A; then
        unknown="run A"
    fi
    if ! late_known B; then
        unknown="${unknown:+$unknown and }run B"
    fi
    for family in $EXISTING_FAMILIES; do
        if [[ -n "$unknown" ]]; then
            check_result "run B" B "$family" "no new failures $family" 0 "$unknown: $LATE_UNKNOWN"
            continue
        fi
        unread=""
        late_failing A "$family" >"$RUN_DIR/late-failing-A" || unread="run A"
        late_failing B "$family" >"$RUN_DIR/late-failing-B" || unread="${unread:+$unread and }run B"
        if [[ -n "$unread" ]]; then
            check_result "run B" B "$family" "no new failures $family" 0 "$unread: $LATE_UNREAD"
            continue
        fi
        { family_failing "$family" "$a_json"; cat "$RUN_DIR/late-failing-A"; } | LC_ALL=C sort -u \
            >"$RUN_DIR/failing-A"
        { family_failing "$family" "$b_json"; cat "$RUN_DIR/late-failing-B"; } | LC_ALL=C sort -u \
            >"$RUN_DIR/failing-B"
        a_failing="$(join_lines <"$RUN_DIR/failing-A")"
        b_failing="$(join_lines <"$RUN_DIR/failing-B")"
        late_a="$(join_lines <"$RUN_DIR/late-failing-A")"
        late_b="$(join_lines <"$RUN_DIR/late-failing-B")"
        late=""
        if [[ -n "$late_a$late_b" ]]; then
            late="; failing after the breakdown, through the stop: run B [${late_b:-none}], run A [${late_a:-none}]"
        fi
        extra="$(LC_ALL=C comm -13 "$RUN_DIR/failing-A" "$RUN_DIR/failing-B" | join_lines)"
        if [[ -z "$extra" ]]; then
            check_result "run B" B "$family" "no new failures $family" 1 \
                "failing [${b_failing:-none}], run A failing [${a_failing:-none}]$late"
        else
            check_result "run B" B "$family" "no new failures $family" 0 \
                "failing in run B but not in run A: $extra$late"
        fi
    done
}


# ---------------------------------------------------------------------------------------------
# Setup

# readiness_once: one readiness attempt, a GET of broker-service's and then feature-flag-service's
# readyz, which succeeds when both answer 200. Inside a poll each request may take the time left
# before PROBE_DEADLINE, at most HTTP_TIMEOUT_SECONDS, so the attempt has ended by the poll's
# deadline; a request due with no time left is not sent, and the attempt fails saying so.
# shellcheck disable=SC2329 # Invoked through poll.
readiness_once() {
    local service left limit="$HTTP_TIMEOUT_SECONDS" answers="" ok=1
    # Each request's --max-time, which http reads.
    local HTTP_TIMEOUT_SECONDS="$limit"
    for service in broker-service feature-flag-service; do
        if [[ -n "$PROBE_DEADLINE" ]]; then
            left=$((PROBE_DEADLINE - $(date -u +%s)))
            if [[ $left -le 0 ]]; then
                POLL_DETAIL="${answers:+$answers, }$service readyz not requested: no time left before the readiness deadline"
                return 1
            fi
            HTTP_TIMEOUT_SECONDS=$((left < limit ? left : limit))
        fi
        http GET "$BASE_URL/$service/readyz"
        answers="${answers:+$answers, }$service readyz gave $(status_text)"
        if [[ "$HTTP_STATUS" != "200" ]]; then
            ok=0
        fi
    done
    POLL_DETAIL="$answers"
    [[ $ok -eq 1 ]]
}

setup() {
    local defined required running missing="" service flag_id modifiable enabled state_rc=0
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
    # loadgen as the run found it, before anything recreates it, for cleanup to restore. The x
    # keeps a trailing line feed of the weight.
    LOADGEN_AT_START="$(loadgen_state && printf x)" || state_rc=$?
    if [[ $state_rc -ne 0 ]]; then
        abort "readiness" "$(docker_problem "reading loadgen's container state" "$state_rc" "$DOCKER_CALL_TIMEOUT_SECONDS")"
    fi
    LOADGEN_AT_START="${LOADGEN_AT_START%x}"
    if [[ "$LOADGEN_AT_START" == running,* ]]; then
        LOADGEN_WAS_RUNNING=1
    fi
    if ! poll "readiness" "$READY_TIMEOUT_SECONDS" "$READY_STEP_SECONDS" readiness_once; then
        exit 1
    fi
    pass "readiness"

    # The x keeps a trailing line feed of the value; printf %q prints a value with control
    # characters on one line, as $'...'.
    DIALECT="$(container_env db-adapter DB_TYPE && printf x)" || DIALECT=""
    DIALECT="${DIALECT%x}"
    if [[ "$DIALECT" != "mssql" && "$DIALECT" != "postgres" ]]; then
        abort "runtime facts" "db-adapter DB_TYPE is [${DIALECT:+$(printf '%q' "$DIALECT")}], expected mssql or postgres"
    fi
    pass "runtime facts"
    info "db type $DIALECT; loadgen at start: $(loadgen_state_text "$LOADGEN_AT_START")"

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

# run_a: run A, whose checks follow the close of its window, so they judge it through its stop:
# no portfolio_insights_alert visit may run, in its breakdown or in its late stretch.
run_a() {
    local rc=0 json names detail late ok=1 status=0
    run_window A false 0 || rc=$?
    close_or_abort "run A"
    report_new_owned "run A"
    if [[ $rc -eq 0 ]]; then
        json="$(cat "$RUN_DIR/breakdown-A.json")"
        # shellcheck disable=SC2086 # The family list splits into one argument per family.
        check_families "run A" A "$json" $EXISTING_FAMILIES
        names="$(family_names "$VISIT" "$json" | join_lines)"
        detail="${names:+entries [$names] at weight 0}"
        if [[ -n "$names" ]]; then
            ok=0
        fi
        if ! late_known A; then
            ok=0
            detail="${detail:+$detail; }$LATE_UNKNOWN"
        elif [[ -f "$RUN_DIR/A.late.log" ]]; then
            # grep -c exits 1 when it counts no line, and above 1 when the read fails.
            late="$(grep -cF "$RUNNING_MARKER$VISIT]" "$RUN_DIR/A.late.log")" || status=$?
            if [[ $status -gt 1 || ! "$late" =~ ^[0-9]+$ ]]; then
                ok=0
                detail="${detail:+$detail; }$LATE_UNREAD"
            elif [[ "$late" != "0" ]]; then
                ok=0
                detail="${detail:+$detail; }$late lines [$RUNNING_MARKER$VISIT]] after the breakdown, through the stop"
            fi
        fi
        check_result "run A" A "$VISIT" "no $VISIT" "$ok" "$detail"
    fi
}

# run_b: run B. audit_owned_ids drains loadgen to Q and closes the window before the breakdown
# checks, so they judge run B through its stop, as run A's judge run A.
run_b() {
    local rc=0 json
    run_window B true "$WEIGHT" || rc=$?
    if [[ $rc -eq 2 ]]; then
        close_or_abort "run B"
        report_new_owned "run B"
        return 0
    fi
    audit_owned_ids
    if [[ $rc -eq 0 ]]; then
        json="$(cat "$RUN_DIR/breakdown-B.json")"
        # shellcheck disable=SC2086 # The family list splits into one argument per family.
        check_families "run B" B "$json" $EXISTING_FAMILIES $VISIT
        compare_failures
        check_visit_fail_rate "run B" B "$json"
    fi
}

# creates_in_flight FILE: how many portfolio_insights_alert visits in FILE have opened the page
# but logged no create outcome yet (created, unconfirmed, no instrument options, page
# unavailable, feature lost before submit, or a visit error). Stopping loadgen inside that
# stretch could leave an alert whose id was never logged.
creates_in_flight() {
    awk '
        index($0, "[visit:portfolio_insights_alert][id:") && match($0, /\[id:[^]]*\]/) {
            id = substr($0, RSTART, RLENGTH)
            if (index($0, "Opening portfolio insights page")) {
                open[id] = 1
            } else if (index($0, "Created alert [") || index($0, "Create unconfirmed threshold [") ||
                index($0, "Alert instrument options did not load") ||
                index($0, "Portfolio insights page unavailable, no alert created") ||
                index($0, "Portfolio insights feature lost before submit, no alert created") ||
                index($0, "Worker had error when running visit")) {
                open[id] = 0
            }
        }
        END { n = 0; for (id in open) if (open[id]) n++; print n }
    ' "$1"
}

# quiescent FILE: whether every alert created in FILE is resolved in FILE and no visit in FILE is
# between opening the page and its create outcome. Sets POLL_DETAIL when not.
quiescent() {
    local in_flight
    unresolved_ids "$1" >"$RUN_DIR/quiesce.unresolved"
    in_flight="$(creates_in_flight "$1")"
    if [[ -s "$RUN_DIR/quiesce.unresolved" ]]; then
        POLL_DETAIL="unresolved: $(join_lines <"$RUN_DIR/quiesce.unresolved")"
        return 1
    fi
    if [[ "$in_flight" != "0" ]]; then
        POLL_DETAIL="$in_flight visits between opening the page and their create outcome"
        return 1
    fi
}

# frozen_log: reads the output of the paused loadgen into $RUN_DIR/frozen.log, again every
# QUIESCE_FLUSH_STEP_SECONDS until two reads in a row match. Fails, with POLL_DETAIL, on an
# unreadable log or when no two reads match within QUIESCE_FLUSH_TIMEOUT_SECONDS. Its reads see
# that deadline, or the drain's when it comes first, as PROBE_DEADLINE, local to this call, and
# it never sleeps up to or past that deadline, where no read could start.
frozen_log() {
    local deadline reads=0
    deadline=$(($(date -u +%s) + QUIESCE_FLUSH_TIMEOUT_SECONDS))
    local PROBE_DEADLINE="${PROBE_DEADLINE:-$deadline}"
    if [[ $deadline -lt $PROBE_DEADLINE ]]; then
        PROBE_DEADLINE="$deadline"
    fi
    while :; do
        if ! read_window "$RUN_DIR/frozen.next"; then
            POLL_DETAIL="reading the paused loadgen's output: $LOG_PROBE_DETAIL"
            return 1
        fi
        if [[ $reads -gt 0 ]] && cmp -s "$RUN_DIR/frozen.log" "$RUN_DIR/frozen.next"; then
            return 0
        fi
        mv -f "$RUN_DIR/frozen.next" "$RUN_DIR/frozen.log"
        reads=$((reads + 1))
        if [[ $(($(date -u +%s) + QUIESCE_FLUSH_STEP_SECONDS)) -ge $PROBE_DEADLINE ]]; then
            if [[ $PROBE_DEADLINE -lt $deadline ]]; then
                POLL_DETAIL="paused loadgen's output still changing at the drain deadline"
            else
                POLL_DETAIL="paused loadgen's output still changing after ${QUIESCE_FLUSH_TIMEOUT_SECONDS}s"
            fi
            return 1
        fi
        sleep "$QUIESCE_FLUSH_STEP_SECONDS"
    done
}

# drain_call_limit DEADLINE: sets DRAIN_CALL_LIMIT to the seconds a Docker call of the run B drain
# may take now, the smaller of DOCKER_CALL_TIMEOUT_SECONDS and the time left before DEADLINE
# (epoch seconds). Fails when no time is left. It sets a variable rather than print, so the drain
# starts no subshell for it.
drain_call_limit() {
    local left
    left=$(($1 - $(date -u +%s)))
    if [[ $left -le 0 ]]; then
        return 1
    fi
    DRAIN_CALL_LIMIT=$((left < DOCKER_CALL_TIMEOUT_SECONDS ? left : DOCKER_CALL_TIMEOUT_SECONDS))
}

# drain_loadgen: ends run B at an instant Q after which loadgen neither logs nor acts. Every
# QUIESCE_STEP_SECONDS until the QUIESCE_TIMEOUT_SECONDS deadline, it checks loadgen's running
# output with quiescent. Once that holds, it pauses loadgen and checks the settled frozen output
# again, since a visit may have opened the page or created an alert after the running read. When
# that holds too, it kills the paused loadgen, and that is Q; otherwise it unpauses loadgen and
# polls on. Returns 0 at Q and 1 when the deadline passes or Compose fails, with DRAIN_DETAIL
# describing the outcome; loadgen may then still run or be paused, for close_window to stop
# under its own bound. The deadline holds for every step: the log reads take at most the time
# left, each pause, unpause and kill the smaller of that and DOCKER_CALL_TIMEOUT_SECONDS
# (drain_call_limit), a step due with no time left is not started, and a kill seen to end in the
# deadline's second or later is no Q: on the whole-second clock only a kill seen before that
# second ended within QUIESCE_TIMEOUT_SECONDS of the drain's start. DRAIN_DETAIL tells a call
# Docker did not answer within its limit from one that failed.
drain_loadgen() {
    local deadline rc now late
    DRAIN_DETAIL=""
    deadline=$(($(date -u +%s) + QUIESCE_TIMEOUT_SECONDS))
    # The log reads of the drain see this deadline, local to this call, so the closing read of
    # close_or_abort takes the fixed bound.
    local PROBE_DEADLINE="$deadline"
    while :; do
        POLL_DETAIL=""
        rc=0
        if ! read_window "$RUN_DIR/quiesce.log"; then
            DRAIN_DETAIL="$LOG_PROBE_DETAIL"
        elif ! quiescent "$RUN_DIR/quiesce.log"; then
            DRAIN_DETAIL="$POLL_DETAIL"
        else
            if ! drain_call_limit "$deadline"; then
                DRAIN_DETAIL="drain deadline of $QUIESCE_TIMEOUT_SECONDS s reached before pausing loadgen"
                return 1
            fi
            pause_loadgen "$DRAIN_CALL_LIMIT" || rc=$?
            if [[ $rc -ne 0 ]]; then
                DRAIN_DETAIL="$(docker_problem "pausing loadgen" "$rc" "$DRAIN_CALL_LIMIT")"
                return 1
            fi
            if frozen_log && quiescent "$RUN_DIR/frozen.log"; then
                if ! drain_call_limit "$deadline"; then
                    DRAIN_DETAIL="drain deadline of $QUIESCE_TIMEOUT_SECONDS s reached before killing the paused loadgen"
                    return 1
                fi
                kill_loadgen "$DRAIN_CALL_LIMIT" || rc=$?
                if [[ $rc -ne 0 ]]; then
                    DRAIN_DETAIL="$(docker_problem "killing the paused loadgen" "$rc" "$DRAIN_CALL_LIMIT")"
                    return 1
                fi
                now="$(date -u +%s)"
                if [[ $now -ge $deadline ]]; then
                    late=""
                    if [[ $now -gt $deadline ]]; then
                        late=", $((now - deadline)) s late"
                    fi
                    DRAIN_DETAIL="paused loadgen killed at or after the drain deadline of $QUIESCE_TIMEOUT_SECONDS s$late, so no Q"
                    return 1
                fi
                DRAIN_DETAIL="Q at $(now_rfc3339) with $(($(created_ids "$RUN_DIR/frozen.log" | wc -l))) created alerts, all resolved, and no create in flight; loadgen killed while paused"
                return 0
            fi
            DRAIN_DETAIL="paused: $POLL_DETAIL"
            if ! drain_call_limit "$deadline"; then
                DRAIN_DETAIL="$DRAIN_DETAIL; drain deadline of $QUIESCE_TIMEOUT_SECONDS s reached before unpausing loadgen"
                return 1
            fi
            unpause_loadgen "$DRAIN_CALL_LIMIT" || rc=$?
            if [[ $rc -ne 0 ]]; then
                DRAIN_DETAIL="$DRAIN_DETAIL; $(docker_problem "unpausing loadgen" "$rc" "$DRAIN_CALL_LIMIT")"
                return 1
            fi
        fi
        # After the sleep no time would be left for a read.
        if [[ $(($(date -u +%s) + QUIESCE_STEP_SECONDS)) -ge $deadline ]]; then
            DRAIN_DETAIL="not quiescent within ${QUIESCE_TIMEOUT_SECONDS}s: $DRAIN_DETAIL"
            return 1
        fi
        sleep "$QUIESCE_STEP_SECONDS"
    done
}

# audit_owned_ids: run B's owned-id audit. drain_loadgen stops loadgen at Q, where no create can
# be cut off before loadgen logs its id. After the stop, "owned-id evidence" fails when run B's
# final output, $RUN_DIR/B.log, lacks a created id, a resolution or the first line that an earlier
# read of run B saw, as after log rotation. The audit, created and rows checks then judge every
# create seen in any read: the final output joined with those earlier reads. The audit also
# holds the final output, the one read whose line order and repeats are exact, to one create and
# one later resolution per id, both by the same tagged visit (owned_id_violations). The in-flight
# and outcomes checks judge the final output. Without Q, quiescence fails, loadgen is stopped all
# the same, and the same checks run. When reading or writing the ids those checks compare fails,
# the evidence check, or the audit, created and rows checks, fail rather than judge an empty or
# partial set.
audit_owned_ids() {
    local stopped=0 count unresolved violations="" violation detail in_flight lines ok lost_created
    local lost_resolved first_line="kept" evidence_read=1 union_read=1
    local first_file="$RUN_DIR/observed-first-$WINDOW_LABEL"
    local ids_unread="the alert ids run B's reads logged could not be read or written in $RUN_DIR"
    if drain_loadgen; then
        stopped=1
        check_result "" B "$VISIT" "owned-id quiescence" 1 "$DRAIN_DETAIL"
    else
        check_result "" B "$VISIT" "owned-id quiescence" 0 "$DRAIN_DETAIL; ownership cannot be established"
    fi
    close_or_abort "run B" "$stopped"

    if ! created_ids "$RUN_DIR/B.log" >"$RUN_DIR/ids.created.all" ||
        ! resolved_ids "$RUN_DIR/B.log" >"$RUN_DIR/ids.resolved.all" ||
        ! lost_created=$(($(observed_ids created | LC_ALL=C comm -23 - "$RUN_DIR/ids.created.all" | wc -l))) ||
        ! lost_resolved=$(($(observed_ids resolved | LC_ALL=C comm -23 - "$RUN_DIR/ids.resolved.all" | wc -l))); then
        evidence_read=0
    fi
    if [[ -s "$first_file" ]] && ! grep -qxF -f "$first_file" "$RUN_DIR/B.log"; then
        first_line="missing"
    fi
    if [[ $evidence_read -eq 0 ]]; then
        check_result "" B "$VISIT" "owned-id evidence" 0 "$ids_unread, so not every create can be proven"
    elif [[ $lost_created -eq 0 && $lost_resolved -eq 0 && "$first_line" == "kept" ]]; then
        check_result "" B "$VISIT" "owned-id evidence" 1 \
            "the final output keeps every created id, resolution and first line an earlier read saw"
    else
        check_result "" B "$VISIT" "owned-id evidence" 0 \
            "the final output lost lines an earlier read saw (log rotation): $lost_created created ids and $lost_resolved resolutions missing, first line $first_line, so not every create can be proven"
    fi

    # Every later check but in flight and outcomes judges what any read of run B saw, so an id
    # seen once is never dropped; close_window has owned the unresolved ones.
    if ! window_ids "$RUN_DIR/B.log" ||
        ! count=$(($(wc -l <"$RUN_DIR/ids.created.union"))) ||
        ! unresolved="$(LC_ALL=C comm -23 "$RUN_DIR/ids.created.union" "$RUN_DIR/ids.resolved.union" |
            join_lines)"; then
        union_read=0
        count=0
        unresolved=""
    fi
    # Pairing needs line order and repeats, which only one read holds: the final output, whose
    # losses the evidence check above reports.
    owned_id_violations "$RUN_DIR/B.log" >"$RUN_DIR/ids.violations"
    while IFS= read -r violation; do
        violations="${violations:+$violations, }$violation"
    done <"$RUN_DIR/ids.violations"
    if [[ $union_read -eq 1 && -z "$unresolved" && -z "$violations" ]]; then
        check_result "" B "$VISIT" "owned-id audit" 1 \
            "$count created alerts, each deleted via ui, via api or already absent"
    else
        detail=""
        if [[ $union_read -eq 0 ]]; then
            detail="$ids_unread, so no create can be paired with its resolution"
        fi
        if [[ -n "$violations" ]]; then
            detail="${detail:+$detail; }not one-to-one: $violations"
        fi
        if [[ -n "$unresolved" ]]; then
            detail="${detail:+$detail; }not resolved by loadgen, deleted on exit: $unresolved"
        fi
        check_result "" B "$VISIT" "owned-id audit" 0 "$detail"
    fi

    in_flight="$(creates_in_flight "$RUN_DIR/B.log")"
    if [[ "$in_flight" == "0" ]]; then
        check_result "" B "$VISIT" "owned-id in flight" 1 \
            "every visit that opened the page logged a create outcome"
    else
        check_result "" B "$VISIT" "owned-id in flight" 0 \
            "$in_flight visits opened the page and logged no create outcome, so their alerts cannot be tied to an id"
    fi

    { grep -F -e "$LEFT_MARKER" -e "$UNKNOWN_MARKER" "$RUN_DIR/B.log" || true; } >"$RUN_DIR/outcomes"
    report_outcomes "$RUN_DIR/outcomes"
    lines=$(($(wc -l <"$RUN_DIR/outcomes")))
    ok=0
    if [[ $lines -eq 0 ]]; then
        ok=1
    fi
    check_result "" B "$VISIT" "owned-id outcomes" "$ok" \
        "$lines lines report an alert left in place or an unknown outcome since $WINDOW_START"

    if [[ $union_read -eq 0 ]]; then
        check_result "" B "$VISIT" "owned-id created" 0 \
            "$ids_unread, so the alerts created in run B cannot be counted"
        check_result "" B "$VISIT" "owned-id rows" 0 "$ids_unread, so no Alerts row was counted"
        return 0
    fi
    ok=0
    if [[ $count -ge 1 ]]; then
        ok=1
    fi
    check_result "" B "$VISIT" "owned-id created" "$ok" \
        "$count alerts created in run B$([[ $ok -eq 0 ]] && echo "; the visit never created an alert")"

    if [[ $count -eq 0 ]]; then
        info "owned-id rows: skipped, no created id to count"
    elif ! db_count_ids "$RUN_DIR/ids.created.union"; then
        check_result "" B "$VISIT" "owned-id rows" 0 "$DB_ERROR"
    elif [[ $DB_COUNT -eq 0 ]]; then
        check_result "" B "$VISIT" "owned-id rows" 1 "no Alerts row carries any of the $count created ids"
    else
        cat "$RUN_DIR/ids.created.union" >>"$RUN_DIR/owned"
        check_result "" B "$VISIT" "owned-id rows" 0 \
            "$DB_COUNT of $count created ids still have an Alerts row; they are deleted on exit"
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
        # The window opened with a loadgen recreate, and a fresh container draws the rare
        # order_credit_card visit first, so its breakdown covers every existing family.
        # shellcheck disable=SC2086 # The family list splits into one argument per family.
        check_families "$prefix" "$label" "$json" $EXISTING_FAMILIES
    else
        info "$prefix: failRate and family checks skipped without a breakdown"
    fi
}

# ---------------------------------------------------------------------------------------------
# Table

# verdict_of LABEL FAMILY: FAIL when a check of FAMILY in phase LABEL failed, PASS when one
# passed and none failed, "not checked" otherwise. Fails, printing nothing, when the verdicts
# file is missing, not a regular file or cannot be read: awk skips a directory with a warning
# and exit status 0, which would otherwise read as "not checked".
verdict_of() {
    local verdict
    if [[ ! -f "$RUN_DIR/verdicts" ]]; then
        echo "verdict_of: $RUN_DIR/verdicts is not a regular file" >&2
        return 1
    fi
    verdict="$(awk -F '\t' -v l="$1" -v f="$2" '
        $1 == l && $2 == f && $3 == "FAIL" { failed = 1 }
        $1 == l && $2 == f && $3 == "PASS" { passed = 1 }
        END { print (failed ? "FAIL" : (passed ? "PASS" : "not checked")) }' "$RUN_DIR/verdicts")" ||
        return 1
    echo "$verdict"
}

# phase_families LABEL: the families phase LABEL is checked on. Run B and the flag-off phase
# share them.
phase_families() {
    case "$1" in
        A) echo "$EXISTING_FAMILIES" ;;
        *) echo "$EXISTING_FAMILIES $VISIT" ;;
    esac
}

# table_rows LABEL: one row per visit name of phase LABEL's breakdown, plus one per checked family
# the breakdown has no name of. Returns non-zero at the first step that fails (reading the
# breakdown, jq, awk, a verdict or a write), so its caller never takes a short table for a whole
# one. No step relies on errexit, which a caller's if condition switches off: each is checked,
# and jq writes to a file, not a process substitution, so its own status is seen.
table_rows() {
    local label="$1" file="$RUN_DIR/breakdown-$1.json" raw="$RUN_DIR/table-$1.raw"
    local tsv="$RUN_DIR/table-$1.tsv" json name total rate completions family families names
    local errors verdict
    if [[ ! -s "$file" ]]; then
        echo "| $label | - | - | - | - | - | - | no breakdown |" || return 1
        return 0
    fi
    json="$(cat "$file")" || return 1
    jq -r 'to_entries[] | [.key, .value.total, .value.failRate,
        (.value.total * (1 - .value.failRate) + 0.5 | floor)] | @tsv' <<<"$json" >"$raw" || return 1
    tr -d '\r' <"$raw" >"$tsv" || return 1
    while IFS=$'\t' read -r name total rate completions; do
        family="$(family_of "$name")" || return 1
        errors="?"
        if [[ -f "$RUN_DIR/errors-$label" ]]; then
            errors="$(awk -v n="$name" '$2 == n { print $1 }' "$RUN_DIR/errors-$label")" || return 1
        fi
        verdict="$(verdict_of "$label" "$family")" || return 1
        echo "| $label | $family | $name | $total | $rate | $completions | ${errors:-0} | $verdict |" ||
            return 1
    done <"$tsv" || return 1
    families="$(phase_families "$label")" || return 1
    for family in $families; do
        # family_names reads a jq failure as no name; here it must fail the rows instead.
        names="$(jq -r --arg f "$family" "keys[] | select($FAMILY_JQ)" <<<"$json")" || return 1
        if [[ -z "$names" ]]; then
            verdict="$(verdict_of "$label" "$family")" || return 1
            echo "| $label | $family | - | 0 | - | 0 | 0 | $verdict |" || return 1
        fi
    done
}

# write_table: the per-family table of runs A, B and the flag-off phase, published at OUT_FILE.
# PASS "table: OUT_FILE" once it is published there; otherwise FAIL "table" with the step that
# failed and OUT_FILE as it was, with no partial file left: the rows are generated into the run
# dir first, then the whole report is written to a temporary file beside OUT_FILE and renamed
# over it. Beside OUT_FILE, not in the run dir, so that the rename stays on one file system and
# replaces OUT_FILE in one step; across file systems mv copies, and a failed copy leaves a short
# OUT_FILE. Every step is checked on its own rather than through errexit, which this function's
# callers may have off (cleanup runs with set +e). The temporary file gets the mode a plain
# redirection would give, since mktemp creates it readable by its owner only.
write_table() {
    local label tmp="" mode reason="" log="$RUN_DIR/table-error.log"
    TABLE_WRITTEN=1
    for label in A B B-flag-off; do
        if ! table_rows "$label" 2>>"$log" >"$RUN_DIR/table-$label.rows"; then
            reason="could not generate the rows of run $label"
            break
        fi
    done
    if [[ -z "$reason" ]]; then
        printf -v mode '%04o' $((0666 & ~$(umask)))
        if ! tmp="$(mktemp -- "$OUT_FILE.XXXXXX" 2>>"$log")"; then
            tmp=""
            reason="could not write $OUT_FILE"
        elif ! chmod -- "$mode" "$tmp" 2>>"$log"; then
            reason="could not write $OUT_FILE"
        elif ! {
            echo "# Loadgen live run" &&
                echo &&
                echo "Project \`$PROJECT\`, db type ${DIALECT:-unknown}, weight $WEIGHT, runs of $MINUTES minutes, started $STARTED_AT." &&
                echo &&
                echo "| run | family | visit name | total | failRate | completions | error lines | verdict |" &&
                echo "| --- | --- | --- | --- | --- | --- | --- | --- |" &&
                cat "$RUN_DIR/table-A.rows" "$RUN_DIR/table-B.rows" "$RUN_DIR/table-B-flag-off.rows"
        } 2>>"$log" >"$tmp"; then
            reason="could not write $OUT_FILE"
        elif ! mv -f -T -- "$tmp" "$OUT_FILE" 2>>"$log"; then
            # -T: an OUT_FILE that is a directory fails the rename instead of receiving the file.
            reason="could not publish $OUT_FILE"
        else
            tmp=""
        fi
    fi
    if [[ -n "$tmp" ]] && ! rm -f -- "$tmp" 2>>"$log"; then
        reason="$reason; partial file $tmp not removed"
    fi
    if [[ -z "$reason" ]]; then
        pass "table: $OUT_FILE"
    else
        fail "table" "$reason (see $log)"
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
# number. Fails, printing no number, when a list cannot be read or written or the ids written
# cannot be counted: an unread owned list must never pass for an empty one.
remaining_owned() {
    local count
    LC_ALL=C sort -u "$RUN_DIR/owned" >"$RUN_DIR/owned.sorted" || return 1
    LC_ALL=C sort -u "$RUN_DIR/deleted" >"$RUN_DIR/deleted.sorted" || return 1
    LC_ALL=C comm -23 "$RUN_DIR/owned.sorted" "$RUN_DIR/deleted.sorted" >"$RUN_DIR/to-delete" || return 1
    count="$(wc -l <"$RUN_DIR/to-delete")" || return 1
    count="${count//[[:space:]]/}"
    if [[ ! "$count" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    echo "$count"
}

# write_recovery_record: writes $RUN_DIR/recovery, one JSON object holding the project, base URL
# and Compose files of this run. --resume-cleanup deletes the owned ids of a run directory only
# for the project and base URL its record names. As for docker, Git Bash must not rewrite a
# path-like value into a Windows path on its way to jq.
write_recovery_record() {
    MSYS_NO_PATHCONV=1 jq -n --arg project "$PROJECT" --arg baseUrl "$BASE_URL" \
        '{project: $project, baseUrl: $baseUrl, composeFiles: $ARGS.positional}' \
        --args "${COMPOSE_FILES[@]}" >"$RUN_DIR/recovery"
}

# resume_command: the command line, each value quoted for the shell, that deletes through
# --resume-cleanup the owned alerts this run directory still holds.
resume_command() {
    local file text
    printf -v text 'scripts/portfolio-insights/loadgen-check.sh --project %q --base-url %q' \
        "$PROJECT" "$BASE_URL"
    for file in "${COMPOSE_FILES[@]}"; do
        printf -v text '%s --compose-file %q' "$text" "$file"
    done
    printf '%s --resume-cleanup %q\n' "$text" "$RUN_DIR"
}

# delete_remaining COUNT: DELETEs every owned id not yet deleted, the COUNT lines remaining_owned
# wrote to $RUN_DIR/to-delete, each a canonical UUID; a line that is not one, which only an edited
# run directory can hold, is refused and never sent. 204 and 404 are clean once the id is added to
# the deleted list; an id that list cannot record stays left, as do the lines a failed read of
# to-delete never reached. A transport error is retried as CLEANUP_RETRY_ATTEMPTS sets out; any
# other outcome is printed with its id and status. Sets CLEANUP_LEFT to the number left in place,
# and CLEANUP_REFUSED to how many of those were refused.
delete_remaining() {
    local id attempt line=0 transport=0
    CLEANUP_LEFT=0
    CLEANUP_REFUSED=0
    while IFS= read -r id; do
        line=$((line + 1))
        if [[ ! "$id" =~ $UUID_RE ]]; then
            # The line is not printed: it is not an id loadgen logged, so it may be any text.
            info "cleanup refused line $line of $RUN_DIR/to-delete: not a canonical alert id, never sent"
            CLEANUP_LEFT=$((CLEANUP_LEFT + 1))
            CLEANUP_REFUSED=$((CLEANUP_REFUSED + 1))
            continue
        fi
        if [[ $transport -ge $MAX_CONSECUTIVE_TRANSPORT_ERRORS ]]; then
            info "cleanup left alert $id: not attempted after $transport transport errors in a row"
            CLEANUP_LEFT=$((CLEANUP_LEFT + 1))
            continue
        fi
        attempt=1
        http DELETE "$ALERTS_URL/$id"
        while [[ "$HTTP_STATUS" == "000" && $attempt -lt $CLEANUP_RETRY_ATTEMPTS ]]; do
            sleep "$CLEANUP_RETRY_STEP_SECONDS"
            attempt=$((attempt + 1))
            http DELETE "$ALERTS_URL/$id"
        done
        case "$HTTP_STATUS" in
            204 | 404)
                transport=0
                # The alert is gone. An id the deleted list cannot record still counts as left, so
                # the check fails and a resume sends its DELETE again, which a 404 answers cleanly.
                if ! echo "$id" >>"$RUN_DIR/deleted"; then
                    info "cleanup left alert $id: gone (status $HTTP_STATUS), but $RUN_DIR/deleted could not record it; a resume DELETEs it again"
                    CLEANUP_LEFT=$((CLEANUP_LEFT + 1))
                fi
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
    # A read of to-delete that fails ends the loop as its end would.
    if [[ $line -lt $1 ]]; then
        info "cleanup left $(($1 - line)) owned alerts: $RUN_DIR/to-delete could not be read past line $line"
        CLEANUP_LEFT=$((CLEANUP_LEFT + $1 - line))
    fi
}

# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() {
    local rc=$? remaining problems="" stopped closed
    trap - EXIT
    set +e
    # An exit inside a poll, the quiescence wait or the progress watch leaves that wait's deadline
    # in scope here, so the closing log read below would inherit it; cleanup reads with the fixed
    # bound instead. Every Docker call below has a hard limit, so none can hold the exit.
    PROBE_DEADLINE=""
    if [[ $WINDOW_OPEN -eq 1 || $WINDOW_UNREAD -eq 1 ]]; then
        # A run ended mid-phase, or its window's closing read failed: the leg still pending is
        # retried. loadgen stops first, so no visit runs while the flag is switched for deletion;
        # a loadgen the run B drain left paused is killed without being thawed. A loadgen whose
        # stop was confirmed has its window read again. Whatever the phase created and did not
        # resolve is owned on either outcome, from the reads that succeeded.
        # When the stop is not confirmed, because Docker did not answer within its limit or the
        # call failed, cleanup still deletes the owned alerts and restores the flag. Skipping them
        # would leave those alerts and a changed flag behind for certain; a loadgen that is still
        # running risks less, since each of its visits deletes its own alert and logs the id of
        # one it cannot. The cleanup check then fails, naming loadgen as not confirmed stopped.
        stopped=0
        if [[ $WINDOW_OPEN -eq 0 ]]; then
            stopped=1
        fi
        close_window "$stopped"
        closed=$?
        report_new_owned "cleanup"
        if [[ $closed -ne 0 && $WINDOW_OPEN -eq 1 ]]; then
            problems="loadgen not confirmed stopped: $CLOSE_ERROR"
        elif [[ $closed -ne 0 ]]; then
            problems="loadgen stopped, but its window was not read: $CLOSE_ERROR"
        fi
    fi
    if [[ $LOADGEN_TOUCHED -eq 1 && $TABLE_WRITTEN -eq 0 ]]; then
        write_table
    fi
    if ! remaining="$(remaining_owned)"; then
        # Without the lists nothing tells which owned ids are left, so none is deleted, the flag
        # is not switched for it, and the steps below still restore the flag and loadgen.
        problems="${problems:+$problems; }owned-alert lists of the run dir could not be read or written, owned alerts not deleted"
        info "cleanup: to delete the owned alerts left, and only those, run: $(resume_command)"
    elif [[ "$remaining" -gt 0 ]]; then
        # DELETE answers 403 while the flag is off, so the flag is switched on to delete.
        http GET "$FLAG_URL"
        if [[ "$HTTP_STATUS" == "200" && "$(jget '.enabled' "$HTTP_BODY")" == "false" ]]; then
            FLAG_TOUCHED=1
            http PUT "$FLAG_URL" '{"enabled": true}'
            info "cleanup: flag $FLAG_ID switched on to delete $remaining owned alerts ($(status_text))"
        fi
        delete_remaining "$remaining"
        info "cleanup: $((remaining - CLEANUP_LEFT)) of $remaining owned alerts deleted or already absent"
        if [[ $CLEANUP_LEFT -gt 0 ]]; then
            problems="${problems:+$problems; }$CLEANUP_LEFT owned alerts left in place"
        fi
        # Refused lines are not ids, so a later run could not delete them either.
        if [[ $CLEANUP_LEFT -gt $CLEANUP_REFUSED ]]; then
            info "cleanup: to delete the owned alerts left, and only those, run: $(resume_command)"
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
            info "cleanup: loadgen restored as at start: $(loadgen_state_text "$LOADGEN_AT_START")"
        else
            problems="${problems:+$problems; }loadgen not restored: $RESTORE_ERROR"
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
# Resuming a cleanup

# resume_refused REASON: ends a --resume-cleanup run, before any request, with exit status 2.
resume_refused() {
    echo "Cannot resume the cleanup of $RESUME_RUN_DIR: $1." >&2
    exit 2
}

# open_resumed_run_dir: makes RESUME_RUN_DIR the run directory once it holds the recovery record
# of a run against this --project and --base-url, and that run's owned and deleted lists.
open_resumed_run_dir() {
    local verdict list
    if [[ ! -f "$RESUME_RUN_DIR/recovery" || ! -r "$RESUME_RUN_DIR/recovery" ]]; then
        resume_refused "it holds no readable recovery record"
    fi
    # Compared inside jq, so no value of the record is printed: an edited record may hold any text.
    verdict="$(MSYS_NO_PATHCONV=1 jq -r --arg project "$PROJECT" --arg baseUrl "$BASE_URL" '
        if type != "object" or (.project | type) != "string" or (.baseUrl | type) != "string"
            or (.composeFiles | type) != "array" or any(.composeFiles[]; type != "string")
        then "malformed"
        elif .project != $project then "project"
        elif .baseUrl != $baseUrl then "base-url"
        else "match" end' <"$RESUME_RUN_DIR/recovery" 2>/dev/null | tr -d '\r')" || verdict=""
    case "$verdict" in
        match) ;;
        project) resume_refused "its run was against another Compose project than --project" ;;
        base-url) resume_refused "its run was against another base URL than --base-url" ;;
        *) resume_refused "its recovery record is not one this script writes" ;;
    esac
    for list in owned deleted; do
        if [[ ! -f "$RESUME_RUN_DIR/$list" || ! -r "$RESUME_RUN_DIR/$list" ]]; then
            resume_refused "its $list list is missing or unreadable"
        fi
    done
    if [[ ! -w "$RESUME_RUN_DIR" || ! -w "$RESUME_RUN_DIR/deleted" ]]; then
        resume_refused "it is not writable, so no deletion could be recorded"
    fi
    RUN_DIR="$RESUME_RUN_DIR"
}

# resume_origin_bound: refuses the resume through resume_refused unless --base-url reaches the
# reverse proxy of the Compose project --project names, so that no request of the resume can
# switch another stack's flag or record its 404s as deletions while the alerts stay in this one.
# The project must run its reverse-proxy service, and docker compose port must print where its
# port 80 is published as HOST:PORT, Compose's form for the first binding, with an IPv6 HOST
# unbracketed. PORT must be the base URL's port: the one it names, else 80 for http:// and 443 for
# https://. HOST must be the base URL's host; or a wildcard, 0.0.0.0 or ::, when that host is
# localhost, 127.0.0.1 or [::1]; or 127.0.0.1 or ::1 when it is localhost. Nothing shows that any
# other base URL host reaches the binding, so any other pair is refused. Each Docker call has
# ended within DOCKER_CALL_TIMEOUT_SECONDS (hard_timeout), and its errors go to compose.log in the
# run directory. The reasons are fixed text: no output of Docker is printed until validated.
resume_origin_bound() {
    local running published bound_host bound_port authority host port reaches rc=0
    running="$(running_services)" || rc=$?
    if [[ $rc -ne 0 ]]; then
        resume_refused "$(docker_problem "listing the running services of --project" "$rc" "$DOCKER_CALL_TIMEOUT_SECONDS")"
    fi
    if ! grep -qxF reverse-proxy <<<"$running"; then
        resume_refused "reverse-proxy is not running in --project, so the stack at --base-url may be another project's"
    fi
    published="$(compose_within "$DOCKER_CALL_TIMEOUT_SECONDS" port reverse-proxy 80 2>>"$RUN_DIR/compose.log" |
        tr -d '\r')" || rc=$?
    if [[ $rc -ne 0 ]]; then
        resume_refused "$(docker_problem "reading where --project publishes port 80 of reverse-proxy" "$rc" "$DOCKER_CALL_TIMEOUT_SECONDS")"
    fi
    bound_port="${published##*:}"
    bound_host="${published%:*}"
    bound_host="${bound_host#\[}"
    bound_host="${bound_host%\]}"
    bound_host="${bound_host,,}"
    if [[ "$published" != *:* ]] || ! is_port_number "$bound_port" ||
        ! { is_ipv4_address "$bound_host" || is_ipv6_address "$bound_host"; }; then
        resume_refused "docker compose port printed no HOST:PORT for port 80 of reverse-proxy in --project"
    fi
    # BASE_URL passed is_base_origin and lost its trailing slash, so it splits as there.
    authority="${BASE_URL#*://}"
    if [[ "$authority" == \[* ]]; then
        host="${authority%%\]*}"
        host="${host#\[}"
        port="${authority#*\]}"
    else
        host="${authority%%:*}"
        port="${authority#"$host"}"
    fi
    host="${host,,}"
    port="${port#:}"
    if [[ -z "$port" ]]; then
        case "$BASE_URL" in
            https://*) port=443 ;;
            *) port=80 ;;
        esac
    fi
    if ((10#$bound_port != 10#$port)); then
        resume_refused "port 80 of reverse-proxy in --project is published on another port than --base-url names"
    fi
    # The binding hosts besides its own that the base URL's host reaches.
    case "$host" in
        localhost) reaches="0.0.0.0 :: 127.0.0.1 ::1" ;;
        127.0.0.1 | ::1) reaches="0.0.0.0 ::" ;;
        *) reaches="" ;;
    esac
    if [[ "$bound_host" != "$host" && " $reaches " != *" $bound_host "* ]]; then
        resume_refused "port 80 of reverse-proxy in --project is published on a host address that --base-url is not shown to reach"
    fi
    info "resume: --base-url reaches reverse-proxy of project [$PROJECT], port 80 published at $published"
}

# resume_cleanup: the --resume-cleanup run. It checks that --base-url is the origin of --project
# (resume_origin_bound) and reads the flag, then ends through cleanup, which DELETEs by id the
# owned ids of the run directory no earlier cleanup deleted, switching the flag on to delete while
# it is off and restoring it after, and appends each id deleted or found absent to the deleted
# list, so a later resume goes on from there. It sends no POST, deletes nothing by account,
# touches no loadgen, opens no window and writes no table.
resume_cleanup() {
    local enabled remaining
    trap 'exit 130' INT TERM
    info "run dir $RUN_DIR"
    info "resuming the owned-alert cleanup of project [$PROJECT], base url $BASE_URL"
    resume_origin_bound
    http GET "$FLAG_URL"
    enabled="$(jq -r --arg id "$FLAG_ID" \
        'if type == "object" and .id == $id and (.enabled | type) == "boolean" then .enabled
        else "invalid" end' <<<"$HTTP_BODY" 2>/dev/null | tr -d '\r')" || enabled=""
    # Without the flag's value cleanup could not restore it, so nothing is deleted.
    if [[ "$HTTP_STATUS" != "200" ]]; then
        fail "resume flag" "GET $FLAG_ID gave $(status_text); nothing was deleted"
    elif [[ "$enabled" != "true" && "$enabled" != "false" ]]; then
        fail "resume flag" "GET $FLAG_ID answered without its id and a boolean enabled; nothing was deleted"
    fi
    if [[ $failed -gt 0 ]]; then
        echo "SUMMARY $passed passed, $failed failed"
        exit 1
    fi
    FLAG_INITIAL="$enabled"
    pass "resume flag: enabled=$FLAG_INITIAL"
    # Without a count nothing is printed for it; cleanup then fails on the same lists.
    if remaining="$(remaining_owned)"; then
        info "resume: $remaining owned alerts of this run directory are not deleted yet"
    fi
    trap cleanup EXIT
    exit 0
}

# ---------------------------------------------------------------------------------------------
# Main

main() {
    parse_options "$@"
    check_tools
    if [[ -n "$RESUME_RUN_DIR" ]]; then
        open_resumed_run_dir
    else
        if ! RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pi-loadgen.XXXXXX")"; then
            echo "Could not create a run directory under ${TMPDIR:-/tmp}." >&2
            exit 2
        fi
        : >"$RUN_DIR/owned"
        : >"$RUN_DIR/deleted"
        : >"$RUN_DIR/new-owned"
        : >"$RUN_DIR/verdicts"
        # Written before anything is owned, so every alert the run leaves behind can be resumed.
        if ! write_recovery_record 2>/dev/null; then
            echo "Could not write the recovery record $RUN_DIR/recovery." >&2
            exit 2
        fi
    fi
    OUT_FILE="${OUT_FILE:-$RUN_DIR/loadgen-families.md}"
    FLAG_URL="$BASE_URL/feature-flag-service/v1/flags/$FLAG_ID"
    ALERTS_URL="$BASE_URL/broker-service/v1/alerts"
    passed=0
    failed=0
    FLAG_INITIAL=""
    FLAG_TOUCHED=0
    LOADGEN_WAS_RUNNING=0
    LOADGEN_TOUCHED=0
    LOADGEN_AT_START=""
    RESTORE_ERROR=""
    DIALECT=""
    WINDOW_OPEN=0
    WINDOW_UNREAD=0
    WINDOW_LABEL=""
    WINDOW_SINCE=""
    LOADGEN_PAUSED=0
    TABLE_WRITTEN=0
    # The absolute deadline (epoch seconds) of the bounded wait running now, empty outside one,
    # and why the last log read failed.
    PROBE_DEADLINE=""
    LOG_PROBE_DETAIL=""
    STARTED_AT="$(now_rfc3339)"

    if [[ -n "$RESUME_RUN_DIR" ]]; then
        resume_cleanup
    fi
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
