#!/usr/bin/env bash
# Unit tests for the helpers of scripts/portfolio-insights/perf.sh. perf.sh does all of its work
# in main(), which it calls only when it is executed: sourced, it only defines its functions and
# constants. These cases source it, set its options, tool check and run directory up through its
# own parse_options, check_tools and prepare_run, as main does before its traps, and call its
# functions, and every outside effect is a stub:
#   - docker and curl are shell functions that record each call and answer with canned output,
#     and timeout is one that records the hard limit perf.sh's hard_timeout gives a Docker call
#     and runs that call through the docker function, so no container, stack, database or
#     network is reached. docker and curl program files ahead of the real ones on PATH fail any
#     case whose calls go around the functions. The armed-set query runs against real SQL Server
#     and PostgreSQL databases in scripts/portfolio-insights/harness-sql-test.sh; the stub cases
#     cover perf.sh's own handling of it: the exact query text and client invocation, login and
#     query timeouts included, per dialect, refusal before any query, the id,revision rows and
#     the one time row it reads back through the container client's output, an answer without
#     exactly one readable time row, the propagation of the client's exit status, and a call the
#     limit cut off;
#   - sleep advances SECONDS instead of waiting, date prints one fixed time, and od gives the
#     target check fixed random bytes.
# Covered: the command line, direct execution running main, sourcing that runs nothing, the tool
# check with a tool missing or its compose plugin probe failing, exact decimals, the nearest-rank
# percentile, cycle-line parsing, sample eligibility, bounded log polling and the held window
# read it parses first, the armed-set query on both dialects including client failures, cut-off
# calls and unexpected answers, the owned-set comparison, re-arming after a rejected sample,
# alert creation outcomes and the write-ahead record of each create, unknown creates and their
# reconciliation, the in-flight create of a killed run, http's write-out record and the POST's
# shield against INT and TERM, the typed flag and alert replies, the run lock container on the
# project's Docker engine (its creation, stale reclaim by id, refusal and release), setup's
# readiness wait against its deadline, setup's Docker reads and stop of loadgen failing or cut
# off before any change, setup's target check stopping a base URL another stack serves before
# any change or any earlier run's alert is taken on, the time limit of every request, which no
# exported variable changes, and every cleanup and exit path, the bounded start of loadgen
# included. Covered elsewhere: the recording of a created alert by perf-inputs-test.sh; each
# time-row format read into ARMED_AT and the sample and follow-up selection built on the armed
# set by perf-cycle-test.sh; the insights p95 measurement by perf-insights-test.sh;
# hard_timeout, broker_logs, running_services, container_env, the compose plugin check and the
# armed-set query against Docker calls that never answer by harness-test.sh; a log read that
# ends after its wait's deadline by harness-test.sh and perf-cycle-test.sh.
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
# Stubs. docker, curl and timeout are defined before load_perf runs perf.sh's tool check, which
# looks for them. Like the helpers below they use builtins only: every fork is slow under Git Bash.

STUB_EXEC_OUT=""
STUB_EXEC_ERR=""
STUB_EXEC_RC=0
STUB_LOGS_RC=0
STUB_LOG_POLLS=0
STUB_START_RC=0
STUB_SIGNAL_PID=""
STUB_TIMEOUT_RC=""
STUB_CURL_MODE=""
STUB_SELF_SIGNALS=""
STUB_TIMEOUT_ON=""
STUB_RUNNING=""
STUB_PS_RC=0
STUB_STOP_RC=0
STUB_INSPECT_FAIL=""
STUB_INSPECT_RC=1
STUB_DB_IMAGE=""
STUB_IMAGE_LABELS=""
STUB_CREATE_RC=0
STUB_RM_RC=0
STUB_RESPAWN=""
STUB_ENV_SIGNAL_PID=""
STUB_DB_CID=""
STUB_CREATE_PRINTS=""
# The log of the stack that serves the base URL, where curl adds the access line of each
# target-check probe it answers: proxy.log, the named project's own reverse-proxy log, or
# other-proxy.log, another stack's.
STUB_SERVED_LOG="$STUB/proxy.log"

# A ready stack: every service perf.sh requires, loadgen not among them.
STUB_READY_SERVICES="broker-service db db-adapter feature-flag-service pricing-service reverse-proxy user-service"
# The db container's image, and the Compose labels a compose build gives that image.
DB_IMAGE="sha256:$(printf '%064d' 1)"
DB_IMAGE_LABELS='{"com.docker.compose.project":"unit-test","com.docker.compose.service":"db","com.docker.compose.version":"5.3.1"}'
LOCK_CONTAINER="pi-perf-lock.unit-test"
# The ids of a lock another run holds, and of one another run makes when a removal frees the name.
HELD_ID="feed$(printf '%060d' 1)"
RESPAWN_ID="beef$(printf '%060d' 2)"

# reset_stubs: empty call records, no lock container, and default answers: a ready stack.
reset_stubs() {
    local file
    for file in docker.calls logs.calls requests responses sleeps exec.args timeouts in-flight.seen \
        max-times proxy.log other-proxy.log; do
        : >"$STUB/$file"
    done
    rm -f "$STUB"/lock.* "$STUB"/env.*
    echo 0 >"$STUB/lock.count"
    STUB_SERVED_LOG="$STUB/proxy.log"
    STUB_EXEC_OUT=""
    STUB_EXEC_ERR=""
    STUB_EXEC_RC=0
    STUB_LOGS_RC=0
    STUB_LOG_POLLS=0
    STUB_START_RC=0
    STUB_SIGNAL_PID=""
    STUB_TIMEOUT_RC=""
    STUB_CURL_MODE=""
    STUB_SELF_SIGNALS=""
    STUB_TIMEOUT_ON=""
    STUB_RUNNING="$STUB_READY_SERVICES"
    STUB_PS_RC=0
    STUB_STOP_RC=0
    STUB_INSPECT_FAIL=""
    STUB_INSPECT_RC=1
    STUB_DB_IMAGE="$DB_IMAGE"
    STUB_IMAGE_LABELS="$DB_IMAGE_LABELS"
    STUB_CREATE_RC=0
    STUB_RM_RC=0
    STUB_RESPAWN=""
    STUB_ENV_SIGNAL_PID=""
    STUB_DB_CID="db0000000001"
    STUB_CREATE_PRINTS=""
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

# docker: `docker compose version` succeeds. Every other call is recorded in docker.calls.
# inspect, image inspect, create and rm are answered by stub_inspect, stub_image_inspect,
# stub_create and stub_rm. Any other call must be `compose -p P -f F <command> ...`: exec writes
# the MSYS_NO_PATHCONV value it ran with and its arguments, one per line, to exec.args and
# answers STUB_EXEC_OUT, STUB_EXEC_ERR and STUB_EXEC_RC; logs of reverse-proxy print proxy.log,
# the project's reverse-proxy log; the Nth other logs call prints logs.N, capped at
# STUB_LOG_POLLS, and exits STUB_LOGS_RC; start exits STUB_START_RC and stop STUB_STOP_RC;
# `ps --status running --services` lists the words of STUB_RUNNING, the running services, one
# per line, none when it is empty, and exits STUB_PS_RC, printing none when that is not 0; and
# `ps -q [--status running] SERVICE` prints SERVICE's container id (stub_cid), unless that is
# empty, when SERVICE is among them. Any other ps is an unexpected compose command.
docker() {
    local calls=() n line service
    if [[ "$*" == "compose version" ]]; then
        return 0
    fi
    printf '%s\n' "$*" >>"$STUB/docker.calls"
    case "$1" in
        inspect)
            stub_inspect "$@"
            return
            ;;
        image)
            stub_image_inspect "$@"
            return
            ;;
        create)
            stub_create "$@"
            return
            ;;
        rm)
            stub_rm "$@"
            return
            ;;
    esac
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
            if [[ "${!#}" == reverse-proxy ]]; then
                while IFS= read -r line; do
                    printf '%s\n' "$line"
                done <"$STUB/proxy.log"
                return 0
            fi
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
        ps)
            if [[ "${*:7}" == "--status running --services" ]]; then
                if [[ $STUB_PS_RC -ne 0 ]]; then
                    echo "docker stub: services query failed" >&2
                    return "$STUB_PS_RC"
                fi
                for service in $STUB_RUNNING; do
                    echo "$service"
                done
            elif [[ $# -eq 8 && "$7" == "-q" ]] ||
                [[ $# -eq 10 && "${*:7:3}" == "-q --status running" ]]; then
                if [[ " $STUB_RUNNING " == *" ${!#} "* ]]; then
                    stub_cid "${!#}"
                    if [[ -n "$REPLY" ]]; then
                        echo "$REPLY"
                    fi
                fi
            else
                echo "docker stub: unexpected compose command: $*" >&2
                return 97
            fi
            return 0
            ;;
        start)
            return "$STUB_START_RC"
            ;;
        stop)
            return "$STUB_STOP_RC"
            ;;
        *)
            echo "docker stub: unexpected compose command: $*" >&2
            return 97
            ;;
    esac
}

# stub_cid SERVICE: sets REPLY to the synthetic container id of SERVICE's container; the db
# container's is STUB_DB_CID.
stub_cid() {
    case "$1" in
        db) REPLY="$STUB_DB_CID" ;;
        db-adapter) REPLY="ada000000001" ;;
        broker-service) REPLY="b0c000000001" ;;
        *) REPLY="eee000000001" ;;
    esac
}

# stub_print FILE: prints FILE's lines.
stub_print() {
    local line
    while IFS= read -r line; do
        printf '%s\n' "$line"
    done <"$1"
}

# stub_inspect inspect [--type container] --format FORMAT TARGET: with {{.Image}}, the db
# container's image STUB_DB_IMAGE; with {{json .Config.Env}}, a container's environment, the
# file env.TARGET, else [], except that the read of the container of the service
# STUB_INSPECT_FAIL names fails with STUB_INSPECT_RC, 124 or 137 standing for a call its limit
# cut off; with {{json .}}, the lock container's JSON, lock.json, when TARGET is its name.
# Anything else is an unknown object. While the db-adapter environment is read,
# STUB_ENV_SIGNAL_PID, when set, gets SIGTERM.
stub_inspect() {
    local format="" previous="" arg target="${!#}"
    for arg in "$@"; do
        if [[ "$previous" == "--format" ]]; then
            format="$arg"
        fi
        previous="$arg"
    done
    stub_cid db
    if [[ "$format" == '{{.Image}}' && "$target" == "$REPLY" ]]; then
        echo "$STUB_DB_IMAGE"
        return 0
    fi
    if [[ "$format" == '{{json .Config.Env}}' ]]; then
        if [[ -n "$STUB_INSPECT_FAIL" ]]; then
            stub_cid "$STUB_INSPECT_FAIL"
            if [[ "$target" == "$REPLY" ]]; then
                echo "docker stub: inspect of $target failed" >&2
                return "$STUB_INSPECT_RC"
            fi
        fi
        stub_cid db-adapter
        if [[ -n "$STUB_ENV_SIGNAL_PID" && "$target" == "$REPLY" ]]; then
            kill -TERM "$STUB_ENV_SIGNAL_PID"
        fi
        if [[ -f "$STUB/env.$target" ]]; then
            stub_print "$STUB/env.$target"
        else
            echo "[]"
        fi
        return 0
    fi
    if [[ "$format" == '{{json .}}' && "$target" == "$LOCK_CONTAINER" && -f "$STUB/lock.json" ]]; then
        stub_print "$STUB/lock.json"
        return 0
    fi
    echo "Error response from daemon: No such container: $target" >&2
    return 1
}

# stub_image_inspect image inspect --format {{json .Config.Labels}} IMAGE: STUB_IMAGE_LABELS for
# the db image.
stub_image_inspect() {
    if [[ "$2" != "inspect" || "${!#}" != "$STUB_DB_IMAGE" ]]; then
        echo "Error response from daemon: No such image: ${!#}" >&2
        return 1
    fi
    echo "$STUB_IMAGE_LABELS"
}

# stub_lock ID IMAGE_LABELS [KEY=VALUE]...: puts the lock container ID in place: lock.id holds
# its id and lock.json its inspect JSON, whose labels are IMAGE_LABELS (JSON) overlaid with the
# KEY=VALUE ones, as a container's labels overlay its image's. The values reach jq unchanged, as
# they reach docker from perf.sh: Git Bash would rewrite a run directory into a Windows path.
stub_lock() {
    local id="$1" image="$2"
    shift 2
    echo "$id" >"$STUB/lock.id"
    MSYS_NO_PATHCONV=1 jq -cn --arg id "$id" --argjson image "$image" \
        '{Id: $id, Config: {Labels: (($image // {}) + ($ARGS.positional
            | map(capture("\\A(?<key>[^=]*)=(?<value>.*)\\z"; "p")) | from_entries))}}' \
        --args "$@" >"$STUB/lock.json"
}

# stub_create create --name NAME [--label KEY=VALUE]... IMAGE: makes the lock container from the
# db image, labelled as given over STUB_IMAGE_LABELS, and prints its id, or STUB_CREATE_PRINTS
# when that is set. It fails with STUB_CREATE_RC, making nothing, when that is set, and as a
# name conflict while a lock exists.
stub_create() {
    local name="" labels=() n id
    shift
    while [[ $# -gt 1 ]]; do
        case "$1" in
            --name)
                name="$2"
                shift 2
                ;;
            --label)
                labels+=("$2")
                shift 2
                ;;
            *)
                echo "docker stub: unexpected create option: $1" >&2
                return 97
                ;;
        esac
    done
    if [[ "$name" != "$LOCK_CONTAINER" || "${1:-}" != "$STUB_DB_IMAGE" ]]; then
        echo "docker stub: unexpected create of [$name] from [${1:-}]" >&2
        return 97
    fi
    if [[ "$STUB_CREATE_RC" -ne 0 ]]; then
        echo "Error response from daemon: create failed" >&2
        return "$STUB_CREATE_RC"
    fi
    if [[ -f "$STUB/lock.id" ]]; then
        echo "Error response from daemon: Conflict. The container name \"/$name\" is already in use by container \"$(<"$STUB/lock.id")\"." >&2
        return 1
    fi
    n=$(($(<"$STUB/lock.count") + 1))
    echo "$n" >"$STUB/lock.count"
    printf -v id 'c0ffee%058d' "$n"
    stub_lock "$id" "$STUB_IMAGE_LABELS" "${labels[@]}"
    echo "${STUB_CREATE_PRINTS:-$id}"
}

# stub_rm rm -v ID: removes the lock container only when ID is its id, and otherwise fails as
# Docker does for an id it does not know; STUB_RM_RC fails it first. With STUB_RESPAWN set to
# "PID HOST", another run takes the lock as soon as the removal frees its name.
stub_rm() {
    if [[ $# -ne 3 || "$2" != "-v" ]]; then
        echo "docker stub: unexpected rm: $*" >&2
        return 97
    fi
    if [[ "$STUB_RM_RC" -ne 0 ]]; then
        echo "Error response from daemon: removal failed" >&2
        return "$STUB_RM_RC"
    fi
    if [[ ! -f "$STUB/lock.id" || "$(<"$STUB/lock.id")" != "$3" ]]; then
        echo "Error response from daemon: No such container: $3" >&2
        return 1
    fi
    rm -f "$STUB/lock.id" "$STUB/lock.json"
    if [[ -n "$STUB_RESPAWN" ]]; then
        stub_lock "$RESPAWN_ID" null "pi-perf.lock.pid=${STUB_RESPAWN%% *}" \
            "pi-perf.lock.host=${STUB_RESPAWN#* }" "pi-perf.lock.started=2026-01-01T00:00:05Z" \
            "pi-perf.lock.run-dir=$TEST_TMP/respawned-run"
    fi
}

# timeout: stands in for timeout(1), under which perf.sh's hard_timeout runs every Docker call,
# the compose plugin check of check_tools and the run lock's calls included. The program
# timeout(1) would exec is the program file on PATH, never the docker function; this one appends
# its options and limit ("-k GRACE LIMIT" or "-s SIGNAL LIMIT") as one line to timeouts and runs
# the rest of its arguments in this shell, so the docker stub answers. It exits with that
# status, or with STUB_TIMEOUT_RC when that is set: the limit cut the call off, as timeout(1)
# reports it with 124 after TERM and 137 after KILL. With STUB_TIMEOUT_ON set, only a call that
# has that word among its arguments is cut off.
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
    if [[ -n "$STUB_TIMEOUT_RC" ]] && [[ -z "$STUB_TIMEOUT_ON" || " $* " == *" $STUB_TIMEOUT_ON "* ]]; then
        return "$STUB_TIMEOUT_RC"
    fi
    return "$rc"
}

# curl: records "METHOD URL[ BODY]" in requests and answers the Nth request with line N of
# responses, "RC<TAB>STATUS<TAB>PAYLOAD". RC 0 writes PAYLOAD as the body and prints the record
# -w '%{http_code} %{exitcode} %{content_type}' prints, "STATUS 0 application/json". RC 1 to 127
# prints PAYLOAD as curl's error and the record "STATUS RC " of a failed transfer, and fails with
# RC. RC 128 and above is a curl killed by a signal, which prints nothing. A request without a
# queued answer fails as a transport error. A target-check probe it answers with RC 0 adds its
# access line, with STATUS, to STUB_SERVED_LOG, as nginx logs it. STUB_CURL_MODE "interrupted"
# prints the record of a finished transfer but ends with 130, as the command substitution does
# under Git Bash when an interrupt arrives while curl runs; "no-exitcode" leaves the record's
# exit field empty, as a curl older than 7.75 writes it; "no-record" prints no record and ends
# with 0. With STUB_SIGNAL_PID set, that process gets SIGTERM while the request is in flight.
# Before it answers, curl's own shell gets each signal STUB_SELF_SIGNALS names, in order, as a
# signal to the process group delivers it. A POST also appends the lines
# $RUN_DIR/in-flight-create holds while it is in flight to in-flight.seen. Each request's
# --max-time value goes, one per line, to max-times.
curl() {
    local method="GET" body_file="" data="" url="" sent=() answers=() response rc status payload exit_field signal
    local max_time=""
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
            --max-time)
                max_time="$2"
                shift 2
                ;;
            -D | -H | -w)
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
    echo "$max_time" >>"$STUB/max-times"
    if [[ "$method" == "POST" && -f "$RUN_DIR/in-flight-create" ]]; then
        stub_print "$RUN_DIR/in-flight-create" >>"$STUB/in-flight.seen"
    fi
    if [[ -n "$STUB_SIGNAL_PID" ]]; then
        kill -TERM "$STUB_SIGNAL_PID"
    fi
    for signal in $STUB_SELF_SIGNALS; do
        kill -"$signal" "$BASHPID"
    done
    mapfile -t sent <"$STUB/requests"
    mapfile -t answers <"$STUB/responses"
    response="${answers[${#sent[@]} - 1]:-}"
    if [[ -z "$response" ]]; then
        echo "curl: (7) no answer queued for request ${#sent[@]}" >&2
        printf '000 7 '
        return 7
    fi
    IFS=$'\t' read -r rc status payload <<<"$response"
    if [[ "$rc" -ge 128 ]]; then
        return "$rc"
    fi
    exit_field="$rc"
    if [[ "$STUB_CURL_MODE" == "no-exitcode" ]]; then
        exit_field=""
    fi
    if [[ "$rc" != "0" ]]; then
        echo "$payload" >&2
        printf '%s %s ' "$status" "$exit_field"
        return "$rc"
    fi
    printf '%s' "$payload" >"$body_file"
    if [[ "$url" == *"?pi-target="* ]]; then
        printf '172.23.0.1 - [01/Jan/2026:00:00:00 +0000] "GET %s HTTP/1.1" %s 7 "-" "curl/8.21.0"\n' \
            "${url#http://localhost}" "$status" >>"$STUB_SERVED_LOG"
    fi
    case "$STUB_CURL_MODE" in
        no-record)
            return 0
            ;;
        interrupted)
            printf '%s 0 application/json' "$status"
            return 130
            ;;
    esac
    printf '%s %s application/json' "$status" "$exit_field"
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

