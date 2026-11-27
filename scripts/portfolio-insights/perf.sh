#!/usr/bin/env bash
# Measures the two Portfolio Insights limits against one running Compose dev project:
#   - insights p95 below 500 ms for an account that holds 15 instruments;
#   - one alert evaluation cycle below 10 s for 1,000 armed alerts.
# Run it from the repository root, once per dialect, against a project whose stack is up.
# The script enables the portfolio-insights-enabled flag itself and restores it on exit.
#
# Usage: scripts/portfolio-insights/perf.sh --project NAME [--base-url URL] [--compose-file FILE]
#   --project NAME       Compose project of the running stack (required): lowercase letters,
#                        digits, dashes and underscores, starting with a letter or digit
#   --base-url URL       Reverse-proxy origin of that stack (default: http://localhost)
#   --compose-file FILE  Compose file of that project, relative to the current directory
#                        (default: compose.dev.yaml)
#   -h, --help           Show this help and exit
#
# One project per invocation, and one invocation per project at a time: before it reads or
# changes the stack, a run takes the project's run lock, bound to the project on its Docker
# engine as a stopped container named pi-perf-lock.<project>, and a second run is refused while
# a live run holds it. A run removes its lock container on exit; the lock container of a run
# that was killed is reclaimed by the next run on the same host. Never run it alongside e2e.sh
# or loadgen-check.sh: all three toggle the same flag and work on the same preset accounts.
#
# What it touches: it reads the 25 PRESET accounts without trading on them, creates 1,000
# alerts of its own on them, stops loadgen while it measures, and runs read-only SELECTs
# through the db container's own client. On exit, normal or not, it deletes every alert it
# created by id, restores the flag to the value it read at start, and starts loadgen again
# only if loadgen was running at start. A DELETE that ends in a transport error or a 5xx is
# tried twice more. After a 403 it reads the flag: a flag at enabled=false is switched on and the
# DELETE tried once more, one at enabled=true gets that try without a PUT, and one it cannot read
# changes nothing. A create whose outcome is unknown, such as a POST cut off by an interrupt, is
# looked for among its account's alerts and deleted by id when its alert can be told from all
# others: by the fields it was created with, armingRevision 1, and a createdAt at or after the
# run's cycle precondition. Otherwise nothing is deleted for it and the cleanup check fails,
# naming the account, type, instrument, direction and threshold.
# It keeps state under ${TMPDIR:-/tmp}/pi-perf-state.<project>: a record of every run
# directory whose owned alerts are not all deleted or whose unknown creates are not all
# reconciled. Each create is written to the run directory before its POST is sent, so the one in
# flight when a run is killed outright, which runs no cleanup, is among its unknown creates. The
# next run on the project with the same base url and compose file deletes those alerts by id and
# looks for those creates' alerts first, as its "recovery" check, before it measures; a record
# made with another base url or compose file stops it before it changes anything.
#
# Prints one PASS or FAIL line per check, a REPORT block and a final SUMMARY line, on the run's
# own stdout even when an interrupt or an error ends the run while a step writes to a file.
# Exits 0 when every check passes, 1 when any check fails, 2 on a usage error, a missing tool, a
# run directory it cannot make or a closed stdout, and 130 on an interrupt. Working files stay
# in the run directory printed at start and end.

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
# The insights log window, read for the server-side share, starts this far before the host's
# clock at the first request, so a host clock ahead of the Docker engine's loses no insights
# line; the earlier lines it also reads carry other trace ids and are left out.
LOG_SKEW_MARGIN_SECONDS=30
# Every broker-service log read runs under timeout(1), so a Docker call that never answers
# cannot hold the run. Inside a cycle wait (wait_cycle_line, or the first read of
# open_verified_window) it may take the time left to that wait's deadline; a read outside one
# may take this fixed bound. Either is a hard limit on the Docker call, its termination
# included: TERM comes LOG_PROBE_KILL_SECONDS before the limit and KILL at it. A cycle-wait read
# that still ends at or after its deadline, output filters included, is discarded (read_window).
LOG_PROBE_TIMEOUT_SECONDS=60
LOG_PROBE_KILL_SECONDS=5
# The hard limit of cleanup's compose start of loadgen, termination included as for log reads,
# so a Docker engine that never answers cannot hold the exit. A start takes seconds on a healthy
# engine; one cut off is reported as a cleanup problem.
DOCKER_CALL_TIMEOUT_SECONDS=60
PRESET_COUNT=25
HOLDINGS_EXPECTED=15
ALERTS_PER_ACCOUNT=40
TARGET_PRICE_PER_ACCOUNT=20
ALERTS_EXPECTED=$((PRESET_COUNT * ALERTS_PER_ACCOUNT))
# The threshold domain maximum (10 integer and 8 fractional digits), sent as the exact token.
MAX_THRESHOLD="9999999999.99999999"
WARMUP_REQUESTS=10
TIMED_REQUESTS=200
# The insights p95 is the nearest-rank 95th percentile of exactly TIMED_REQUESTS valid timings:
# the 190th sorted value of 200.
INSIGHTS_P95_RANK=$(((95 * TIMED_REQUESTS + 99) / 100))
# A readable curl time_total, in seconds.
TIME_TOTAL_RE='^[0-9]+(\.[0-9]+)?$'
# The run nonce: the first 16 hex digits of every insights trace id this run sends.
TRACE_NONCE_RE='^[0-9a-f]{16}$'
# Failed insights requests named in the FAIL reason; every failure is counted.
INSIGHTS_REASONS_SHOWN=5
INSIGHTS_LIMIT_SECONDS="0.5"
CYCLE_LIMIT_MS="10000"
MAX_REJECTED_SAMPLES=3
FOLLOW_UP_CYCLES=2
# Cycle-line deadlines are whole evaluation intervals plus this margin: two intervals for the
# first line after T, one for a follow-up read straight after the previous line.
CYCLE_WAIT_MARGIN_SECONDS=30
# The broker's interval rule: a whole number from 1 to 4294967 seconds, otherwise 60.
DEFAULT_INTERVAL_SECONDS=60
MAX_INTERVAL_SECONDS=4294967
# Cleanup stops sending DELETEs after this many alerts in a row whose every attempt ended in a
# transport error.
MAX_CONSECUTIVE_TRANSPORT_ERRORS=5
# Each DELETE that ends in a transport error or a 5xx is tried up to DELETE_ATTEMPTS times, the
# retry after attempt n waiting n * DELETE_RETRY_STEP_SECONDS (1 s, then 2 s).
DELETE_ATTEMPTS=3
DELETE_RETRY_STEP_SECONDS=1
# A DELETE answers 403 when someone switched the flag off, or while the broker cannot read it;
# one cleanup reads the flag after a 403, and switches it on again or tries the id once more, at
# most this many times, so a flag toggled off over and over cannot hold the exit.
MAX_FLAG_REENABLES=3
# A create whose outcome is unknown is looked for among its account's alerts every
# UNKNOWN_CREATE_STEP_SECONDS until UNKNOWN_CREATE_SETTLE_SECONDS after its POST ended. The
# broker may still be writing the alert after the POST's curl has ended: its create call to
# db-adapter has a 10 s deadline (AlertRepository.CallTimeout), and the flag read and account
# reads before that call take their own time; 30 s covers them with a margin. A create carried
# from an earlier run is looked for until HTTP_TIMEOUT_SECONDS + UNKNOWN_CREATE_SETTLE_SECONDS
# after this run adopted it: that run had ended by then, and the curl of a POST that its kill
# left running ends within HTTP_TIMEOUT_SECONDS.
UNKNOWN_CREATE_SETTLE_SECONDS=30
UNKNOWN_CREATE_STEP_SECONDS=5
UNKNOWN_CREATE_NOTE="the alert may exist without an id this run knows; cleanup looks for it among the account's alerts"

CYCLE_MARKER="Alert evaluation cycle finished"
CYCLE_RE='alerts \[([0-9]+)\] triggered \[([0-9]+)\] failed \[([0-9]+)\] skipped \[([0-9]+)\] outcome \[([A-Za-z_]+)\] duration \[([0-9]+(\.[0-9]+)?)\] ms'
INSIGHTS_TRACE_RE='duration \[([0-9]+(\.[0-9]+)?)\] ms trace \[([0-9a-f]{32})\]'
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
# The armed-set query's time row as db_query prints it, lower-cased: date, time, fraction.
ARMED_TIME_RE='^at,([0-9]{4}-[0-9]{2}-[0-9]{2})t([0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]{1,9})?z?$'

usage() {
    cat <<'EOF'
Usage: scripts/portfolio-insights/perf.sh --project NAME [--base-url URL] [--compose-file FILE]
  --project NAME       Compose project of the running stack (required): lowercase letters,
                       digits, dashes and underscores, starting with a letter or digit
  --base-url URL       Reverse-proxy origin of that stack (default: http://localhost)
  --compose-file FILE  Compose file of that project, relative to the current directory
                       (default: compose.dev.yaml)
  -h, --help           Show this help and exit
Run one project at a time, never alongside e2e.sh or loadgen-check.sh; a second run on the
same project is refused while the first holds its run lock, a stopped container named
pi-perf-lock.NAME on the project's Docker engine. The next run on the same host reclaims the
lock container of a run that was killed. Owned alerts a run could not
delete are recorded under ${TMPDIR:-/tmp}/pi-perf-state.NAME, and the next run on NAME with
the same --base-url and --compose-file deletes them by id before it measures.

Examples:
  scripts/portfolio-insights/perf.sh --project pi-dev-postgres
  scripts/portfolio-insights/perf.sh --project pi-dev-mssql --base-url http://localhost \
      --compose-file compose.dev.yaml

Exit: 0 all passed, 1 a check failed, 2 bad usage, missing tool, no run dir or closed stdout,
130 interrupted.
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

# parse_options ARGS...: sets BASE_URL, COMPOSE_FILE and PROJECT from the command line, and
# COMPOSE_PATH to the compose file's absolute path. A usage error prints its reason and the usage
# on stderr and exits 2; -h or --help prints the usage on stdout and exits 0.
parse_options() {
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
    # Compose's own rule for a project name; the name also keys this script's state directory.
    if [[ ! "$PROJECT" =~ ^[abcdefghijklmnopqrstuvwxyz0123456789][abcdefghijklmnopqrstuvwxyz0123456789_-]*$ ]]; then
        usage_error "Option --project needs a Compose project name: lowercase letters, digits, dashes and underscores, starting with a letter or digit."
    fi
    # The refused value is never echoed, since it can hold credentials.
    if ! is_base_origin "$BASE_URL"; then
        usage_error "Option --base-url needs an http:// or https:// origin: a host and optional port, without credentials, path, query or fragment."
    fi
    BASE_URL="${BASE_URL%/}"
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        usage_error "Compose file not found: $COMPOSE_FILE (resolved from $(pwd); the repository root is $REPO_ROOT)"
    fi
    # The compose file's absolute path, which the run record keeps (record_run).
    COMPOSE_PATH="$(cd "$(dirname "$COMPOSE_FILE")" && pwd)/$(basename "$COMPOSE_FILE")"
}

# check_tools: exits 2 with the reason on stderr unless every program the run calls is on PATH
# and docker has its compose plugin.
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

# The run lock's owner labels (acquire_run_lock, read_lock_owner) are this prefix followed by
# pid, host, started and run-dir.
LOCK_LABEL_PREFIX="pi-perf.lock."
# A container id as docker create prints it and docker inspect reads it: 64 lower-case hex
# digits, of which Docker also accepts a 12-digit short form.
CONTAINER_ID_RE='^[0-9a-f]{12}([0-9a-f]{52})?$'

# prepare_run: makes the run directory under TMPDIR, with empty owned, expected and deleted
# files, sets the request URLs from BASE_URL, and sets STATE_DIR and LOCK_NAME from PROJECT.
# It writes nothing under STATE_DIR and takes no lock. Exits 2 when the directory cannot be made.
prepare_run() {
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
    # State kept between runs on one project, written only once main runs: runs/, one record
    # per run directory that may still hold owned alerts not yet deleted.
    STATE_DIR="${TMPDIR:-/tmp}/pi-perf-state.$PROJECT"
    # The run lock: a container of this name on the project's Docker engine, which exists while a
    # run holds the lock and carries that run's owner labels. Being a Docker name, it is the same
    # for every run that reaches that engine, whatever its TMPDIR.
    LOCK_NAME="pi-perf-lock.$PROJECT"
}

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
RUNNING_SERVICES=""
LOCK_HELD=0
# The id of the lock container this run created, the only one it ever releases.
LOCK_ID=""
RUN_RECORD=""
REPORT_PRINTED=0
# The descriptors, 8 and 9, that hold the copies of the run's own stdout and stderr install_traps
# keeps for restore_run_output, empty until it has kept them.
RUN_STDOUT_FD=""
RUN_STDERR_FD=""
DIALECT=""
EVAL_INTERVAL=""
STARTED_AT=""
# The database's UTC time of the passed cycle precondition, empty until it passes; it is also
# kept in $RUN_DIR/precondition-at for the next run (measure_cycle).
PRECONDITION_AT=""
# The settle deadline (on the $SECONDS clock) of the creates carried from earlier runs, set when
# adopt_earlier_runs carries any; 0 until then.
CARRIED_SETTLE_UNTIL=0
# The number of lines of an unknown-creates file, as count_unknown_creates last counted them.
UNKNOWN_COUNT=0
# The deadline (on the $SECONDS clock) of the cycle wait running now (wait_cycle_line, or the
# first read of open_verified_window), empty outside one, and why the last log read failed.
PROBE_DEADLINE=""
LOG_PROBE_DETAIL=""
# 1 while $RUN_DIR/broker.log holds the read open_verified_window made of the window it opened,
# which ended before that window's deadline; the next wait_cycle_line parses it first and sets 0.
WINDOW_READ_HELD=0

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

# restore_run_output: points stdout and stderr back at the run's own, which install_traps kept.
# bash runs a trap inside the function it interrupts, under that function's redirections, and an
# exit or abort inside a call whose output goes to a file, as read_window's log read into
# broker.log or a compose call into compose.log, ends the run with that file as its output. So
# on_exit and abort call this before they print, and the FAIL line, the REPORT, the cleanup check
# and the SUMMARY reach the run's own output. Without the copies, as when a suite calls on_exit
# or abort directly, stdout and stderr stay as they are.
restore_run_output() {
    if [[ -n "$RUN_STDOUT_FD" && -n "$RUN_STDERR_FD" ]]; then
        exec 1>&"$RUN_STDOUT_FD" 2>&"$RUN_STDERR_FD"
    fi
}

# Fails the check and ends the run through finish, so cleanup still runs, on the run's own
# stdout and stderr (restore_run_output).
abort() {
    restore_run_output
    fail "$1" "$2"
    finish
}

# ---------------------------------------------------------------------------------------------
# HTTP and JSON

# http_within MAX_TIME METHOD URL [BODY]: one request that curl ends after MAX_TIME seconds.
# Every caller passes MAX_TIME itself, so no variable of the caller's scope or environment sets
# a request's limit. A MAX_TIME that is not a whole number above 0 is refused unsent: curl takes
# 0 as no limit at all. Sets HTTP_STATUS (000 on a transport error or a refused limit),
# HTTP_CTYPE, HTTP_BODY and HTTP_ERROR (curl's message on a transport error, or why the request
# was not sent). Never trips set -e.
# curl writes the record "<http_code> <exitcode> <content_type>", content_type last because it
# can hold spaces. A complete record carries curl's own exit status and outranks the status of
# the command substitution: under Git Bash an interrupt that arrives while curl runs sets that
# status to 130 although curl finished the transfer. Without a record (a curl killed before it
# wrote one) the substitution's status stands for curl's, and so it does when the record's exit
# field is empty, as a curl older than 7.75 that knows no %{exitcode} writes it.
# A POST creates an alert and is never repeated, so its curl ignores INT and TERM: an interrupt
# cannot cut off a request the server may already have committed, and --max-time still bounds
# it. Native Windows curl under Git Bash is killed by a TERM to its process group all the same;
# post_alert records such a create for cleanup to reconcile.
http_within() {
    local max_time="$1" method="$2" url="$3" out rc=0 record_re='^([0-9]{3}) ([0-9]*) (.*)$'
    if [[ ! "$max_time" =~ ^[1-9][0-9]*$ ]]; then
        HTTP_STATUS="000"
        HTTP_CTYPE=""
        HTTP_ERROR="not sent: time limit [$max_time] is not a whole number of seconds above 0"
        HTTP_BODY=""
        return 0
    fi
    local args=(-sS --max-time "$max_time" -X "$method"
        -o "$RUN_DIR/body" -D "$RUN_DIR/headers" -w '%{http_code} %{exitcode} %{content_type}'
        -H 'Accept: application/json')
    if [[ $# -ge 4 ]]; then
        args+=(-H 'Content-Type: application/json' --data-binary "$4")
    fi
    : >"$RUN_DIR/body"
    if [[ "$method" == "POST" ]]; then
        out="$(
            trap '' INT TERM
            curl "${args[@]}" "$url" 2>"$RUN_DIR/curl-error"
        )" || rc=$?
    else
        out="$(curl "${args[@]}" "$url" 2>"$RUN_DIR/curl-error")" || rc=$?
    fi
    HTTP_STATUS="000"
    HTTP_CTYPE=""
    if [[ "$out" =~ $record_re ]]; then
        if [[ -n "${BASH_REMATCH[2]}" ]]; then
            rc="${BASH_REMATCH[2]}"
        fi
        HTTP_STATUS="${BASH_REMATCH[1]}"
        HTTP_CTYPE="${BASH_REMATCH[3]}"
    elif [[ "$rc" == "0" ]]; then
        # A curl that ends with 0 but wrote no record has not reported any answer.
        rc=1
    fi
    if [[ "$rc" != "0" ]]; then
        HTTP_STATUS="000"
        HTTP_CTYPE=""
        HTTP_ERROR="$(tr -d '\r' <"$RUN_DIR/curl-error" | head -c 300)"
    else
        HTTP_ERROR=""
    fi
    HTTP_BODY="$(cat "$RUN_DIR/body")"
}

# http METHOD URL [BODY]: http_within with the HTTP_TIMEOUT_SECONDS limit, which every request
# but readyz's takes.
http() {
    http_within "$HTTP_TIMEOUT_SECONDS" "$@"
}

# read_flag JSON: reads a flag reply as exactly one JSON object whose id is FLAG_ID and whose
# enabled and isModifiable are JSON booleans, and sets FLAG_ENABLED and FLAG_MODIFIABLE to true
# or false. Each type is tested, because raw jq output reads the string "false" as the boolean.
# Otherwise fails with FLAG_ERROR, a fixed reason that never repeats the reply.
read_flag() {
    local fields
    FLAG_ENABLED=""
    FLAG_MODIFIABLE=""
    FLAG_ERROR=""
    if ! fields="$(jq -rs --arg id "$FLAG_ID" "$JQ_ONE_VALUE"'
        one_value
        | if type != "object" then "object"
          elif .id != $id then "id"
          elif (.enabled | type) != "boolean" then "enabled"
          elif (.isModifiable | type) != "boolean" then "isModifiable"
          else "ok \(.enabled) \(.isModifiable)" end' 2>/dev/null <<<"$1" | tr -d '\r')"; then
        fields="object"
    fi
    case "$fields" in
        "ok true true" | "ok true false" | "ok false true" | "ok false false")
            fields="${fields#ok }"
            FLAG_ENABLED="${fields% *}"
            FLAG_MODIFIABLE="${fields#* }"
            return 0
            ;;
        id) FLAG_ERROR="its id is not $FLAG_ID" ;;
        enabled) FLAG_ERROR="its enabled is not a JSON boolean" ;;
        isModifiable) FLAG_ERROR="its isModifiable is not a JSON boolean" ;;
        *) FLAG_ERROR="its reply is not one JSON object" ;;
    esac
    return 1
}

