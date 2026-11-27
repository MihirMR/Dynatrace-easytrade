#!/usr/bin/env bash
# Tests the verification paths of scripts/portfolio-insights/e2e.sh offline, through its real
# functions. Sourcing e2e.sh defines them without running its steps. Every outside call is a
# stub: shell functions while sourced (http, broker_logs, container_env, running_services, poll,
# docker, timeout, node, curl), scripts first on PATH when executed (docker, node, curl, a lossy
# jq), so no docker daemon, network or running stack is involved:
#   - the exact decimal helpers num_split, magnitude_cmp and num_cmp;
#   - the step-9 triggerValue verdict, the step-9 instrument choice and step9_trigger with both;
#   - alert_body, the create body of every alert request;
#   - the step-1 startup decision and flag body: startup_flag_default and step1_ready, including
#     a Docker read that fails or is cut off and a base URL that another stack's reverse proxy
#     serves;
#   - the flag reads and PUT answers of step2_flag_off, step11_browser and
#     step13_cleanup_and_disable;
#   - the step-5 rendered insights log line: insights_line_logged and step5_figures;
#   - the step-6 empty-account check and the step-8 AlertDTO filters (WANT_JQ, ALERT_JQ);
#   - the step-7 response checks response_kind and expect_error, step 7's unbindable PATCH
#     bodies and the reserved notifications routes of steps 2 and 7;
#   - e2e.sh executed: the jq literal-precision probe and a run whose services are down.
#
# Usage: scripts/portfolio-insights/e2e-checks-test.sh
#   --help  Show this help and exit
#
# Prints one PASS or FAIL line per check and a final SUMMARY line. Exits 0 when every check
# passes, 1 when any check fails, and 2 on a usage error or a missing tool (jq, or a jq that
# e2e.sh refuses). The run's temporary directory, which holds e2e.sh's run and private
# directories, is removed on exit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E="$SCRIPT_DIR/e2e.sh"
STUB_PROJECT="e2e-checks-test"
# A reserved name that never resolves, in case a request ever got past the stubs.
STUB_BASE_URL="http://e2e-checks-test.invalid"

usage() {
    cat <<'EOF'
Usage: scripts/portfolio-insights/e2e-checks-test.sh
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

if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required on PATH." >&2
    exit 2
fi
if [[ ! -f "$E2E" ]]; then
    echo "e2e.sh not found beside this test: $E2E" >&2
    exit 2
fi
REAL_JQ="$(command -v jq)"

checks_passed=0
checks_failed=0
reasons=()
TEST_DIR=""

# Named apart from e2e.sh's own cleanup, which sourcing defines.
remove_test_dir() {
    local status=$?
    trap - EXIT
    if [[ -n "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
    exit "$status"
}
trap remove_test_dir EXIT
trap 'exit 130' INT TERM

if ! TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/e2e-checks-test.XXXXXX")"; then
    echo "Could not create a temporary directory under ${TMPDIR:-/tmp}." >&2
    exit 2
fi

# ---------------------------------------------------------------------------------------------
# Reporting. e2e.sh defines pass, fail and expect_*, so this test's own names differ.

check_pass() {
    checks_passed=$((checks_passed + 1))
    echo "PASS $1"
}

check_fail() {
    checks_failed=$((checks_failed + 1))
    echo "FAIL $1: $2"
}

# flat TEXT: TEXT on one line, cut to 600 characters, for failure reasons.
flat() {
    local text="${1//$'\r'/}"
    text="${text//$'\n'/ | }"
    echo "${text:0:600}"
}

# assert_eq CHECK EXPECTED ACTUAL
assert_eq() {
    if [[ "$3" == "$2" ]]; then
        check_pass "$1"
    else
        check_fail "$1" "got [$3], expected [$2]"
    fi
}

# assert_line CHECK LINE: PASS when the captured OUT holds LINE as a whole line.
assert_line() {
    if grep -qxF -- "$2" <<<"$OUT"; then
        check_pass "$1"
    else
        check_fail "$1" "no line [$2] in output [$(flat "$OUT")]"
    fi
}

# want_line LINE / want_no_text TEXT / want_rc RC: collect a reason when the captured OUT or RC
# differs; conclude CHECK reports them as one PASS or FAIL line.
want_line() {
    if ! grep -qxF -- "$1" <<<"$OUT"; then
        reasons+=("no line [$1]")
    fi
}

want_no_text() {
    if grep -qF -- "$1" <<<"$OUT"; then
        reasons+=("output contains [$1]")
    fi
}

want_rc() {
    if [[ "$RC" -ne "$1" ]]; then
        reasons+=("exit status $RC, expected $1")
    fi
}

conclude() {
    local joined
    if [[ ${#reasons[@]} -eq 0 ]]; then
        check_pass "$1"
    else
        joined="$(printf '%s; ' "${reasons[@]}")"
        check_fail "$1" "${joined%; } (output [$(flat "$OUT")])"
    fi
    reasons=()
}

# capture COMMAND [ARGS...]: runs COMMAND in a subshell with errexit on, as main runs the steps,
# so an abort's exit ends only the subshell. Sets OUT (stdout and stderr) and RC.
capture() {
    set +e
    OUT="$(
        set -e
        "$@" 2>&1
    )"
    RC=$?
    set -e
}

# ---------------------------------------------------------------------------------------------
# Sourcing e2e.sh. Its preamble checks for docker and node and runs "docker compose version"
# under timeout(1): these functions satisfy both without a daemon. The project's compose logs of
# reverse-proxy, which step 1's target check reads, print STUB_PROXY_LOG, and every other docker
# call fails. curl fails as a transport error would, so a request that missed the http stub
# never leaves the machine.

# The named project's reverse-proxy log, and the log of the stack that serves BASE_URL, to which
# a routed target-check probe adds its access line: one file while the base URL is the
# project's own, another stack's log otherwise.
STUB_PROXY_LOG="$TEST_DIR/proxy.log"
STUB_SERVED_LOG="$STUB_PROXY_LOG"
: >"$STUB_PROXY_LOG"
: >"$TEST_DIR/other-proxy.log"

docker() {
    case "$*" in
        "compose version") return 0 ;;
        "compose -p $STUB_PROJECT -f $TEST_DIR/compose.yaml logs --no-color --no-log-prefix --since "*" reverse-proxy")
            cat "$STUB_PROXY_LOG"
            ;;
        *) return 1 ;;
    esac
}

# timeout [-k GRACE | -s SIGNAL] LIMIT COMMAND [ARGS...]: timeout(1) would exec the docker
# program on PATH, never the function above, so this one drops the options and the limit and
# runs COMMAND in this shell.
timeout() {
    while [[ "${1:-}" == -* ]]; do
        shift 2
    done
    shift
    "$@"
}

node() {
    return 1
}

curl() {
    return 7
}

: >"$TEST_DIR/compose.yaml"
TMPDIR="$TEST_DIR"
SOURCE_CHECK="e2eSource_validOptions_definesFunctionsWithoutRunningSteps"

# A sourcing that ran the steps would end this shell, so a first one runs in a subshell: it must
# print nothing before the marker. Exit status 2 is e2e.sh refusing a tool, as its message says.
set +e
OUT="$(
    # shellcheck source-path=SCRIPTDIR source=e2e.sh
    source "$E2E" --project "$STUB_PROJECT" --base-url "$STUB_BASE_URL" \
        --compose-file "$TEST_DIR/compose.yaml" 2>&1
    echo "sourced"
)"
RC=$?
set -e
if [[ $RC -eq 2 ]]; then
    echo "$OUT" >&2
    exit 2
fi
if [[ $RC -ne 0 || "$OUT" != "sourced" ]]; then
    check_fail "$SOURCE_CHECK" "sourcing exited $RC before its end or printed output, so a step ran: $(flat "$OUT")"
    echo "SUMMARY $checks_passed passed, $checks_failed failed"
    exit 1
fi

# shellcheck source-path=SCRIPTDIR source=e2e.sh
source "$E2E" --project "$STUB_PROJECT" --base-url "$STUB_BASE_URL" \
    --compose-file "$TEST_DIR/compose.yaml" >"$TEST_DIR/source.out"

OUT="$(cat "$TEST_DIR/source.out")"
if ! declare -F main step1_ready step9_trigger pick_close_instrument trigger_value_verdict >/dev/null; then
    reasons+=("main, a step or a step-9 helper is not defined")
fi
if [[ -n "$OUT" ]]; then
    reasons+=("sourcing printed output, so a step ran")
fi
if [[ "$RUN_DIR" != "$TEST_DIR"/pi-e2e.* || ! -d "$RUN_DIR" ]]; then
    reasons+=("run directory [$RUN_DIR] is not inside $TEST_DIR")
fi
private_dir_ok=1
if [[ -z "${PRIVATE_DIR:-}" || "$PRIVATE_DIR" != "$TEST_DIR"/pi-e2e-private.* || ! -d "$PRIVATE_DIR" ]]; then
    reasons+=("private directory [${PRIVATE_DIR:-}] is not a directory inside $TEST_DIR")
    private_dir_ok=0
fi
conclude "$SOURCE_CHECK"
# Every stubbed response below goes to the private directory, so no later check can run without it.
if [[ $private_dir_ok -eq 0 ]]; then
    echo "SUMMARY $checks_passed passed, $checks_failed failed"
    exit 1
fi

# ---------------------------------------------------------------------------------------------
# Stubs of e2e.sh's outside calls. Each section sets the STUB_* values or redefines
# route_response for the responses it needs.

# last_response STATUS CONTENT_TYPE BODY: the HTTP_* globals and $PRIVATE_DIR/body and
# $PRIVATE_DIR/headers, the files e2e.sh's http writes and its checks read, as http leaves them
# after a response; status 000 is a transport error.
last_response() {
    HTTP_STATUS="$1"
    HTTP_CTYPE="$2"
    HTTP_BODY="$3"
    HTTP_ERROR=""
    if [[ "$1" == "000" ]]; then
        HTTP_ERROR="stubbed transport error"
    fi
    printf '%s' "$3" >"$PRIVATE_DIR/body"
    : >"$PRIVATE_DIR/headers"
}

# route_response METHOD URL [BODY]: answers a stubbed request through last_response; fails
# for a request the current section does not route.
# shellcheck disable=SC2329 # Invoked through the http stub.
route_response() {
    return 1
}

# http METHOD URL [BODY]: records "METHOD URL" in $TEST_DIR/requests and answers through
# route_response; a request without a route gets a transport error.
http() {
    echo "$1 $2" >>"$TEST_DIR/requests"
    if ! route_response "$@"; then
        last_response 000 "" ""
    fi
}

STUB_PS_RC=0
# running_services: the services a shipped stack runs, or, with STUB_PS_RC not 0, nothing and
# that status, as a services query that fails (124 or 137 when its call limit cut it off).
running_services() {
    if [[ $STUB_PS_RC -ne 0 ]]; then
        return "$STUB_PS_RC"
    fi
    tr ' ' '\n' <<<"$REQUIRED_SERVICES"
}

STUB_ENV_MODE="unset"
STUB_ENV_VALUE=""
STUB_INTERVAL_VALUE="60"
STUB_FAILED_READ=""
STUB_FAILED_RC=1
# container_env SERVICE NAME: ENABLE_PORTFOLIO_INSIGHTS per STUB_ENV_MODE (unset, value or
# fail), the dialect a shipped stack reports, and the interval STUB_INTERVAL_VALUE, unset when
# empty. The read STUB_FAILED_READ names, "SERVICE NAME", prints nothing and fails with
# STUB_FAILED_RC instead, as a Docker read that fails or is cut off does. Like the real one, it
# prints the value byte for byte with no line feed added.
container_env() {
    if [[ "$1 $2" == "$STUB_FAILED_READ" ]]; then
        return "$STUB_FAILED_RC"
    fi
    case "$1 $2" in
        "feature-flag-service ENABLE_PORTFOLIO_INSIGHTS")
            case "$STUB_ENV_MODE" in
                unset) return 0 ;;
                value) printf '%s' "$STUB_ENV_VALUE" ;;
                *) return 1 ;;
            esac
            ;;
        "db-adapter DB_TYPE") printf '%s' postgres ;;
        "broker-service ALERT_EVALUATION_INTERVAL_SECONDS") printf '%s' "$STUB_INTERVAL_VALUE" ;;
        *) return 1 ;;
    esac
}

STUB_LOG=""
broker_logs() {
    printf '%s\n' "$STUB_LOG"
}

# poll CHECK TIMEOUT STEP COMMAND [ARGS...]: e2e.sh's poll with one attempt and no sleep; on a
# miss it reports as the real one does when its deadline expires.
poll() {
    local check="$1" timeout="$2"
    shift 3
    POLL_DETAIL=""
    if "$@"; then
        return 0
    fi
    fail "$check" "deadline $timeout s expired${POLL_DETAIL:+; $POLL_DETAIL}"
    return 1
}

# ---------------------------------------------------------------------------------------------
# num_split: exact reading of a number as jq prints it.

# num_split_row SCENARIO_RESULT TEXT EXPECTED: EXPECTED is "[sign] [digits] point integers
# fractions" or "not a number".
num_split_row() {
    local got="not a number"
    if num_split "$2"; then
        got="[$NUM_SIGN] [$NUM_DIGITS] $NUM_POINT $NUM_INTEGERS $NUM_FRACTIONS"
    fi
    assert_eq "numSplit_$1" "$3" "$got"
}

NINES_28="9999999999999999999999999999"
num_split_row maxTriggerValue_twentyIntegerAndEightFractionDigits \
    99999999999999999999.99999999 "[] [$NINES_28] 20 20 8"
num_split_row negativeMaxTriggerValue_minusSignAndSameDigits \
    -99999999999999999999.99999999 "[-] [$NINES_28] 20 20 8"
num_split_row twentyOneIntegerDigits_twentyOneIntegers 100000000000000000000 "[] [1] 21 21 0"
num_split_row exponentMinusEight_eightFractionDigits 1E-8 "[] [1] -7 0 8"
num_split_row negativeExponentMinusEight_minusSign -1E-8 "[-] [1] -7 0 8"
num_split_row exponentPlusThree_pointShifted 1.5E+3 "[] [15] 4 4 0"
num_split_row lowerCaseExponent_pointShifted 2.5e-1 "[] [25] 0 0 2"
num_split_row negativeZero_zeroWithoutSign -0 "[] [] 0 0 0"
num_split_row zeroWithLargeExponent_zero 0E-5000 "[] [] 0 0 0"
num_split_row trailingZeros_dropped 12.30000000 "[] [123] 2 2 1"
num_split_row leadingZeros_dropped 0012.5000 "[] [125] 2 2 1"
num_split_row eighteenDigitExponent_capped 1E+999999999999999999999 \
    "[] [1] 100000000000000001 100000000000000001 0"
for text in abc '"12"' null 1e .5 '' '1 2' +1 1.2.3 0x10; do
    num_split_row "notJsonNumber[$text]_notANumber" "$text" "not a number"
done

# ---------------------------------------------------------------------------------------------
# magnitude_cmp: digit-string magnitudes as num_split gives them.

# magnitude_cmp_row SCENARIO_RESULT DIGITS_A POINT_A DIGITS_B POINT_B EXPECTED
magnitude_cmp_row() {
    assert_eq "magnitudeCmp_$1" "$6" "$(magnitude_cmp "$2" "$3" "$4" "$5")"
}

