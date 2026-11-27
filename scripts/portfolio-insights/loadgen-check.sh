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
#   -h, --help           Show this help and exit
#
# Examples:
#   A full run with every default, against the stack of Compose project pi-dev-mssql:
#     scripts/portfolio-insights/loadgen-check.sh --project pi-dev-mssql
#   A stack started with an override file on its own port, the table written to FILE:
#     scripts/portfolio-insights/loadgen-check.sh --project NAME --base-url http://localhost:PORT \
#         --compose-file compose.dev.yaml --compose-file OVERRIDE.yaml --out FILE
#
# One project per invocation, and one invocation per project at a time: from setup until it exits
# a run holds the lock directory /tmp/pi-loadgen-check.NAME.lock, as a --resume-cleanup does from
# before its flag read, and a second invocation on the same project is refused while the first
# holds it, before it reads the flag or changes anything. The
# refusal names the holding run and says when that run has ended; a lock left by a run killed
# before its cleanup is removed by hand once no run on the project is active. Never run it
# alongside e2e.sh or perf.sh: all three toggle the same flag, and perf.sh stops loadgen to
# measure with no visit running.
#
# What it touches: it toggles only portfolio-insights-enabled and restores it. It recreates
# loadgen with the weight passed through Compose interpolation of the existing
# PORTFOLIO_INSIGHTS_ALERT_WEIGHT declaration, set on that one command and never exported. It
# deletes, by id, only alerts loadgen logged as created and did not delete itself, and reads the
# Alerts table read-only through the db container's own client. Before it changes anything, it
# checks that a loadgen container it finds can be put back as it is: these compose files, under
# the weight that container has, must give loadgen the Compose config hash the container was
# created with, and the image reference it was created from must still name the image it runs.
# What changed on the container since, outside Compose, as docker update does to its resource
# limits or restart policy, only a container shows: so it then briefly creates a twin loadgen
# container in the project, from these compose files under that weight, without starting it or
# touching the container found, reads the twin's effective configuration and removes it again,
# and the two must match in image, settings, host configuration and network endpoints, apart
# from what names one container; the project must also hold that one loadgen container only.
# Otherwise the run ends with nothing changed. It then keeps that container's output since it
# last started in at-start.log in the run directory, since a recreate discards it. When that
# loadgen runs with the flag on, it is first ended, while the flag is still on, at an instant Q
# when no portfolio_insights_alert visit is between opening the page or creating an alert and its
# outcome, as run B ends below, so no visit of that workload has a create or delete refused once
# run A switches the flag off; its alerts are reported, never deleted, and when no Q comes within
# the drain's deadline the run ends with the flag and loadgen as at start. Short of Q that
# container is never recreated, as a visit of its workload may be in flight: when the run ends
# or is interrupted before Q, cleanup unpauses it in place if it is paused, checks that it runs as
# at start, and recreates it only once it has exited, killed at Q. Otherwise, on exit, normal or
# not, it restores the flag and puts loadgen back as it was at start: recreated, without building
# or pulling, with the PORTFOLIO_INSIGHTS_ALERT_WEIGHT its container had (set on that one
# command, or unset when it was unset), running or stopped as it was, or removed when the project
# had no loadgen container; the cleanup check fails unless the restored container matches in
# state, weight, image ID, config hash and effective configuration, with no twin left behind.
# Run B ends at an instant Q when every alert it logged as created is resolved and no visit is
# between opening the page and its create outcome: loadgen is paused, its frozen output checked
# again, and killed while paused, so it logs and does nothing after Q. Run B's owned-id checks
# judge every create seen in any read of run B's output, and fail when the final output lost
# one, as log rotation can. A create cut off before loadgen logs its id by any other stop, such
# as an interrupt while loadgen runs, cannot be tied to an id and is not deleted; an unconfirmed
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
# SUMMARY line, on the run's own stdout even when an interrupt lands while a step writes to a
# file. Exits 0 when every check passes, 1 when any check fails, 2 on a usage error, a missing
# tool, a run that cannot start (no run directory, or stdout closed) or a run directory or stack
# --resume-cleanup refuses, and 130 on an interrupt. Working files stay in the run directory
# printed at start and end. The loadgen output kept there is reduced to the validated lines the
# checks read, so no DEBUG line, typed value or error detail is retained.

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
# The hard limit, termination included as for log reads, of every other Docker call setup's
# restorability check, the drains and the EXIT cleanup make: pausing, unpausing, stopping and
# killing loadgen (pause_loadgen, unpause_loadgen, stop_loadgen, kill_loadgen), restoring it
# (restore_loadgen), reading container state (running_services, container_env,
# container_env_entry, loadgen_state, loadgen_identity, loadgen_run_state), reading what a
# recreate would give loadgen (predicted_loadgen_hash, loadgen_declares_weight, image_id_of), and
# creating, listing, reading and removing the twin loadgen container the restorability check
# compares loadgen with (create_loadgen_twin, loadgen_container_ids, container_snapshot,
# remove_loadgen_twin), wherever those functions run. Inside a drain, run B's or the one of the
# loadgen found at start, a pause, unpause or kill takes the time left before the drain's deadline
# instead when that is shorter, and none starts with no time left, so the drain ends by
# QUIESCE_TIMEOUT_SECONDS; the stop that follows it and the EXIT cleanup's calls each keep this
# bound of their own. Each takes seconds on a healthy engine. A call cut off is reported, and
# cleanup carries on with its other steps.
DOCKER_CALL_TIMEOUT_SECONDS=60
# The root of the per-project run lock (acquire_run_lock): /tmp, not TMPDIR, so every run on this
# host finds the lock another run holds, whatever TMPDIR each was given.
LOCK_ROOT="/tmp"
# The hard limit of lock_refusal's read of another run's lock owner file: a few hundred bytes of
# a local file, so a read still running after it is one that will never end.
LOCK_READ_TIMEOUT_SECONDS=5
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
  -h, --help           Show this help and exit
Examples:
  A full run with every default, against the stack of Compose project pi-dev-mssql:
    scripts/portfolio-insights/loadgen-check.sh --project pi-dev-mssql
  A stack started with an override file on its own port, the table written to FILE:
    scripts/portfolio-insights/loadgen-check.sh --project NAME --base-url http://localhost:PORT \
        --compose-file compose.dev.yaml --compose-file OVERRIDE.yaml --out FILE
Takes roughly 2 x M + 20 minutes. One invocation per project runs at a time, a --resume-cleanup
included: it holds the lock directory /tmp/pi-loadgen-check.NAME.lock until it exits, and a
second invocation on the same project is refused while the first holds it. Remove a lock a
killed run left behind only once no run on that project is active. Run one project at a time,
never alongside e2e.sh or perf.sh.
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
                if [[ $# -lt 2 || -z "$2" ]]; then
                    usage_error "Option $1 requires a value."
                fi
                # A count option takes a negative number as its value, so the count check below
                # names the real problem. Any other value starting with - is refused unseen: it is
                # most likely the next option, and a misplaced argument can hold credentials.
                if [[ "$2" == -* ]] && ! [[ ("$1" == --weight || "$1" == --minutes) && "$2" =~ ^-[0-9] ]]; then
                    usage_error "Option $1 requires a value; the next argument starts with '-' and is not taken as one."
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
            -h | --help)
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

# http METHOD URL [BODY]: sets HTTP_STATUS (000 on a transport error), HTTP_BODY and HTTP_ERROR
# (curl's message on a transport error). Never trips set -e. BODY goes through stdin.
http() {
    local method="$1" url="$2" out rc=0
    local args=(-sS --max-time "$HTTP_TIMEOUT_SECONDS" -X "$method"
        -o "$RUN_DIR/body" -D "$RUN_DIR/headers" -w '%{http_code}'
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
        HTTP_ERROR="$(tr -d '\r' <"$RUN_DIR/curl-error" | head -c 300)"
    else
        HTTP_STATUS="$out"
        HTTP_ERROR=""
    fi
    HTTP_BODY="$(cat "$RUN_DIR/body")"
}

# jget FILTER JSON: prints jq's raw output, or nothing when the JSON does not parse. Raw output
# reads the string "true" as the boolean true, so jget only serves display; a flag reply goes
# through flag_reply.
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

# flag_reply BODY: whether BODY is the flag as feature-flag-service serializes flag/model.go's Flag
# for a GET or PUT of its path: exactly one JSON value, an object whose id is the string FLAG_ID,
# whose enabled and isModifiable are booleans, whose name, description and tag are strings, and
# whose enabledAt, omitted while the flag is off, is absent or a string holding the RFC 3339 time
# Go encodes a time.Time as: date, "T", time with up to nine fraction digits, then "Z" or a
# +hh:mm or -hh:mm offset, and nothing after it, not even a newline. Each type is checked as
# jq parsed it, so the string "true" is not the boolean true. On success FLAG_ENABLED and
# FLAG_MODIFIABLE are true or false. Otherwise it returns 1 with FLAG_REASON a fixed text naming
# the first rule the reply breaks, which never quotes the reply.
flag_reply() {
    local verdict re='^flag (true|false) (true|false)$'
    FLAG_ENABLED=""
    FLAG_MODIFIABLE=""
    FLAG_REASON=""
    # -s reads the whole body into one array, so a second value is counted; a body that does not
    # parse makes jq fail without output.
    verdict="$(jq -r -s --arg id "$FLAG_ID" '
        if length != 1 then "not one JSON value"
        else .[0]
            | if type != "object" then "not a JSON object"
            elif (.id | type) != "string" then "id is not a string"
            elif .id != $id then "id is not \($id)"
            elif (.enabled | type) != "boolean" then "enabled is not a boolean"
            elif (.isModifiable | type) != "boolean" then "isModifiable is not a boolean"
            elif (.name | type) != "string" then "name is not a string"
            elif (.description | type) != "string" then "description is not a string"
            elif (.tag | type) != "string" then "tag is not a string"
            elif has("enabledAt") and (.enabledAt | type) != "string" then "enabledAt is not a string"
            elif has("enabledAt") and (.enabledAt
                | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})\\z")
                | not)
            then "enabledAt is not an RFC 3339 time"
            else "flag \(.enabled) \(.isModifiable)"
            end
        end' 2>/dev/null <<<"$1")" || verdict=""
    verdict="${verdict//$'\r'/}"
    if [[ "$verdict" =~ $re ]]; then
        FLAG_ENABLED="${BASH_REMATCH[1]}"
        FLAG_MODIFIABLE="${BASH_REMATCH[2]}"
        return 0
    fi
    FLAG_REASON="${verdict:-not valid JSON}"
    return 1
}

