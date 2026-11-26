#!/usr/bin/env bash
# Tests, offline, the shell helpers and bounded Docker calls of the three Portfolio Insights
# harness scripts, e2e.sh, perf.sh and loadgen-check.sh:
#   - the origin helpers and hard_timeout are byte-identical in all three, and container_env and
#     resolve_interval in e2e.sh and perf.sh;
#   - is_base_origin, in each copy and in the C and a UTF-8 locale, accepts http(s) origins and
#     refuses credentials, paths, queries, fragments, other schemes, white space, control
#     characters and malformed hosts and ports;
#   - each script, run as a process, refuses a bad --base-url or a stray argument with exit 2
#     without printing it, and takes an accepted origin on to its next check, all before any
#     Docker call;
#   - container_env reads a container's variable byte for byte, and resolve_interval reads the
#     value as the broker does: int.TryParse with NumberStyles.Integer, then 1 to 4294967;
#   - hard_timeout, the log reads inside and outside a deadline, perf.sh's cycle-line wait and
#     loadgen-check.sh's progress watch and run B drain end by their bounds when Docker never
#     answers, and loadgen-check.sh's cleanup still deletes the owned alerts and restores the
#     flag then, whether loadgen was running or paused.
# No Docker engine, network or stack is used: a fake docker, first on PATH, answers, fails or
# hangs as each case needs and records every call.
#
# Usage: bash scripts/portfolio-insights/harness-test.sh [--help]
#   --help  Show this help and exit
#
# Needs bash 5 or later, jq and the coreutils the scripts use (timeout, base64, od, sed,
# mktemp). Takes under two minutes.
#
# Prints one PASS or FAIL line per check and a final SUMMARY line. Exits 0 when every check
# passes, 1 when any check fails, and 2 on a usage error or a missing tool. The run's temporary
# directory is removed on exit.

# shellcheck disable=SC2329 # The case_* functions run through run_case.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: bash scripts/portfolio-insights/harness-test.sh [--help]
  --help  Show this help and exit
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "${EPOCHREALTIME:-}" ]]; then
    echo "bash 5 or later is required: the timing checks read EPOCHREALTIME." >&2
    exit 2
fi
missing_tools=""
for tool in timeout base64 od sed mktemp jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing_tools="$missing_tools $tool"
    fi
done
if [[ -n "$missing_tools" ]]; then
    echo "Missing required tools:$missing_tools" >&2
    exit 2
fi

# Byte-exact text handling; the locale cases switch to a UTF-8 locale themselves.
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIGIN_HELPERS="is_port_number is_ipv4_address is_dns_name is_ipv6_address is_base_origin"
# Every value passed to a refused option carries this marker, which no output may show.
SECRET="hts-s3cret-7f3a"
FAKE_CID="0123456789abcdef"
LOG_SINCE_TEXT="2026-01-01T00:00:00Z"
FLAG_PATH="feature-flag-service/v1/flags/portfolio-insights-enabled"
ALERT_ID_1="11111111-1111-4111-8111-111111111111"
ALERT_ID_2="22222222-2222-4222-8222-222222222222"
ALERT_ID_3="33333333-3333-4333-8333-333333333333"
# The id of the visit run whose log lines the loadgen-check.sh cases read.
VISIT_RUN_ID="44444444-4444-4444-8444-444444444444"
CR=$'\r'
LF=$'\n'
TAB=$'\t'
# tests.md rules out sleeps and arbitrary timeouts as a way to wait for asynchronous work. Here
# time is the behaviour under test: each timing case hands the code a fake docker that never
# answers, the stimulus, and checks that the code's own deadline ends the wait within its bound.
# The test itself never sleeps, and the fake's wait ends by itself after this many seconds, so
# every wait is bounded even when a deadline under test is broken.
export FAKE_DOCKER_HANG_SECONDS=15

passed=0
failed=0
reasons=()
TEST_DIR=""
CASE_DIR=""
CASE_RC=0
CASE_MS=0

pass() {
    passed=$((passed + 1))
    echo "PASS $1"
}

fail() {
    failed=$((failed + 1))
    echo "FAIL $1: $2"
}

summarize() {
    echo "SUMMARY ${passed} passed, ${failed} failed"
}

# A failed prerequisite leaves nothing meaningful to test, so the run stops there.
abort() {
    fail "$1" "$2"
    summarize
    exit 1
}

# Reports one PASS or FAIL line for CHECK from the reasons collected since the last call.
conclude() {
    local joined
    if [[ ${#reasons[@]} -eq 0 ]]; then
        pass "$1"
    else
        joined="$(printf '%s; ' "${reasons[@]}")"
        fail "$1" "${joined%; }"
    fi
    reasons=()
}

remove_test_dir() {
    local status=$? pid
    trap - EXIT
    for pid in $(jobs -p); do
        kill "$pid" 2>/dev/null || true
    done
    if [[ -n "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
    exit "$status"
}
trap remove_test_dir EXIT
trap 'exit 130' INT TERM

if ! TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/harness-test.XXXXXX")"; then
    TEST_DIR=""
    echo "Could not create a temporary directory under ${TMPDIR:-/tmp}." >&2
    exit 2
fi
# The directory goes on PATH, so it is used in the shell's own form, which has no drive colon.
TEST_DIR="$(cd "$TEST_DIR" && pwd)"
mkdir "$TEST_DIR/bin" "$TEST_DIR/cases" "$TEST_DIR/cwd" "$TEST_DIR/env"

# ---------------------------------------------------------------------------------------------
# The fake docker

cat >"$TEST_DIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
# Fake docker for harness-test.sh. It appends each call's arguments to FAKE_DOCKER_RECORD and
# never reaches a Docker engine. The verb is the first of logs, stop, up, pause, unpause, kill,
# rm, ps and inspect among the arguments. FAKE_DOCKER_MODE_<verb>, else FAKE_DOCKER_MODE, sets
# what the call does:
#   answer            (default) logs prints the file FAKE_DOCKER_LINES; stop, up, pause,
#                     unpause, kill and rm succeed; ps --services prints FAKE_DOCKER_RUNNING, the
#                     running services, and any other ps FAKE_DOCKER_CID when it is set; inspect
#                     renders the environment of container FAKE_DOCKER_CID, the NUL-separated
#                     entries of the file FAKE_DOCKER_ENV;
#   fail              exits 3 at once with an error on stderr;
#   hang              waits, ending on TERM;
#   hang-ignore-term  waits with TERM ignored, ending only on KILL.
# A wait ends by itself after FAKE_DOCKER_HANG_SECONDS. Its sleeps hold none of the call's
# descriptors, so a killed call closes its output pipe at once.
set -u
printf '%s\n' "$*" >>"$FAKE_DOCKER_RECORD"
verb=""
for arg in "$@"; do
    case "$arg" in
        logs | stop | up | pause | unpause | kill | rm | ps | inspect)
            verb="$arg"
            break
            ;;
    esac
done
if [[ -z "$verb" ]]; then
    echo "fake docker: unsupported call: $*" >&2
    exit 1
fi
mode_var="FAKE_DOCKER_MODE_$verb"
mode="${!mode_var:-${FAKE_DOCKER_MODE:-answer}}"
case "$mode" in
    answer) ;;
    fail)
        echo "fake docker: Cannot connect to the Docker daemon" >&2
        exit 3
        ;;
    hang)
        exec sleep "$FAKE_DOCKER_HANG_SECONDS" </dev/null >/dev/null 2>&1
        ;;
    hang-ignore-term)
        trap '' TERM
        for ((i = 0; i < FAKE_DOCKER_HANG_SECONDS; i++)); do
            sleep 1 </dev/null >/dev/null 2>&1
        done
        exit 0
        ;;
    *)
        echo "fake docker: unknown mode $mode" >&2
        exit 1
        ;;