# Loads perf.sh and sets up the state main sets before its traps: perf.sh's own parse_options,
# check_tools and prepare_run read the fixture's options, check the stubbed tools and make a run
# directory under TMPDIR. Sourced, perf.sh does not call main, so it sets no trap and runs no
# step. Every assignment perf.sh makes at its top level or in those functions is global, so
# loading it from a function defines the same state as loading it here.
load_perf() {
    # shellcheck source-path=SCRIPTDIR source=perf.sh
    source "$PERF_SH"
    parse_options --project unit-test --compose-file compose.dev.yaml
    check_tools
    prepare_run
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

# od: the 16 random bytes of the target check, fixed so that its probe URLs are known; any other
# use of od runs the real one.
PROBE_NONCE="0f1e2d3c4b5a69788796a5b4c3d2e1f0"
od() {
    if [[ "$*" == "-An -N16 -tx1 /dev/urandom" ]]; then
        echo " 0f 1e 2d 3c 4b 5a 69 78 87 96 a5 b4 c3 d2 e1 f0"
        return 0
    fi
    command od "$@"
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
    rm -rf "$RUN_DIR/unknown-creates" "$RUN_DIR/unknown-resolved" "$RUN_DIR/candidates" \
        "$RUN_DIR/recovered" "$RUN_DIR"/adopt.* "$RUN_DIR/precondition-at" \
        "$RUN_DIR/carried-creates" "$RUN_DIR/carried-resolved" "$RUN_DIR/in-flight-create"
    PRECONDITION_AT=""
    CARRIED_SETTLE_UNTIL=0
    rm -rf "$STATE_DIR" "$TEST_TMP/earlier"
    LOCK_HELD=0
    LOCK_ID=""
    RUNNING_SERVICES=""
    RUN_RECORD=""
    REPORT_PRINTED=0
    STARTED_AT="2026-01-01T00:00:00Z"
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
    ARMED_ERROR=""
    OWNED_ERROR=""
    REARM_ERROR=""
    CREATE_ERROR=""
    LOG_SINCE="2026-01-01T00:00:00Z"
    WINDOW_READ_HELD=0
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
    command_row "-h" 0 out "  -h, --help           Show this help and exit" -h
    command_row "--help examples" 0 out \
        $'Examples:\n  scripts/portfolio-insights/perf.sh --project pi-dev-postgres\n' --help
    command_row "--help exit statuses" 0 out \
        $'Exit: 0 all passed, 1 a check failed, 2 bad usage, missing tool, no run dir or closed stdout,\n130 interrupted.' --help
    command_row "no arguments" 2 err "Option --project is required."
    command_row "unknown option" 2 err "Unknown option: --bogus" --project unit-test --bogus
    command_row "--project without a value" 2 err "Option --project requires a value." --project
    command_row "--compose-file followed by an option" 2 err "Option --compose-file requires a value." \
        --project unit-test --compose-file --base-url http://localhost
    command_row "ftp base URL" 2 err "Option --base-url" --project unit-test --base-url ftp://localhost
    command_row "missing compose file" 2 err "Compose file not found: no-such-compose.yaml" \
        --project unit-test --compose-file no-such-compose.yaml
    command_row "project with upper case" 2 err "Option --project needs a Compose project name" \
        --project Unit-Test
    command_row "project starting with an underscore" 2 err "Option --project needs a Compose project name" \
        --project _unit
    command_row "project with a path" 2 err "Option --project needs a Compose project name" --project ../unit
}

# Run directly, perf.sh calls main, whose first step, setup's run lock, asks docker for the
# project's running db container. The stub lists no running service, so the lock cannot be
# made: readiness fails, naming every required service, cleanup runs and the run ends with its
# SUMMARY and status 1, with nothing reached outside the stubs.
executed_case() {
    local status=0 calls=() out=()
    (
        STUB_RUNNING=""
        export STUB_EXEC_OUT STUB_EXEC_ERR STUB_EXEC_RC STUB_LOGS_RC STUB_LOG_POLLS \
            STUB_START_RC STUB_SIGNAL_PID STUB_TIMEOUT_RC STUB_CURL_MODE STUB_SELF_SIGNALS \
            STUB_TIMEOUT_ON STUB_RUNNING STUB_PS_RC STUB_STOP_RC STUB_INSPECT_FAIL STUB_INSPECT_RC \
            STUB_SERVED_LOG STUB_DB_IMAGE STUB_CREATE_RC STUB_RM_RC STUB_RESPAWN \
            STUB_ENV_SIGNAL_PID STUB_DB_CID STUB_CREATE_PRINTS LOCK_CONTAINER RESPAWN_ID
        export -f docker curl timeout od stub_cid stub_print stub_inspect stub_image_inspect stub_lock \
            stub_create stub_rm
        "$BASH" "$PERF_SH" --project unit-test --compose-file compose.dev.yaml
    ) >"$RUN_DIR/child.out" 2>"$RUN_DIR/child.err" </dev/null || status=$?
    mapfile -t calls <"$STUB/docker.calls"
    mapfile -t out <"$RUN_DIR/child.out"
    expect "exit status" 1 "$status"
    expect "docker calls" "$COMPOSE_PREFIX ps -q --status running db|$COMPOSE_PREFIX ps --status running --services|" \
        "${calls[0]:-}|${calls[1]:-}|${calls[2]:-}"
    exit_lines "$RUN_DIR/child.out"
    expect "verdicts" \
        "FAIL readiness: services not running in project [unit-test]: $STUB_READY_SERVICES|PASS cleanup|SUMMARY 1 passed, 1 failed|" \
        "$REPLY"
    if [[ "${out[${#out[@]} - 1]:-}" != "SUMMARY "* ]]; then
        case_reasons+=("last line [${out[${#out[@]} - 1]:-}] is not a SUMMARY")
    fi
}

# sourced_row ROW CALLER_ARGS SOURCE_ARGS: sources perf.sh with the words of SOURCE_ARGS in a
# subshell whose positional parameters are the words of CALLER_ARGS. That subshell has no trap,
# none of perf.sh's option, URL, state directory and lock name variables, a TMPDIR of its own,
# and docker and curl functions that only record their calls. Sourcing must return 0 and print
# nothing, and leave the positional parameters, the traps, those variables, RUN_DIR and TMPDIR
# as they were, with no docker or curl call.
sourced_row() {
    local row="$1" caller=() sourced=() status=0
    local source_tmp="$RUN_DIR/sourced-tmp" call_log="$RUN_DIR/sourced.calls"
    local report="$RUN_DIR/sourced.report"
    read -ra caller <<<"$2"
    read -ra sourced <<<"$3"
    rm -rf "$source_tmp" "$report"
    mkdir "$source_tmp"
    : >"$call_log"
    (
        trap - EXIT INT TERM
        unset BASE_URL COMPOSE_FILE PROJECT COMPOSE_PATH FLAG_URL ALERTS_URL INSIGHTS_URL \
            STATE_DIR LOCK_NAME
        # shellcheck disable=SC2329 # Called only when sourcing perf.sh runs its code.
        docker() {
            echo "docker $*" >>"$call_log"
            return 1
        }
        # shellcheck disable=SC2329 # Called only when sourcing perf.sh runs its code.
        curl() {
            echo "curl $*" >>"$call_log"
            return 7
        }
        export TMPDIR="$source_tmp"
        set -- "${caller[@]}"
        sourced_status=0
        # shellcheck source=/dev/null # The linter reads perf.sh through load_perf.
        source "$PERF_SH" "${sourced[@]}" || sourced_status=$?
        set_names=""
        for name in BASE_URL COMPOSE_FILE PROJECT COMPOSE_PATH FLAG_URL ALERTS_URL INSIGHTS_URL \
            STATE_DIR LOCK_NAME; do
            if [[ -v "$name" ]]; then
                set_names="$set_names $name"
            fi
        done
        {
            echo "status $sourced_status"
            echo "positional parameters [$*]"
            echo "traps [$(trap -p EXIT INT TERM)]"
            echo "variables set [${set_names# }]"
            echo "run dir [$RUN_DIR]"
        } >"$report"
    ) >"$RUN_DIR/child.out" 2>"$RUN_DIR/child.err" </dev/null || status=$?
    expect "$row: subshell status" 0 "$status"
    expect_file "$row: state after sourcing" "$report" "status 0" "positional parameters [$2]" \
        "traps []" "variables set []" "run dir [$RUN_DIR]"
    slurp "$RUN_DIR/child.out"
    expect "$row: stdout" "" "$REPLY"
    slurp "$RUN_DIR/child.err"
    expect "$row: stderr" "" "$REPLY"
    slurp "$call_log"
    expect "$row: docker and curl calls" "" "$REPLY"
    expect "$row: entries made under TMPDIR" "" "$(compgen -G "$source_tmp/*" || true)"
}

# Sourced, perf.sh only defines its functions and constants: it reads neither the arguments
# given to source nor the caller's own positional parameters, and consumes neither.
sourced_case() {
    sourced_row "arguments to source" "caller-1 caller-2" "--project x --bogus"
    sourced_row "the caller's arguments" "--project x --bogus" ""
}

# capture_exit COMMAND...: runs COMMAND in a subshell, since it may exit, with its output in
# child.out and child.err, and sets OUTCOME to "rc=STATUS" followed by its stderr, if any.
capture_exit() {
    local rc=0
    ("$@") >"$RUN_DIR/child.out" 2>"$RUN_DIR/child.err" </dev/null || rc=$?
    slurp "$RUN_DIR/child.err"
    OUTCOME="rc=$rc${REPLY:+ $REPLY}"
}

# without_programs COMMAND...: runs COMMAND with a PATH that names no directory, so of the
# tools check_tools looks for only the docker, curl and timeout functions are found.
without_programs() {
    local PATH="$TEST_TMP/no-such-directory"
    "$@"
}

# compose_plugin_failing COMMAND...: runs COMMAND with a docker that fails every call, as
# docker compose version fails without the plugin. Call it only through capture_exit, whose
# subshell keeps the stub docker of every other case.
compose_plugin_failing() {
    # shellcheck disable=SC2329 # Called by check_tools, which COMMAND runs.
    docker() {
        return 1
    }
    "$@"
}

check_tools_case() {
    capture_exit check_tools
    expect "every tool found" "rc=0" "$OUTCOME"
    capture_exit without_programs check_tools
    expect "bash and jq not on PATH" "rc=2 Missing required tools: bash jq" "$OUTCOME"
    capture_exit compose_plugin_failing check_tools
    expect "compose plugin failing" \
        "rc=2 The docker compose plugin is required (docker compose version failed)." "$OUTCOME"
}

# with_tmpdir DIR COMMAND...: runs COMMAND with TMPDIR set to DIR.
with_tmpdir() {
    local TMPDIR="$1"
    shift
    "$@"
}

# prepared_run: prepare_run, then prints the run directory, the three request URLs, the state
# directory, the lock name, whether the state directory exists, and one "NAME empty" or
# "NAME not empty" line per entry of the run directory.
prepared_run() {
    local entry
    prepare_run
    printf '%s\n' "$RUN_DIR" "$FLAG_URL" "$ALERTS_URL" "$INSIGHTS_URL" "$STATE_DIR" "$LOCK_NAME"
    if [[ -e "$STATE_DIR" ]]; then
        echo "state directory made"
    else
        echo "state directory not made"
    fi
    for entry in "$RUN_DIR"/*; do
        if [[ -s "$entry" ]]; then
            echo "${entry##*/} not empty"
        else
            echo "${entry##*/} empty"
        fi
    done
}