# flag_answered WHAT: whether the last http call, the request WHAT, answered 200 with the flag
# (flag_reply). Otherwise it returns 1 with FLAG_REASON "WHAT gave STATUS" for another status or a
# transport error (status_text), or "WHAT gave status 200 with a reply that is not the flag: RULE".
flag_answered() {
    if [[ "$HTTP_STATUS" != "200" ]]; then
        FLAG_ENABLED=""
        FLAG_MODIFIABLE=""
        FLAG_REASON="$1 gave $(status_text)"
        return 1
    fi
    if ! flag_reply "$HTTP_BODY"; then
        FLAG_REASON="$1 gave status 200 with a reply that is not the flag: $FLAG_REASON"
        return 1
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
# .env for Compose's interpolation of the declaration both compose files carry. With LIMIT, as
# restore_loadgen calls it, the call has ended within LIMIT seconds (compose_within), with status
# 124 or 137 when cut off, and neither builds nor pulls: the container gets the local image its
# image reference names, the one check_loadgen_restorable found it running. Without it, as when a
# window opens and Compose may first have to build or pull the image, the call is not bounded.
recreate_loadgen() {
    if [[ -n "${3:-}" ]]; then
        PORTFOLIO_INSIGHTS_ALERT_WEIGHT="$1" compose_within "$3" up "${2:--d}" --no-deps --force-recreate \
            --no-build --pull never loadgen >>"$RUN_DIR/compose.log" 2>&1
    else
        PORTFOLIO_INSIGHTS_ALERT_WEIGHT="$1" compose up "${2:--d}" --no-deps --force-recreate loadgen \
            >>"$RUN_DIR/compose.log" 2>&1
    fi
}

# restore_loadgen: puts loadgen back as setup recorded it in LOADGEN_AT_START,
# LOADGEN_IMAGE_AT_START, LOADGEN_HASH_AT_START and LOADGEN_CONFIG_AT_START and verifies the
# result; on failure it sets RESTORE_ERROR. A container that existed is recreated alone with the
# PORTFOLIO_INSIGHTS_ALERT_WEIGHT it had, set or unset on that one command, so neither this shell
# nor .env replaces a weight the operator set elsewhere. Its other settings come from the same
# --compose-file files, so the weight is the only interpolated value this run overrides, and the
# recreate neither builds nor pulls. The result must match the start in its state (running or
# stopped), its weight entry, its image ID, the config hash Compose labels it with, the hash
# check_loadgen_restorable found these compose files give it, and its effective configuration
# (loadgen_config_snapshot), the one check_loadgen_restorable recorded at start and found a twin
# of it gets; RESTORE_ERROR names every one that differs, the configuration by each differing
# field (snapshot_differences). A loadgen stopped at start is recreated without being started
# rather than started and stopped: a visit run in between could create an alert and be cut off.
# Without a container at start, the one this run created is removed. Each Docker call has ended
# within DOCKER_CALL_TIMEOUT_SECONDS (hard_timeout), and RESTORE_ERROR tells a call Docker did not
# answer in time from one that failed.
restore_loadgen() {
    local start=-d entry actual identity image hash joined configuration rc=0
    local restored="$RUN_DIR/loadgen-restored.config.json"
    local -a differs=() fields=()
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
                compose_within "$DOCKER_CALL_TIMEOUT_SECONDS" up "$start" --no-deps --force-recreate \
                    --no-build --pull never loadgen >>"$RUN_DIR/compose.log" 2>&1
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
    if [[ "$LOADGEN_AT_START" != "no container" && "$actual" != "no container" ]]; then
        # Removed first, so a configuration this read does not write is never one read before.
        rm -f "$restored"
        identity="$(loadgen_identity "$restored")" || rc=$?
        if [[ $rc -ne 0 ]]; then
            RESTORE_ERROR="$(docker_problem "reading loadgen's image, config hash and effective configuration after the restore" "$rc" "$DOCKER_CALL_TIMEOUT_SECONDS")"
            return 1
        fi
        IFS=$'\t' read -r image hash _ <<<"$identity"
        if [[ "$image" != "$LOADGEN_IMAGE_AT_START" ]]; then
            differs+=("image ID $(short_digest "$image") instead of $(short_digest "$LOADGEN_IMAGE_AT_START") as at start")
        fi
        if [[ "$hash" != "$LOADGEN_HASH_AT_START" ]]; then
            differs+=("config hash $(short_digest "$hash") instead of $(short_digest "$LOADGEN_HASH_AT_START") as at start")
        fi
        # The configuration hash covers what Compose applied when it created the container at
        # start; what changed on that container since is in its effective configuration.
        if [[ -z "$LOADGEN_CONFIG_AT_START" ]]; then
            differs+=("no effective configuration was recorded at start to verify it against")
        elif ! configuration="$(snapshot_differences "$LOADGEN_CONFIG_AT_START" "$restored" restore)"; then
            differs+=("its effective configuration could not be compared with the one at start (see $RUN_DIR/compose.log)")
        elif [[ -n "$configuration" ]]; then
            mapfile -t fields <<<"$configuration"
            differs+=("${fields[@]}")
        fi
    fi
    if [[ "$actual" != "$LOADGEN_AT_START" ]]; then
        differs=("expected [$(loadgen_state_text "$LOADGEN_AT_START")] as at start, got [$(loadgen_state_text "$actual")]" "${differs[@]}")
    fi
    if [[ ${#differs[@]} -gt 0 ]]; then
        printf -v joined '%s; ' "${differs[@]}"
        RESTORE_ERROR="${joined%; }"
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
# loadgen rather than thawing it, and so is LOADGEN_TOUCHED, since a paused loadgen, the one found
# at start included, is no longer as at start for cleanup. Bounded as stop_loadgen is, or by LIMIT
# seconds when given.
pause_loadgen() {
    LOADGEN_PAUSED=1
    LOADGEN_TOUCHED=1
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

# The label Compose sets on every container it creates: the hash of the service configuration the
# container was created from, which docker compose config --hash prints for the configuration the
# compose files give the service now.
CONFIG_HASH_LABEL="com.docker.compose.config-hash"

# loadgen_identity [SNAPSHOT]: what restore_loadgen verifies of loadgen's container beyond
# loadgen_state, on one line of five tab-separated fields: its image ID, its CONFIG_HASH_LABEL
# hash, the image reference it was created from, the time it last started (.State.StartedAt) and
# its container ID as docker compose ps -q prints it. A field the container lacks is -, and jq's
# @tsv escapes a tab, line feed, carriage return or backslash inside one. With SNAPSHOT, the
# container's effective configuration, as loadgen_config_snapshot writes it from the same docker
# inspect, goes to the file SNAPSHOT. Prints nothing, and writes no SNAPSHOT, when the project has
# no loadgen container. Fails when a Compose or docker inspect call fails, with 124 or 137 when
# DOCKER_CALL_TIMEOUT_SECONDS cut one off, or when jq cannot read what docker inspect printed.
loadgen_identity() {
    local cid raw
    cid="$(compose_within "$DOCKER_CALL_TIMEOUT_SECONDS" ps -a -q loadgen 2>>"$RUN_DIR/compose.log" |
        tr -d '\r' | sed -n '1p')" || return
    if [[ -z "$cid" ]]; then
        return 0
    fi
    raw="$(hard_timeout "$DOCKER_CALL_TIMEOUT_SECONDS" docker inspect --format '{{json .}}' "$cid" </dev/null \
        2>>"$RUN_DIR/compose.log")" || return
    if [[ -n "${1:-}" ]]; then
        loadgen_config_snapshot <<<"$raw" >"$1" || return
    fi
    jq -r --arg label "$CONFIG_HASH_LABEL" --arg cid "$cid" '[.Image, (.Config.Labels // {})[$label],
        .Config.Image, .State.StartedAt, $cid] | map(if . == null or . == "" then "-" else tostring end)
        | @tsv' <<<"$raw" 2>>"$RUN_DIR/compose.log" | tr -d '\r'
}

# loadgen_config_snapshot: the effective configuration of the container whose docker inspect
# object is on stdin, as one canonical JSON document (jq -S): what a recreate from the compose
# files has to give loadgen back beyond its state. It holds the image ID; the container
# configuration (command, environment, labels and the rest) without its hostname, which is its
# short ID unless the compose files set one, and without the three labels Compose sets per
# container or per command rather than from the service: its number in the service, the
# container it replaced and the dependencies of the up that created it, empty for one with
# --no-deps; the host configuration, with the resource limits and restart policy docker update
# changes; and per network the endpoint settings a container is created or connected with: its
# aliases without the container's own name and IDs, IPAM configuration, links, driver options and
# gateway priority. What the engine derives while a container runs is left out, so a running
# container and one only created compare alike: the endpoint's addresses, and its DNS names,
# which are its name, aliases and IDs and are empty for a container not started. OomKillDisable
# null, as the engine leaves it once it starts a container on a kernel without that control,
# counts as false, as Compose creates it. Orders without meaning that Compose does not keep from
# one create to the next are sorted: the environment, whose names are unique, and the host
# configuration's lists other than the DNS ones and the console size. Fails when stdin holds no
# JSON object (jq -e), an empty one included.
loadgen_config_snapshot() {
    jq -e -S '. as $c
        | [($c.Name // "" | ltrimstr("/")), ($c.Id // ""), (($c.Id // "")[0:12])]
        | map(select(. != "")) as $own
        | {Image: $c.Image,
            Config: (($c.Config // {}) | del(.Hostname)
                | .Labels = ((.Labels // {}) | del(.["com.docker.compose.container-number"],
                    .["com.docker.compose.replace"], .["com.docker.compose.depends_on"]))
                | if (.Env | type) == "array" then .Env |= sort else . end),
            HostConfig: (($c.HostConfig // {}) | .OomKillDisable |= (. // false)
                | with_entries(if (.value | type) == "array"
                    and (.key | IN("ConsoleSize", "Dns", "DnsOptions", "DnsSearch") | not)
                    then .value |= sort else . end)),
            Networks: (($c.NetworkSettings.Networks // {}) | map_values({
                Aliases: ((.Aliases // []) - $own | sort), IPAMConfig, Links, DriverOpts,
                GwPriority}))}' 2>>"$RUN_DIR/compose.log" | tr -d '\r'
}

# container_snapshot ID FILE: the effective configuration of container ID, as
# loadgen_config_snapshot writes it, in FILE, from one docker inspect. Fails when the call fails,
# with 124 or 137 when DOCKER_CALL_TIMEOUT_SECONDS cut it off (hard_timeout), or when jq cannot
# read what it printed.
container_snapshot() {
    local raw
    raw="$(hard_timeout "$DOCKER_CALL_TIMEOUT_SECONDS" docker inspect --format '{{json .}}' "$1" </dev/null \
        2>>"$RUN_DIR/compose.log")" || return
    loadgen_config_snapshot <<<"$raw" >"$2"
}

# How many differing fields snapshot_differences names before it counts the rest.
SNAPSHOT_FIELDS_SHOWN=10

# snapshot_value KIND TEXT: a value of snapshot_differences for a report line: a string as
# printf %q writes it, a number, boolean or null as JSON writes it, a list or map only as such,
# never its content, and a field one side lacks as absent.
snapshot_value() {
    case "$1" in
        string) printf '%q' "$2" ;;
        scalar) printf '%s' "$2" ;;
        list) printf 'a list' ;;
        map) printf 'a map' ;;
        *) printf 'absent' ;;
    esac
}

# snapshot_differences START OTHER MODE: one line per field in which OTHER, an effective
# configuration as loadgen_config_snapshot writes it, differs from START, the one recorded at
# start; the first SNAPSHOT_FIELDS_SHOWN of them, then a line counting the rest. A field is a
# setting of Config or HostConfig, a label of Config.Labels, a network of Networks or one
# endpoint setting of a network, named by its path, as HostConfig.CpuShares. MODE check words
# a line for the restorability check, "its FIELD is A, a recreate gives B", and MODE restore for
# the restore's verification, "FIELD B instead of A as at start"; values are written by
# snapshot_value, and two lists or maps that differ are named without either value, so the
# environment never reaches a report line. The image ID and the labels holding it and the config
# hash are left to the checks of loadgen_identity's fields, which name them shortened, so no
# difference is reported twice. Prints nothing when the two match. Fails when either file is
# missing or no JSON document.
snapshot_differences() {
    local rows path a_kind a_text b_kind b_text a b count=0
    rows="$(cat -- "$1" "$2" 2>>"$RUN_DIR/compose.log" | jq -s -r '
        def shown: if type == "string" then ["string", .] elif type == "array" then ["list", ""]
            elif type == "object" then ["map", ""] else ["scalar", tojson] end;
        def descend($p): ($p | length) < 2 or $p == ["Config", "Labels"]
            or (($p | length) == 2 and $p[0] == "Networks");
        def diffs($a; $b; $p):
            if $a == $b then empty
            elif ($a | type) == "object" and ($b | type) == "object" and descend($p) then
                (($a | keys) + ($b | keys) | unique[]) as $k
                | if ($a | has($k)) and ($b | has($k)) then diffs($a[$k]; $b[$k]; $p + [$k])
                  elif $a | has($k) then [$p + [$k], ($a[$k] | shown), ["absent", ""]]
                  else [$p + [$k], ["absent", ""], ($b[$k] | shown)] end
            else [$p, ($a | shown), ($b | shown)] end;
        if length != 2 then error("two configurations expected") else . end
        | diffs(.[0]; .[1]; [])
        | select(.[0] | IN(["Image"], ["Config", "Labels", "com.docker.compose.config-hash"],
            ["Config", "Labels", "com.docker.compose.image"]) | not)
        | [(.[0] | map(if test("^[A-Za-z0-9_.-]+$") then . else tojson end) | join(".")
            | if . == "" then "configuration" else . end), .[1][0], .[1][1], .[2][0], .[2][1]]
        | map(@base64) | join(":")' 2>>"$RUN_DIR/compose.log" | tr -d '\r')" || return
    while IFS=: read -r path a_kind a_text b_kind b_text; do
        if [[ -z "$path" ]]; then
            continue
        fi
        count=$((count + 1))
        if [[ $count -gt $SNAPSHOT_FIELDS_SHOWN ]]; then
            continue
        fi
        path="$(base64 -d <<<"$path")"
        a_kind="$(base64 -d <<<"$a_kind")"
        b_kind="$(base64 -d <<<"$b_kind")"
        # The x keeps a trailing line feed of a string value.
        a_text="$(base64 -d <<<"$a_text" && printf x)"
        b_text="$(base64 -d <<<"$b_text" && printf x)"
        a="$(snapshot_value "$a_kind" "${a_text%x}")"
        b="$(snapshot_value "$b_kind" "${b_text%x}")"
        if [[ "$a_kind" =~ ^(list|map)$ && "$b_kind" =~ ^(list|map)$ ]]; then
            if [[ "$3" == check ]]; then
                echo "its $path differs from what a recreate gives"
            else
                echo "$path differs from the one at start"
            fi
        elif [[ "$3" == check ]]; then
            echo "its $path is $a, a recreate gives $b"
        else
            echo "$path $b instead of $a as at start"
        fi
    done <<<"$rows"
    if [[ $count -gt $SNAPSHOT_FIELDS_SHOWN ]]; then
        echo "$((count - SNAPSHOT_FIELDS_SHOWN)) more fields differ"
    fi
}

# short_digest VALUE: VALUE, an image ID or a config hash, for a report line: a SHA-256 digest,
# with or without its sha256: prefix, as its first 12 hex digits, as docker shortens IDs; - or
# nothing as none; anything else as printf %q writes it.
short_digest() {
    if [[ "$1" =~ ^(sha256:)?([0-9a-f]{64})$ ]]; then
        printf '%s' "${BASH_REMATCH[2]:0:12}"
    elif [[ -z "$1" || "$1" == "-" ]]; then
        printf 'none'
    else
        printf '%q' "$1"
    fi
}

# loadgen_start_text: loadgen as setup recorded it and restore_loadgen verifies it, for a report
# line: loadgen_state_text of LOADGEN_AT_START and, for a container, its image ID and config hash
# as short_digest writes them and its effective configuration, named only, as recorded at start.
loadgen_start_text() {
    loadgen_state_text "$LOADGEN_AT_START"
    if [[ "$LOADGEN_AT_START" != "no container" ]]; then
        printf ', image ID %s, config hash %s, effective configuration verified as recorded at start' \
            "$(short_digest "$LOADGEN_IMAGE_AT_START")" "$(short_digest "$LOADGEN_HASH_AT_START")"
    fi
}

# predicted_loadgen_hash: the hash of the configuration these compose files give loadgen now, as
# docker compose config --hash prints it, under the PORTFOLIO_INSIGHTS_ALERT_WEIGHT restore_loadgen
# recreates loadgen with: the value LOADGEN_AT_START records, set on that one command, or unset in
# the command substitution's subshell when it was unset. Compose labels the container it creates
# with that hash. Fails when the call fails or prints no hash, with 124 or 137 when
# DOCKER_CALL_TIMEOUT_SECONDS cut it off.
predicted_loadgen_hash() {
    local entry="${LOADGEN_AT_START#*, }" out rc=0
    if [[ "$entry" == PORTFOLIO_INSIGHTS_ALERT_WEIGHT=* ]]; then
        out="$(PORTFOLIO_INSIGHTS_ALERT_WEIGHT="${entry#PORTFOLIO_INSIGHTS_ALERT_WEIGHT=}" \
            compose_within "$DOCKER_CALL_TIMEOUT_SECONDS" config --hash loadgen 2>>"$RUN_DIR/compose.log")" ||
            rc=$?
    else
        out="$(
            unset PORTFOLIO_INSIGHTS_ALERT_WEIGHT
            compose_within "$DOCKER_CALL_TIMEOUT_SECONDS" config --hash loadgen 2>>"$RUN_DIR/compose.log"
        )" || rc=$?
    fi
    if [[ $rc -ne 0 ]]; then
        return "$rc"
    fi
    out="${out//$'\r'/}"
    if [[ ! "$out" =~ ^loadgen\ ([0-9a-f]{64})$ ]]; then
        printf 'docker compose config --hash loadgen printed no hash: %q\n' "$out" >>"$RUN_DIR/compose.log"
        return 1
    fi
    printf '%s' "${BASH_REMATCH[1]}"
}

# loadgen_declares_weight: true when these compose files declare PORTFOLIO_INSIGHTS_ALERT_WEIGHT in
# loadgen's environment, false otherwise, read from docker compose config without interpolation,
# so no value of this shell or .env enters the read. Fails when the call fails, with 124 or 137
# when DOCKER_CALL_TIMEOUT_SECONDS cut it off.
loadgen_declares_weight() {
    compose_within "$DOCKER_CALL_TIMEOUT_SECONDS" config --no-interpolate --format json 2>>"$RUN_DIR/compose.log" |
        jq -r --arg name PORTFOLIO_INSIGHTS_ALERT_WEIGHT '(.services.loadgen.environment // {})
            | if type == "array" then any(.[]; . == $name or startswith($name + "=")) else has($name) end' \
            2>>"$RUN_DIR/compose.log" | tr -d '\r'
}

# image_id_of REFERENCE: the ID of the local image REFERENCE names now, the image a recreate with
# --pull never runs. Fails when no local image has that name or the call fails, with 124 or 137
# when DOCKER_CALL_TIMEOUT_SECONDS cut it off.
image_id_of() {
    hard_timeout "$DOCKER_CALL_TIMEOUT_SECONDS" docker image inspect --format '{{.Id}}' "$1" </dev/null \
        2>>"$RUN_DIR/compose.log" | tr -d '\r'
}

# loadgen_container_ids: the IDs of every loadgen container of the project, created and stopped
# ones included, one per line as docker compose ps -q prints them. Fails when the call fails,
# with 124 or 137 when DOCKER_CALL_TIMEOUT_SECONDS cut it off (compose_within).
loadgen_container_ids() {
    compose_within "$DOCKER_CALL_TIMEOUT_SECONDS" ps -a -q loadgen 2>>"$RUN_DIR/compose.log" | tr -d '\r' |
        { grep -v '^$' || true; }
}

# loadgen_twin_ids: the IDs of the project's loadgen containers other than the one setup found
# (LOADGEN_ID_AT_START), one per line: twins create_loadgen_twin made, as check_loadgen_restorable
# creates one only while that container is the project's only loadgen container. Fails as
# loadgen_container_ids does.
loadgen_twin_ids() {
    local ids id
    ids="$(loadgen_container_ids)" || return
    while IFS= read -r id; do
        if [[ -n "$id" && "$id" != "$LOADGEN_ID_AT_START" ]]; then
            printf '%s\n' "$id"
        fi
    done <<<"$ids"
}

# create_loadgen_twin: creates one more loadgen container in the project, not started, exactly as
# restore_loadgen's recreate creates loadgen: from these compose files, with the
# PORTFOLIO_INSIGHTS_ALERT_WEIGHT LOADGEN_AT_START records set on that one command, or unset in a
# subshell when it was unset, neither building nor pulling, and with no other service touched.
# --no-recreate leaves the container found at start as it is, running or not. The call has ended
# within DOCKER_CALL_TIMEOUT_SECONDS (compose_within), with status 124 or 137 when cut off.
create_loadgen_twin() {
    local entry="${LOADGEN_AT_START#*, }"
    if [[ "$entry" == PORTFOLIO_INSIGHTS_ALERT_WEIGHT=* ]]; then
        PORTFOLIO_INSIGHTS_ALERT_WEIGHT="${entry#PORTFOLIO_INSIGHTS_ALERT_WEIGHT=}" \
            compose_within "$DOCKER_CALL_TIMEOUT_SECONDS" up --no-start --no-deps --no-recreate --no-build \
            --pull never --scale loadgen=2 loadgen >>"$RUN_DIR/compose.log" 2>&1
    else
        (
            unset PORTFOLIO_INSIGHTS_ALERT_WEIGHT
            compose_within "$DOCKER_CALL_TIMEOUT_SECONDS" up --no-start --no-deps --no-recreate --no-build \
                --pull never --scale loadgen=2 loadgen >>"$RUN_DIR/compose.log" 2>&1
        )
    fi
}

# remove_loadgen_twin: removes the twin loadgen container LOADGEN_TWIN names by its ID, or, when
# LOADGEN_TWIN is "unknown" because a create may have made one whose ID was not read, every
# loadgen container but the one setup found (loadgen_twin_ids), then checks that none of them is
# listed any more. LOADGEN_TWIN is then empty, and TWIN_REMOVED holds the short IDs removed,
# empty when there was none. Otherwise TWIN_ERROR says what failed, telling a call Docker did not
# answer in time from one that failed. docker rm --force succeeds for a container already gone,
# and --volumes takes any anonymous volume the twin got with it. Each Docker call has ended
# within DOCKER_CALL_TIMEOUT_SECONDS (hard_timeout).
remove_loadgen_twin() {
    local ids id rm_error="" rc=0
    local -a twins=()
    TWIN_ERROR=""
    TWIN_REMOVED=""
    if [[ "$LOADGEN_TWIN" == "unknown" ]]; then
        ids="$(loadgen_twin_ids)" || rc=$?
        if [[ $rc -ne 0 ]]; then
            TWIN_ERROR="$(docker_problem "listing loadgen's containers to find its twin" "$rc" "$DOCKER_CALL_TIMEOUT_SECONDS")"
            return 1
        fi
        if [[ -n "$ids" ]]; then
            mapfile -t twins <<<"$ids"
        fi
    elif [[ -n "$LOADGEN_TWIN" ]]; then
        twins=("$LOADGEN_TWIN")
    fi
    if [[ ${#twins[@]} -eq 0 ]]; then
        LOADGEN_TWIN=""
        return 0
    fi
    for id in "${twins[@]}"; do
        rc=0
        hard_timeout "$DOCKER_CALL_TIMEOUT_SECONDS" docker rm --force --volumes "$id" </dev/null \
            >>"$RUN_DIR/compose.log" 2>&1 || rc=$?
        if [[ $rc -ne 0 && -z "$rm_error" ]]; then
            rm_error="$(docker_problem "removing twin loadgen container $(short_digest "$id")" "$rc" "$DOCKER_CALL_TIMEOUT_SECONDS")"
        fi
    done
    rc=0
    ids="$(loadgen_container_ids)" || rc=$?
    if [[ $rc -ne 0 ]]; then
        TWIN_ERROR="${rm_error:+$rm_error; }$(docker_problem "listing loadgen's containers after removing its twin" "$rc" "$DOCKER_CALL_TIMEOUT_SECONDS")"
        return 1
    fi
    for id in "${twins[@]}"; do
        if grep -qxF -e "$id" <<<"$ids"; then
            TWIN_ERROR="${rm_error:-twin loadgen container $(short_digest "$id") is still listed after its removal}"
            return 1
        fi
        TWIN_REMOVED="${TWIN_REMOVED:+$TWIN_REMOVED }$(short_digest "$id")"
    done
    LOADGEN_TWIN=""
}

# loadgen_twin_check CONFIG: the twin step of check_loadgen_restorable, for the loadgen container
# setup found (LOADGEN_ID_AT_START), whose effective configuration is in the file CONFIG. That
# container must be the project's only loadgen container, as a restore recreates one. A twin is
# then created as a restore would create loadgen (create_loadgen_twin), its effective
# configuration read into $RUN_DIR/loadgen-twin.config.json (container_snapshot), and the twin
# removed (remove_loadgen_twin) before the two are compared (snapshot_differences). Returns 0 when
# they match, with no twin left. Otherwise sets TWIN_DETAIL, the check's failure: each field that
# differs, with its two values, or the step that failed and whether a twin is left; a twin not
# confirmed removed stays in LOADGEN_TWIN, for cleanup to remove. No other container is created,
# changed or removed either way.
loadgen_twin_check() {
    local twin="$RUN_DIR/loadgen-twin.config.json" ids count create_error differences joined rc=0
    local -a fields=()
    TWIN_DETAIL=""
    ids="$(loadgen_container_ids)" || rc=$?
    if [[ $rc -ne 0 ]]; then
        TWIN_DETAIL="$(docker_problem "listing loadgen's containers" "$rc" "$DOCKER_CALL_TIMEOUT_SECONDS"); nothing was changed"
        return 1
    fi
    count="$(grep -c . <<<"$ids" || true)"
    if [[ $count -eq 0 ]]; then
        TWIN_DETAIL="loadgen's container was removed while setup read it; nothing was changed"
        return 1
    elif [[ $count -gt 1 ]]; then
        TWIN_DETAIL="the project has $count loadgen containers, and a restore recreates one only; nothing was changed"
        return 1
    elif [[ "$ids" != "$LOADGEN_ID_AT_START" ]]; then
        TWIN_DETAIL="loadgen's container was replaced while setup read it; nothing was changed"
        return 1
    fi
    # From here until remove_loadgen_twin has seen it gone, cleanup removes any twin left.
    LOADGEN_TWIN="unknown"
    create_loadgen_twin || rc=$?
    if [[ $rc -ne 0 ]]; then
        create_error="$(docker_problem "creating a twin loadgen container" "$rc" "$DOCKER_CALL_TIMEOUT_SECONDS")"
        if remove_loadgen_twin; then
            TWIN_DETAIL="$create_error; no twin is left and nothing else was changed"
        else
            TWIN_DETAIL="$create_error; a twin it may have made is not confirmed removed ($TWIN_ERROR), so cleanup removes it on exit"
        fi
        return 1
    fi
    ids="$(loadgen_twin_ids)" || rc=$?
    if [[ $rc -ne 0 ]]; then
        TWIN_DETAIL="$(docker_problem "listing loadgen's containers after creating its twin" "$rc" "$DOCKER_CALL_TIMEOUT_SECONDS"); cleanup removes the twin on exit"
        return 1
    fi
    count="$(grep -c . <<<"$ids" || true)"
    if [[ $count -ne 1 ]]; then
        if remove_loadgen_twin; then
            TWIN_DETAIL="creating a twin loadgen container gave $count new loadgen containers instead of 1; none is left and nothing else was changed"
        else
            TWIN_DETAIL="creating a twin loadgen container gave $count new loadgen containers instead of 1, not confirmed removed ($TWIN_ERROR), so cleanup removes them on exit"
        fi
        return 1
    fi
    LOADGEN_TWIN="$ids"
    container_snapshot "$LOADGEN_TWIN" "$twin" || rc=$?
    # Removed before the comparison, so no outcome of it leaves the twin behind.
    if ! remove_loadgen_twin; then
        TWIN_DETAIL="twin loadgen container $(short_digest "$LOADGEN_TWIN") not removed: $TWIN_ERROR; cleanup removes it on exit"
        return 1
    fi
    if [[ $rc -ne 0 ]]; then
        TWIN_DETAIL="$(docker_problem "reading the twin loadgen container's effective configuration" "$rc" "$DOCKER_CALL_TIMEOUT_SECONDS"); the twin is removed and nothing else was changed"
        return 1
    fi
    differences="$(snapshot_differences "$1" "$twin" check)" || rc=$?
    if [[ $rc -ne 0 ]]; then
        TWIN_DETAIL="comparing loadgen's effective configuration with its twin's failed (see $RUN_DIR/compose.log); the twin is removed and nothing else was changed"
        return 1
    fi
    if [[ -n "$differences" ]]; then
        mapfile -t fields <<<"$differences"
        printf -v joined '%s; ' "${fields[@]}"
        TWIN_DETAIL="a recreate from these compose files would not give loadgen back as it is, so the run changes nothing: ${joined%; }; the twin that shows it is removed"
        return 1
    fi
}

# check_loadgen_restorable: the check "loadgen restorable", which setup runs before the run changes
# anything. restore_loadgen puts a loadgen container back by recreating it from these compose
# files with its weight at start, neither building nor pulling, so the container is restorable
# when that recreate gives what it has now: the hash these compose files give loadgen under that
# weight (predicted_loadgen_hash) equals its CONFIG_HASH_LABEL, so every setting Compose applies
# matches, and the image reference it was created from still names the image it runs. The hash
# covers only what Compose applied when it created the container, so its effective configuration
# (loadgen_config_snapshot), read with its image ID and hash before anything changes, must also
# match a twin created as the restore would create loadgen (loadgen_twin_check), which shows
# what was changed on the container since, as docker update changes resource limits. Its image
# ID, hash and effective configuration then go to LOADGEN_IMAGE_AT_START, LOADGEN_HASH_AT_START
# and LOADGEN_CONFIG_AT_START, which restore_loadgen verifies, and its start time to
# LOADGEN_STARTED_AT, from which secure_loadgen_at_start reads its output. Otherwise the run ends
# with nothing changed, naming each difference. Without a loadgen container the check passes:
# cleanup removes the one the run creates. Each Docker call has ended within
# DOCKER_CALL_TIMEOUT_SECONDS (hard_timeout).
check_loadgen_restorable() {
    local check="loadgen restorable" entry="${LOADGEN_AT_START#*, }" weight="" identity image hash ref
    local started cid predicted resolved declared joined rc=0
    local config="$RUN_DIR/loadgen-at-start.config.json"
    local -a differs=()
    if [[ "$LOADGEN_AT_START" == "no container" ]]; then
        pass "$check: no loadgen container at start; the one this run creates is removed on exit"
        return 0
    fi
    identity="$(loadgen_identity "$config")" || rc=$?
    if [[ $rc -ne 0 ]]; then
        abort "$check" "$(docker_problem "reading loadgen's image, config hash and effective configuration" "$rc" "$DOCKER_CALL_TIMEOUT_SECONDS")"
    fi
    if [[ -z "$identity" ]]; then
        abort "$check" "loadgen's container was removed while setup read it; nothing was changed"
    fi
    IFS=$'\t' read -r image hash ref started cid <<<"$identity"
    predicted="$(predicted_loadgen_hash)" || rc=$?
    if [[ $rc -ne 0 ]]; then
        abort "$check" "$(docker_problem "docker compose config --hash loadgen" "$rc" "$DOCKER_CALL_TIMEOUT_SECONDS")"
    fi
    if [[ "$hash" != "$predicted" ]]; then
        differs+=("these compose files give loadgen config hash $(short_digest "$predicted") under its weight at start, its container has $(short_digest "$hash")")
        case "$entry" in
            "PORTFOLIO_INSIGHTS_ALERT_WEIGHT unset") weight="unset" ;;
            "PORTFOLIO_INSIGHTS_ALERT_WEIGHT=") weight="empty" ;;
        esac
        if [[ -n "$weight" ]]; then
            declared="$(loadgen_declares_weight)" || rc=$?
            if [[ $rc -ne 0 ]]; then
                differs+=("whether these compose files declare PORTFOLIO_INSIGHTS_ALERT_WEIGHT is unknown: $(docker_problem "docker compose config --no-interpolate" "$rc" "$DOCKER_CALL_TIMEOUT_SECONDS")")
            elif [[ "$declared" == "true" ]]; then
                differs+=("its PORTFOLIO_INSIGHTS_ALERT_WEIGHT is $weight, and these compose files always declare it")
            fi
        fi
    fi
    rc=0
    if [[ "$ref" == "-" ]]; then
        differs+=("its container records no image reference to recreate it from")
    else
        resolved="$(image_id_of "$ref")" || rc=$?
        if [[ $rc -ne 0 ]]; then
            differs+=("its image reference $(printf '%q' "$ref") names no image a recreate could run: $(docker_problem "docker image inspect" "$rc" "$DOCKER_CALL_TIMEOUT_SECONDS")")
        elif [[ "$resolved" != "$image" ]]; then
            differs+=("its image reference $(printf '%q' "$ref") now names image ID $(short_digest "$resolved"), its container runs $(short_digest "$image")")
        fi
    fi
    if [[ ${#differs[@]} -gt 0 ]]; then
        printf -v joined '%s; ' "${differs[@]}"
        abort "$check" "a recreate from these compose files would not give loadgen back as it is, so the run changes nothing: ${joined%; }"
    fi
    LOADGEN_ID_AT_START="$cid"
    if ! loadgen_twin_check "$config"; then
        abort "$check" "$TWIN_DETAIL"
    fi
    LOADGEN_IMAGE_AT_START="$image"
    LOADGEN_HASH_AT_START="$hash"
    LOADGEN_CONFIG_AT_START="$config"
    LOADGEN_STARTED_AT="$started"
    pass "$check: image ID $(short_digest "$image") ($(printf '%q' "$ref")) and config hash $(short_digest "$hash"), as these compose files give it, and a twin created from them, now removed, matched its effective configuration"
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

# report_outcomes FILE [PREFIX]: one INFO line per line of FILE, an outcome line of run B, or of
# loadgen's output at start, each line starting with PREFIX (default: outcome). Only parsed fields
# are printed: the id and status token of an alert left in place, or the threshold marker of an
# unconfirmed create. A line in neither form gets a fixed notice, never its text.
report_outcomes() {
    local line id status prefix="${2:-outcome}"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ $LEFT_RE ]]; then
            status="${BASH_REMATCH[2]}"
            id="$(lower <<<"${BASH_REMATCH[1]}")"
            if [[ "$id" =~ $UUID_RE ]]; then
                info "$prefix: alert [$id] left in place: $status"
                continue
            fi
        elif [[ "$line" =~ $UNCONFIRMED_RE ]]; then
            info "$prefix: unconfirmed create, threshold [${BASH_REMATCH[1]}], outcome unknown"
            continue
        fi
        info "$prefix: a line in no known outcome form, not printed"
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

# put_flag VALUE: PUTs {"enabled": VALUE}, which feature-flag-service answers with the updated
# flag, and then reads the flag back. Succeeds when both answer 200 with the flag (flag_reply) at
# VALUE. Otherwise it returns 1 at the first step that fails, with FLAG_REASON a fixed text naming
# the request and why.
put_flag() {
    local value="$1" put="PUT {\"enabled\": $1}"
    http PUT "$FLAG_URL" "{\"enabled\": $value}"
    flag_answered "$put" || return 1
    if [[ "$FLAG_ENABLED" != "$value" ]]; then
        FLAG_REASON="$put gave status 200 with enabled=$FLAG_ENABLED, expected $value"
        return 1
    fi
    http GET "$FLAG_URL"
    flag_answered "read-back" || return 1
    if [[ "$FLAG_ENABLED" != "$value" ]]; then
        FLAG_REASON="read-back gave status 200 with enabled=$FLAG_ENABLED, expected $value"
        return 1
    fi
}

# set_flag CHECK VALUE: put_flag VALUE. PASS CHECK when the PUT and the read-back both give the
# flag at VALUE; otherwise the run ends.
set_flag() {
    local check="$1" value="$2"
    FLAG_TOUCHED=1
    if ! put_flag "$value"; then
        abort "$check" "$FLAG_REASON"
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

# The run lock: one invocation per Compose project runs at a time. setup, or resume_cleanup for a
# --resume-cleanup, takes it with mkdir, which creates the directory or fails in one step, so of
# two invocations on one project only one gets it and the other stops before it records a
# baseline, reads the flag or changes anything. The directory holds an owner file naming its run,
# and cleanup, or resume_exit, removes both last, only when this run created them.

# acquire_run_lock: creates LOCK_DIR for PROJECT under LOCK_ROOT, records this run in its owner
# file and sets LOCK_HELD to 1. Otherwise it ends the run with a FAIL of the run lock check: for a
# project name that is no Compose project name, for a lock another run holds, naming that run,
# and for a directory that cannot be created.
acquire_run_lock() {
    local name_re='^[abcdefghijklmnopqrstuvwxyz0123456789][abcdefghijklmnopqrstuvwxyz0123456789_-]*$'
    local error
    # The name becomes part of a path. Compose has accepted it already, and this keeps the path to
    # a Compose project name whatever Compose accepts.
    if [[ ! "$PROJECT" =~ $name_re ]]; then
        abort "run lock" "project name [$(printf '%q' "$PROJECT")] is not a Compose project name (lower-case letters, digits, - and _, starting with a letter or digit), so no lock is taken for it"
    fi
    LOCK_DIR="$LOCK_ROOT/pi-loadgen-check.$PROJECT.lock"
    if ! error="$(mkdir "$LOCK_DIR" 2>&1)"; then
        if [[ -d "$LOCK_DIR" ]]; then
            abort "run lock" "$(lock_refusal)"
        fi
        abort "run lock" "could not create $LOCK_DIR: $(join_lines <<<"$error")"
    fi
    LOCK_HELD=1
    # Written aside and renamed into place, so a run reading it finds all of it or none of it.
    if ! error="$( {
        printf 'pid=%s\nhost=%s\nstarted=%s\nrun_dir=%s\n' "$$" "${HOSTNAME:-}" "$STARTED_AT" "$RUN_DIR" \
            >"$LOCK_DIR/owner.new" && mv -f "$LOCK_DIR/owner.new" "$LOCK_DIR/owner"
    } 2>&1)"; then
        abort "run lock" "created $LOCK_DIR but could not record this run in it: $(join_lines <<<"$error")"
    fi
    pass "run lock: $LOCK_DIR"
}

# lock_refusal: why LOCK_DIR stops this run, naming the run its owner file records (start time,
# pid, host and run dir) and how the lock is cleared. A field is shown only in the form
# acquire_run_lock writes it, so no other text of the file reaches the output. Only a regular
# owner file, never a symlink, is read, and that read has ended within LOCK_READ_TIMEOUT_SECONDS
# (hard_timeout): a FIFO, a device or a symlink in its place, or a read that fails or is cut off,
# leaves every field unknown, so no owner entry can hold the run. A run recorded on this host
# whose pid no longer answers kill -0 has ended and left the lock stale. The lock is never removed
# here: it may be one another run has only just created.
lock_refusal() {
    local alnum='0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz' d='0123456789'
    local started_re="^[$d]{4}-[$d]{2}-[$d]{2}T[$d]{2}:[$d]{2}:[$d]{2}Z\$"
    local pid_re="^[123456789][$d]{0,9}\$"
    local host_re="^[$alnum][$alnum._-]{0,252}\$"
    # Bounded by length rather than by an interval: a regex library may allow no more than 255.
    local dir_re="^[$alnum /._:~+-]+\$"
    local content="" line value started="" pid="" host="" run_dir="" holder
    # At most 4 KiB, read in one step, so a file that grows or goes meanwhile cannot hold the run;
    # the time limit also ends the read of an entry swapped for a FIFO after the type test.
    if [[ -f "$LOCK_DIR/owner" && ! -L "$LOCK_DIR/owner" ]]; then
        content="$(hard_timeout "$LOCK_READ_TIMEOUT_SECONDS" head -c 4096 -- "$LOCK_DIR/owner" 2>/dev/null)" || content=""
    fi
    while IFS= read -r line; do
        value="${line#*=}"
        case "${line%%=*}" in
            started) if [[ -z "$started" && "$value" =~ $started_re ]]; then started="$value"; fi ;;
            pid) if [[ -z "$pid" && "$value" =~ $pid_re ]]; then pid="$value"; fi ;;
            host) if [[ -z "$host" && "$value" =~ $host_re ]]; then host="$value"; fi ;;
            run_dir) if [[ -z "$run_dir" && ${#value} -le 1024 && "$value" =~ $dir_re ]]; then run_dir="$value"; fi ;;
        esac
    done <<<"$content"
    holder="started ${started:-unknown}, pid ${pid:-unknown}, host ${host:-unknown}, run dir ${run_dir:-unknown}"
    printf '%s' "project [$PROJECT] is in use by another run, which holds $LOCK_DIR ($holder). One invocation per project runs at a time, so this run stops before it reads or changes anything."
    if [[ -n "$pid" && -n "$host" && "$host" == "${HOSTNAME:-}" ]] && ! kill -0 "$pid" 2>/dev/null; then
        printf '%s' " Pid $pid no longer runs on this host, so that run has ended and left the lock stale: remove $LOCK_DIR once no run on the project is active, and start again."
    else
        printf '%s' " If no run on the project is active, as after a run killed before its cleanup, remove $LOCK_DIR and start again."
    fi
}

# release_run_lock: removes the lock this run holds, its owner file first, and sets LOCK_HELD to
# 0; on failure sets LOCK_ERROR. It removes only what acquire_run_lock wrote, so a lock directory
# holding anything else stays and is reported.
release_run_lock() {
    local error
    if error="$( { rm -f "$LOCK_DIR/owner" "$LOCK_DIR/owner.new" && rmdir "$LOCK_DIR"; } 2>&1)"; then
        LOCK_HELD=0
        return 0
    fi
    LOCK_ERROR="removing $LOCK_DIR failed: $(join_lines <<<"$error")"
    return 1
}

setup() {
    local defined required running missing="" service state_rc=0
    if ! defined="$(compose config --services 2>>"$RUN_DIR/compose.log" | tr -d '\r')"; then
        abort "readiness" "docker compose config failed for project [$PROJECT] (see $RUN_DIR/compose.log)"
    fi
    # Before anything is recorded or changed: a run that finds the project's lock held stops here,
    # so it never takes another run's test settings for the state to restore.
    acquire_run_lock
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
    # A loadgen that cleanup could not put back as it is ends the run here, before any change.
    check_loadgen_restorable
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

    # Only a reply that is the flag (flag_reply) sets the value cleanup restores, and a failure
    # names the broken rule, never the reply's content.
    http GET "$FLAG_URL"
    if ! flag_answered "GET $FLAG_ID"; then
        abort "flag modifiable" "$FLAG_REASON"
    fi
    if [[ "$FLAG_MODIFIABLE" != "true" ]]; then
        abort "flag modifiable" "isModifiable is [false]; a deployment with ENABLE_MODIFY=false cannot be toggled"
    fi
    FLAG_INITIAL="$FLAG_ENABLED"
    pass "flag modifiable"
    info "flag $FLAG_ID initially enabled=$FLAG_INITIAL"
}

# ---------------------------------------------------------------------------------------------
# Loadgen at start

# How the outcomes of loadgen's output at start are reported: that workload's alerts are none of
# this run's, so they are never owned or deleted.
AT_START_PREFIX="loadgen at start (not this run's, not deleted)"
# An RFC 3339 time, as docker inspect gives a container's .State.StartedAt.
STARTED_AT_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$'

# loadgen_run_state CID: the run state of the container whose full ID is CID, so of that
# container and no other, on one line of three tab-separated fields: its .State.Status (running,
# paused, exited, ...), .State.Paused (true or false) and .State.StartedAt, each - when missing,
# and escaped by jq's @tsv; nothing when docker inspect prints no state. Fails when that container
# no longer exists or a Docker call fails, with 124 or 137 when DOCKER_CALL_TIMEOUT_SECONDS cut
# the call off (hard_timeout).
loadgen_run_state() {
    hard_timeout "$DOCKER_CALL_TIMEOUT_SECONDS" docker inspect --type container --format '{{json .State}}' "$1" \
        </dev/null 2>>"$RUN_DIR/compose.log" |
        jq -r '[.Status, .Paused, .StartedAt] | map(if . == null or . == "" then "-" else tostring end)
            | @tsv' 2>>"$RUN_DIR/compose.log" | tr -d '\r'
}

# run_state_text STATE: STATE, a loadgen_run_state line, for a report line.
run_state_text() {
    local status paused started
    IFS=$'\t' read -r status paused started <<<"$1"
    printf 'status %s, paused %s, started %s' "${status:--}" "${paused:--}" "${started:--}"
}

# record_loadgen_cid_at_start CHECK: records in LOADGEN_CID_AT_START the full ID of the loadgen
# container the at-start drain acts on, so that cleanup inspects that container and no other,
# once loadgen_run_state shows it as setup found it: running, not paused, last started at
# LOADGEN_STARTED_AT. Otherwise the run ends, as the check CHECK, with nothing changed. Each
# Docker call has ended within DOCKER_CALL_TIMEOUT_SECONDS (hard_timeout).
record_loadgen_cid_at_start() {
    local cid state expected="running"$'\t'"false"$'\t'"$LOADGEN_STARTED_AT" rc=0
    cid="$(compose_within "$DOCKER_CALL_TIMEOUT_SECONDS" ps -a -q loadgen 2>>"$RUN_DIR/compose.log" |
        tr -d '\r' | sed -n '1p')" || rc=$?
    if [[ $rc -ne 0 ]]; then
        abort "$1" "$(docker_problem "reading loadgen's container ID" "$rc" "$DOCKER_CALL_TIMEOUT_SECONDS"); nothing was changed"
    fi
    if [[ ! "$cid" =~ ^[0-9a-f]{64}$ ]]; then
        abort "$1" "loadgen's container ID is [${cid:+$(printf '%q' "$cid")}], not a full container ID cleanup could inspect again; nothing was changed"
    fi
    state="$(loadgen_run_state "$cid")" || rc=$?
    if [[ $rc -ne 0 ]]; then
        abort "$1" "$(docker_problem "reading the state of loadgen's container ${cid:0:12}" "$rc" "$DOCKER_CALL_TIMEOUT_SECONDS"); nothing was changed"
    fi
    if [[ "$state" != "$expected" ]]; then
        abort "$1" "loadgen's container ${cid:0:12} is [$(run_state_text "$state")] instead of [$(run_state_text "$expected")] as setup found it; nothing was changed"
    fi
    LOADGEN_CID_AT_START="$cid"
}

# secure_loadgen_at_start: the check "loadgen at start", which main runs after setup and before
# anything switches the flag or recreates loadgen. A recreate discards a container's output, the
# only receipt of the alerts its visits created, so the output of the loadgen container found at
# start, since it last started (LOADGEN_STARTED_AT), is first kept in $RUN_DIR/at-start.log. A
# loadgen running with the flag on can have a portfolio_insights_alert visit between opening the
# page or creating an alert and its outcome, whose create or delete the flag switched off for run
# A would refuse. So that loadgen is drained while the flag is still on: drain_loadgen with the
# per-visit test at_start_settled ends it at an instant Q at which no such visit is in flight, by
# killing it while paused, and its frozen output at Q replaces the kept one. Only a visit in
# flight holds Q off, never an id an earlier visit left unresolved. The reads go through
# read_window with the window set to that output, labelled at-start; WINDOW_OPEN stays 0, so
# cleanup never closes that window or owns its alerts. Before the drain,
# record_loadgen_cid_at_start records the container's ID, and AT_START_DRAINING is 1 from then
# until Q: a run that ends or is interrupted short of Q has that container, which a visit of its
# workload may still be using, put back in place by cleanup (recover_loadgen_in_place), never
# recreated. Without Q the run ends: with loadgen's container shown running on as at start,
# LOADGEN_TOUCHED, which a pause sets, goes back to 0, since the flag and loadgen are as at start;
# with it left paused, cleanup unpauses it in place, and with it killed too late for Q, cleanup
# recreates it, as no visit of it can still be in flight. A loadgen running with the flag off, or
# stopped, has no alert work in flight, so its output is only kept. The created ids the kept
# output never resolves and its left-in-place and unknown outcomes are reported, as INFO lines of
# parsed fields only, as that workload's and not deleted.
secure_loadgen_at_start() {
    local check="loadgen at start" detail id
    if [[ "$LOADGEN_AT_START" == "no container" ]]; then
        pass "$check: no container, so no visit of an earlier workload can be in flight"
        return 0
    fi
    if [[ ! "$LOADGEN_STARTED_AT" =~ $STARTED_AT_RE ]]; then
        abort "$check" "loadgen's start time $(printf '%q' "$LOADGEN_STARTED_AT") is not an RFC 3339 time, so its output cannot be read; nothing was changed"
    fi
    WINDOW_LABEL="at-start"
    WINDOW_SINCE="$LOADGEN_STARTED_AT"
    if ! read_window "$RUN_DIR/at-start.log"; then
        abort "$check" "reading loadgen's output since it started at $LOADGEN_STARTED_AT: $LOG_PROBE_DETAIL; nothing was changed"
    fi
    if [[ $LOADGEN_WAS_RUNNING -eq 1 && "$FLAG_INITIAL" == "true" ]]; then
        record_loadgen_cid_at_start "$check"
        AT_START_DRAINING=1
        if ! drain_loadgen at_start_settled at_start_summary; then
            if [[ $LOADGEN_PAUSED -eq 1 ]]; then
                abort "$check" "$DRAIN_DETAIL; loadgen may be left paused, and cleanup unpauses it in place rather than recreating it"
            fi
            # Unpaused, nothing was changed only when the container's own state shows it running
            # on as at start: a kill that ended too late for Q leaves it ended, and cleanup then
            # recreates it (recover_loadgen_in_place), as no visit of it can still be in flight.
            if [[ "$(loadgen_run_state "$LOADGEN_CID_AT_START")" == "running"$'\t'"false"$'\t'"$LOADGEN_STARTED_AT" ]]; then
                # LOADGEN_TOUCHED first: an interrupt in between leaves cleanup nothing to put back.
                LOADGEN_TOUCHED=0
                AT_START_DRAINING=0
                abort "$check" "$DRAIN_DETAIL; nothing was changed: loadgen runs on as at start and the flag is untouched"
            fi
            abort "$check" "$DRAIN_DETAIL; loadgen is not shown running as at start, so cleanup puts it back: in place while it runs, recreated once it has ended"
        fi
        # Q: the container was killed while paused, so a recreate cuts off no visit of it.
        AT_START_DRAINING=0
        cp "$RUN_DIR/frozen.log" "$RUN_DIR/at-start.log"
        detail="$DRAIN_DETAIL"
    elif [[ $LOADGEN_WAS_RUNNING -eq 1 ]]; then
        detail="running with the flag off, so no visit creates or deletes an alert; not drained"
    else
        detail="stopped, so no visit can be in flight"
    fi
    unresolved_ids "$RUN_DIR/at-start.log" >"$RUN_DIR/at-start.unresolved"
    while IFS= read -r id; do
        info "$AT_START_PREFIX: alert [$id] was logged as created and never resolved"
    done <"$RUN_DIR/at-start.unresolved"
    { grep -F -e "$LEFT_MARKER" -e "$UNKNOWN_MARKER" "$RUN_DIR/at-start.log" || true; } \
        >"$RUN_DIR/at-start.outcomes"
    report_outcomes "$RUN_DIR/at-start.outcomes" "$AT_START_PREFIX"
    pass "$check: $detail; its output since $LOADGEN_STARTED_AT is kept in $RUN_DIR/at-start.log"
}

# recover_loadgen_in_place: cleanup's step for the loadgen container found at start while the
# at-start drain holds it short of Q (AT_START_DRAINING): paused, or running again between the
# drain's polls, when the drain failed or the run was interrupted. A visit of that workload may
# then be between creating an alert and deleting it, and a recreate would cut it off and discard
# its receipt, so the container LOADGEN_CID_AT_START names is put back in place, as its own state
# shows it rather than LOADGEN_PAUSED: unpaused when paused, left alone when running, and then
# verified running as at start. Returns 0 when it is, and 0 with RECOVER_ERROR set when it cannot
# be unpaused, its state cannot be read, or it is otherwise not as at start: it is then left as
# it is, never recreated. Returns 1 when it has ended, as after the kill at Q, so no visit of it
# can be in flight and restore_loadgen recreates it; its output since LOADGEN_STARTED_AT, which
# that recreate discards, is first kept in $RUN_DIR/at-start.log. Each Docker call has ended
# within DOCKER_CALL_TIMEOUT_SECONDS (hard_timeout), and the log read within its probe_limit.
recover_loadgen_in_place() {
    local cid="$LOADGEN_CID_AT_START" state status paused rc=0
    local expected="running"$'\t'"false"$'\t'"$LOADGEN_STARTED_AT"
    local what="loadgen at start (container ${LOADGEN_CID_AT_START:0:12})"
    local why="not recreated, since a visit of its workload may be in flight"
    RECOVER_ERROR=""
    state="$(loadgen_run_state "$cid")" || rc=$?
    IFS=$'\t' read -r status paused _ <<<"$state"
    if [[ $rc -eq 0 && "$paused" == "true" ]]; then
        unpause_loadgen || rc=$?
        if [[ $rc -ne 0 ]]; then
            RECOVER_ERROR="$what left paused, $why: $(docker_problem "unpausing loadgen" "$rc" "$DOCKER_CALL_TIMEOUT_SECONDS")"
            return 0
        fi
        state="$(loadgen_run_state "$cid")" || rc=$?
        IFS=$'\t' read -r status paused _ <<<"$state"
    fi
    if [[ $rc -ne 0 ]]; then
        RECOVER_ERROR="$what unverified, $why: $(docker_problem "reading its state" "$rc" "$DOCKER_CALL_TIMEOUT_SECONDS")"
        return 0
    fi
    if [[ "$status" == "exited" || "$status" == "dead" ]]; then
        if loadgen_logs "$LOADGEN_STARTED_AT" >"$RUN_DIR/at-start.final"; then
            mv -f "$RUN_DIR/at-start.final" "$RUN_DIR/at-start.log"
            info "cleanup: $what has ended (status $status), so no visit of its workload is in flight; its output since $LOADGEN_STARTED_AT is kept in $RUN_DIR/at-start.log before it is recreated"
        else
            info "cleanup: $what has ended (status $status), so no visit of its workload is in flight; its output since $LOADGEN_STARTED_AT could not be kept before it is recreated: $LOG_PROBE_DETAIL"
        fi
        return 1
    fi
    if [[ "$state" != "$expected" ]]; then
        RECOVER_ERROR="$what is [$(run_state_text "$state")] instead of [$(run_state_text "$expected")] as at start, $why"
    fi
    return 0
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

# quiescent_summary FILE: what run B's Q holds, for its DRAIN_DETAIL: the number of alerts FILE,
# the frozen output, logged as created, all resolved, and no create in flight.
quiescent_summary() {
    echo "$(($(created_ids "$1" | wc -l))) created alerts, all resolved, and no create in flight"
}

# alert_visits_in_flight FILE: how many portfolio_insights_alert visits in FILE, told apart by
# their [id:..] tag, are between opening the page or logging a create and their alert's outcome:
# an alert deleted via ui or api, already absent or left in place, an unconfirmed create, a
# no-create outcome (no instrument options, page unavailable, feature lost before submit) or a
# visit error. A visit in that stretch may still send a create or a delete, which the flag
# switched off would refuse. A visit that reached its outcome counts no more, whatever that was,
# so an id an earlier visit left unresolved never holds the count up.
alert_visits_in_flight() {
    LC_ALL=C awk -v tag="[visit:$VISIT][id:" -v opening="$OPENING_LINE" -v created="$CREATED_MARKER" \
        -v deleted="$DELETED_MARKER" -v absent="$ABSENT_TAIL" -v left="$LEFT_MARKER" \
        -v unconfirmed="$UNCONFIRMED_MARKER" -v no_options="$NO_OPTIONS_LINE" \
        -v page_unavailable="$PAGE_UNAVAILABLE_LINE" -v feature_lost="$FEATURE_LOST_LINE" \
        -v visit_error="$ERROR_MARKER" '
        index($0, tag) && match($0, /\[id:[^]]*\]/) {
            id = substr($0, RSTART, RLENGTH)
            if (index($0, opening) || index($0, created)) {
                open[id] = 1
            } else if (index($0, deleted) || index($0, absent) || index($0, left) ||
                index($0, unconfirmed) || index($0, no_options) || index($0, page_unavailable) ||
                index($0, feature_lost) || index($0, visit_error)) {
                open[id] = 0
            }
        }
        END { n = 0; for (id in open) if (open[id]) n++; print n }
    ' "$1"
}

# at_start_settled FILE: whether no portfolio_insights_alert visit in FILE is in flight
# (alert_visits_in_flight). Sets POLL_DETAIL when one is.
at_start_settled() {
    local in_flight
    in_flight="$(alert_visits_in_flight "$1")"
    if [[ "$in_flight" != "0" ]]; then
        POLL_DETAIL="$in_flight $VISIT visits between opening the page or creating an alert and its outcome"
        return 1
    fi
}

# at_start_summary FILE: what the at-start drain's Q holds, for its DRAIN_DETAIL.
# shellcheck disable=SC2329 # Invoked by drain_loadgen as secure_loadgen_at_start names it.
at_start_summary() {
    echo "no $VISIT visit in flight"
}

# drain_call_limit DEADLINE: sets DRAIN_CALL_LIMIT to the seconds a Docker call of a drain may
# take now, the smaller of DOCKER_CALL_TIMEOUT_SECONDS and the time left before DEADLINE (epoch
# seconds). Fails when no time is left. It sets a variable rather than print, so the drain starts
# no subshell for it.
drain_call_limit() {
    local left
    left=$(($1 - $(date -u +%s)))
    if [[ $left -le 0 ]]; then
        return 1
    fi
    DRAIN_CALL_LIMIT=$((left < DOCKER_CALL_TIMEOUT_SECONDS ? left : DOCKER_CALL_TIMEOUT_SECONDS))
}

# drain_loadgen [SETTLED [SUMMARY]]: ends loadgen's output at an instant Q after which loadgen
# neither logs nor acts, by default for run B. SETTLED FILE (default quiescent) tells whether
# loadgen's output FILE is settled, setting POLL_DETAIL when not, and SUMMARY FILE (default
# quiescent_summary) prints what the frozen output FILE holds at Q. Every QUIESCE_STEP_SECONDS
# until the QUIESCE_TIMEOUT_SECONDS deadline, it checks loadgen's running output with SETTLED.
# Once that holds, it pauses loadgen and checks the settled frozen output again, since a visit
# may have opened the page or created an alert after the running read. When that holds too, it
# kills the paused loadgen, and that is Q; otherwise it unpauses loadgen and polls on. Returns 0
# at Q and 1 when the deadline passes or Compose fails, with DRAIN_DETAIL describing the outcome;
# loadgen may then still run, be paused, or have been killed past the deadline, for its caller to
# handle under its own bound. The deadline holds for every step: the log reads take at most the
# time left, each pause, unpause and kill the smaller of that and DOCKER_CALL_TIMEOUT_SECONDS
# (drain_call_limit), a step due with no time left is not started, and a kill seen to end in the
# deadline's second or later is no Q: on the whole-second clock only a kill seen before that
# second ended within QUIESCE_TIMEOUT_SECONDS of the drain's start. DRAIN_DETAIL tells a call
# Docker did not answer within its limit from one that failed.
drain_loadgen() {
    local settled="${1:-quiescent}" summary="${2:-quiescent_summary}" deadline rc now late
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
        elif ! "$settled" "$RUN_DIR/quiesce.log"; then
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
            if frozen_log && "$settled" "$RUN_DIR/frozen.log"; then
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
                DRAIN_DETAIL="Q at $(now_rfc3339) with $("$summary" "$RUN_DIR/frozen.log"); loadgen killed while paused"
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
    # An exit or a signal inside a call with its output redirected, as read_window's log read into
    # a file, runs this trap with that redirection still in force. The run's own stdout and
    # stderr, which install_cleanup kept, are put back first, so every line below reaches them.
    # Without those copies, as when a suite calls cleanup directly, it writes to the stdout and
    # stderr it has.
    if [[ -n "${RUN_STDOUT_FD:-}" && -n "${RUN_STDERR_FD:-}" ]]; then
        exec 1>&"$RUN_STDOUT_FD" 2>&"$RUN_STDERR_FD"
    fi
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
        # DELETE answers 403 while the flag is off, so the flag is switched on to delete. Only a
        # reply that is the flag (flag_reply) shows it off; after any other reply, or a switch the
        # PUT and its read-back do not confirm, the deletes still run and report their statuses.
        http GET "$FLAG_URL"
        if ! flag_answered "GET $FLAG_ID"; then
            info "cleanup: flag $FLAG_ID not read before deleting $remaining owned alerts: $FLAG_REASON"
        elif [[ "$FLAG_ENABLED" == "false" ]]; then
            FLAG_TOUCHED=1
            if put_flag true; then
                info "cleanup: flag $FLAG_ID switched on to delete $remaining owned alerts (status 200)"
            else
                info "cleanup: flag $FLAG_ID not confirmed switched on to delete $remaining owned alerts: $FLAG_REASON"
            fi
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
        # Restored only when the PUT and the read-back both give the flag at its value at start.
        if put_flag "$FLAG_INITIAL"; then
            info "cleanup: flag $FLAG_ID restored to enabled=$FLAG_INITIAL"
        else
            problems="${problems:+$problems; }flag $FLAG_ID not restored to enabled=$FLAG_INITIAL: $FLAG_REASON"
        fi
    fi
    if [[ $LOADGEN_TOUCHED -eq 1 ]]; then
        # Short of the at-start drain's Q, the container found at start is put back in place and
        # never recreated; recover_loadgen_in_place hands it to the restore once it has ended.
        if [[ $AT_START_DRAINING -eq 1 ]] && recover_loadgen_in_place; then
            if [[ -n "$RECOVER_ERROR" ]]; then
                problems="${problems:+$problems; }$RECOVER_ERROR"
            else
                info "cleanup: loadgen at start recovered in place: running as at start (container ${LOADGEN_CID_AT_START:0:12}), not recreated"
            fi
        elif restore_loadgen; then
            info "cleanup: loadgen restored as at start: $(loadgen_start_text)"
        else
            problems="${problems:+$problems; }loadgen not restored: $RESTORE_ERROR"
        fi
    fi
    # A twin loadgen container the restorability check made and did not see removed, as when an
    # exit cut its create short: removed before the lock goes, since every later read of loadgen
    # takes the project's first loadgen container.
    if [[ -n "$LOADGEN_TWIN" ]]; then
        if remove_loadgen_twin; then
            info "cleanup: ${TWIN_REMOVED:+twin loadgen container $TWIN_REMOVED removed; }no twin loadgen container is left"
        else
            problems="${problems:+$problems; }twin loadgen container not removed: $TWIN_ERROR"
        fi
    fi
    # Last, with the flag and loadgen put back: the lock this run took. A run refused at the lock
    # holds none, so it never removes the lock of the run it found.
    if [[ $LOCK_HELD -eq 1 ]]; then
        if release_run_lock; then
            info "cleanup: run lock $LOCK_DIR released"
        else
            problems="${problems:+$problems; }run lock not released: $LOCK_ERROR"
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

# install_cleanup: keeps copies of the run's stdout and stderr in RUN_STDOUT_FD and RUN_STDERR_FD
# for cleanup to put back, then runs cleanup on EXIT and turns INT and TERM into exit 130, which
# runs it too. Child processes inherit the copies as they inherit stdout and stderr, and the run
# starts none in the background, so no copy holds the run's output open once it has exited. When
# the copies cannot be made, as with stdout closed, the run ends with exit 2 before any change.
install_cleanup() {
    if ! exec {RUN_STDOUT_FD}>&1 {RUN_STDERR_FD}>&2; then
        echo "Could not keep copies of stdout and stderr for the cleanup report." >&2
        exit 2
    fi
    trap cleanup EXIT
    trap 'exit 130' INT TERM
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

# resume_exit: the EXIT trap of a --resume-cleanup run from its run lock until cleanup takes
# over, which runs when the lock is refused, the flag read fails or an interrupt lands. Nothing
# has been deleted and the flag not switched by then, so it only releases the lock when this run
# holds it, failing the cleanup check when that fails, and prints the SUMMARY line.
# shellcheck disable=SC2329 # Invoked by the EXIT trap resume_cleanup sets.
resume_exit() {
    local rc=$?
    trap - EXIT
    set +e
    if [[ $LOCK_HELD -eq 1 ]]; then
        if release_run_lock; then
            info "cleanup: run lock $LOCK_DIR released"
        else
            fail "cleanup" "run lock not released: $LOCK_ERROR"
        fi
    fi
    echo "SUMMARY $passed passed, $failed failed"
    if [[ $rc -eq 0 && $failed -gt 0 ]]; then
        rc=1
    fi
    exit "$rc"
}

# resume_cleanup: the --resume-cleanup run. It checks that --base-url is the origin of --project
# (resume_origin_bound), takes the project's run lock (acquire_run_lock), since a resume
# alongside a run or another resume on the project would toggle the same flag and could take the
# other's test value for the one to restore, and reads the flag, then ends through cleanup, which
# DELETEs by id the owned ids of the run directory no earlier cleanup deleted, switching the flag
# on to delete while it is off and restoring it after, appends each id deleted or found absent to
# the deleted list, so a later resume goes on from there, and releases the lock. Until cleanup
# takes over, resume_exit releases it. It sends no POST, deletes nothing by account, touches no
# loadgen, opens no window and writes no table.
resume_cleanup() {
    local remaining
    trap 'exit 130' INT TERM
    info "run dir $RUN_DIR"
    info "resuming the owned-alert cleanup of project [$PROJECT], base url $BASE_URL"
    resume_origin_bound
    trap resume_exit EXIT
    acquire_run_lock
    http GET "$FLAG_URL"
    # Only a reply that is the flag (flag_reply) gives the value cleanup restores, so without one
    # nothing is deleted; the failure names the broken rule, never the reply's content.
    if ! flag_answered "GET $FLAG_ID"; then
        abort "resume flag" "$FLAG_REASON; nothing was deleted"
    fi
    FLAG_INITIAL="$FLAG_ENABLED"
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
    # The image ID, config hash and effective configuration file restore_loadgen verifies, and
    # the time loadgen's container at start last started, all set by check_loadgen_restorable.
    LOADGEN_IMAGE_AT_START=""
    LOADGEN_HASH_AT_START=""
    LOADGEN_CONFIG_AT_START=""
    LOADGEN_STARTED_AT=""
    RESTORE_ERROR=""
    # The container ID check_loadgen_restorable read for loadgen at start, the twin it compares
    # with while one may exist (its ID, or unknown before it is read), and remove_loadgen_twin's
    # and loadgen_twin_check's outcomes.
    LOADGEN_ID_AT_START=""
    LOADGEN_TWIN=""
    TWIN_ERROR=""
    TWIN_REMOVED=""
    TWIN_DETAIL=""
    # The ID of loadgen's container at start, 1 while the at-start drain holds it short of Q, and
    # why cleanup could not recover it in place (record_loadgen_cid_at_start,
    # recover_loadgen_in_place).
    LOADGEN_CID_AT_START=""
    AT_START_DRAINING=0
    RECOVER_ERROR=""
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
    # The per-project run lock under LOCK_ROOT (acquire_run_lock).
    LOCK_DIR=""
    LOCK_HELD=0
    LOCK_ERROR=""

    # A resume ends inside resume_cleanup, through its own exit steps or cleanup.
    if [[ -n "$RESUME_RUN_DIR" ]]; then
        resume_cleanup
    fi
    install_cleanup
    info "run dir $RUN_DIR"
    info "started $STARTED_AT: project [$PROJECT], base url $BASE_URL, compose files [${COMPOSE_FILES[*]}], weight $WEIGHT, runs of $MINUTES minutes, table $OUT_FILE"
    setup
    secure_loadgen_at_start
    run_a
    run_b
    flag_off_window
    finish_run
}

# Sourcing the file defines its functions without running it.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