magnitude_cmp_row bothZero_equal "" 0 "" 0 0
magnitude_cmp_row zeroAgainstNonzero_below "" 0 1 -7 -1
magnitude_cmp_row nonzeroAgainstZero_above 1 -7 "" 0 1
magnitude_cmp_row laterPoint_above 1 2 9 1 1
magnitude_cmp_row earlierPoint_below 9 1 1 2 -1
magnitude_cmp_row samePointShorterDigits_padded 12 1 119 1 1
magnitude_cmp_row samePointLongerDigits_padded 119 1 12 1 -1
magnitude_cmp_row sameDigitsAndPoint_equal 15 4 15 4 0
magnitude_cmp_row twentyEighthDigitHigher_above "$NINES_28" 20 "${NINES_28:0:27}8" 20 1
magnitude_cmp_row twentyEighthDigitLower_below "${NINES_28:0:27}8" 20 "$NINES_28" 20 -1

# ---------------------------------------------------------------------------------------------
# num_cmp: exact comparison at any length.

# num_cmp_row SCENARIO_RESULT A B EXPECTED: EXPECTED is -1, 0, 1 or "error".
num_cmp_row() {
    local got
    got="$(num_cmp "$2" "$3")" || got="error"
    assert_eq "numCmp_$1" "$4" "$got"
}

num_cmp_row maxAgainstOneUnitLess_above 99999999999999999999.99999999 99999999999999999999.99999998 1
num_cmp_row oneUnitLessAgainstMax_below 99999999999999999999.99999998 99999999999999999999.99999999 -1
num_cmp_row negativeMaxAgainstMax_below -99999999999999999999.99999999 99999999999999999999.99999999 -1
num_cmp_row negativeMaxAgainstNegativeOneUnitLess_below \
    -99999999999999999999.99999999 -99999999999999999999.99999998 -1
num_cmp_row maxAgainstItself_equal 99999999999999999999.99999999 99999999999999999999.99999999 0
num_cmp_row twentyOneIntegerDigitsAgainstMax_above 100000000000000000000 99999999999999999999.99999999 1
num_cmp_row negativeZeroAgainstZero_equal -0 0 0
num_cmp_row zeroAgainstNegativeZero_equal 0 -0 0
num_cmp_row zerosWithFractionDigits_equal 0.0 -0.00000000 0
num_cmp_row exponentAgainstPlain_equal 1E-8 0.00000001 0
num_cmp_row negativeExponentAgainstPlain_equal -1E-8 -0.00000001 0
num_cmp_row negativeExponentAgainstZero_below -1E-8 0 -1
num_cmp_row zeroAgainstNegativeExponent_above 0 -1E-8 1
num_cmp_row exponentPlusThreeAgainstPlain_equal 1.5E+3 1500 0
num_cmp_row exponentPlusThreeAgainstOneUnitMore_below 1.5E+3 1500.00000001 -1
num_cmp_row trailingZeros_equal 1.50 1.5 0
num_cmp_row tenAgainstOneUnitLess_above 10 9.99999999 1
num_cmp_row negativeTenthsAgainstHundredths_below -0.1 -0.09 -1
num_cmp_row notNumberFirst_error abc 1 error
num_cmp_row notNumberSecond_error 1 abc error
num_cmp_row quotedNumber_error '"12"' 12 error

# ---------------------------------------------------------------------------------------------
# trigger_value_verdict: the step-9 triggerValue check.

DOMAIN="outside the trigger-value domain of at most 20 and 8"
# verdict_row SCENARIO_RESULT DIRECTION THRESHOLD TYPE VALUE EXPECTED
verdict_row() {
    assert_eq "triggerValueVerdict_$1" "$6" "$(trigger_value_verdict "$2" "$3" "$4" "$5")"
}

verdict_row aboveHigherValue_ok ABOVE 10 number 10.00000001 ok
verdict_row aboveEqualValue_ok ABOVE 10 number 10 ok
verdict_row aboveLowerValue_notOnSide ABOVE 10 number 9.99999999 \
    "triggerValue 9.99999999 is not on the ABOVE side of threshold 10"
verdict_row belowLowerValue_ok BELOW 10 number 9.99999999 ok
verdict_row belowEqualExponentValue_ok BELOW 0.00000001 number 1E-8 ok
verdict_row belowHigherValue_notOnSide BELOW 0.00000001 number 2E-8 \
    "triggerValue 2E-8 is not on the BELOW side of threshold 0.00000001"
verdict_row aboveEqualNegativeExponent_ok ABOVE -0.00000001 number -1E-8 ok
verdict_row aboveNegativeExponentBelowThreshold_notOnSide ABOVE -0.00000001 number -2E-8 \
    "triggerValue -2E-8 is not on the ABOVE side of threshold -0.00000001"
verdict_row aboveMaxTriggerValue_ok ABOVE 9999999999.99999998 number 99999999999999999999.99999999 ok
verdict_row belowNegativeMaxTriggerValue_ok BELOW 0.00000001 number -99999999999999999999.99999999 ok
verdict_row twentyOneIntegerDigits_outOfDomain ABOVE 1 number 100000000000000000000 \
    "triggerValue has 21 integer and 0 fractional digits, $DOMAIN"
verdict_row exponentTwentyOneIntegerDigits_outOfDomain ABOVE 1 number 1E+20 \
    "triggerValue has 21 integer and 0 fractional digits, $DOMAIN"
verdict_row nineFractionDigits_outOfDomain BELOW 1 number 0.000000001 \
    "triggerValue has 0 integer and 9 fractional digits, $DOMAIN"
verdict_row stringType_wrongType ABOVE 1 string '"12"' "triggerValue has JSON type string, expected number"
verdict_row nullType_wrongType ABOVE 1 null null "triggerValue has JSON type null, expected number"
verdict_row noType_unknownType ABOVE 1 "" "" "triggerValue has JSON type unknown, expected number"
verdict_row numberInUnreadableForm_unreadable ABOVE 1 number 1.2.3 \
    "triggerValue is a JSON number in a form this script cannot read"
verdict_row unreadableThreshold_unreadable ABOVE abc number 1 \
    "threshold [abc] of this run is not a readable decimal"

# ---------------------------------------------------------------------------------------------
# pick_close_instrument: the step-9 instrument choice over the listing body.

U1="11111111-1111-4111-8111-111111111111"
U2="22222222-2222-4222-8222-222222222222"
SECOND="{\"id\":\"$U2\",\"amount\":1,\"price\":{\"close\":3}}"
# pick_row SCENARIO_RESULT LISTING EXPECTED: EXPECTED is "ID UNITS" or "none".
pick_row() {
    local got
    if pick_close_instrument "$2"; then
        got="$CHOSEN_ID $CHOSEN_UNITS"
    else
        got="none${CHOSEN_ID}${CHOSEN_UNITS}"
    fi
    assert_eq "pickCloseInstrument_$1" "$3" "$got"
}

pick_row canonicalId_chosen "{\"results\":[{\"id\":\"$U1\",\"amount\":1,\"price\":{\"close\":12.5}}]}" \
    "$U1 1250000000"
pick_row upperCaseId_chosenInLowerCase \
    "{\"results\":[{\"id\":\"${U1^^}\",\"amount\":2,\"price\":{\"close\":12.5}}]}" "$U1 1250000000"
pick_row nonCanonicalId_skipped \
    "{\"results\":[{\"id\":\"not-a-guid\",\"amount\":1,\"price\":{\"close\":12.5}},$SECOND]}" "$U2 300000000"
pick_row misplacedDashesId_skipped \
    "{\"results\":[{\"id\":\"1111111-11111-4111-8111-111111111111\",\"amount\":1,\"price\":{\"close\":5}},$SECOND]}" \
    "$U2 300000000"
pick_row jsonInjectionId_skipped \
    "{\"results\":[{\"id\":\"$U1\\\",\\\"type\\\":\\\"PROFIT_LOSS\",\"amount\":1,\"price\":{\"close\":5}},$SECOND]}" \
    "$U2 300000000"
pick_row lineForgingId_skipped \
    "{\"results\":[{\"id\":\"x\\n$U1 5\\ny\",\"amount\":1,\"price\":{\"close\":5}},$SECOND]}" "$U2 300000000"
pick_row numericId_skipped "{\"results\":[{\"id\":12345,\"amount\":1,\"price\":{\"close\":5}},$SECOND]}" \
    "$U2 300000000"
pick_row stringAmount_skipped "{\"results\":[{\"id\":\"$U1\",\"amount\":\"1\",\"price\":{\"close\":5}},$SECOND]}" \
    "$U2 300000000"
pick_row stringClose_skipped "{\"results\":[{\"id\":\"$U1\",\"amount\":1,\"price\":{\"close\":\"5\"}},$SECOND]}" \
    "$U2 300000000"
pick_row unheldInstrument_skipped "{\"results\":[{\"id\":\"$U1\",\"amount\":0,\"price\":{\"close\":5}},$SECOND]}" \
    "$U2 300000000"
pick_row closeBelowRange_skipped \
    "{\"results\":[{\"id\":\"$U1\",\"amount\":1,\"price\":{\"close\":0.00000001}},$SECOND]}" "$U2 300000000"
pick_row closeAboveRange_skipped \
    "{\"results\":[{\"id\":\"$U1\",\"amount\":1,\"price\":{\"close\":9999999999.99999999}},$SECOND]}" \
    "$U2 300000000"
pick_row lowestUsableClose_chosen \
    "{\"results\":[{\"id\":\"$U1\",\"amount\":1,\"price\":{\"close\":0.00000002}}]}" "$U1 2"
pick_row highestUsableClose_chosen \
    "{\"results\":[{\"id\":\"$U1\",\"amount\":1,\"price\":{\"close\":9999999999.99999998}}]}" \
    "$U1 999999999999999998"
pick_row exponentClose_chosen "{\"results\":[{\"id\":\"$U1\",\"amount\":1,\"price\":{\"close\":1E-7}}]}" "$U1 10"
pick_row noUsableInstrument_none \
    "{\"results\":[{\"id\":\"not-a-guid\",\"amount\":1,\"price\":{\"close\":12.5}}]}" "none"
pick_row emptyListing_none '{"results":[]}' "none"
pick_row unreadableBody_none 'not json' "none"

# ---------------------------------------------------------------------------------------------
# step9_trigger: the instrument choice and the triggerValue verdict as the step uses them.

HOLDER_ID="210e9235-10d0-4f73-b88d-5aad621a1972"
STUB_LISTING=""
STUB_NOTIFICATIONS=""
STUB_POSTS=0
# shellcheck disable=SC2329 # Invoked through the http stub.
route_response() {
    case "$1 $2" in
        "GET $B/v1/instrument?accountId=$HOLDER_ID")
            last_response 200 "application/json; charset=utf-8" "$STUB_LISTING"
            ;;
        "POST $ALERTS_URL")
            STUB_POSTS=$((STUB_POSTS + 1))
            last_response 201 "application/json; charset=utf-8" \
                "{\"id\":\"aaaaaaaa-0000-4000-8000-00000000000$STUB_POSTS\"}"
            ;;
        "GET $ALERTS_URL/notifications?accountId=$HOLDER_ID")
            last_response 200 "application/json; charset=utf-8" "$STUB_NOTIFICATIONS"
            ;;
        *) return 1 ;;
    esac
}

# reset_alert_files: forgets the alerts and pairs a previous step run recorded.
reset_alert_files() {
    local name
    for name in owned deleted pairs triggered listed; do
        : >"$RUN_DIR/$name"
    done
    : >"$TEST_DIR/requests"
}

notification() { # ID VALUE
    printf '{"id":"%s","armingRevision":1,"triggeredAt":"2026-11-26T01:02:03.456+00:00","triggerValue":%s}' "$1" "$2"
}
trigger_line() { # N DIRECTION THRESHOLD
    printf '[26/11/26 01:02:03 | Information] Alert [aaaaaaaa-0000-4000-8000-00000000000%s] triggered for account [%s] type [X] direction [%s] threshold [%s] value [1] revision [1] | AlertEvaluationService' \
        "$1" "$HOLDER_ID" "$2" "$3"
}
ID_PREFIX="aaaaaaaa-0000-4000-8000-00000000000"
STUB_LISTING="{\"results\":[{\"id\":\"not-a-guid\",\"amount\":1,\"price\":{\"close\":7}},{\"id\":\"$U1\",\"amount\":1,\"price\":{\"close\":12.5}}]}"
STUB_NOTIFICATIONS="{\"results\":[$(notification "${ID_PREFIX}1" 12.5),$(notification "${ID_PREFIX}2" 12.6),$(notification "${ID_PREFIX}3" -1E-8),$(notification "${ID_PREFIX}4" '"0"')]}"
STUB_LOG="[26/11/26 01:02:00 | Information] Alert evaluation cycle finished: 0 triggered | AlertEvaluationService
$(trigger_line 1 ABOVE 12.49999999)
$(trigger_line 2 BELOW 12.50000001)
$(trigger_line 3 ABOVE -0.00000001)
$(trigger_line 4 BELOW 0.00000001)"
reset_alert_files
STUB_POSTS=0
capture step9_trigger

assert_line step9Trigger_canonicalInstrumentListedSecond_passesInstrumentCheck \
    "PASS step 9 instrument with a usable close"
assert_line step9Trigger_chosenClose_infoNamesInstrumentAndClose \
    "INFO pair alerts on instrument [$U1], listed close 12.5"
if [[ "$(grep -cxF "POST $ALERTS_URL" "$TEST_DIR/requests")" == 4 ]] &&
    grep -qx "${ID_PREFIX}1 target_price TARGET_PRICE ABOVE 12.49999999" "$RUN_DIR/pairs" &&
    grep -qx "${ID_PREFIX}2 target_price TARGET_PRICE BELOW 12.50000001" "$RUN_DIR/pairs" &&
    grep -qx "${ID_PREFIX}3 profit_loss PROFIT_LOSS ABOVE -0.00000001" "$RUN_DIR/pairs" &&
    grep -qx "${ID_PREFIX}4 profit_loss PROFIT_LOSS BELOW 0.00000001" "$RUN_DIR/pairs"; then
    check_pass step9Trigger_closeOneStepEitherSide_createsFourPairAlerts
else
    check_fail step9Trigger_closeOneStepEitherSide_createsFourPairAlerts \
        "requests [$(flat "$(cat "$TEST_DIR/requests")")], pairs [$(flat "$(cat "$RUN_DIR/pairs")")]"
fi
assert_line step9Trigger_valueAboveThreshold_passesTriggerValue "PASS step 9 target_price ABOVE trigger value"
assert_line step9Trigger_valueAboveBelowThreshold_failsNotOnSide \
    "FAIL step 9 target_price BELOW trigger value: triggerValue 12.6 is not on the BELOW side of threshold 12.50000001"
assert_line step9Trigger_exponentValueEqualToThreshold_passesTriggerValue \
    "PASS step 9 profit_loss ABOVE trigger value"
assert_line step9Trigger_stringValue_failsWrongType \
    "FAIL step 9 profit_loss BELOW trigger value: triggerValue has JSON type string, expected number"
assert_line step9Trigger_triggerLineInFirstCycle_passesLogLine "PASS step 9 target_price ABOVE trigger log line"

# A revision the server sends as text reaches the INFO line as its digits only.
STUB_NOTIFICATIONS="{\"results\":[$(notification "${ID_PREFIX}1" 12.5 |
    jq -c '.armingRevision = "\u001b[2J7"' | tr -d '\r')]}"
reset_alert_files
STUB_POSTS=0
capture step9_trigger
want_line "INFO triggered target_price ABOVE ${ID_PREFIX}1 revision ??2?7"
want_no_text "$(printf '\033')"
conclude step9Trigger_textRevision_infoShowsDigitsOnly