prepare_run_case() {
    local tmp="$RUN_DIR/prepare-tmp" missing="$RUN_DIR/no-such-tmp" lines=() got
    rm -rf "$tmp"
    mkdir "$tmp"
    capture_exit with_tmpdir "$tmp" prepared_run
    expect "TMPDIR that exists: status and stderr" "rc=0" "$OUTCOME"
    mapfile -t lines <"$RUN_DIR/child.out"
    if [[ ! "${lines[0]:-}" =~ ^"$tmp"/pi-perf\.[[:alnum:]]{6}$ ]]; then
        case_reasons+=("TMPDIR that exists: run directory [${lines[0]:-}] is not $tmp/pi-perf.XXXXXX")
    fi
    joined "${lines[@]:1}"
    got="$REPLY"
    joined "$FLAG_ENDPOINT" "$ALERTS_ENDPOINT" "http://localhost/broker-service/v1/portfolio/insights" \
        "$tmp/pi-perf-state.unit-test" "$LOCK_CONTAINER" "state directory not made" \
        "deleted empty" "expected empty" "owned empty"
    expect "TMPDIR that exists: URLs, state directory, lock name and run directory entries" \
        "$REPLY" "$got"
    capture_exit with_tmpdir "$missing" prepare_run
    if [[ "$OUTCOME" != "rc=2 "* || "$OUTCOME" != *"Could not create a run directory under $missing." ]]; then
        case_reasons+=("TMPDIR that does not exist: expected status 2 naming it, got [$OUTCOME]")
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
    wait_cycle_line 2 "$((SECONDS + 60))" >"$TEST_OUT" || rc=$?
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
    wait_cycle_line 0 "$((SECONDS + 60))" 1000 >"$TEST_OUT" || rc=$?
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
    wait_cycle_line "$after" "$((SECONDS + 10))" "$wanted" >"$TEST_OUT" || rc=$?
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

# held_row ROW HELD EXPECTED: a 10 s wait over 1000 alerts while broker.log holds the window read
# open_verified_window made (WINDOW_READ_HELD 1), the cleaned line HELD, and the first logs call
# would print a clean 900 ms cycle. EXPECTED is the status, the line found, the logs calls, the
# seconds slept and the hold left: the held read is parsed before any logs call, and is used up.
held_row() {
    local rc=0 polls c900
    fresh_state
    cycle_text 1000 0 0 0 completed 900
    c900="$REPLY"
    log_poll 1 "$c900"
    printf '%s\n' "$2" >"$RUN_DIR/broker.log"
    WINDOW_READ_HELD=1
    wait_cycle_line 0 "$((SECONDS + 10))" 1000 >"$TEST_OUT" || rc=$?
    count_lines "$STUB/logs.calls"
    polls="$REPLY"
    expect "$1" "$3" "rc=$rc line=$CYCLE_LINE polls=$polls elapsed=$SECONDS held=$WINDOW_READ_HELD"
}

wait_held_read_case() {
    local c812 c900
    cycle_text 1000 0 0 0 completed 812
    c812="$REPLY"
    cycle_text 1000 0 0 0 completed 900
    c900="$REPLY"
    held_row "qualifying line in the held read" "$c812" "rc=0 line=$c812 polls=0 elapsed=0 held=0"
    held_row "no cycle line in the held read" "$INSIGHTS_TEXT" "rc=0 line=$c900 polls=1 elapsed=5 held=0"
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

# Each client gets a 15 s login and a 30 s query timeout of its own, and the exec the 60 s call
# limit: TERM at 55 s, KILL at 60 s. sqlcmd, which does not exit after its query timeout, is
# killed in the container at 50 s, and that kill is reported as its failure, status 1.
db_query_case() {
    DIALECT=mssql
    db_query "SELECT 1" >"$TEST_OUT" || true
    # shellcheck disable=SC2016 # $SA_PASSWORD, $1 and $rc are expanded by the container's shell.
    expect_file "mssql" "$STUB/exec.args" MSYS_NO_PATHCONV=1 "${COMPOSE_ARGS[@]}" exec -T db sh -c \
        'timeout -s KILL 50 /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -d TradeManagement -l 15 -t 30 -b -h -1 -W -Q "$1"; rc=$?; if [ "$rc" -eq 137 ]; then echo "sqlcmd had not exited 50 s after it started" >&2; rc=1; fi; exit "$rc"' \
        sh "SET NOCOUNT ON; SELECT 1"
    expect_file "mssql limit" "$STUB/timeouts" "-k 5 55"
    : >"$STUB/timeouts"
    DIALECT=postgres
    db_query "SELECT 1" >"$TEST_OUT" || true
    expect_file "postgres" "$STUB/exec.args" MSYS_NO_PATHCONV=1 "${COMPOSE_ARGS[@]}" exec -T db psql \
        -v ON_ERROR_STOP=1 -U postgres \
        -d "dbname=TradeManagement connect_timeout=15 options='-c statement_timeout=30000'" \
        -At -F , -c "SELECT 1"
    expect_file "postgres limit" "$STUB/timeouts" "-k 5 55"
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
    # The clients' own login and query timeouts are client errors, told apart from a cut-off call.
    client_failure_row "sqlcmd query timeout" mssql 1 "" \
        "Sqlcmd: Error: Microsoft ODBC Driver 17 for SQL Server : Query timeout expired."
    client_failure_row "psql statement timeout" postgres 1 "" \
        "ERROR:  canceling statement due to statement timeout"
}

# A query whose call the limit cut off, 124 after TERM or 137 after KILL, fails as one Docker did
# not answer, never as a client error, even after a complete-looking answer.
read_armed_cut_off_case() {
    local dialect rc
    for rc in 124 137; do
        for dialect in mssql postgres; do
            time_row "$dialect"
            client_answer "$dialect" "$REPLY"
            STUB_TIMEOUT_RC="$rc"
            armed_failure_row "$dialect cut off with $rc" "$dialect" 0 "$REPLY" "" \
                "armed-set query timed out after 60 s (Docker did not answer)"
            expect "$dialect cut off with $rc: ARMED_ERROR" \
                "armed-set query timed out after 60 s (Docker did not answer)" "$ARMED_ERROR"
            STUB_TIMEOUT_RC=""
        done
    done
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
    local b
    alert_id 2
    b="$REPLY"
    rearm_failure_row "alert gone" 0 404 '{"error":"not_found"}' "status 404"
    rearm_failure_row "200 without an id" 0 200 '{"enabled":true,"armingRevision":2}' \
        "status 200, but its id is not the patched alert's"
    rearm_failure_row "200 for another alert" 0 200 "{\"id\":\"$ALERT_ID\",\"enabled\":true,\"armingRevision\":2}" \
        "status 200, but its id is not the patched alert's"
    rearm_failure_row "200 still disabled" 0 200 "{\"id\":\"$b\",\"enabled\":false,\"armingRevision\":2}" \
        "status 200, but its enabled is not true"
    rearm_failure_row "200 with enabled as a string" 0 200 "{\"id\":\"$b\",\"enabled\":\"true\",\"armingRevision\":2}" \
        "status 200, but its enabled is not true"
    rearm_failure_row "200 without a revision" 0 200 "{\"id\":\"$b\",\"enabled\":true}" \
        "status 200, but its armingRevision is not a JSON integer of at least 1"
    rearm_failure_row "200 with the revision as a string" 0 200 "{\"id\":\"$b\",\"enabled\":true,\"armingRevision\":\"2\"}" \
        "status 200, but its armingRevision is not a JSON integer of at least 1"
    rearm_failure_row "200 with a fractional revision" 0 200 "{\"id\":\"$b\",\"enabled\":true,\"armingRevision\":2.5}" \
        "status 200, but its armingRevision is not a JSON integer of at least 1"
    rearm_failure_row "200 that is not JSON" 0 200 "<html>$b</html>" \
        "status 200, but its reply is not one JSON object"
    rearm_failure_row "transport error" 7 000 "$CONNECT_ERROR" "transport error ($CONNECT_ERROR)"
}

# ---------------------------------------------------------------------------------------------
# Alert creation

# post_row THRESHOLD: post_alert for the fixture account and instrument on a fresh state; sets
# POST_RC, POST_OWNED, POST_EXPECTED and POST_UNKNOWN, the unknown creates it recorded.
post_row() {
    POST_RC=0
    post_alert "$ACCOUNT_ID" TARGET_PRICE "$INSTRUMENT_ID" ABOVE "$1" || POST_RC=$?
    slurp "$RUN_DIR/owned"
    POST_OWNED="$REPLY"
    slurp "$RUN_DIR/expected"
    POST_EXPECTED="$REPLY"
    POST_UNKNOWN=""
    if [[ -f "$RUN_DIR/unknown-creates" ]]; then
        slurp "$RUN_DIR/unknown-creates"
        POST_UNKNOWN="$REPLY"
    fi
}

# expect_post ROW RC OWNED EXPECTED ERROR [UNKNOWN]: the outcome of the last post_row; UNKNOWN
# is the unknown-create record it must have written, none when omitted.
expect_post() {
    expect "$1" "rc=$2 owned=[$3] expected=[$4] error=[$5] unknown=[${6:-}]" \
        "rc=$POST_RC owned=[$POST_OWNED] expected=[$POST_EXPECTED] error=[$CREATE_ERROR] unknown=[$POST_UNKNOWN]"
}

# The note of a create whose outcome is unknown, and the record post_row's create leaves for
# cleanup when its POST ends at 42 s.
UNKNOWN_NOTE="the alert may exist without an id this run knows; cleanup looks for it among the account's alerts"
printf -v UNKNOWN_RECORD '42\t%s\tTARGET_PRICE\t%s\tABOVE\t1.5' "$ACCOUNT_ID" "$INSTRUMENT_ID"

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
        respond 0 201 "{\"id\":\"$ALERT_ID\",\"enabled\":true,\"armingRevision\":1}"
        post_row "$threshold"
        expect_file "[$threshold]" "$STUB/requests" \
            "POST $ALERTS_ENDPOINT {\"accountId\":\"$ACCOUNT_ID\",\"type\":\"TARGET_PRICE\",\"instrumentId\":\"$INSTRUMENT_ID\",\"direction\":\"ABOVE\",\"threshold\":$threshold}"
    done
}

# transport_row ROW CURL_RC MESSAGE: the POST, ending at 42 s, fails with CURL_RC; the create
# is recorded as unknown.
transport_row() {
    fresh_state
    SECONDS=42
    respond "$2" 000 "$3"
    post_row 1.5
    expect_post "$1" 1 "" "" "transport error ($3); $UNKNOWN_NOTE" "$UNKNOWN_RECORD"
}

post_transport_case() {
    transport_row "connection refused" 7 \
        "curl: (7) Failed to connect to localhost port 80 after 0 ms: Could not connect to server"
    transport_row "timeout" 28 \
        "curl: (28) Operation timed out after 15000 milliseconds with 0 bytes received"
    fresh_state
    SECONDS=42
    respond 143 000 ""
    post_row 1.5
    expect_post "curl killed by TERM" 1 "" "" "transport error (no response); $UNKNOWN_NOTE" "$UNKNOWN_RECORD"
}

# A 4xx refuses the create, so nothing is recorded; after a 5xx or another 2xx the alert may
# exist, so the create is recorded as unknown.
post_status_case() {
    local status
    for status in 400 403 404; do
        fresh_state
        respond 0 "$status" '{"error":"rejected"}'
        post_row 1.5
        expect_post "$status" 1 "" "" "status $status"
    done
    for status in 200 500 502 503 504; do
        fresh_state
        SECONDS=42
        respond 0 "$status" '{"error":"unavailable"}'
        post_row 1.5
        expect_post "$status" 1 "" "" "status $status; $UNKNOWN_NOTE" "$UNKNOWN_RECORD"
    done
}

post_no_id_case() {
    local body
    for body in '{}' '{"id":"not-a-uuid","armingRevision":1}' \
        '{"id":"d0000000-0000-4000-8000-0000000000a","armingRevision":1}' 'not json' '' \
        '{"id":12,"armingRevision":1}' '[{"id":"d0000000-0000-4000-8000-0000000000ab","armingRevision":1}]' \
        '{"id":"d0000000-0000-4000-8000-0000000000ab","armingRevision":1}{"id":"d0000000-0000-4000-8000-0000000000ac","armingRevision":1}'; do
        fresh_state
        SECONDS=42
        respond 0 201 "$body"
        post_row 1.5
        expect_post "[$body]" 1 "" "" "201 without a readable id; $UNKNOWN_NOTE" "$UNKNOWN_RECORD"
    done
}

# A receipt that shows the alert enabled at any revision but 1 is refused once its id is owned,
# so cleanup deletes the alert and the expected set stays at revision 1.
post_no_revision_case() {
    local body
    for body in '{"id":"D0000000-0000-4000-8000-0000000000AB","enabled":true}' \
        '{"id":"d0000000-0000-4000-8000-0000000000ab","enabled":true,"armingRevision":null}' \
        '{"id":"d0000000-0000-4000-8000-0000000000ab","enabled":true,"armingRevision":"x"}' \
        '{"id":"d0000000-0000-4000-8000-0000000000ab","enabled":true,"armingRevision":1.5}' \
        '{"id":"d0000000-0000-4000-8000-0000000000ab","enabled":true,"armingRevision":"1"}' \
        '{"id":"d0000000-0000-4000-8000-0000000000ab","enabled":true,"armingRevision":0}' \
        '{"id":"d0000000-0000-4000-8000-0000000000ab","enabled":true,"armingRevision":1.0}' \
        '{"id":"d0000000-0000-4000-8000-0000000000ab","enabled":true,"armingRevision":2}' \
        '{"id":"d0000000-0000-4000-8000-0000000000ab","enabled":true,"armingRevision":2147483647}'; do
        fresh_state
        respond 0 201 "$body"
        post_row 1.5
        expect_post "[$body]" 1 "$ALERT_ID" "" "201 for alert [$ALERT_ID] whose armingRevision is not the JSON integer 1"
    done
}

# A receipt whose enabled is not the JSON boolean true is refused once its id is owned, whatever
# its revision, with a reason that does not repeat the reply.
post_not_enabled_case() {
    local body
    for body in '{"id":"d0000000-0000-4000-8000-0000000000ab","armingRevision":1}' \
        '{"id":"d0000000-0000-4000-8000-0000000000ab","enabled":"true","armingRevision":1}' \
        '{"id":"d0000000-0000-4000-8000-0000000000ab","enabled":false,"armingRevision":1}' \
        '{"id":"d0000000-0000-4000-8000-0000000000ab","enabled":null,"armingRevision":1}' \
        '{"id":"d0000000-0000-4000-8000-0000000000ab","enabled":1,"armingRevision":1}' \
        '{"id":"d0000000-0000-4000-8000-0000000000ab","enabled":"<b>x</b>","armingRevision":"1"}'; do
        fresh_state
        respond 0 201 "$body"
        post_row 1.5
        expect_post "[$body]" 1 "$ALERT_ID" "" "201 for alert [$ALERT_ID] whose enabled is not the JSON boolean true"
    done
}

# An interrupt while the POST is in flight is held until the returned id is recorded, so
# cleanup can still delete the alert; the run then exits 130.
create_interrupt_case() {
    local status=0
    respond 0 201 "{\"id\":\"$ALERT_ID\",\"enabled\":true,\"armingRevision\":1}"
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

# A group TERM kills the POST's curl under Git Bash: the outcome is unknown, and the create is
# recorded for cleanup before the held interrupt ends the run with 130.
create_interrupt_unknown_case() {
    local status=0
    SECONDS=42
    respond 143 000 ""
    (
        trap on_signal INT TERM
        STUB_SIGNAL_PID="$BASHPID"
        create_alert "$ACCOUNT_ID" TARGET_PRICE "$INSTRUMENT_ID" ABOVE 1.5
        echo "create_alert returned"
    ) >"$TEST_OUT" 2>&1 || status=$?
    expect "exit status" 130 "$status"
    expect_file "output" "$TEST_OUT"
    expect_file "owned" "$RUN_DIR/owned"
    expect_file "unknown creates" "$RUN_DIR/unknown-creates" "$UNKNOWN_RECORD"
}

# Every create is written to in-flight-create before its POST is sent, one line led by the number
# of unknown-creates lines before it, and the file is emptied once the outcome is recorded: the
# id owned, the create recorded as unknown, or the create refused.
post_in_flight_case() {
    local row rc status payload earlier owned unknown line after recorded
    while IFS='|' read -r row rc status payload earlier owned unknown; do
        fresh_state
        SECONDS=42
        if [[ "$earlier" -eq 1 ]]; then
            printf '7\t%s\tPROFIT_LOSS\t%s\tABOVE\t2\n' "$ACCOUNT_ID" "$INSTRUMENT_ID" >"$RUN_DIR/unknown-creates"
        fi
        respond "$rc" "$status" "$payload"
        post_row 1.5
        printf -v line '%s\t%s\tTARGET_PRICE\t%s\tABOVE\t1.5' "$earlier" "$ACCOUNT_ID" "$INSTRUMENT_ID"
        expect_file "$row: written ahead of the POST" "$STUB/in-flight.seen" "$line"
        after="missing"
        if [[ -f "$RUN_DIR/in-flight-create" ]]; then
            slurp "$RUN_DIR/in-flight-create"
            after="[$REPLY]"
        fi
        recorded=0
        if [[ -f "$RUN_DIR/unknown-creates" ]]; then
            count_lines "$RUN_DIR/unknown-creates"
            recorded="$REPLY"
        fi
        expect "$row: outcome" "in-flight=[] owned=[$owned] unknown lines=$unknown" \
            "in-flight=$after owned=[$POST_OWNED] unknown lines=$recorded"
    done <<EOF
created|0|201|{"id":"$ALERT_ID","enabled":true,"armingRevision":1}|0|$ALERT_ID|0
created at revision 2|0|201|{"id":"$ALERT_ID","enabled":true,"armingRevision":2}|0|$ALERT_ID|0
refused|0|400|{"error":"invalid"}|0||0
transport error|7|000|$CONNECT_ERROR|0||1
201 without a readable id|0|201|{}|0||1
transport error after an earlier unknown create|7|000|$CONNECT_ERROR|1||2
EOF
}

# A create that cannot be written ahead is never sent, so no alert can exist without a record.
post_in_flight_unwritable_case() {
    mkdir "$RUN_DIR/in-flight-create"
    respond 0 201 "{\"id\":\"$ALERT_ID\",\"enabled\":true,\"armingRevision\":1}"
    post_row 1.5 2>"$TEST_OUT"
    expect_post "unwritable" 1 "" "" \
        "the create could not be written to $RUN_DIR/in-flight-create, so its POST was not sent"
    count_lines "$STUB/requests"
    expect "requests" 0 "$REPLY"
}

# ---------------------------------------------------------------------------------------------
# The http write-out record and the POST's shield

# record_row ROW MODE RC STATUS PAYLOAD EXPECTED: one GET, answered RC STATUS PAYLOAD with curl
# mode MODE; EXPECTED is "status=S type=[T] error=[E]".
record_row() {
    fresh_state
    STUB_CURL_MODE="$2"
    respond "$3" "$4" "$5"
    http GET "$FLAG_ENDPOINT"
    expect "$1" "$6" "status=$HTTP_STATUS type=[$HTTP_CTYPE] error=[$HTTP_ERROR]"
}

http_record_case() {
    record_row "complete transfer" "" 0 200 "$FLAG_ON" "status=200 type=[application/json] error=[]"
    record_row "interrupt held while curl finished" interrupted 0 201 "{}" \
        "status=201 type=[application/json] error=[]"
    record_row "connection refused" "" 7 000 "$CONNECT_ERROR" "status=000 type=[] error=[$CONNECT_ERROR]"
    record_row "transfer broken after the header" "" 18 200 "curl: (18) transfer closed" \
        "status=000 type=[] error=[curl: (18) transfer closed]"
    record_row "curl killed before its record" "" 143 000 "" "status=000 type=[] error=[]"
    record_row "curl without exitcode, complete" no-exitcode 0 200 "$FLAG_ON" \
        "status=200 type=[application/json] error=[]"
    record_row "curl without exitcode, refused" no-exitcode 7 000 "$CONNECT_ERROR" \
        "status=000 type=[] error=[$CONNECT_ERROR]"
    record_row "exit 0 without a record" no-record 0 200 "$FLAG_ON" "status=000 type=[] error=[]"
}

# A POST's curl ignores INT and TERM, so a signal to the process group cannot cut off a create;
# a GET's curl is ended by TERM. The POST runs in a subshell with an INT trap of its own: bash
# runs the INT trap when a foreground child is killed by INT, so an unshielded curl shows up as
# that trap's line instead of ending this suite.
http_shield_case() {
    STUB_SELF_SIGNALS="INT TERM"
    respond 0 201 "{\"id\":\"$ALERT_ID\",\"armingRevision\":1}"
    respond 0 200 "$FLAG_ON"
    (
        trap 'echo "INT reached the shell"' INT
        http POST "$ALERTS_ENDPOINT" '{}'
        echo "status=$HTTP_STATUS body=[$HTTP_BODY]"
    ) >"$TEST_OUT" 2>&1
    expect_file "POST" "$TEST_OUT" "status=201 body=[{\"id\":\"$ALERT_ID\",\"armingRevision\":1}]"
    STUB_SELF_SIGNALS="TERM"
    http GET "$FLAG_ENDPOINT"
    expect "GET" "status=000" "status=$HTTP_STATUS"
}

# ---------------------------------------------------------------------------------------------
# Typed replies: the flag, and the alert a create or re-arm answers with

FLAG_LOCKED='{"id":"portfolio-insights-enabled","enabled":false,"isModifiable":false}'
# A flag reply whose id an attacker could choose; no reason may repeat it.
FLAG_FOREIGN_ID='{"id":"<b>other-flag</b>","enabled":true,"isModifiable":true}'

# flag_row ROW BODY EXPECTED: read_flag on BODY; EXPECTED is
# "rc=N enabled=[E] modifiable=[M] error=[REASON]".
flag_row() {
    local rc=0
    read_flag "$2" || rc=$?
    expect "$1" "$3" "rc=$rc enabled=[$FLAG_ENABLED] modifiable=[$FLAG_MODIFIABLE] error=[$FLAG_ERROR]"
}

read_flag_case() {
    local none="rc=1 enabled=[] modifiable=[]" not_object="error=[its reply is not one JSON object]"
    flag_row "on and modifiable" "$FLAG_ON" "rc=0 enabled=[true] modifiable=[true] error=[]"
    flag_row "off and locked" "$FLAG_LOCKED" "rc=0 enabled=[false] modifiable=[false] error=[]"
    flag_row "enabled as a string" '{"id":"portfolio-insights-enabled","enabled":"false","isModifiable":true}' \
        "$none error=[its enabled is not a JSON boolean]"
    flag_row "enabled as a number" '{"id":"portfolio-insights-enabled","enabled":0,"isModifiable":true}' \
        "$none error=[its enabled is not a JSON boolean]"
    flag_row "isModifiable as a string" '{"id":"portfolio-insights-enabled","enabled":true,"isModifiable":"true"}' \
        "$none error=[its isModifiable is not a JSON boolean]"
    flag_row "isModifiable missing" '{"id":"portfolio-insights-enabled","enabled":true}' \
        "$none error=[its isModifiable is not a JSON boolean]"
    flag_row "another flag's id" "$FLAG_FOREIGN_ID" "$none error=[its id is not portfolio-insights-enabled]"
    flag_row "id in another case" '{"id":"Portfolio-Insights-Enabled","enabled":true,"isModifiable":true}' \
        "$none error=[its id is not portfolio-insights-enabled]"
    flag_row "id missing" '{"enabled":true,"isModifiable":true}' "$none error=[its id is not portfolio-insights-enabled]"
    flag_row "array" "[$FLAG_ON]" "$none $not_object"
    flag_row "two objects" "$FLAG_ON$FLAG_OFF" "$none $not_object"
    flag_row "trailing text" "$FLAG_ON x" "$none $not_object"
    flag_row "not JSON" "enabled=true" "$none $not_object"
    flag_row "empty" "" "$none $not_object"
}

# put_row ROW VALUE RC STATUS BODY EXPECTED: put_flag VALUE, answered RC STATUS BODY, sends one
# PUT of VALUE; EXPECTED is "rc=N error=[REASON]".
put_row() {
    local rc=0
    fresh_state
    respond "$3" "$4" "$5"
    put_flag "$2" || rc=$?
    expect_file "$1 requests" "$STUB/requests" "PUT $FLAG_ENDPOINT {\"enabled\": $2}"
    expect "$1" "$6" "rc=$rc error=[$FLAG_PUT_ERROR]"
}

put_flag_case() {
    put_row "on, reply on" true 0 200 "$FLAG_ON" "rc=0 error=[]"
    put_row "off, reply off" false 0 200 "$FLAG_OFF" "rc=0 error=[]"
    put_row "on, reply still off" true 0 200 "$FLAG_OFF" "rc=1 error=[status 200, but its reply shows enabled=false]"
    put_row "off, reply still on" false 0 200 "$FLAG_ON" "rc=1 error=[status 200, but its reply shows enabled=true]"
    put_row "reply without an id" true 0 200 '{"enabled":true}' \
        "rc=1 error=[status 200, but its id is not portfolio-insights-enabled]"
    put_row "reply with enabled as a string" true 0 200 \
        '{"id":"portfolio-insights-enabled","enabled":"true","isModifiable":true}' \
        "rc=1 error=[status 200, but its enabled is not a JSON boolean]"
    put_row "empty 200" true 0 200 "" "rc=1 error=[status 200, but its reply is not one JSON object]"
    put_row "status 400" true 0 400 '{"message":"flag is not modifiable"}' "rc=1 error=[status 400]"
    put_row "transport error" true 7 000 "$CONNECT_ERROR" "rc=1 error=[transport error ($CONNECT_ERROR)]"
}

# initial_flag_row ROW STATUS BODY EXPECTED: read_initial_flag answered STATUS BODY ends the run
# through abort; EXPECTED is its status and PASS, FAIL and SUMMARY lines. Its output never
# repeats the reply or its content type.
initial_flag_row() {
    local status=0
    fresh_state
    respond 0 "$2" "$3"
    (read_initial_flag) >"$TEST_OUT" 2>&1 || status=$?
    exit_lines "$TEST_OUT"
    expect "$1" "$4" "status=$status $REPLY"
    slurp "$TEST_OUT"
    if [[ "$REPLY" == *"other-flag"* || "$REPLY" == *"application/json"* ]]; then
        case_reasons+=("$1: the output repeats the reply or its content type: $REPLY")
    fi
}

read_initial_flag_case() {
    local summary="PASS cleanup|SUMMARY 1 passed, 1 failed|" requests
    respond 0 200 "$FLAG_OFF"
    read_initial_flag >"$TEST_OUT"
    slurp "$STUB/requests"
    requests="$REPLY"
    exit_lines "$TEST_OUT"
    expect "off and modifiable" "initial=[false] requests=[GET $FLAG_ENDPOINT] PASS flag modifiable|" \
        "initial=[$FLAG_INITIAL] requests=[$requests] $REPLY"
    initial_flag_row "locked" 200 "$FLAG_LOCKED" \
        "status=1 FAIL flag modifiable: isModifiable is false; a deployment with ENABLE_MODIFY=false cannot be toggled|$summary"
    initial_flag_row "isModifiable as a string" 200 \
        '{"id":"portfolio-insights-enabled","enabled":false,"isModifiable":"true"}' \
        "status=1 FAIL flag modifiable: GET portfolio-insights-enabled gave status 200, but its isModifiable is not a JSON boolean|$summary"
    initial_flag_row "another flag's id" 200 "$FLAG_FOREIGN_ID" \
        "status=1 FAIL flag modifiable: GET portfolio-insights-enabled gave status 200, but its id is not portfolio-insights-enabled|$summary"
    initial_flag_row "status 404" 404 "" \
        "status=1 FAIL flag modifiable: GET portfolio-insights-enabled gave status 404|$summary"
}

# A PUT whose reply does not show the flag on fails "flag enabled", and the flag, touched before
# the PUT, is restored on the way out.
enable_flag_case() {
    local status=0
    respond 0 200 "$FLAG_ON"
    enable_flag >"$TEST_OUT"
    exit_lines "$TEST_OUT"
    expect "reply on" "touched=1 PASS flag enabled|" "touched=$FLAG_TOUCHED $REPLY"
    fresh_state
    FLAG_INITIAL=false
    respond 0 200 "$FLAG_OFF"
    respond 0 200 "$FLAG_OFF"
    (enable_flag) >"$TEST_OUT" 2>&1 || status=$?
    exit_lines "$TEST_OUT"
    expect "reply still off" \
        "status=1 FAIL flag enabled: PUT {\"enabled\": true} gave status 200, but its reply shows enabled=false|PASS cleanup|SUMMARY 1 passed, 1 failed|" \
        "status=$status $REPLY"
    expect_file "reply still off requests" "$STUB/requests" "PUT $FLAG_ENDPOINT {\"enabled\": true}" \
        "PUT $FLAG_ENDPOINT {\"enabled\": false}"
}

# reply_row ROW BODY EXPECTED: read_alert_reply on BODY; EXPECTED is
# "rc=N id=[ID] enabled=[E] revision=[R]".
reply_row() {
    local rc=0
    read_alert_reply "$2" || rc=$?
    expect "$1" "$3" "rc=$rc id=[$REPLY_ID] enabled=[$REPLY_ENABLED] revision=[$REPLY_REVISION]"
}

read_alert_reply_case() {
    local id='"id":"d0000000-0000-4000-8000-0000000000ab"' none="rc=1 id=[] enabled=[] revision=[]"
    reply_row "created, upper-case id" '{"id":"D0000000-0000-4000-8000-0000000000AB","enabled":true,"armingRevision":1}' \
        "rc=0 id=[$ALERT_ID] enabled=[true] revision=[1]"
    reply_row "re-armed" "{$id,\"enabled\":true,\"armingRevision\":2147483647}" \
        "rc=0 id=[$ALERT_ID] enabled=[true] revision=[2147483647]"
    reply_row "disabled" "{$id,\"enabled\":false,\"armingRevision\":3}" "rc=0 id=[$ALERT_ID] enabled=[false] revision=[3]"
    reply_row "revision as a string" "{$id,\"enabled\":true,\"armingRevision\":\"1\"}" \
        "rc=0 id=[$ALERT_ID] enabled=[true] revision=[]"
    reply_row "fractional revision" "{$id,\"enabled\":true,\"armingRevision\":1.5}" \
        "rc=0 id=[$ALERT_ID] enabled=[true] revision=[]"
    reply_row "revision 1.0" "{$id,\"enabled\":true,\"armingRevision\":1.0}" "rc=0 id=[$ALERT_ID] enabled=[true] revision=[]"
    reply_row "revision 0" "{$id,\"enabled\":true,\"armingRevision\":0}" "rc=0 id=[$ALERT_ID] enabled=[true] revision=[]"
    reply_row "negative revision" "{$id,\"enabled\":true,\"armingRevision\":-1}" \
        "rc=0 id=[$ALERT_ID] enabled=[true] revision=[]"
    reply_row "exponent revision" "{$id,\"enabled\":true,\"armingRevision\":1e2}" \
        "rc=0 id=[$ALERT_ID] enabled=[true] revision=[]"
    reply_row "eleven-digit revision" "{$id,\"enabled\":true,\"armingRevision\":12345678901}" \
        "rc=0 id=[$ALERT_ID] enabled=[true] revision=[]"
    reply_row "enabled as a string" "{$id,\"enabled\":\"true\",\"armingRevision\":1}" \
        "rc=0 id=[$ALERT_ID] enabled=[] revision=[1]"
    reply_row "id one digit short" '{"id":"d0000000-0000-4000-8000-0000000000a","enabled":true,"armingRevision":1}' \
        "rc=0 id=[] enabled=[true] revision=[1]"
    reply_row "id as a number" '{"id":12,"enabled":true,"armingRevision":1}' "rc=0 id=[] enabled=[true] revision=[1]"
    reply_row "array" "[{$id,\"enabled\":true,\"armingRevision\":1}]" "$none"
    reply_row "two objects" "{$id}{$id}" "$none"
    reply_row "not JSON" "created" "$none"
    reply_row "empty" "" "$none"
}

# ---------------------------------------------------------------------------------------------
# Cleanup and exit

# delete_fixture: owned ids 3, 1, 2, 4, 5, 1 again and 6, where 6 is already deleted; the five
# remaining ids get, in sorted order, 204, 404, a 500 on all three attempts, a 403 again after
# the flag is read off and switched on, and a transport error on all three attempts.
delete_fixture() {
    own 3 1 2 4 5 1 6
    alert_id 6
    echo "$REPLY" >"$RUN_DIR/deleted"
    respond 0 204
    respond 0 404 '{"error":"not_found"}'
    respond 0 500 '{"error":"internal"}'
    respond 0 500 '{"error":"internal"}'
    respond 0 500 '{"error":"internal"}'
    respond 0 403 '{"error":"feature_disabled"}'
    respond 0 200 "$FLAG_OFF"
    respond 0 200 "$FLAG_ON"
    respond 0 403 '{"error":"feature_disabled"}'
    respond 7 000 "$CONNECT_ERROR"
    respond 7 000 "$CONNECT_ERROR"
    respond 7 000 "$CONNECT_ERROR"
    delete_owned_alerts >"$TEST_OUT"
}

# Each undeleted id is deleted by id; a 500 and a transport error are tried three times, with
# waits of 1 s and 2 s, and a 403 once more after the flag is read off and switched on.
delete_requests_case() {
    local ids=() n
    for n in 1 2 3 3 3 4; do
        alert_id "$n"
        ids+=("DELETE $ALERTS_ENDPOINT/$REPLY")
    done
    ids+=("GET $FLAG_ENDPOINT" "PUT $FLAG_ENDPOINT {\"enabled\": true}" "${ids[5]}")
    alert_id 5
    ids+=("DELETE $ALERTS_ENDPOINT/$REPLY" "DELETE $ALERTS_ENDPOINT/$REPLY" "DELETE $ALERTS_ENDPOINT/$REPLY")
    delete_fixture
    expect_file "requests" "$STUB/requests" "${ids[@]}"
    expect_file "sleeps" "$STUB/sleeps" 1 2 1 2
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

# cutoff_row ROW EXPECTED ANSWER...: owned ids 1 to MAX_CONSECUTIVE_TRANSPORT_ERRORS + 2, each
# ANSWER answering every attempt at one id, in order. An ANSWER is a status (000 is a transport
# error, off the flag read that shows the flag off, and on the PUT reply that shows it on); a 000
# or 5xx answers all DELETE_ATTEMPTS attempts, and A/B/C answers the requests one by one.
cutoff_row() {
    local row="$1" expected="$2" answer status statuses=() i requests left=() skipped=0
    shift 2
    fresh_state
    for ((i = 1; i <= MAX_CONSECUTIVE_TRANSPORT_ERRORS + 2; i++)); do
        own "$i"
    done
    for answer in "$@"; do
        IFS=/ read -r -a statuses <<<"$answer"
        if [[ ${#statuses[@]} -eq 1 && ("$answer" == "000" || "$answer" == 5??) ]]; then
            for ((i = 1; i < DELETE_ATTEMPTS; i++)); do
                statuses+=("$answer")
            done
        fi
        for status in "${statuses[@]}"; do
            if [[ "$status" == "000" ]]; then
                respond 7 000 "$CONNECT_ERROR"
            elif [[ "$status" == "off" ]]; then
                respond 0 200 "$FLAG_OFF"
            elif [[ "$status" == "on" ]]; then
                respond 0 200 "$FLAG_ON"
            else
                respond 0 "$status"
            fi
        done
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
    local max="$MAX_CONSECUTIVE_TRANSPORT_ERRORS" tries="$DELETE_ATTEMPTS" total errors=() i
    total=$((max + 2))
    for ((i = 1; i < max; i++)); do
        errors+=(000)
    done
    cutoff_row "only transport errors" \
        "requests=$((max * tries)) not attempted=2 problems=$total owned alerts left in place, ids in RUN/left-in-place" \
        "${errors[@]}" 000 000 000
    cutoff_row "an HTTP status resets the count" \
        "requests=$((total * tries)) not attempted=0 problems=$total owned alerts left in place, ids in RUN/left-in-place" \
        "${errors[@]}" 500 000 000
    cutoff_row "a 404 resets the count" \
        "requests=$(((total - 1) * tries + 1)) not attempted=0 problems=$((total - 1)) owned alerts left in place, ids in RUN/left-in-place" \
        "${errors[@]}" 404 000 000
    cutoff_row "an id whose attempts did not all end in transport errors resets the count" \
        "requests=$((total * tries)) not attempted=0 problems=$total owned alerts left in place, ids in RUN/left-in-place" \
        "${errors[@]}" 000/500/000 000 000
    cutoff_row "a 403 whose try after the flag is switched on again ends in transport errors counts" \
        "requests=$((max * tries + 3)) not attempted=2 problems=$total owned alerts left in place, ids in RUN/left-in-place" \
        "${errors[@]}" 403/off/on/000/000/000 000 000
}

# retry_row ROW EXPECTED ANSWER...: one owned id whose attempts get the ANSWERs, statuses with
# 000 for a transport error; EXPECTED is "deleted=[IDS] requests=N sleeps=[STEPS] left=[LINE]".
retry_row() {
    local row="$1" expected="$2" status steps=()
    shift 2
    fresh_state
    own 1
    for status in "$@"; do
        if [[ "$status" == "000" ]]; then
            respond 28 000 "curl: (28) Operation timed out"
        else
            respond 0 "$status"
        fi
    done
    delete_owned_alerts >"$TEST_OUT"
    count_lines "$STUB/requests"
    mapfile -t steps <"$STUB/sleeps"
    local requests="$REPLY"
    slurp "$RUN_DIR/deleted"
    local deleted="$REPLY"
    slurp "$RUN_DIR/left-in-place"
    expect "$row" "$expected" "deleted=[$deleted] requests=$requests sleeps=[${steps[*]}] left=[${REPLY#* }]"
}

delete_retry_case() {
    local a
    alert_id 1
    a="$REPLY"
    retry_row "transport error, then deleted" "deleted=[$a] requests=2 sleeps=[1] left=[]" 000 204
    retry_row "two 503s, then deleted" "deleted=[$a] requests=3 sleeps=[1 2] left=[]" 503 503 204
    retry_row "502, then already absent" "deleted=[$a] requests=2 sleeps=[1] left=[]" 502 404
    retry_row "three transport errors" \
        "deleted=[] requests=3 sleeps=[1 2] left=[transport error (curl: (28) Operation timed out)]" 000 000 000
    retry_row "transport error, then 500 twice" "deleted=[] requests=3 sleeps=[1 2] left=[status 500]" 000 500 500
    retry_row "400 is not tried again" "deleted=[] requests=1 sleeps=[] left=[status 400]" 400
}

# A 403 after which the flag reads enabled=false means the flag was switched off: it is switched
# on again and the id tried once more, at most MAX_FLAG_REENABLES times in one call; an id left
# in place names the next run.
delete_flag_off_case() {
    local a requests=() i
    alert_id 1
    a="$REPLY"
    own 1
    respond 0 403 '{"error":"feature_disabled"}'
    respond 0 200 "$FLAG_OFF"
    respond 0 200 "$FLAG_ON"
    respond 0 204
    delete_owned_alerts >"$TEST_OUT"
    expect_file "read off, switched on, then deleted" "$STUB/requests" "DELETE $ALERTS_ENDPOINT/$a" \
        "GET $FLAG_ENDPOINT" "PUT $FLAG_ENDPOINT {\"enabled\": true}" "DELETE $ALERTS_ENDPOINT/$a"
    expect "read off, switched on, then deleted: flag, deleted and problems" \
        "touched=1 initial=[false] deleted=[$a] problems=[]" \
        "touched=$FLAG_TOUCHED initial=[$FLAG_INITIAL] deleted=[$(<"$RUN_DIR/deleted")] problems=[$CLEANUP_PROBLEMS]"

    fresh_state
    own 1
    FLAG_INITIAL=true
    respond 0 403 '{"error":"feature_disabled"}'
    respond 0 200 "$FLAG_OFF"
    respond 0 200 "$FLAG_ON"
    respond 0 204
    delete_owned_alerts >"$TEST_OUT"
    expect "read off with the setup value kept" "touched=1 initial=[true]" \
        "touched=$FLAG_TOUCHED initial=[$FLAG_INITIAL]"

    fresh_state
    for i in 1 2 3 4 5; do
        own "$i"
        alert_id "$i"
        requests+=("DELETE $ALERTS_ENDPOINT/$REPLY")
        if [[ $i -le $MAX_FLAG_REENABLES ]]; then
            requests+=("GET $FLAG_ENDPOINT" "PUT $FLAG_ENDPOINT {\"enabled\": true}" "DELETE $ALERTS_ENDPOINT/$REPLY")
            respond 0 403 '{"error":"feature_disabled"}'
            respond 0 200 "$FLAG_OFF"
            respond 0 200 "$FLAG_ON"
        fi
        respond 0 403 '{"error":"feature_disabled"}'
    done
    RUN_RECORD="$STATE_DIR/runs/run"
    delete_owned_alerts >"$TEST_OUT"
    expect_file "switched off again and again" "$STUB/requests" "${requests[@]}"
    expect "switched off again and again: problems" \
        "5 owned alerts left in place, ids in $RUN_DIR/left-in-place; the next run on project [unit-test] with base url http://localhost and compose file $COMPOSE_PATH deletes them first" \
        "$CLEANUP_PROBLEMS"

    fresh_state
    own 1
    respond 0 403 '{"error":"feature_disabled"}'
    respond 0 200 "$FLAG_OFF"
    respond 0 503 '{"error":"unavailable"}'
    delete_owned_alerts >"$TEST_OUT"
    expect "flag not switched on again" "left=[$a status 403] requests=3" \
        "left=[$(<"$RUN_DIR/left-in-place")] requests=$(($(wc -l <"$STUB/requests")))"
}

# flag_403_row ROW FLAG_STATUS FLAG_BODY RETRY_STATUS EXPECTED: one owned id whose DELETE answers
# 403, after which the flag read answers FLAG_STATUS FLAG_BODY (000 is a transport error) and a
# second DELETE, if any, RETRY_STATUS; EXPECTED is "requests=[R|R...] touched=T initial=[V]
# deleted=[IDS] left=[LINE]", with the requests joined by |.
flag_403_row() {
    local requests
    fresh_state
    own 1
    respond 0 403 '{"error":"feature_disabled"}'
    if [[ "$2" == "000" ]]; then
        respond 7 000 "$CONNECT_ERROR"
    else
        respond 0 "$2" "$3"
    fi
    respond 0 "$4"
    delete_owned_alerts >"$TEST_OUT"
    requests="$(<"$STUB/requests")"
    expect "$1" "$5" \
        "requests=[${requests//$'\n'/|}] touched=$FLAG_TOUCHED initial=[$FLAG_INITIAL] deleted=[$(<"$RUN_DIR/deleted")] left=[$(<"$RUN_DIR/left-in-place")]"
}

# The broker also answers 403 while it cannot read the flag, so a 403 is no proof that the flag
# is off. A flag read as enabled=true is left as it is and the id tried once more, which counts
# toward MAX_FLAG_REENABLES; a flag that cannot be read is left as it is, and the id keeps its
# 403 with nothing tried again.
delete_flag_403_case() {
    local a delete get="GET $FLAG_ENDPOINT" requests=() i
    alert_id 1
    a="$REPLY"
    delete="DELETE $ALERTS_ENDPOINT/$a"
    flag_403_row "read on, tried once more" 200 "$FLAG_ON" 204 \
        "requests=[$delete|$get|$delete] touched=0 initial=[] deleted=[$a] left=[]"
    flag_403_row "read on, 403 again" 200 "$FLAG_ON" 403 \
        "requests=[$delete|$get|$delete] touched=0 initial=[] deleted=[] left=[$a status 403]"
    flag_403_row "flag read fails" 000 "" 204 \
        "requests=[$delete|$get] touched=0 initial=[] deleted=[] left=[$a status 403]"
    flag_403_row "flag read answers 503" 503 '{"error":"unavailable"}' 204 \
        "requests=[$delete|$get] touched=0 initial=[] deleted=[] left=[$a status 403]"
    flag_403_row "flag read shows enabled as a string" 200 \
        '{"id":"portfolio-insights-enabled","enabled":"false","isModifiable":true}' 204 \
        "requests=[$delete|$get] touched=0 initial=[] deleted=[] left=[$a status 403]"
    flag_403_row "flag read names another flag" 200 \
        '{"id":"<b>other</b>","enabled":false,"isModifiable":true}' 204 \
        "requests=[$delete|$get] touched=0 initial=[] deleted=[] left=[$a status 403]"

    fresh_state
    for i in 1 2 3 4 5; do
        own "$i"
        alert_id "$i"
        requests+=("DELETE $ALERTS_ENDPOINT/$REPLY")
        if [[ $i -le $MAX_FLAG_REENABLES ]]; then
            requests+=("$get" "DELETE $ALERTS_ENDPOINT/$REPLY")
            respond 0 403 '{"error":"feature_disabled"}'
            respond 0 200 "$FLAG_ON"
        fi
        respond 0 403 '{"error":"feature_disabled"}'
    done
    delete_owned_alerts >"$TEST_OUT"
    expect_file "read on again and again" "$STUB/requests" "${requests[@]}"
    expect "read on again and again: flag" "touched=0 left=5" \
        "touched=$FLAG_TOUCHED left=$(($(wc -l <"$RUN_DIR/left-in-place")))"
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

    cleanup_row_start 1 0 false
    respond 0 200 '{"id":"portfolio-insights-enabled","enabled":"false","isModifiable":true}'
    respond 0 204
    cleanup_row_end "owned alert, enabled read as a string and left untouched" "GET $FLAG_ENDPOINT" "$delete"

    cleanup_row_start 0 1 ""
    cleanup_row_end "flag touched before its value was read"
}

# expect_restored ROW VALUE: cleanup_all's output reports the flag restored to enabled=VALUE.
expect_restored() {
    local lines=() line found=""
    mapfile -t lines <"$TEST_OUT"
    for line in "${lines[@]}"; do
        if [[ "$line" == "INFO cleanup: flag portfolio-insights-enabled restored to enabled="* ]]; then
            found="$line"
        fi
    done
    expect "$1 restore line" "INFO cleanup: flag portfolio-insights-enabled restored to enabled=$2" "$found"
}

# A run that ends before setup read the flag (FLAG_INITIAL empty) can still own ids adopted from
# an earlier run. Cleanup restores the value found just before it switched the flag on to delete
# them: enabled=false, as its own read found it, or as the read after a DELETE's 403 found it
# when its own read failed. A 403 alone shows nothing: with the flag still unreadable, or read
# as on, the flag is not switched and nothing is restored. A value setup read is restored
# however cleanup finds the flag.
cleanup_flag_unread_case() {
    local delete on="PUT $FLAG_ENDPOINT {\"enabled\": true}" off="PUT $FLAG_ENDPOINT {\"enabled\": false}"
    local get="GET $FLAG_ENDPOINT" a
    alert_id 1
    a="$REPLY"
    delete="DELETE $ALERTS_ENDPOINT/$REPLY"

    cleanup_row_start 1 0 ""
    respond 0 200 "$FLAG_OFF"
    respond 0 200 "$FLAG_ON"
    respond 0 204
    respond 0 200 "$FLAG_OFF"
    cleanup_row_end "not read by setup, read off by cleanup" "GET $FLAG_ENDPOINT" "$on" "$delete" "$off"
    expect_restored "not read by setup, read off by cleanup" false

    cleanup_row_start 1 0 ""
    respond 7 000 "$CONNECT_ERROR"
    respond 0 403 '{"error":"feature_disabled"}'
    respond 0 200 "$FLAG_OFF"
    respond 0 200 "$FLAG_ON"
    respond 0 204
    respond 0 200 "$FLAG_OFF"
    cleanup_row_end "not read by setup or cleanup, DELETE 403, then read off" "$get" "$delete" "$get" \
        "$on" "$delete" "$off"
    expect_restored "not read by setup or cleanup, DELETE 403, then read off" false

    cleanup_row_start 1 0 ""
    respond 7 000 "$CONNECT_ERROR"
    respond 0 403 '{"error":"feature_disabled"}'
    respond 7 000 "$CONNECT_ERROR"
    cleanup_all >"$TEST_OUT"
    expect_file "not read by setup or cleanup, DELETE 403, still unreadable: requests" "$STUB/requests" \
        "$get" "$delete" "$get"
    expect "not read by setup or cleanup, DELETE 403, still unreadable: flag and problems" \
        "touched=0 initial=[] problems=[1 owned alerts left in place, ids in RUN/left-in-place]" \
        "touched=$FLAG_TOUCHED initial=[$FLAG_INITIAL] problems=[${CLEANUP_PROBLEMS//$RUN_DIR/RUN}]"
    expect_file "not read by setup or cleanup, DELETE 403, still unreadable: left" "$RUN_DIR/left-in-place" \
        "$a status 403"

    cleanup_row_start 1 0 ""
    respond 7 000 "$CONNECT_ERROR"
    respond 0 403 '{"error":"feature_disabled"}'
    respond 0 200 "$FLAG_ON"
    respond 0 204
    cleanup_row_end "not read by setup or cleanup, DELETE 403, then read on" "$get" "$delete" "$get" \
        "$delete"
    expect "not read by setup or cleanup, DELETE 403, then read on: flag" "touched=0 initial=[]" \
        "touched=$FLAG_TOUCHED initial=[$FLAG_INITIAL]"

    cleanup_row_start 1 1 true
    respond 0 200 "$FLAG_OFF"
    respond 0 200 "$FLAG_ON"
    respond 0 204
    respond 0 200 "$FLAG_ON"
    cleanup_row_end "read on by setup, read off by cleanup" "$get" "$on" "$delete" "$on"
    expect_restored "read on by setup, read off by cleanup" true

    cleanup_row_start 1 1 true
    respond 0 200 "$FLAG_ON"
    respond 0 403 '{"error":"feature_disabled"}'
    respond 0 200 "$FLAG_OFF"
    respond 0 200 "$FLAG_ON"
    respond 0 204
    respond 0 200 "$FLAG_ON"
    cleanup_row_end "read on by setup, DELETE 403, then read off" "$get" "$delete" "$get" "$on" "$delete" \
        "$on"
    expect_restored "read on by setup, DELETE 403, then read off" true
}

# The flag cannot be switched on for deletion: the DELETE answers 403, the flag, read off again,
# is tried once more, and the alert is deleted when that works and left in place when it does
# not.
cleanup_flag_not_on_case() {
    own 1
    FLAG_TOUCHED=1
    FLAG_INITIAL=false
    respond 0 200 "$FLAG_OFF"
    respond 0 503 '{"error":"unavailable"}'
    respond 0 403 '{"error":"feature_disabled"}'
    respond 0 200 "$FLAG_OFF"
    respond 0 503 '{"error":"unavailable"}'
    respond 0 200 "$FLAG_OFF"
    cleanup_all >"$TEST_OUT"
    expect "status 503 twice" \
        "flag could not be switched on for deletion: status 503; 1 owned alerts left in place, ids in $RUN_DIR/left-in-place" \
        "$CLEANUP_PROBLEMS"
    fresh_state
    own 1
    FLAG_TOUCHED=1
    FLAG_INITIAL=false
    respond 0 200 "$FLAG_OFF"
    respond 0 200 "$FLAG_OFF"
    respond 0 403 '{"error":"feature_disabled"}'
    respond 0 200 "$FLAG_OFF"
    respond 0 200 "$FLAG_ON"
    respond 0 204
    respond 0 200 "$FLAG_OFF"
    cleanup_all >"$TEST_OUT"
    expect "200 whose reply shows the flag still off, then switched on" \
        "flag could not be switched on for deletion: status 200, but its reply shows enabled=false" \
        "$CLEANUP_PROBLEMS"
    count_lines "$RUN_DIR/deleted"
    expect "200 whose reply shows the flag still off, then switched on: deleted" 1 "$REPLY"
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
    fresh_state
    FLAG_TOUCHED=1
    FLAG_INITIAL=false
    respond 0 200 "$FLAG_ON"
    cleanup_all >"$TEST_OUT"
    expect "200 whose reply shows the flag still on" \
        "flag portfolio-insights-enabled not restored to enabled=false: status 200, but its reply shows enabled=true" \
        "$CLEANUP_PROBLEMS"
}

# The fixture precondition time, as read_armed_set writes a seven-digit SQL Server fraction, and
# the createdAt of an alert made after it, as the broker renders a DateTimeOffset.
PRECONDITION_FIXTURE="2026-01-01T00:00:00.5000000Z"
CREATED_AFTER='"2026-01-01T00:00:01.25+00:00"'

# alert_json ID TYPE INSTRUMENT DIRECTION THRESHOLD ENABLED TRIGGERED_AT REVISION [CREATED_AT]:
# sets REPLY to one alert of the fixture account as the broker's list renders it. CREATED_AT is
# the createdAt JSON value, CREATED_AFTER by default.
alert_json() {
    printf -v REPLY '{"id":"%s","accountId":"%s","instrumentId":"%s","type":"%s","direction":"%s","threshold":%s,"enabled":%s,"armingRevision":%s,"triggeredAt":%s,"triggerValue":null,"acknowledged":false,"createdAt":%s}' \
        "$1" "$ACCOUNT_ID" "$3" "$2" "$4" "$5" "$6" "$8" "$7" "${9:-$CREATED_AFTER}"
}

# alert_list ALERT...: sets REPLY to the list body holding the ALERTs.
alert_list() {
    local IFS=,
    REPLY="{\"results\":[$*]}"
}

# unknown_start THRESHOLD [TYPE]: one unknown create of the fixture account, TYPE (TARGET_PRICE
# by default) ABOVE THRESHOLD on the fixture instrument, whose POST ended at 0 s after the cycle
# precondition passed at PRECONDITION_FIXTURE; the flag is read as on.
unknown_start() {
    fresh_state
    printf '0\t%s\t%s\t%s\tABOVE\t%s\n' "$ACCOUNT_ID" "${2:-TARGET_PRICE}" "$INSTRUMENT_ID" "$1" \
        >"$RUN_DIR/unknown-creates"
    PRECONDITION_AT="$PRECONDITION_FIXTURE"
    respond 0 200 "$FLAG_ON"
}

# unknown_end ROW EXPECTED [TEXT]: runs cleanup_all; EXPECTED is "problems=[P] owned=[IDS]
# resolved=[LINES] lists=N deletes=N sleeps=[STEPS]", with the run directory written as RUN.
# TEXT, when given, must be in cleanup's output.
unknown_end() {
    local lists=0 deletes=0 line steps=() owned resolved=""
    cleanup_all >"$TEST_OUT"
    while IFS= read -r line; do
        case "$line" in
            "GET $ALERTS_ENDPOINT?accountId=$ACCOUNT_ID") lists=$((lists + 1)) ;;
            "DELETE "*) deletes=$((deletes + 1)) ;;
        esac
    done <"$STUB/requests"
    mapfile -t steps <"$STUB/sleeps"
    slurp "$RUN_DIR/owned"
    owned="$REPLY"
    if [[ -f "$RUN_DIR/unknown-resolved" ]]; then
        slurp "$RUN_DIR/unknown-resolved"
        resolved="$REPLY"
    fi
    expect "$1" "$2" \
        "problems=[${CLEANUP_PROBLEMS//$RUN_DIR/RUN}] owned=[$owned] resolved=[$resolved] lists=$lists deletes=$deletes sleeps=[${steps[*]}]"
    if [[ -n "${3:-}" ]]; then
        slurp "$TEST_OUT"
        if [[ "$REPLY" != *"$3"* ]]; then
            case_reasons+=("$1: the output lacks [$3]: $REPLY")
        fi
    fi
}

MAX_TOKEN="9999999999.99999999"
UNKNOWN_DESC="TARGET_PRICE ABOVE $MAX_TOKEN on instrument [$INSTRUMENT_ID] for account [$ACCOUNT_ID], whose outcome"

# An RFC 3339 UTC time becomes its 23-digit key, the fraction padded to nine digits; any other
# text, another offset included, is refused.
utc_time_key_case() {
    local row text want
    while IFS='|' read -r row text want; do
        capture utc_time_key "$text"
        expect "$row" "$want" "$OUTCOME"
    done <<'EOF'
Z without a fraction|2026-01-01T00:00:00Z|rc=0 20260101000000000000000
read_armed_set's PostgreSQL form|2026-11-26T01:49:38.151857Z|rc=0 20261126014938151857000
read_armed_set's SQL Server form|2026-11-26T01:49:38.1518570Z|rc=0 20261126014938151857000
broker's +00:00 form|2026-11-26T20:00:47.1234567+00:00|rc=0 20261126200047123456700
nine fraction digits|2026-12-31T23:59:59.123456789Z|rc=0 20261231235959123456789
leap second|2026-06-30T23:59:60Z|rc=0 20260630235960000000000
ten fraction digits|2026-11-26T01:49:38.1234567890Z|rc=1
offset +01:00|2026-11-26T01:49:38+01:00|rc=1
offset -00:00|2026-11-26T01:49:38-00:00|rc=1
no offset|2026-11-26T01:49:38|rc=1
lower-case t and z|2026-11-26t01:49:38z|rc=1
space for T|2026-11-26 01:49:38Z|rc=1
month 13|2026-13-26T01:49:38Z|rc=1
hour 24|2026-11-26T24:00:00Z|rc=1
empty fraction|2026-11-26T01:49:38.Z|rc=1
trailing text|2026-11-26T01:49:38Z x|rc=1
empty||rc=1
EOF
}

# Keys compare by their whole seconds first, then by their fractions.
time_key_at_or_after_case() {
    local row key from want rc
    while IFS='|' read -r row key from want; do
        rc=0
        time_key_at_or_after "$key" "$from" || rc=$?
        expect "$row" "$want" "rc=$rc"
    done <<'EOF'
equal|20260101000000500000000|20260101000000500000000|rc=0
fraction later|20260101000000500000001|20260101000000500000000|rc=0
fraction earlier|20260101000000499999999|20260101000000500000000|rc=1
second later, fraction smaller|20260101000001000000000|20260101000000999999999|rc=0
second earlier, fraction larger|20260101000000999999999|20260101000001000000000|rc=1
year later|20270101000000000000000|20261231235959999999999|rc=0
EOF
}

# An alert that shows every piece of evidence is adopted and deleted by id, whatever its enabled
# and triggeredAt: the evaluator may have triggered it before cleanup reads the list. Its
# createdAt may equal the precondition time, in either UTC form and with any fraction length.
cleanup_unknown_matched_case() {
    local a b row enabled triggered created
    alert_id 7
    a="$REPLY"
    alert_id 8
    b="$REPLY"

    while IFS='|' read -r row enabled triggered created; do
        unknown_start "$MAX_TOKEN"
        alert_json "$a" TARGET_PRICE "$INSTRUMENT_ID" ABOVE "$MAX_TOKEN" "$enabled" "$triggered" 1 "$created"
        alert_list "$REPLY"
        respond 0 200 "$REPLY"
        respond 0 204
        unknown_end "$row" "problems=[] owned=[$a] resolved=[1] lists=1 deletes=1 sleeps=[]" \
            "INFO cleanup: alert [$a] is the create of $UNKNOWN_DESC was unknown; it is deleted as an owned alert"
    done <<EOF
armed exact alert|true|null|$CREATED_AFTER
exact alert the evaluator triggered|true|"2026-01-01T00:00:02.5+00:00"|$CREATED_AFTER
exact alert disabled|false|null|$CREATED_AFTER
created at the precondition time, +00:00 and one fraction digit|true|null|"2026-01-01T00:00:00.5+00:00"
created at the precondition time, Z and nine fraction digits|true|null|"2026-01-01T00:00:00.500000000Z"
created one microsecond after the precondition time|true|null|"2026-01-01T00:00:00.500001Z"
EOF

    unknown_start "1.500000000" PROFIT_LOSS
    alert_json "$a" PROFIT_LOSS "$INSTRUMENT_ID" ABOVE 1.5 true null 1
    alert_list "$REPLY"
    respond 0 200 "$REPLY"
    respond 0 204
    unknown_end "same threshold value in another form" \
        "problems=[] owned=[$a] resolved=[1] lists=1 deletes=1 sleeps=[]"

    unknown_start "$MAX_TOKEN"
    alert_json "$b" TARGET_PRICE "$INSTRUMENT_ID" ABOVE "$MAX_TOKEN" true null 1
    own 8
    echo "$b" >"$RUN_DIR/deleted"
    alert_json "$a" TARGET_PRICE "$INSTRUMENT_ID" ABOVE "$MAX_TOKEN" true null 1
    alert_list "$REPLY"
    respond 0 200 "{\"results\":[]}"
    respond 0 200 "{\"results\":[]}"
    respond 0 200 "$REPLY"
    respond 0 204
    unknown_end "the alert appears on the third read" \
        "problems=[] owned=[$b"$'\n'"$a] resolved=[1] lists=3 deletes=1 sleeps=[5 5]"
}

# An alert whose createdAt is a UTC time before the precondition was made before the create, so
# it is no candidate whatever its other fields, an exact twin included: the create's alert beside
# it is adopted and deleted by id, and no DELETE goes to the older one.
cleanup_unknown_older_case() {
    local a old row threshold revision enabled triggered created older
    alert_id 7
    a="$REPLY"
    alert_id 9
    old="$REPLY"

    while IFS='|' read -r row threshold revision enabled triggered created; do
        unknown_start "$MAX_TOKEN"
        alert_json "$old" TARGET_PRICE "$INSTRUMENT_ID" ABOVE "$threshold" "$enabled" "$triggered" "$revision" "$created"
        older="$REPLY"
        alert_json "$a" TARGET_PRICE "$INSTRUMENT_ID" ABOVE "$MAX_TOKEN" true null 1
        alert_list "$older" "$REPLY"
        respond 0 200 "$REPLY"
        respond 0 204
        unknown_end "$row" "problems=[] owned=[$a] resolved=[1] lists=1 deletes=1 sleeps=[]" \
            "INFO cleanup: alert [$a] is the create of $UNKNOWN_DESC was unknown; it is deleted as an owned alert"
        expect_file "$row: requests" "$STUB/requests" "GET $FLAG_ENDPOINT" \
            "GET $ALERTS_ENDPOINT?accountId=$ACCOUNT_ID" "DELETE $ALERTS_ENDPOINT/$a"
    done <<EOF
triggered exact twin made 100 ns before the precondition|$MAX_TOKEN|1|true|"2026-01-01T00:00:00.4Z"|"2026-01-01T00:00:00.4999999Z"
disabled exact twin made in the second before the precondition, no fraction|$MAX_TOKEN|1|false|null|"2026-01-01T00:00:00Z"
disabled alert at another threshold and revision made a day before the precondition|1|2|false|null|"2025-12-31T00:00:01.25+00:00"
EOF
}

# An alert this run owns, and alerts that differ in type, instrument or direction, are no
# candidates; with none, the list is read every 5 s until 30 s after the POST, and the create is
# reported as not created.
cleanup_unknown_not_listed_case() {
    local alerts=() i ids=()
    for i in 8 9 10 11; do
        alert_id "$i"
        ids+=("$REPLY")
    done
    unknown_start "$MAX_TOKEN"
    own 8
    echo "${ids[0]}" >"$RUN_DIR/deleted"
    alert_json "${ids[0]}" TARGET_PRICE "$INSTRUMENT_ID" ABOVE "$MAX_TOKEN" true null 1
    alerts+=("$REPLY")
    alert_json "${ids[1]}" TARGET_PRICE "c0000000-0000-4000-8000-000000000002" ABOVE "$MAX_TOKEN" true null 1
    alerts+=("$REPLY")
    alert_json "${ids[2]}" PROFIT_LOSS "$INSTRUMENT_ID" ABOVE "$MAX_TOKEN" true null 1
    alerts+=("$REPLY")
    alert_json "${ids[3]}" TARGET_PRICE "$INSTRUMENT_ID" BELOW "$MAX_TOKEN" true '"1"' '"1"' '"x"'
    alerts+=("$REPLY")
    alert_list "${alerts[@]}"
    for i in 1 2 3 4 5 6 7; do
        respond 0 200 "$REPLY"
    done
    unknown_end "no candidate" "problems=[] owned=[${ids[0]}] resolved=[1] lists=7 deletes=0 sleeps=[5 5 5 5 5 5]" \
        "INFO cleanup: 1 create(s) of $UNKNOWN_DESC was unknown, made no alert within 30s of the POST"

    unknown_start "$MAX_TOKEN"
    echo 1 >"$RUN_DIR/unknown-resolved"
    unknown_end "already reconciled" "problems=[] owned=[] resolved=[1] lists=0 deletes=0 sleeps=[]"
}

# untold LOOSE EXACT UNREADABLE: sets REPLY to the problem of the fixture create whose alert
# cannot be told from others among LOOSE candidates not made before the precondition, EXACT of
# them with the evidence and UNREADABLE with a createdAt that is no UTC time.
untold() {
    REPLY="the create of $UNKNOWN_DESC is unknown, cannot be told from other alerts: $1 alerts this run does not own match its type, instrument and direction without a createdAt before the cycle precondition, $2 of them with its threshold, armingRevision 1 and a createdAt at or after it, $3 of them with a createdAt that is no UTC time, for 1 such creates; none of them was deleted"
}

# When this run's alert cannot be told from others, or the list cannot be read, nothing is
# deleted for the create and cleanup fails naming it; the create stays unreconciled. A candidate
# at another threshold or revision, or without a readable UTC createdAt, is no evidence,
# whatever its other fields, and neither is any candidate while the precondition time is
# unknown.
cleanup_unknown_ambiguous_case() {
    local a b old exact other older row created threshold revision
    alert_id 7
    a="$REPLY"
    alert_id 8
    b="$REPLY"
    alert_id 9
    old="$REPLY"
    alert_json "$a" TARGET_PRICE "$INSTRUMENT_ID" ABOVE "$MAX_TOKEN" true null 1
    exact="$REPLY"

    unknown_start "$MAX_TOKEN"
    alert_json "$b" TARGET_PRICE "$INSTRUMENT_ID" ABOVE 1 true null 1
    other="$REPLY"
    alert_list "$exact" "$other"
    respond 0 200 "$REPLY"
    untold 2 1 0
    unknown_end "another threshold" "problems=[$REPLY] owned=[] resolved=[] lists=1 deletes=0 sleeps=[]"

    unknown_start "$MAX_TOKEN"
    alert_json "$b" TARGET_PRICE "$INSTRUMENT_ID" ABOVE "$MAX_TOKEN" true null 1
    alert_list "$exact" "$REPLY"
    respond 0 200 "$REPLY"
    untold 2 2 0
    unknown_end "two exact alerts for one create" "problems=[$REPLY] owned=[] resolved=[] lists=1 deletes=0 sleeps=[]"

    unknown_start "$MAX_TOKEN"
    alert_json "$a" TARGET_PRICE "$INSTRUMENT_ID" ABOVE "\"$MAX_TOKEN\"" true null 1
    alert_list "$REPLY"
    respond 0 200 "$REPLY"
    untold 1 0 0
    unknown_end "threshold as a string" "problems=[$REPLY] owned=[] resolved=[] lists=1 deletes=0 sleeps=[]"

    unknown_start "$MAX_TOKEN"
    alert_json "$a" TARGET_PRICE "$INSTRUMENT_ID" ABOVE "$MAX_TOKEN" true null 2
    alert_list "$REPLY"
    respond 0 200 "$REPLY"
    untold 1 0 0
    unknown_end "re-armed to revision 2" "problems=[$REPLY] owned=[] resolved=[] lists=1 deletes=0 sleeps=[]"

    unknown_start "$MAX_TOKEN"
    alert_json "$a" TARGET_PRICE "$INSTRUMENT_ID" ABOVE "$MAX_TOKEN" true null '"1"'
    alert_list "$REPLY"
    respond 0 200 "$REPLY"
    untold 1 0 0
    unknown_end "revision as a string" "problems=[$REPLY] owned=[] resolved=[] lists=1 deletes=0 sleeps=[]"

    while IFS='|' read -r row created; do
        unknown_start "$MAX_TOKEN"
        alert_json "$a" TARGET_PRICE "$INSTRUMENT_ID" ABOVE "$MAX_TOKEN" true '"2026-01-01T00:00:02Z"' 1 "$created"
        alert_list "$REPLY"
        respond 0 200 "$REPLY"
        untold 1 0 1
        unknown_end "triggered, $row" "problems=[$REPLY] owned=[] resolved=[] lists=1 deletes=0 sleeps=[]"
    done <<'EOF'
createdAt with another offset|"2026-01-01T01:00:01.25+01:00"
createdAt with offset -00:00|"2026-01-01T00:00:01.25-00:00"
createdAt without an offset|"2026-01-01T00:00:01.25"
createdAt with a ten-digit fraction|"2026-01-01T00:00:01.1234567890Z"
createdAt in month 13|"2026-13-01T00:00:01Z"
createdAt with a space for T|"2026-01-01 00:00:01Z"
createdAt as a number|1767225601
createdAt null|null
createdAt with markup|"<b>2026-01-01T00:00:01Z</b>"
EOF

    # Beside the create's alert and an alert made before the precondition, which is not counted,
    # a candidate made at or after the precondition that differs in threshold or revision still
    # leaves the create's alert one that cannot be told from others.
    while IFS='|' read -r row threshold revision created; do
        unknown_start "$MAX_TOKEN"
        alert_json "$old" TARGET_PRICE "$INSTRUMENT_ID" ABOVE "$MAX_TOKEN" false null 1 '"2026-01-01T00:00:00.4999999Z"'
        older="$REPLY"
        alert_json "$b" TARGET_PRICE "$INSTRUMENT_ID" ABOVE "$threshold" true null "$revision" "$created"
        alert_list "$older" "$REPLY" "$exact"
        respond 0 200 "$REPLY"
        untold 2 1 0
        unknown_end "beside an older alert, $row" "problems=[$REPLY] owned=[] resolved=[] lists=1 deletes=0 sleeps=[]"
    done <<EOF
another threshold, made at the precondition time|1|1|"2026-01-01T00:00:00.5+00:00"
revision 2, made at the precondition time|$MAX_TOKEN|2|"2026-01-01T00:00:00.500000000Z"
another threshold, made after the precondition|1|1|$CREATED_AFTER
EOF

    unknown_start "$MAX_TOKEN"
    PRECONDITION_AT=""
    unknown_end "precondition time unknown" \
        "problems=[the create of $UNKNOWN_DESC is unknown, was not reconciled: the time of the cycle precondition before it is unknown, so no alert can be shown to be its own] owned=[] resolved=[] lists=0 deletes=0 sleeps=[]"

    unknown_start "$MAX_TOKEN"
    respond 0 403 '{"error":"feature_disabled"}'
    unknown_end "list answers 403" \
        "problems=[the create of $UNKNOWN_DESC is unknown, was not reconciled: GET alerts of account [$ACCOUNT_ID] gave status 403] owned=[] resolved=[] lists=1 deletes=0 sleeps=[]"

    unknown_start "$MAX_TOKEN"
    respond 0 200 "{\"results\":[$exact,{\"id\":\"<b>x</b>\"}]}"
    unknown_end "list with an unreadable alert" \
        "problems=[the create of $UNKNOWN_DESC is unknown, was not reconciled: GET alerts of account [$ACCOUNT_ID] gave status 200, but its reply is not one JSON object with a results array of alerts with canonical ids] owned=[] resolved=[] lists=1 deletes=0 sleeps=[]"

    unknown_start "$MAX_TOKEN" BOGUS
    unknown_end "unreadable record" \
        "problems=[unknown create 1 in RUN/unknown-creates cannot be read, so it is not reconciled] owned=[] resolved=[] lists=0 deletes=0 sleeps=[]"
}

# With the flag off, cleanup switches it on to read the list, deletes the adopted alert by id
# and restores the flag.
cleanup_unknown_flag_off_case() {
    local a
    alert_id 7
    a="$REPLY"
    unknown_start "$MAX_TOKEN"
    : >"$STUB/responses"
    FLAG_INITIAL=false
    respond 0 200 "$FLAG_OFF"
    respond 0 200 "$FLAG_ON"
    alert_json "$a" TARGET_PRICE "$INSTRUMENT_ID" ABOVE "$MAX_TOKEN" true null 1
    alert_list "$REPLY"
    respond 0 200 "$REPLY"
    respond 0 204
    respond 0 200 "$FLAG_OFF"
    cleanup_all >"$TEST_OUT"
    expect_file "requests" "$STUB/requests" "GET $FLAG_ENDPOINT" "PUT $FLAG_ENDPOINT {\"enabled\": true}" \
        "GET $ALERTS_ENDPOINT?accountId=$ACCOUNT_ID" "DELETE $ALERTS_ENDPOINT/$a" \
        "PUT $FLAG_ENDPOINT {\"enabled\": false}"
    expect "problems" "" "$CLEANUP_PROBLEMS"
}

# ---------------------------------------------------------------------------------------------
# The run lock and run records

# THIS_HOST: this shell's host as the run lock records it, the host name and the system name.
THIS_HOST="$(uname -n) ($(uname -s))"
# The id of the first lock container the docker stub creates.
FIRST_LOCK_ID="c0ffee$(printf '%058d' 1)"
HELD_TEXT="run one perf.sh at a time per project, or run docker rm -v $LOCK_CONTAINER once that run has ended"
UNREADABLE_OWNER="project [unit-test] is locked by container $LOCK_CONTAINER, whose owner labels cannot be read; run docker rm -v $LOCK_CONTAINER once no perf.sh runs on this project"

# lock_owned_by PID HOST: another run's lock container, HELD_ID, held by PID on HOST for run
# directory $TEST_TMP/earlier-run since a fixed time.
lock_owned_by() {
    stub_lock "$HELD_ID" null "pi-perf.lock.pid=$1" "pi-perf.lock.host=$2" \
        "pi-perf.lock.started=2025-12-31T23:00:00Z" "pi-perf.lock.run-dir=$TEST_TMP/earlier-run"
}

# dead_pid: sets REPLY to the pid of a process that has ended.
dead_pid() {
    (exit 0) &
    REPLY=$!
    wait "$REPLY" || true
}

# docker_calls_of WORD: sets REPLY to the recorded docker calls whose first word is WORD, each
# followed by |.
docker_calls_of() {
    local all=() line
    REPLY=""
    mapfile -t all <"$STUB/docker.calls"
    for line in "${all[@]}"; do
        if [[ "$line" == "$1 "* ]]; then
            REPLY+="$line|"
        fi
    done
}

# lock_state: sets REPLY to the id of the lock container in place, or to none.
lock_state() {
    REPLY="none"
    if [[ -f "$STUB/lock.id" ]]; then
        REPLY="$(<"$STUB/lock.id")"
    fi
}

# expect_own_lock ROW ID: this run holds the lock container ID, the one in place, whose labels
# are the db image's Compose labels blanked and this run's owner labels.
expect_own_lock() {
    local labels want
    labels="$(jq -c '.Config.Labels' "$STUB/lock.json" | tr -d '\r')"
    want="$(MSYS_NO_PATHCONV=1 jq -cn --arg pid "$$" --arg host "$THIS_HOST" --arg run "$RUN_DIR" \
        '{"com.docker.compose.project": "", "com.docker.compose.service": "",
          "com.docker.compose.version": "", "pi-perf.lock.pid": $pid, "pi-perf.lock.host": $host,
          "pi-perf.lock.started": "2026-01-01T00:00:00Z", "pi-perf.lock.run-dir": $run}' | tr -d '\r')"
    lock_state
    expect "$1: lock" "held=1 id=$2 kept=$2 labels=$want" "held=$LOCK_HELD id=$LOCK_ID kept=$REPLY labels=$labels"
}

# A free name is taken by a container made from the db container's image, with the image's
# Compose labels blanked and this run's owner labels; every Docker call runs under the call
# limit, and the id it printed is the one this run keeps.
acquire_run_lock_free_case() {
    acquire_run_lock >"$TEST_OUT"
    exit_lines "$TEST_OUT"
    expect "verdict" "PASS run lock|" "$REPLY"
    expect_own_lock "free" "$FIRST_LOCK_ID"
    expect_file "docker calls" "$STUB/docker.calls" "$COMPOSE_PREFIX ps -q --status running db" \
        "inspect --type container --format {{.Image}} db0000000001" \
        "image inspect --format {{json .Config.Labels}} $DB_IMAGE" \
        "create --name $LOCK_CONTAINER --label com.docker.compose.project= --label com.docker.compose.service= --label com.docker.compose.version= --label pi-perf.lock.pid=$$ --label pi-perf.lock.host=$THIS_HOST --label pi-perf.lock.started=2026-01-01T00:00:00Z --label pi-perf.lock.run-dir=$RUN_DIR $DB_IMAGE"
    expect_file "call limits" "$STUB/timeouts" "-k 5 55" "-k 5 55" "-k 5 55" "-k 5 55"
}

# A lock whose owner ran on this host and no longer runs, or whose pid is this shell's under
# another run directory, is removed by its id, never by its name, and the create is tried once
# more.
acquire_run_lock_stale_case() {
    local dead
    dead_pid
    dead="$REPLY"
    lock_owned_by "$dead" "$THIS_HOST"
    acquire_run_lock >"$TEST_OUT"
    slurp "$TEST_OUT"
    expect "owner ended: output" \
        "INFO run lock: removing the lock container $HELD_ID of pid $dead (run dir $TEST_TMP/earlier-run), which no longer runs"$'\n'"PASS run lock" \
        "$REPLY"
    expect_own_lock "owner ended" "$FIRST_LOCK_ID"
    docker_calls_of rm
    expect "owner ended: removals" "rm -v $HELD_ID|" "$REPLY"

    fresh_state
    lock_owned_by "$$" "$THIS_HOST"
    acquire_run_lock >"$TEST_OUT"
    expect_own_lock "this shell's pid under another run directory" "$FIRST_LOCK_ID"
}

# lock_refused_row ROW REASON: acquire_run_lock aborts the run as "run lock" with REASON before
# anything is changed: no request and no removal, and the lock as it was.
lock_refused_row() {
    local status=0 before="" after="" removals requests
    if [[ -f "$STUB/lock.json" ]]; then
        before="$(<"$STUB/lock.json")"
    fi
    (acquire_run_lock) >"$TEST_OUT" 2>&1 || status=$?
    if [[ -f "$STUB/lock.json" ]]; then
        after="$(<"$STUB/lock.json")"
    fi
    docker_calls_of rm
    removals="$REPLY"
    count_lines "$STUB/requests"
    requests="$REPLY"
    exit_lines "$TEST_OUT"
    expect "$1" "status=1 FAIL run lock: $2|PASS cleanup|SUMMARY 1 passed, 1 failed|" "status=$status $REPLY"
    expect "$1: removals, requests and lock" "rm=[] requests=0 lock=[$before]" \
        "rm=[$removals] requests=$requests lock=[$after]"
}

# A lock held by a live run on this host, by a run on another host or system, or with owner
# labels that cannot be read, and a state directory that cannot be made, refuse the run without
# touching the lock.
acquire_run_lock_refused_case() {
    local live dead other_system
    local held="since 2025-12-31T23:00:00Z (run dir $TEST_TMP/earlier-run); $HELD_TEXT"
    other_system="$(uname -n) (other-system)"
    command sleep 60 &
    live=$!
    lock_owned_by "$live" "$THIS_HOST"
    lock_refused_row "live owner" "project [unit-test] is locked by pid $live on host $THIS_HOST $held"
    kill "$live"
    wait "$live" 2>/dev/null || true

    fresh_state
    dead_pid
    dead="$REPLY"
    lock_owned_by "$dead" "other-host"
    lock_refused_row "owner on another host" "project [unit-test] is locked by pid $dead on host other-host $held"

    fresh_state
    lock_owned_by "$dead" "$other_system"
    lock_refused_row "owner on this host name under another system" \
        "project [unit-test] is locked by pid $dead on host $other_system $held"

    fresh_state
    stub_lock "$HELD_ID" null
    lock_refused_row "no owner labels" "$UNREADABLE_OWNER"

    fresh_state
    stub_lock "$HELD_ID" null "pi-perf.lock.pid=$dead"$'\n' "pi-perf.lock.host=$THIS_HOST" \
        "pi-perf.lock.run-dir=$TEST_TMP/earlier-run"
    lock_refused_row "pid with a trailing line feed" "$UNREADABLE_OWNER"

    fresh_state
    stub_lock "$HELD_ID" null "pi-perf.lock.pid=$dead" "pi-perf.lock.host=$THIS_HOST"
    lock_refused_row "no run directory label" "$UNREADABLE_OWNER"

    fresh_state
    lock_owned_by "$dead" "$THIS_HOST"
    echo '{"Id":"not-a-container-id","Config":{"Labels":{}}}' >"$STUB/lock.json"
    lock_refused_row "id that is not a container id" "$UNREADABLE_OWNER"

    fresh_state
    : >"$STATE_DIR"
    lock_refused_row "state directory taken by a file" "state directory $STATE_DIR could not be made as this user's own"
}

# Once the stale lock is removed, another run takes the name before this run's second create:
# the run is refused, naming that run, and neither its lock nor any other is removed again, even
# one that looks stale.
acquire_run_lock_conflict_after_stale_case() {
    local dead status=0 removals creates
    dead_pid
    dead="$REPLY"
    lock_owned_by "$dead" "$THIS_HOST"
    STUB_RESPAWN="4242 other-host"
    (acquire_run_lock) >"$TEST_OUT" 2>&1 || status=$?
    docker_calls_of rm
    removals="$REPLY"
    docker_calls_of create
    creates="${REPLY//[!|]/}"
    lock_state
    expect "live run took the name" "status=1 rm=[rm -v $HELD_ID|] creates=2 lock=$RESPAWN_ID" \
        "status=$status rm=[$removals] creates=${#creates} lock=$REPLY"
    exit_lines "$TEST_OUT"
    expect "live run took the name: verdicts" \
        "FAIL run lock: project [unit-test] is locked by pid 4242 on host other-host since 2026-01-01T00:00:05Z (run dir $TEST_TMP/respawned-run); $HELD_TEXT|PASS cleanup|SUMMARY 1 passed, 1 failed|" \
        "$REPLY"

    fresh_state
    status=0
    lock_owned_by "$dead" "$THIS_HOST"
    STUB_RESPAWN="$dead $THIS_HOST"
    (acquire_run_lock) >"$TEST_OUT" 2>&1 || status=$?
    docker_calls_of rm
    removals="$REPLY"
    lock_state
    expect "stale-looking run took the name" "status=1 rm=[rm -v $HELD_ID|] lock=$RESPAWN_ID" \
        "status=$status rm=[$removals] lock=$REPLY"
}

# lock_problem_row ROW REASON REMOVALS LOCK: acquire_run_lock aborts the run as "run lock" with
# REASON, having sent no request and stopped nothing; REMOVALS are its docker rm calls, each
# followed by |, and LOCK the lock container left in place, or none.
lock_problem_row() {
    local status=0 removals requests stops lock
    (acquire_run_lock) >"$TEST_OUT" 2>&1 || status=$?
    docker_calls_of rm
    removals="$REPLY"
    count_lines "$STUB/requests"
    requests="$REPLY"
    stops="$(grep -c " stop " "$STUB/docker.calls" || true)"
    lock_state
    lock="$REPLY"
    exit_lines "$TEST_OUT"
    expect "$1" "status=1 FAIL run lock: $2|PASS cleanup|SUMMARY 1 passed, 1 failed| requests=0 stops=0 rm=[$3] lock=$4" \
        "status=$status $REPLY requests=$requests stops=$stops rm=[$removals] lock=$lock"
}

# A Docker call that does not answer in time or fails aborts the run before anything is
# changed. A create cut off after the engine made the container leaves this run's container,
# which the abort removes by its id.
acquire_run_lock_docker_problem_case() {
    local dead limit="timed out after 60 s (Docker did not answer)"
    STUB_TIMEOUT_RC=124
    STUB_TIMEOUT_ON="ps"
    lock_problem_row "db lookup cut off" "compose ps db $limit" "" none

    fresh_state
    STUB_TIMEOUT_RC=137
    STUB_TIMEOUT_ON="--type"
    lock_problem_row "db container inspect cut off" "docker inspect of the db container $limit" "" none

    fresh_state
    STUB_TIMEOUT_RC=124
    STUB_TIMEOUT_ON="image"
    lock_problem_row "db image inspect cut off" "docker image inspect of the db image $limit" "" none

    fresh_state
    STUB_IMAGE_LABELS='["not", "an", "object"]'
    lock_problem_row "db image labels unreadable" "the labels of the db image cannot be read" "" none

    fresh_state
    STUB_DB_CID="--rm"
    lock_problem_row "db lookup prints no container id" "compose ps db printed no container id" "" none

    fresh_state
    STUB_DB_IMAGE="-v"
    lock_problem_row "db image not an image reference" "the db container's image cannot be read" "" none

    fresh_state
    STUB_CREATE_RC=1
    lock_problem_row "create fails" "docker create $LOCK_CONTAINER failed, exit 1 (see RUN/compose.log)" "" none

    fresh_state
    STUB_TIMEOUT_RC=124
    STUB_TIMEOUT_ON="create"
    lock_problem_row "create cut off after the engine made the container" \
        "docker create $LOCK_CONTAINER $limit" "rm -v $FIRST_LOCK_ID|" none

    fresh_state
    STUB_CREATE_PRINTS="WARNING: no id"
    lock_problem_row "create prints no id after the engine made the container" \
        "docker create $LOCK_CONTAINER printed no container id" "rm -v $FIRST_LOCK_ID|" none

    fresh_state
    dead_pid
    dead="$REPLY"
    lock_owned_by "$dead" "$THIS_HOST"
    STUB_RM_RC=1
    lock_problem_row "stale lock removal fails" \
        "the stale lock container $HELD_ID was not removed: docker rm $HELD_ID failed, exit 1 (see RUN/compose.log)" \
        "rm -v $HELD_ID|" "$HELD_ID"
}

# release_row ROW EXPECTED: release_run_lock, from a fresh call record; EXPECTED is its docker
# calls, the lock left in place and its output.
release_row() {
    local calls lock
    : >"$STUB/docker.calls"
    release_run_lock >"$TEST_OUT"
    slurp "$STUB/docker.calls"
    calls="$REPLY"
    lock_state
    lock="$REPLY"
    slurp "$TEST_OUT"
    expect "$1" "$2" "held=$LOCK_HELD calls=[$calls] lock=$lock output=[${REPLY//$RUN_DIR/RUN}]"
}

# The release removes, by its id, the lock container this run made, and never the container
# that holds the name after it; a removal that fails is reported and not failed, and a lock
# never held makes no Docker call.
release_run_lock_case() {
    acquire_run_lock >"$TEST_OUT"
    release_row "own lock" "held=0 calls=[rm -v $FIRST_LOCK_ID] lock=none output=[]"

    fresh_state
    acquire_run_lock >"$TEST_OUT"
    rm -f "$STUB/lock.id" "$STUB/lock.json"
    lock_owned_by 4242 "other-host"
    release_row "another run's lock under the name" \
        "held=0 calls=[rm -v $FIRST_LOCK_ID] lock=$HELD_ID output=[INFO run lock: lock container $FIRST_LOCK_ID not removed: docker rm $FIRST_LOCK_ID failed, exit 1 (see RUN/compose.log); the next run on this host reclaims it, or run docker rm -v $FIRST_LOCK_ID]"

    fresh_state
    acquire_run_lock >"$TEST_OUT"
    STUB_RM_RC=1
    release_row "removal fails" \
        "held=0 calls=[rm -v $FIRST_LOCK_ID] lock=$FIRST_LOCK_ID output=[INFO run lock: lock container $FIRST_LOCK_ID not removed: docker rm $FIRST_LOCK_ID failed, exit 1 (see RUN/compose.log); the next run on this host reclaims it, or run docker rm -v $FIRST_LOCK_ID]"

    fresh_state
    acquire_run_lock >"$TEST_OUT"
    STUB_RM_RC=1
    STUB_TIMEOUT_RC=137
    STUB_TIMEOUT_ON="rm"
    release_row "removal cut off" \
        "held=0 calls=[rm -v $FIRST_LOCK_ID] lock=$FIRST_LOCK_ID output=[INFO run lock: lock container $FIRST_LOCK_ID not removed: docker rm $FIRST_LOCK_ID timed out after 60 s (Docker did not answer); the next run on this host reclaims it, or run docker rm -v $FIRST_LOCK_ID]"

    fresh_state
    lock_owned_by 4242 "other-host"
    release_row "lock never held" "held=0 calls=[] lock=$HELD_ID output=[]"
}

# The run record is written at start, removed by a cleanup that deletes every owned alert, and
# kept, named in the cleanup problem, while any is left in place.
run_record_case() {
    acquire_run_lock >"$TEST_OUT"
    record_run
    expect_file "record" "$STATE_DIR/runs/${RUN_DIR##*/}" "$RUN_DIR" "http://localhost" "$COMPOSE_PATH"
    cleanup_all >"$TEST_OUT"
    expect "nothing left" "record=gone RUN_RECORD=[]" \
        "record=$([[ -e "$STATE_DIR/runs/${RUN_DIR##*/}" ]] && echo kept || echo gone) RUN_RECORD=[$RUN_RECORD]"

    fresh_state
    acquire_run_lock >"$TEST_OUT"
    record_run
    own 1
    respond 0 200 "$FLAG_ON"
    respond 0 400 '{"error":"invalid"}'
    cleanup_all >"$TEST_OUT"
    expect "an alert left in place" \
        "record=kept problems=[1 owned alerts left in place, ids in RUN/left-in-place; the next run on project [unit-test] with base url http://localhost and compose file $COMPOSE_PATH deletes them first]" \
        "record=$([[ -f "$STATE_DIR/runs/${RUN_DIR##*/}" ]] && echo kept || echo gone) problems=[${CLEANUP_PROBLEMS//$RUN_DIR/RUN}]"
}

# earlier_run NAME URL COMPOSE OWNED DELETED: an earlier run's directory pi-perf.NAME under
# $TEST_TMP/earlier, whose owned and deleted files hold OWNED and DELETED (space-separated), and
# its record, naming URL and COMPOSE. Sets REPLY to the record's path.
earlier_run() {
    local dir="$TEST_TMP/earlier/pi-perf.$1" line
    mkdir -p "$dir" "$STATE_DIR/runs"
    : >"$dir/owned"
    : >"$dir/deleted"
    for line in $4; do
        echo "$line" >>"$dir/owned"
    done
    for line in $5; do
        echo "$line" >>"$dir/deleted"
    done
    printf '%s\n%s\n%s\n' "$dir" "$2" "$3" >"$STATE_DIR/runs/pi-perf.$1"
    REPLY="$STATE_DIR/runs/pi-perf.$1"
}

# The owned ids an earlier run on the project left undeleted, canonical UUIDs only, are adopted
# and its record removed; this run's own record is not read.
adopt_earlier_runs_case() {
    local a b c record
    alert_id 1
    a="$REPLY"
    alert_id 2
    b="$REPLY"
    alert_id 3
    c="$REPLY"
    acquire_run_lock >"$TEST_OUT"
    record_run
    earlier_run a1 "http://localhost" "$COMPOSE_PATH" "$c $a $b not-an-id ${a^^} $a" "$b"
    record="$REPLY"
    adopt_earlier_runs >"$TEST_OUT"
    expect_file "owned" "$RUN_DIR/owned" "$a" "$c"
    expect_file "recovered" "$RUN_DIR/recovered" "$a" "$c"
    expect "records" "earlier=gone own=kept" \
        "earlier=$([[ -e "$record" ]] && echo kept || echo gone) own=$([[ -f "$RUN_RECORD" ]] && echo kept || echo gone)"
    expect_file "output" "$TEST_OUT" \
        "INFO recovery: adopted 2 owned alert ids that run dir $TEST_TMP/earlier/pi-perf.a1 left undeleted"
}

# adopt_refused_row ROW REASON: adopt_earlier_runs aborts the run as "recovery" with REASON
# before anything is changed: nothing is adopted and every record stays.
adopt_refused_row() {
    local status=0 records
    records="$(ls "$STATE_DIR/runs")"
    (adopt_earlier_runs) >"$TEST_OUT" 2>&1 || status=$?
    exit_lines "$TEST_OUT"
    expect "$1" "status=1 FAIL recovery: $2|PASS cleanup|SUMMARY 1 passed, 1 failed|" "status=$status $REPLY"
    expect "$1: owned and records" "owned=[] records=[$records]" \
        "owned=[$(<"$RUN_DIR/owned")] records=[$(ls "$STATE_DIR/runs")]"
}

adopt_earlier_runs_refused_case() {
    local a record dir="$TEST_TMP/earlier/pi-perf"
    alert_id 1
    a="$REPLY"
    earlier_run a1 "http://other.example:8080" "$COMPOSE_PATH" "$a" ""
    adopt_refused_row "another base url" \
        "run dir $dir.a1 of an earlier run on project [unit-test] may hold alerts created through base url http://other.example:8080 with compose file $COMPOSE_PATH; this run uses http://localhost with $COMPOSE_PATH, so it changes nothing. Run perf.sh with that run's base url and compose file to delete them, or remove $REPLY once they are gone"

    fresh_state
    earlier_run a1 "http://localhost" "$COMPOSE_PATH" "$a" ""
    earlier_run b1 "http://localhost" "/elsewhere/compose.yaml" "$a" ""
    record="$REPLY"
    adopt_refused_row "a matching record and one with another compose file" \
        "run dir $dir.b1 of an earlier run on project [unit-test] may hold alerts created through base url http://localhost with compose file /elsewhere/compose.yaml; this run uses http://localhost with $COMPOSE_PATH, so it changes nothing. Run perf.sh with that run's base url and compose file to delete them, or remove $record once they are gone"

    fresh_state
    earlier_run a1 "http://localhost" "$COMPOSE_PATH" "$a" ""
    printf '%s\n%s\n' "$dir.a1" "http://localhost" >"$REPLY"
    adopt_refused_row "record with two lines" \
        "the record $REPLY of an earlier run on project [unit-test] cannot be read; remove it once no alert of that run remains"

    fresh_state
    earlier_run a1 "http://localhost" "$COMPOSE_PATH" "$a" ""
    mv "$REPLY" "$STATE_DIR/runs/pi-perf.other"
    adopt_refused_row "record named after another run directory" \
        "the record $STATE_DIR/runs/pi-perf.other of an earlier run on project [unit-test] cannot be read; remove it once no alert of that run remains"

    fresh_state
    earlier_run a1 "http://localhost" "$COMPOSE_PATH" "$a" ""
    rm -rf "$dir.a1"
    adopt_refused_row "run directory gone" \
        "run dir $dir.a1, recorded by an earlier run on project [unit-test], no longer exists, so the alerts it may hold cannot be deleted by id; remove $REPLY once they are gone"

    # An earlier run's open unknown creates that cannot be read, or that lack the precondition
    # time they are matched by, refuse adoption before anything changes or is carried; so does
    # its in-flight create alone, since a create is only made after the precondition passed.
    local row
    for row in "no precondition time" "precondition time on two lines" \
        "precondition time with an offset" "unknown create of another type" \
        "unknown create led by no second" "carried create led by a local time" \
        "in-flight create without a precondition time" "in-flight create on two lines" \
        "in-flight create led by no count"; do
        fresh_state
        earlier_run a1 "http://localhost" "$COMPOSE_PATH" "$a" ""
        record="$REPLY"
        printf '0\t%s\tTARGET_PRICE\t%s\tABOVE\t1\n' "$ACCOUNT_ID" "$INSTRUMENT_ID" >"$dir.a1/unknown-creates"
        echo "2026-01-01T00:00:00.5Z" >"$dir.a1/precondition-at"
        case "$row" in
            "no precondition time") rm "$dir.a1/precondition-at" ;;
            "precondition time on two lines") echo "2026-01-01T00:00:01Z" >>"$dir.a1/precondition-at" ;;
            "precondition time with an offset") echo "2026-01-01T01:00:00.5+01:00" >"$dir.a1/precondition-at" ;;
            "unknown create of another type")
                printf '0\t%s\tBOGUS\t%s\tABOVE\t1\n' "$ACCOUNT_ID" "$INSTRUMENT_ID" >"$dir.a1/unknown-creates"
                ;;
            "unknown create led by no second")
                printf 'x\t%s\tTARGET_PRICE\t%s\tABOVE\t1\n' "$ACCOUNT_ID" "$INSTRUMENT_ID" >"$dir.a1/unknown-creates"
                ;;
            "carried create led by a local time")
                echo 1 >"$dir.a1/unknown-resolved"
                printf '2026-01-01T00:00:00\t%s\tTARGET_PRICE\t%s\tABOVE\t1\n' "$ACCOUNT_ID" "$INSTRUMENT_ID" \
                    >"$dir.a1/carried-creates"
                ;;
            "in-flight create without a precondition time")
                mv "$dir.a1/unknown-creates" "$dir.a1/in-flight-create"
                rm "$dir.a1/precondition-at"
                ;;
            "in-flight create on two lines")
                mv "$dir.a1/unknown-creates" "$dir.a1/in-flight-create"
                printf '0\t%s\tTARGET_PRICE\t%s\tABOVE\t1\n' "$ACCOUNT_ID" "$INSTRUMENT_ID" >>"$dir.a1/in-flight-create"
                ;;
            "in-flight create led by no count")
                rm "$dir.a1/unknown-creates"
                printf 'x\t%s\tTARGET_PRICE\t%s\tABOVE\t1\n' "$ACCOUNT_ID" "$INSTRUMENT_ID" >"$dir.a1/in-flight-create"
                ;;
        esac
        adopt_refused_row "$row" \
            "run dir $dir.a1 of an earlier run on project [unit-test] lists creates whose outcome is unknown that cannot be read, or lacks the precondition time they are matched by, so their alerts cannot be told from others; remove $record once no alert of that run remains"
        expect "$row: carried" "none" "$([[ -e "$RUN_DIR/carried-creates" ]] && echo some || echo none)"
    done
}