# put_flag VALUE: PUTs {"enabled": VALUE} and succeeds only when the reply, read by read_flag,
# shows enabled VALUE: a 200 alone does not show that the flag holds it. Sets FLAG_PUT_ERROR to
# the status or a fixed reason on failure.
put_flag() {
    FLAG_PUT_ERROR=""
    http PUT "$FLAG_URL" "{\"enabled\": $1}"
    if [[ "$HTTP_STATUS" != "200" ]]; then
        FLAG_PUT_ERROR="$(status_text)"
        return 1
    fi
    if ! read_flag "$HTTP_BODY"; then
        FLAG_PUT_ERROR="status 200, but $FLAG_ERROR"
        return 1
    fi
    if [[ "$FLAG_ENABLED" != "$1" ]]; then
        FLAG_PUT_ERROR="status 200, but its reply shows enabled=$FLAG_ENABLED"
        return 1
    fi
}

# read_alert_reply JSON: reads the alert a create or re-arm answered with, as exactly one JSON
# object, and sets REPLY_ID to its id when that is a canonical UUID string (lower-cased),
# REPLY_ENABLED to true or false when enabled is a JSON boolean, and REPLY_REVISION to its
# armingRevision when that is a JSON integer of 1 to 10 digits (a string "1" or 1.5 is not);
# each is empty otherwise. Fails, all three empty, when the reply is not one JSON object.
read_alert_reply() {
    local fields id enabled revision
    REPLY_ID=""
    REPLY_ENABLED=""
    REPLY_REVISION=""
    if ! fields="$(jq -rs --arg re "$UUID_RE" "$JQ_CANONICAL$JQ_ONE_VALUE"'
        one_value
        | if type == "object" then . else error("not an object") end
        | "\(.id | canonical // "-") \(.enabled | if type == "boolean" then tostring else "-" end) \(.armingRevision | if type == "number" then tojson else "-" end)"' \
        2>/dev/null <<<"$1" | tr -d '\r')" || [[ ! "$fields" =~ ^([^\ ]+)\ ([^\ ]+)\ ([^\ ]+)$ ]]; then
        return 1
    fi
    id="${BASH_REMATCH[1]}"
    enabled="${BASH_REMATCH[2]}"
    revision="${BASH_REMATCH[3]}"
    if [[ "$id" =~ $UUID_RE ]]; then
        REPLY_ID="$id"
    fi
    case "$enabled" in
        true | false) REPLY_ENABLED="$enabled" ;;
    esac
    if [[ "$revision" =~ ^[1-9][0-9]{0,9}$ ]]; then
        REPLY_REVISION="$revision"
    fi
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
# recorded as owned at once, so cleanup deletes it whatever happens next, and id,1 is appended
# to the expected armed set once the receipt shows the alert enabled at revision 1. A create
# whose outcome is unknown is recorded for cleanup to reconcile (record_unknown_create). Sets
# CREATE_ERROR on failure.
# An interrupt that arrives while the POST is in flight is held until the id, or the unknown
# outcome, is recorded: exiting in between would leave an alert this run created but cannot
# delete. A kill that no trap sees is covered by post_alert's write-ahead record instead.
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
    local strings body
    if [[ ! "$5" =~ ^-?(0|[1-9][0-9]*)(\.[0-9]+)?$ ]]; then
        CREATE_ERROR="threshold [$5] is not a plain decimal token"
        return 1
    fi
    # jq encodes the four strings; the threshold token, checked above, is appended as its own
    # text, so it never passes through a number type.
    if ! strings="$(jq -cn --arg accountId "$1" --arg type "$2" --arg instrumentId "$3" \
        --arg direction "$4" '{$accountId, $type, $instrumentId, $direction}' 2>/dev/null | tr -d '\r')" ||
        [[ "$strings" != \{*\} ]]; then
        CREATE_ERROR="the request body could not be encoded"
        return 1
    fi
    body="${strings%?},\"threshold\":$5}"
    # Write-ahead: the create goes to $RUN_DIR/in-flight-create before its POST is sent, and the
    # file is emptied only once the outcome is recorded below, so a run killed in between, by a
    # SIGKILL that runs no trap for one, still leaves the create for the next run to look for
    # (earlier_open_creates). Its one line has the fields of an unknown-creates line, led by the
    # number of lines unknown-creates held before this create instead of the second its POST
    # ended: more lines than that show the create recorded there already. Nothing is sent without
    # it.
    count_unknown_creates "$RUN_DIR"
    if ! printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$UNKNOWN_COUNT" "$1" "$2" "$3" "$4" "$5" \
        >"$RUN_DIR/in-flight-create"; then
        CREATE_ERROR="the create could not be written to $RUN_DIR/in-flight-create, so its POST was not sent"
        return 1
    fi
    http POST "$ALERTS_URL" "$body"
    # A 4xx refuses the create before anything is written. After any other answer but a 201,
    # a transport error included, the alert may exist.
    case "$HTTP_STATUS" in
        201) ;;
        4??)
            : >"$RUN_DIR/in-flight-create"
            CREATE_ERROR="$(status_text)"
            return 1
            ;;
        *)
            record_unknown_create "$@"
            : >"$RUN_DIR/in-flight-create"
            CREATE_ERROR="$(status_text); $UNKNOWN_CREATE_NOTE"
            return 1
            ;;
    esac
    # The id is recorded as soon as it is known, before the rest of the receipt is checked, so
    # cleanup deletes the alert even when its receipt is refused. A create answers with the alert
    # armed: enabled the JSON boolean true and armingRevision the JSON integer 1. Any other
    # receipt fails the workload, since the measured set must be 1,000 alerts at revision 1.
    if ! read_alert_reply "$HTTP_BODY" || [[ -z "$REPLY_ID" ]]; then
        record_unknown_create "$@"
        : >"$RUN_DIR/in-flight-create"
        CREATE_ERROR="201 without a readable id; $UNKNOWN_CREATE_NOTE"
        return 1
    fi
    echo "$REPLY_ID" >>"$RUN_DIR/owned"
    : >"$RUN_DIR/in-flight-create"
    if [[ "$REPLY_ENABLED" != "true" ]]; then
        CREATE_ERROR="201 for alert [$REPLY_ID] whose enabled is not the JSON boolean true"
        return 1
    fi
    if [[ "$REPLY_REVISION" != "1" ]]; then
        CREATE_ERROR="201 for alert [$REPLY_ID] whose armingRevision is not the JSON integer 1"
        return 1
    fi
    echo "$REPLY_ID,1" >>"$RUN_DIR/expected"
}

# record_unknown_create ACCOUNT TYPE INSTRUMENT DIRECTION THRESHOLD: appends a create whose
# outcome is unknown to $RUN_DIR/unknown-creates as one tab-separated line, led by $SECONDS when
# its POST ended, for cleanup_all to reconcile (reconcile_unknown_creates).
record_unknown_create() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$SECONDS" "$1" "$2" "$3" "$4" "$5" >>"$RUN_DIR/unknown-creates"
}