STUB_LISTING="{\"results\":[{\"id\":\"not-a-guid\",\"amount\":1,\"price\":{\"close\":12.5}},{\"id\":\"$U1\",\"amount\":\"1\",\"price\":{\"close\":12.5}}]}"
reset_alert_files
capture step9_trigger
want_line "FAIL step 9 instrument with a usable close: no held instrument with a canonical id has a close from 0.00000002 to 9999999999.99999998 (listing status 200)"
want_line "FAIL step 10 no second notification: skipped: no held instrument with a usable close"
want_line "FAIL step 11 browser flag-on: skipped: no held instrument with a usable close"
want_line "FAIL step 12 untriggered acknowledge: skipped: no held instrument with a usable close"
if grep -q '^POST ' "$TEST_DIR/requests"; then
    reasons+=("an alert was created")
fi
conclude step9Trigger_noUsableInstrument_failsAndSkipsLaterStepsWithoutCreating
reset_alert_files

# ---------------------------------------------------------------------------------------------
# alert_body: four JSON-encoded strings and the threshold token as given.

# alert_body_row SCENARIO_RESULT ACCOUNT TYPE INSTRUMENT DIRECTION THRESHOLD EXPECTED
alert_body_row() {
    local got
    got="$(alert_body "$2" "$3" "$4" "$5" "$6")" || got="alert_body failed"
    assert_eq "alertBody_$1" "$7" "$got"
}

alert_body_row plainValues_compactObject a TARGET_PRICE i ABOVE 1 \
    '{"accountId":"a","type":"TARGET_PRICE","instrumentId":"i","direction":"ABOVE","threshold":1}'
alert_body_row quoteAndBackslash_escaped 'a"b\c' 'x\"y' i d 1 \
    '{"accountId":"a\"b\\c","type":"x\\\"y","instrumentId":"i","direction":"d","threshold":1}'
alert_body_row newline_escaped $'a\nb' t i d 1 \
    '{"accountId":"a\nb","type":"t","instrumentId":"i","direction":"d","threshold":1}'
alert_body_row pathLikeValues_unchanged /etc/passwd 'C:\Temp' //server/share /tmp/x:/y 1 \
    '{"accountId":"/etc/passwd","type":"C:\\Temp","instrumentId":"//server/share","direction":"/tmp/x:/y","threshold":1}'
alert_body_row fieldInjection_staysOneString 'x","type":"PROFIT_LOSS' t i d 2 \
    '{"accountId":"x\",\"type\":\"PROFIT_LOSS","type":"t","instrumentId":"i","direction":"d","threshold":2}'
alert_body_row emptyStrings_keptEmpty "" "" "" "" 1 \
    '{"accountId":"","type":"","instrumentId":"","direction":"","threshold":1}'
for token in '"abc"' '"12"' 1e5 10000000000 0.000000001 0.000000010000000000000000000001 -1 \
    -0.00000001 9999999999.99999999; do
    alert_body_row "thresholdToken[$token]_writtenUnchanged" a TARGET_PRICE i ABOVE "$token" \
        "{\"accountId\":\"a\",\"type\":\"TARGET_PRICE\",\"instrumentId\":\"i\",\"direction\":\"ABOVE\",\"threshold\":$token}"
done
assert_eq alertBody_fieldInjection_parsesWithAccountIdIntact 'x","type":"PROFIT_LOSS|t' \
    "$(alert_body 'x","type":"PROFIT_LOSS' t i d 1 | jq -r '"\(.accountId)|\(.type)"' | tr -d '\r')"

# ---------------------------------------------------------------------------------------------
# startup_flag_default and step1_ready: the run starts only on the shipped default, disabled.

# startup_row SCENARIO_RESULT VALUE EXPECTED
startup_row() {
    assert_eq "startupFlagDefault_$1" "$3" "$(startup_flag_default "$2")"
}

for value in 1 t T TRUE true True; do
    startup_row "parseBoolTrueSpelling[$value]_true" "$value" true
done
for value in 0 f F FALSE false False; do
    startup_row "parseBoolFalseSpelling[$value]_false" "$value" false
done
startup_row emptyValue_false "" false
startup_row yes_unparsableSoFalse yes false
startup_row leadingSpaceTrue_unparsableSoFalse " true" false
startup_row mixedCaseTrue_unparsableSoFalse tRUE false
startup_row on_unparsableSoFalse on false

STUB_FLAG_ENABLED="false"
# The body the flag GET answers; empty for a modifiable flag whose enabled is STUB_FLAG_ENABLED.
STUB_FLAG_BODY=""
# shellcheck disable=SC2329 # Invoked through the http stub.
route_response() {
    local flag="{\"id\":\"$FLAG_ID\",\"description\":\"Portfolio Insights\",\"enabled\":$STUB_FLAG_ENABLED,\"isModifiable\":true,\"tag\":\"feature\"}"
    case "$1 $2" in
        "GET $BASE_URL/broker-service/readyz" | "GET $BASE_URL/feature-flag-service/readyz")
            last_response 200 "text/plain" "Healthy"
            ;;
        # The target check's probes, logged by the stack that serves the base URL.
        "GET $BASE_URL/broker-service/readyz?pi-target="* | "GET $BASE_URL/feature-flag-service/readyz?pi-target="*)
            printf '172.23.0.1 - [26/Nov/2026:21:30:41 +0000] "GET %s HTTP/1.1" 200 2 "-" "curl/8.21.0"\n' \
                "${2#"$BASE_URL"}" >>"$STUB_SERVED_LOG"
            last_response 200 "text/plain" "Healthy"
            ;;
        "GET $F")
            last_response 200 "application/json; charset=utf-8" "${STUB_FLAG_BODY:-$flag}"
            ;;
        *) return 1 ;;
    esac
}

# step1_row SCENARIO_RESULT FLAG ENV_MODE ENV_VALUE OUTCOME [STARTUP_DEFAULT]: OUTCOME is pass,
# enabled (the flag or the startup setting is on, the setting giving STARTUP_DEFAULT) or unread
# (the startup setting cannot be read). Every outcome sends GET requests only: nothing is written.
# ENV_VALUE is reported as printf %q writes it, so a control character stays on the line.
step1_row() {
    local outcome="$5" shown=""
    STUB_FLAG_ENABLED="$2"
    STUB_ENV_MODE="$3"
    STUB_ENV_VALUE="$4"
    if [[ -n "$4" ]]; then
        printf -v shown '%q' "$4"
    fi
    : >"$TEST_DIR/requests"
    capture step1_ready
    case "$outcome" in
        pass)
            want_rc 0
            want_line "PASS step 1 target project"
            want_line "PASS step 1 flag default disabled"
            want_line "INFO flag $FLAG_ID initially enabled=false; ENABLE_PORTFOLIO_INSIGHTS [$shown]"
            want_line "PASS step 1 runtime facts"
            ;;
        enabled)
            want_rc 1
            want_line "FAIL step 1 flag default disabled: the flag reads enabled [$2] and ENABLE_PORTFOLIO_INSIGHTS [$shown] gives startup default enabled [${6:-}]; the run needs the shipped default, disabled, on both"
            want_no_text "runtime facts"
            ;;
        unread)
            want_rc 1
            want_line "FAIL step 1 flag default disabled: reading ENABLE_PORTFOLIO_INSIGHTS from the feature-flag-service container of project [$STUB_PROJECT] failed, exit 1 (see $RUN_DIR/compose.log); the run needs the shipped default, disabled"
            want_no_text "runtime facts"
            ;;
    esac
    if grep -qv '^GET ' "$TEST_DIR/requests"; then
        reasons+=("a request other than GET was sent: $(flat "$(grep -v '^GET ' "$TEST_DIR/requests")")")
    fi
    conclude "step1Ready_$1"
}

step1_row shippedDefaultUnset_passesWithoutWrite false unset "" pass
step1_row startupSettingFalse_passesWithoutWrite false value false pass
step1_row startupSettingZero_passesWithoutWrite false value 0 pass
step1_row startupSettingUnparsable_passesWithoutWrite false value yes pass
# strconv.ParseBool reads the value untrimmed, so a true with a trailing line feed or carriage
# return is unparsable and the service starts disabled; the run reads it byte for byte too.
step1_row startupSettingTrueLineFeed_passesWithoutWrite false value $'true\n' pass
step1_row startupSettingTrueCarriageReturn_passesWithoutWrite false value $'true\r' pass
step1_row flagEnabled_abortsWithoutWrite true unset "" enabled false
step1_row flagEnabledStartupSettingFalse_abortsWithoutWrite true value false enabled false
step1_row startupSettingTrue_abortsWithoutWrite false value true enabled true
step1_row startupSettingOne_abortsWithoutWrite false value 1 enabled true
step1_row containerEnvFails_abortsWithoutWrite false fail "" unread
step1_row flagEnabledContainerEnvFails_abortsWithoutWrite true fail "" unread
STUB_ENV_MODE="unset"

# step1_docker_row SCENARIO_RESULT PS_RC FAILED_READ FAILED_RC REQUESTS LINE: the services query
# ends with PS_RC, or the container read FAILED_READ ("SERVICE NAME") fails with FAILED_RC, 124 and
# 137 being a call its limit cut off. Step 1 stops there with LINE, a FAIL that names the Docker
# problem, never a list of missing services or a default for an unset setting; it sends exactly
# REQUESTS requests, all GETs, so nothing is written.
step1_docker_row() {
    local count
    STUB_FLAG_ENABLED=false
    STUB_PS_RC="$2"
    STUB_FAILED_READ="$3"
    STUB_FAILED_RC="$4"
    : >"$TEST_DIR/requests"
    capture step1_ready
    want_rc 1
    want_line "$6"
    want_no_text "PASS step 1 runtime facts"
    count="$(grep -c '' "$TEST_DIR/requests" || true)"
    if [[ "$count" -ne "$5" ]]; then
        reasons+=("$count requests sent, expected $5")
    fi
    if grep -qv '^GET ' "$TEST_DIR/requests"; then
        reasons+=("a request other than GET was sent: $(flat "$(grep -v '^GET ' "$TEST_DIR/requests")")")
    fi
    STUB_PS_RC=0
    STUB_FAILED_READ=""
    STUB_FAILED_RC=1
    conclude "step1Ready_$1"
}

FLAG_READ="feature-flag-service ENABLE_PORTFOLIO_INSIGHTS"
DIALECT_READ="db-adapter DB_TYPE"
INTERVAL_READ="broker-service ALERT_EVALUATION_INTERVAL_SECONDS"
TIMED_OUT="timed out after $DOCKER_CALL_TIMEOUT_SECONDS s (Docker did not answer)"
of_project="of project [$STUB_PROJECT]"
step1_docker_row servicesQueryCutOff_abortsBeforeReadinessWithTimeout 137 "" 1 0 \
    "FAIL step 1 services running: listing the running services $of_project $TIMED_OUT"
step1_docker_row servicesQueryFails_abortsBeforeReadinessWithExitStatus 3 "" 1 0 \
    "FAIL step 1 services running: listing the running services $of_project failed, exit 3 (see $RUN_DIR/compose.log)"
# Past the services query, five GETs: both readyz, both target-check probes and the flag read.
step1_docker_row flagDefaultReadCutOff_abortsWithTimeout 0 "$FLAG_READ" 137 5 \
    "FAIL step 1 flag default disabled: reading ENABLE_PORTFOLIO_INSIGHTS from the feature-flag-service container $of_project $TIMED_OUT; the run needs the shipped default, disabled"
step1_docker_row dialectReadCutOff_abortsRuntimeFactsWithTimeout 0 "$DIALECT_READ" 124 5 \
    "FAIL step 1 runtime facts: reading DB_TYPE from the db-adapter container $of_project $TIMED_OUT"
step1_docker_row dialectReadFails_abortsRuntimeFactsWithExitStatus 0 "$DIALECT_READ" 1 5 \
    "FAIL step 1 runtime facts: reading DB_TYPE from the db-adapter container $of_project failed, exit 1 (see $RUN_DIR/compose.log)"
step1_docker_row intervalReadCutOff_abortsRuntimeFactsWithoutDefault 0 "$INTERVAL_READ" 137 5 \
    "FAIL step 1 runtime facts: reading ALERT_EVALUATION_INTERVAL_SECONDS from the broker-service container $of_project $TIMED_OUT"
step1_docker_row intervalReadFails_abortsRuntimeFactsWithoutDefault 0 "$INTERVAL_READ" 1 5 \
    "FAIL step 1 runtime facts: reading ALERT_EVALUATION_INTERVAL_SECONDS from the broker-service container $of_project failed, exit 1 (see $RUN_DIR/compose.log)"

# step1_ready_fake_clock: step1_ready on a clock only sleep advances, so the target check's
# deadline passes without waiting.
step1_ready_fake_clock() {
    unset SECONDS
    SECONDS=0
    sleep() {
        SECONDS=$((SECONDS + $1))
    }
    step1_ready
}

# Two otherwise valid stacks: the base URL is served by another stack, whose reverse proxy logs
# the probes, while the named project's log never shows them. Step 1 stops at its target check,
# with readiness passed, before the flag read whose value cleanup restores, and so before any
# write; its only requests are the two readyz GETs and the two probes.
step1_target_mismatch_row() {
    local requests want_re
    STUB_FLAG_ENABLED=false
    STUB_SERVED_LOG="$TEST_DIR/other-proxy.log"
    : >"$TEST_DIR/requests"
    capture step1_ready_fake_clock
    want_rc 1
    want_line "PASS step 1 readiness"
    want_line "FAIL step 1 target project: base url $STUB_BASE_URL is not served by the reverse-proxy of project [$STUB_PROJECT]: its log shows no request carrying this run's probe within $TARGET_TIMEOUT_SECONDS s; give the --base-url and --project of one stack"
    want_no_text "flag modifiable"
    requests="$(<"$TEST_DIR/requests")"
    want_re="^GET $STUB_BASE_URL/broker-service/readyz
GET $STUB_BASE_URL/feature-flag-service/readyz
GET $STUB_BASE_URL/broker-service/readyz\?pi-target=[0-9a-f]{32}
GET $STUB_BASE_URL/feature-flag-service/readyz\?pi-target=[0-9a-f]{32}$"
    if [[ ! "$requests" =~ $want_re ]]; then
        reasons+=("requests [$(flat "$requests")], expected both readyz GETs and both probes only")
    fi
    STUB_SERVED_LOG="$STUB_PROXY_LOG"
    conclude "step1Ready_$1"
}

step1_target_mismatch_row baseUrlServedByOtherStack_abortsBeforeFlagReadOrWrite

# step1_interval_row SCENARIO_RESULT VALUE: an interval read successfully, VALUE unset (empty)
# or not a valid interval, gets the broker's default, 60 s, and step 1 passes.
step1_interval_row() {
    local shown=""
    STUB_FLAG_ENABLED=false
    STUB_INTERVAL_VALUE="$2"
    if [[ -n "$2" ]]; then
        printf -v shown '%q' "$2"
    fi
    capture step1_ready
    want_rc 0
    want_line "PASS step 1 runtime facts"
    want_line "INFO db type postgres; evaluation interval ${DEFAULT_INTERVAL_SECONDS}s (ALERT_EVALUATION_INTERVAL_SECONDS [$shown])"
    STUB_INTERVAL_VALUE="60"
    conclude "step1Ready_$1"
}

step1_interval_row intervalReadUnset_passesWithDefault ""
step1_interval_row intervalReadInvalid_passesWithDefault abc