# carried_line PRECONDITION [THRESHOLD]: sets REPLY to the carried line of a create of the
# fixture account, TARGET_PRICE ABOVE THRESHOLD (the domain maximum by default) on the fixture
# instrument, made by a run whose cycle precondition passed at PRECONDITION.
carried_line() {
    printf -v REPLY '%s\t%s\tTARGET_PRICE\t%s\tABOVE\t%s' "$1" "$ACCOUNT_ID" "$INSTRUMENT_ID" "${2:-$MAX_TOKEN}"
}

# An earlier run's creates whose outcome it left unknown are carried into this run with that
# run's precondition time: its own open unknown creates, led by its precondition-at instead of
# the second their POST ended, then the open lines it had carried itself. Reconciled lines are
# neither read nor carried, an unreadable one included, and the earlier record is removed, since
# this run's record now stands for them.
adopt_earlier_runs_carried_case() {
    local dir="$TEST_TMP/earlier/pi-perf.a1" record pre="2026-11-26T01:49:38.1518570Z" first third
    mkdir -p "$STATE_DIR/runs"
    record_run
    earlier_run a1 "http://localhost" "$COMPOSE_PATH" "" ""
    record="$REPLY"
    {
        printf '12\t%s\tTARGET_PRICE\t%s\tABOVE\t%s\n' "$ACCOUNT_ID" "$INSTRUMENT_ID" "$MAX_TOKEN"
        printf '13\t%s\tBOGUS\t%s\tABOVE\t1.5\n' "$ACCOUNT_ID" "$INSTRUMENT_ID"
        printf '14\t%s\tPROFIT_LOSS\t%s\tABOVE\t1.500\n' "$ACCOUNT_ID" "$INSTRUMENT_ID"
    } >"$dir/unknown-creates"
    echo 2 >"$dir/unknown-resolved"
    echo "$pre" >"$dir/precondition-at"
    carried_line "2026-11-24T00:00:00Z" 7
    echo "$REPLY" >"$dir/carried-creates"
    carried_line "2026-11-25T10:00:00.5+00:00"
    echo "$REPLY" >>"$dir/carried-creates"
    echo 1 >"$dir/carried-resolved"
    adopt_earlier_runs >"$TEST_OUT"
    printf -v first '%s\t%s\tTARGET_PRICE\t%s\tABOVE\t%s' "$pre" "$ACCOUNT_ID" "$INSTRUMENT_ID" "$MAX_TOKEN"
    printf -v third '%s\t%s\tPROFIT_LOSS\t%s\tABOVE\t1.500' "$pre" "$ACCOUNT_ID" "$INSTRUMENT_ID"
    expect_file "carried" "$RUN_DIR/carried-creates" "$first" "$third" "$REPLY"
    expect "records" "earlier=gone own=kept" \
        "earlier=$([[ -e "$record" ]] && echo kept || echo gone) own=$([[ -f "$RUN_RECORD" ]] && echo kept || echo gone)"
    expect_file "output" "$TEST_OUT" \
        "INFO recovery: adopted 0 owned alert ids that run dir $dir left undeleted" \
        "INFO recovery: carried 3 creates whose outcome run dir $dir left unknown"
}