esac
case "$verb" in
    logs)
        if [[ -n "${FAKE_DOCKER_LINES:-}" ]]; then
            cat "$FAKE_DOCKER_LINES"
        fi
        ;;
    stop | up | pause | unpause | kill | rm) ;;
    ps)
        if [[ " $* " == *" --services "* ]]; then
            if [[ -n "${FAKE_DOCKER_RUNNING:-}" ]]; then
                printf '%s\n' "$FAKE_DOCKER_RUNNING"
            fi
        elif [[ -n "${FAKE_DOCKER_CID:-}" ]]; then
            printf '%s\n' "$FAKE_DOCKER_CID"
        fi
        ;;
    inspect)
        format=""
        previous=""
        for arg in "$@"; do
            if [[ "$previous" == --format ]]; then
                format="$arg"
            fi
            previous="$arg"
        done
        id="${!#}"
        if [[ -z "${FAKE_DOCKER_CID:-}" || "$id" != "$FAKE_DOCKER_CID" ]]; then
            echo "Error: No such object: $id" >&2
            exit 1
        fi
        entries=()
        if [[ -n "${FAKE_DOCKER_ENV:-}" ]]; then
            mapfile -d '' -t entries <"$FAKE_DOCKER_ENV"
        fi
        case "$format" in
            '{{json .Config.Env}}')
                json="["
                separator=""
                for entry in "${entries[@]}"; do
                    entry="${entry//\\/\\\\}"
                    entry="${entry//\"/\\\"}"
                    entry="${entry//$'\t'/\\t}"
                    entry="${entry//$'\n'/\\n}"
                    entry="${entry//$'\r'/\\r}"
                    json+="$separator\"$entry\""
                    separator=","
                done
                printf '%s]\n' "$json"
                ;;
            # The line template, the lossy form container_env must not go back to: it is answered
            # too, so such a change shows up as wrong bytes rather than as an unknown template.
            '{{range .Config.Env}}{{println .}}{{end}}')
                for entry in "${entries[@]}"; do
                    printf '%s\n' "$entry"
                done
                ;;
            *)
                echo "fake docker: unsupported format $format" >&2
                exit 1
                ;;
        esac
        ;;
esac
EOF
chmod +x "$TEST_DIR/bin/docker"
export PATH="$TEST_DIR/bin:$PATH"

# ---------------------------------------------------------------------------------------------
# Helpers

# Flattens a captured output file into one line, cut to 300 characters, for a FAIL reason.
one_line() {
    tr '\r\n' '  ' <"$1" | head -c 300
}

# hex_of: stdin as lower-case hex, two digits per byte.
hex_of() {
    od -An -tx1 -v | tr -d ' \n'
}