# step1_flag_row SCENARIO_RESULT BODY REASON: the flag GET answers BODY with 200, and step 1
# aborts at "step 1 flag modifiable" with REASON, before it reads the startup setting, sending
# GET requests only. Feature-flag-service's Flag has a string id and boolean enabled and
# isModifiable, so a string "true" or "false" is never read as the boolean.
step1_flag_row() {
    STUB_FLAG_BODY="$2"
    : >"$TEST_DIR/requests"
    capture step1_ready
    want_rc 1
    want_line "FAIL step 1 flag modifiable: $3"
    want_no_text "PASS step 1 flag modifiable"
    want_no_text "flag default disabled"
    if grep -qv '^GET ' "$TEST_DIR/requests"; then
        reasons+=("a request other than GET was sent: $(flat "$(grep -v '^GET ' "$TEST_DIR/requests")")")
    fi
    conclude "step1Ready_$1"
    STUB_FLAG_BODY=""
}

NOT_MODIFIABLE="a deployment with ENABLE_MODIFY=false cannot be toggled"
FLAG_EXPECTED="expected id $FLAG_ID and a boolean enabled"
step1_flag_row isModifiableString_aborts \
    "{\"id\":\"$FLAG_ID\",\"enabled\":false,\"isModifiable\":\"true\",\"tag\":\"feature\"}" \
    "isModifiable is [a JSON string]: $NOT_MODIFIABLE"
step1_flag_row isModifiableFalse_aborts \
    "{\"id\":\"$FLAG_ID\",\"enabled\":false,\"isModifiable\":false,\"tag\":\"feature\"}" \
    "isModifiable is [false]: $NOT_MODIFIABLE"
step1_flag_row isModifiableAbsent_aborts "{\"id\":\"$FLAG_ID\",\"enabled\":false,\"tag\":\"feature\"}" \
    "isModifiable is [a JSON null]: $NOT_MODIFIABLE"
step1_flag_row enabledString_aborts \
    "{\"id\":\"$FLAG_ID\",\"enabled\":\"false\",\"isModifiable\":true,\"tag\":\"feature\"}" \
    "GET $FLAG_ID answered [id is $FLAG_ID, enabled is a JSON string]; $FLAG_EXPECTED"
step1_flag_row otherId_aborts \
    '{"id":"db_not_responding","enabled":false,"isModifiable":true,"tag":"problem_pattern"}' \
    "GET $FLAG_ID answered [id is another string, enabled is false]; $FLAG_EXPECTED"
step1_flag_row idNotString_aborts '{"id":1,"enabled":false,"isModifiable":true}' \
    "GET $FLAG_ID answered [id is a JSON number, enabled is false]; $FLAG_EXPECTED"
step1_flag_row twoFlagObjects_aborts \
    "{\"id\":\"$FLAG_ID\",\"enabled\":false,\"isModifiable\":true} {\"id\":\"$FLAG_ID\",\"enabled\":true}" \
    "GET $FLAG_ID answered [not one JSON object]; $FLAG_EXPECTED"
step1_flag_row notJson_aborts 'enabled' "GET $FLAG_ID answered [not JSON]; $FLAG_EXPECTED"

# ---------------------------------------------------------------------------------------------
# step2_flag_off, step11_browser and step13_cleanup_and_disable: a flag read or PUT answer counts
# only as this flag's JSON boolean, as feature-flag-service's Flag defines it. The other requests
# of these steps get a transport error unless routed here; only the flag checks are asserted.

STUB_FLAG_ACK=""
STUB_FLAG_ACK_STATUS=200
# shellcheck disable=SC2329 # Invoked through the http stub.
route_response() {
    case "$1 $2" in
        "GET $F")
            last_response 200 "application/json; charset=utf-8" "$STUB_FLAG_BODY"
            ;;
        "PUT $F")
            last_response "$STUB_FLAG_ACK_STATUS" "application/json; charset=utf-8" "$STUB_FLAG_ACK"
            ;;
        "GET $BASE_URL/feature-flag-service/v1/flags?tag=problem_pattern" | \
            "GET $ALERTS_URL?accountId=$HOLDER_ID" | "GET $ALERTS_URL/notifications?accountId=$HOLDER_ID")
            last_response 200 "application/json; charset=utf-8" '{"results":[]}'
            ;;
        *) return 1 ;;
    esac
}

# step2_flag_row SCENARIO_RESULT BODY VERDICT: step 2's flag GET answers BODY; VERDICT is its
# "step 2 flag reads disabled" line. A reason never repeats the id another flag sent.
step2_flag_row() {
    STUB_FLAG_BODY="$2"
    capture step2_flag_off
    want_line "$3"
    want_no_text "db_not_responding"
    conclude "step2FlagOff_$1"
}

FLAG_OFF_EXPECTED="expected portfolio-insights-enabled, false and feature"
step2_flag_row thisFlagDisabled_passes \
    "{\"id\":\"$FLAG_ID\",\"enabled\":false,\"isModifiable\":true,\"tag\":\"feature\"}" \
    "PASS step 2 flag reads disabled"
step2_flag_row enabledStringFalse_fails "{\"id\":\"$FLAG_ID\",\"enabled\":\"false\",\"tag\":\"feature\"}" \
    "FAIL step 2 flag reads disabled: id [$FLAG_ID] enabled [a JSON string] tag [feature], $FLAG_OFF_EXPECTED"
step2_flag_row enabledTrue_fails "{\"id\":\"$FLAG_ID\",\"enabled\":true,\"tag\":\"feature\"}" \
    "FAIL step 2 flag reads disabled: id [$FLAG_ID] enabled [true] tag [feature], $FLAG_OFF_EXPECTED"
step2_flag_row otherFlag_fails '{"id":"db_not_responding","enabled":false,"tag":"feature"}' \
    "FAIL step 2 flag reads disabled: id [a JSON string] enabled [false] tag [feature], $FLAG_OFF_EXPECTED"
step2_flag_row idAbsent_fails '{"enabled":false,"tag":"feature"}' \
    "FAIL step 2 flag reads disabled: id [a JSON null] enabled [false] tag [feature], $FLAG_OFF_EXPECTED"
step2_flag_row otherTag_fails "{\"id\":\"$FLAG_ID\",\"enabled\":false,\"tag\":\"problem_pattern\"}" \
    "FAIL step 2 flag reads disabled: id [$FLAG_ID] enabled [false] tag [a JSON string], $FLAG_OFF_EXPECTED"

# flag_step11: step11_browser with no pair alerts, in a run directory of its own, so it lists
# none, writes the fixture, runs the browser check (node is stubbed to fail) and reads the flag;
# then prints FLAG_TOUCHED. Run through capture, so nothing it sets outlives it.
flag_step11() {
    RUN_DIR="$TEST_DIR/flag-step11"
    rm -rf "$RUN_DIR"
    mkdir -p "$RUN_DIR"
    : >"$RUN_DIR/pairs"
    PAIRS_READY=1
    FLAG_TOUCHED=0
    step11_browser
    echo "FLAG_TOUCHED=$FLAG_TOUCHED"
}

# step11_flag_row SCENARIO_RESULT BODY ACK_STATUS ACK VERDICT: the flag GET after the browser
# check answers BODY, and a PUT answers ACK with ACK_STATUS. VERDICT is step 11's one "flag on
# for step 12" line: PASS only for a 200 with this flag's JSON boolean true, otherwise a FAIL
# naming the status or the answer's JSON types, never a value another flag sent. An empty
# VERDICT means the flag reads on, so step 11 sends no PUT and prints no such line.
step11_flag_row() {
    local put switches=1
    if [[ -z "$5" ]]; then
        switches=0
    fi
    STUB_FLAG_BODY="$2"
    STUB_FLAG_ACK_STATUS="$3"
    STUB_FLAG_ACK="$4"
    : >"$TEST_DIR/requests"
    capture flag_step11
    put="$(grep -cxF "PUT $F" "$TEST_DIR/requests" || true)"
    if [[ "$put" != "$switches" ]]; then
        reasons+=("PUT sent $put times, expected $switches")
    fi
    want_line "FLAG_TOUCHED=$switches"
    if [[ $switches -eq 1 ]]; then
        want_line "INFO flag $FLAG_ID is not on after the browser check (status 200); switching it on for step 12"
        want_line "$5"
        if [[ "$(grep -c 'step 11 flag on for step 12' <<<"$OUT" || true)" != "1" ]]; then
            reasons+=("not exactly one step 11 flag on for step 12 line")
        fi
    else
        want_no_text "switching it on"
        want_no_text "step 11 flag on for step 12"
    fi
    want_no_text "db_not_responding"
    conclude "step11Browser_$1"
    STUB_FLAG_ACK_STATUS=200
}

STEP11_OFF="{\"id\":\"$FLAG_ID\",\"enabled\":false,\"tag\":\"feature\"}"
STEP11_ACK_ON="{\"id\":\"$FLAG_ID\",\"enabled\":true}"
STEP11_ON="PASS step 11 flag on for step 12"
STEP11_UNCONFIRMED="FAIL step 11 flag on for step 12: PUT {\"enabled\": true}"
STEP11_EXPECTED="expected id $FLAG_ID and enabled true"
step11_flag_row thisFlagOn_keepsFlag "{\"id\":\"$FLAG_ID\",\"enabled\":true,\"tag\":\"feature\"}" \
    200 "$STEP11_ACK_ON" ""
step11_flag_row enabledStringTrue_switchesOn "{\"id\":\"$FLAG_ID\",\"enabled\":\"true\",\"tag\":\"feature\"}" \
    200 "$STEP11_ACK_ON" "$STEP11_ON"
step11_flag_row otherFlagOn_switchesOn '{"id":"db_not_responding","enabled":true,"tag":"problem_pattern"}' \
    200 "$STEP11_ACK_ON" "$STEP11_ON"
step11_flag_row thisFlagOff_switchesOn "$STEP11_OFF" 200 "$STEP11_ACK_ON" "$STEP11_ON"
step11_flag_row ackOtherFlag_failsSwitchOn "$STEP11_OFF" 200 '{"id":"db_not_responding","enabled":true}' \
    "$STEP11_UNCONFIRMED answered [id is another string, enabled is true]; $STEP11_EXPECTED"
step11_flag_row ackEnabledString_failsSwitchOn "$STEP11_OFF" 200 "{\"id\":\"$FLAG_ID\",\"enabled\":\"true\"}" \
    "$STEP11_UNCONFIRMED answered [id is $FLAG_ID, enabled is a JSON string]; $STEP11_EXPECTED"
step11_flag_row ackFlagOff_failsSwitchOn "$STEP11_OFF" 200 "{\"id\":\"$FLAG_ID\",\"enabled\":false}" \
    "$STEP11_UNCONFIRMED answered [false]; $STEP11_EXPECTED"
step11_flag_row ackNotJson_failsSwitchOn "$STEP11_OFF" 200 'ok' \
    "$STEP11_UNCONFIRMED answered [not JSON]; $STEP11_EXPECTED"
step11_flag_row ackStatus500_failsSwitchOn "$STEP11_OFF" 500 "$STEP11_ACK_ON" \
    "$STEP11_UNCONFIRMED gave status 500"
step11_flag_row ackTransportError_failsSwitchOn "$STEP11_OFF" 000 "" \
    "$STEP11_UNCONFIRMED gave transport error (stubbed transport error)"

# flag_step13: step13_cleanup_and_disable with no owned alerts, in a run directory of its own.
flag_step13() {
    RUN_DIR="$TEST_DIR/flag-step13"
    rm -rf "$RUN_DIR"
    mkdir -p "$RUN_DIR"
    : >"$RUN_DIR/owned"
    : >"$RUN_DIR/deleted"
    step13_cleanup_and_disable
}

# step13_flag_row SCENARIO_RESULT ACK OUTCOME: the PUT {"enabled": false} answers ACK with 200;
# OUTCOME is pass or fail, the failure naming the status and the body's shape only.
step13_flag_row() {
    STUB_FLAG_ACK="$2"
    capture flag_step13
    if [[ "$3" == pass ]]; then
        want_line "PASS step 13 disable flag"
    else
        want_line "FAIL step 13 disable flag: PUT {\"enabled\": false} gave status 200; body [${#2} bytes, JSON object with 2 keys [id,enabled]]"
    fi
    conclude "step13CleanupAndDisable_$1"
}

step13_flag_row thisFlagOff_passes "{\"id\":\"$FLAG_ID\",\"enabled\":false}" pass
step13_flag_row enabledStringFalse_fails "{\"id\":\"$FLAG_ID\",\"enabled\":\"false\"}" fail
step13_flag_row otherFlagOff_fails '{"id":"db_not_responding","enabled":false}' fail
step13_flag_row thisFlagOn_fails "{\"id\":\"$FLAG_ID\",\"enabled\":true}" fail
STUB_FLAG_BODY=""
STUB_FLAG_ACK=""

# ---------------------------------------------------------------------------------------------
# insights_line_logged and step5_figures: the full rendered insights event of the holder.

ACCOUNT="210e9235-10d0-4f73-b88d-5aad621a1972"
OTHER_ACCOUNT="08d4d015-82fa-400b-9867-fef2ebabfad9"
TRACE="a2c33a5432a347217784eb7cc0a95605"
GOOD_LINE="[26/11/26 00:47:05 | Information] Portfolio insights for account [$ACCOUNT] holdings [2] value [222.38948395] risk [HIGH] duration [6] ms trace [$TRACE] | Entities.Portfolio.Service.PortfolioInsightsService"
SINCE="2026-11-26T00:00:00Z"

# insights_row SCENARIO_RESULT VALUE LOG EXPECTED: VALUE is the response's totalValue as jq
# prints it. EXPECTED is "logged", or text the miss's POLL_DETAIL must contain.
insights_row() {
    local rc=0
    STUB_LOG="$3"
    insights_line_logged "$SINCE" "$ACCOUNT" 2 "$2" HIGH || rc=$?
    if [[ "$4" == "logged" && $rc -eq 0 ]] || [[ "$4" != "logged" && $rc -ne 0 && "$POLL_DETAIL" == *"$4"* ]]; then
        check_pass "insightsLineLogged_$1"
    else
        check_fail "insightsLineLogged_$1" "return $rc, POLL_DETAIL [$POLL_DETAIL], expected [$4]"
    fi
}

insights_row fullLine_logged 222.38948395 "$GOOD_LINE" logged
insights_row upperCaseAccountInLine_logged 222.38948395 "${GOOD_LINE/$ACCOUNT/${ACCOUNT^^}}" logged
insights_row valueWithTrailingZero_logged 222.38948395 "${GOOD_LINE/value \[222.38948395\]/value [222.389483950]}" logged
insights_row valueInExponentForm_logged 1E-8 "${GOOD_LINE/value \[222.38948395\]/value [0.00000001]}" logged
insights_row valuePlusExponentForm_logged 1.5E+3 "${GOOD_LINE/value \[222.38948395\]/value [1500.00]}" logged
insights_row wrongLineThenFullLine_logged 222.38948395 "${GOOD_LINE/holdings \[2\]/holdings [3]}
$GOOD_LINE" logged
insights_row prefixOnly_missed 222.38948395 \
    "[26/11/26 00:47:05 | Information] Portfolio insights for account [$ACCOUNT] | PortfolioInsightsService" \
    "the line for account [$ACCOUNT] does not render holdings, value, risk, duration and trace"
insights_row wrongHoldings_missed 222.38948395 "${GOOD_LINE/holdings \[2\]/holdings [3]}" \
    "holdings [3], expected [2]"
insights_row valueLastDigitDiffers_missed 222.38948395 "${GOOD_LINE/value \[222.38948395\]/value [222.38948396]}" \
    "value [222.38948396], expected [222.38948395]"
insights_row roundedValue_missed 222.38948395 "${GOOD_LINE/value \[222.38948395\]/value [222.39]}" \
    "value [222.39], expected [222.38948395]"