# count_unknown_creates DIR: sets UNKNOWN_COUNT to the number of lines of DIR/unknown-creates, 0
# when it is missing or empty. It reads with builtins only, since post_alert counts before every
# create and every fork is slow under Git Bash.
count_unknown_creates() {
    local -a records=()
    UNKNOWN_COUNT=0
    if [[ -s "$1/unknown-creates" ]]; then
        mapfile -t records <"$1/unknown-creates"
        UNKNOWN_COUNT=${#records[@]}
    fi
}

# ---------------------------------------------------------------------------------------------
# Docker, times and logs

# Arguments such as /opt/mssql-tools/... must reach docker unchanged: Git Bash would rewrite
# them to Windows paths. Only docker gets this; curl still needs the rewrite of its file paths.
# stdin is detached so docker never consumes the input of a surrounding read loop.
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

# docker_problem WHAT STATUS LIMIT: why the Docker call WHAT, run by hard_timeout with LIMIT,
# ended with STATUS, telling a call Docker did not answer in time from one that failed.
docker_problem() {
    case "$2" in
        124 | 137) echo "$1 timed out after $3 s (Docker did not answer)" ;;
        *) echo "$1 failed, exit $2 (see $RUN_DIR/compose.log)" ;;
    esac
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
# callers match substrings only. The Docker call has ended, killed if need be, probe_limit
# seconds after it started (hard_timeout), and is never started once the wait's deadline has
# passed. The colour and carriage-return filters after it are outside that limit, so a read can
# still end after the deadline; the cycle waits read through read_window, which discards such a
# read. On failure LOG_PROBE_DETAIL tells a read Docker did not answer in time from one that
# failed.
broker_logs() {
    local limit rc=0
    if ! limit="$(probe_limit)"; then
        # Only the cycle waits set a deadline, and an attempt of wait_cycle_line can start just
        # as it passes. That attempt fails at once and leaves LOG_PROBE_DETAIL to the read
        # before it, the one that tells why the wait found no line.
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

# probe_limit: the seconds the Docker call of a log read may take now, the time left to
# PROBE_DEADLINE inside a cycle wait (wait_cycle_line, or the first read of
# open_verified_window) and LOG_PROBE_TIMEOUT_SECONDS outside it. Fails when the deadline has
# passed, so no read starts then; read_window checks the deadline again once a read has ended.
probe_limit() {
    local left
    if [[ -z "$PROBE_DEADLINE" ]]; then
        echo "$LOG_PROBE_TIMEOUT_SECONDS"
        return 0
    fi
    left=$((PROBE_DEADLINE - SECONDS))
    if [[ $left -le 0 ]]; then
        return 1
    fi
    echo "$left"
}

# read_window: one read of the cycle-log window, the broker-service output since LOG_SINCE, into
# $RUN_DIR/broker.log, by PROBE_DEADLINE, the deadline of the cycle wait that reads it. A read
# counts only when it has ended before that deadline: one that ends at or after it, whatever
# Docker answered, returns 1 like an unreadable one, with LOG_PROBE_DETAIL saying it ended late,
# so no line in it is used. A failed read, or one never started, returns 1 with
# LOG_PROBE_DETAIL as broker_logs left it.
read_window() {
    if ! broker_logs "$LOG_SINCE" >"$RUN_DIR/broker.log"; then
        return 1
    fi
    if [[ $SECONDS -ge $PROBE_DEADLINE ]]; then
        LOG_PROBE_DETAIL="broker-service logs read ended after the wait deadline and was discarded"
        return 1
    fi
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

# wait_cycle_line AFTER DEADLINE [ALERTS]: bounded poll, every LOG_STEP_SECONDS until DEADLINE
# (on the $SECONDS clock), for the first cycle line of the current window after the AFTER-th
# one. The caller sets DEADLINE at its own boundary, so time it spent since counts against the
# wait. With ALERTS, lines rendering another alert count are cycles that began during setup and
# are skipped. Sets CYCLE_INDEX and CYCLE_LINE. When open_verified_window holds its read of the
# window (WINDOW_READ_HELD), made by the CYCLE_DEADLINE its caller then passes as DEADLINE, the
# first attempt parses that read, even once DEADLINE has passed, and the hold is used up either
# way; every other attempt reads the window anew through read_window, which uses a read only
# when it ended before DEADLINE. Its log reads see the deadline as PROBE_DEADLINE, local to this
# call, so it ends with the wait; on expiry LOG_PROBE_DETAIL holds why the last read failed or
# was discarded, or nothing when it succeeded.
wait_cycle_line() {
    local after="$1" deadline="$2" wanted="${3:-}" reported="$1" held="$WINDOW_READ_HELD" index line
    local PROBE_DEADLINE="$deadline"
    WINDOW_READ_HELD=0
    while :; do
        if [[ $held -eq 1 ]] || read_window; then
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
        held=0
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

# armed_sql: every armed alert as one "id,revision" column, identical on both dialects, plus one
# "at,<time>" row: the database's own UTC time of the statement, in ISO 8601 with its fraction
# (PostgreSQL six digits; SQL Server seven, or none when it is zero). "at," never starts an id
# row, because t is not a hex digit.
armed_sql() {
    if [[ "$DIALECT" == "mssql" ]]; then
        echo "SELECT LOWER(CONVERT(varchar(36), [Id])) + ',' + CONVERT(varchar(12), [ArmingRevision]) FROM [dbo].[Alerts] WHERE [Enabled] = 1 AND [TriggeredAt] IS NULL UNION ALL SELECT 'at,' + CONVERT(varchar(27), SYSUTCDATETIME(), 126) ORDER BY 1"
    else
        echo "SELECT lower(\"Id\"::text) || ',' || \"ArmingRevision\" FROM \"Alerts\" WHERE \"Enabled\" = true AND \"TriggeredAt\" IS NULL UNION ALL SELECT 'at,' || to_char(statement_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US') ORDER BY 1"
    fi
}

# read_armed_set: runs the armed-set query once. Its id,revision rows go, sorted, to
# $RUN_DIR/armed, and its one time row sets ARMED_AT to the database's UTC time of that query in
# RFC3339: YYYY-MM-DDTHH:MM:SS, the fraction as returned, then Z. Sets ARMED_ERROR on failure,
# including a time row that is missing, repeated or unreadable.
read_armed_set() {
    local rows times stamp
    ARMED_AT=""
    if ! rows="$(db_query "$(armed_sql)")"; then
        ARMED_ERROR="armed-set query failed: $(tail -n 3 "$RUN_DIR/db-error.log" | tr '\n' ' ')$(head -n 3 <<<"$rows" | tr '\n' ' ')"
        return 1
    fi
    times="$(grep -ci '^at,' <<<"$rows" || true)"
    if [[ "$times" != "1" ]]; then
        ARMED_ERROR="armed-set query returned $times time rows instead of 1"
        return 1
    fi
    stamp="$(grep -i '^at,' <<<"$rows" | tr '[:upper:]' '[:lower:]')"
    if [[ ! "$stamp" =~ $ARMED_TIME_RE ]]; then
        ARMED_ERROR="armed-set query returned an unreadable time row [$stamp]"
        return 1
    fi
    ARMED_AT="${BASH_REMATCH[1]}T${BASH_REMATCH[2]}${BASH_REMATCH[3]}Z"
    rows="$(grep -vi '^at,' <<<"$rows" || true)"
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

# running_services: the project's running services, one per line. The call has ended within
# DOCKER_CALL_TIMEOUT_SECONDS (hard_timeout); one cut off fails the function with 124 or 137.
running_services() {
    hard_timeout "$DOCKER_CALL_TIMEOUT_SECONDS" docker compose -p "$PROJECT" -f "$COMPOSE_FILE" \
        ps --status running --services </dev/null 2>>"$RUN_DIR/compose.log" | tr -d '\r'
}

# require_running_services: samples the project's running services into RUNNING_SERVICES and
# aborts the run as "readiness", naming every required service that is not among them, or the
# Docker problem that kept the sample from being read.
require_running_services() {
    local service missing="" rc=0
    RUNNING_SERVICES="$(running_services)" || rc=$?
    if [[ $rc -ne 0 ]]; then
        abort "readiness" "$(docker_problem "compose ps" "$rc" "$DOCKER_CALL_TIMEOUT_SECONDS")"
    fi
    for service in $REQUIRED_SERVICES; do
        if ! grep -qxF "$service" <<<"$RUNNING_SERVICES"; then
            missing="$missing $service"
        fi
    done
    if [[ -n "$missing" ]]; then
        abort "readiness" "services not running in project [$PROJECT]:$missing"
    fi
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

# ---------------------------------------------------------------------------------------------
# Cleanup. Every step is idempotent, so an interrupted cleanup resumes when it runs again.

add_cleanup_problem() {
    CLEANUP_PROBLEMS="${CLEANUP_PROBLEMS:+$CLEANUP_PROBLEMS; }$1"
}

# delete_alert ID: DELETEs one alert by id. A transport error or a 5xx is tried again, up to
# DELETE_ATTEMPTS attempts in all, the wait after attempt n being n * DELETE_RETRY_STEP_SECONDS.
# Leaves the last answer in HTTP_STATUS and sets DELETE_ALL_TRANSPORT to 1 when every attempt
# ended in a transport error, otherwise to 0.
delete_alert() {
    local attempt
    DELETE_ALL_TRANSPORT=1
    for ((attempt = 1; attempt <= DELETE_ATTEMPTS; attempt++)); do
        http DELETE "$ALERTS_URL/$1"
        if [[ "$HTTP_STATUS" != "000" ]]; then
            DELETE_ALL_TRANSPORT=0
        fi
        case "$HTTP_STATUS" in
            000 | 5??) ;;
            *) return 0 ;;
        esac
        if [[ $attempt -lt $DELETE_ATTEMPTS ]]; then
            sleep $((attempt * DELETE_RETRY_STEP_SECONDS))
        fi
    done
}

# delete_owned_alerts [LABEL]: DELETEs every owned id not yet deleted, through delete_alert, and
# prints its lines under LABEL, cleanup by default. 204 and 404 are clean. A 403 comes from a
# flag switched off after it was read, or from the broker failing closed while it cannot read the
# flag, so the flag is read first (read_flag), at most MAX_FLAG_REENABLES times per call. Read as
# enabled=false, it is switched on again (put_flag) and the id tried once more; when FLAG_INITIAL
# is still empty, the run having ended before setup read the flag, false becomes the value
# cleanup_all restores, and a FLAG_INITIAL already set is kept. Read as enabled=true, the flag is
# left as it is and the id tried once more. A flag that cannot be read is left as it is, and the
# id keeps its 403. Any other outcome is printed with its id and listed in
# $RUN_DIR/left-in-place. After MAX_CONSECUTIVE_TRANSPORT_ERRORS ids in a row whose every
# attempt ended in a transport error, the once-more try included, the remaining ids are listed
# as not attempted. Ids left in place stay owned and undeleted, so the run record hands them to
# the next run on the project (adopt_earlier_runs).
delete_owned_alerts() {
    local label="${1:-cleanup}" id deleted=0 absent=0 left=0 skipped=0 transport=0 reenables=0
    local status text all_transport retry
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
        delete_alert "$id"
        status="$HTTP_STATUS"
        text="$(status_text)"
        all_transport="$DELETE_ALL_TRANSPORT"
        if [[ "$status" == "403" && $reenables -lt $MAX_FLAG_REENABLES ]]; then
            reenables=$((reenables + 1))
            retry=0
            http GET "$FLAG_URL"
            if [[ "$HTTP_STATUS" != "200" ]]; then
                info "$label: alert [$id] answered 403 and flag $FLAG_ID could not be read ($(status_text)); the flag is left as it is"
            elif ! read_flag "$HTTP_BODY"; then
                info "$label: alert [$id] answered 403 and flag $FLAG_ID could not be read (status 200, but $FLAG_ERROR); the flag is left as it is"
            elif [[ "$FLAG_ENABLED" == "true" ]]; then
                info "$label: alert [$id] answered 403 while flag $FLAG_ID reads enabled=true; trying it once more"
                retry=1
            else
                FLAG_TOUCHED=1
                FLAG_INITIAL="${FLAG_INITIAL:-$FLAG_ENABLED}"
                if put_flag true; then
                    info "$label: flag $FLAG_ID was switched off; switched on again to delete alert [$id]"
                    retry=1
                else
                    info "$label: flag $FLAG_ID was switched off and could not be switched on again: $FLAG_PUT_ERROR"
                fi
            fi
            if [[ $retry -eq 1 ]]; then
                delete_alert "$id"
                status="$HTTP_STATUS"
                text="$(status_text)"
                all_transport="$DELETE_ALL_TRANSPORT"
            fi
        fi
        case "$status" in
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
                if [[ "$status" == "000" && "$all_transport" == "1" ]]; then
                    transport=$((transport + 1))
                else
                    transport=0
                fi
                echo "$id $text" >>"$RUN_DIR/left-in-place"
                info "$label: alert [$id] left in place: $text"
                ;;
        esac
    done <"$RUN_DIR/to-delete"
    info "$label: $deleted alerts deleted, $absent already absent, $left left in place, $skipped not attempted"
    if [[ $((left + skipped)) -gt 0 ]]; then
        add_cleanup_problem "$((left + skipped)) owned alerts left in place, ids in $RUN_DIR/left-in-place${RUN_RECORD:+; the next run on project [$PROJECT] with base url $BASE_URL and compose file $COMPOSE_PATH deletes them first}"
    fi
}

# undeleted_count: the number of owned ids not yet deleted.
undeleted_count() {
    LC_ALL=C sort -u "$RUN_DIR/owned" >"$RUN_DIR/owned.sorted"
    LC_ALL=C sort -u "$RUN_DIR/deleted" >"$RUN_DIR/deleted.sorted"
    echo $(($(LC_ALL=C comm -23 "$RUN_DIR/owned.sorted" "$RUN_DIR/deleted.sorted" | wc -l)))
}

# Unknown creates. post_alert records each create whose outcome it cannot know in
# $RUN_DIR/unknown-creates, one "ENDED<TAB>ACCOUNT<TAB>TYPE<TAB>INSTRUMENT<TAB>DIRECTION<TAB>
# THRESHOLD" line each, ENDED being $SECONDS when its POST ended; the numbers of the lines that
# are reconciled go to $RUN_DIR/unknown-resolved. A create in $RUN_DIR/in-flight-create, which
# post_alert writes ahead of each POST and empties once the outcome is recorded, is an unknown
# create as well: cleanup moves it into unknown-creates (settle_in_flight), and a later run
# carries it from the directory of a run killed outright. The unknown creates an earlier run on
# the project left unreconciled are carried into $RUN_DIR/carried-creates (adopt_earlier_runs),
# one line each in the same form but led by that run's precondition time instead of ENDED; their
# reconciled line numbers go to $RUN_DIR/carried-resolved. Such an alert is found by its fields
# and deleted by its id, never by account, and its POST is never repeated.
#
# The broker logs a create without a trace id, so the alert of an unknown create is told only by
# what its row shows: this run does not own it, its type, instrumentId and direction are exactly
# the create's, its threshold has the create's value, its armingRevision is the JSON integer 1,
# and its createdAt, which db-adapter stamps from its UTC clock, is at or after the database's
# time of the cycle precondition that passed before the create (PRECONDITION_AT, kept in
# $RUN_DIR/precondition-at). The database and db-adapter containers read the one clock of their
# Docker engine. Its enabled and triggeredAt are no evidence either way: the evaluator may have
# triggered the alert already, since no threshold is assumed unreachable. The precondition found
# no armed alert, loadgen is stopped while alerts are created, e2e.sh never runs alongside, and
# the run lock keeps every other perf.sh run off the project, so an alert that shows all of this
# is the create's. An alert whose createdAt is a readable UTC time before the precondition time
# was made before the create and is left out, whatever its other fields. Any other alert of the
# same type, instrument and direction that this run does not own and that does not show all of
# this, one whose createdAt is no readable UTC time included, means the create's alert cannot be
# told from others, and so do more alerts that show all of it than such creates: nothing is
# deleted for them, and the check fails naming the create. So does a create whose precondition
# time is unknown. For a create carried from an earlier run, alerts made since that run ended,
# by loadgen for one, fall under the same rule.

# open_line_numbers CREATES RESOLVED: the numbers of the lines of the file CREATES that the file
# RESOLVED does not list, one per line; nothing when CREATES is missing or empty.
open_line_numbers() {
    local n=0 line
    if [[ ! -s "$1" ]]; then
        return 0
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        if ! grep -qxF "$n" "$2" 2>/dev/null; then
            echo "$n"
        fi
    done <"$1"
}

# unknown_open_lines [carried]: the line numbers of this run's unknown creates not yet
# reconciled, or with "carried" those of the creates carried from earlier runs, one per line.
unknown_open_lines() {
    if [[ "${1:-}" == "carried" ]]; then
        open_line_numbers "$RUN_DIR/carried-creates" "$RUN_DIR/carried-resolved"
    else
        open_line_numbers "$RUN_DIR/unknown-creates" "$RUN_DIR/unknown-resolved"
    fi
}

# read_create_line LINE: splits one unknown-create line into CR_FIRST, CR_ACCOUNT, CR_TYPE,
# CR_INSTRUMENT, CR_DIRECTION and CR_THRESHOLD, and sets CR_UNITS to the threshold in units of
# 1e-8. Fails unless LINE holds exactly six tab-separated fields of which the last five are
# canonical account and instrument ids around an exact type, an exact direction and a plain
# decimal threshold; what the first field must be is the caller's to check.
read_create_line() {
    local extra=""
    CR_FIRST=""
    CR_ACCOUNT=""
    CR_TYPE=""
    CR_INSTRUMENT=""
    CR_DIRECTION=""
    CR_THRESHOLD=""
    CR_UNITS=""
    IFS=$'\t' read -r CR_FIRST CR_ACCOUNT CR_TYPE CR_INSTRUMENT CR_DIRECTION CR_THRESHOLD extra \
        <<<"$1" || true
    [[ -z "$extra" && -n "$CR_FIRST" && "$CR_ACCOUNT" =~ $UUID_RE && "$CR_INSTRUMENT" =~ $UUID_RE ]] &&
        [[ "$CR_TYPE" == "TARGET_PRICE" || "$CR_TYPE" == "PROFIT_LOSS" ]] &&
        [[ "$CR_DIRECTION" == "ABOVE" || "$CR_DIRECTION" == "BELOW" ]] &&
        CR_UNITS="$(dec_to_units "$CR_THRESHOLD")"
}

# utc_time_key TIME: prints the fixed-width key of an RFC 3339 UTC time, which is
# YYYY-MM-DDTHH:MM:SS, an optional fraction of 1 to 9 digits, then Z or +00:00: its 14 date and
# time digits, then its fraction padded with zeros to 9 digits. Fails on any other text, a time
# with another offset included, so such a time is never compared.
utc_time_key() {
    local re='^([0-9]{4})-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):([0-5][0-9]):([0-5][0-9]|60)(\.([0-9]{1,9}))?(Z|\+00:00)$'
    local frac
    if [[ ! "$1" =~ $re ]]; then
        return 1
    fi
    frac="${BASH_REMATCH[8]}000000000"
    echo "${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[4]}${BASH_REMATCH[5]}${BASH_REMATCH[6]}${frac:0:9}"
}

# time_key_at_or_after KEY FROM: succeeds when the utc_time_key KEY is the time FROM or later.
# The 14 whole-second digits and the 9 fraction digits are compared as two numbers, since all
# 23 digits do not fit in one.
time_key_at_or_after() {
    local seconds=$((10#${1:0:14})) from=$((10#${2:0:14}))
    if [[ $seconds -ne $from ]]; then
        [[ $seconds -gt $from ]]
        return
    fi
    [[ $((10#${1:14:9})) -ge $((10#${2:14:9})) ]]
}

# unowned_matching_alerts ACCOUNT TYPE INSTRUMENT DIRECTION: GETs ACCOUNT's alerts and writes to
# $RUN_DIR/candidates one "ID THRESHOLD REVISION CREATED" line for each alert this run does not
# own whose type, instrumentId and direction are exactly these, whatever its enabled and
# triggeredAt. THRESHOLD and REVISION are the JSON number tokens of threshold and
# armingRevision, CREATED is the createdAt string when it holds only characters an RFC 3339 time
# has, and each is "-" otherwise. The reply must be one JSON object whose results array holds
# only objects with canonical ids; otherwise, and on any status but 200, it fails with
# LIST_ERROR, which never repeats the reply.
unowned_matching_alerts() {
    local rows
    LIST_ERROR=""
    : >"$RUN_DIR/candidates"
    http GET "$ALERTS_URL?accountId=$1"
    if [[ "$HTTP_STATUS" != "200" ]]; then
        LIST_ERROR="GET alerts of account [$1] gave $(status_text)"
        return 1
    fi
    if ! rows="$(jq -rs --arg re "$UUID_RE" --arg type "$2" --arg instrument "$3" --arg direction "$4" \
        "$JQ_CANONICAL$JQ_ONE_VALUE"'
        def token: if type == "number" then tojson else "-" end;
        def stamp: if type == "string" and test("^[0-9A-Za-z:.+-]{1,64}$") then . else "-" end;
        (one_value | if type == "object" and (.results | type) == "array" then .results
            else error("no results array") end) as $all
        | if any($all[]; type != "object" or (.id | canonical) == null) then error("unreadable alert")
          else $all[] end
        | select(.type == $type and (.instrumentId | canonical) == $instrument
            and .direction == $direction)
        | "\(.id | canonical) \(.threshold | token) \(.armingRevision | token) \(.createdAt | stamp)"' \
        2>/dev/null <<<"$HTTP_BODY" | tr -d '\r')"; then
        LIST_ERROR="GET alerts of account [$1] gave status 200, but its reply is not one JSON object with a results array of alerts with canonical ids"
        return 1
    fi
    if [[ -n "$rows" ]]; then
        LC_ALL=C sort -u "$RUN_DIR/owned" >"$RUN_DIR/owned.sorted"
        awk 'FILENAME == ARGV[1] { own[$1]; next } !($1 in own)' "$RUN_DIR/owned.sorted" - \
            <<<"$rows" >"$RUN_DIR/candidates"
    fi
}

# reconcile_unknown_creates [LABEL [carried]]: reconciles this run's unknown creates not yet
# reconciled, or with "carried" those carried from earlier runs, and prints its lines under
# LABEL, cleanup by default. Creates with the same account, type, instrument, direction,
# threshold value and precondition time form a group of N creates. Each poll reads the group's
# account list once (unowned_matching_alerts): its candidates are the alerts this run does not
# own with the create's type, instrument and direction, less those whose createdAt is a readable
# UTC time before the group's precondition time, which are left untouched, and the exact ones
# among them also show the rest of the evidence set out above. When a candidate is not exact,
# its createdAt not being a readable UTC time included, or there are more than N exact ones, the
# creates' alerts cannot be told from others: nothing is deleted for the group and the check
# fails naming it. Once there are N exact ones, or the group's settle deadline has passed, the
# exact ones join the owned set, for delete_owned_alerts to delete by id, and any shortfall is
# reported as not created. This run's deadline is UNKNOWN_CREATE_SETTLE_SECONDS after the
# group's last POST ended, and until then the list is read again every
# UNKNOWN_CREATE_STEP_SECONDS; a carried create's deadline is CARRIED_SETTLE_UNTIL, set when
# adopt_earlier_runs carried it. A failed list read, an unknown precondition time, or a line that
# cannot be read fails the check naming the create.
reconcile_unknown_creates() {
    local label="${1:-cleanup}" source="${2:-own}"
    local creates="$RUN_DIR/unknown-creates" resolved="$RUN_DIR/unknown-resolved"
    local -a records=() state=() keys=() deadlines=() descs=()
    local -a members=() exact=()
    local line n i j start deadline pending loose unreadable id token revision created value
    local account type instrument direction units since
    if [[ "$source" == "carried" ]]; then
        creates="$RUN_DIR/carried-creates"
        resolved="$RUN_DIR/carried-resolved"
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        records+=("$line")
    done <"$creates"
    for ((i = 0; i < ${#records[@]}; i++)); do
        state[i]="done"
        keys[i]=""
        deadlines[i]=0
        descs[i]=""
    done
    while IFS= read -r n; do
        i=$((n - 1))
        # This run's lines lead with the second its POST ended, and carried lines with the
        # precondition time of the run that made them.
        if ! read_create_line "${records[i]}" ||
            { [[ "$source" == "own" ]] && [[ ! "$CR_FIRST" =~ ^[0-9]+$ ]]; } ||
            { [[ "$source" == "carried" ]] && ! utc_time_key "$CR_FIRST" >/dev/null; }; then
            add_cleanup_problem "unknown create $n in $creates cannot be read, so it is not reconciled"
            state[i]="failed"
            continue
        fi
        descs[i]="$CR_TYPE $CR_DIRECTION $CR_THRESHOLD on instrument [$CR_INSTRUMENT] for account [$CR_ACCOUNT]"
        if [[ "$source" == "own" ]]; then
            start="$PRECONDITION_AT"
            deadlines[i]=$((CR_FIRST + UNKNOWN_CREATE_SETTLE_SECONDS))
        else
            start="$CR_FIRST"
            deadlines[i]=$CARRIED_SETTLE_UNTIL
        fi
        if ! since="$(utc_time_key "$start")"; then
            add_cleanup_problem "the create of ${descs[i]}, whose outcome is unknown, was not reconciled: the time of the cycle precondition before it is unknown, so no alert can be shown to be its own"
            state[i]="failed"
            continue
        fi
        keys[i]="$CR_ACCOUNT $CR_TYPE $CR_INSTRUMENT $CR_DIRECTION $CR_UNITS $since"
        state[i]="pending"
    done < <(unknown_open_lines "$source")

    while :; do
        pending=0
        for ((i = 0; i < ${#records[@]}; i++)); do
            if [[ "${state[i]}" != "pending" ]]; then
                continue
            fi
            members=()
            deadline=0
            for ((j = i; j < ${#records[@]}; j++)); do
                if [[ "${state[j]}" == "pending" && "${keys[j]}" == "${keys[i]}" ]]; then
                    members+=("$j")
                    if [[ ${deadlines[j]} -gt $deadline ]]; then
                        deadline=${deadlines[j]}
                    fi
                fi
            done
            read -r account type instrument direction units since <<<"${keys[i]}"
            if ! unowned_matching_alerts "$account" "$type" "$instrument" "$direction"; then
                add_cleanup_problem "the create of ${descs[i]}, whose outcome is unknown, was not reconciled: $LIST_ERROR"
                for j in "${members[@]}"; do
                    state[j]="failed"
                done
                continue
            fi
            loose=0
            unreadable=0
            exact=()
            while read -r id token revision created; do
                if ! created="$(utc_time_key "$created")"; then
                    unreadable=$((unreadable + 1))
                elif ! time_key_at_or_after "$created" "$since"; then
                    # Made before the precondition that passed before the create: not its alert.
                    continue
                elif value="$(dec_to_units "$token")" && [[ "$value" == "$units" && "$revision" == "1" ]]; then
                    exact+=("$id")
                fi
                loose=$((loose + 1))
            done <"$RUN_DIR/candidates"
            if [[ $loose -ne ${#exact[@]} || ${#exact[@]} -gt ${#members[@]} ]]; then
                add_cleanup_problem "the create of ${descs[i]}, whose outcome is unknown, cannot be told from other alerts: $loose alerts this run does not own match its type, instrument and direction without a createdAt before the cycle precondition, ${#exact[@]} of them with its threshold, armingRevision 1 and a createdAt at or after it, $unreadable of them with a createdAt that is no UTC time, for ${#members[@]} such creates; none of them was deleted"
                for j in "${members[@]}"; do
                    state[j]="failed"
                done
                continue
            fi
            if [[ ${#exact[@]} -lt ${#members[@]} && $SECONDS -lt $deadline ]]; then
                pending=$((pending + 1))
                for j in "${members[@]}"; do
                    state[j]="waiting"
                done
                continue
            fi
            for id in "${exact[@]}"; do
                echo "$id" >>"$RUN_DIR/owned"
                info "$label: alert [$id] is the create of ${descs[i]}, whose outcome was unknown; it is deleted as an owned alert"
            done
            if [[ ${#exact[@]} -lt ${#members[@]} ]]; then
                if [[ "$source" == "own" ]]; then
                    info "$label: $((${#members[@]} - ${#exact[@]})) create(s) of ${descs[i]}, whose outcome was unknown, made no alert within ${UNKNOWN_CREATE_SETTLE_SECONDS}s of the POST"
                else
                    info "$label: $((${#members[@]} - ${#exact[@]})) create(s) of ${descs[i]}, whose outcome an earlier run did not know, made no alert"
                fi
            fi
            for j in "${members[@]}"; do
                echo "$((j + 1))" >>"$resolved"
                state[j]="done"
            done
        done
        if [[ $pending -eq 0 ]]; then
            return 0
        fi
        sleep "$UNKNOWN_CREATE_STEP_SECONDS"
        for ((i = 0; i < ${#records[@]}; i++)); do
            if [[ "${state[i]}" == "waiting" ]]; then
                state[i]="pending"
            fi
        done
    done
}

# settle_in_flight: the create left in $RUN_DIR/in-flight-create, by a run that ended between
# post_alert's write-ahead and its record of the outcome, as through an error or a signal no trap
# holds, becomes an unknown create of this run: its line joins unknown-creates, led by $SECONDS,
# by which its POST has ended, and the file is emptied. A line already recorded there, which
# unknown-creates holding more lines than the count that leads it shows, is not recorded twice.
# A line that cannot be read stays where it is, so the run record keeps it for the next run
# (update_run_record), and is recorded as a cleanup problem.
settle_in_flight() {
    local line extra=""
    if [[ ! -s "$RUN_DIR/in-flight-create" ]]; then
        return 0
    fi
    if ! { IFS= read -r line && ! IFS= read -r extra; } 2>/dev/null <"$RUN_DIR/in-flight-create" ||
        ! read_create_line "$line" || [[ ! "$CR_FIRST" =~ ^[0-9]{1,9}$ ]]; then
        add_cleanup_problem "the create in $RUN_DIR/in-flight-create cannot be read, so it is not reconciled"
        return 0
    fi
    count_unknown_creates "$RUN_DIR"
    if [[ $UNKNOWN_COUNT -le $((10#$CR_FIRST)) ]]; then
        info "cleanup: the create of $CR_TYPE $CR_DIRECTION $CR_THRESHOLD on instrument [$CR_INSTRUMENT] for account [$CR_ACCOUNT] was in flight when the run ended; its outcome is unknown"
        record_unknown_create "$CR_ACCOUNT" "$CR_TYPE" "$CR_INSTRUMENT" "$CR_DIRECTION" "$CR_THRESHOLD"
    fi
    : >"$RUN_DIR/in-flight-create"
}

# cleanup_all: reconciles the unknown creates, this run's, the one it left in flight
# (settle_in_flight) and those carried from earlier runs, deletes every owned id not yet
# deleted, restores the flag and starts loadgen again, and records each problem in
# CLEANUP_PROBLEMS. Once the flag has been changed (FLAG_TOUCHED), it is
# restored to FLAG_INITIAL, the value setup read. A run that ends before setup read it can still
# own ids adopted from an earlier run: FLAG_INITIAL is then empty, and the value restored is the
# one found just before cleanup changed the flag, enabled=false, as cleanup's own read found it
# or the read after a DELETE's 403 found it (delete_owned_alerts). A FLAG_INITIAL that setup
# read is never replaced.
cleanup_all() {
    local remaining unknown carried rc=0
    CLEANUP_PROBLEMS=""
    settle_in_flight
    remaining="$(undeleted_count)"
    unknown=$(($(unknown_open_lines | wc -l)))
    carried=$(($(unknown_open_lines carried | wc -l)))
    if [[ $remaining -gt 0 || $unknown -gt 0 || $carried -gt 0 ]]; then
        # DELETE answers 403 while the flag is off, and so does the alert list a reconciliation
        # reads, so the flag is switched on first. Only a flag read as enabled=false is switched;
        # one that cannot be read is left as it is, and a DELETE that then answers 403 reads it
        # again and switches it on only when that read shows enabled=false (delete_owned_alerts).
        http GET "$FLAG_URL"
        if [[ "$HTTP_STATUS" != "200" ]]; then
            info "cleanup: flag $FLAG_ID not read ($(status_text)); deleting without switching it on"
        elif ! read_flag "$HTTP_BODY"; then
            info "cleanup: flag $FLAG_ID not read (status 200, but $FLAG_ERROR); deleting without switching it on"
        elif [[ "$FLAG_ENABLED" == "false" ]]; then
            FLAG_TOUCHED=1
            FLAG_INITIAL="${FLAG_INITIAL:-$FLAG_ENABLED}"
            if ! put_flag true; then
                add_cleanup_problem "flag could not be switched on for deletion: $FLAG_PUT_ERROR"
            fi
        fi
        if [[ $unknown -gt 0 ]]; then
            info "cleanup: reconciling $unknown creates whose outcome is unknown"
            reconcile_unknown_creates
        fi
        # Creates carried from earlier runs that recovery did not reconcile, or that the run
        # ended before recovery reached.
        if [[ $carried -gt 0 ]]; then
            info "cleanup: reconciling $carried creates whose outcome earlier runs did not know"
            reconcile_unknown_creates cleanup carried
        fi
        remaining="$(undeleted_count)"
        if [[ $remaining -gt 0 ]]; then
            info "cleanup: deleting $remaining owned alerts"
            delete_owned_alerts
        fi
    fi
    if [[ $FLAG_TOUCHED -eq 1 && -n "$FLAG_INITIAL" ]]; then
        if put_flag "$FLAG_INITIAL"; then
            info "cleanup: flag $FLAG_ID restored to enabled=$FLAG_INITIAL"
        else
            add_cleanup_problem "flag $FLAG_ID not restored to enabled=$FLAG_INITIAL: $FLAG_PUT_ERROR"
        fi
    fi
    # loadgen starts again last, after the deletions and the flag, and under a hard limit, so a
    # Docker engine that does not answer delays the exit by that limit at most.
    if [[ $LOADGEN_STOPPED -eq 1 ]]; then
        hard_timeout "$DOCKER_CALL_TIMEOUT_SECONDS" docker compose -p "$PROJECT" -f "$COMPOSE_FILE" \
            start loadgen </dev/null >>"$RUN_DIR/compose.log" 2>&1 || rc=$?
        if [[ $rc -eq 0 ]]; then
            info "cleanup: loadgen started again"
        else
            add_cleanup_problem "loadgen was running at start and could not be started again: $(docker_problem "compose start loadgen" "$rc" "$DOCKER_CALL_TIMEOUT_SECONDS")"
        fi
    fi
    update_run_record
    CLEANUP_DONE=1
}

# ---------------------------------------------------------------------------------------------
# Run lock and run records. The lock, a container on the project's Docker engine, lets one run
# at a time work on the project; a run record, kept in STATE_DIR, hands the owned alerts a run
# could not delete to the next run on it.

# lock_docker WHAT ARGS...: runs docker ARGS for the run lock under hard_timeout with
# DOCKER_CALL_TIMEOUT_SECONDS, so an engine that never answers cannot hold the run. Its output,
# without carriage returns, goes to LOCK_OUT and its errors to compose.log. On failure
# LOCK_PROBLEM tells why, naming the call WHAT (docker_problem).
lock_docker() {
    local what="$1" rc=0
    shift
    LOCK_PROBLEM=""
    LOCK_OUT="$(hard_timeout "$DOCKER_CALL_TIMEOUT_SECONDS" docker "$@" </dev/null 2>>"$RUN_DIR/compose.log" |
        tr -d '\r')" || rc=$?
    if [[ $rc -ne 0 ]]; then
        LOCK_PROBLEM="$(docker_problem "$what" "$rc" "$DOCKER_CALL_TIMEOUT_SECONDS")"
        return 1
    fi
}

# lock_host: this run's host as the lock records it, the host name and the system name. kill -0
# can judge only a pid of its own process table, and a Git Bash shell and a WSL shell on one
# machine share the host name but not their pids.
lock_host() {
    echo "$(uname -n) ($(uname -s))"
}

# read_lock_owner JSON: reads the lock container's docker inspect JSON, exactly one object, into
# LOCK_OWNER_ID, its container id, and from its owner labels into LOCK_OWNER_PID,
# LOCK_OWNER_HOST, LOCK_OWNER_STARTED and LOCK_OWNER_RUN, control characters shown as ?. Fails
# when the id is not a container id, or the labels lack a pid of 1 to 10 digits, a host or a run
# directory.
read_lock_owner() {
    local fields
    LOCK_OWNER_ID=""
    LOCK_OWNER_PID=""
    LOCK_OWNER_HOST=""
    LOCK_OWNER_STARTED=""
    LOCK_OWNER_RUN=""
    if ! fields="$(jq -rs --arg p "$LOCK_LABEL_PREFIX" "$JQ_ONE_VALUE"'
        one_value
        | (.Config.Labels // {}) as $labels
        | [.Id, $labels[$p + "pid"], $labels[$p + "host"], ($labels[$p + "started"] // ""),
            $labels[$p + "run-dir"]]
        | if (.[0] | type == "string" and test("\\A[0-9a-f]{12}([0-9a-f]{52})?\\z"))
            and (.[1] | type == "string" and test("\\A[0-9]{1,10}\\z"))
            and (.[2] | type == "string" and length > 0)
            and (.[3] | type == "string")
            and (.[4] | type == "string" and length > 0)
          then .[] | gsub("[[:cntrl:]]"; "?")
          else error("unreadable owner labels") end' <<<"$1" 2>/dev/null | tr -d '\r')"; then
        return 1
    fi
    {
        IFS= read -r LOCK_OWNER_ID && IFS= read -r LOCK_OWNER_PID && IFS= read -r LOCK_OWNER_HOST &&
            IFS= read -r LOCK_OWNER_STARTED && IFS= read -r LOCK_OWNER_RUN
    } <<<"$fields"
}

# acquire_run_lock: takes the project's run lock before anything about the stack is sampled or
# changed. The lock is the container LOCK_NAME, which docker create makes atomically on the
# project's Docker engine and which is never started. It is made from the image of the
# project's running db container, which that engine is sure to hold, and every Compose label
# that image carries is blanked, so Compose never counts the container in any project. Its owner
# labels hold this shell's pid, lock_host, the start time and the run directory, and LOCK_ID
# keeps its id.
#   - A name already taken by a lock whose owner ran on this host and no longer runs (kill -0
#     fails, or the pid is this shell's under another run directory) is stale: that container is
#     removed by its id, never by name, so a lock another run made meanwhile stays, and the
#     create is tried once more.
#   - Any other lock, a second conflict, owner labels that cannot be read, a Docker call that
#     fails or does not answer in time, or a state directory that is not this user's own aborts
#     the run as "run lock"; it never waits for a lock.
#   - A project whose db container is not running has no image to make the lock from, and aborts
#     the run as "readiness", naming every required service that is not running.
# Each abort comes before anything is changed; a lock container this run made is released on the
# way out.
acquire_run_lock() {
    local attempt host db_cid image keys key create_problem
    local args=()
    host="$(lock_host)"
    if ! (umask 077 && mkdir -p "$STATE_DIR/runs") 2>/dev/null || [[ -L "$STATE_DIR" || ! -O "$STATE_DIR" ]]; then
        abort "run lock" "state directory $STATE_DIR could not be made as this user's own"
    fi
    if ! lock_docker "compose ps db" compose -p "$PROJECT" -f "$COMPOSE_FILE" ps -q --status running db; then
        abort "run lock" "$LOCK_PROBLEM"
    fi
    db_cid="$(sed -n '1p' <<<"$LOCK_OUT")"
    if [[ -z "$db_cid" ]]; then
        require_running_services
        # The db service started after the lookup above: it was not running when the lock
        # needed it.
        abort "readiness" "services not running in project [$PROJECT]: db"
    fi
    if [[ ! "$db_cid" =~ $CONTAINER_ID_RE ]]; then
        abort "run lock" "compose ps db printed no container id"
    fi
    if ! lock_docker "docker inspect of the db container" inspect --type container --format '{{.Image}}' "$db_cid"; then
        abort "run lock" "$LOCK_PROBLEM"
    fi
    image="$LOCK_OUT"
    if [[ ! "$image" =~ ^[0-9A-Za-z][0-9A-Za-z_.:@/-]*$ ]]; then
        abort "run lock" "the db container's image cannot be read"
    fi
    if ! lock_docker "docker image inspect of the db image" image inspect --format '{{json .Config.Labels}}' "$image"; then
        abort "run lock" "$LOCK_PROBLEM"
    fi
    if ! keys="$(jq -r '(. // {}) | keys
        | if any(.[]; test("[[:cntrl:]]")) then error("control character in a label key") else . end
        | .[] | select(startswith("com.docker.compose."))' <<<"$LOCK_OUT" 2>/dev/null | tr -d '\r')"; then
        abort "run lock" "the labels of the db image cannot be read"
    fi
    args=(create --name "$LOCK_NAME")
    while IFS= read -r key; do
        if [[ -n "$key" ]]; then
            args+=(--label "$key=")
        fi
    done <<<"$keys"
    args+=(--label "${LOCK_LABEL_PREFIX}pid=$$" --label "${LOCK_LABEL_PREFIX}host=$host"
        --label "${LOCK_LABEL_PREFIX}started=$STARTED_AT" --label "${LOCK_LABEL_PREFIX}run-dir=$RUN_DIR"
        "$image")
    for attempt in 1 2; do
        if lock_docker "docker create $LOCK_NAME" "${args[@]}"; then
            if [[ "$LOCK_OUT" =~ $CONTAINER_ID_RE ]]; then
                LOCK_ID="$LOCK_OUT"
                LOCK_HELD=1
                pass "run lock"
                return 0
            fi
            create_problem="docker create $LOCK_NAME printed no container id"
        else
            create_problem="$LOCK_PROBLEM"
        fi
        # The name is taken, or the create failed; the container under the name, if any, tells.
        if ! lock_docker "docker inspect $LOCK_NAME" inspect --type container --format '{{json .}}' "$LOCK_NAME"; then
            abort "run lock" "$create_problem"
        fi
        if ! read_lock_owner "$LOCK_OUT"; then
            abort "run lock" "project [$PROJECT] is locked by container $LOCK_NAME, whose owner labels cannot be read; run docker rm -v $LOCK_NAME once no perf.sh runs on this project"
        fi
        if [[ "$LOCK_OWNER_HOST" == "$host" && "$LOCK_OWNER_PID" == "$$" && "$LOCK_OWNER_RUN" == "$RUN_DIR" ]]; then
            # This run's own create reached the engine, but its answer did not: the container is
            # this run's, so the abort releases it by its id.
            LOCK_ID="$LOCK_OWNER_ID"
            LOCK_HELD=1
            abort "run lock" "$create_problem"
        fi
        if [[ $attempt -eq 1 && "$LOCK_OWNER_HOST" == "$host" ]] &&
            { [[ "$LOCK_OWNER_PID" == "$$" ]] || ! kill -0 "$LOCK_OWNER_PID" 2>/dev/null; }; then
            info "run lock: removing the lock container $LOCK_OWNER_ID of pid $LOCK_OWNER_PID (run dir $LOCK_OWNER_RUN), which no longer runs"
            if ! lock_docker "docker rm $LOCK_OWNER_ID" rm -v "$LOCK_OWNER_ID"; then
                abort "run lock" "the stale lock container $LOCK_OWNER_ID was not removed: $LOCK_PROBLEM"
            fi
            continue
        fi
        break
    done
    abort "run lock" "project [$PROJECT] is locked by pid $LOCK_OWNER_PID on host $LOCK_OWNER_HOST since $LOCK_OWNER_STARTED (run dir $LOCK_OWNER_RUN); run one perf.sh at a time per project, or run docker rm -v $LOCK_NAME once that run has ended"
}

# release_run_lock: removes, by its id, the lock container this run created (LOCK_ID), and only
# while this run holds it; a container found by name is never removed here. A removal that fails
# or does not answer in time is reported and does not fail the run: the container stays, and
# the next run on this host reclaims it as stale.
release_run_lock() {
    if [[ $LOCK_HELD -ne 1 ]]; then
        return 0
    fi
    LOCK_HELD=0
    if ! lock_docker "docker rm $LOCK_ID" rm -v "$LOCK_ID"; then
        info "run lock: lock container $LOCK_ID not removed: $LOCK_PROBLEM; the next run on this host reclaims it, or run docker rm -v $LOCK_ID"
    fi
}

# record_run: writes this run's record, runs/<run directory name>, holding the run directory,
# the base URL and the compose file's absolute path, one per line. It is written before any
# alert is created, so the alerts of a run that ends without its cleanup are found as well.
record_run() {
    RUN_RECORD="$STATE_DIR/runs/${RUN_DIR##*/}"
    if ! printf '%s\n%s\n%s\n' "$RUN_DIR" "$BASE_URL" "$COMPOSE_PATH" >"$RUN_RECORD"; then
        abort "run lock" "the run record $RUN_RECORD could not be written"
    fi
}

# update_run_record: removes this run's record once every owned alert is deleted and every
# create whose outcome is unknown, this run's, the one left in $RUN_DIR/in-flight-create or one
# carried from an earlier run, is reconciled. Until then the record stays, so the next run on the
# project deletes those alerts and looks for those creates' alerts first (adopt_earlier_runs);
# creates left unreconciled are also recorded as a cleanup problem that says so.
update_run_record() {
    local open in_flight=0 files="unknown-creates"
    if [[ -z "$RUN_RECORD" ]]; then
        return 0
    fi
    if [[ -s "$RUN_DIR/in-flight-create" ]]; then
        in_flight=1
        files="unknown-creates, in-flight-create"
    fi
    open=$(($(unknown_open_lines | wc -l) + $(unknown_open_lines carried | wc -l) + in_flight))
    if [[ $open -gt 0 ]]; then
        add_cleanup_problem "$open creates whose outcome is unknown are not reconciled (lines of $RUN_DIR/$files and carried-creates); the next run on project [$PROJECT] with base url $BASE_URL and compose file $COMPOSE_PATH looks for their alerts first, and $RUN_RECORD can be removed by hand once those alerts are known to be gone"
    elif [[ "$(undeleted_count)" == "0" ]]; then
        rm -f "$RUN_RECORD"
        RUN_RECORD=""
    fi
}

# read_run_record FILE: reads a run record into RECORD_RUN_DIR, RECORD_BASE_URL and
# RECORD_COMPOSE. Fails unless FILE holds exactly three lines: a run directory whose name is the
# record's own, an origin is_base_origin accepts, and a compose file path.
read_run_record() {
    local extra=""
    RECORD_RUN_DIR=""
    RECORD_BASE_URL=""
    RECORD_COMPOSE=""
    {
        IFS= read -r RECORD_RUN_DIR && IFS= read -r RECORD_BASE_URL &&
            IFS= read -r RECORD_COMPOSE && ! IFS= read -r extra
    } <"$1" 2>/dev/null || return 1
    [[ -z "$extra" && "${RECORD_RUN_DIR##*/}" == "${1##*/}" && -n "$RECORD_COMPOSE" ]] &&
        is_base_origin "$RECORD_BASE_URL"
}

# earlier_open_creates DIR: prints, one carried line each, the creates whose outcome is unknown
# that the run directory DIR left unreconciled: every open line of DIR/unknown-creates, then the
# create DIR/in-flight-create holds, which a run killed between post_alert's write-ahead and its
# record of the outcome left there, each led by the precondition time in DIR/precondition-at
# instead of its first field, then every open line of DIR/carried-creates as it is. An in-flight
# create already recorded in unknown-creates, which holds more lines than the count that leads
# it then, is carried only as that line. Fails when any of these lines cannot be read
# (read_create_line, led by a second, a count or a UTC precondition time as its file requires),
# when DIR/in-flight-create holds more than one line, or when DIR has open unknown creates or an
# in-flight create of its own but no precondition-at of exactly one UTC time: a create is only
# made after the precondition passed.
earlier_open_creates() {
    local dir="$1" n precondition="" extra="" in_flight=""
    local -a records=()
    if [[ -s "$dir/in-flight-create" ]]; then
        if ! { IFS= read -r in_flight && ! IFS= read -r extra; } 2>/dev/null <"$dir/in-flight-create" ||
            ! read_create_line "$in_flight" || [[ ! "$CR_FIRST" =~ ^[0-9]{1,9}$ ]]; then
            return 1
        fi
        count_unknown_creates "$dir"
        if [[ $UNKNOWN_COUNT -gt $((10#$CR_FIRST)) ]]; then
            in_flight=""
        fi
    fi
    if [[ -n "$in_flight" || -n "$(open_line_numbers "$dir/unknown-creates" "$dir/unknown-resolved")" ]]; then
        if ! { IFS= read -r precondition && ! IFS= read -r extra; } 2>/dev/null <"$dir/precondition-at" ||
            ! utc_time_key "$precondition" >/dev/null; then
            return 1
        fi
    fi
    if [[ -n "$(open_line_numbers "$dir/unknown-creates" "$dir/unknown-resolved")" ]]; then
        mapfile -t records <"$dir/unknown-creates"
        while IFS= read -r n; do
            if ! read_create_line "${records[n - 1]}" || [[ ! "$CR_FIRST" =~ ^[0-9]+$ ]]; then
                return 1
            fi
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$precondition" "$CR_ACCOUNT" "$CR_TYPE" \
                "$CR_INSTRUMENT" "$CR_DIRECTION" "$CR_THRESHOLD"
        done < <(open_line_numbers "$dir/unknown-creates" "$dir/unknown-resolved")
    fi
    if [[ -n "$in_flight" ]]; then
        read_create_line "$in_flight" || return 1
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$precondition" "$CR_ACCOUNT" "$CR_TYPE" \
            "$CR_INSTRUMENT" "$CR_DIRECTION" "$CR_THRESHOLD"
    fi
    if [[ -n "$(open_line_numbers "$dir/carried-creates" "$dir/carried-resolved")" ]]; then
        mapfile -t records <"$dir/carried-creates"
        while IFS= read -r n; do
            if ! read_create_line "${records[n - 1]}" || ! utc_time_key "$CR_FIRST" >/dev/null; then
                return 1
            fi
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$CR_FIRST" "$CR_ACCOUNT" "$CR_TYPE" \
                "$CR_INSTRUMENT" "$CR_DIRECTION" "$CR_THRESHOLD"
        done < <(open_line_numbers "$dir/carried-creates" "$dir/carried-resolved")
    fi
}

# adopt_earlier_runs: adopts the owned alerts that earlier runs on this project left undeleted,
# and carries on the creates whose outcome they left unknown. Every other record is checked
# first, and one that cannot be read, whose run directory is gone, that names another base URL
# or compose file, or whose run directory lists unreconciled creates that cannot be read
# (earlier_open_creates) aborts the run as "recovery" before anything is changed: those alerts
# can only be deleted through the stack that record names, and only by what that run recorded.
# Then the owned ids of each recorded run that are canonical UUIDs and not in its deleted file
# are appended to this run's owned set and to $RUN_DIR/recovered, its unreconciled creates are
# appended to $RUN_DIR/carried-creates, and that record is removed, since this run's own record
# now stands for them. recover_earlier_alerts reconciles those creates and deletes those alerts
# once the flag is on. Carried creates are looked for until CARRIED_SETTLE_UNTIL, which is
# HTTP_TIMEOUT_SECONDS + UNKNOWN_CREATE_SETTLE_SECONDS after they were carried: the run lock
# shows that run ended, but a POST its kill left in flight may run on until its curl's --max-time.
adopt_earlier_runs() {
    local record count carried i
    local -a checked=() checked_dirs=()
    for record in "$STATE_DIR"/runs/*; do
        if [[ ! -f "$record" || "$record" == "$RUN_RECORD" ]]; then
            continue
        fi
        if ! read_run_record "$record"; then
            abort "recovery" "the record $record of an earlier run on project [$PROJECT] cannot be read; remove it once no alert of that run remains"
        fi
        if [[ "$RECORD_BASE_URL" != "$BASE_URL" || "$RECORD_COMPOSE" != "$COMPOSE_PATH" ]]; then
            abort "recovery" "run dir ${RECORD_RUN_DIR//[[:cntrl:]]/?} of an earlier run on project [$PROJECT] may hold alerts created through base url $RECORD_BASE_URL with compose file ${RECORD_COMPOSE//[[:cntrl:]]/?}; this run uses $BASE_URL with $COMPOSE_PATH, so it changes nothing. Run perf.sh with that run's base url and compose file to delete them, or remove $record once they are gone"
        fi
        if [[ ! -d "$RECORD_RUN_DIR" ]]; then
            abort "recovery" "run dir ${RECORD_RUN_DIR//[[:cntrl:]]/?}, recorded by an earlier run on project [$PROJECT], no longer exists, so the alerts it may hold cannot be deleted by id; remove $record once they are gone"
        fi
        if ! earlier_open_creates "$RECORD_RUN_DIR" >"$RUN_DIR/adopt.creates.${record##*/}"; then
            abort "recovery" "run dir ${RECORD_RUN_DIR//[[:cntrl:]]/?} of an earlier run on project [$PROJECT] lists creates whose outcome is unknown that cannot be read, or lacks the precondition time they are matched by, so their alerts cannot be told from others; remove $record once no alert of that run remains"
        fi
        checked+=("$record")
        checked_dirs+=("$RECORD_RUN_DIR")
    done
    # Only the records checked above are adopted, with what was read from them then.
    for ((i = 0; i < ${#checked[@]}; i++)); do
        record="${checked[i]}"
        RECORD_RUN_DIR="${checked_dirs[i]}"
        : >"$RUN_DIR/adopt.owned"
        : >"$RUN_DIR/adopt.deleted"
        if [[ -f "$RECORD_RUN_DIR/owned" ]]; then
            { grep -E "$UUID_RE" "$RECORD_RUN_DIR/owned" || true; } | LC_ALL=C sort -u >"$RUN_DIR/adopt.owned"
        fi
        if [[ -f "$RECORD_RUN_DIR/deleted" ]]; then
            LC_ALL=C sort -u "$RECORD_RUN_DIR/deleted" >"$RUN_DIR/adopt.deleted"
        fi
        LC_ALL=C comm -23 "$RUN_DIR/adopt.owned" "$RUN_DIR/adopt.deleted" >"$RUN_DIR/adopt.ids"
        count=$(($(wc -l <"$RUN_DIR/adopt.ids")))
        carried=$(($(wc -l <"$RUN_DIR/adopt.creates.${record##*/}")))
        cat "$RUN_DIR/adopt.ids" >>"$RUN_DIR/owned"
        cat "$RUN_DIR/adopt.ids" >>"$RUN_DIR/recovered"
        cat "$RUN_DIR/adopt.creates.${record##*/}" >>"$RUN_DIR/carried-creates"
        rm -f "$record"
        info "recovery: adopted $count owned alert ids that run dir $RECORD_RUN_DIR left undeleted"
        if [[ $carried -gt 0 ]]; then
            CARRIED_SETTLE_UNTIL=$((SECONDS + HTTP_TIMEOUT_SECONDS + UNKNOWN_CREATE_SETTLE_SECONDS))
            info "recovery: carried $carried creates whose outcome run dir $RECORD_RUN_DIR left unknown"
        fi
    done
}

# recover_earlier_alerts: the "recovery" check, run once the flag is on and before anything is
# measured, so the cycle precondition finds none of the earlier runs' alerts armed. It first
# reconciles the creates adopt_earlier_runs carried (reconcile_unknown_creates): each alert shown
# to be one of them joins the owned set, and a create whose alert cannot be shown, or whose list
# cannot be read, aborts the run with nothing deleted for it; it stays carried, so cleanup looks
# for it again and the run record keeps it for the next run. Then it deletes by id the alerts
# adopt_earlier_runs adopted and those the reconciliation found. An alert left in place aborts
# the run; it stays owned, so cleanup tries it again and the run record keeps it for the next
# run.
recover_earlier_alerts() {
    local count carried problems
    carried=$(($(unknown_open_lines carried | wc -l)))
    if [[ ! -s "$RUN_DIR/recovered" && $carried -eq 0 ]]; then
        return 0
    fi
    CLEANUP_PROBLEMS=""
    if [[ $carried -gt 0 ]]; then
        info "recovery: reconciling $carried creates whose outcome earlier runs on project [$PROJECT] did not know"
        reconcile_unknown_creates "recovery" carried
        problems="$CLEANUP_PROBLEMS"
        CLEANUP_PROBLEMS=""
        if [[ -n "$problems" ]]; then
            abort "recovery" "$problems"
        fi
    fi
    count="$(undeleted_count)"
    if [[ $count -gt 0 ]]; then
        info "recovery: deleting $count alerts that earlier runs on project [$PROJECT] left in place"
        delete_owned_alerts "recovery"
        problems="$CLEANUP_PROBLEMS"
        CLEANUP_PROBLEMS=""
        if [[ -n "$problems" ]]; then
            abort "recovery" "$problems"
        fi
    fi
    pass "recovery"
}

# ---------------------------------------------------------------------------------------------
# Report and exit

# print_report: prints the REPORT block and notes that it did (REPORT_PRINTED), so a run that
# ends early after finish printed it does not print it twice.
print_report() {
    REPORT_PRINTED=1
    echo "REPORT"
    printf '  %-24s %s\n' \
        "project" "$PROJECT" \
        "base url" "$BASE_URL" \
        "db type" "$(printf '%q' "${DIALECT:-n/a}")" \
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
    release_run_lock
    FINISHED=1
    echo "SUMMARY $passed passed, $failed failed"
    if [[ $failed -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

# Runs when the script ends anywhere but finish: an interrupt or an unexpected error. The early
# end is a failed check of its own ("run"), so the SUMMARY counts it, and the REPORT block is
# printed before cleanup unless finish already printed it. The exit status is kept, and 0
# becomes 1. Every line goes to the run's own stdout and stderr (restore_run_output).
# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
on_exit() {
    local status=$?
    trap - EXIT
    # The trap runs under the redirections of the call the run ended in, such as a log read into
    # broker.log, so the run's own stdout and stderr come back before anything is printed.
    restore_run_output
    if [[ $FINISHED -eq 1 ]]; then
        exit "$status"
    fi
    set +e
    info "run ended early with status $status; cleaning up"
    fail "run" "ended early with status $status"
    if [[ $REPORT_PRINTED -eq 0 ]]; then
        print_report
    fi
    if [[ $CLEANUP_DONE -eq 0 ]]; then
        cleanup_all
        if [[ -n "$CLEANUP_PROBLEMS" ]]; then
            fail "cleanup" "$CLEANUP_PROBLEMS"
        else
            pass "cleanup"
        fi
    fi
    release_run_lock
    info "run dir $RUN_DIR"
    echo "SUMMARY $passed passed, $failed failed"
    if [[ $status -eq 0 ]]; then
        status=1
    fi
    exit "$status"
}

# ---------------------------------------------------------------------------------------------
# Setup

# readyz SERVICE DEADLINE: one GET of SERVICE's readyz through the reverse proxy, sent only while
# DEADLINE (on the $SECONDS clock) is ahead, through http_within with a limit of the seconds
# left to it, at most HTTP_TIMEOUT_SECONDS. Sets READY_ANSWER to the answer's status text, or to
# why none was sent.
readyz() {
    local left=$(($2 - SECONDS)) limit
    if [[ $left -le 0 ]]; then
        READY_ANSWER="no answer (not probed: no time left before the deadline)"
        return 0
    fi
    limit=$((left < HTTP_TIMEOUT_SECONDS ? left : HTTP_TIMEOUT_SECONDS))
    http_within "$limit" GET "$BASE_URL/$1/readyz"
    READY_ANSWER="$(status_text)"
}

setup() {
    local deadline broker_ready flag_ready dialect raw_interval

    # The lock comes before anything about the stack is sampled: a run that sampled it first
    # could see loadgen stopped by the run holding the lock, which starts it again on exit, and
    # would then leave it running. This run's record follows, and the records of earlier runs
    # are read before the first change to the stack, so a mismatching one changes nothing.
    acquire_run_lock
    record_run
    adopt_earlier_runs
    require_running_services
    if grep -qxF "loadgen" <<<"$RUNNING_SERVICES"; then
        LOADGEN_WAS_RUNNING=1
    fi
    # Both answers must come by the deadline: no probe starts once it has passed, each may take
    # only the time left to it, and a pair answered after it is no pass.
    deadline=$((SECONDS + READY_TIMEOUT_SECONDS))
    while :; do
        readyz broker-service "$deadline"
        broker_ready="$READY_ANSWER"
        readyz feature-flag-service "$deadline"
        flag_ready="$READY_ANSWER"
        if [[ "$broker_ready" == "status 200" && "$flag_ready" == "status 200" ]]; then
            if [[ $SECONDS -le $deadline ]]; then
                break
            fi
            abort "readiness" "broker-service and feature-flag-service readyz gave status 200 only $((SECONDS - deadline))s after the ${READY_TIMEOUT_SECONDS}s deadline"
        fi
        # A sleep that reaches the deadline would leave no time to probe again.
        if [[ $((SECONDS + READY_STEP_SECONDS)) -ge $deadline ]]; then
            abort "readiness" "after ${READY_TIMEOUT_SECONDS}s broker-service readyz gave $broker_ready, feature-flag-service readyz gave $flag_ready"
        fi
        sleep "$READY_STEP_SECONDS"
    done
    pass "readiness"

    # The x keeps a trailing line feed of the value; printf %q prints a value with control
    # characters on one line, as $'...'. The value is read and checked in a local, so DIALECT,
    # which the REPORT shows, only ever holds mssql or postgres: an interrupt between the steps
    # leaves it empty, n/a in the REPORT.
    dialect="$(container_env db-adapter DB_TYPE && printf x)" || dialect=""
    dialect="${dialect%x}"
    if [[ "$dialect" != "mssql" && "$dialect" != "postgres" ]]; then
        abort "runtime facts" "db-adapter DB_TYPE is [${dialect:+$(printf '%q' "$dialect")}], expected mssql or postgres"
    fi
    DIALECT="$dialect"
    raw_interval="$(container_env broker-service ALERT_EVALUATION_INTERVAL_SECONDS && printf x)" || raw_interval=""
    raw_interval="${raw_interval%x}"
    EVAL_INTERVAL="$(resolve_interval "$raw_interval")"
    pass "runtime facts"
    info "db type $DIALECT; evaluation interval ${EVAL_INTERVAL}s (ALERT_EVALUATION_INTERVAL_SECONDS [${raw_interval:+$(printf '%q' "$raw_interval")}]); loadgen running at start: $([[ $LOADGEN_WAS_RUNNING -eq 1 ]] && echo yes || echo no)"

    read_initial_flag

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

    enable_flag
}

# read_initial_flag: GETs the flag, whose reply must read through read_flag as a modifiable
# flag, and keeps its value in FLAG_INITIAL for cleanup to restore. Aborts the run otherwise.
read_initial_flag() {
    http GET "$FLAG_URL"
    if [[ "$HTTP_STATUS" != "200" ]]; then
        abort "flag modifiable" "GET $FLAG_ID gave $(status_text)"
    fi
    if ! read_flag "$HTTP_BODY"; then
        abort "flag modifiable" "GET $FLAG_ID gave status 200, but $FLAG_ERROR"
    fi
    if [[ "$FLAG_MODIFIABLE" != "true" ]]; then
        abort "flag modifiable" "isModifiable is false; a deployment with ENABLE_MODIFY=false cannot be toggled"
    fi
    FLAG_INITIAL="$FLAG_ENABLED"
    pass "flag modifiable"
    info "flag $FLAG_ID initially enabled=$FLAG_INITIAL"
}

# enable_flag: switches the flag on for the measurement, and the reply must show it on
# (put_flag). FLAG_TOUCHED is set first, so an interrupted PUT still restores the flag on exit.
enable_flag() {
    FLAG_TOUCHED=1
    if ! put_flag true; then
        abort "flag enabled" "PUT {\"enabled\": true} gave $FLAG_PUT_ERROR"
    fi
    pass "flag enabled"
}

# ---------------------------------------------------------------------------------------------
# Inputs. Account and instrument ids come from remote JSON, so each one is checked to be a
# canonical UUID before it becomes part of a URL, a file name or a request body.

# jq definition, used with --arg re "$UUID_RE": the lower-cased text of a canonical UUID
# string, otherwise null. The length test keeps out a trailing newline, which jq's "$" accepts.
JQ_CANONICAL="def canonical: if type == \"string\" and length == 36 and (ascii_downcase | test(\$re)) then ascii_downcase else null end;"
# jq definition, used with jq -s: the one JSON value a body holds. jq -s reads the whole body,
# so trailing text fails the read and a second value fails here; neither is read as a body.
JQ_ONE_VALUE='def one_value: if length == 1 then .[0] else error("not exactly one JSON value") end;'

# id_file_matches FILE COUNT: succeeds when FILE holds exactly COUNT lines and each one is a
# canonical UUID. Otherwise empties FILE, so none of its lines is used, and sets
# ID_FILE_COUNTS naming what it held.
id_file_matches() {
    local line lines=0 malformed=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        lines=$((lines + 1))
        if [[ ! "$line" =~ $UUID_RE ]]; then
            malformed=$((malformed + 1))
        fi
    done <"$1"
    if [[ $lines -eq $2 && $malformed -eq 0 ]]; then
        return 0
    fi
    : >"$1"
    ID_FILE_COUNTS="$lines id lines written, $malformed of them not canonical UUIDs, $2 canonical ids counted"
    return 1
}

# read_id_list JSON FILE: writes the canonical ids of a {"results": [{"id": ...}]} body, in
# order, to FILE and sets IDS_TOTAL, IDS_INVALID (ids that are not canonical UUIDs) and
# IDS_DUPLICATE. The body must be exactly one JSON value. Fails, leaving FILE empty and
# IDS_ERROR naming the reason, when it is not, when jq cannot read it, when it has no results
# array, or when FILE would not hold exactly the canonical ids counted.
read_id_list() {
    local lines canonical
    IDS_ERROR=""
    : >"$2"
    # One line "total non-canonical canonical distinct", then the canonical ids in order.
    if ! lines="$(jq -rs --arg re "$UUID_RE" "$JQ_CANONICAL$JQ_ONE_VALUE"'
        (one_value | .results | if type == "array" then map((.id? // null) | canonical)
            else error("no results array") end) as $ids
        | [$ids[] | select(. != null)] as $ok
        | "\($ids | length) \([$ids[] | select(. == null)] | length) \($ok | length) \($ok | unique | length)",
          $ok[]' 2>/dev/null <<<"$1" | tr -d '\r')" ||
        [[ ! "${lines%%$'\n'*}" =~ ^([0-9]+)\ ([0-9]+)\ ([0-9]+)\ ([0-9]+)$ ]]; then
        IDS_ERROR="an unreadable ${HTTP_CTYPE:-untyped} body"
        return 1
    fi
    IDS_TOTAL="${BASH_REMATCH[1]}"
    IDS_INVALID="${BASH_REMATCH[2]}"
    canonical="${BASH_REMATCH[3]}"
    IDS_DUPLICATE=$((BASH_REMATCH[3] - BASH_REMATCH[4]))
    if [[ "$lines" == *$'\n'* ]]; then
        printf '%s\n' "${lines#*$'\n'}" >"$2"
    fi
    if ! id_file_matches "$2" "$canonical"; then
        IDS_ERROR="results whose written ids do not match their counts: $ID_FILE_COUNTS"
        return 1
    fi
}

# fetch_presets: the preset account ids of GET presets?limit=PRESET_COUNT, in the service's
# order, into $RUN_DIR/presets: each canonical UUID once, at its first occurrence, and at most
# PRESET_COUNT of them, so the presets verify_cycle_inputs requests stay bounded whatever the
# body holds.
# An id that is not a canonical UUID is never written. These ids are the candidates for the p95
# account even when they fall short of the cycle workload. PRESETS_ERROR names the counts
# unless the body held exactly PRESET_COUNT distinct canonical ids and nothing else; a status
# other than 200 or an unreadable body leaves no id at all.
fetch_presets() {
    PRESETS_ERROR=""
    : >"$RUN_DIR/presets"
    http GET "$BASE_URL/user-service/api/accounts/presets?limit=$PRESET_COUNT"
    if [[ "$HTTP_STATUS" != "200" ]]; then
        PRESETS_ERROR="GET presets gave $(status_text); exactly $PRESET_COUNT distinct canonical account ids are needed"
        return 0
    fi
    if ! read_id_list "$HTTP_BODY" "$RUN_DIR/presets-read"; then
        PRESETS_ERROR="GET presets gave status 200 with $IDS_ERROR; exactly $PRESET_COUNT distinct canonical account ids are needed"
        return 0
    fi
    awk -v limit="$PRESET_COUNT" '!seen[$0]++ && ++kept <= limit' "$RUN_DIR/presets-read" \
        >"$RUN_DIR/presets"
    if [[ $IDS_TOTAL -ne $PRESET_COUNT || $IDS_INVALID -ne 0 || $IDS_DUPLICATE -ne 0 ]]; then
        PRESETS_ERROR="GET presets gave $IDS_TOTAL accounts, $IDS_INVALID without a canonical UUID id and $IDS_DUPLICATE duplicate ids; exactly $PRESET_COUNT distinct canonical account ids are needed"
    fi
}

# insights_profile ACCOUNT: GETs the account's insights. Sets PROFILE_STATUS, PROFILE_COUNTS
# (empty when there are none to name) and PROFILE_QUALIFIES, and writes the distinct held
# instrument ids, sorted, to $RUN_DIR/held-ACCOUNT. PROFILE_QUALIFIES is 1, the p95 account's
# condition, when the body has exactly HOLDINGS_EXPECTED allocations and each is an object
# with a numeric quantity > 0; it comes from those counts alone, so neither the instrument ids
# nor the held file bear on it, and it is 0 otherwise. It succeeds, the cycle workload's
# condition, when the account qualifies and each of its allocations is held on a distinct
# canonical instrumentId. An ACCOUNT that is not a canonical UUID is refused before it reaches
# a file name or a URL. The body must be exactly one JSON value, and the held file exactly the
# canonical ids counted; otherwise the file is left empty.
insights_profile() {
    local lines allocations positive invalid held distinct
    PROFILE_COUNTS=""
    PROFILE_QUALIFIES=0
    if [[ ! "$1" =~ $UUID_RE ]]; then
        PROFILE_STATUS="refused: the account id is not a canonical UUID"
        return 1
    fi
    : >"$RUN_DIR/held-$1"
    http GET "$INSIGHTS_URL/$1"
    PROFILE_STATUS="$(status_text)"
    if [[ "$HTTP_STATUS" != "200" ]]; then
        return 1
    fi
    # One line "allocations positive non-canonical held distinct", then the distinct held
    # instrument ids, sorted. An allocation is held when its quantity is a JSON number above 0
    # and its instrumentId is a canonical UUID. The type is tested first because jq orders
    # every string and object above every number.
    if ! lines="$(jq -rs --arg re "$UUID_RE" "$JQ_CANONICAL$JQ_ONE_VALUE"'
        (one_value | .allocations | if type == "array" then . else error("no allocations array") end
            | map(if type == "object"
                then {positive: ((.quantity | type) == "number" and .quantity > 0), id: (.instrumentId | canonical)}
                else {positive: false, id: null} end)) as $all
        | [$all[] | select(.positive and .id != null) | .id] as $held
        | "\($all | length) \([$all[] | select(.positive)] | length) \([$all[] | select(.id == null)] | length) \($held | length) \($held | unique | length)",
          ($held | unique[])' 2>/dev/null <<<"$HTTP_BODY" | tr -d '\r')" ||
        [[ ! "${lines%%$'\n'*}" =~ ^([0-9]+)\ ([0-9]+)\ ([0-9]+)\ ([0-9]+)\ ([0-9]+)$ ]]; then
        PROFILE_STATUS="status 200 with an unreadable ${HTTP_CTYPE:-untyped} body"
        return 1
    fi
    allocations="${BASH_REMATCH[1]}"
    positive="${BASH_REMATCH[2]}"
    invalid="${BASH_REMATCH[3]}"
    held="${BASH_REMATCH[4]}"
    distinct="${BASH_REMATCH[5]}"
    PROFILE_COUNTS="$allocations allocations, $positive with a numeric quantity > 0, $invalid without a canonical instrumentId, $held held on $distinct distinct instruments"
    if [[ $allocations -eq $HOLDINGS_EXPECTED && $positive -eq $HOLDINGS_EXPECTED ]]; then
        PROFILE_QUALIFIES=1
    fi
    if [[ "$lines" == *$'\n'* ]]; then
        printf '%s\n' "${lines#*$'\n'}" | LC_ALL=C sort -u >"$RUN_DIR/held-$1"
    fi
    if ! id_file_matches "$RUN_DIR/held-$1" "$distinct"; then
        PROFILE_STATUS="status 200 with held instruments that do not match their counts: $ID_FILE_COUNTS"
        return 1
    fi
    if [[ $allocations -ne $HOLDINGS_EXPECTED || $held -ne $HOLDINGS_EXPECTED || $distinct -ne $HOLDINGS_EXPECTED ]]; then
        return 1
    fi
    return 0
}

# select_insights_account: the p95 account, from what preflight_inputs recorded before any
# timing: the first preset, in the service's order, whose PROFILE_QUALIFIES was 1, as
# SELECTED_ACCOUNT. The cycle inputs verdict does not bear on it: a preset list short of
# PRESET_COUNT, or a qualifying preset whose instrument ids or listing fall short, still gives
# the p95 its account. Sets SELECT_ERROR when preflight_inputs has not run, with PRESETS_ERROR
# when no preset id was read, and naming every preset's insights counts when none qualifies.
select_insights_account() {
    local k seen=""
    SELECTED_ACCOUNT=""
    SELECT_ERROR=""
    if [[ -z "${INPUTS_VERIFIED:-}" ]]; then
        SELECT_ERROR="the preset inputs were not verified before the account was selected"
        return 1
    fi
    if [[ ${#INPUT_IDS[@]} -eq 0 ]]; then
        SELECT_ERROR="${PRESETS_ERROR:-no preset account id was read}"
        return 1
    fi
    for ((k = 0; k < ${#INPUT_IDS[@]}; k++)); do
        if [[ "${INPUT_QUALIFIES[k]}" == "1" ]]; then
            SELECTED_ACCOUNT="${INPUT_IDS[k]}"
            return 0
        fi
        seen="$seen [${INPUT_IDS[k]}] ${INPUT_INSIGHTS[k]};"
    done
    SELECT_ERROR="no preset account has exactly $HOLDINGS_EXPECTED allocations, each with a numeric quantity > 0:$seen"
    return 1
}

# verify_cycle_inputs: the cycle workload's inputs. Every preset holds HOLDINGS_EXPECTED
# instruments (insights_profile succeeds), and its instrument listing returns exactly those:
# HOLDINGS_EXPECTED distinct canonical ids, the same set as the held one. Every id of
# $RUN_DIR/presets is profiled, also when PRESETS_ERROR is set, so a short preset list still
# yields the p95 account. An id that is not a canonical UUID is refused before any URL or file
# name is built from it. Records, per preset in order, INPUT_IDS, INPUT_QUALIFIES (its
# PROFILE_QUALIFIES, 0 for a refused id) and INPUT_INSIGHTS (its insights status and counts).
# Succeeds only when PRESETS_ERROR is empty, which fetch_presets leaves only for exactly
# PRESET_COUNT distinct canonical ids, and no preset falls short. Otherwise sets INPUTS_ERROR
# to PRESETS_ERROR and the counts of each account that falls short.
verify_cycle_inputs() {
    local id problem shortfalls="" listing unlisted unheld
    INPUTS_ERROR=""
    INPUT_IDS=()
    INPUT_QUALIFIES=()
    INPUT_INSIGHTS=()
    while IFS= read -r id; do
        INPUT_IDS+=("$id")
        if [[ ! "$id" =~ $UUID_RE ]]; then
            INPUT_QUALIFIES+=(0)
            INPUT_INSIGHTS+=("refused: the account id is not a canonical UUID")
            shortfalls="$shortfalls [$id] refused: the account id is not a canonical UUID, so neither its insights nor its instrument listing is requested;"
            continue
        fi
        problem=""
        if ! insights_profile "$id"; then
            problem="insights $PROFILE_STATUS${PROFILE_COUNTS:+, $PROFILE_COUNTS}"
        fi
        INPUT_QUALIFIES+=("$PROFILE_QUALIFIES")
        INPUT_INSIGHTS+=("$PROFILE_STATUS${PROFILE_COUNTS:+, $PROFILE_COUNTS}")
        listing=""
        http GET "$BASE_URL/broker-service/v1/instrument?accountId=$id"
        if [[ "$HTTP_STATUS" != "200" ]]; then
            listing="$(status_text)"
        elif ! read_id_list "$HTTP_BODY" "$RUN_DIR/listed"; then
            listing="status 200 with $IDS_ERROR"
        else
            LC_ALL=C sort -u -o "$RUN_DIR/listed" "$RUN_DIR/listed"
            unlisted=$(($(LC_ALL=C comm -23 "$RUN_DIR/held-$id" "$RUN_DIR/listed" | wc -l)))
            unheld=$(($(LC_ALL=C comm -13 "$RUN_DIR/held-$id" "$RUN_DIR/listed" | wc -l)))
            if [[ $IDS_TOTAL -ne $HOLDINGS_EXPECTED || $IDS_INVALID -ne 0 || $IDS_DUPLICATE -ne 0 ||
                $unlisted -ne 0 || $unheld -ne 0 ]]; then
                listing="$IDS_TOTAL results, $IDS_INVALID without a canonical UUID id, $IDS_DUPLICATE duplicate ids, $unlisted held instruments not listed, $unheld listed instruments not held"
            fi
        fi
        if [[ -n "$listing" ]]; then
            problem="${problem:+$problem, }instrument listing $listing"
        fi
        if [[ -n "$problem" ]]; then
            shortfalls="$shortfalls [$id] $problem;"
        fi
    done <"$RUN_DIR/presets"
    if [[ -n "$shortfalls" ]]; then
        INPUTS_ERROR="every preset must hold and list the same $HOLDINGS_EXPECTED instruments:$shortfalls"
    fi
    if [[ -n "$PRESETS_ERROR" ]]; then
        INPUTS_ERROR="$PRESETS_ERROR${INPUTS_ERROR:+; $INPUTS_ERROR}"
    fi
    if [[ -n "$INPUTS_ERROR" ]]; then
        return 1
    fi
    return 0
}

# preflight_inputs: runs verify_cycle_inputs once, after fetch_presets and before anything is
# timed or created, and prints its "cycle inputs" line. INPUTS_VERIFIED becomes 1 only when it
# passed: exactly PRESET_COUNT distinct canonical presets, each holding and listing the same
# HOLDINGS_EXPECTED instruments. measure_cycle creates alerts only then, while
# select_insights_account chooses the p95 account from the same record whatever the verdict.
preflight_inputs() {
    INPUTS_VERIFIED=0
    if verify_cycle_inputs; then
        INPUTS_VERIFIED=1
        pass "cycle inputs"
    else
        fail "cycle inputs" "$INPUTS_ERROR"
    fi
}


# ---------------------------------------------------------------------------------------------
# Limit 1: insights p95 < 500 ms for 15 holdings

# insights_trace_nonce: 16 lowercase hex digits that start every insights trace id of this run,
# so its trace ids differ from those of other runs and callers. They are read from
# /dev/urandom; where that is unreadable they are derived from the clock and the process id.
# The nonce only keeps trace ids apart and is no secret, so the fallback needs no strength.
insights_trace_nonce() {
    local nonce
    nonce="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')" || nonce=""
    if [[ ! "$nonce" =~ $TRACE_NONCE_RE ]]; then
        printf -v nonce '%08x%08x' $(($(date -u +%s) & 0xffffffff)) $(($$ & 0xffffffff))
    fi
    echo "$nonce"
}

# insights_trace NONCE INDEX: the W3C trace context of insights request INDEX (1-based). Sets
# INSIGHTS_TRACE_ID to NONCE followed by INDEX as 16 hex digits, and INSIGHTS_TRACEPARENT to
# "00-<trace id>-<INDEX as 16 hex digits>-01" (version 00, sampled). INDEX is at least 1, so
# neither id is the all-zero value W3C reserves as invalid. Fails on any other NONCE or INDEX.
insights_trace() {
    if [[ ! "$1" =~ $TRACE_NONCE_RE || ! "$2" =~ ^[1-9][0-9]{0,17}$ ]]; then
        return 1
    fi
    printf -v INSIGHTS_TRACE_ID '%s%016x' "$1" "$2"
    printf -v INSIGHTS_TRACEPARENT '00-%s-%016x-01' "$INSIGHTS_TRACE_ID" "$2"
}

# classify_insights_request RC OUT: classifies one insights request from curl's exit status RC
# and its -w output OUT, "<http_code> <time_total>". Sets REQUEST_STATUS, REQUEST_SECONDS and
# REQUEST_PROBLEM, the reason the request failed or empty. Succeeds only for a complete transfer
# that answered 200 with a readable time_total. The exit status is checked first: a transfer
# that breaks after a 200 header (timeout, partial body, write error) still prints 200.
classify_insights_request() {
    REQUEST_STATUS="${2%% *}"
    REQUEST_SECONDS=""
    if [[ "$2" == *" "* ]]; then
        REQUEST_SECONDS="${2#* }"
    fi
    REQUEST_PROBLEM=""
    if [[ "$1" != "0" ]]; then
        REQUEST_PROBLEM="transport error (curl exit $1, status ${REQUEST_STATUS:-none})"
    elif [[ "$REQUEST_STATUS" != "200" ]]; then
        REQUEST_PROBLEM="status ${REQUEST_STATUS:-none}"
    elif [[ ! "$REQUEST_SECONDS" =~ $TIME_TOTAL_RE ]]; then
        REQUEST_PROBLEM="unreadable time_total [${REQUEST_SECONDS:0:40}]"
    fi
    [[ -z "$REQUEST_PROBLEM" ]]
}

# insights_p95 FILE: the p95 of the timings in FILE, one per line: its INSIGHTS_P95_RANK-th
# sorted value. FILE must hold exactly TIMED_REQUESTS lines, each a readable time_total;
# otherwise it fails and prints nothing, so a p95 never comes from a short or damaged sample.
insights_p95() {
    local count valid
    if [[ ! -f "$1" ]]; then
        return 1
    fi
    count=$(($(wc -l <"$1")))
    valid=$(($(grep -cE "$TIME_TOTAL_RE" "$1" || true)))
    if [[ $count -ne $TIMED_REQUESTS || $valid -ne $count ]]; then
        return 1
    fi
    LC_ALL=C sort -n "$1" | sed -n "${INSIGHTS_P95_RANK}p"
}

# insights_trace_durations ACCOUNT LOG TRACES: the durationMs of every insights log line in LOG
# for ACCOUNT whose rendered trace id is listed in TRACES (one id per line), one per line in log
# order and each trace id once. Lines of other accounts, lines without a trace id and lines whose
# trace id is not listed (warm-ups, failed requests, other callers) are left out.
insights_trace_durations() {
    local line
    if [[ ! -s "$3" ]]; then
        return 0
    fi
    while IFS= read -r line; do
        if [[ "$line" =~ $INSIGHTS_TRACE_RE ]]; then
            echo "${BASH_REMATCH[3]} ${BASH_REMATCH[1]}"
        fi
    done < <(grep -F "Portfolio insights for account [$1]" "$2" || true) \
        | awk 'NR == FNR { wanted[$1] = 1; next } ($1 in wanted) && !seen[$1]++ { print $2 }' "$3" -
}

measure_insights() {
    local account="" since i total out rc nonce failures=0 reasons="" timed p95 p95_ms
    local matched median_ms server_p95_ms

    if ! select_insights_account; then
        fail "insights p95 account" "$SELECT_ERROR"
        return 0
    fi
    account="$SELECTED_ACCOUNT"
    R_INSIGHTS_ACCOUNT="$account"
    pass "insights p95 account"

    # Every request, warm-ups included, must complete with status 200 and a readable time_total.
    # Any failed one fails the check without a p95: a p95 over fewer than TIMED_REQUESTS timings
    # would not be the 190th of 200. Each request sends its own traceparent, and each valid timed
    # request records its trace id beside its time, so the broker's log line for it can be found.
    total=$((WARMUP_REQUESTS + TIMED_REQUESTS))
    nonce="$(insights_trace_nonce)"
    info "timing insights of account [$account]: $WARMUP_REQUESTS warm-up then $TIMED_REQUESTS sequential requests; request n sends trace id $nonce followed by n as 16 hex digits"
    since="$(epoch_to_rfc3339 $(($(date -u +%s) - LOG_SKEW_MARGIN_SECONDS)))"
    : >"$RUN_DIR/insights-times"
    : >"$RUN_DIR/insights-traces"
    for ((i = 1; i <= total; i++)); do
        insights_trace "$nonce" "$i"
        rc=0
        out="$(curl -sS --max-time "$HTTP_TIMEOUT_SECONDS" -o "$RUN_DIR/insights-body" \
            -H "traceparent: $INSIGHTS_TRACEPARENT" -w '%{http_code} %{time_total}' \
            "$INSIGHTS_URL/$account" 2>>"$RUN_DIR/curl-error.log")" || rc=$?
        if ! classify_insights_request "$rc" "$out"; then
            failures=$((failures + 1))
            if [[ $failures -le $INSIGHTS_REASONS_SHOWN ]]; then
                reasons="${reasons:+$reasons; }request $i: $REQUEST_PROBLEM"
            fi
        elif [[ $i -gt $WARMUP_REQUESTS ]]; then
            echo "$REQUEST_SECONDS" >>"$RUN_DIR/insights-times"
            echo "$INSIGHTS_TRACE_ID" >>"$RUN_DIR/insights-traces"
        fi
    done

    timed=$(($(wc -l <"$RUN_DIR/insights-times")))
    if [[ $failures -gt 0 ]]; then
        R_INSIGHTS_VERDICT="FAIL"
        if [[ $failures -gt $INSIGHTS_REASONS_SHOWN ]]; then
            reasons="$reasons; and $((failures - INSIGHTS_REASONS_SHOWN)) more"
        fi
        fail "insights p95 < 500 ms" "$failures of $total requests failed, so no p95 is computed: $reasons (curl messages in $RUN_DIR/curl-error.log)"
    elif ! p95="$(insights_p95 "$RUN_DIR/insights-times")"; then
        R_INSIGHTS_VERDICT="FAIL"
        fail "insights p95 < 500 ms" "$timed timing records were kept instead of exactly $TIMED_REQUESTS valid ones, so no p95 is computed"
    elif ! p95_ms="$(seconds_to_ms "$p95")"; then
        R_INSIGHTS_VERDICT="FAIL"
        fail "insights p95 < 500 ms" "the ${INSIGHTS_P95_RANK}th sorted timing [$p95] is beyond the comparable range"
    else
        R_INSIGHTS_P95="$p95_ms ms"
        info "insights p95 $p95_ms ms: the ${INSIGHTS_P95_RANK}th of $TIMED_REQUESTS sorted curl time_total values through the reverse proxy"
        if [[ $(dec_to_units "$p95") -lt $(dec_to_units "$INSIGHTS_LIMIT_SECONDS") ]]; then
            R_INSIGHTS_VERDICT="PASS"
            pass "insights p95 < 500 ms"
        else
            R_INSIGHTS_VERDICT="FAIL"
            fail "insights p95 < 500 ms" "p95 $p95_ms ms is not below 500 ms"
        fi
    fi

    # Server-side share, a report value rather than a check: the durationMs the broker logged for
    # the valid timed requests, matched by the trace id each one sent. Warm-ups, failed requests
    # and other callers' requests carry other trace ids and are left out.
    if ! broker_logs "$since" >"$RUN_DIR/insights.log"; then
        info "insights server share: $LOG_PROBE_DETAIL"
        return 0
    fi
    if ! insights_trace_durations "$account" "$RUN_DIR/insights.log" "$RUN_DIR/insights-traces" \
        >"$RUN_DIR/insights-server"; then
        info "insights server share: the insights log lines could not be matched to the timed trace ids"
        return 0
    fi
    matched=$(($(wc -l <"$RUN_DIR/insights-server")))
    if [[ $matched -eq 0 ]]; then
        info "insights server share: no insights log line of account [$account] carries the trace id of a valid timed request"
        return 0
    fi
    median_ms="$(nearest_rank 50 "$RUN_DIR/insights-server")"
    server_p95_ms="$(nearest_rank 95 "$RUN_DIR/insights-server")"
    R_SERVER_SHARE="median $median_ms ms, p95 $server_p95_ms ms over $matched of $TIMED_REQUESTS timed requests, matched by trace id"
    info "insights server share: $R_SERVER_SHARE"
    if [[ $matched -lt $TIMED_REQUESTS ]]; then
        info "insights server share: $((TIMED_REQUESTS - matched)) of $TIMED_REQUESTS timed requests are left out, as failed requests or without a log line carrying their trace id"
    fi
}

# ---------------------------------------------------------------------------------------------
# Limit 2: one evaluation cycle < 10 s for 1,000 alerts

# rearm_missing: PATCHes {"enabled":true} on every owned alert missing from the armed set and
# records the returned armingRevision in the expected set. A 200 counts only when its reply,
# read by read_alert_reply, is the patched alert, enabled, with an integer revision. REARMED
# counts the alerts re-armed. Sets REARM_ERROR on failure, with a fixed reason for a reply that
# does not show the re-arm.
rearm_missing() {
    local id reason
    REARMED=0
    cut -d, -f1 "$RUN_DIR/expected" | LC_ALL=C sort >"$RUN_DIR/expected.ids"
    cut -d, -f1 "$RUN_DIR/armed" | LC_ALL=C sort >"$RUN_DIR/armed.ids"
    LC_ALL=C comm -23 "$RUN_DIR/expected.ids" "$RUN_DIR/armed.ids" >"$RUN_DIR/missing"
    while IFS= read -r id; do
        http PATCH "$ALERTS_URL/$id" '{"enabled":true}'
        reason=""
        if [[ "$HTTP_STATUS" != "200" ]]; then
            reason="$(status_text)"
        elif ! read_alert_reply "$HTTP_BODY"; then
            reason="status 200, but its reply is not one JSON object"
        elif [[ "$REPLY_ID" != "$id" ]]; then
            reason="status 200, but its id is not the patched alert's"
        elif [[ "$REPLY_ENABLED" != "true" ]]; then
            reason="status 200, but its enabled is not true"
        elif [[ -z "$REPLY_REVISION" ]]; then
            reason="status 200, but its armingRevision is not a JSON integer of at least 1"
        fi
        if [[ -n "$reason" ]]; then
            REARM_ERROR="PATCH alert [$id] gave $reason"
            return 1
        fi
        awk -F, -v id="$id" -v rev="$REPLY_REVISION" 'BEGIN { OFS = "," } $1 == id { $2 = rev } { print }' \
            "$RUN_DIR/expected" >"$RUN_DIR/expected.new"
        mv "$RUN_DIR/expected.new" "$RUN_DIR/expected"
        REARMED=$((REARMED + 1))
    done <"$RUN_DIR/missing"
    info "re-armed $REARMED owned alerts missing from the armed set"
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

# open_verified_window: establishes T and opens the cycle-log window that starts at it. The
# owned set is verified first, and T (CYCLE_T) is the database's own time of the armed-set
# query that verified it. The window is `compose logs --since T` (LOG_SINCE), so every cycle
# line in it was logged after T and none is skipped (LOG_BASE is 0). The db container runs on
# the Docker engine whose clock stamps the log lines, so no host-clock margin applies. The first
# line after T is due within two intervals plus the margin: CYCLE_DEADLINE, on the $SECONDS
# clock, counts that allowance from just before the query, so it never ends later than T plus
# the allowance, and the caller's wait for that line ends at it. One read of the window
# (read_window), by the same deadline, checks that the logs are readable, and it is the first
# read of that wait: it stays in $RUN_DIR/broker.log with WINDOW_READ_HELD set, so the wait
# parses it before reading again and a line already in it is never lost to a later read.
# Returns 2 with OWNED_ERROR set when the armed set differs from the owned id,revision set, and
# 1 when no time is left to read the logs, when they are unreadable, or when the read ended at
# or after the deadline, LOG_PROBE_DETAIL saying which; WINDOW_READ_HELD is then 0.
open_verified_window() {
    local allowance=$((2 * EVAL_INTERVAL + CYCLE_WAIT_MARGIN_SECONDS)) PROBE_DEADLINE
    WINDOW_READ_HELD=0
    CYCLE_DEADLINE=$((SECONDS + allowance))
    if ! verify_owned_set; then
        return 2
    fi
    CYCLE_T="$ARMED_AT"
    LOG_SINCE="$CYCLE_T"
    LOG_BASE=0
    if [[ $SECONDS -ge $CYCLE_DEADLINE ]]; then
        LOG_PROBE_DETAIL="broker-service logs probe not started: no time left of the ${allowance}s allowance after $CYCLE_T"
        return 1
    fi
    PROBE_DEADLINE="$CYCLE_DEADLINE"
    if ! read_window; then
        return 1
    fi
    WINDOW_READ_HELD=1
}

# select_cycle_sample: establishes T over the owned set and reads the accepted sample. The
# first line of the verified window over ALERTS_EXPECTED alerts is the sample, read by
# open_verified_window's deadline, two intervals plus the margin after T. The window's first
# read, which open_verified_window makes and the wait parses before reading again, counts
# against it, and a read that ends at or after it is discarded with its lines; lines over
# another count are cycles that began during setup and are skipped. A sample is rejected when
# its line shows a trigger, skip, failure or another outcome, or when the armed set differs from
# the owned set after it. Owned alerts missing from the armed set are then re-armed. When any
# was, a new verified window opens at a new T and its first line over ALERTS_EXPECTED alerts is
# read by that window's deadline, in the same way. When none was, the owned set is verified
# again and reading goes on in the same window after the rejected line, so a cycle already
# logged there is the next one read, for up to two intervals plus the margin after that check.
# The workload itself never changes. Returns 0 with the accepted line in CYCLE_INDEX, CYCLE_LINE
# and the C_* values; otherwise prints the failing check and returns 1, at the latest after
# MAX_REJECTED_SAMPLES rejected samples.
select_cycle_sample() {
    local revisions rc rejected=0 reasons="" reason after deadline
    local timeout=$((2 * EVAL_INTERVAL + CYCLE_WAIT_MARGIN_SECONDS))

    revisions="$(cut -d, -f2 "$RUN_DIR/expected" | LC_ALL=C sort -u | tr '\n' ' ')"
    rc=0
    open_verified_window || rc=$?
    if [[ $rc -eq 1 ]]; then
        R_CYCLE_VERDICT="FAIL"
        fail "cycle < 10 s" "${LOG_PROBE_DETAIL:-broker-service logs unreadable (see $RUN_DIR/compose.log)}"
        return 1
    fi
    if [[ $rc -ne 0 ]]; then
        fail "cycle owned set" "$OWNED_ERROR"
        return 1
    fi
    if [[ "$revisions" != "1 " ]]; then
        fail "cycle owned set" "owned alerts carry revisions [${revisions% }], all must be 1"
        return 1
    fi
    pass "cycle owned set"
    after="$LOG_BASE"
    deadline="$CYCLE_DEADLINE"
    info "owned set verified at $CYCLE_T; waiting up to $((deadline > SECONDS ? deadline - SECONDS : 0))s, ${timeout}s after T in all, for a cycle over $ALERTS_EXPECTED alerts"

    while :; do
        if ! wait_cycle_line "$after" "$deadline" "$ALERTS_EXPECTED"; then
            R_CYCLE_VERDICT="FAIL"
            fail "cycle < 10 s" "no cycle line rendered alerts [$ALERTS_EXPECTED] within ${timeout}s after $CYCLE_T${LOG_PROBE_DETAIL:+; last read: $LOG_PROBE_DETAIL}${reasons:+; rejected: $reasons}"
            return 1
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
            return 0
        fi
        rejected=$((rejected + 1))
        R_CYCLE_REJECTIONS="$rejected"
        reasons="${reasons:+$reasons; }sample $rejected: $reason"
        info "cycle sample $rejected rejected: $reason"
        if [[ $rejected -ge $MAX_REJECTED_SAMPLES ]]; then
            R_CYCLE_VERDICT="FAIL"
            fail "cycle < 10 s" "no clean sample: $reasons"
            return 1
        fi
        if ! read_armed_set; then
            R_CYCLE_VERDICT="FAIL"
            fail "cycle < 10 s" "no clean sample: $ARMED_ERROR; $reasons"
            return 1
        fi
        if ! rearm_missing; then
            R_CYCLE_VERDICT="FAIL"
            fail "cycle < 10 s" "no clean sample: re-arming failed, $REARM_ERROR; $reasons"
            return 1
        fi
        if [[ $REARMED -eq 0 ]]; then
            if ! verify_owned_set; then
                R_CYCLE_VERDICT="FAIL"
                fail "cycle < 10 s" "no clean sample: after re-arming $OWNED_ERROR; $reasons"
                return 1
            fi
            after="$CYCLE_INDEX"
            deadline=$((SECONDS + timeout))
            info "nothing re-armed and the owned set verified again; waiting up to ${timeout}s for the next cycle over $ALERTS_EXPECTED alerts after line $after of the window since $CYCLE_T"
            continue
        fi
        rc=0
        open_verified_window || rc=$?
        if [[ $rc -eq 1 ]]; then
            R_CYCLE_VERDICT="FAIL"
            fail "cycle < 10 s" "${LOG_PROBE_DETAIL:-broker-service logs unreadable (see $RUN_DIR/compose.log)}"
            return 1
        fi
        if [[ $rc -ne 0 ]]; then
            R_CYCLE_VERDICT="FAIL"
            fail "cycle < 10 s" "no clean sample: after re-arming $OWNED_ERROR; $reasons"
            return 1
        fi
        after="$LOG_BASE"
        deadline="$CYCLE_DEADLINE"
        info "owned set verified at $CYCLE_T; waiting up to $((deadline > SECONDS ? deadline - SECONDS : 0))s, ${timeout}s after T in all, for a cycle over $ALERTS_EXPECTED alerts"
    done
}

# record_follow_ups: records the FOLLOW_UP_CYCLES clean cycles after the accepted sample as
# evidence and prints one `cycle follow-ups` check, apart from the `cycle < 10 s` verdict.
# Reading continues in the sample's window after CYCLE_INDEX, within one interval plus the
# margin per line. A follow-up is clean when its line is clean and the armed set still equals
# the owned id,revision set after it, and only a clean one fills a slot. After an unclean one,
# owned alerts missing from the armed set are re-armed. When any was, a new verified window
# opens at a new T and its first line over ALERTS_EXPECTED alerts is read by that window's
# deadline, two intervals plus the margin after T, starting with the window's first read, which
# open_verified_window made. When none was, the owned set is verified again and reading goes on
# in the same window after the unclean line, so cycles already logged there are the next
# follow-ups, each read within one interval plus the margin. Every wait discards a read that
# ends at or after its deadline. Recording stops when FOLLOW_UP_CYCLES clean follow-ups are
# recorded, after MAX_REJECTED_SAMPLES unclean ones, or when a wait times out or the logs, the
# database or a re-arm fail; the check then fails with the shortfall and its reasons. Sets
# R_FOLLOW_UPS to the recorded durations and any shortfall.
record_follow_ups() {
    local after="$CYCLE_INDEX" wanted="" attempt=0 clean=0 unclean=0 durations="" problems=""
    local problem rc deadline="" timeout=$((EVAL_INTERVAL + CYCLE_WAIT_MARGIN_SECONDS))

    while [[ $clean -lt $FOLLOW_UP_CYCLES ]]; do
        attempt=$((attempt + 1))
        # A re-armed window set its deadline at its T; any other read counts from now, straight
        # after the previous line or the check after it.
        if [[ -z "$deadline" ]]; then
            deadline=$((SECONDS + timeout))
        fi
        if ! wait_cycle_line "$after" "$deadline" "$wanted"; then
            if [[ -n "$wanted" ]]; then
                problem="no cycle line rendered alerts [$wanted] within ${timeout}s after $CYCLE_T${LOG_PROBE_DETAIL:+; last read: $LOG_PROBE_DETAIL}"
            else
                problem="no cycle line within ${timeout}s${LOG_PROBE_DETAIL:+; last read: $LOG_PROBE_DETAIL}"
            fi
            problems="${problems:+$problems; }follow-up $attempt: $problem"
            info "follow-up cycle $attempt: $problem"
            break
        fi
        after="$CYCLE_INDEX"
        wanted=""
        deadline=""
        timeout=$((EVAL_INTERVAL + CYCLE_WAIT_MARGIN_SECONDS))
        parse_cycle_line "$CYCLE_LINE"
        problem=""
        if ! cycle_is_clean; then
            problem="cycle line shows $(cycle_summary_text)"
        fi
        if ! verify_owned_set; then
            problem="${problem:+$problem, }$OWNED_ERROR"
        fi
        if [[ -z "$problem" ]]; then
            clean=$((clean + 1))
            durations="${durations:+$durations, }$C_DURATION ms"
            info "follow-up cycle $attempt: $C_DURATION ms"
            continue
        fi
        unclean=$((unclean + 1))
        problems="${problems:+$problems; }follow-up $attempt: $problem"
        info "follow-up cycle $attempt rejected: $problem"
        if [[ $unclean -ge $MAX_REJECTED_SAMPLES ]]; then
            problems="$problems; stopped after $unclean unclean follow-up cycles"
            break
        fi
        if ! read_armed_set; then
            problems="$problems; $ARMED_ERROR"
            break
        fi
        if ! rearm_missing; then
            problems="$problems; re-arming failed, $REARM_ERROR"
            break
        fi
        if [[ $REARMED -eq 0 ]]; then
            if ! verify_owned_set; then
                problems="$problems; after re-arming $OWNED_ERROR"
                break
            fi
            info "nothing re-armed and the owned set verified again; waiting up to ${timeout}s for the next cycle after line $after of the window since $CYCLE_T"
            continue
        fi
        rc=0
        open_verified_window || rc=$?
        if [[ $rc -eq 1 ]]; then
            problems="$problems; ${LOG_PROBE_DETAIL:-broker-service logs unreadable (see $RUN_DIR/compose.log)}"
            break
        fi
        if [[ $rc -ne 0 ]]; then
            problems="$problems; after re-arming $OWNED_ERROR"
            break
        fi
        after="$LOG_BASE"
        wanted="$ALERTS_EXPECTED"
        timeout=$((2 * EVAL_INTERVAL + CYCLE_WAIT_MARGIN_SECONDS))
        deadline="$CYCLE_DEADLINE"
        info "owned set verified again at $CYCLE_T; waiting up to $((deadline > SECONDS ? deadline - SECONDS : 0))s, ${timeout}s after T in all, for a cycle over $ALERTS_EXPECTED alerts"
    done

    if [[ $clean -ge $FOLLOW_UP_CYCLES ]]; then
        R_FOLLOW_UPS="$durations"
        pass "cycle follow-ups"
    else
        R_FOLLOW_UPS="${durations:-none} ($clean of $FOLLOW_UP_CYCLES clean follow-up cycles recorded)"
        fail "cycle follow-ups" "$clean of $FOLLOW_UP_CYCLES clean follow-up cycles recorded; $problems"
    fi
}

measure_cycle() {
    local id armed created=0 k type instrument held
    local instruments units limit

    # Inputs: all presets hold every instrument, and every instrument is listed with a price.
    # preflight_inputs verified them before anything was timed and printed "cycle inputs";
    # nothing is created on inputs that failed it.
    if [[ "${INPUTS_VERIFIED:-0}" != "1" ]]; then
        info "cycle not measured: the cycle inputs check did not pass"
        return 0
    fi

    if ! read_armed_set; then
        fail "cycle precondition" "$ARMED_ERROR"
        return 0
    fi
    armed=$(($(wc -l <"$RUN_DIR/armed")))
    if [[ $armed -ne 0 ]]; then
        fail "cycle precondition" "$armed armed alerts already exist; the measurement needs none besides its own"
        return 0
    fi
    # The database's time of the query that passed: every alert this run creates is stamped at
    # or after it, which tells the alert of a create whose outcome is unknown from alerts made
    # before (reconcile_unknown_creates). The file hands it to the next run, with any such create
    # left unreconciled (adopt_earlier_runs). Nothing is created without it.
    if ! printf '%s\n' "$ARMED_AT" >"$RUN_DIR/precondition-at"; then
        fail "cycle precondition" "its time could not be written to $RUN_DIR/precondition-at"
        return 0
    fi
    PRECONDITION_AT="$ARMED_AT"
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

    if ! select_cycle_sample; then
        return 0
    fi

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

    # Follow-ups are recorded after any verdict on the accepted sample, and are never held to
    # the 10 s limit.
    record_follow_ups
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

# install_traps: keeps copies of the run's stdout and stderr on descriptors 8 and 9, names them
# in RUN_STDOUT_FD and RUN_STDERR_FD for restore_run_output, then runs on_exit on EXIT and
# on_signal on INT and TERM. The descriptors are fixed because bash 3.2 cannot allocate one into
# a variable, and the script opens no other descriptor by number. Child processes inherit the
# copies as they inherit stdout and stderr, and the run starts none in the background, so no
# copy holds the run's output open once it has exited. When the copies cannot be made, as with
# stdout closed, the run ends with exit 2 before any trap is set or the stack is touched.
install_traps() {
    if ! exec 8>&1 9>&2; then
        echo "Could not keep copies of stdout and stderr for the exit report." >&2
        exit 2
    fi
    RUN_STDOUT_FD=8
    RUN_STDERR_FD=9
    trap on_exit EXIT
    trap on_signal INT TERM
}

# main ARGS...: reads the options, checks the tools and makes the run directory, then installs
# the traps, whose cleanup needs that directory, and runs the checks in order. The state
# directory and the run lock are written only from here on, by setup.
main() {
    parse_options "$@"
    check_tools
    prepare_run
    install_traps

    STARTED_AT="$(now_rfc3339)"
    info "run dir $RUN_DIR"
    info "started $STARTED_AT: project [$PROJECT], base url $BASE_URL, compose file $COMPOSE_FILE"
    setup
    recover_earlier_alerts
    fetch_presets
    preflight_inputs
    measure_insights
    measure_cycle
    finish
}

# Sourcing the file defines its functions and constants without running it: it reads no option,
# checks no tool, makes no run directory, writes no state directory, takes no lock and sets no
# trap.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