# The adopted alerts are deleted by id as the "recovery" check; one left in place aborts the
# run, stays owned for cleanup and keeps the run record.
recover_earlier_alerts_case() {
    local a b status=0 note
    alert_id 1
    a="$REPLY"
    alert_id 2
    b="$REPLY"
    recover_earlier_alerts >"$TEST_OUT"
    count_lines "$STUB/requests"
    expect "nothing adopted" "requests=0 output=[]" "requests=$REPLY output=[$(<"$TEST_OUT")]"

    fresh_state
    own 1 2
    printf '%s\n' "$a" "$b" >"$RUN_DIR/recovered"
    respond 0 204
    respond 0 404 '{"error":"not_found"}'
    recover_earlier_alerts >"$TEST_OUT"
    exit_lines "$TEST_OUT"
    expect "deleted" "PASS recovery|" "$REPLY"
    expect_file "deleted requests" "$STUB/requests" "DELETE $ALERTS_ENDPOINT/$a" "DELETE $ALERTS_ENDPOINT/$b"

    fresh_state
    acquire_run_lock >"$TEST_OUT"
    record_run
    passed=0
    own 1
    echo "$a" >"$RUN_DIR/recovered"
    respond 0 400 '{"error":"invalid"}'
    respond 0 200 "$FLAG_ON"
    respond 0 400 '{"error":"invalid"}'
    (recover_earlier_alerts) >"$TEST_OUT" 2>&1 || status=$?
    exit_lines "$TEST_OUT"
    note="1 owned alerts left in place, ids in RUN/left-in-place; the next run on project [unit-test] with base url http://localhost and compose file $COMPOSE_PATH deletes them first"
    expect "left in place" "status=1 FAIL recovery: $note|FAIL cleanup: $note|SUMMARY 0 passed, 2 failed|" \
        "status=$status $REPLY"
    expect "left in place: record" "kept" "$([[ -f "$STATE_DIR/runs/${RUN_DIR##*/}" ]] && echo kept || echo gone)"
}

# carried_start ADOPTED: this run's record, one create carried from an earlier run whose cycle
# precondition passed at PRECONDITION_FIXTURE and, with ADOPTED 1, adopted alert 1.
carried_start() {
    fresh_state
    mkdir -p "$STATE_DIR/runs"
    record_run
    carried_line "$PRECONDITION_FIXTURE"
    echo "$REPLY" >"$RUN_DIR/carried-creates"
    if [[ "$1" -eq 1 ]]; then
        own 1
        alert_id 1
        echo "$REPLY" >"$RUN_DIR/recovered"
    fi
}

# handed_on COUNT [FILES]: sets REPLY to the cleanup problem of COUNT creates left unreconciled,
# which keep this run's record, with the run directory written as RUN. FILES names this run's
# files that hold them, unknown-creates by default.
handed_on() {
    REPLY="$1 creates whose outcome is unknown are not reconciled (lines of RUN/${2:-unknown-creates} and carried-creates); the next run on project [unit-test] with base url http://localhost and compose file $COMPOSE_PATH looks for their alerts first, and $STATE_DIR/runs/${RUN_DIR##*/} can be removed by hand once those alerts are known to be gone"
}

# Carried creates are reconciled before the adopted alerts are deleted, on the same evidence as
# this run's own: an alert that shows it joins the owned set and is deleted by id, and with no
# such alert the create made none, since its settle deadline passed with its run, so the list is
# read once. A create whose alert cannot be told from others, or whose list cannot be read,
# aborts recovery with nothing deleted for it; cleanup looks for it again, and the run record
# stays for the next run, naming it.
recover_carried_case() {
    local a f status=0 note handed k row lists=() rows=()
    alert_id 1
    a="$REPLY"
    alert_id 7
    f="$REPLY"

    carried_start 1
    alert_json "$f" TARGET_PRICE "$INSTRUMENT_ID" ABOVE "$MAX_TOKEN" true '"2026-01-01T00:00:03Z"' 1
    alert_list "$REPLY"
    respond 0 200 "$REPLY"
    respond 0 204
    respond 0 204
    recover_earlier_alerts >"$TEST_OUT"
    exit_lines "$TEST_OUT"
    expect "found" "PASS recovery|" "$REPLY"
    expect_file "found: requests" "$STUB/requests" "GET $ALERTS_ENDPOINT?accountId=$ACCOUNT_ID" \
        "DELETE $ALERTS_ENDPOINT/$a" "DELETE $ALERTS_ENDPOINT/$f"
    expect_file "found: resolved" "$RUN_DIR/carried-resolved" 1
    slurp "$TEST_OUT"
    if [[ "$REPLY" != *"INFO recovery: alert [$f] is the create of $UNKNOWN_DESC was unknown; it is deleted as an owned alert"* ]]; then
        case_reasons+=("found: the output lacks the adoption line: $REPLY")
    fi

    # An alert made before that run's precondition is no candidate, so beside one, as with none,
    # the create made no alert and the older alert gets no DELETE.
    alert_json "$f" TARGET_PRICE "$INSTRUMENT_ID" ABOVE "$MAX_TOKEN" true null 1 '"2026-01-01T00:00:00Z"'
    alert_list "$REPLY"
    lists=('{"results":[]}' "$REPLY")
    rows=("made no alert" "made no alert beside an alert made before the precondition")
    for k in 0 1; do
        row="${rows[k]}"
        carried_start 1
        respond 0 200 "${lists[k]}"
        respond 0 204
        recover_earlier_alerts >"$TEST_OUT"
        exit_lines "$TEST_OUT"
        expect "$row" "PASS recovery|" "$REPLY"
        expect_file "$row: requests" "$STUB/requests" "GET $ALERTS_ENDPOINT?accountId=$ACCOUNT_ID" \
            "DELETE $ALERTS_ENDPOINT/$a"
        expect_file "$row: resolved" "$RUN_DIR/carried-resolved" 1
        count_lines "$STUB/sleeps"
        expect "$row: sleeps" 0 "$REPLY"
        slurp "$TEST_OUT"
        if [[ "$REPLY" != *"INFO recovery: 1 create(s) of TARGET_PRICE ABOVE $MAX_TOKEN on instrument [$INSTRUMENT_ID] for account [$ACCOUNT_ID], whose outcome an earlier run did not know, made no alert"* ]]; then
            case_reasons+=("$row: the output lacks the not-created line: $REPLY")
        fi
    done

    carried_start 0
    respond 0 200 '{"results":[]}'
    recover_earlier_alerts >"$TEST_OUT"
    exit_lines "$TEST_OUT"
    expect "only a carried create" "PASS recovery|" "$REPLY"
    count_lines "$STUB/requests"
    expect "only a carried create: requests" 1 "$REPLY"

    carried_start 1
    alert_json "$f" TARGET_PRICE "$INSTRUMENT_ID" ABOVE "$MAX_TOKEN" true null 2
    alert_list "$REPLY"
    respond 0 200 "$REPLY"
    respond 0 200 "$FLAG_ON"
    respond 0 200 "$REPLY"
    respond 0 204
    status=0
    (recover_earlier_alerts) >"$TEST_OUT" 2>&1 || status=$?
    untold 1 0 0
    note="$REPLY"
    handed_on 1
    handed="$REPLY"
    exit_lines "$TEST_OUT"
    expect "re-armed after the precondition" \
        "status=1 FAIL recovery: $note|FAIL cleanup: $note; $handed|SUMMARY 0 passed, 2 failed|" \
        "status=$status $REPLY"
    expect_file "re-armed after the precondition: requests" "$STUB/requests" \
        "GET $ALERTS_ENDPOINT?accountId=$ACCOUNT_ID" "GET $FLAG_ENDPOINT" \
        "GET $ALERTS_ENDPOINT?accountId=$ACCOUNT_ID" "DELETE $ALERTS_ENDPOINT/$a"
    expect "re-armed after the precondition: record and resolved" "record=kept resolved=none" \
        "record=$([[ -f "$STATE_DIR/runs/${RUN_DIR##*/}" ]] && echo kept || echo gone) resolved=$([[ -e "$RUN_DIR/carried-resolved" ]] && echo some || echo none)"

    carried_start 1
    respond 0 503 '{"error":"unavailable"}'
    respond 0 200 "$FLAG_ON"
    respond 0 503 '{"error":"unavailable"}'
    respond 0 204
    status=0
    (recover_earlier_alerts) >"$TEST_OUT" 2>&1 || status=$?
    note="the create of $UNKNOWN_DESC is unknown, was not reconciled: GET alerts of account [$ACCOUNT_ID] gave status 503"
    handed_on 1
    handed="$REPLY"
    exit_lines "$TEST_OUT"
    expect "list unreadable" "status=1 FAIL recovery: $note|FAIL cleanup: $note; $handed|SUMMARY 0 passed, 2 failed|" \
        "status=$status $REPLY"
    count_lines "$STUB/requests"
    expect "list unreadable: requests" 4 "$REPLY"
}

# A run that ends before recovery reconciles its carried creates in cleanup, deletes the alert
# found by id, and then drops its record, since nothing is left for the next run. A carried line
# that cannot be read keeps the record.
cleanup_carried_case() {
    local f
    alert_id 7
    f="$REPLY"
    carried_start 0
    respond 0 200 "$FLAG_ON"
    alert_json "$f" TARGET_PRICE "$INSTRUMENT_ID" ABOVE "$MAX_TOKEN" true null 1
    alert_list "$REPLY"
    respond 0 200 "$REPLY"
    respond 0 204
    cleanup_all >"$TEST_OUT"
    expect_file "requests" "$STUB/requests" "GET $FLAG_ENDPOINT" "GET $ALERTS_ENDPOINT?accountId=$ACCOUNT_ID" \
        "DELETE $ALERTS_ENDPOINT/$f"
    expect "problems, resolved and record" "problems=[] resolved=[1] record=gone" \
        "problems=[$CLEANUP_PROBLEMS] resolved=[$(<"$RUN_DIR/carried-resolved")] record=$([[ -e "$STATE_DIR/runs/${RUN_DIR##*/}" ]] && echo kept || echo gone)"

    # A carried line that cannot be read is not reconciled: no list is read for it, and the
    # record stays for it.
    carried_start 0
    printf '2026-01-01T00:00:00\t%s\tTARGET_PRICE\t%s\tABOVE\t1\n' "$ACCOUNT_ID" "$INSTRUMENT_ID" \
        >"$RUN_DIR/carried-creates"
    respond 0 200 "$FLAG_ON"
    cleanup_all >"$TEST_OUT"
    handed_on 1
    expect "unreadable carried line" \
        "problems=[unknown create 1 in RUN/carried-creates cannot be read, so it is not reconciled; $REPLY] requests=1 record=kept" \
        "problems=[${CLEANUP_PROBLEMS//$RUN_DIR/RUN}] requests=$(($(wc -l <"$STUB/requests"))) record=$([[ -e "$STATE_DIR/runs/${RUN_DIR##*/}" ]] && echo kept || echo gone)"
}

# in_flight_line FIRST [TYPE]: sets REPLY to the line of a create of the fixture account, TYPE
# (TARGET_PRICE by default) ABOVE the domain maximum on the fixture instrument, led by FIRST.
in_flight_line() {
    printf -v REPLY '%s\t%s\t%s\t%s\tABOVE\t%s' "$1" "$ACCOUNT_ID" "${2:-TARGET_PRICE}" "$INSTRUMENT_ID" "$MAX_TOKEN"
}

# The create a killed run left in in-flight-create is carried once, led by that run's
# precondition time, after the open unknown creates of that run: not at all when that run
# recorded it in unknown-creates already, which then holds more lines than the count leading it.
# The carried creates are looked for until 45 s after adoption.
adopt_in_flight_case() {
    local dir="$TEST_TMP/earlier/pi-perf.a1" row unknown resolved lead want settle status seen
    local pre="2026-11-26T01:49:38.1518570Z" earlier flight carried
    # The in-flight create is PROFIT_LOSS; an earlier unknown create of that run is TARGET_PRICE.
    in_flight_line "$pre" PROFIT_LOSS
    flight="$REPLY"
    in_flight_line "$pre"
    earlier="$REPLY"
    while IFS='|' read -r row unknown resolved lead want; do
        fresh_state
        mkdir -p "$STATE_DIR/runs"
        record_run
        earlier_run a1 "http://localhost" "$COMPOSE_PATH" "" ""
        echo "$pre" >"$dir/precondition-at"
        case "$unknown" in
            earlier) in_flight_line 12 ;;
            same) in_flight_line 12 PROFIT_LOSS ;;
        esac
        if [[ "$unknown" != "none" ]]; then
            echo "$REPLY" >"$dir/unknown-creates"
        fi
        if [[ "$resolved" -eq 1 ]]; then
            echo 1 >"$dir/unknown-resolved"
            rm "$dir/precondition-at"
        fi
        in_flight_line "$lead" PROFIT_LOSS
        echo "$REPLY" >"$dir/in-flight-create"
        # A refused adoption ends its shell through finish, so it runs in a subshell that prints
        # the settle deadline it set.
        status=0
        seen="$(
            adopt_earlier_runs >"$TEST_OUT" 2>&1
            echo "$CARRIED_SETTLE_UNTIL"
        )" || status=$?
        carried=""
        if [[ -f "$RUN_DIR/carried-creates" ]]; then
            slurp "$RUN_DIR/carried-creates"
            carried="$REPLY"
        fi
        settle=45
        case "$want" in
            flight) want="$flight" ;;
            earlier,flight) want="$earlier"$'\n'"$flight" ;;
            "") settle=0 ;;
        esac
        expect "$row" "status=0 carried=[${want//$'\t'/ }] settle=$settle" \
            "status=$status carried=[${carried//$'\t'/ }] settle=$seen"
    done <<'EOF'