insights_row wrongRisk_missed 222.38948395 "${GOOD_LINE/risk \[HIGH\]/risk [LOW]}" "risk [LOW], expected [HIGH]"
insights_row fractionalDuration_missed 222.38948395 "${GOOD_LINE/duration \[6\]/duration [6.5]}" \
    "duration [6.5], expected whole milliseconds"
insights_row nullTrace_missed 222.38948395 "${GOOD_LINE/trace \[$TRACE\]/trace [(null)]}" "trace [(null)], expected"
insights_row allZeroTrace_missed 222.38948395 \
    "${GOOD_LINE/trace \[$TRACE\]/trace [00000000000000000000000000000000]}" \
    "trace [00000000000000000000000000000000], expected"
insights_row shortTrace_missed 222.38948395 "${GOOD_LINE/trace \[$TRACE\]/trace [a2c33a54]}" "trace [a2c33a54], expected"
insights_row upperCaseTrace_missed 222.38948395 "${GOOD_LINE/trace \[$TRACE\]/trace [${TRACE^^}]}" \
    "trace [${TRACE^^}], expected"
insights_row otherAccountOnly_missed 222.38948395 "${GOOD_LINE//$ACCOUNT/$OTHER_ACCOUNT}" \
    "no broker-service line renders insights for account [$ACCOUNT]"
insights_row noLines_missed 222.38948395 "" "no broker-service line renders insights for account [$ACCOUNT]"

HOLDER_ID="$ACCOUNT"
LOG4_SINCE="$SINCE"
LIVE_INSIGHTS='{"totalValue":222.38948395,"totalInvested":223.54717581,"unrealizedPnl":-1.15769186,"unrealizedPnlPercent":-0.5178736236793078007796818800,"allocations":[{"instrumentId":"c0000000-0000-4000-8000-000000000001","name":"EasyTravel","quantity":1,"value":150.57349003,"percent":67.707108877438446882101324290},{"instrumentId":"c0000000-0000-4000-8000-000000000002","name":"EasyPlanes","quantity":1,"value":71.81599392,"percent":32.292891122561553117898675710}],"largestPosition":{"instrumentId":"c0000000-0000-4000-8000-000000000001","name":"EasyTravel","quantity":1,"value":150.57349003,"percent":67.707108877438446882101324290},"riskLevel":"HIGH"}'
UNMATCHABLE="FAIL step 5 insights log line: the response lacks an allocations array, a numeric totalValue or a LOW, MEDIUM or HIGH riskLevel to match the line against"

# step5_row SCENARIO_RESULT INSIGHTS LOG EXPECTED: EXPECTED is the step's whole log-line verdict
# line, or its start followed by "...".
step5_row() {
    local line
    HOLDER_INSIGHTS="$2"
    STUB_LOG="$3"
    capture step5_figures
    line="$(grep '^\(PASS\|FAIL\) step 5 insights log line' <<<"$OUT" || true)"
    if [[ "$line" == "$4" || ("$4" == *... && "$line" == "${4%...}"*) ]]; then
        check_pass "step5Figures_$1"
    else
        check_fail "step5Figures_$1" "log-line verdict [$line], expected [$4]"
    fi
}

step5_row liveBodyAndLine_passes "$LIVE_INSIGHTS" "$GOOD_LINE" "PASS step 5 insights log line"
step5_row prefixOnlyLine_fails "$LIVE_INSIGHTS" "Portfolio insights for account [$ACCOUNT]" \
    "FAIL step 5 insights log line: deadline $LOG_LINE_TIMEOUT_SECONDS s expired; the line for account [$ACCOUNT] does not render..."
step5_row wrongValueLine_fails "$LIVE_INSIGHTS" "${GOOD_LINE/value \[222.38948395\]/value [1]}" \
    "FAIL step 5 insights log line: deadline $LOG_LINE_TIMEOUT_SECONDS s expired; the line for account [$ACCOUNT] has value [1], expected [222.38948395]..."
step5_row responseWithoutRiskLevel_failsUnmatchable "$(jq -c 'del(.riskLevel)' <<<"$LIVE_INSIGHTS" | tr -d '\r')" \
    "$GOOD_LINE" "$UNMATCHABLE"
step5_row responseWithStringTotalValue_failsUnmatchable \
    "${LIVE_INSIGHTS/\"totalValue\":222.38948395/\"totalValue\":\"222.38948395\"}" "$GOOD_LINE" "$UNMATCHABLE"
step5_row responseWithoutAllocations_failsUnmatchable "$(jq -c 'del(.allocations)' <<<"$LIVE_INSIGHTS" | tr -d '\r')" \
    "$GOOD_LINE" "$UNMATCHABLE"

# Signed values netting to a totalValue of exactly 0, as PortfolioInsightsCalculator answers
# them: every percent 0, the lowest id the largest although its value is the lower, risk LOW.
ZERO_INSIGHTS='{"totalValue":0.00,"totalInvested":10.00,"unrealizedPnl":-10.00,"unrealizedPnlPercent":-100,"allocations":[{"instrumentId":"c0000000-0000-4000-8000-000000000002","name":"EasyPlanes","quantity":1,"value":5.00,"percent":0},{"instrumentId":"c0000000-0000-4000-8000-000000000001","name":"EasyTravel","quantity":1,"value":-5.00,"percent":0}],"largestPosition":{"instrumentId":"c0000000-0000-4000-8000-000000000001","name":"EasyTravel","quantity":1,"value":-5.00,"percent":0},"riskLevel":"LOW"}'
ZERO_LINE="${GOOD_LINE/value \[222.38948395\] risk \[HIGH\]/value [0.00] risk [LOW]}"
mutate_zero() {
    jq -c "$1" <<<"$ZERO_INSIGHTS" | tr -d '\r'
}
STEP5_NONZERO_PASS=("PASS step 5 two allocations" "PASS step 5 percents sum to 100"
    "PASS step 5 totalValue is the sum of the values" "PASS step 5 largest position"
    "PASS step 5 risk level" "PASS step 5 insights log line")
STEP5_ZERO_PASS=("PASS step 5 two allocations" "PASS step 5 percents are 0 at a zero total"
    "PASS step 5 totalValue is the sum of the values" "PASS step 5 largest position"
    "PASS step 5 risk level" "PASS step 5 insights log line")
# The start of the largest-position verdict when largestPosition is not its allocation entry.
ZERO_LARGEST="FAIL step 5 largest position: largestPosition differs from the lowest-id allocation, as totalValue is 0"
NONZERO_LARGEST="FAIL step 5 largest position: largestPosition differs from the highest-value allocation with the lowest id"

# step5_checks_row SCENARIO_RESULT INSIGHTS LOG LINE...: step5_figures prints exactly the LINEs,
# one per check and in order; a LINE ending in "..." is matched as the start of its line.
step5_checks_row() {
    local check="step5Figures_$1" i
    local -a want got
    HOLDER_INSIGHTS="$2"
    STUB_LOG="$3"
    shift 3
    want=("$@")
    capture step5_figures
    mapfile -t got <<<"$OUT"
    want_rc 0
    if [[ ${#got[@]} -ne ${#want[@]} ]]; then
        reasons+=("${#got[@]} lines, expected ${#want[@]}")
    fi
    for i in "${!want[@]}"; do
        if [[ "${got[i]:-}" != "${want[i]}" && ! ("${want[i]}" == *... && "${got[i]:-}" == "${want[i]%...}"*) ]]; then
            reasons+=("line $((i + 1)) [${got[i]:-}], expected [${want[i]}]")
        fi
    done
    conclude "$check"
}

step5_checks_row liveBody_passesNonzeroChecks "$LIVE_INSIGHTS" "$GOOD_LINE" "${STEP5_NONZERO_PASS[@]}"
# The rows that change only the allocations' percents leave largestPosition with its own, so it
# is no longer its allocation entry either.
step5_checks_row nonzeroTotalZeroPercents_failsSum "$(jq -c '.allocations |= map(.percent = 0)' <<<"$LIVE_INSIGHTS" | tr -d '\r')" \
    "$GOOD_LINE" "${STEP5_NONZERO_PASS[0]}" "FAIL step 5 percents sum to 100: allocation percents sum to 0" \
    "${STEP5_NONZERO_PASS[2]}" "$NONZERO_LARGEST: percent 67.707108877438446882101324290, expected 0" \
    "${STEP5_NONZERO_PASS[@]:4}"
step5_checks_row zeroTotalSignedValues_passesZeroTotalChecks "$ZERO_INSIGHTS" "$ZERO_LINE" "${STEP5_ZERO_PASS[@]}"
step5_checks_row zeroTotalIntegerForm_passesZeroTotalChecks "${ZERO_INSIGHTS/\"totalValue\":0.00/\"totalValue\":0}" \
    "$ZERO_LINE" "${STEP5_ZERO_PASS[@]}"
step5_checks_row zeroTotalPercentsSumTo100_failsPercents "$(mutate_zero '.allocations |= map(.percent = 50)')" \
    "$ZERO_LINE" "${STEP5_ZERO_PASS[0]}" \
    "FAIL step 5 percents are 0 at a zero total: allocation percents [50,50], expected the number 0 each at a totalValue of 0" \
    "${STEP5_ZERO_PASS[2]}" "$ZERO_LARGEST: percent 0, expected 50" "${STEP5_ZERO_PASS[@]:4}"
step5_checks_row zeroTotalStringPercent_failsPercents "$(mutate_zero '.allocations[1].percent = "0"')" \
    "$ZERO_LINE" "${STEP5_ZERO_PASS[0]}" \
    "FAIL step 5 percents are 0 at a zero total: allocation percents [0,\"0\"], expected the number 0 each at a totalValue of 0" \
    "${STEP5_ZERO_PASS[2]}" "$ZERO_LARGEST: percent differs" "${STEP5_ZERO_PASS[@]:4}"
step5_checks_row zeroTotalHighestValueLargest_failsLargest "$(mutate_zero '.largestPosition = .allocations[0]')" \
    "$ZERO_LINE" "${STEP5_ZERO_PASS[@]:0:3}" \
    "FAIL step 5 largest position: largestPosition [c0000000-0000-4000-8000-000000000002], expected [c0000000-0000-4000-8000-000000000001], the lowest id, as totalValue is 0" \
    "${STEP5_ZERO_PASS[@]:4}"
step5_checks_row zeroTotalRiskHigh_failsRisk "$(mutate_zero '.riskLevel = "HIGH"')" "${ZERO_LINE/risk \[LOW\]/risk [HIGH]}" \
    "${STEP5_ZERO_PASS[@]:0:4}" "FAIL step 5 risk level: riskLevel [HIGH], a totalValue of 0 gives LOW" \
    "${STEP5_ZERO_PASS[5]}"
step5_checks_row zeroTotalRiskMedium_failsRisk "$(mutate_zero '.riskLevel = "MEDIUM"')" \
    "${ZERO_LINE/risk \[LOW\]/risk [MEDIUM]}" \
    "${STEP5_ZERO_PASS[@]:0:4}" "FAIL step 5 risk level: riskLevel [MEDIUM], a totalValue of 0 gives LOW" \
    "${STEP5_ZERO_PASS[5]}"
# Only a JSON number equal to 0 is a zero total, so a string "0" keeps the nonzero checks.
step5_checks_row zeroTotalAsString_failsNonzeroChecks "${ZERO_INSIGHTS/\"totalValue\":0.00/\"totalValue\":\"0\"}" \
    "$ZERO_LINE" "${STEP5_NONZERO_PASS[0]}" "FAIL step 5 percents sum to 100: allocation percents sum to 0" \
    "FAIL step 5 totalValue is the sum of the values: unreadable JSON [..." \
    "FAIL step 5 largest position: largestPosition value -5.00, highest value 5.00" \
    "${STEP5_NONZERO_PASS[4]}" "$UNMATCHABLE"

# step5_largest_row SCENARIO_RESULT BRANCH MUTATION LARGEST: the zero or nonzero BRANCH's body,
# changed by the jq MUTATION, passes every step-5 check but the largest position, whose line is
# LARGEST. largestPosition must be the selected allocation entry itself, in every field.
step5_largest_row() {
    local body line
    local -a lines
    if [[ "$2" == "zero" ]]; then
        body="$(mutate_zero "$3")"
        line="$ZERO_LINE"
        lines=("${STEP5_ZERO_PASS[@]}")
    else
        body="$(jq -c "$3" <<<"$LIVE_INSIGHTS" | tr -d '\r')"
        line="$GOOD_LINE"
        lines=("${STEP5_NONZERO_PASS[@]}")
    fi
    lines[3]="$4"
    step5_checks_row "$1" "$body" "$line" "${lines[@]}"
}

step5_largest_row zeroTotalLowestIdOtherPercentAndValue_failsLargest zero \
    '.largestPosition.percent = 80 | .largestPosition.value = 700' "$ZERO_LARGEST: value 700, expected -5.00; percent 80, expected 0"
step5_largest_row zeroTotalLowestIdOtherName_failsLargest zero '.largestPosition.name = "EasyPlanes"' "$ZERO_LARGEST: name differs"
step5_largest_row nonzeroSelectedIdOtherPercent_failsLargest nonzero '.largestPosition.percent = 67.7' \
    "$NONZERO_LARGEST: percent 67.7, expected 67.707108877438446882101324290"
step5_largest_row nonzeroSelectedIdOtherName_failsLargest nonzero '.largestPosition.name = "EasyPlanes"' \
    "$NONZERO_LARGEST: name differs"
step5_largest_row nonzeroSelectedIdWithoutQuantity_failsLargest nonzero 'del(.largestPosition.quantity)' \
    "$NONZERO_LARGEST: quantity differs"
step5_largest_row nonzeroSelectedIdExtraField_failsLargest nonzero '.largestPosition.extra = true' \
    "$NONZERO_LARGEST: other fields differ"
step5_largest_row nonzeroSelectedIdUpperCase_failsLargest nonzero \
    '.largestPosition.instrumentId |= ascii_upcase' "$NONZERO_LARGEST: instrumentId differs"
# Equal values, listed with the higher id first: the entry with the lowest id is the largest.
step5_checks_row nonzeroTiedValuesLowestIdEntry_passesNonzeroChecks \
    "$(jq -c '.totalValue = 200 | .allocations = [.allocations[1], .allocations[0]]
        | .allocations |= map(.value = 100 | .percent = 50)
        | .largestPosition = .allocations[1] | .riskLevel = "MEDIUM"' <<<"$LIVE_INSIGHTS" | tr -d '\r')" \
    "${GOOD_LINE/value \[222.38948395\] risk \[HIGH\]/value [200] risk [MEDIUM]}" "${STEP5_NONZERO_PASS[@]}"

# ---------------------------------------------------------------------------------------------
# step6_empty: WANT_JQ's verdict, where an absent property never passes as null.

EMPTY_ID="b0000000-0000-4000-8000-000000000001"
EMPTY_OK='{"totalValue":0,"totalInvested":0,"unrealizedPnl":0,"unrealizedPnlPercent":0,"allocations":[],"largestPosition":null,"riskLevel":null}'
STUB_STATUS=200
STUB_BODY=""
# shellcheck disable=SC2329 # Invoked through the http stub.
route_response() {
    if [[ "$1 $2" == "GET $INSIGHTS_URL/$EMPTY_ID" ]]; then
        last_response "$STUB_STATUS" "application/json; charset=utf-8" "$STUB_BODY"
        return 0
    fi
    return 1
}
mutate_empty() {
    jq -c "$1" <<<"$EMPTY_OK" | tr -d '\r'
}

# step6_row SCENARIO_RESULT STATUS BODY EXPECTED: EXPECTED is "ok" or the FAIL reason.
step6_row() {
    local expected="PASS step 6 empty account insights"
    STUB_STATUS="$2"
    STUB_BODY="$3"
    if [[ "$4" != "ok" ]]; then
        expected="FAIL step 6 empty account insights: $4"
    fi
    capture step6_empty
    if [[ "$OUT" == "$expected" ]]; then
        check_pass "step6Empty_$1"
    else
        check_fail "step6Empty_$1" "output [$(flat "$OUT")], expected [$expected]"
    fi
}

step6_row zeroFigures_ok 200 "$EMPTY_OK" ok
step6_row zeroFiguresWithFractionDigits_ok 200 \
    '{"totalValue":0.0,"totalInvested":0.00,"unrealizedPnl":0,"unrealizedPnlPercent":0.000,"allocations":[],"largestPosition":null,"riskLevel":null}' ok
step6_row largestPositionMissing_fails 200 "$(mutate_empty 'del(.largestPosition)')" \
    "largestPosition missing, expected null"
step6_row riskLevelMissing_fails 200 "$(mutate_empty 'del(.riskLevel)')" "riskLevel missing, expected null"
step6_row totalInvestedMissing_fails 200 "$(mutate_empty 'del(.totalInvested)')" \
    "totalInvested missing, expected the number 0"
step6_row totalValueString0_fails 200 "$(mutate_empty '.totalValue = "0"')" \
    'totalValue ["0"], expected the number 0'
step6_row unrealizedPnlOne_fails 200 "$(mutate_empty '.unrealizedPnl = 1')" "unrealizedPnl [1], expected the number 0"
step6_row unrealizedPnlPercentNull_fails 200 "$(mutate_empty '.unrealizedPnlPercent = null')" \
    "unrealizedPnlPercent [null], expected the number 0"
step6_row allocationsNull_fails 200 "$(mutate_empty '.allocations = null')" "allocations [null], expected []"
step6_row allocationsWithItem_fails 200 "$(mutate_empty '.allocations = [{"instrumentId":"x"}]')" \
    'allocations [[{"instrumentId":"x"}]], expected []'
step6_row largestPositionObject_fails 200 "$(mutate_empty '.largestPosition = {}')" \
    "largestPosition [{}], expected null"
step6_row riskLevelLow_fails 200 "$(mutate_empty '.riskLevel = "LOW"')" 'riskLevel ["LOW"], expected null'
step6_row twoPropertiesWrong_failsWithBoth 200 "$(mutate_empty 'del(.riskLevel) | .totalValue = 5')" \
    "totalValue [5], expected the number 0; riskLevel missing, expected null"
step6_row bodyArray_fails 200 '[]' "the body is a JSON array, expected an object"
step6_row status404_fails 404 '{"statusCode":404,"message":"Account not found"}' \
    'status 404, expected 200; body [48 bytes, JSON object with 2 keys [statusCode,message]]'

# ---------------------------------------------------------------------------------------------
# ALERT_JQ alert(ENABLED; REVISION; KEPT): the step-8 AlertDTO check.

TRIGGERED_ALERT='{"id":"6f1c2b9e-3d4a-4b5c-8d6e-7f8091a2b3c4","accountId":"210e9235-10d0-4f73-b88d-5aad621a1972","instrumentId":"08d4d015-82fa-400b-9867-fef2ebabfad9","type":"TARGET_PRICE","direction":"ABOVE","threshold":9999999999.99999999,"enabled":false,"armingRevision":1,"triggeredAt":"2026-11-26T01:02:03.456789+00:00","triggerValue":10000000000.5,"acknowledged":false,"createdAt":"2026-11-26T01:00:00.123456+00:00"}'
STAMP='"2026-11-26T01:02:03.456789+00:00"'
mutate_alert() {
    jq -c "$1" <<<"$TRIGGERED_ALERT" | tr -d '\r'
}
CREATED_BODY="$(mutate_alert '.enabled = true | .triggeredAt = null | .triggerValue = null')"
NEVER_TRIGGERED="$(mutate_alert '.triggeredAt = null | .triggerValue = null')"
REARMED_BODY="$(mutate_alert '.enabled = true | .armingRevision = 2 | .triggeredAt = null | .triggerValue = null')"

# alert_row FILTER SCENARIO_RESULT BODY EXPECTED: FILTER is create (alert(true; 1; false)),
# disable (alert(false; 1; true)) or rearm (alert(true; 2; false)); EXPECTED is "ok" or the
# verdict.
alert_row() {
    local filter
    case "$1" in
        create) filter="$ALERT_JQ"'alert(true; 1; false)' ;;
        disable) filter="$ALERT_JQ"'alert(false; 1; true)' ;;
        *) filter="$ALERT_JQ"'alert(true; 2; false)' ;;
    esac
    assert_eq "alertFilter_$2" "$4" "$(jget "$filter" "$3")"
}