# from_hex VAR HEX: sets VAR to the bytes HEX spells, two hex digits per byte, trailing line
# feeds included, which a command substitution would drop.
from_hex() {
    local bytes="" byte i
    for ((i = 0; i < ${#2}; i += 2)); do
        printf -v byte '%b' "\\x${2:i:2}"
        bytes+="$byte"
    done
    printf -v "$1" '%s' "$bytes"
}

# camel NAME: NAME, in snake_case or kebab-case, as camelCase for a check name.
camel() {
    local part out
    local -a parts
    IFS='_-' read -ra parts <<<"$1"
    out="${parts[0]}"
    for part in "${parts[@]:1}"; do
        out+="${part^}"
    done
    printf '%s' "$out"
}

# extract_function FILE NAME: the definition of NAME in FILE, from its "NAME() {" line to the
# first line that is only "}", which is how every function in the three scripts ends.
extract_function() {
    sed -n "/^$2() {\$/,/^}\$/p" "$1"
}

# check_definitions SCRIPT CONSTANTS FUNCTIONS [LIB]: collects a reason for each of CONSTANTS
# (assignments) and FUNCTIONS (definitions) of SCRIPT.sh not found exactly once, and appends
# the ones found to LIB when it is given.
check_definitions() {
    local file="$SCRIPT_DIR/$1.sh" lib="${4:-}" name count text
    local -a names
    read -ra names <<<"$2"
    for name in "${names[@]}"; do
        count="$(grep -c "^$name=" "$file" || true)"
        if [[ "$count" != 1 ]]; then
            reasons+=("$name= is assigned on ${count:-0} lines of $1.sh, expected 1")
        elif [[ -n "$lib" ]]; then
            grep "^$name=" "$file" >>"$lib"
        fi
    done
    read -ra names <<<"$3"
    for name in "${names[@]}"; do
        count="$(grep -c "^$name() {\$" "$file" || true)"
        text="$(extract_function "$file" "$name")"
        if [[ "$count" != 1 || "${text##*$'\n'}" != "}" ]]; then
            reasons+=("$name() is defined on ${count:-0} lines of $1.sh, expected 1")
        elif [[ -n "$lib" ]]; then
            printf '%s\n' "$text" >>"$lib"
        fi
    done
}

# run_case NAME COMMAND [ARGS...]: runs COMMAND in a background subshell, where set -e stays in
# force as it does in the scripts (a subshell tested with || would run with it off), and waits
# for it. COMMAND gets CASE_DIR, a directory of its own, and the fake docker records its calls
# in CASE_DIR/docker.calls. Sets CASE_RC and CASE_MS, the wall-clock milliseconds from COMMAND's
# mark_start, or from its start without one, to its end. Leaves stdout and stderr in
# CASE_DIR/out and CASE_DIR/err.
run_case() {
    local start end
    CASE_DIR="$TEST_DIR/cases/$1"
    shift
    mkdir -p "$CASE_DIR"
    : >"$CASE_DIR/docker.calls"
    CASE_RC=0
    start="${EPOCHREALTIME//[!0-9]/}"
    (
        export FAKE_DOCKER_RECORD="$CASE_DIR/docker.calls"
        "$@"
    ) >"$CASE_DIR/out" 2>"$CASE_DIR/err" </dev/null &
    wait "$!" || CASE_RC=$?
    end="${EPOCHREALTIME//[!0-9]/}"
    if [[ -s "$CASE_DIR/start" ]]; then
        start="$(<"$CASE_DIR/start")"
    fi
    CASE_MS=$(((end - start) / 1000))
}

# mark_start: in a case, notes the moment the operation under test begins, so that CASE_MS
# leaves out the time spent loading the script.
mark_start() {
    printf '%s\n' "${EPOCHREALTIME//[!0-9]/}" >"$CASE_DIR/start"
}

# docker_calls VERB: how many fake docker calls of the last case carry VERB as an argument.
docker_calls() {
    grep -cE "(^| )$1( |\$)" "$CASE_DIR/docker.calls" || true
}

expect_status() {
    if [[ "$CASE_RC" -ne "$1" ]]; then
        reasons+=("exit status $CASE_RC, expected $1 (stderr: $(one_line "$CASE_DIR/err"))")
    fi
}

expect_line() {
    if ! grep -qxF -- "$1" "$CASE_DIR/out"; then
        reasons+=("no output line [$1]; output [$(one_line "$CASE_DIR/out")]")
    fi
}

# expect_line_re ERE: some output line matches ERE, anchored by the caller.
expect_line_re() {
    if ! grep -qE -- "$1" "$CASE_DIR/out"; then
        reasons+=("no output line matches [$1]; output [$(one_line "$CASE_DIR/out")]")
    fi
}

expect_within_ms() {
    if [[ "$CASE_MS" -gt "$1" ]]; then
        reasons+=("took ${CASE_MS} ms, more than the $1 ms bound")
    fi
}

expect_docker_calls() {
    local count
    count="$(docker_calls "$1")"
    if [[ "$count" -ne "$2" ]]; then
        reasons+=("${count} fake docker $1 calls, expected $2")
    fi
}

# load_script SCRIPT: defines, in a case's subshell, the functions and constants of SCRIPT.sh
# and the state they read. Docker calls go to the fake under project harness-test.
# shellcheck disable=SC2034 # The variables are the state the loaded script functions read.
load_script() {
    if [[ "$1" == loadgen-check ]]; then
        # shellcheck source=scripts/portfolio-insights/loadgen-check.sh
        source "$SCRIPT_DIR/loadgen-check.sh"
        # main()'s defaults of the loadgen state the stop, drain and restore read.
        LOADGEN_PAUSED=0
        LOADGEN_AT_START=""
        RESTORE_ERROR=""
    else
        # shellcheck source=/dev/null
        source "$TEST_DIR/lib-$1.sh"
    fi
    RUN_DIR="$CASE_DIR"
    PROJECT="harness-test"
    COMPOSE_FILE="fake-compose.yaml"
    COMPOSE_ARGS=(-f "$COMPOSE_FILE")
    passed=0
    failed=0
    POLL_DETAIL=""
    PROBE_DEADLINE=""
    LOG_PROBE_DETAIL=""
    # e2e.sh's fail() redacts its two fixture passwords, which e2e.sh starts empty.
    HOLDER_PASSWORD=""
    EMPTY_PASSWORD=""
}

# ---------------------------------------------------------------------------------------------
# Definitions under test. e2e.sh and perf.sh run main only when executed, but even when sourced
# they parse their options, check their tools and create a run directory, so the functions and
# constants these cases need are extracted from their text into one library per script; each
# must be found exactly once. loadgen-check.sh does all of that in main, so the cases source it
# whole.

SHARED_CONSTANTS="LOG_PROBE_TIMEOUT_SECONDS LOG_PROBE_KILL_SECONDS DEFAULT_INTERVAL_SECONDS MAX_INTERVAL_SECONDS"
E2E_CONSTANTS="$SHARED_CONSTANTS INSIGHTS_LINE_RE"
E2E_FUNCTIONS="$ORIGIN_HELPERS compose hard_timeout container_env resolve_interval probe_limit broker_logs insights_line_logged poll fail"
PERF_CONSTANTS="$SHARED_CONSTANTS LOG_STEP_SECONDS CYCLE_MARKER CYCLE_RE"
PERF_FUNCTIONS="$ORIGIN_HELPERS compose hard_timeout container_env resolve_interval probe_limit broker_logs parse_cycle_line cycle_summary_text info wait_cycle_line"
LOADGEN_CHECK_FUNCTIONS="$ORIGIN_HELPERS hard_timeout container_env loadgen_logs probe_limit watch_progress cleanup"
# The guard line of loadgen-check.sh that keeps sourcing it from starting a run.
# shellcheck disable=SC2016 # Matched as text, never expanded.
LOADGEN_CHECK_GUARD='if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then'

for script in e2e perf loadgen-check; do
    if [[ ! -f "$SCRIPT_DIR/$script.sh" ]]; then
        abort "extractDefinitions_$(camel "$script")Script_eachFoundOnce" "$SCRIPT_DIR/$script.sh not found"
    fi
done
# conclude_or_abort CHECK: conclude CHECK, and end the run when it failed, since nothing after
# it can be loaded.
conclude_or_abort() {
    local before="$failed"
    conclude "$1"
    if [[ "$failed" -ne "$before" ]]; then
        summarize
        exit 1
    fi
}

: >"$TEST_DIR/lib-e2e.sh"
check_definitions e2e "$E2E_CONSTANTS" "$E2E_FUNCTIONS" "$TEST_DIR/lib-e2e.sh"
conclude_or_abort "extractDefinitions_e2eScript_eachFoundOnce"
: >"$TEST_DIR/lib-perf.sh"
check_definitions perf "$PERF_CONSTANTS" "$PERF_FUNCTIONS" "$TEST_DIR/lib-perf.sh"
conclude_or_abort "extractDefinitions_perfScript_eachFoundOnce"
check_definitions loadgen-check "" "$LOADGEN_CHECK_FUNCTIONS"
if ! grep -qxF -- "$LOADGEN_CHECK_GUARD" "$SCRIPT_DIR/loadgen-check.sh"; then
    reasons+=("its source guard line [$LOADGEN_CHECK_GUARD] is missing, so sourcing it would start a run")
fi
conclude_or_abort "extractDefinitions_loadgenCheckScript_eachFoundOnce"

# ---------------------------------------------------------------------------------------------
# 1. Helper parity: the copies stay byte-identical, so a fix in one script reaches all of them.

read -ra parity_names <<<"$ORIGIN_HELPERS hard_timeout"
for name in "${parity_names[@]}"; do
    reference="$(extract_function "$SCRIPT_DIR/e2e.sh" "$name")"
    for script in perf loadgen-check; do
        if [[ "$(extract_function "$SCRIPT_DIR/$script.sh" "$name")" != "$reference" ]]; then
            reasons+=("the $script.sh copy differs from the e2e.sh copy")
        fi
    done
    conclude "$(camel "$name")_threeScriptCopies_byteIdentical"
done
for name in resolve_interval container_env; do
    if [[ "$(extract_function "$SCRIPT_DIR/perf.sh" "$name")" != "$(extract_function "$SCRIPT_DIR/e2e.sh" "$name")" ]]; then
        reasons+=("the perf.sh copy differs from the e2e.sh copy")
    fi
    conclude "$(camel "$name")_e2eAndPerfCopies_byteIdentical"
done

# A UTF-8 locale for the locale cases: one in which a two-byte character has length 1.
UTF8_LOCALE=""
for candidate in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    if (
        LC_ALL="$candidate"
        nbsp=$'\xc2\xa0'
        [[ ${#nbsp} -eq 1 ]]
    ) 2>/dev/null; then
        UTF8_LOCALE="$candidate"
        break
    fi
done
LOCALES=(C)
if [[ -n "$UTF8_LOCALE" ]]; then
    LOCALES+=("$UTF8_LOCALE")
else
    echo "INFO no UTF-8 locale found (tried C.UTF-8, C.utf8, en_US.UTF-8, en_US.utf8); the locale cases run in the C locale only"
fi

# locale_label LOCALE: CLocale or Utf8Locale, for a check name.
locale_label() {
    if [[ "$1" == C ]]; then
        printf 'CLocale'
    else
        printf 'Utf8Locale'
    fi
}

# ---------------------------------------------------------------------------------------------
# 2. is_base_origin

LABEL63="$(printf 'a%.0s' {1..63})"
# 253 characters: three 63-character labels, a dot after each, then a 61-character label.
NAME253="$LABEL63.$LABEL63.$LABEL63.$(printf 'b%.0s' {1..61})"
ORIGINS=(
    'http://localhost'
    'http://reverse-proxy'
    'http://localhost/'
    'http://localhost.'
    'http://localhost./'
    'http://localhost.:8080/'
    'http://localhost:20100'
    'http://localhost:65535'
    'http://localhost:1'
    'http://localhost:00080'
    'https://easytrade.example.com:443/'
    'https://a'
    'http://A-1.b-2.C'
    'http://xn--bcher-kva.example'
    'http://1a.2b'
    'http://foo.123a'
    'http://foo.0xg'
    "http://$LABEL63.example"
    "http://$NAME253"
    "http://$NAME253."
    # 269 characters, the longest origin there is.
    "https://$NAME253.:65535/"
    "https://$NAME253.:00080/"
    'http://10.0.0.255:8080'
    'http://0.0.0.0'
    'http://255.255.255.255'
    'http://[::1]:20100'
    'http://[::]'
    'http://[1::]'
    'http://[2001:db8::8a2e:370:7334]'
    'http://[1:2:3:4:5:6:7:8]'
    'http://[1:2:3:4:5:6:7::]'
    'http://[::2:3:4:5:6:7:8]'
    'http://[ABCD:ef01::]:443'
    'http://[::ffff:192.0.2.1]'
    'http://[::1.2.3.4]'
    'http://[1:2:3:4:5::1.2.3.4]'
    'http://[1:2:3:4:5:6:1.2.3.4]'
)
NON_ORIGINS=(
    'http://localhost:0'
    'http://localhost:65536'
    'http://localhost:99999'
    'http://localhost:123456'
    'http://localhost:'
    'http://localhost:-1'
    'http://localhost:+80'
    'http://localhost:8a'
    'http://localhost:8080:80'
    $'http://localhost:\xef\xbc\x98\xef\xbc\x90'
    'http://user:s3cret@localhost'
    'http://user@localhost'
    'http://:pw@localhost'
    'http://localhost/path'
    'http://localhost//'
    'http://localhost?x'
    'http://localhost#x'
    'http://localhost%2F'
    "http://localhost\\"
    'http://localhost;x'
    'HTTP://localhost'
    'Http://localhost'
    'ftp://localhost'
    'httpx://localhost'
    'http:/localhost'
    'http//localhost'
    'localhost'
    'http://'
    'http:///'
    'https://'
    "http://local${LF}host"
    "http://localhost${LF}"
    "http://localhost/${LF}"
    "http://local${TAB}host"
    "http://local${CR}host"
    "http://localhost${CR}"
    "http://localhost/${CR}"
    "http://localhost:80${CR}"
    'http://local host'
    'http://localhost '
    ' http://localhost'
    'http://256.1.1.1'
    'http://1.2.3.256'
    'http://01.2.3.4'
    'http://1.2.3.04'
    'http://00.0.0.0'
    'http://1.2.3'
    'http://1.2.3.4.5'
    'http://1.2.3.4.'
    'http://123'
    'http://0x7f'
    'http://foo.123'
    'http://foo.123.'
    'http://foo.0x1'
    'http://foo.0x'
    'http://foo.0X'
    'http://-bad.example'
    'http://bad-.example'
    'http://-'
    'http://a-'
    'http://a..b'
    'http://.'
    'http://..'
    'http://localhost..'
    'http://local_host'
    $'http://l\xc3\xb3calhost'
    "http://${LABEL63}a.example"
    # 254 characters before the root dot, one more than a name may have.
    "http://${NAME253}c"
    "http://${NAME253}c."
    # 270 characters, one more than the longest origin.
    "http://$(printf 'a%.0s' {1..263})"
    'http://[:::]'
    'http://[1:2:3:4:5:6:7:8:9]'
    'http://[1::2::3]'
    'http://[12345::]'
    'http://[::1]:x'
    'http://[::1]/path'
    'http://[fe80::1%25eth0]'
    'http://[::1%eth0]'
    'http://[ ::1]'
    'http://[::1'
    'http://::1]'
    'http://[::1]]'
    'http://[[::1]]'
    'http://[::1]extra'
    'http://[]'
    'http://[g::1]'
    'http://[1:2:3:4:5:6:7]'
    'http://[1:2:3:4::5:6:7:8]'
    'http://[::1:2:3:4:5:6:7:8]'
    'http://[1:2:3:4:5:6:7:8::]'
    'http://[:1::2]'
    'http://[1::2:]'
    'http://[1:2:3:4:5:6:7:8:]'
    'http://[:1:2:3:4:5:6:7:8]'
    'http://[1.2.3.4]'
    'http://[1.2.3.4::]'
    'http://[::1.2.3]'
    'http://[::1.2.3.4.5]'
    'http://[::1.2.3.4:5]'
    'http://[::256.1.1.1]'
    'http://[::01.2.3.4]'
    'http://[1:2:3:4:5:6::1.2.3.4]'
    'http://[1:2:3:4:5:6:7:1.2.3.4]'
)

# case_origin_table SCRIPT LOCALE accept|refuse VALUE...: prints, quoted with %q, each VALUE
# that SCRIPT's is_base_origin, run in LOCALE, does not accept or refuse as asked.
case_origin_table() {
    load_script "$1"
    LC_ALL="$2"
    local want="$3" value
    shift 3
    for value in "$@"; do
        if is_base_origin "$value"; then
            if [[ "$want" == refuse ]]; then
                printf 'accepted %q\n' "$value"
            fi
        elif [[ "$want" == accept ]]; then
            printf 'refused %q\n' "$value"
        fi
    done
}

control_rows=0
for value in "${NON_ORIGINS[@]}"; do
    if [[ "$value" == *[$CR$LF$TAB]* ]]; then
        control_rows=$((control_rows + 1))
    fi
done
if [[ "$control_rows" -ne 8 ]]; then
    reasons+=("$control_rows rows hold a CR, LF or tab, expected 8: the shell dropped one")
fi
conclude "isBaseOrigin_tableControlRows_keepTheirControlCharacters"

for script in e2e perf loadgen-check; do
    for locale in "${LOCALES[@]}"; do
        label="$(camel "$script")Copy$(locale_label "$locale")"
        run_case "origins-$script-$locale" case_origin_table "$script" "$locale" accept "${ORIGINS[@]}"
        expect_status 0
        if [[ -s "$CASE_DIR/out" ]]; then
            reasons+=("$(paste -s -d ' ' "$CASE_DIR/out")")
        fi
        conclude "isBaseOrigin_${label}Origins_allAccepted"
        run_case "non-origins-$script-$locale" case_origin_table "$script" "$locale" refuse "${NON_ORIGINS[@]}"
        expect_status 0
        if [[ -s "$CASE_DIR/out" ]]; then
            reasons+=("$(paste -s -d ' ' "$CASE_DIR/out")")
        fi
        conclude "isBaseOrigin_${label}NonOrigins_allRefused"
    done
done

# ---------------------------------------------------------------------------------------------
# 3. Option handling, through each script run as a process. Every case ends with exit 2 before
# the scripts look for docker, so the fake docker must record no call.

# label|--base-url value
REFUSED_BASE_URLS=(
    "baseUrlUserinfo|http://user:$SECRET@localhost"
    "baseUrlUserOnly|http://$SECRET@localhost"
    "baseUrlPath|http://localhost/$SECRET"
    "baseUrlQuery|http://localhost?$SECRET"
    "baseUrlFragment|http://localhost#$SECRET"
    "baseUrlOtherScheme|ftp://$SECRET"
    "baseUrlUpperCaseScheme|HTTP://$SECRET"
    "baseUrlPortZero|http://$SECRET:0"
    "baseUrlPortAboveRange|http://$SECRET:65536"
    "baseUrlSpace|http://$SECRET x"
    "baseUrlLineFeed|http://localhost${LF}$SECRET"
)
# label|argument
STRAY_ARGUMENTS=(
    "equalsFormBaseUrl|--base-url=http://user:$SECRET@localhost"
    "strayPositionalUrl|http://user:$SECRET@localhost"
)
BASE_URL_ERROR="Option --base-url needs an http:// or https:// origin: a host and optional port, without credentials, path, query or fragment."
STRAY_ERROR="Unknown argument (not shown): each option takes its value as the next argument."
MISSING_COMPOSE_PREFIX="Compose file not found: does-not-exist.yaml (resolved from "

# case_run_script SCRIPT ARGS...: SCRIPT.sh as its own process, from a directory that holds no
# does-not-exist.yaml.
case_run_script() {
    cd "$TEST_DIR/cwd"
    "$BASH" "$SCRIPT_DIR/$1.sh" "${@:2}"
}

# expect_no_secret: neither output stream of the last case shows SECRET.
expect_no_secret() {
    if grep -qF -- "$SECRET" "$CASE_DIR/out" "$CASE_DIR/err"; then
        reasons+=("the output shows the refused value: $(one_line "$CASE_DIR/err")")
    fi
}

expect_stderr_line() {
    if ! grep -qxF -- "$1" "$CASE_DIR/err"; then
        reasons+=("no stderr line [$1]; stderr [$(one_line "$CASE_DIR/err")]")
    fi
}

expect_no_docker_call() {
    if [[ -s "$CASE_DIR/docker.calls" ]]; then
        reasons+=("docker was called: $(one_line "$CASE_DIR/docker.calls")")
    fi
}

# expect_compose_file_error: stderr holds the missing compose file error, which follows an
# accepted --base-url, and not the --base-url error.
expect_compose_file_error() {
    if ! grep -qF -- "$MISSING_COMPOSE_PREFIX" "$CASE_DIR/err" ||
        grep -qxF -- "$BASE_URL_ERROR" "$CASE_DIR/err"; then
        reasons+=("stderr [$(one_line "$CASE_DIR/err")] is not the compose-file error")
    fi
}

COMMON_ARGS=(--project harness-test --compose-file does-not-exist.yaml)
for script in e2e perf loadgen-check; do
    prefix="$(camel "$script")Options"
    for row in "${REFUSED_BASE_URLS[@]}"; do
        label="${row%%|*}"
        run_case "options-$script-$label" case_run_script "$script" "${COMMON_ARGS[@]}" --base-url "${row#*|}"
        expect_status 2
        expect_stderr_line "$BASE_URL_ERROR"
        expect_no_secret
        expect_no_docker_call
        conclude "${prefix}_${label}_exitsTwoWithoutShowingIt"
    done
    for row in "${STRAY_ARGUMENTS[@]}"; do
        label="${row%%|*}"
        run_case "options-$script-$label" case_run_script "$script" "${COMMON_ARGS[@]}" "${row#*|}"
        expect_status 2
        expect_stderr_line "$STRAY_ERROR"
        expect_no_secret
        expect_no_docker_call
        conclude "${prefix}_${label}_exitsTwoAsUnknownArgumentNotShown"
    done
    run_case "options-$script-bare" case_run_script "$script" "${COMMON_ARGS[@]}" --no-such-option
    expect_status 2
    expect_stderr_line "Unknown option: --no-such-option"
    expect_no_docker_call
    conclude "${prefix}_bareUnknownOption_exitsTwoNamingIt"
    run_case "options-$script-accepted" case_run_script "$script" "${COMMON_ARGS[@]}" --base-url "http://localhost:20100/"
    expect_status 2
    expect_compose_file_error
    expect_no_docker_call
    conclude "${prefix}_acceptedOrigin_passesToComposeFileCheck"
    run_case "options-$script-default" case_run_script "$script" "${COMMON_ARGS[@]}"
    expect_status 2
    expect_compose_file_error
    expect_no_docker_call
    conclude "${prefix}_defaultOrigin_passesToComposeFileCheck"
done

# ---------------------------------------------------------------------------------------------
# 4. container_env, every copy, against the fake inspect of one container.

V=ALERT_EVALUATION_INTERVAL_SECONDS
# label|NAME read|environment entries, space-separated NAME:HEX where HEX spells the value|the
# expected value as hex
CONTAINER_ENV_ROWS=(
    "plainValue_printsItExactly|$V|$V:3630|3630"
    "lineFeedInside_keepsBothLines|$V|$V:3132300a35|3132300a35"
    "carriageReturnInside_keepsIt|$V|$V:31320d30|31320d30"
    "trailingLineFeed_keepsIt|$V|$V:36300a|36300a"
    "spacesAndLeadingZeros_keepsThem|$V|$V:203030393020|203030393020"
    "equalsSignsInValue_keepsThem|EQ|EQ:613d623d63|613d623d63"
    "decoyNamesFirst_printsExactNameOnly|$V|${V}_X:37 X$V:38 alert_evaluation_interval_seconds:39 $V:3630|3630"
    "nameTwice_printsFirstEntry|$V|$V:31 $V:32|31"
    "onlyDecoyNames_printsNothing|$V|${V}_X:37 X$V:38 alert_evaluation_interval_seconds:39|"
    "nameUnset_printsNothing|$V|OTHER:31|"
)

# case_container_env SCRIPT NAME ENV_FILE CID: prints "status N", then what container_env printed
# as hex, captured as the scripts capture it so that a trailing line feed survives.
case_container_env() {
    load_script "$1"
    export FAKE_DOCKER_ENV="$3" FAKE_DOCKER_CID="$4"
    local value status=0
    value="$(container_env broker-service "$2" && printf x)" || status=$?
    printf 'status %s\n%s\n' "$status" "$(printf '%s' "${value%x}" | hex_of)"
}

# container_env_result: the status and hex printed by the last case_container_env.
container_env_result() {
    local status_line hex_line=""
    {
        IFS= read -r status_line || status_line=""
        IFS= read -r hex_line || true
    } <"$CASE_DIR/out"
    printf '%s %s' "${status_line#status }" "$hex_line"
}

for row in "${CONTAINER_ENV_ROWS[@]}"; do
    IFS='|' read -r label name entries expected <<<"$row"
    env_file="$TEST_DIR/env/$label"
    : >"$env_file"
    read -ra pairs <<<"$entries"
    for pair in "${pairs[@]}"; do
        from_hex value "${pair#*:}"
        printf '%s=%s\0' "${pair%%:*}" "$value" >>"$env_file"
    done
    for script in e2e perf loadgen-check; do
        run_case "container-env-$label-$script" case_container_env "$script" "$name" "$env_file" "$FAKE_CID"
        result="$(container_env_result)"
        if [[ "$CASE_RC" -ne 0 || "$result" != "0 $expected" ]]; then
            reasons+=("$script.sh: status and bytes [$result], expected [0 $expected] (stderr: $(one_line "$CASE_DIR/err"))")
        fi
    done
    conclude "containerEnv_$label"
done
for script in e2e perf loadgen-check; do
    run_case "container-env-none-$script" case_container_env "$script" "$V" "$TEST_DIR/env/plainValue_printsItExactly" ""
    result="$(container_env_result)"
    if [[ "$CASE_RC" -ne 0 || "${result%% *}" == 0 || -n "${result#* }" ]]; then
        reasons+=("$script.sh: status and bytes [$result], expected a nonzero status and no bytes")
    fi
done
conclude "containerEnv_serviceWithoutContainer_failsWithoutOutput"

# ---------------------------------------------------------------------------------------------
# 5. resolve_interval against the broker's rule, int.TryParse(raw, NumberStyles.Integer,
# CultureInfo.InvariantCulture) and then 1 to 4294967, otherwise 60. The expected values are
# what .NET 10 returns for each input, read through the environment configuration provider.

# hex of the raw value|interval
RESOLVE_ROWS=(
    "3630|60"
    "2b37|7"
    "2d35|60"
    "2d30|60"
    "30|60"
    "2b2b37|60"
    "34323934393637|4294967"
    "34323934393638|60"
    "3939393939393939393939|60"
    "203030393020|90"
    "36300a|60"
    "370a|7"
    "0936300d|60"
    "09370d|7"
    "0b360c|6"
    "0a0a370a0a|7"
    "3132300a35|60"
    "31320d30|60"
    "350a30|60"
    "616263|60"
    "|60"
    "c2a03630c2a0|60"
    "c2a037c2a0|60"
    "e380803630e38080|60"
    "e3808037e38080|60"
    "e2808337|60"
)

# case_resolve_table SCRIPT LOCALE: prints each RESOLVE_ROWS row that SCRIPT's resolve_interval,
# run in LOCALE, resolves to another interval.
case_resolve_table() {
    load_script "$1"
    LC_ALL="$2"
    local row hex want value got
    for row in "${RESOLVE_ROWS[@]}"; do
        hex="${row%%|*}"
        want="${row#*|}"
        from_hex value "$hex"
        got="$(resolve_interval "$value")"
        if [[ "$got" != "$want" ]]; then
            printf 'raw [%s] gave %s, expected %s\n' "$hex" "$got" "$want"
        fi
    done
}

for script in e2e perf; do
    for locale in "${LOCALES[@]}"; do
        run_case "resolve-$script-$locale" case_resolve_table "$script" "$locale"
        expect_status 0
        if [[ -s "$CASE_DIR/out" ]]; then
            reasons+=("$(paste -s -d ' ' "$CASE_DIR/out")")
        fi
        conclude "resolveInterval_$(camel "$script")Copy$(locale_label "$locale")_matchesDotnetRule"
    done
done

# ---------------------------------------------------------------------------------------------
# 6. Bounded Docker calls. A bound of N s is met when the call has ended within N s plus 1 s for
# process start-up and the deadlines' whole-second clocks.

# e2e.sh: a poll whose log reads never answer ends at its deadline and says why. The poll
# command is step 5's insights_line_logged, waiting for an account's insights line.
case_poll_logs_hang() {
    load_script e2e
    export FAKE_DOCKER_MODE=hang-ignore-term
    mark_start
    poll "probe" 3 1 insights_line_logged "$LOG_SINCE_TEXT" "$ALERT_ID_1" 2 1.5 LOW
}
run_case poll-hang case_poll_logs_hang
expect_status 1
expect_line_re '^FAIL probe: deadline 3 s expired; broker-service logs probe timed out after [123] s \(Docker did not answer\)$'
expect_within_ms 4000
expect_docker_calls logs 1
conclude "poll_brokerLogsNeverAnswer_failsByDeadlineWithTimeoutDetail"

# case_broker_logs MODE [PROBE_DEADLINE [POLL_DETAIL]]: one e2e.sh broker_logs read, outside or
# inside a deadline, then its LOG_PROBE_DETAIL. Outside a deadline the read takes
# LOG_PROBE_TIMEOUT_SECONDS, lowered here to 2 s.
case_broker_logs() {
    load_script e2e
    export FAKE_DOCKER_MODE="$1"
    PROBE_DEADLINE="${2:-}"
    POLL_DETAIL="${3:-}"
    LOG_PROBE_TIMEOUT_SECONDS=2
    mark_start
    if broker_logs "$LOG_SINCE_TEXT" >"$CASE_DIR/logs"; then
        echo "read succeeded"
    fi
    printf 'detail %s\n' "$LOG_PROBE_DETAIL"
}

run_case logs-fail case_broker_logs fail
expect_status 0
expect_line "detail broker-service logs unreadable, exit 3 (see $CASE_DIR/compose.log)"
if ! grep -qF "Cannot connect to the Docker daemon" "$CASE_DIR/compose.log"; then
    reasons+=("compose.log does not hold Docker's error")
fi
conclude "brokerLogs_dockerFails_reportsUnreadableWithExitStatus"

now="$(date -u +%s)"
run_case logs-no-time case_broker_logs answer "$((now - 1))"
expect_status 0
expect_line "detail broker-service logs probe not started: no time left before the poll deadline"
expect_docker_calls logs 0
conclude "brokerLogs_noTimeLeftInPoll_skipsDockerWithNotStartedDetail"

run_case logs-no-time-after-attempt case_broker_logs answer "$((now - 1))" "no broker-service line contains [x]"
expect_status 0
expect_line "detail no broker-service line contains [x]"
expect_docker_calls logs 0
conclude "brokerLogs_noTimeLeftAfterEarlierAttempt_keepsThatAttemptsDetail"

run_case logs-fixed-bound case_broker_logs hang-ignore-term
expect_status 0
expect_line "detail broker-service logs probe timed out after 2 s (Docker did not answer)"
expect_within_ms 3000
conclude "brokerLogs_outsidePollNeverAnswers_endsByFixedBound"

case_broker_logs_lines() {
    load_script e2e
    printf '\033[32mINFO\033[0m Alert evaluation cycle finished\r\nsecond line\r\n' >"$CASE_DIR/lines"
    export FAKE_DOCKER_LINES="$CASE_DIR/lines"
    broker_logs "$LOG_SINCE_TEXT"
}
run_case logs-lines case_broker_logs_lines
expect_status 0
want_hex="$(printf 'INFO Alert evaluation cycle finished\nsecond line\n' | hex_of)"
got_hex="$(hex_of <"$CASE_DIR/out")"
if [[ "$got_hex" != "$want_hex" ]]; then
    reasons+=("output bytes $got_hex, expected $want_hex")
fi
conclude "brokerLogs_dockerAnswers_printsLinesWithoutColourOrCarriageReturn"

# hard_timeout, with its grace LOG_PROBE_KILL_SECONDS set per row:
# check|grace|limit|fake docker mode|status|bound in ms
HARD_TIMEOUT_ROWS=(
    "hardTimeout_termIgnored_exits137AtLimit|1|3|hang-ignore-term|137|4000"
    "hardTimeout_termHonoured_exits124AtLimitLessGrace|1|3|hang|124|3000"
    "hardTimeout_limitWithinGrace_killsAtLimitWith137|5|2|hang|137|3000"
    "hardTimeout_programFails_keepsItsStatus|1|3|fail|3|2000"
    "hardTimeout_programAnswers_keepsItsOutput|1|3|answer|0|2000"
)

# case_hard_timeout GRACE LIMIT MODE: one e2e.sh hard_timeout run of a fake docker log read.
case_hard_timeout() {
    load_script e2e
    LOG_PROBE_KILL_SECONDS="$1"
    export FAKE_DOCKER_MODE="$3"
    printf 'program output\n' >"$CASE_DIR/lines"
    export FAKE_DOCKER_LINES="$CASE_DIR/lines"
    mark_start
    hard_timeout "$2" docker compose -p "$PROJECT" -f "$COMPOSE_FILE" logs broker-service
}
for row in "${HARD_TIMEOUT_ROWS[@]}"; do
    IFS='|' read -r check grace limit mode status bound <<<"$row"
    run_case "$check" case_hard_timeout "$grace" "$limit" "$mode"
    expect_status "$status"
    expect_within_ms "$bound"
    if [[ "$mode" == answer ]]; then
        expect_line "program output"
    fi
    conclude "$check"
done

# perf.sh: the cycle-line wait ends at its deadline when no log read answers.
# shellcheck disable=SC2034 # LOG_SINCE is read by wait_cycle_line.
case_wait_cycle_line_hang() {
    load_script perf
    export FAKE_DOCKER_MODE=hang-ignore-term
    LOG_SINCE="$LOG_SINCE_TEXT"
    mark_start
    if wait_cycle_line 0 3; then
        printf 'found %s\n' "$CYCLE_LINE"
    fi
    printf 'detail %s\n' "$LOG_PROBE_DETAIL"
}
run_case wait-cycle-line-hang case_wait_cycle_line_hang
expect_status 0
expect_line_re '^detail broker-service logs probe timed out after [123] s \(Docker did not answer\)$'
expect_within_ms 4000
expect_docker_calls logs 1
conclude "waitCycleLine_brokerLogsNeverAnswer_endsByDeadline"

# loadgen-check.sh: each Docker call of container_env has ended by DOCKER_CALL_TIMEOUT_SECONDS.
# shellcheck disable=SC2034 # DOCKER_CALL_TIMEOUT_SECONDS is read by container_env.
case_container_env_hang() {
    load_script loadgen-check
    export FAKE_DOCKER_CID="$FAKE_CID" FAKE_DOCKER_MODE_inspect=hang-ignore-term
    DOCKER_CALL_TIMEOUT_SECONDS=2
    local status=0
    mark_start
    container_env loadgen PORTFOLIO_INSIGHTS_ALERT_WEIGHT >/dev/null || status=$?
    printf 'status %s\n' "$status"
}
run_case container-env-hang case_container_env_hang
expect_status 0
expect_line "status 137"
expect_within_ms 3000
expect_docker_calls inspect 1
conclude "containerEnv_loadgenCheckInspectNeverAnswers_failsWith137ByCallLimit"

# case_watch_progress STEP SECONDS: loadgen-check.sh's watch_progress over a window that ends
# SECONDS from now, with a progress read due every STEP seconds and Docker never answering.
# shellcheck disable=SC2034 # The variables are read by watch_progress.
case_watch_progress() {
    load_script loadgen-check
    export FAKE_DOCKER_MODE=hang-ignore-term
    PROGRESS_STEP_SECONDS="$1"
    MINUTES=35
    WINDOW_START_EPOCH="$(date -u +%s)"
    WINDOW_SINCE="$LOG_SINCE_TEXT"
    mark_start
    watch_progress B $((WINDOW_START_EPOCH + $2))
}
# With the script's 60 s step the first read is due at the window's end, so it is skipped.
run_case watch-progress-skip case_watch_progress 60 2
expect_status 0
expect_line "INFO run B progress 0/35 min: read skipped at the window end; the breakdown and the window's closing read follow"
expect_within_ms 3000
expect_docker_calls logs 0
conclude "watchProgress_readDueAtWindowEnd_skipsItWithoutDockerCall"

run_case watch-progress-capped case_watch_progress 1 3
expect_status 0
expect_line_re '^INFO run B progress 0/35 min: loadgen logs probe timed out after [12] s \(Docker did not answer\)$'
expect_within_ms 4000
expect_docker_calls logs 1
conclude "watchProgress_logsNeverAnswer_readEndsByWindowEnd"

# record_http METHOD URL [BODY]: stands in for loadgen-check.sh's http, records each request in
# CASE_DIR/http.calls and answers it: the flag reads back as FAKE_FLAG, which a PUT sets, and a
# DELETE gets 204.
record_http() {
    local enabled_re='"enabled": *(true|false)'
    printf '%s %s %s\n' "$1" "$2" "${3:-}" >>"$CASE_DIR/http.calls"
    HTTP_ERROR=""
    HTTP_CTYPE="application/json"
    HTTP_BODY=""
    case "$1" in
        GET) HTTP_STATUS=200 ;;
        PUT)
            HTTP_STATUS=200
            if [[ "${3:-}" =~ $enabled_re ]]; then
                FAKE_FLAG="${BASH_REMATCH[1]}"
            fi
            ;;
        DELETE) HTTP_STATUS=204 ;;
        *) HTTP_STATUS=405 ;;
    esac
    if [[ "$1" != DELETE ]]; then
        HTTP_BODY="{\"id\":\"portfolio-insights-enabled\",\"enabled\":$FAKE_FLAG}"
    fi
}

# case_cleanup MODE [PAUSED]: loadgen-check.sh's EXIT cleanup after a run ended inside run B, the
# fake docker in MODE, and loadgen paused by the run B drain when PAUSED is 1. Two alerts are
# owned, and the window's log shows loadgen created a third that it never resolved; the flag was
# false at start, and loadgen was running with weight 0, as it is again once recreated.
# shellcheck disable=SC2034 # The variables are the run state cleanup reads.
case_cleanup() {
    load_script loadgen-check
    export FAKE_DOCKER_MODE="$1" FAKE_DOCKER_CID="$FAKE_CID" FAKE_DOCKER_RUNNING=loadgen
    http() {
        record_http "$@"
    }
    FAKE_FLAG=false
    : >"$CASE_DIR/http.calls"
    : >"$RUN_DIR/deleted"
    : >"$RUN_DIR/new-owned"
    : >"$RUN_DIR/verdicts"
    printf '%s\n' "$ALERT_ID_2" "$ALERT_ID_1" >"$RUN_DIR/owned"
    printf '%s\n' "[2026-01-01 00:00:00+00:00][worker:0][visit:portfolio_insights_alert][id:$VISIT_RUN_ID][INFO]: Created alert [$ALERT_ID_3] threshold [1.5]" >"$CASE_DIR/lines"
    export FAKE_DOCKER_LINES="$CASE_DIR/lines"
    printf '%s\0' "PORTFOLIO_INSIGHTS_ALERT_WEIGHT=0" >"$CASE_DIR/env"
    export FAKE_DOCKER_ENV="$CASE_DIR/env"
    BASE_URL="http://harness-test.invalid"
    FLAG_URL="$BASE_URL/$FLAG_PATH"
    ALERTS_URL="$BASE_URL/broker-service/v1/alerts"
    FLAG_INITIAL=false
    FLAG_TOUCHED=1
    LOADGEN_WAS_RUNNING=1
    LOADGEN_AT_START="running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=0"
    LOADGEN_PAUSED="${2:-0}"
    LOADGEN_TOUCHED=1
    WINDOW_OPEN=1
    WINDOW_LABEL=B
    WINDOW_SINCE="$LOG_SINCE_TEXT"
    TABLE_WRITTEN=1
    # A wait's deadline left in scope by the exit; cleanup reads with its fixed bound instead.
    PROBE_DEADLINE=$(($(date -u +%s) + 600))
    DOCKER_CALL_TIMEOUT_SECONDS=2
    trap cleanup EXIT
    mark_start
    exit 0
}

# expect_rest_requests ID...: the cleanup's REST requests were the flag read, its switch on, a
# DELETE of each ID in order and the flag's restore.
expect_rest_requests() {
    local url="http://harness-test.invalid" id want
    want="GET $url/$FLAG_PATH ${LF}PUT $url/$FLAG_PATH {\"enabled\": true}"
    for id in "$@"; do
        want+="${LF}DELETE $url/broker-service/v1/alerts/$id "
    done
    want+="${LF}PUT $url/$FLAG_PATH {\"enabled\": false}"
    if [[ "$(cat "$CASE_DIR/http.calls")" != "$want" ]]; then
        reasons+=("REST requests [$(one_line "$CASE_DIR/http.calls")], expected the flag read and switch on, a DELETE of $* and the flag restore, in that order")
    fi
}

# Docker answering at once: every step is done and the check passes. This run's time is the
# cleanup's own work, the baseline of the bound below.
run_case cleanup-docker-answers case_cleanup answer
expect_status 0
expect_line "PASS cleanup"
expect_line "INFO cleanup: alert [$ALERT_ID_3] was logged as created and never resolved by loadgen; it is deleted on exit"
expect_line "INFO cleanup: 3 of 3 owned alerts deleted or already absent"
expect_line "INFO cleanup: flag portfolio-insights-enabled restored to enabled=false"
expect_line "INFO cleanup: loadgen restored as at start: running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=0"
expect_rest_requests "$ALERT_ID_1" "$ALERT_ID_2" "$ALERT_ID_3"
expect_docker_calls stop 1
expect_docker_calls logs 1
expect_docker_calls up 1
expect_docker_calls inspect 1
conclude "cleanup_dockerAnswers_passesWithEveryStepDone"
cleanup_baseline_ms="$CASE_MS"

# loadgen's stop and its recreate never answering: the closing read must not start, the owned
# alerts are still deleted and the flag restored, and the check fails, naming both calls. Both
# calls are cut off at 2 s, so the run takes at most the baseline, 2 x 2 s and 1 s.
run_case cleanup-docker-hangs case_cleanup hang-ignore-term
expect_status 1
expect_line "FAIL cleanup: loadgen not confirmed stopped: compose stop loadgen timed out after 2 s (Docker did not answer); loadgen not restored: recreating loadgen as [running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=0] timed out after 2 s (Docker did not answer)"
expect_line "INFO cleanup: flag portfolio-insights-enabled switched on to delete 2 owned alerts (status 200)"
expect_line "INFO cleanup: 2 of 2 owned alerts deleted or already absent"
expect_line "INFO cleanup: flag portfolio-insights-enabled restored to enabled=false"
expect_rest_requests "$ALERT_ID_1" "$ALERT_ID_2"
expect_docker_calls stop 1
expect_docker_calls up 1
expect_docker_calls logs 0
expect_within_ms $((cleanup_baseline_ms + 5000))
conclude "cleanup_stopAndUpNeverAnswer_deletesAlertsAndRestoresFlag"

# A loadgen the run B drain left paused is killed rather than stopped; that kill and the
# recreate never answering, cleanup goes on as above and names the kill. Same bound as above.
run_case cleanup-paused-docker-hangs case_cleanup hang-ignore-term 1
expect_status 1
expect_line "FAIL cleanup: loadgen not confirmed stopped: compose kill loadgen timed out after 2 s (Docker did not answer); loadgen not restored: recreating loadgen as [running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=0] timed out after 2 s (Docker did not answer)"
expect_line "INFO cleanup: 2 of 2 owned alerts deleted or already absent"
expect_line "INFO cleanup: flag portfolio-insights-enabled restored to enabled=false"
expect_rest_requests "$ALERT_ID_1" "$ALERT_ID_2"
expect_docker_calls kill 1
expect_docker_calls stop 0
expect_docker_calls up 1
expect_docker_calls logs 0
expect_within_ms $((cleanup_baseline_ms + 5000))
conclude "cleanup_pausedLoadgenKillAndUpNeverAnswer_deletesAlertsAndRestoresFlag"

# case_drain_pause_hang: loadgen-check.sh's run B drain over a quiescent window, one create
# deleted by its visit, with loadgen's pause never answering. The drain ends by the call limit,
# names the pause as timed out, and leaves LOADGEN_PAUSED at 1, so the stop that follows kills.
# shellcheck disable=SC2034 # The variables are the run state drain_loadgen reads.
case_drain_pause_hang() {
    load_script loadgen-check
    export FAKE_DOCKER_MODE_pause=hang-ignore-term
    local tags="[2026-01-01 00:00:00+00:00][worker:0][visit:portfolio_insights_alert][id:$VISIT_RUN_ID][INFO]:"
    printf '%s\n' "$tags Opening portfolio insights page" \
        "$tags Created alert [$ALERT_ID_1] threshold [1.5]" \
        "$tags Deleted alert [$ALERT_ID_1] via ui" >"$CASE_DIR/lines"
    export FAKE_DOCKER_LINES="$CASE_DIR/lines"
    WINDOW_LABEL=B
    WINDOW_SINCE="$LOG_SINCE_TEXT"
    DOCKER_CALL_TIMEOUT_SECONDS=2
    local status=0
    mark_start
    drain_loadgen || status=$?
    printf 'status %s\n' "$status"
    printf 'detail %s\n' "$DRAIN_DETAIL"
    printf 'paused %s\n' "$LOADGEN_PAUSED"
}
run_case drain-pause-hangs case_drain_pause_hang
expect_status 0
expect_line "status 1"
expect_line "detail pausing loadgen timed out after 2 s (Docker did not answer)"
expect_line "paused 1"
expect_within_ms 3000
expect_docker_calls logs 1
expect_docker_calls pause 1
expect_docker_calls kill 0
conclude "drainLoadgen_pauseNeverAnswers_failsByCallLimitAndLeavesKillToStop"

summarize
if [[ "$failed" -ne 0 ]]; then
    exit 1
fi