in flight, nothing recorded|none|0|0|flight
in flight after an earlier unknown create|earlier|0|1|earlier,flight
in flight and recorded as unknown|same|0|0|flight
in flight, recorded and reconciled, no precondition time|same|1|0|
EOF
}

# killed_run_start: this run's record and the record of an earlier run killed outright while
# creating, whose directory holds owned alert 1 not yet deleted and owned alert 2 deleted, its
# precondition time PRECONDITION_FIXTURE, and the in-flight create of the fixture account,
# TARGET_PRICE ABOVE the domain maximum on the fixture instrument.
killed_run_start() {
    local a b
    fresh_state
    mkdir -p "$STATE_DIR/runs"
    record_run
    alert_id 1
    a="$REPLY"
    alert_id 2
    b="$REPLY"
    earlier_run k1 "http://localhost" "$COMPOSE_PATH" "$a $b" "$b"
    echo "$PRECONDITION_FIXTURE" >"$TEST_TMP/earlier/pi-perf.k1/precondition-at"
    in_flight_line 0
    echo "$REPLY" >"$TEST_TMP/earlier/pi-perf.k1/in-flight-create"
}

# The next run adopts a killed run's owned alerts and carries its in-flight create; recovery
# deletes by id the one alert that shows the create's evidence. The killed run's own alert with
# the same fields is adopted as owned and is no candidate, so a create whose id was recorded
# before the kill is not counted twice. The list is read until 45 s after adoption, since the
# killed run's POST may still be committing; with no such alert by then the create made none.
recover_in_flight_case() {
    local a f twin orphan status row lists want sleeps verdict reads text k line want_deletes
    local -a bodies=() requests=() steps=() deletes=()
    alert_id 1
    a="$REPLY"
    alert_id 7
    f="$REPLY"
    alert_json "$a" TARGET_PRICE "$INSTRUMENT_ID" ABOVE "$MAX_TOKEN" true null 1
    twin="$REPLY"
    alert_json "$f" TARGET_PRICE "$INSTRUMENT_ID" ABOVE "$MAX_TOKEN" true null 1
    orphan="$REPLY"
    while IFS='|' read -r row lists want sleeps; do
        killed_run_start
        # LISTS reads; only the last one lists the orphan when it is found.
        alert_list "$twin"
        bodies=()
        for ((k = 1; k < lists; k++)); do
            bodies+=("$REPLY")
        done
        if [[ "$want" == "found" ]]; then
            alert_list "$twin" "$orphan"
        fi
        bodies+=("$REPLY")
        for line in "${bodies[@]}"; do
            respond 0 200 "$line"
        done
        respond 0 204
        respond 0 204
        status=0
        (
            adopt_earlier_runs
            recover_earlier_alerts
        ) >"$TEST_OUT" 2>&1 || status=$?
        exit_lines "$TEST_OUT"
        verdict="$REPLY"
        reads=0
        deletes=()
        mapfile -t requests <"$STUB/requests"
        for line in "${requests[@]}"; do
            case "$line" in
                "GET $ALERTS_ENDPOINT?accountId=$ACCOUNT_ID") reads=$((reads + 1)) ;;
                "DELETE $ALERTS_ENDPOINT/"*) deletes+=("${line##*/}") ;;
            esac
        done
        mapfile -t steps <"$STUB/sleeps"
        want_deletes="$a"
        text="INFO recovery: 1 create(s) of $UNKNOWN_DESC an earlier run did not know, made no alert"
        if [[ "$want" == "found" ]]; then
            want_deletes="$a $f"
            text="INFO recovery: alert [$f] is the create of $UNKNOWN_DESC was unknown; it is deleted as an owned alert"
        fi
        expect "$row" \
            "status=0 PASS recovery| reads=$lists deletes=[$want_deletes] other requests=0 sleeps=[$sleeps] resolved=[1]" \
            "status=$status $verdict reads=$reads deletes=[${deletes[*]}] other requests=$((${#requests[@]} - reads - ${#deletes[@]})) sleeps=[${steps[*]}] resolved=[$(<"$RUN_DIR/carried-resolved")]"
        slurp "$TEST_OUT"
        if [[ "$REPLY" != *"$text"* ]]; then
            case_reasons+=("$row: the output lacks [$text]: $REPLY")
        fi
    done <<'EOF'
