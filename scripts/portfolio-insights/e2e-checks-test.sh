#!/usr/bin/env bash
# Tests the verification paths of scripts/portfolio-insights/e2e.sh offline, through its real
# functions. Sourcing e2e.sh defines them without running its steps. Every outside call is a
# stub: shell functions while sourced (http, broker_logs, container_env, running_services, poll,
# docker, node, curl), scripts first on PATH when executed (docker, node, curl, a lossy jq), so
# no docker daemon, network or running stack is involved:
#   - the exact decimal helpers num_split, magnitude_cmp and num_cmp;
#   - the step-9 triggerValue verdict, the step-9 instrument choice and step9_trigger with both;
#   - alert_body, the create body of every alert request;
#   - the step-1 startup decision: startup_flag_default and step1_ready;
#   - the step-5 rendered insights log line: insights_line_logged and step5_figures;
#   - the step-6 empty-account check and the step-8 AlertDTO filters (WANT_JQ, ALERT_JQ);
#   - the step-7 response checks response_kind and expect_error;
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
# Sourcing e2e.sh. Its preamble checks for docker and node and runs "docker compose version":
# these functions satisfy both without a daemon, and every other docker call fails. curl fails
# as a transport error would, so a request that missed the http stub never leaves the machine.

docker() {
    [[ "${1:-} ${2:-}" == "compose version" ]]
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

running_services() {
    tr ' ' '\n' <<<"$REQUIRED_SERVICES"
}

STUB_ENV_MODE="unset"
STUB_ENV_VALUE=""
# container_env SERVICE NAME: ENABLE_PORTFOLIO_INSIGHTS per STUB_ENV_MODE (unset, value or
# fail), and the dialect and interval a shipped stack reports. Like the real one, it prints the
# value byte for byte with no line feed added.
container_env() {
    case "$1 $2" in
        "feature-flag-service ENABLE_PORTFOLIO_INSIGHTS")
            case "$STUB_ENV_MODE" in
                unset) return 0 ;;
                value) printf '%s' "$STUB_ENV_VALUE" ;;
                *) return 1 ;;
            esac
            ;;
        "db-adapter DB_TYPE") printf '%s' postgres ;;
        "broker-service ALERT_EVALUATION_INTERVAL_SECONDS") printf '%s' 60 ;;
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
# shellcheck disable=SC2329 # Invoked through the http stub.
route_response() {
    case "$1 $2" in
        "GET $BASE_URL/broker-service/readyz" | "GET $BASE_URL/feature-flag-service/readyz")
            last_response 200 "text/plain" "Healthy"
            ;;
        "GET $F")
            last_response 200 "application/json; charset=utf-8" \
                "{\"id\":\"$FLAG_ID\",\"description\":\"Portfolio Insights\",\"enabled\":$STUB_FLAG_ENABLED,\"isModifiable\":true,\"tag\":\"feature\"}"
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
            want_line "FAIL step 1 flag default disabled: ENABLE_PORTFOLIO_INSIGHTS could not be read from the feature-flag-service container of project [$STUB_PROJECT]; the run needs the shipped default, disabled"
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

# ---------------------------------------------------------------------------------------------
# step6_empty: WANT_JQ's verdict, where an absent property never passes as null.

EMPTY_ID="b0000000-0000-4000-8000-000000000001"
EMPTY_OK='{"totalValue":0,"totalInvested":0,"unrealizedPnl":0,"unrealizedPnlPercent":0,"allocations":[],"largestPosition":null,"riskLevel":null}'
STUB_STATUS=200
STUB_BODY=""
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

# alert_row FILTER SCENARIO_RESULT BODY EXPECTED: FILTER is create (CREATED_FILTER), disable
# (alert(false; 1; true)) or rearm (alert(true; 2; false)); EXPECTED is "ok" or the verdict.
alert_row() {
    local filter
    case "$1" in
        create) filter="$CREATED_FILTER" ;;
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
    "status 400, body kind [error_response], content type [application/problem+json; charset=utf-8]; expected 400: $ER_400"
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

# ---------------------------------------------------------------------------------------------
# e2e.sh executed: the main guard, the jq literal-precision probe and the step-1 abort. PATH
# starts with this run's own docker, node and curl, which record every call; docker answers
# only "docker compose version".

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/lossy-jq" "$TEST_DIR/run-lossy" "$TEST_DIR/run-down"
cat >"$TEST_DIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-}" == "compose version" ]]; then
    exit 0
fi
echo "docker $*" >>"${0%/*}/calls"
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