alert_row create createUntriggered_ok "$CREATED_BODY" ok
alert_row create createWithTriggerData_fails "$(mutate_alert '.enabled = true')" \
    "triggeredAt [$STAMP], expected null; triggerValue [10000000000.5], expected null"
alert_row create createTriggerValueMissing_fails "$(jq -c 'del(.triggerValue)' <<<"$CREATED_BODY" | tr -d '\r')" \
    "triggerValue missing, expected null"
alert_row create createAcknowledgedTrue_fails "$(jq -c '.acknowledged = true' <<<"$CREATED_BODY" | tr -d '\r')" \
    "acknowledged [true], expected false"
alert_row create createRevisionString_fails "$(jq -c '.armingRevision = "1"' <<<"$CREATED_BODY" | tr -d '\r')" \
    'armingRevision ["1"], expected 1'
alert_row create createThresholdString_fails "$(jq -c '.threshold = "1"' <<<"$CREATED_BODY" | tr -d '\r')" \
    'threshold ["1"], expected a number'
alert_row create createIdNotGuid_fails "$(jq -c '.id = "x"' <<<"$CREATED_BODY" | tr -d '\r')" \
    'id ["x"], expected a GUID string'
alert_row create createBodyArray_fails '[1]' "the body is a JSON array, expected an object"
alert_row disable disableKeptTrigger_ok "$TRIGGERED_ALERT" ok
alert_row disable disableKeptTwentyDigitTrigger_ok \
    "${TRIGGERED_ALERT/\"triggerValue\":10000000000.5/\"triggerValue\":99999999999999999999.99999999}" ok
alert_row disable disableKeptNegativeTrigger_ok "$(mutate_alert '.type = "PROFIT_LOSS" | .triggerValue = -12.5')" ok
alert_row disable disableNeverTriggered_ok "$NEVER_TRIGGERED" ok
alert_row disable disableTriggeredAtWithoutValue_failsInconsistentPair "$(mutate_alert '.triggerValue = null')" \
    "triggerValue [null], expected a number in a kept trigger"
alert_row disable disableValueWithoutTriggeredAt_failsInconsistentPair "$(mutate_alert '.triggeredAt = null')" \
    "triggeredAt [null], expected an ISO-8601 string in a kept trigger"
alert_row disable disableKeptTriggerValueMissing_fails "$(mutate_alert 'del(.triggerValue)')" \
    "triggerValue missing, expected a number in a kept trigger"
alert_row disable disableNeverTriggeredAtMissing_fails "$(jq -c 'del(.triggeredAt)' <<<"$NEVER_TRIGGERED" | tr -d '\r')" \
    "triggeredAt missing, expected null or a kept trigger"
alert_row disable disableTriggerValueString0_fails "$(mutate_alert '.triggerValue = "0"')" \
    'triggerValue ["0"], expected a number in a kept trigger'
alert_row disable disableTriggeredAtNotIso_fails "$(mutate_alert '.triggeredAt = "yesterday"')" \
    'triggeredAt ["yesterday"], expected an ISO-8601 string in a kept trigger'
alert_row disable disableEnabledTrue_fails "$(mutate_alert '.enabled = true')" "enabled [true], expected false"
alert_row disable disableCreatedAtMissing_fails "$(mutate_alert 'del(.createdAt)')" \
    "createdAt missing, expected an ISO-8601 string"
alert_row rearm rearmCleared_ok "$REARMED_BODY" ok
alert_row rearm rearmWithTriggerData_fails "$(mutate_alert '.enabled = true | .armingRevision = 2')" \
    "triggeredAt [$STAMP], expected null; triggerValue [10000000000.5], expected null"
alert_row rearm rearmTriggerValueOnly_fails "$(jq -c '.triggerValue = 5' <<<"$REARMED_BODY" | tr -d '\r')" \
    "triggerValue [5], expected null"
alert_row rearm rearmRevisionOne_fails "$(jq -c '.armingRevision = 1' <<<"$REARMED_BODY" | tr -d '\r')" \
    "armingRevision [1], expected 2"

# ---------------------------------------------------------------------------------------------
# alert_verdict: a step-8 response tied to its request, the holder's TARGET_PRICE alert ABOVE
# MAX_THRESHOLD on H1, with ids in any letter case and the threshold compared exactly.

HOLDER_ID="210e9235-10d0-4f73-b88d-5aad621a1972"
H1="08d4d015-82fa-400b-9867-fef2ebabfad9"
ALERT_ID="6f1c2b9e-3d4a-4b5c-8d6e-7f8091a2b3c4"
OTHER_GUID="00000000-0000-4000-8000-000000000000"

# alert_verdict_row FILTER SCENARIO_RESULT BODY EXPECTED: FILTER is create (CREATED_FILTER, its
# request without an id), disable (DISABLED_FILTER) or rearm (REARMED_FILTER), the PATCHes of
# ALERT_ID; EXPECTED is "ok" or the verdict.
alert_verdict_row() {
    local filter="$DISABLED_FILTER" id="$ALERT_ID"
    case "$1" in
        create)
            filter="$CREATED_FILTER"
            id=""
            ;;
        rearm) filter="$REARMED_FILTER" ;;
    esac
    last_response 200 "application/json; charset=utf-8" "$3"
    assert_eq "alertVerdict_$2" "$4" \
        "$(alert_verdict "$filter" "$(alert_want "$id" "$HOLDER_ID" "$H1" TARGET_PRICE ABOVE)" "$MAX_THRESHOLD")"
}

alert_verdict_row create createAsRequested_ok "$CREATED_BODY" ok
alert_verdict_row create createUpperCaseGuids_ok \
    "$(jq -c '.id |= ascii_upcase | .accountId |= ascii_upcase | .instrumentId |= ascii_upcase' <<<"$CREATED_BODY" | tr -d '\r')" ok
alert_verdict_row create createThresholdTrailingZero_ok "${CREATED_BODY/9999999999.99999999/9999999999.999999990}" ok
alert_verdict_row create createThresholdExponentOfSameValue_ok \
    "${CREATED_BODY/9999999999.99999999/9.99999999999999999E+9}" ok
alert_verdict_row create createOtherAccount_fails "$(jq -c --arg g "$OTHER_GUID" '.accountId = $g' <<<"$CREATED_BODY" | tr -d '\r')" \
    "accountId [\"$OTHER_GUID\"], expected $HOLDER_ID"
alert_verdict_row create createAccountNotGuid_failsOnce "$(jq -c '.accountId = "x"' <<<"$CREATED_BODY" | tr -d '\r')" \
    "accountId [\"x\"], expected $HOLDER_ID"
alert_verdict_row create createOtherInstrument_fails "$(jq -c --arg g "$OTHER_GUID" '.instrumentId = $g' <<<"$CREATED_BODY" | tr -d '\r')" \
    "instrumentId [\"$OTHER_GUID\"], expected $H1"
alert_verdict_row create createOtherType_fails "$(jq -c '.type = "PROFIT_LOSS"' <<<"$CREATED_BODY" | tr -d '\r')" \
    'type ["PROFIT_LOSS"], expected TARGET_PRICE'
alert_verdict_row create createLowerCaseType_failsOnce "$(jq -c '.type = "target_price"' <<<"$CREATED_BODY" | tr -d '\r')" \
    'type ["target_price"], expected TARGET_PRICE'
alert_verdict_row create createOtherDirection_fails "$(jq -c '.direction = "BELOW"' <<<"$CREATED_BODY" | tr -d '\r')" \
    'direction ["BELOW"], expected ABOVE'
alert_verdict_row create createRoundedThreshold_fails "${CREATED_BODY/9999999999.99999999/10000000000}" \
    "threshold [10000000000], expected $MAX_THRESHOLD"
alert_verdict_row create createThresholdLastDigitDropped_fails "${CREATED_BODY/9999999999.99999999/9999999999.9999999}" \
    "threshold [9999999999.9999999], expected $MAX_THRESHOLD"
alert_verdict_row create createThresholdExponentOfOtherValue_fails "${CREATED_BODY/9999999999.99999999/1E+10}" \
    "threshold [1E+10], expected $MAX_THRESHOLD"
alert_verdict_row create createThresholdString_failsOnce "${CREATED_BODY/9999999999.99999999/\"9999999999.99999999\"}" \
    'threshold ["9999999999.99999999"], expected a number'
alert_verdict_row create createOtherAccountAndRoundedThreshold_failsWithBoth \
    "$(jq -c --arg g "$OTHER_GUID" '.accountId = $g' <<<"${CREATED_BODY/9999999999.99999999/10000000000}" | tr -d '\r')" \
    "accountId [\"$OTHER_GUID\"], expected $HOLDER_ID; threshold [10000000000], expected $MAX_THRESHOLD"
alert_verdict_row create createBodyNotJson_failsUnreadable 'not json' "unreadable JSON [8 bytes, not JSON]"
alert_verdict_row create createBodyThenGarbage_failsUnreadable "${CREATED_BODY}garbage" \
    "unreadable JSON [$((${#CREATED_BODY} + 7)) bytes, not JSON]"
alert_verdict_row create createBodyTwice_failsUnreadable "$CREATED_BODY$CREATED_BODY" \
    "unreadable JSON [$((2 * ${#CREATED_BODY})) bytes, not JSON]"