alert listed at once|1|found|
alert listed on the third read|3|found|5 5
only the killed run's owned alert listed until 45 s after adoption|10|none|5 5 5 5 5 5 5 5 5
EOF
}

# A create this run left in in-flight-create, its outcome never recorded, is reconciled once by
# cleanup: its line joins unknown-creates led by the second cleanup found it, and the alert that
# shows its evidence is deleted by id. One that post_alert recorded already is not recorded
# twice. A line that cannot be read stays, nothing is deleted for it, and the run record stays.
cleanup_in_flight_case() {
    local f row recorded first noted list status want unknown after
    alert_id 7
    f="$REPLY"
    alert_json "$f" TARGET_PRICE "$INSTRUMENT_ID" ABOVE "$MAX_TOKEN" true null 1
    alert_list "$REPLY"
    list="$REPLY"
    while IFS='|' read -r row recorded first; do
        fresh_state
        mkdir -p "$STATE_DIR/runs"
        record_run
        PRECONDITION_AT="$PRECONDITION_FIXTURE"
        SECONDS=42
        if [[ "$recorded" -eq 1 ]]; then
            in_flight_line 40
            echo "$REPLY" >"$RUN_DIR/unknown-creates"
        fi
        in_flight_line 0
        echo "$REPLY" >"$RUN_DIR/in-flight-create"
        respond 0 200 "$FLAG_ON"
        respond 0 200 "$list"
        respond 0 204
        cleanup_all >"$TEST_OUT"
        in_flight_line "$first"
        want="$REPLY"
        slurp "$RUN_DIR/unknown-creates"
        unknown="$REPLY"
        slurp "$RUN_DIR/in-flight-create"
        after="$REPLY"
        expect "$row" "problems=[] unknown=[${want//$'\t'/ }] in-flight=[] resolved=[1] record=gone" \
            "problems=[$CLEANUP_PROBLEMS] unknown=[${unknown//$'\t'/ }] in-flight=[$after] resolved=[$(<"$RUN_DIR/unknown-resolved")] record=$([[ -e "$STATE_DIR/runs/${RUN_DIR##*/}" ]] && echo kept || echo gone)"
        expect_file "$row: requests" "$STUB/requests" "GET $FLAG_ENDPOINT" \
            "GET $ALERTS_ENDPOINT?accountId=$ACCOUNT_ID" "DELETE $ALERTS_ENDPOINT/$f"
        slurp "$TEST_OUT"
        noted=no
        if [[ "$REPLY" == *"INFO cleanup: the create of TARGET_PRICE ABOVE $MAX_TOKEN on instrument [$INSTRUMENT_ID] for account [$ACCOUNT_ID] was in flight when the run ended; its outcome is unknown"* ]]; then
            noted=yes
        fi
        expect "$row: noted as in flight" "$([[ "$recorded" -eq 1 ]] && echo no || echo yes)" "$noted"
    done <<'EOF'
in flight when the run ended|0|42
recorded by post_alert before the run ended|1|40
EOF

    fresh_state
    mkdir -p "$STATE_DIR/runs"
    record_run
    PRECONDITION_AT="$PRECONDITION_FIXTURE"
    in_flight_line x
    echo "$REPLY" >"$RUN_DIR/in-flight-create"
    status=0
    cleanup_all >"$TEST_OUT" || status=$?
    handed_on 1 "unknown-creates, in-flight-create"
    expect "unreadable line" \
        "status=0 problems=[the create in RUN/in-flight-create cannot be read, so it is not reconciled; $REPLY] requests=0 in-flight=kept record=kept" \
        "status=$status problems=[${CLEANUP_PROBLEMS//$RUN_DIR/RUN}] requests=$(($(wc -l <"$STUB/requests"))) in-flight=$([[ -s "$RUN_DIR/in-flight-create" ]] && echo kept || echo emptied) record=$([[ -e "$STATE_DIR/runs/${RUN_DIR##*/}" ]] && echo kept || echo gone)"
}

# update_row ROW OWN CARRIED LEFT EXPECTED: this run's record, OWN and CARRIED unknown creates of
# its own and carried ones, each "open" or "reconciled" (or "none"), and with LEFT 1 an owned
# alert not deleted; update_run_record must leave "record=kept|gone problems=[P]".
update_row() {
    fresh_state
    mkdir -p "$STATE_DIR/runs"
    record_run
    if [[ "$2" != "none" ]]; then
        printf '0\t%s\tTARGET_PRICE\t%s\tABOVE\t1\n' "$ACCOUNT_ID" "$INSTRUMENT_ID" >"$RUN_DIR/unknown-creates"
        if [[ "$2" == "reconciled" ]]; then
            echo 1 >"$RUN_DIR/unknown-resolved"
        fi
    fi
    if [[ "$3" != "none" ]]; then
        carried_line "$PRECONDITION_FIXTURE"
        echo "$REPLY" >"$RUN_DIR/carried-creates"
        if [[ "$3" == "reconciled" ]]; then
            echo 1 >"$RUN_DIR/carried-resolved"
        fi
    fi
    if [[ "$4" -eq 1 ]]; then
        own 1
    fi
    update_run_record
    expect "$1" "$5" \
        "record=$([[ -e "$STATE_DIR/runs/${RUN_DIR##*/}" ]] && echo kept || echo gone) problems=[${CLEANUP_PROBLEMS//$RUN_DIR/RUN}]"
}

# The record stays while a create whose outcome is unknown is not reconciled, this run's or a
# carried one, and the cleanup problem says the next run looks for its alert; it goes once every
# create is reconciled and no owned alert is left.
update_run_record_case() {
    handed_on 1
    update_row "this run's create open" open none 0 "record=kept problems=[$REPLY]"
    update_row "carried create open" none open 0 "record=kept problems=[$REPLY]"
    handed_on 2
    update_row "both open" open open 0 "record=kept problems=[$REPLY]"
    update_row "both reconciled" reconciled reconciled 0 "record=gone problems=[]"
    update_row "creates reconciled, owned alert left" reconciled reconciled 1 "record=kept problems=[]"
    update_row "nothing unknown or left" none none 0 "record=gone problems=[]"
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

# on_exit_row ROW EXIT_STATUS FINISHED CLEANUP_DONE OWNED START_RC EXPECTED [REPORT_PRINTED]:
# the run exits with EXIT_STATUS anywhere but finish; OWNED 1 leaves one owned id, START_RC as in
# finish_row, and REPORT_PRINTED 1 means finish printed the REPORT before the run ended.
# EXPECTED starts with the order of the output's marks: F for the "run" FAIL, R for the REPORT
# line, C for the cleanup check and S for the SUMMARY.
on_exit_row() {
    local status=0 requests all=() line order=""
    fresh_state
    FINISHED="$3"
    CLEANUP_DONE="$4"
    REPORT_PRINTED="${8:-0}"
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
    mapfile -t all <"$TEST_OUT"
    for line in "${all[@]}"; do
        case "$line" in
            "FAIL run: "*) order+=F ;;
            REPORT) order+=R ;;
            "PASS cleanup" | "FAIL cleanup: "*) order+=C ;;
            "SUMMARY "*) order+=S ;;
        esac
    done
    exit_lines "$TEST_OUT"
    expect "$1" "$7" "order=$order status=$status requests=$requests $REPLY"
}

on_exit_case() {
    on_exit_row "error status kept" 3 0 0 0 - \
        "order=FRCS status=3 requests=0 FAIL run: ended early with status 3|PASS cleanup|SUMMARY 1 passed, 1 failed|"
    on_exit_row "status 0 becomes 1" 0 0 0 0 - \
        "order=FRCS status=1 requests=0 FAIL run: ended early with status 0|PASS cleanup|SUMMARY 1 passed, 1 failed|"
    on_exit_row "interrupt with a cleanup problem" 130 0 0 0 1 \
        "order=FRCS status=130 requests=0 FAIL run: ended early with status 130|FAIL cleanup: $LOADGEN_NOT_STARTED: compose start loadgen failed, exit 1 (see RUN/compose.log)|SUMMARY 0 passed, 2 failed|"
    on_exit_row "interrupt after finish printed the report" 130 0 0 0 - \
        "order=FCS status=130 requests=0 FAIL run: ended early with status 130|PASS cleanup|SUMMARY 1 passed, 1 failed|" 1
    on_exit_row "cleanup already done" 4 0 1 1 - \
        "order=FRS status=4 requests=0 FAIL run: ended early with status 4|SUMMARY 0 passed, 1 failed|"
    on_exit_row "after finish" 0 1 1 0 - "order= status=0 requests=0 "
    on_exit_row "after finish with a failure" 1 1 1 0 - "order= status=1 requests=0 "
}

# An interrupt that ends the run removes the lock container it made, by its id.
on_exit_lock_case() {
    local status=0 removals
    acquire_run_lock >"$TEST_OUT"
    (
        trap on_exit EXIT
        exit 130
    ) >"$TEST_OUT" 2>&1 || status=$?
    docker_calls_of rm
    removals="$REPLY"
    lock_state
    expect "status, removal and lock" "status=130 rm=[rm -v $FIRST_LOCK_ID|] lock=none" \
        "status=$status rm=[$removals] lock=$REPLY"
}

# ---------------------------------------------------------------------------------------------
# Setup

# container_env_is SERVICE JSON: SERVICE's container runs with the environment JSON, an array
# of NAME=VALUE strings.
container_env_is() {
    stub_cid "$1"
    printf '%s\n' "$2" >"$STUB/env.$REPLY"
}

# queue_ready_stack: queues the answers of a ready stack to setup's requests: both readyz
# checks, the target check's two probes, which the project's own reverse proxy logs unless
# STUB_SERVED_LOG names another stack's, the flag read as off and modifiable, and the PUT that
# switches it on.
queue_ready_stack() {
    respond 0 200 '{"status":"ready"}'
    respond 0 200 '{"status":"ready"}'
    respond 0 200 '{"status":"ready"}'
    respond 0 200 '{"status":"ready"}'
    respond 0 200 "$FLAG_OFF"
    respond 0 200 "$FLAG_ON"
}

# setup_marks: sets REPLY to the order of setup's Docker steps: L for the lock's create, S for
# the sample of the running services, and T for the stop of loadgen.
setup_marks() {
    local all=() line
    REPLY=""
    mapfile -t all <"$STUB/docker.calls"
    for line in "${all[@]}"; do
        case "$line" in
            "create "*) REPLY+=L ;;
            *" ps --status running --services") REPLY+=S ;;
            *" stop loadgen") REPLY+=T ;;
        esac
    done
}

# setup takes the run lock before it samples the running services, so loadgen's state at start
# is read under the lock; loadgen running then is stopped, to be started again on exit.
setup_lock_first_case() {
    STUB_RUNNING="$STUB_READY_SERVICES loadgen"
    container_env_is db-adapter '["DB_TYPE=postgres"]'
    queue_ready_stack
    setup >"$TEST_OUT"
    setup_marks
    expect "order and loadgen" "order=LST was_running=1 stopped=1" \
        "order=$REPLY was_running=$LOADGEN_WAS_RUNNING stopped=$LOADGEN_STOPPED"
    exit_lines "$TEST_OUT"
    expect "verdicts" \
        "PASS run lock|PASS readiness|PASS target project|PASS runtime facts|PASS flag modifiable|PASS loadgen isolation|PASS flag enabled|" \
        "$REPLY"
}

# A run refused the lock samples nothing and changes nothing: its one Docker step is its create
# of the lock, and it never reads loadgen's state, so it cannot keep a stop of loadgen by the
# run that holds the lock and starts it again.
setup_lock_refused_case() {
    local status=0 live marks requests
    command sleep 60 &
    live=$!
    lock_owned_by "$live" "$THIS_HOST"
    STUB_RUNNING="$STUB_READY_SERVICES loadgen"
    queue_ready_stack
    (setup) >"$TEST_OUT" 2>&1 || status=$?
    kill "$live"
    wait "$live" 2>/dev/null || true
    setup_marks
    marks="$REPLY"
    count_lines "$STUB/requests"
    requests="$REPLY"
    lock_state
    expect "refused" "status=1 marks=[L] requests=0 lock=$HELD_ID" \
        "status=$status marks=[$marks] requests=$requests lock=$REPLY"
}

# setup_readiness_row ROW VERDICTS MARKS REMOVALS: setup ends the run with exit status 1 and
# the PASS, FAIL and SUMMARY lines VERDICTS (exit_lines); MARKS are its Docker steps
# (setup_marks) and REMOVALS its docker rm calls, each followed by |. It sends no request, and
# leaves no lock container behind.
setup_readiness_row() {
    local status=0 marks removals requests lock
    (setup) >"$TEST_OUT" 2>&1 || status=$?
    setup_marks
    marks="$REPLY"
    docker_calls_of rm
    removals="$REPLY"
    count_lines "$STUB/requests"
    requests="$REPLY"
    lock_state
    lock="$REPLY"
    exit_lines "$TEST_OUT"
    expect "$1" "status=1 $2 marks=[$3] rm=[$4] requests=0 lock=none" \
        "status=$status $REPLY marks=[$marks] rm=[$removals] requests=$requests lock=$lock"
}

# Without a running db container there is nothing to make the lock from, so the run fails
# readiness, naming every required service that is not running, before anything is changed. A
# required service down once the lock is taken fails readiness the same way, and the lock
# container is removed on the way out.
setup_readiness_case() {
    local summary="PASS cleanup|SUMMARY 1 passed, 1 failed|"
    STUB_RUNNING="broker-service db-adapter feature-flag-service pricing-service reverse-proxy"
    setup_readiness_row "db and user-service down" \
        "FAIL readiness: services not running in project [unit-test]: db user-service|$summary" "S" ""

    fresh_state
    STUB_RUNNING="broker-service db-adapter"
    STUB_TIMEOUT_RC=124
    STUB_TIMEOUT_ON="--services"
    setup_readiness_row "db down, services sample cut off" \
        "FAIL readiness: listing the running services of project [unit-test] timed out after 60 s (Docker did not answer)|$summary" "S" ""

    fresh_state
    STUB_DB_CID=""
    setup_readiness_row "db started between the lookup and the services sample" \
        "FAIL readiness: services not running in project [unit-test]: db|$summary" "S" ""

    fresh_state
    STUB_RUNNING="broker-service db db-adapter feature-flag-service pricing-service reverse-proxy"
    setup_readiness_row "user-service down after the lock" \
        "PASS run lock|FAIL readiness: services not running in project [unit-test]: user-service|PASS cleanup|SUMMARY 2 passed, 1 failed|" \
        "LS" "rm -v $FIRST_LOCK_ID|"
}

# report_value KEY: sets REPLY to the value the REPORT block in TEST_OUT shows for KEY, or to a
# marker when it shows none.
report_value() {
    local all=() line prefix
    printf -v prefix '  %-24s ' "$1"
    REPLY="<no $1 line>"
    mapfile -t all <"$TEST_OUT"
    for line in "${all[@]}"; do
        if [[ "$line" == "$prefix"* ]]; then
            REPLY="${line#"$prefix"}"
        fi
    done
}

# setup_dialect_row ROW DB_TYPE_ENV VERDICTS: setup, with db-adapter's environment DB_TYPE_ENV,
# ends the run with exit status 1, the PASS, FAIL and SUMMARY lines VERDICTS, and a REPORT that
# shows no db type.
setup_dialect_row() {
    local status=0 verdicts
    fresh_state
    container_env_is db-adapter "$2"
    queue_ready_stack
    (setup) >"$TEST_OUT" 2>&1 || status=$?
    exit_lines "$TEST_OUT"
    verdicts="$REPLY"
    report_value "db type"
    expect "$1" "status=1 $3 db type=[n/a]" "status=$status $verdicts db type=[$REPLY]"
}

# DIALECT is set only to mssql or postgres, once the value read is checked. A run interrupted
# while DB_TYPE is read, or one whose DB_TYPE is anything else, which fails "runtime facts"
# naming the value as read, shows no db type in its REPORT.
setup_dialect_case() {
    local status=0 verdicts facts="PASS run lock|PASS readiness|PASS target project|FAIL runtime facts: db-adapter DB_TYPE is"
    local tail="expected mssql or postgres|PASS cleanup|SUMMARY 4 passed, 1 failed|"
    container_env_is db-adapter '["DB_TYPE=mssql"]'
    queue_ready_stack
    setup >"$TEST_OUT"
    expect "mssql" "DIALECT=mssql" "DIALECT=$DIALECT"

    fresh_state
    container_env_is db-adapter '["DB_TYPE=postgres"]'
    queue_ready_stack
    (
        STUB_ENV_SIGNAL_PID="$BASHPID"
        trap on_exit EXIT
        trap on_signal INT TERM
        setup
    ) >"$TEST_OUT" 2>&1 || status=$?
    exit_lines "$TEST_OUT"
    verdicts="$REPLY"
    report_value "db type"
    expect "interrupted while DB_TYPE is read" \
        "status=130 PASS run lock|PASS readiness|PASS target project|FAIL run: ended early with status 130|PASS cleanup|SUMMARY 4 passed, 1 failed| db type=[n/a]" \
        "status=$status $verdicts db type=[$REPLY]"

    setup_dialect_row "another dialect" '["DB_TYPE=sqlite"]' "$facts [sqlite], $tail"
    setup_dialect_row "postgres and a line feed" '["DB_TYPE=postgres\n"]' "$facts [\$'postgres\\n'], $tail"
    setup_dialect_row "unset" '["OTHER=postgres"]' "$facts [], $tail"
}

# ---------------------------------------------------------------------------------------------
# Setup: a Docker call that fails or is cut off stops the run before any change

SERVICES_CALL="$COMPOSE_PREFIX ps --status running --services"
STOP_CALL="$COMPOSE_PREFIX stop loadgen"
START_CALL="$COMPOSE_PREFIX start loadgen"
READY_REQUESTS="GET http://localhost/broker-service/readyz|GET http://localhost/feature-flag-service/readyz"
# The target check's two probes and its read of the project's reverse-proxy log, since the
# fixed time the date stub prints.
PROBE_REQUESTS="GET http://localhost/broker-service/readyz?pi-target=$PROBE_NONCE|GET http://localhost/feature-flag-service/readyz?pi-target=$PROBE_NONCE"
PROXY_LOGS_CALL="$COMPOSE_PREFIX logs --no-color --no-log-prefix --since 2026-01-01T00:00:00Z reverse-proxy"
FLAG_READ_REQUEST="GET $FLAG_ENDPOINT"
FLAG_ON_REQUEST="PUT $FLAG_ENDPOINT {\"enabled\": true}"
TIMED_OUT="timed out after 60 s (Docker did not answer)"
# The run lock's release on the way out: the removal, by its id, of the lock container setup made.
RELEASE_CALL="rm -v $FIRST_LOCK_ID"

# lock_calls: sets REPLY to the four Docker calls of setup's run lock on a free name, joined by
# |: the running db container's id, its image, that image's labels, and the create of the lock.
lock_calls() {
    REPLY="$COMPOSE_PREFIX ps -q --status running db|inspect --type container --format {{.Image}} db0000000001|image inspect --format {{json .Config.Labels}} $DB_IMAGE|create --name $LOCK_CONTAINER --label com.docker.compose.project= --label com.docker.compose.service= --label com.docker.compose.version= --label pi-perf.lock.pid=$$ --label pi-perf.lock.host=$THIS_HOST --label pi-perf.lock.started=2026-01-01T00:00:00Z --label pi-perf.lock.run-dir=$RUN_DIR $DB_IMAGE"
}

# env_calls SERVICE: sets REPLY to the two Docker calls container_env makes for SERVICE, joined
# by |: the running container's id, then its environment.
env_calls() {
    stub_cid "$1"
    REPLY="$COMPOSE_PREFIX ps -q $1|inspect --format {{json .Config.Env}} $REPLY"
}