alert_verdict_row create createBodyEmpty_failsUnreadable '' "unreadable JSON [empty]"
alert_verdict_row disable disableAsPatched_ok "$TRIGGERED_ALERT" ok
alert_verdict_row disable disableOtherId_fails "$(mutate_alert ".id = \"$OTHER_GUID\"")" \
    "id [\"$OTHER_GUID\"], expected $ALERT_ID"
alert_verdict_row disable disableOtherInstrument_fails "$(mutate_alert ".instrumentId = \"$OTHER_GUID\"")" \
    "instrumentId [\"$OTHER_GUID\"], expected $H1"
alert_verdict_row disable disableRoundedThreshold_fails "${TRIGGERED_ALERT/9999999999.99999999/10000000000}" \
    "threshold [10000000000], expected $MAX_THRESHOLD"
alert_verdict_row rearm rearmAsPatched_ok "$REARMED_BODY" ok
alert_verdict_row rearm rearmOtherId_fails "$(jq -c --arg g "$OTHER_GUID" '.id = $g' <<<"$REARMED_BODY" | tr -d '\r')" \
    "id [\"$OTHER_GUID\"], expected $ALERT_ID"
alert_verdict_row rearm rearmOtherAccount_fails "$(jq -c --arg g "$OTHER_GUID" '.accountId = $g' <<<"$REARMED_BODY" | tr -d '\r')" \
    "accountId [\"$OTHER_GUID\"], expected $HOLDER_ID"
alert_verdict_row rearm rearmOtherDirection_fails "$(jq -c '.direction = "BELOW"' <<<"$REARMED_BODY" | tr -d '\r')" \
    'direction ["BELOW"], expected ABOVE'

# ---------------------------------------------------------------------------------------------
# step8_crud against a fake broker: every response tied to its request, and each listing's
# {"results": [...]} envelope and entries, each an alert with a GUID id, checked before an id is
# looked for in it. The fake keeps the holder's alerts newest first, one "ID TYPE ENABLED
# REVISION" line each, in STEP8_ALERTS.
# STEP8_WHERE names the one response that STEP8_MUTATION, a jq filter, rewrites and that
# STEP8_STATUS, when set, answers with: create, disable or rearm of the TARGET_PRICE alert,
# list (the read after both creates) or absent (the read after the TARGET_PRICE delete).

STEP8_PREFIX="cccccccc-0000-4000-8000-00000000000"
STEP8_TP="${STEP8_PREFIX}1"
STEP8_ALERTS=""
STEP8_POSTS=0
STEP8_GETS=0
STEP8_WHERE=""
STEP8_MUTATION="."
STEP8_STATUS=""

# step8_alert ID TYPE ENABLED REVISION: the fake's AlertDTO of an untriggered holder alert.
step8_alert() {
    printf '{"id":"%s","accountId":"%s","instrumentId":"%s","type":"%s","direction":"ABOVE","threshold":%s,"enabled":%s,"armingRevision":%s,"triggeredAt":null,"triggerValue":null,"acknowledged":false,"createdAt":"2026-11-26T01:00:00.123456+00:00"}' \
        "$1" "$HOLDER_ID" "$H1" "$2" "$MAX_THRESHOLD" "$3" "$4"
}

# shellcheck disable=SC2329 # Invoked through the http stub.
route_response() {
    local id="" type enabled revision line kind status body="" sep=""
    case "$1 $2" in
        "POST $ALERTS_URL")
            STEP8_POSTS=$((STEP8_POSTS + 1))
            id="$STEP8_PREFIX$STEP8_POSTS"
            type="TARGET_PRICE"
            if [[ "$3" == *'"type":"PROFIT_LOSS"'* ]]; then
                type="PROFIT_LOSS"
            fi
            STEP8_ALERTS="$id $type true 1${STEP8_ALERTS:+$'\n'$STEP8_ALERTS}"
            kind="create"
            status=201
            body="$(step8_alert "$id" "$type" true 1)"
            ;;
        "PATCH $ALERTS_URL/"*)
            id="${2##*/}"
            kind="patch"
            status=404
            body='{"statusCode":404,"message":"Alert not found"}'
            line="$(grep "^$id " <<<"$STEP8_ALERTS" || true)"
            if [[ -n "$line" ]]; then
                read -r _ type enabled revision <<<"$line"
                if [[ "$3" == '{"enabled":true}' ]]; then
                    kind="rearm"
                    enabled=true
                    revision=$((revision + 1))
                else
                    kind="disable"
                    enabled=false
                fi
                STEP8_ALERTS="${STEP8_ALERTS/"$line"/"$id $type $enabled $revision"}"
                status=200
                body="$(step8_alert "$id" "$type" "$enabled" "$revision")"
            fi
            ;;
        "DELETE $ALERTS_URL/"*)
            id="${2##*/}"
            kind="delete"
            status=404
            body='{"statusCode":404,"message":"Alert not found"}'
            if grep -q "^$id " <<<"$STEP8_ALERTS"; then
                STEP8_ALERTS="$(grep -v "^$id " <<<"$STEP8_ALERTS" || true)"
                status=204
                body=""
            fi
            ;;
        "GET $ALERTS_URL?accountId=$HOLDER_ID")
            STEP8_GETS=$((STEP8_GETS + 1))
            kind="read"
            if [[ $STEP8_GETS -eq 1 ]]; then
                kind="list"
            elif [[ $STEP8_GETS -eq 2 ]]; then
                kind="absent"
            fi
            body='{"results":['
            while read -r id type enabled revision; do
                if [[ -n "$id" ]]; then
                    body="$body$sep$(step8_alert "$id" "$type" "$enabled" "$revision")"
                    sep=","
                fi
            done <<<"$STEP8_ALERTS"
            body="$body]}"
            id=""
            status=200
            ;;
        *) return 1 ;;
    esac
    if [[ "$kind" == "$STEP8_WHERE" && (-z "$id" || "$id" == "$STEP8_TP") ]]; then
        body="$(jq -c "$STEP8_MUTATION" <<<"$body" | tr -d '\r')"
        status="${STEP8_STATUS:-$status}"
    fi
    last_response "$status" "application/json; charset=utf-8" "$body"
}

# step8_row SCENARIO_RESULT WHERE MUTATION STATUS EXPECTED: EXPECTED is PASS, every one of the
# 13 step-8 checks passing, or the one FAIL line, its start followed by "..." where a body
# description ends it, with the other 12 checks passing.
step8_row() {
    local fails passes expected_passes=12
    STEP8_WHERE="$2"
    STEP8_MUTATION="$3"
    STEP8_STATUS="$4"
    STEP8_ALERTS=""
    STEP8_POSTS=0
    STEP8_GETS=0
    reset_alert_files
    capture step8_crud
    fails="$(grep '^FAIL ' <<<"$OUT" || true)"
    passes="$(grep -c '^PASS ' <<<"$OUT" || true)"
    if [[ "$5" == "PASS" ]]; then
        expected_passes=13
        if [[ -n "$fails" ]]; then
            reasons+=("unexpected FAIL lines [$(flat "$fails")]")
        fi
    elif [[ "$fails" != "$5" && ("$5" != *... || "$fails" == *$'\n'* || "$fails" != "${5%...}"*) ]]; then
        reasons+=("FAIL lines [$(flat "$fails")], expected [$5]")
    fi
    if [[ "$passes" != "$expected_passes" ]]; then
        reasons+=("$passes PASS lines, expected $expected_passes")
    fi
    want_rc 0
    conclude "step8Crud_$1"
}

step8_row asRequested_passesEveryCheck "" . "" PASS
step8_row createOtherAccount_failsCreate create ".accountId = \"$OTHER_GUID\"" "" \
    "FAIL step 8 create TARGET_PRICE: accountId [\"$OTHER_GUID\"], expected $HOLDER_ID"
step8_row createRoundedThreshold_failsCreate create '.threshold = 10000000000' "" \
    "FAIL step 8 create TARGET_PRICE: threshold [10000000000], expected $MAX_THRESHOLD"
step8_row disableOtherId_failsDisable disable ".id = \"$OTHER_GUID\"" "" \
    "FAIL step 8 TARGET_PRICE disable: id [\"$OTHER_GUID\"], expected $STEP8_TP"
step8_row rearmOtherType_failsRearm rearm '.type = "PROFIT_LOSS"' "" \
    'FAIL step 8 TARGET_PRICE re-arm: type ["PROFIT_LOSS"], expected TARGET_PRICE'
step8_row listWithoutResults_failsList list 'del(.results)' "" \
    "FAIL step 8 list newest first: results missing, expected an array"
step8_row absentWithoutResults_failsAbsent absent 'del(.results)' "" \
    "FAIL step 8 TARGET_PRICE absent after delete: results missing, expected an array"
step8_row absentResultsNull_failsAbsent absent '.results = null' "" \
    "FAIL step 8 TARGET_PRICE absent after delete: results [null], expected an array"
step8_row absentResultsEmpty_passes absent '.results = []' "" PASS
step8_row absentStillListedUpperCase_failsAbsent absent ".results += [{\"id\": \"${STEP8_TP^^}\"}]" "" \
    "FAIL step 8 TARGET_PRICE absent after delete: alert $STEP8_TP listed 1 times, expected 0"
step8_row absentStatus503_failsAbsent absent '{statusCode: 503, message: "Database unavailable"}' 503 \
    "FAIL step 8 TARGET_PRICE absent after delete: status 503, expected 200; body [..."
# Every listed entry must be an alert object with a GUID id, named by position when it is not;
# only then are the ids looked at.
STEP8_ENTRY_FAIL="is not an alert with a GUID id"
step8_row listMalformedBesideBoth_failsList list '.results += [{"id": 42}]' "" \
    "FAIL step 8 list newest first: results entry 3 of 3 $STEP8_ENTRY_FAIL"
step8_row listNullFirst_failsList list '.results = [null] + .results' "" \
    "FAIL step 8 list newest first: results entry 1 of 3 $STEP8_ENTRY_FAIL"
step8_row listUpperCaseIds_passes list '.results |= map(.id |= ascii_upcase)' "" PASS
step8_row listOneMissing_failsList list '.results |= .[0:1]' "" \
    "FAIL step 8 list newest first: listed ids [\"${STEP8_PREFIX}2\"], expected both ${STEP8_PREFIX}2 and $STEP8_TP"
step8_row listOldestFirst_failsList list '.results |= reverse' "" \
    "FAIL step 8 list newest first: PROFIT_LOSS ${STEP8_PREFIX}2 is listed after TARGET_PRICE $STEP8_TP"
step8_row absentNumericId_failsAbsent absent '.results = [{"id": 42}]' "" \
    "FAIL step 8 TARGET_PRICE absent after delete: results entry 1 of 1 $STEP8_ENTRY_FAIL"
step8_row absentNullEntry_failsAbsent absent '.results = [null]' "" \
    "FAIL step 8 TARGET_PRICE absent after delete: results entry 1 of 1 $STEP8_ENTRY_FAIL"
step8_row absentStringEntry_failsAbsent absent '.results = ["x"]' "" \
    "FAIL step 8 TARGET_PRICE absent after delete: results entry 1 of 1 $STEP8_ENTRY_FAIL"
step8_row absentNonGuidId_failsAbsent absent '.results = [{"id": "not-a-guid"}]' "" \
    "FAIL step 8 TARGET_PRICE absent after delete: results entry 1 of 1 $STEP8_ENTRY_FAIL"
step8_row absentBracedDeletedId_failsAbsent absent ".results += [{\"id\": \"{$STEP8_TP}\"}]" "" \
    "FAIL step 8 TARGET_PRICE absent after delete: results entry 2 of 2 $STEP8_ENTRY_FAIL"
step8_row absentMissingId_failsAbsent absent '.results += [{}]' "" \
    "FAIL step 8 TARGET_PRICE absent after delete: results entry 2 of 2 $STEP8_ENTRY_FAIL"
step8_row absentTwoMalformed_failsAbsent absent '.results += [42, {"id": null}]' "" \
    "FAIL step 8 TARGET_PRICE absent after delete: results entries 2, 3 of 3 are not alerts with a GUID id"
step8_row absentSevenMalformed_failsAbsent absent '.results = [range(7) | {id: 42}]' "" \
    "FAIL step 8 TARGET_PRICE absent after delete: results entries 1, 2, 3, 4, 5 and 2 more of 7 are not alerts with a GUID id"
step8_row absentOtherAlert_passes absent ".results += [{\"id\": \"$OTHER_GUID\"}]" "" PASS
reset_alert_files

# ---------------------------------------------------------------------------------------------
# response_kind and expect_error: the step-7 status and response-kind checks.

ERROR_400='{"statusCode":400,"message":"Invalid alert threshold."}'
PROBLEM_400='{"type":"https://tools.ietf.org/html/rfc9110#section-15.5.1","title":"One or more validation errors occurred.","status":400,"errors":{"accountId":["The accountId field is required."]},"traceId":"00-a2c33a5432a347217784eb7cc0a95605-0123456789abcdef-00"}'

# kind_row SCENARIO_RESULT STATUS BODY EXPECTED
kind_row() {
    last_response "$2" "application/json" "$3"
    assert_eq "responseKind_$1" "$4" "$(response_kind)"
}

kind_row errorResponseMatchingStatus_errorResponse 400 "$ERROR_400" error_response
kind_row errorResponseOtherStatusCode_flagged 404 "$ERROR_400" "error_response with another statusCode"
kind_row problemMatchingStatus_problem 400 "$PROBLEM_400" problem
kind_row problemOtherStatus_flagged 404 "$PROBLEM_400" "problem with another status"
kind_row problemWithEmptyErrors_json 400 '{"status":400,"errors":{}}' json
kind_row statusCodeString_json 400 '{"statusCode":"400","message":"x"}' json
kind_row emptyBody_empty 404 "" empty
kind_row textBody_text 404 "Not Found" text
kind_row jsonArray_json 400 '[{"statusCode":400,"message":"x"}]' json
kind_row twoJsonValues_json 400 '{} {}' json

# expect_error_row SCENARIO_RESULT KIND WANT_STATUS STATUS CONTENT_TYPE BODY EXPECTED: EXPECTED
# is "PASS" or the FAIL reason of the check "probe".
expect_error_row() {
    local expected="PASS probe"
    if [[ "$7" != "PASS" ]]; then
        expected="FAIL probe: $7"
    fi
    last_response "$4" "$5" "$6"
    capture expect_error probe "$3" "$2"
    if [[ "$OUT" == "$expected" ]]; then
        check_pass "expectError_$1"
    else
        check_fail "expectError_$1" "output [$(flat "$OUT")], expected [$expected]"
    fi
}

ER_400="an ErrorResponse with statusCode 400 as application/json"
PR_400="a validation problem with status 400 as application/problem+json"
NR="no route, so neither an ErrorResponse nor a validation problem"
expect_error_row errorResponseAsJson_passes error_response 400 400 "application/json; charset=utf-8" "$ERROR_400" PASS
expect_error_row errorResponseAsProblemJson_failsContentType error_response 400 400 \
    "application/problem+json; charset=utf-8" "$ERROR_400" \
    "status 400, body kind [error_response], content type [application/problem+json]; expected 400: $ER_400"
# The media type is compared whole, in any case and without its parameters, so a type that only
# begins with the expected one is another type.
expect_error_row errorResponseAsJsonp_failsContentType error_response 400 400 "application/jsonp" "$ERROR_400" \
    "status 400, body kind [error_response], content type [application/jsonp]; expected 400: $ER_400"
expect_error_row errorResponseAsJsonSeq_failsContentType error_response 400 400 \
    "application/json-seq; charset=utf-8" "$ERROR_400" \
    "status 400, body kind [error_response], content type [application/json-seq]; expected 400: $ER_400"
expect_error_row errorResponseMixedCaseJsonWithBlanks_passes error_response 400 400 \
    $' Application/JSON\t; charset=utf-8' "$ERROR_400" PASS
expect_error_row problemAsProblemJsonLonger_failsContentType problem 400 400 "application/problem+jsonx" \
    "$PROBLEM_400" "status 400, body kind [problem], content type [application/problem+jsonx]; expected 400: $PR_400"
expect_error_row problemUpperCaseProblemJson_passes problem 400 400 "APPLICATION/PROBLEM+JSON" "$PROBLEM_400" PASS
expect_error_row errorResponseOtherStatusCode_fails error_response 404 404 "application/json" "$ERROR_400" \
    "status 404, body kind [error_response with another statusCode], content type [application/json]; expected 404: an ErrorResponse with statusCode 404 as application/json"
expect_error_row problemAsProblemJson_passes problem 400 400 "application/problem+json; charset=utf-8" "$PROBLEM_400" PASS
expect_error_row problemAsJson_failsContentType problem 400 400 "application/json" "$PROBLEM_400" \
    "status 400, body kind [problem], content type [application/json]; expected 400: $PR_400"
expect_error_row errorResponseWhereProblemExpected_fails problem 400 400 "application/json" "$ERROR_400" \
    "status 400, body kind [error_response], content type [application/json]; expected 400: $PR_400"
expect_error_row noRouteEmptyBody_passes no_route 404 404 "" "" PASS
expect_error_row noRouteTextBody_passes no_route 404 404 "text/plain" "Not Found" PASS
expect_error_row noRouteGotErrorResponse_fails no_route 404 404 "application/json" '{"statusCode":404,"message":"x"}' \
    "status 404, body kind [error_response], content type [application/json]; expected 404: $NR"
expect_error_row noRouteGotProblem_fails no_route 404 404 "application/problem+json" \
    '{"status":404,"errors":{"id":["bad"]}}' \
    "status 404, body kind [problem], content type [application/problem+json]; expected 404: $NR"
expect_error_row otherStatus_fails error_response 404 400 "application/json" "$ERROR_400" \
    "status 400, body kind [error_response], content type [application/json]; expected 404: an ErrorResponse with statusCode 404 as application/json"
expect_error_row transportError_fails no_route 404 000 "" "" \
    "transport error (stubbed transport error), body kind [empty], content type [none]; expected 404: $NR"
expect_error_row unknownKind_fails other 400 400 "application/json" "$ERROR_400" \
    "unknown expected response kind [other]"

# check_reserved_notifications_routes, as steps 2 and 7 call it, and step 7's PATCH bodies on
# its temporary alert.

H1="c0000000-0000-4000-8000-000000000001"
TEMP_ID="aaaaaaaa-0000-4000-8000-0000000000a7"
STUB_RESERVED_STATUS=404
STUB_RESERVED_CTYPE=""
STUB_RESERVED_BODY=""
STUB_RESERVED_ALLOW=""
STUB_TEMP_CREATED=1
STUB_BINDING_KIND="problem"
# The notifications literal answers PATCH with the valid body, and DELETE without one, with the
# STUB_RESERVED_* values: an Allow header STUB_RESERVED_ALLOW unless it is empty. Only the
# temporary alert's create is answered, 201 with STUB_TEMP_CREATED 1 and a 400 ErrorResponse
# otherwise. Its missing and null enabled get the ErrorResponse 400, its two unbindable bodies
# the 400 of STUB_BINDING_KIND (problem or error_response). Every other request gets a transport
# error.
# shellcheck disable=SC2329 # Invoked through the http stub.
route_response() {
    case "$1 $2" in
        "PATCH $ALERTS_URL/notifications" | "DELETE $ALERTS_URL/notifications")
            if [[ ("$1" == "PATCH" && ($# -ne 3 || "${3-}" != '{"enabled":true}')) ||
                ("$1" == "DELETE" && $# -ne 2) ]]; then
                return 1
            fi
            last_response "$STUB_RESERVED_STATUS" "$STUB_RESERVED_CTYPE" "$STUB_RESERVED_BODY"
            if [[ -n "$STUB_RESERVED_ALLOW" ]]; then
                printf 'HTTP/1.1 %s\r\nAllow: %s\r\n\r\n' "$STUB_RESERVED_STATUS" "$STUB_RESERVED_ALLOW" \
                    >"$PRIVATE_DIR/headers"
            fi
            ;;
        "POST $ALERTS_URL")
            if [[ $# -ne 3 || "${3-}" != "$(alert_body "$HOLDER_ID" TARGET_PRICE "$H1" ABOVE "$MAX_THRESHOLD")" ]]; then
                return 1
            fi
            if [[ "$STUB_TEMP_CREATED" -eq 1 ]]; then
                last_response 201 "application/json; charset=utf-8" "{\"id\":\"$TEMP_ID\"}"
            else
                last_response 400 "application/json; charset=utf-8" "$ERROR_400"
            fi
            ;;
        "PATCH $ALERTS_URL/$TEMP_ID")
            case "${3-}" in
                '{}' | '{"enabled":null}')
                    last_response 400 "application/json; charset=utf-8" "$ERROR_400"
                    ;;
                '{"enabled":true' | '{"enabled":"true"}')
                    if [[ "$STUB_BINDING_KIND" == "problem" ]]; then
                        last_response 400 "application/problem+json; charset=utf-8" "$PROBLEM_400"
                    else
                        last_response 400 "application/json; charset=utf-8" "$ERROR_400"
                    fi
                    ;;
                *) return 1 ;;
            esac
            ;;
        "DELETE $ALERTS_URL/$TEMP_ID") last_response 204 "" "" ;;
        *) return 1 ;;
    esac
}

# want_check CHECK EXPECTED: collects a reason unless the captured OUT reports CHECK on exactly
# one line: "PASS CHECK" when EXPECTED is PASS, otherwise a FAIL whose reason contains EXPECTED.
want_check() {
    local line verdict="" found=0
    while IFS= read -r line; do
        if [[ "$line" == "PASS $1" || "$line" == "FAIL $1: "* ]]; then
            found=$((found + 1))
            verdict="$line"
        fi
    done <<<"$OUT"
    if [[ $found -ne 1 ]]; then
        reasons+=("[$1] reported on $found lines, expected one")
    elif [[ "$2" == "PASS" && "$verdict" != "PASS $1" ]]; then
        reasons+=("[$1] reported [$verdict], expected PASS")
    elif [[ "$2" != "PASS" && "$verdict" != "FAIL $1: "*"$2"* ]]; then
        reasons+=("[$1] reported [$verdict], expected a FAIL naming [$2]")
    fi
}

# reserved_row SCENARIO_RESULT STATUS CONTENT_TYPE BODY ALLOW EXPECTED: both requests answered
# with STATUS, CONTENT_TYPE and BODY, and an Allow header ALLOW unless it is empty. EXPECTED is
# "PASS", or text both checks' FAIL reasons must contain.
reserved_row() {
    local method
    STUB_RESERVED_STATUS="$2"
    STUB_RESERVED_CTYPE="$3"
    STUB_RESERVED_BODY="$4"
    STUB_RESERVED_ALLOW="$5"
    : >"$TEST_DIR/requests"
    capture check_reserved_notifications_routes "step 7"
    want_rc 0
    for method in PATCH DELETE; do
        want_check "step 7 $method notifications path 404" "$6"
    done
    if [[ "$(grep -c '' <<<"$OUT")" != 2 ]]; then
        reasons+=("expected exactly one line per check")
    fi
    if [[ "$(cat "$TEST_DIR/requests")" != "PATCH $ALERTS_URL/notifications"$'\n'"DELETE $ALERTS_URL/notifications" ]]; then
        reasons+=("requests [$(flat "$(cat "$TEST_DIR/requests")")], expected a PATCH and then a DELETE on the notifications path")
    fi
    conclude "checkReservedNotificationsRoutes_$1"
}

reserved_row plain404_passes 404 "" "" "" PASS
reserved_row featureDisabled403_fails 403 "application/json" "$FORBIDDEN_BODY" "" "status 403, body kind [json]"
reserved_row methodNotAllowed405WithAllow_fails 405 "" "" GET \
    "status 405 with an Allow header; expected 404 with no route and no Allow header"
STUB_RESERVED_STATUS=404
STUB_RESERVED_CTYPE=""
STUB_RESERVED_BODY=""
STUB_RESERVED_ALLOW=""

: >"$TEST_DIR/requests"
capture step2_flag_off
want_check "step 2 PATCH notifications path 404" PASS
want_check "step 2 DELETE notifications path 404" PASS
conclude step2FlagOff_reservedNotificationsPath_checksBothMethods

# step7_row SCENARIO_RESULT CREATED KIND EXPECTED: step7_errors with the temporary alert created
# (CREATED 1) or refused (0) and its two unbindable PATCH bodies answered as KIND. EXPECTED is
# "PASS", or text both binding checks' FAIL reasons must contain. The notifications literal
# answers with routing's plain 404 throughout.
step7_row() {
    STUB_TEMP_CREATED="$2"
    STUB_BINDING_KIND="$3"
    reset_alert_files
    capture step7_errors
    want_check "step 7 PATCH malformed JSON 400" "$4"
    want_check 'step 7 PATCH quoted enabled "true" 400' "$4"
    want_check "step 7 PATCH notifications path 404" PASS
    want_check "step 7 DELETE notifications path 404" PASS
    conclude "step7Errors_$1"
}

step7_row unbindablePatchAnsweredProblem_passes 1 problem PASS
step7_row unbindablePatchAnsweredErrorResponse_fails 1 error_response "status 400, body kind [error_response]"
step7_row temporaryAlertRefused_failsBothBindingChecks 0 problem \
    "creating the temporary alert gave status 400, body kind [error_response]; expected 201 with an id"
reset_alert_files

# ---------------------------------------------------------------------------------------------
# step12_untriggered_ack: a changed row's reason names the AlertDTO fields that differ and only
# counts every other key, so a key that holds the holder's password never reaches the output,
# whole or in part.

LEAK="e2e-checks-leak-marker"
A12="aaaaaaaa-0000-4000-8000-000000000012"
# The disabled, untriggered state step 12 requires, beside a key AlertDTO does not have.
ROW12="{\"id\":\"$A12\",\"enabled\":false,\"triggeredAt\":null,\"triggerValue\":null,\"acknowledged\":false,\"note\":\"$LEAK\"}"

STEP12_LISTS=()
STEP12_GETS=0
# shellcheck disable=SC2329 # Invoked through the http stub.
route_response() {
    local list='{"results":[]}'
    case "$1 $2" in
        "POST $ALERTS_URL")
            last_response 201 "application/json; charset=utf-8" "{\"id\":\"$A12\",\"armingRevision\":1}"
            ;;
        "PATCH $ALERTS_URL/$A12")
            last_response 200 "application/json; charset=utf-8" "{\"id\":\"$A12\",\"enabled\":false}"
            ;;
        "POST $ALERTS_URL/$A12/acknowledge") last_response 204 "" "" ;;
        "GET $ALERTS_URL?accountId=$HOLDER_ID")
            if [[ $STEP12_GETS -lt ${#STEP12_LISTS[@]} ]]; then
                list="${STEP12_LISTS[$STEP12_GETS]}"
            fi
            STEP12_GETS=$((STEP12_GETS + 1))
            last_response 200 "application/json; charset=utf-8" "$list"
            ;;
        *) return 1 ;;
    esac
}

# step12_with BEFORE_JQ AFTER_JQ: step12_untriggered_ack, captured, with the listing before the
# acknowledge holding ROW12 as BEFORE_JQ changes it and the listing after it as AFTER_JQ does.
step12_with() {
    reset_alert_files
    PAIRS_READY=1
    H1="$U1"
    EVIDENCE_DIR="$TEST_DIR/evidence-12"
    mkdir -p "$EVIDENCE_DIR"
    STEP12_GETS=0
    STEP12_LISTS=(
        "{\"results\":[$(jq -c "$1" <<<"$ROW12" | tr -d '\r')]}"
        "{\"results\":[$(jq -c "$2" <<<"$ROW12" | tr -d '\r')]}"
    )
    capture step12_untriggered_ack
}

# A holder password in random_secret's format, assembled here so no literal resembles a
# credential.
PW12="Pi-$(printf '%02x' {16..31})"
ACK12_FAIL="FAIL step 12 acknowledge leaves an untriggered alert unchanged"

# want_no_fragment PREFIX SECRET: collect a reason when a captured OUT line holding PREFIX holds
# any 8 consecutive characters of SECRET.
want_no_fragment() {
    local lines i
    lines="$(grep -F -- "$1" <<<"$OUT" || true)"
    for ((i = 0; i + 8 <= ${#2}; i++)); do
        if [[ "$lines" == *"${2:i:8}"* ]]; then
            reasons+=("a [$1] line holds the 8 password characters from offset $i")
            return 0
        fi
    done
}

# step12_secret_key SCENARIO_RESULT AFTER_JQ EXPECTED: step12_untriggered_ack run as step12_with
# '.' AFTER_JQ runs it, with PW12 as the holder's password; its step-12 FAIL line must read
# EXPECTED and hold no 8 consecutive characters of PW12, and no output the row's LEAK value.
step12_secret_key() {
    HOLDER_PASSWORD="$PW12"
    step12_with '.' "$2"
    HOLDER_PASSWORD=""
    want_line "$ACK12_FAIL: $3"
    want_no_fragment "$ACK12_FAIL" "$PW12"
    want_no_text "$LEAK"
    conclude "step12UntriggeredAck_$1"
}

step12_secret_key passwordAsChangedKey_countsItWithoutPasswordFragment \
    ".acknowledged = true | .[\"$PW12\"] = 1" \
    "acknowledging changed the row: acknowledged, 1 other key"
step12_secret_key longKeyHoldingPassword_countsItWithoutPasswordFragment \
    ".triggeredAt = \"2026-11-26T01:02:03Z\" | .acknowledged = true | .note = \"other\"
        | .[\"k-$PW12-$(printf 'z%.0s' {1..8})\"] = 1" \
    "acknowledging changed the row: acknowledged, triggeredAt, 2 other keys"
reset_alert_files

# ---------------------------------------------------------------------------------------------
# e2e.sh executed: the main guard, the jq literal-precision probe and the step-1 abort. PATH
# starts with this run's own docker, node and curl, which record every call; docker answers
# "docker compose version", and compose ps as for a project with no service running.

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/lossy-jq" "$TEST_DIR/run-lossy" "$TEST_DIR/run-down"
cat >"$TEST_DIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-}" == "compose version" ]]; then
    exit 0
fi
echo "docker $*" >>"${0%/*}/calls"
if [[ " $* " == *" ps "* ]]; then
    exit 0
fi
exit 1
EOF
cat >"$TEST_DIR/bin/node" <<'EOF'
#!/usr/bin/env bash
echo "node $*" >>"${0%/*}/calls"
exit 1
EOF
cat >"$TEST_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >>"${0%/*}/calls"
exit 7
EOF
# jq 1.6 reads every number as a double, so it prints MAX_TRIGGER_VALUE as 1e+20.
cat >"$TEST_DIR/lossy-jq/jq" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "jq-1.6"
    exit 0
fi
"$REAL_JQ" "$@" | sed 's/99999999999999999999\.99999999/1e+20/g'
EOF
chmod +x "$TEST_DIR/bin/docker" "$TEST_DIR/bin/node" "$TEST_DIR/bin/curl" "$TEST_DIR/lossy-jq/jq"
: >"$TEST_DIR/bin/calls"

# run_e2e TMP [PATH_PREFIX]: e2e.sh executed with valid options and TMPDIR TMP; sets OUT and RC.
run_e2e() {
    set +e
    OUT="$(REAL_JQ="$REAL_JQ" TMPDIR="$1" PATH="${2:+$2:}$TEST_DIR/bin:$PATH" "$BASH" "$E2E" \
        --project "$STUB_PROJECT" --base-url "$STUB_BASE_URL" --compose-file "$TEST_DIR/compose.yaml" 2>&1)"
    RC=$?
    set -e
}

run_e2e "$TEST_DIR/run-lossy" "$TEST_DIR/lossy-jq"
want_rc 2
want_line "jq must keep number literals exact (jq 1.7 or later); jq-1.6 changes $MAX_TRIGGER_VALUE."
want_no_text "INFO run dir"
if compgen -G "$TEST_DIR/run-lossy/pi-e2e.*" >/dev/null; then
    reasons+=("a run directory was created")
fi
conclude e2eScript_jqChangesNumberLiterals_exitsTwoBeforeAnyRun

: >"$TEST_DIR/bin/calls"
run_e2e "$TEST_DIR/run-down"
want_rc 1
want_line "FAIL step 1 services running: not running in project [$STUB_PROJECT]: $REQUIRED_SERVICES"
want_line "PASS cleanup"
want_line "SUMMARY 1 passed, 1 failed"
want_no_text "step 1 readiness"
if [[ "$(cat "$TEST_DIR/bin/calls")" != "docker compose -p $STUB_PROJECT -f $TEST_DIR/compose.yaml ps --status running --services" ]]; then
    reasons+=("outside calls [$(flat "$(cat "$TEST_DIR/bin/calls")")], expected only the docker compose ps")
fi
conclude e2eScript_executedWithServicesDown_runsMainAbortsStepOneAndSummarises

echo "SUMMARY $checks_passed passed, $checks_failed failed"
if [[ $checks_failed -ne 0 ]]; then
    exit 1
fi