# file_lines FILE: sets REPLY to FILE's lines joined by |, empty for an empty FILE.
file_lines() {
    local all=()
    mapfile -t all <"$1"
    REPLY=""
    if [[ ${#all[@]} -gt 0 ]]; then
        printf -v REPLY '%s|' "${all[@]}"
        REPLY="${REPLY%|}"
    fi
}

# setup_stack RUNNING: a fresh state on a stack running the services RUNNING, whose db-adapter
# runs with DB_TYPE postgres and whose broker-service runs with an interval of 60 s, and which
# answers setup's requests as a ready stack does (queue_ready_stack).
setup_stack() {
    fresh_state
    STUB_RUNNING="$1"
    container_env_is db-adapter '["PATH=/usr/bin","DB_TYPE=postgres"]'
    container_env_is broker-service '["PATH=/usr/bin","ALERT_EVALUATION_INTERVAL_SECONDS=60"]'
    queue_ready_stack
}

# setup_row ROW LINES REQUESTS CALLS: runs setup in a subshell, as main does, and expects LINES,
# "status=N" and its PASS, FAIL and SUMMARY lines as exit_lines writes them, and exactly the REST
# REQUESTS and the Docker CALLS, each list joined by |.
setup_row() {
    local status=0
    (setup) >"$TEST_OUT" 2>&1 || status=$?
    exit_lines "$TEST_OUT"
    expect "$1: status and lines" "$2" "status=$status $REPLY"
    file_lines "$STUB/requests"
    expect "$1: requests" "$3" "$REPLY"
    file_lines "$STUB/docker.calls"
    expect "$1: docker calls" "$4" "$REPLY"
}

# expect_output_line ROW LINE: the last setup_row's output holds LINE.
expect_output_line() {
    if ! grep -qxF -- "$2" "$TEST_OUT"; then
        case_reasons+=("$1: no output line [$2]")
    fi
}

# The services query, after the run lock is taken, fails or is cut off, by the call's own status
# (STUB_PS_RC) or by timeout's 124 or 137 for that call alone (STUB_TIMEOUT_RC, STUB_TIMEOUT_ON):
# readiness fails naming the call, with no request sent, and the lock is released on the way out.
setup_services_query_case() {
    local of="of project [unit-test]" row calls
    for row in "137 -" "124 -" "- 3"; do
        setup_stack "$REQUIRED_SERVICES loadgen"
        lock_calls
        calls="$REPLY|$SERVICES_CALL|$RELEASE_CALL"
        if [[ "${row% *}" != "-" ]]; then
            STUB_TIMEOUT_RC="${row% *}"
            STUB_TIMEOUT_ON="--services"
            setup_row "cut off with ${row% *}" \
                "status=1 PASS run lock|FAIL readiness: listing the running services $of $TIMED_OUT|PASS cleanup|SUMMARY 2 passed, 1 failed|" \
                "" "$calls"
        else
            STUB_PS_RC="${row#* }"
            setup_row "failing with ${row#* }" \
                "status=1 PASS run lock|FAIL readiness: listing the running services $of failed, exit ${row#* } (see RUN/compose.log)|PASS cleanup|SUMMARY 2 passed, 1 failed|" \
                "" "$calls"
        fi
    done
}

# runtime_facts_row ROW SERVICE NAME RC TEXT: the read of NAME from SERVICE fails with RC (124
# and 137 standing for a cut-off call). Runtime facts fail with TEXT after readiness passed; the
# flag is never read and loadgen, running at start, never stopped; no interval is assumed.
runtime_facts_row() {
    local calls
    setup_stack "$REQUIRED_SERVICES loadgen"
    STUB_INSPECT_FAIL="$2"
    STUB_INSPECT_RC="$4"
    lock_calls
    calls="$REPLY|$SERVICES_CALL|$PROXY_LOGS_CALL"
    env_calls db-adapter
    calls="$calls|$REPLY"
    if [[ "$2" == broker-service ]]; then
        env_calls broker-service
        calls="$calls|$REPLY"
    fi
    setup_row "$1" \
        "status=1 PASS run lock|PASS readiness|PASS target project|FAIL runtime facts: reading $3 from the $2 container of project [unit-test] $5|PASS cleanup|SUMMARY 4 passed, 1 failed|" \
        "$READY_REQUESTS|$PROBE_REQUESTS" "$calls|$RELEASE_CALL"
    expect_output_line "$1" "  evaluation interval      n/a"
}

setup_dialect_read_case() {
    runtime_facts_row "DB_TYPE read cut off" db-adapter DB_TYPE 137 "$TIMED_OUT"
    runtime_facts_row "DB_TYPE read failing" db-adapter DB_TYPE 1 "failed, exit 1 (see RUN/compose.log)"
}

setup_interval_read_case() {
    runtime_facts_row "interval read cut off by TERM" broker-service ALERT_EVALUATION_INTERVAL_SECONDS \
        124 "$TIMED_OUT"
    runtime_facts_row "interval read cut off by KILL" broker-service ALERT_EVALUATION_INTERVAL_SECONDS \
        137 "$TIMED_OUT"
    runtime_facts_row "interval read failing" broker-service ALERT_EVALUATION_INTERVAL_SECONDS \
        1 "failed, exit 1 (see RUN/compose.log)"
}

# An interval read successfully, unset or invalid, gets the broker's default of 60 s, and setup
# goes on to read and enable the flag.
setup_interval_default_case() {
    local value calls
    for value in "" abc; do
        setup_stack "$REQUIRED_SERVICES"
        if [[ -n "$value" ]]; then
            container_env_is broker-service "[\"PATH=/usr/bin\",\"ALERT_EVALUATION_INTERVAL_SECONDS=$value\"]"
        else
            container_env_is broker-service '["PATH=/usr/bin"]'
        fi
        lock_calls
        calls="$REPLY|$SERVICES_CALL|$PROXY_LOGS_CALL"
        env_calls db-adapter
        calls="$calls|$REPLY"
        env_calls broker-service
        calls="$calls|$REPLY"
        setup_row "interval [$value]" \
            "status=0 PASS run lock|PASS readiness|PASS target project|PASS runtime facts|PASS flag modifiable|PASS loadgen isolation|PASS flag enabled|" \
            "$READY_REQUESTS|$PROBE_REQUESTS|$FLAG_READ_REQUEST|$FLAG_ON_REQUEST" "$calls"
        expect_output_line "interval [$value]" \
            "INFO db type postgres; evaluation interval 60s (ALERT_EVALUATION_INTERVAL_SECONDS [$value]); loadgen running at start: no"
    done
}

# The stop of loadgen fails or is cut off: loadgen isolation fails naming it, the flag is never
# switched on, and cleanup still starts loadgen again.
setup_loadgen_stop_case() {
    local rc calls text
    for rc in 137 124 1; do
        setup_stack "$REQUIRED_SERVICES loadgen"
        STUB_STOP_RC="$rc"
        lock_calls
        calls="$REPLY|$SERVICES_CALL|$PROXY_LOGS_CALL"
        env_calls db-adapter
        calls="$calls|$REPLY"
        env_calls broker-service
        calls="$calls|$REPLY|$STOP_CALL|$START_CALL|$RELEASE_CALL"
        text="$TIMED_OUT"
        if [[ $rc -eq 1 ]]; then
            text="failed, exit 1 (see RUN/compose.log)"
        fi
        setup_row "stop ending with $rc" \
            "status=1 PASS run lock|PASS readiness|PASS target project|PASS runtime facts|PASS flag modifiable|FAIL loadgen isolation: compose stop loadgen $text|PASS cleanup|SUMMARY 6 passed, 1 failed|" \
            "$READY_REQUESTS|$PROBE_REQUESTS|$FLAG_READ_REQUEST" "$calls"
        expect_output_line "stop ending with $rc" "INFO cleanup: loadgen started again"
    done
}

# Two otherwise valid stacks: the base URL is served by another stack, whose reverse proxy logs
# the probes, while the named project's log never shows them. Over the 30 s deadline the log is
# read every 2 s, 15 times, then the target check fails and ends the run: the flag is never read
# or switched on, and loadgen, running at start, is never stopped, so cleanup has nothing to
# start again. The alert an earlier run on the project left undeleted is not taken on, so no
# DELETE for it goes through that base URL, and that run's record stays for a run whose base URL
# the project serves.
setup_target_mismatch_case() {
    local calls i earlier record
    setup_stack "$REQUIRED_SERVICES loadgen"
    STUB_SERVED_LOG="$STUB/other-proxy.log"
    alert_id 7
    earlier="$REPLY"
    earlier_run m1 "http://localhost" "$COMPOSE_PATH" "$earlier" ""
    record="$REPLY"
    lock_calls
    calls="$REPLY|$SERVICES_CALL"
    for ((i = 0; i < 15; i++)); do
        calls="$calls|$PROXY_LOGS_CALL"
    done
    setup_row "base url of another stack" \
        "status=1 PASS run lock|PASS readiness|FAIL target project: base url http://localhost is not served by the reverse-proxy of project [unit-test]: its log shows no request carrying this run's probe within 30 s; give the --base-url and --project of one stack|PASS cleanup|SUMMARY 3 passed, 1 failed|" \
        "$READY_REQUESTS|$PROBE_REQUESTS" "$calls|$RELEASE_CALL"
    file_lines "$STUB/sleeps"
    expect "base url of another stack: sleeps" "2|2|2|2|2|2|2|2|2|2|2|2|2|2" "$REPLY"
    expect "base url of another stack: earlier run" "owned=[] earlier record=kept" \
        "owned=[$(<"$RUN_DIR/owned")] earlier record=$([[ -f "$record" ]] && echo kept || echo gone)"
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
# Setup readiness

# readiness_row ROW TIMES STATUSES EXPECTED: runs setup in a subshell with every required
# service running. The Nth readyz request answers status word N of STATUSES and takes word N of
# TIMES in seconds, 0 past its last word, whatever its --max-time. curl runs inside
# http_within's command substitution, where a change to SECONDS never reaches setup, so
# http_within itself, which readyz and http both call, is wrapped to move the clock on.
# EXPECTED is "LINE|max-times L...|sleeps S...|requests N|elapsed E": the readiness check line,
# each request's --max-time, each sleep, the request count and SECONDS when the subshell exits.
# The run lock before the wait goes through docker alone, so it adds no request. setup ends at
# the target check that follows a passed readiness at the latest: the subshell replaces it with
# an exit, so only readiness's own requests are counted here, and the target check's own cases
# are the setup_* cases above.
readiness_row() {
    local row="$1" times=() statuses=() status limits=() steps=() line readiness="" requests
    fresh_state
    : >"$STUB/elapsed"
    read -ra times <<<"$2"
    read -ra statuses <<<"$3"
    for status in "${statuses[@]}"; do
        respond 0 "$status" '{"status":"Healthy"}'
    done
    STUB_RUNNING="$REQUIRED_SERVICES"
    (
        trap 'echo "$SECONDS" >"$STUB/elapsed"' EXIT
        eval "perf_$(declare -f http_within)"
        request=0
        # shellcheck disable=SC2329 # Called by perf.sh's readyz, which setup runs.
        http_within() {
            perf_http_within "$@"
            SECONDS=$((SECONDS + ${times[request]:-0}))
            request=$((request + 1))
        }
        # shellcheck disable=SC2329 # Called by setup once readiness has passed.
        verify_target_project() {
            exit 0
        }
        setup
    ) >"$TEST_OUT" 2>&1 || true
    while IFS= read -r line; do
        if [[ "$line" == "PASS readiness" || "$line" == "FAIL readiness: "* ]]; then
            readiness="$line"
        fi
    done <"$TEST_OUT"
    mapfile -t limits <"$STUB/max-times"
    mapfile -t steps <"$STUB/sleeps"
    count_lines "$STUB/requests"
    requests="$REPLY"
    slurp "$STUB/elapsed"
    expect "$row" "$4" \
        "$readiness|max-times ${limits[*]}|sleeps ${steps[*]}|requests $requests|elapsed $REPLY"
}

# With READY_TIMEOUT_SECONDS 300, READY_STEP_SECONDS 5 and HTTP_TIMEOUT_SECONDS 15: a pair that
# answers 200 by the deadline passes; one answered after it fails; a probe gets only the time
# left; no probe starts, and no sleep ends, at or after the deadline.
readiness_case() {
    readiness_row "both 200 at once" "" "200 200" \
        "PASS readiness|max-times 15 15|sleeps |requests 2|elapsed 0"
    readiness_row "both 200, the second after the deadline" "0 0 285 20" "503 503 200 200" \
        "FAIL readiness: broker-service and feature-flag-service readyz gave status 200 only 10s after the 300s deadline|max-times 15 15 15 10|sleeps 5|requests 4|elapsed 310"
    readiness_row "deadline reached by the first probe of a pair" "0 0 295" "503 503 200" \
        "FAIL readiness: after 300s broker-service readyz gave status 200, feature-flag-service readyz gave no answer (not probed: no time left before the deadline)|max-times 15 15 15|sleeps 5|requests 3|elapsed 300"
    readiness_row "503 until the deadline" "0 0 280" "503 503 503 503 503 503 503 503" \
        "FAIL readiness: after 300s broker-service readyz gave status 503, feature-flag-service readyz gave status 503|max-times 15 15 15 15 10 10 5 5|sleeps 5 5 5|requests 8|elapsed 295"
}

# ---------------------------------------------------------------------------------------------
# Request time limits

# Names a caller's environment could hold for a request's limit: the override perf.sh's http
# once read from its caller's scope, and http_within's own local. None of them may reach a
# request; executed, perf.sh's own HTTP_TIMEOUT_SECONDS must not be replaced either.
LIMIT_VARIABLES=(HTTP_MAX_TIME max_time)
HEALTHY='{"status":"Healthy"}'

# Sourced: with every name of LIMIT_VARIABLES exported as 0, an owned alert's DELETE and
# cleanup_all's flag restore keep HTTP_TIMEOUT_SECONDS, and each readyz probe takes the lesser
# of that and the time left to its deadline: 40 and 7 seconds. Executed: perf.sh as its own
# process, with HTTP_TIMEOUT_SECONDS also exported as 0 and every required service running,
# takes the run lock and probes both readyz with its own 15 seconds, and so does the target
# check's first probe, which no answer is queued for, so setup ends there.
limit_variables_case() {
    local name id status=0 out=() line readiness=""
    alert_id 1
    id="$REPLY"
    own 1
    FLAG_TOUCHED=1
    FLAG_INITIAL=false
    : >"$RUN_DIR/ready-answers"
    respond 0 204
    respond 0 200 "$FLAG_OFF"
    respond 0 200 "$HEALTHY"
    respond 0 200 "$HEALTHY"
    (
        for name in "${LIMIT_VARIABLES[@]}"; do
            export "$name=0"
        done
        delete_owned_alerts
        cleanup_all
        # fresh_state set SECONDS to 0, and no stub here advances it.
        readyz broker-service 40
        echo "$READY_ANSWER" >>"$RUN_DIR/ready-answers"
        readyz feature-flag-service 7
        echo "$READY_ANSWER" >>"$RUN_DIR/ready-answers"
    ) >"$TEST_OUT" 2>&1 || status=$?
    expect "sourced: subshell status" 0 "$status"
    expect_file "sourced: requests" "$STUB/requests" "DELETE $ALERTS_ENDPOINT/$id" \
        "PUT $FLAG_ENDPOINT {\"enabled\": false}" "GET http://localhost/broker-service/readyz" \
        "GET http://localhost/feature-flag-service/readyz"
    expect_file "sourced: limits" "$STUB/max-times" 15 15 15 7
    expect_file "sourced: readyz answers" "$RUN_DIR/ready-answers" "status 200" "status 200"

    fresh_state
    respond 0 200 "$HEALTHY"
    respond 0 200 "$HEALTHY"
    status=0
    (
        for name in "${LIMIT_VARIABLES[@]}" HTTP_TIMEOUT_SECONDS; do
            export "$name=0"
        done
        STUB_SIGNAL_PID=""
        STUB_ENV_SIGNAL_PID=""
        STUB_RUNNING="$REQUIRED_SERVICES"
        export STUB_EXEC_OUT STUB_EXEC_ERR STUB_EXEC_RC STUB_LOGS_RC STUB_LOG_POLLS \
            STUB_START_RC STUB_SIGNAL_PID STUB_TIMEOUT_RC STUB_CURL_MODE STUB_SELF_SIGNALS \
            STUB_TIMEOUT_ON STUB_RUNNING STUB_PS_RC STUB_STOP_RC STUB_INSPECT_FAIL STUB_INSPECT_RC \
            STUB_SERVED_LOG STUB_DB_IMAGE STUB_CREATE_RC STUB_RM_RC STUB_RESPAWN \
            STUB_ENV_SIGNAL_PID STUB_DB_CID STUB_CREATE_PRINTS LOCK_CONTAINER RESPAWN_ID
        export -f docker curl timeout od stub_cid stub_print stub_inspect stub_image_inspect stub_lock \
            stub_create stub_rm
        # The image's labels are JSON, so they reach perf.sh's environment as one quoted word.
        STUB_IMAGE_LABELS="$STUB_IMAGE_LABELS" \
            "$BASH" "$PERF_SH" --project unit-test --compose-file compose.dev.yaml
    ) >"$RUN_DIR/child.out" 2>"$RUN_DIR/child.err" </dev/null || status=$?
    expect "executed: exit status" 1 "$status"
    mapfile -t out <"$RUN_DIR/child.out"
    for line in "${out[@]}"; do
        if [[ "$line" == "PASS readiness" || "$line" == "FAIL readiness: "* ]]; then
            readiness="$line"
        fi
    done
    expect "executed: readiness" "PASS readiness" "$readiness"
    expect_file "executed: requests" "$STUB/requests" "GET http://localhost/broker-service/readyz" \
        "GET http://localhost/feature-flag-service/readyz" \
        "GET http://localhost/broker-service/readyz?pi-target=$PROBE_NONCE"
    expect_file "executed: limits" "$STUB/max-times" 15 15 15
}

# refused_limit_row LIMIT: http_within with LIMIT, after an earlier answer, sends nothing and
# reports why as a transport error, replacing every field of that answer.
refused_limit_row() {
    HTTP_STATUS="200"
    HTTP_CTYPE="application/json"
    HTTP_BODY="earlier body"
    HTTP_ERROR=""
    : >"$STUB/requests"
    http_within "$1" DELETE "$ALERTS_ENDPOINT/$ALERT_ID"
    count_lines "$STUB/requests"
    expect "limit [$1]" \
        "requests=0 status=000 ctype=[] body=[] transport error (not sent: time limit [$1] is not a whole number of seconds above 0)" \
        "requests=$REPLY status=$HTTP_STATUS ctype=[$HTTP_CTYPE] body=[$HTTP_BODY] $(status_text)"
}

# A limit that is not a whole number above 0, 0 above all, which curl takes as no limit, is
# refused; a whole number above 0 goes to curl as given.
refused_limit_case() {
    local limit
    for limit in 0 00 -5 "" 1.5 15s " 15"; do
        refused_limit_row "$limit"
    done
    : >"$STUB/requests"
    respond 0 204
    http_within 1 DELETE "$ALERTS_ENDPOINT/$ALERT_ID"
    expect "limit [1]: status" 204 "$HTTP_STATUS"
    expect_file "limit [1]: limits" "$STUB/max-times" 1
}

# ---------------------------------------------------------------------------------------------
# Main

run_case "perfSh_commandLine_exitsWithUsageStatus" command_line_case
run_case "perfSh_executedDirectly_runsMainFlow" executed_case
run_case "perfSh_sourcedWithArguments_runsNothing" sourced_case
run_case "checkTools_toolsAndComposePlugin_exitsTwoWhenOneIsMissing" check_tools_case
run_case "prepareRun_tmpdir_makesRunDirectoryOrExitsTwo" prepare_run_case
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
run_case "waitCycleLine_heldWindowRead_parsedBeforeAnyLogsCall" wait_held_read_case
run_case "armedSql_dialect_rendersExactQuery" armed_sql_case
run_case "dbQuery_dialect_sendsContainerClientInvocation" db_query_case
run_case "readArmedSet_emptyResult_writesEmptySet" read_armed_empty_case
run_case "readArmedSet_populatedRows_writesSortedLowerCaseSet" read_armed_populated_case
run_case "readArmedSet_clientFails_returnsOneWithErrorAndNoSet" read_armed_failure_case
run_case "readArmedSet_callCutOff_returnsOneWithTimeoutAndNoSet" read_armed_cut_off_case
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
run_case "postAlert_201NotEnabled_ownsIdWithoutExpectingIt" post_not_enabled_case
run_case "createAlert_interruptDuringPost_exitsAfterRecordingId" create_interrupt_case
run_case "createAlert_interruptKillsPost_exitsAfterRecordingUnknownCreate" create_interrupt_unknown_case
run_case "postAlert_anyOutcome_writesCreateAheadThenEmptiesInFlightRecord" post_in_flight_case
run_case "postAlert_inFlightRecordUnwritable_refusesBeforeRequest" post_in_flight_unwritable_case
run_case "http_writeOutRecord_takesCurlExitStatusOverSubstitutionStatus" http_record_case
run_case "http_groupSignalDuringRequest_postCompletesOtherRequestsEnd" http_shield_case
run_case "readFlag_flagReply_setsTypedBooleansOrFixedReason" read_flag_case
run_case "putFlag_reply_succeedsOnlyWhenReplyShowsValue" put_flag_case
run_case "readInitialFlag_flagReply_keepsValueOrAbortsWithFixedReason" read_initial_flag_case
run_case "enableFlag_replyNotOn_abortsAndRestoresFlag" enable_flag_case
run_case "readAlertReply_alertReply_setsOnlyTypedFields" read_alert_reply_case
run_case "deleteOwnedAlerts_ownedIds_deletesEachUndeletedIdOnce" delete_requests_case
run_case "deleteOwnedAlerts_responseStatuses_recordsCleanAndLeftInPlace" delete_statuses_case
run_case "deleteOwnedAlerts_consecutiveTransportErrors_stopsAtCutoff" delete_cutoff_case
run_case "deleteOwnedAlerts_transportErrorOr5xx_retriesWithBackoff" delete_retry_case
run_case "deleteOwnedAlerts_flagSwitchedOff_reenablesFlagAndRetriesOnce" delete_flag_off_case
run_case "deleteOwnedAlerts_403FlagReadOnOrUnreadable_retriesWithoutPutOrLeavesId" delete_flag_403_case
run_case "cleanupAll_flagAndOwnedAlerts_switchesFlagOnlyToDeleteThenRestores" cleanup_flag_case
run_case "cleanupAll_flagSwitchedOnToDelete_restoresSetupValueElseValueFoundBefore" cleanup_flag_unread_case
run_case "cleanupAll_flagNotSwitchedOn_recordsProblem" cleanup_flag_not_on_case
run_case "cleanupAll_flagRestoreFails_recordsProblem" cleanup_restore_fails_case
run_case "utcTimeKey_rfc3339Text_printsFixedWidthKeyOnlyForUtc" utc_time_key_case
run_case "timeKeyAtOrAfter_twoKeys_comparesSecondsThenFraction" time_key_at_or_after_case
run_case "cleanupAll_unknownCreateMatched_adoptsAndDeletesById" cleanup_unknown_matched_case
run_case "cleanupAll_unknownCreateBesideAlertMadeBeforePrecondition_adoptsOnlyItsAlert" cleanup_unknown_older_case
run_case "cleanupAll_unknownCreateNotListed_pollsUntilSettleDeadline" cleanup_unknown_not_listed_case
run_case "cleanupAll_unknownCreateAmbiguousOrUnreadable_failsWithoutDeleting" cleanup_unknown_ambiguous_case
run_case "cleanupAll_unknownCreateFlagOff_switchesFlagOnToReconcile" cleanup_unknown_flag_off_case
run_case "cleanupAll_loadgenStopped_startsLoadgenOrRecordsProblem" cleanup_loadgen_case
run_case "acquireRunLock_freeName_createsLabelledContainerFromDbImage" acquire_run_lock_free_case
run_case "acquireRunLock_staleOwnerOnThisHost_removesItByIdAndCreatesOnceMore" acquire_run_lock_stale_case
run_case "acquireRunLock_liveOtherHostOrUnreadableOwner_abortsLeavingLock" acquire_run_lock_refused_case
run_case "acquireRunLock_conflictAfterStaleRemoval_abortsWithoutSecondRemoval" acquire_run_lock_conflict_after_stale_case
run_case "acquireRunLock_dockerCallFailsOrTimesOut_abortsBeforeAnyChange" acquire_run_lock_docker_problem_case
run_case "releaseRunLock_heldLock_removesOnlyOwnContainerById" release_run_lock_case
run_case "recordRun_cleanupOutcome_keepsRecordOnlyWhileAlertsLeft" run_record_case
run_case "adoptEarlierRuns_matchingRecord_adoptsUndeletedOwnedIds" adopt_earlier_runs_case
run_case "adoptEarlierRuns_mismatchingOrUnreadableRecord_abortsChangingNothing" adopt_earlier_runs_refused_case
run_case "recoverEarlierAlerts_adoptedIds_deletesByIdAsRecoveryCheck" recover_earlier_alerts_case
run_case "adoptEarlierRuns_unreconciledCreates_carriesThemWithPreconditionTime" adopt_earlier_runs_carried_case
run_case "recoverEarlierAlerts_carriedCreates_reconcilesBeforeDeletingOrAbortsKeepingRecord" recover_carried_case
run_case "cleanupAll_carriedCreate_reconcilesAndDropsRecordOrKeepsRecordWhenUnreadable" cleanup_carried_case
run_case "adoptEarlierRuns_inFlightCreate_carriesItOnceLedByPreconditionTime" adopt_in_flight_case
run_case "recoverEarlierAlerts_killedRunInFlightCreate_deletesItsAlertOrFindsNoneBySettleDeadline" recover_in_flight_case
run_case "cleanupAll_ownInFlightCreate_reconcilesItOnceOrKeepsRecordWhenUnreadable" cleanup_in_flight_case
run_case "updateRunRecord_unreconciledCreates_keepsRecordNamingHandOff" update_run_record_case
run_case "finish_cleanupOutcome_reportsCleanupAndExitStatus" finish_case
run_case "abort_failedCheck_failsCheckThenFinishes" abort_case
run_case "onExit_runEndsEarly_cleansUpOnceAndKeepsFailureStatus" on_exit_case
run_case "onExit_runEndsEarly_removesOwnLockContainer" on_exit_lock_case
run_case "setup_loadgenRunning_samplesServicesOnlyAfterTakingLock" setup_lock_first_case
run_case "setup_lockHeldByLiveRun_abortsBeforeSamplingOrChanging" setup_lock_refused_case
run_case "setup_requiredServiceDown_failsReadinessNamingServicesWithoutLeavingLock" setup_readiness_case
run_case "setup_dbTypeInterruptedOrNotADialect_reportsNoDbType" setup_dialect_case
run_case "setup_servicesQueryFailsOrIsCutOff_failsReadinessWithoutRequest" setup_services_query_case
run_case "setup_dialectReadFailsOrIsCutOff_failsRuntimeFactsBeforeFlagRead" setup_dialect_read_case
run_case "setup_intervalReadFailsOrIsCutOff_failsRuntimeFactsWithoutDefault" setup_interval_read_case
run_case "setup_intervalReadUnsetOrInvalid_appliesDefaultAndEnablesFlag" setup_interval_default_case
run_case "setup_loadgenStopFailsOrIsCutOff_failsIsolationAndCleanupStartsLoadgen" setup_loadgen_stop_case
run_case "setup_baseUrlServedByOtherStack_failsTargetProjectBeforeFlagReadOrLoadgenStop" setup_target_mismatch_case
run_case "resolveInterval_rawSetting_appliesBrokerRule" resolve_interval_case
run_case "setup_readyzAnswerTimes_passesOnlyBothAnswersWithinDeadline" readiness_case
run_case "httpWithin_limitVariablesExported_sendsFixedLimitAndReadyzTimeLeft" limit_variables_case
run_case "httpWithin_limitNotWholeSecondsAboveZero_returns000WithoutRequest" refused_limit_case

echo "SUMMARY ${t_passed} passed, ${t_failed} failed"
if [[ $t_failed -ne 0 ]]; then
    exit 1
fi
