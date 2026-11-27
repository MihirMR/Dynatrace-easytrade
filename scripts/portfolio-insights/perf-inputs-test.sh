#!/usr/bin/env bash
# Tests the input checks of scripts/portfolio-insights/perf.sh offline, through the script's
# own functions. Sourcing perf.sh only defines them; its parse_options, check_tools and
# prepare_run then set up the stubbed run as main does, and the checks below call them:
#   - read_id_list and id_file_matches: a body is exactly one JSON value with a results
#     array, and the file written holds exactly the canonical UUIDs counted;
#   - fetch_presets: each canonical preset id once, in order, and PRESETS_ERROR unless 25;
#   - insights_profile: 15 allocations, each with a numeric quantity > 0 on a distinct
#     canonical instrumentId; a non-canonical account is refused before any request or file;
#   - verify_cycle_inputs and preflight_inputs: every preset lists exactly the instruments it
#     holds, and a non-canonical preset id is refused before any request;
#   - select_insights_account: the first preset preflight_inputs recorded with 15 allocations,
#     each with a numeric quantity > 0, whatever its listing or the count of presets read;
#   - post_alert: jq encodes the request's strings, and the threshold is sent as the exact
#     token it was given, or refused before any request when it is not a plain decimal.
# http, docker and curl are shell functions here, so nothing leaves the shell: no Docker
# daemon, no network and no running stack is needed.
#
# Usage: scripts/portfolio-insights/perf-inputs-test.sh
#   --help  Show this help and exit
#
# Prints one PASS or FAIL line per check and a final SUMMARY line. Exits 0 when every check
# passes, 1 when any check fails, and 2 on a usage error or when jq or perf.sh is missing.
# The run's temporary files, perf.sh's run directory among them, are removed on exit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERF_SH="$SCRIPT_DIR/perf.sh"

usage() {
    cat <<'EOF'
Usage: scripts/portfolio-insights/perf-inputs-test.sh
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
if [[ ! -f "$PERF_SH" ]]; then
    echo "perf.sh not found next to this test: $PERF_SH" >&2
    exit 2
fi

checks_passed=0
checks_failed=0
reasons=()
test_dir=""

# Removes this run's directory and perf.sh's run directory inside it.
cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "${RUN_DIR:-}" ]]; then
        rm -rf "$RUN_DIR"
    fi
    if [[ -n "$test_dir" ]]; then
        rm -rf "$test_dir"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if ! test_dir="$(mktemp -d -t perf-inputs-test.XXXXXX)"; then
    echo "Could not create a temporary directory." >&2
    exit 2
fi

# ---------------------------------------------------------------------------------------------
# Stubs. perf.sh's check_tools, run below, finds these functions with command -v. Only
# "docker compose version", which that check runs, succeeds; every other docker or curl call
# is recorded as unexpected, and the last check fails on any.

docker() {
    if [[ "$*" == "compose version" ]]; then
        return 0
    fi
    echo "docker $*" >>"$test_dir/unexpected"
    return 1
}

curl() {
    echo "curl $*" >>"$test_dir/unexpected"
    return 7
}

: >"$test_dir/unexpected"
: >"$test_dir/compose.yaml"
# prepare_run makes perf.sh's run directory under TMPDIR, so it lands inside this run's directory.
TMPDIR="$test_dir"
# shellcheck source-path=SCRIPTDIR source=perf.sh
source "$PERF_SH"
parse_options --project perf-inputs-test --base-url http://stub.invalid \
    --compose-file "$test_dir/compose.yaml"
check_tools
prepare_run

# ---------------------------------------------------------------------------------------------
# Reporting. perf.sh's pass and fail count its own checks, which preflight_inputs prints, so
# these have other names.

check_pass() {
    checks_passed=$((checks_passed + 1))
    echo "PASS $1"
}

check_fail() {
    checks_failed=$((checks_failed + 1))
    echo "FAIL $1: $2"
}

summarize() {
    echo "SUMMARY ${checks_passed} passed, ${checks_failed} failed"
}

# printable TEXT: TEXT on one line, with carriage returns and newlines shown as \r and \n.
printable() {
    local text="${1//$'\r'/\\r}"
    printf '%s' "${text//$'\n'/\\n}"
}

# expect_eq WHAT ACTUAL EXPECTED: records a reason when ACTUAL is not EXPECTED.
expect_eq() {
    if [[ "$2" != "$3" ]]; then
        reasons+=("$1 is [$(printable "$2")], expected [$(printable "$3")]")
    fi
}

# Reports one PASS or FAIL line for CHECK from the reasons collected since the last call.
conclude() {
    local joined
    if [[ ${#reasons[@]} -eq 0 ]]; then
        check_pass "$1"
    else
        joined="$(printf '%s; ' "${reasons[@]}")"
        check_fail "$1" "${joined%; }"
    fi
    reasons=()
}

check="perfSh_sourcedThenInitialized_definesFunctionsWithoutRunningChecks"
expect_eq "STARTED_AT" "$STARTED_AT" ""
expect_eq "perf.sh passed and failed counts" "$passed $failed" "0 0"
expect_eq "EXIT trap" "$(trap -p EXIT)" "trap -- 'cleanup' EXIT"
expect_eq "type of main" "$(type -t main)" "function"
expect_eq "run directory parent" "${RUN_DIR%/*}" "$test_dir"
conclude "$check"

# ---------------------------------------------------------------------------------------------
# Fixtures and the http stub

ACCOUNT_PREFIX="a0000000-0000-4000-8000-"
INSTRUMENT_PREFIX="c0000000-0000-4000-8000-"
ALERT_ID="e0000000-0000-4000-8000-000000000001"
PRESETS_URL="$BASE_URL/user-service/api/accounts/presets?limit=$PRESET_COUNT"
LISTING_URL="$BASE_URL/broker-service/v1/instrument?accountId="
TRANSPORT_ERROR="curl: (7) Failed to connect to stub.invalid port 80"
# jq definitions, with $a and $c bound to the account and instrument id prefixes:
# account(k) and instrument(k) are id k, and ids(prefix; n) the ids 1 to n.
JQ_IDS="def pad12: (\"000000000000\" + tostring)[-12:];
def account(k): \$a + (k | pad12);
def instrument(k): \$c + (k | pad12);
def ids(prefix; n): [range(1; n + 1) | prefix + pad12];"

account() {
    printf '%s%012d' "$ACCOUNT_PREFIX" "$1"
}

instrument() {
    printf '%s%012d' "$INSTRUMENT_PREFIX" "$1"
}

# id_lines KIND FIRST LAST: the account or instrument ids FIRST to LAST, one per line.
id_lines() {
    local k
    for ((k = $2; k <= $3; k++)); do
        "$1" "$k"
        echo
    done
}

# words WORD COUNT: COUNT copies of WORD, separated by single spaces.
words() {
    local k text=""
    for ((k = 0; k < $2; k++)); do
        text="$text${text:+ }$1"
    done
    printf '%s' "$text"
}

# fixture PROGRAM: the compact JSON a jq program writes from no input, with $a and $c bound
# to the account and instrument id prefixes. jq on Windows ends lines with CRLF.
fixture() {
    command jq -cn --arg a "$ACCOUNT_PREFIX" --arg c "$INSTRUMENT_PREFIX" "$JQ_IDS $1" | tr -d '\r'
}

# presets_json COUNT [EDIT]: a presets body of accounts 1 to COUNT, after a jq EDIT of the list.
presets_json() {
    fixture "ids(\$a; $1) | map({id: ., username: \"preset\"}) | ${2:-.} | {results: .}"
}

# listing_json [EDIT]: an instrument listing of instruments 1 to 15, after a jq EDIT.
listing_json() {
    fixture "ids(\$c; 15) | map({id: ., code: \"CODE\", name: \"Instrument\", amount: 1}) | ${1:-.} | {results: .}"
}

# insights_json [EDIT]: insights with one allocation per instrument 1 to 15, each holding its
# own number of units, after a jq EDIT of the allocations.
insights_json() {
    fixture "ids(\$c; 15) | to_entries | map({instrumentId: .value, name: \"Instrument\", quantity: (.key + 1), value: 10, percent: 6.67}) | ${1:-.} | {totalValue: 150, totalInvested: 150, unrealizedPnl: 0, unrealizedPnlPercent: 0, allocations: ., largestPosition: .[0], riskLevel: \"LOW\"}"
}

INSIGHTS_OK="$(insights_json)"
LISTING_OK="$(listing_json)"
PRESETS_OK="$(presets_json 25)"
ALL_ACCOUNTS="$(id_lines account 1 25)"
ALL_INSTRUMENTS="$(id_lines instrument 1 15)"
DEFAULT_INSIGHTS="$INSIGHTS_OK"
DEFAULT_LISTING="$LISTING_OK"

# http METHOD URL [BODY]: perf.sh's http contract without a request. Appends "METHOD URL" to
# $test_dir/requests and writes BODY to $test_dir/request-body, then answers from STUB_STATUS
# and STUB_BODY, keyed by "METHOD URL"; otherwise with DEFAULT_INSIGHTS or DEFAULT_LISTING for
# an insights or instrument-listing GET, and 404 for anything else. Status 000 is a transport
# error, as perf.sh's http reports one.
declare -A STUB_STATUS=()
declare -A STUB_BODY=()
http() {
    local key="$1 $2"
    echo "$key" >>"$test_dir/requests"
    if [[ $# -ge 3 ]]; then
        printf '%s' "$3" >"$test_dir/request-body"
    fi
    HTTP_CTYPE="application/json"
    HTTP_ERROR=""
    if [[ -n "${STUB_STATUS[$key]+set}" ]]; then
        HTTP_STATUS="${STUB_STATUS[$key]}"
        HTTP_BODY="${STUB_BODY[$key]-}"
    else
        case "$key" in
            "GET $INSIGHTS_URL/"*)
                HTTP_STATUS=200
                HTTP_BODY="$DEFAULT_INSIGHTS"
                ;;
            "GET $LISTING_URL"*)
                HTTP_STATUS=200
                HTTP_BODY="$DEFAULT_LISTING"
                ;;
            *)
                HTTP_STATUS=404
                HTTP_BODY=""
                ;;
        esac
    fi
    if [[ "$HTTP_STATUS" == "000" ]]; then
        HTTP_CTYPE=""
        HTTP_ERROR="$TRANSPORT_ERROR"
        HTTP_BODY=""
    fi
}

# stub_reply METHOD URL STATUS [BODY]: the answer http gives to METHOD URL.
stub_reply() {
    STUB_STATUS["$1 $2"]="$3"
    STUB_BODY["$1 $2"]="${4-}"
}

# With JQ_EXTRA_LINE set, jq prints that line after its own output: a parser that writes an id
# it did not count, which the line check after each parse must catch.
JQ_EXTRA_LINE=""
jq() {
    local rc=0
    command jq "$@" || rc=$?
    if [[ -n "$JQ_EXTRA_LINE" ]]; then
        printf '%s\n' "$JQ_EXTRA_LINE"
    fi
    return "$rc"
}

# reset_state: forgets the requests, the stub answers and every per-account file of the last
# check, and restores the default answers.
reset_state() {
    : >"$test_dir/requests"
    rm -f "$test_dir/request-body" "$RUN_DIR"/held-*
    STUB_STATUS=()
    STUB_BODY=()
    JQ_EXTRA_LINE=""
    DEFAULT_INSIGHTS="$INSIGHTS_OK"
    DEFAULT_LISTING="$LISTING_OK"
    HTTP_CTYPE="application/json"
}

file_size() {
    wc -c <"$1" | tr -d ' '
}

request_count() {
    echo $(($(wc -l <"$test_dir/requests")))
}

# held_files: how many held-* files perf.sh's run directory holds.
held_files() {
    local f count=0
    for f in "$RUN_DIR"/held-*; do
        if [[ -e "$f" ]]; then
            count=$((count + 1))
        fi
    done
    echo "$count"
}

# use_valid_presets: fetch_presets reads the 25 valid preset ids, as a run does first.
use_valid_presets() {
    stub_reply GET "$PRESETS_URL" 200 "$PRESETS_OK"
    fetch_presets || true
    expect_eq "PRESETS_ERROR of the valid presets" "$PRESETS_ERROR" ""
    : >"$test_dir/requests"
}

# use_three_presets: a presets file of accounts 1 to 3, as fetch_presets leaves one that it
# accepted. verify_cycle_inputs treats each preset alike, and three keep these checks short.
use_three_presets() {
    PRESETS_ERROR=""
    id_lines account 1 3 >"$RUN_DIR/presets"
}

# ---------------------------------------------------------------------------------------------
# read_id_list

# read_ids_counted CHECK BODY COUNTS IDS: read_id_list succeeds on BODY with "IDS_TOTAL
# IDS_INVALID IDS_DUPLICATE" equal to COUNTS, and writes exactly IDS, replacing a stale line.
read_ids_counted() {
    local rc=0
    reset_state
    echo "stale" >"$test_dir/ids"
    read_id_list "$2" "$test_dir/ids" || rc=$?
    expect_eq "exit status" "$rc" 0
    expect_eq "IDS_ERROR" "$IDS_ERROR" ""
    expect_eq "IDS_TOTAL IDS_INVALID IDS_DUPLICATE" \
        "${IDS_TOTAL-unset} ${IDS_INVALID-unset} ${IDS_DUPLICATE-unset}" "$3"
    expect_eq "written ids" "$(cat "$test_dir/ids")" "$4"
    conclude "$1"
}

# read_ids_rejected CHECK BODY IDS_ERROR [EXTRA_LINE]: read_id_list fails on BODY naming
# IDS_ERROR and leaves its file empty. EXTRA_LINE is a line jq writes without counting it.
read_ids_rejected() {
    local rc=0
    reset_state
    echo "stale" >"$test_dir/ids"
    JQ_EXTRA_LINE="${4-}"
    read_id_list "$2" "$test_dir/ids" || rc=$?
    JQ_EXTRA_LINE=""
    expect_eq "exit status" "$rc" 1
    expect_eq "IDS_ERROR" "$IDS_ERROR" "$3"
    expect_eq "written file size" "$(file_size "$test_dir/ids")" 0
    conclude "$1"
}

ACCOUNTS_1_AND_3="$(account 1)
$(account 3)"
three="$(presets_json 3)"
read_ids_counted "readIdList_oneEnvelope_writesCanonicalIdsInOrder" "$(presets_json 3 'reverse')" \
    "3 0 0" "$(account 3)
$(account 2)
$(account 1)"
read_ids_counted "readIdList_upperCaseCanonicalIds_writesThemLowerCased" \
    "$(presets_json 3 'map(.id |= ascii_upcase)')" "3 0 0" "$(id_lines account 1 3)"
read_ids_counted "readIdList_emptyResults_succeedsWritingNothing" '{"results":[]}' "0 0 0" ""
read_ids_counted "readIdList_nonCanonicalId_countsItInvalidAndOmitsIt" \
    "$(presets_json 3 '.[1].id = "../../etc/passwd"')" "3 1 0" "$ACCOUNTS_1_AND_3"
read_ids_counted "readIdList_multiLineId_countsItInvalidAndOmitsIt" \
    "$(presets_json 3 '.[1].id = (account(2) + "\n" + account(4))')" "3 1 0" \
    "$ACCOUNTS_1_AND_3"
read_ids_counted "readIdList_idWithTrailingNewline_countsItInvalidAndOmitsIt" \
    "$(presets_json 3 '.[1].id = (account(2) + "\n")')" "3 1 0" "$ACCOUNTS_1_AND_3"
read_ids_counted "readIdList_numericId_countsItInvalidAndOmitsIt" \
    "$(presets_json 3 '.[1].id = 5')" "3 1 0" "$ACCOUNTS_1_AND_3"
read_ids_counted "readIdList_missingId_countsItInvalidAndOmitsIt" \
    "$(presets_json 3 '.[1] |= del(.id)')" "3 1 0" "$ACCOUNTS_1_AND_3"
read_ids_counted "readIdList_resultNotAnObject_countsItInvalidAndOmitsIt" \
    "$(presets_json 3 '.[1] = "x"')" "3 1 0" "$ACCOUNTS_1_AND_3"
read_ids_counted "readIdList_duplicateId_countsTheDuplicate" \
    "$(presets_json 3 '.[2].id = .[0].id')" "3 0 1" "$(account 1)
$(account 2)
$(account 1)"
read_ids_counted "readIdList_caseOnlyDuplicateId_countsTheDuplicate" \
    "$(presets_json 3 '.[2].id = (.[0].id | ascii_upcase)')" "3 0 1" "$(account 1)
$(account 2)
$(account 1)"

unreadable="an unreadable application/json body"
read_ids_rejected "readIdList_validEnvelopeThenSecondEnvelope_failsAsUnreadable" "$three
{\"results\":[{\"id\":\"$(account 4)\"}]}" "$unreadable"
read_ids_rejected "readIdList_twoEnvelopesBackToBack_failsAsUnreadable" "$three$three" "$unreadable"
read_ids_rejected "readIdList_validEnvelopeThenTrailingGarbage_failsAsUnreadable" "$three garbage" \
    "$unreadable"
read_ids_rejected "readIdList_validEnvelopeThenUnclosedBrace_failsAsUnreadable" "$three{" "$unreadable"
read_ids_rejected "readIdList_nonJsonBody_failsAsUnreadable" "not json" "$unreadable"
read_ids_rejected "readIdList_emptyBody_failsAsUnreadable" "" "$unreadable"
read_ids_rejected "readIdList_resultsNotAnArray_failsAsUnreadable" \
    "{\"results\":{\"id\":\"$(account 1)\"}}" "$unreadable"
read_ids_rejected "readIdList_resultsNull_failsAsUnreadable" '{"results":null}' "$unreadable"
read_ids_rejected "readIdList_noResultsArray_failsAsUnreadable" '{"items":[]}' "$unreadable"
read_ids_rejected "readIdList_topLevelArray_failsAsUnreadable" "[{\"id\":\"$(account 1)\"}]" \
    "$unreadable"
read_ids_rejected "readIdList_parserWritesUncountedCanonicalId_failsNamingCounts" "$three" \
    "results whose written ids do not match their counts: 4 id lines written, 0 of them not canonical UUIDs, 3 canonical ids counted" \
    "$(account 9)"
read_ids_rejected "readIdList_parserWritesUncountedMalformedLine_failsNamingCounts" "$three" \
    "results whose written ids do not match their counts: 4 id lines written, 1 of them not canonical UUIDs, 3 canonical ids counted" \
    "../x"

check="readIdList_unreadableBodyWithoutContentType_namesItUntyped"
reset_state
HTTP_CTYPE=""
rc=0
read_id_list "not json" "$test_dir/ids" || rc=$?
expect_eq "exit status" "$rc" 1
expect_eq "IDS_ERROR" "$IDS_ERROR" "an unreadable untyped body"
conclude "$check"

# ---------------------------------------------------------------------------------------------
# id_file_matches

# id_file_kept CHECK CONTENT COUNT: id_file_matches accepts a file of CONTENT for COUNT ids and
# leaves it as it was.
id_file_kept() {
    local rc=0
    reset_state
    printf '%s' "$2" >"$test_dir/ids"
    id_file_matches "$test_dir/ids" "$3" || rc=$?
    expect_eq "exit status" "$rc" 0
    expect_eq "file" "$(cat "$test_dir/ids")" "$(printf '%s' "$2")"
    conclude "$1"
}

# id_file_emptied CHECK CONTENT COUNT ID_FILE_COUNTS: id_file_matches refuses a file of CONTENT
# for COUNT ids, empties it and names ID_FILE_COUNTS.
id_file_emptied() {
    local rc=0
    reset_state
    printf '%s' "$2" >"$test_dir/ids"
    id_file_matches "$test_dir/ids" "$3" || rc=$?
    expect_eq "exit status" "$rc" 1
    expect_eq "ID_FILE_COUNTS" "${ID_FILE_COUNTS-unset}" "$4"
    expect_eq "file size" "$(file_size "$test_dir/ids")" 0
    conclude "$1"
}

id_file_kept "idFileMatches_countCanonicalLines_succeedsKeepingFile" "$(id_lines account 1 3)
" 3
id_file_kept "idFileMatches_lastLineWithoutNewline_countsItAndSucceeds" "$(id_lines account 1 2)" 2
id_file_kept "idFileMatches_emptyFileForZeroIds_succeeds" "" 0
id_file_emptied "idFileMatches_moreLinesThanCounted_failsAndEmptiesFile" "$(id_lines account 1 3)
" 2 "3 id lines written, 0 of them not canonical UUIDs, 2 canonical ids counted"
id_file_emptied "idFileMatches_fewerLinesThanCounted_failsAndEmptiesFile" "$(id_lines account 1 2)
" 3 "2 id lines written, 0 of them not canonical UUIDs, 3 canonical ids counted"
id_file_emptied "idFileMatches_malformedLine_failsAndEmptiesFile" "$(account 1)
../x
$(account 3)
" 3 "3 id lines written, 1 of them not canonical UUIDs, 3 canonical ids counted"
id_file_emptied "idFileMatches_upperCaseLine_failsAndEmptiesFile" \
    "$(account 1 | tr '[:lower:]' '[:upper:]')
" 1 "1 id lines written, 1 of them not canonical UUIDs, 1 canonical ids counted"
id_file_emptied "idFileMatches_blankLine_failsAndEmptiesFile" "$(account 1)

$(account 2)
" 3 "3 id lines written, 1 of them not canonical UUIDs, 3 canonical ids counted"
# Git Bash does not parse $'\r' directly after a command substitution, so CR holds it.
CR=$'\r'
id_file_emptied "idFileMatches_carriageReturnLine_failsAndEmptiesFile" "$(account 1)$CR
" 1 "1 id lines written, 1 of them not canonical UUIDs, 1 canonical ids counted"

# ---------------------------------------------------------------------------------------------
# fetch_presets

presets_counts() {
    echo "GET presets gave $1 accounts, $2 without a canonical UUID id and $3 duplicate ids; exactly 25 distinct canonical account ids are needed"
}

# presets_accepted CHECK BODY: fetch_presets accepts BODY after one GET of 25 presets and
# writes the 25 account ids in order.
presets_accepted() {
    local rc=0
    reset_state
    stub_reply GET "$PRESETS_URL" 200 "$2"
    fetch_presets || rc=$?
    expect_eq "exit status" "$rc" 0
    expect_eq "PRESETS_ERROR" "$PRESETS_ERROR" ""
    expect_eq "presets file" "$(cat "$RUN_DIR/presets")" "$ALL_ACCOUNTS"
    expect_eq "requests" "$(cat "$test_dir/requests")" "GET $PRESETS_URL"
    conclude "$1"
}

# presets_rejected CHECK STATUS BODY PRESETS_ERROR: fetch_presets answered STATUS and BODY
# names PRESETS_ERROR and leaves the presets file empty, replacing a stale id.
presets_rejected() {
    local rc=0
    reset_state
    stub_reply GET "$PRESETS_URL" "$2" "$3"
    account 1 >"$RUN_DIR/presets"
    fetch_presets || rc=$?
    expect_eq "exit status" "$rc" 0
    expect_eq "PRESETS_ERROR" "$PRESETS_ERROR" "$4"
    expect_eq "presets file size" "$(file_size "$RUN_DIR/presets")" 0
    conclude "$1"
}

# presets_short CHECK BODY PRESETS_ERROR IDS: fetch_presets answered 200 and a readable BODY
# that is not 25 distinct canonical ids names PRESETS_ERROR and still writes exactly IDS, each
# canonical id once at its first occurrence and at most 25 of them, replacing a stale id.
presets_short() {
    local rc=0
    reset_state
    stub_reply GET "$PRESETS_URL" 200 "$2"
    account 99 >"$RUN_DIR/presets"
    fetch_presets || rc=$?
    expect_eq "exit status" "$rc" 0
    expect_eq "PRESETS_ERROR" "$PRESETS_ERROR" "$3"
    expect_eq "presets file" "$(cat "$RUN_DIR/presets")" "$4"
    conclude "$1"
}

ALL_BUT_FOURTH_ACCOUNT="$(id_lines account 1 3)
$(id_lines account 5 25)"
ALL_BUT_THIRD_ACCOUNT="$(id_lines account 1 2)
$(id_lines account 4 25)"

presets_accepted "fetchPresets_25DistinctCanonicalIds_writesThemInOrder" "$PRESETS_OK"
presets_accepted "fetchPresets_25UpperCaseIds_writesThemLowerCased" \
    "$(presets_json 25 'map(.id |= ascii_upcase)')"
presets_short "fetchPresets_24Ids_keepsThemNamingCounts" "$(presets_json 24)" \
    "$(presets_counts 24 0 0)" "$(id_lines account 1 24)"
presets_short "fetchPresets_26Ids_keepsFirst25NamingCounts" "$(presets_json 26)" \
    "$(presets_counts 26 0 0)" "$ALL_ACCOUNTS"
presets_short "fetchPresets_26IdsWithDuplicate_keeps25DistinctNamingCounts" \
    "$(presets_json 26 '.[1].id = .[0].id')" "$(presets_counts 26 0 1)" \
    "$(account 1)
$(id_lines account 3 26)"
presets_short "fetchPresets_emptyResults_keepsNoIdNamingCounts" '{"results":[]}' \
    "$(presets_counts 0 0 0)" ""
presets_short "fetchPresets_nonCanonicalId_keepsTheOthersNamingCounts" \
    "$(presets_json 25 '.[3].id = "../../etc/passwd"')" "$(presets_counts 25 1 0)" \
    "$ALL_BUT_FOURTH_ACCOUNT"
presets_short "fetchPresets_multiLineId_keepsTheOthersNamingCounts" \
    "$(presets_json 25 '.[3].id = (account(4) + "\n" + account(26))')" \
    "$(presets_counts 25 1 0)" "$ALL_BUT_FOURTH_ACCOUNT"
presets_short "fetchPresets_numericId_keepsTheOthersNamingCounts" \
    "$(presets_json 25 '.[3].id = 5')" "$(presets_counts 25 1 0)" "$ALL_BUT_FOURTH_ACCOUNT"
presets_short "fetchPresets_duplicateId_keepsFirstOccurrenceNamingCounts" \
    "$(presets_json 25 '.[2].id = .[0].id')" "$(presets_counts 25 0 1)" "$ALL_BUT_THIRD_ACCOUNT"
presets_short "fetchPresets_caseOnlyDuplicateId_keepsFirstOccurrenceNamingCounts" \
    "$(presets_json 25 '.[2].id = (.[0].id | ascii_upcase)')" "$(presets_counts 25 0 1)" \
    "$ALL_BUT_THIRD_ACCOUNT"
presets_rejected "fetchPresets_status503_failsNamingStatus" 503 "$PRESETS_OK" \
    "GET presets gave status 503; exactly 25 distinct canonical account ids are needed"
presets_rejected "fetchPresets_transportError_failsNamingCurlError" 000 "" \
    "GET presets gave transport error ($TRANSPORT_ERROR); exactly 25 distinct canonical account ids are needed"
presets_rejected "fetchPresets_twoEnvelopes_failsAsUnreadable" 200 "$PRESETS_OK$PRESETS_OK" \
    "GET presets gave status 200 with $unreadable; exactly 25 distinct canonical account ids are needed"
presets_rejected "fetchPresets_trailingGarbage_failsAsUnreadable" 200 "$PRESETS_OK garbage" \
    "GET presets gave status 200 with $unreadable; exactly 25 distinct canonical account ids are needed"

# ---------------------------------------------------------------------------------------------
# insights_profile

profile_counts() {
    echo "$1 allocations, $2 with a numeric quantity > 0, $3 without a canonical instrumentId, $4 held on $5 distinct instruments"
}

ALL_BUT_FIFTH="$(id_lines instrument 1 4)
$(id_lines instrument 6 15)"
UNREADABLE_PROFILE="status 200 with $unreadable"

# profile_accepted CHECK BODY: insights_profile accepts BODY for account 1, qualifies it for
# the p95 and writes the 15 held instrument ids, sorted and lower-cased.
profile_accepted() {
    local rc=0
    reset_state
    stub_reply GET "$INSIGHTS_URL/$(account 1)" 200 "$2"
    PROFILE_QUALIFIES="stale"
    insights_profile "$(account 1)" || rc=$?
    expect_eq "exit status" "$rc" 0
    expect_eq "PROFILE_STATUS" "$PROFILE_STATUS" "status 200"
    expect_eq "PROFILE_COUNTS" "$PROFILE_COUNTS" "$(profile_counts 15 15 0 15 15)"
    expect_eq "PROFILE_QUALIFIES" "$PROFILE_QUALIFIES" 1
    expect_eq "held file" "$(cat "$RUN_DIR/held-$(account 1)")" "$ALL_INSTRUMENTS"
    conclude "$1"
}

# profile_rejected CHECK STATUS BODY PROFILE_STATUS PROFILE_COUNTS HELD QUALIFIES
# [EXTRA_LINE]: insights_profile fails for account 1 answered STATUS and BODY, names
# PROFILE_STATUS and PROFILE_COUNTS, sets PROFILE_QUALIFIES to QUALIFIES and leaves exactly
# HELD in the held file. EXTRA_LINE is a line jq writes without counting it.
profile_rejected() {
    local rc=0
    reset_state
    stub_reply GET "$INSIGHTS_URL/$(account 1)" "$2" "$3"
    JQ_EXTRA_LINE="${8-}"
    PROFILE_QUALIFIES="stale"
    insights_profile "$(account 1)" || rc=$?
    JQ_EXTRA_LINE=""
    expect_eq "exit status" "$rc" 1
    expect_eq "PROFILE_STATUS" "$PROFILE_STATUS" "$4"
    expect_eq "PROFILE_COUNTS" "$PROFILE_COUNTS" "$5"
    expect_eq "PROFILE_QUALIFIES" "$PROFILE_QUALIFIES" "$7"
    expect_eq "held file" "$(cat "$RUN_DIR/held-$(account 1)" 2>/dev/null || echo "missing")" "$6"
    conclude "$1"
}

# profile_refused CHECK ACCOUNT: insights_profile refuses ACCOUNT with no request and no file,
# and does not qualify it.
profile_refused() {
    local rc=0
    reset_state
    PROFILE_QUALIFIES="stale"
    insights_profile "$2" || rc=$?
    expect_eq "exit status" "$rc" 1
    expect_eq "PROFILE_STATUS" "$PROFILE_STATUS" "refused: the account id is not a canonical UUID"
    expect_eq "PROFILE_QUALIFIES" "$PROFILE_QUALIFIES" 0
    expect_eq "requests" "$(request_count)" 0
    expect_eq "held files" "$(held_files)" 0
    conclude "$1"
}

profile_accepted "insightsProfile_15HeldNumericQuantities_succeedsWithSortedHeldFile" "$INSIGHTS_OK"
profile_accepted "insightsProfile_unsortedUpperCaseFractionalHoldings_succeedsWithSortedHeldFile" \
    "$(insights_json 'reverse | map(.instrumentId |= ascii_upcase | .quantity = 0.5)')"
profile_rejected "insightsProfile_stringQuantity_failsNamingCountsUnqualified" 200 \
    "$(insights_json '.[4].quantity = "5"')" "status 200" "$(profile_counts 15 14 0 14 14)" \
    "$ALL_BUT_FIFTH" 0
profile_rejected "insightsProfile_zeroQuantity_failsNamingCountsUnqualified" 200 \
    "$(insights_json '.[4].quantity = 0')" "status 200" "$(profile_counts 15 14 0 14 14)" \
    "$ALL_BUT_FIFTH" 0
profile_rejected "insightsProfile_negativeQuantity_failsNamingCountsUnqualified" 200 \
    "$(insights_json '.[4].quantity = -1')" "status 200" "$(profile_counts 15 14 0 14 14)" \
    "$ALL_BUT_FIFTH" 0
profile_rejected "insightsProfile_missingQuantity_failsNamingCountsUnqualified" 200 \
    "$(insights_json '.[4] |= del(.quantity)')" "status 200" "$(profile_counts 15 14 0 14 14)" \
    "$ALL_BUT_FIFTH" 0
profile_rejected "insightsProfile_nonCanonicalInstrumentId_failsNamingCountsButQualifies" 200 \
    "$(insights_json '.[4].instrumentId = "../../x"')" "status 200" \
    "$(profile_counts 15 15 1 14 14)" "$ALL_BUT_FIFTH" 1
profile_rejected "insightsProfile_missingInstrumentId_failsNamingCountsButQualifies" 200 \
    "$(insights_json '.[4] |= del(.instrumentId)')" "status 200" \
    "$(profile_counts 15 15 1 14 14)" "$ALL_BUT_FIFTH" 1
profile_rejected "insightsProfile_allocationNotAnObject_failsNamingCountsUnqualified" 200 \
    "$(insights_json '.[4] = 7')" "status 200" "$(profile_counts 15 14 1 14 14)" \
    "$ALL_BUT_FIFTH" 0
profile_rejected "insightsProfile_14Allocations_failsNamingCountsUnqualified" 200 \
    "$(insights_json '.[:14]')" "status 200" "$(profile_counts 14 14 0 14 14)" \
    "$(id_lines instrument 1 14)" 0
profile_rejected "insightsProfile_14DistinctInstruments_failsNamingCountsButQualifies" 200 \
    "$(insights_json '.[4].instrumentId = .[5].instrumentId')" "status 200" \
    "$(profile_counts 15 15 0 15 14)" "$ALL_BUT_FIFTH" 1
profile_rejected "insightsProfile_16Allocations_failsNamingCountsUnqualified" 200 \
    "$(insights_json '. + [.[0] | .instrumentId = instrument(16)]')" "status 200" \
    "$(profile_counts 16 16 0 16 16)" "$(id_lines instrument 1 16)" 0
profile_rejected "insightsProfile_twoEnvelopes_failsAsUnreadableWithEmptyHeldFile" 200 \
    "$INSIGHTS_OK$INSIGHTS_OK" "$UNREADABLE_PROFILE" "" "" 0
profile_rejected "insightsProfile_secondEnvelopeOnItsOwnLine_failsAsUnreadableWithEmptyHeldFile" \
    200 "$INSIGHTS_OK
{\"allocations\":[]}" "$UNREADABLE_PROFILE" "" "" 0
profile_rejected "insightsProfile_trailingText_failsAsUnreadableWithEmptyHeldFile" 200 \
    "$INSIGHTS_OK trailing" "$UNREADABLE_PROFILE" "" "" 0
profile_rejected "insightsProfile_nonJsonBody_failsAsUnreadableWithEmptyHeldFile" 200 \
    "<html>502 Bad Gateway</html>" "$UNREADABLE_PROFILE" "" "" 0
profile_rejected "insightsProfile_emptyBody_failsAsUnreadableWithEmptyHeldFile" 200 "" \
    "$UNREADABLE_PROFILE" "" "" 0
profile_rejected "insightsProfile_allocationsNotAnArray_failsAsUnreadableWithEmptyHeldFile" 200 \
    '{"allocations":null}' "$UNREADABLE_PROFILE" "" "" 0
profile_rejected "insightsProfile_status404_failsNamingStatusWithEmptyHeldFile" 404 \
    '{"error":"Account not found"}' "status 404" "" "" 0
profile_rejected "insightsProfile_status403_failsNamingStatusWithEmptyHeldFile" 403 \
    '{"error":"feature_disabled"}' "status 403" "" "" 0
profile_rejected "insightsProfile_transportError_failsNamingCurlErrorWithEmptyHeldFile" 000 "" \
    "transport error ($TRANSPORT_ERROR)" "" "" 0
profile_rejected "insightsProfile_parserWritesUncountedCanonicalId_failsNamingCounts" 200 \
    "$INSIGHTS_OK" \
    "status 200 with held instruments that do not match their counts: 16 id lines written, 0 of them not canonical UUIDs, 15 canonical ids counted" \
    "$(profile_counts 15 15 0 15 15)" "" 1 "$(instrument 16)"
profile_rejected "insightsProfile_parserWritesUncountedMalformedLine_failsNamingCounts" 200 \
    "$INSIGHTS_OK" \
    "status 200 with held instruments that do not match their counts: 16 id lines written, 1 of them not canonical UUIDs, 15 canonical ids counted" \
    "$(profile_counts 15 15 0 15 15)" "" 1 "not-a-uuid"
profile_refused "insightsProfile_pathTraversalAccount_refusedWithoutRequestOrFile" "../../evil"
profile_refused "insightsProfile_canonicalIdWithPathSuffix_refusedWithoutRequestOrFile" \
    "$(account 1)/../x"
profile_refused "insightsProfile_canonicalIdWithSecondLine_refusedWithoutRequestOrFile" \
    "$(account 1)
x"
profile_refused "insightsProfile_upperCaseAccount_refusedWithoutRequestOrFile" \
    "$(account 1 | tr '[:lower:]' '[:upper:]')"
profile_refused "insightsProfile_emptyAccount_refusedWithoutRequestOrFile" ""

# ---------------------------------------------------------------------------------------------
# verify_cycle_inputs

listing_counts() {
    echo "$1 results, $2 without a canonical UUID id, $3 duplicate ids, $4 held instruments not listed, $5 listed instruments not held"
}

SHORTFALL_PREFIX="every preset must hold and list the same 15 instruments:"

# verify_accepted CHECK COUNT LISTING: with COUNT presets (25 read by fetch_presets, otherwise
# three) and account 2's listing answered LISTING, verify_cycle_inputs succeeds after one
# insights and one listing GET per preset, in order.
verify_accepted() {
    local rc=0 k expected_requests=""
    reset_state
    if [[ $2 -eq 25 ]]; then
        use_valid_presets
    else
        use_three_presets
    fi
    stub_reply GET "$LISTING_URL$(account 2)" 200 "$3"
    verify_cycle_inputs || rc=$?
    for ((k = 1; k <= $2; k++)); do
        expected_requests="$expected_requests${expected_requests:+$'\n'}GET $INSIGHTS_URL/$(account "$k")"
        expected_requests="$expected_requests"$'\n'"GET $LISTING_URL$(account "$k")"
    done
    expect_eq "exit status" "$rc" 0
    expect_eq "INPUTS_ERROR" "$INPUTS_ERROR" ""
    expect_eq "INPUT_IDS" "$(printf '%s\n' "${INPUT_IDS[@]}")" "$(id_lines account 1 "$2")"
    expect_eq "INPUT_QUALIFIES" "${INPUT_QUALIFIES[*]}" "$(words 1 "$2")"
    expect_eq "requests" "$(cat "$test_dir/requests")" "$expected_requests"
    conclude "$1"
}

# verify_rejected CHECK INSIGHTS_STATUS INSIGHTS LISTING_STATUS LISTING QUALIFIES SHORTFALL:
# with three presets and account 2 answered as given, verify_cycle_inputs fails naming only
# account 2's SHORTFALL, and records QUALIFIES as its INPUT_QUALIFIES.
verify_rejected() {
    local rc=0
    reset_state
    use_three_presets
    stub_reply GET "$INSIGHTS_URL/$(account 2)" "$2" "$3"
    stub_reply GET "$LISTING_URL$(account 2)" "$4" "$5"
    verify_cycle_inputs || rc=$?
    expect_eq "exit status" "$rc" 1
    expect_eq "INPUTS_ERROR" "$INPUTS_ERROR" "$SHORTFALL_PREFIX [$(account 2)] $7;"
    expect_eq "INPUT_QUALIFIES" "${INPUT_QUALIFIES[*]}" "1 $6 1"
    conclude "$1"
}

# listing_rejected CHECK STATUS BODY LISTING: account 2's listing answered STATUS and BODY is
# the only shortfall, named as LISTING, and account 2 still qualifies for the p95.
listing_rejected() {
    verify_rejected "$1" 200 "$INSIGHTS_OK" "$2" "$3" 1 "instrument listing $4"
}

# preset_refused CHECK ID: a presets file whose second id is ID makes verify_cycle_inputs
# refuse it by name, with no request or held file for it, and verify the other two with two
# GETs each.
preset_refused() {
    local rc=0
    reset_state
    PRESETS_ERROR=""
    {
        account 1
        printf '\n%s\n' "$2"
        account 3
        echo
    } >"$RUN_DIR/presets"
    verify_cycle_inputs || rc=$?
    expect_eq "exit status" "$rc" 1
    expect_eq "INPUTS_ERROR" "$INPUTS_ERROR" "$SHORTFALL_PREFIX [$2] refused: the account id is not a canonical UUID, so neither its insights nor its instrument listing is requested;"
    expect_eq "INPUT_QUALIFIES" "${INPUT_QUALIFIES[*]}" "1 0 1"
    expect_eq "requests naming the id" "$(grep -cF -- "$2" "$test_dir/requests" || true)" 0
    expect_eq "requests" "$(request_count)" 4
    expect_eq "held files" "$(held_files)" 2
    conclude "$1"
}

verify_accepted "verifyCycleInputs_everyListingEqualsHeldSet_succeedsWithTwoRequestsPerPreset" 25 \
    "$LISTING_OK"
verify_accepted "verifyCycleInputs_listingInOtherOrderAndCase_succeeds" 3 \
    "$(listing_json 'reverse | map(.id |= ascii_upcase)')"
listing_rejected "verifyCycleInputs_listingOfAnotherSet_failsNamingCounts" 200 \
    "$(listing_json '.[4].id = instrument(99)')" "$(listing_counts 15 0 0 1 1)"
listing_rejected "verifyCycleInputs_listingWithDuplicateId_failsNamingCounts" 200 \
    "$(listing_json '.[4].id = .[5].id')" "$(listing_counts 15 0 1 1 0)"
listing_rejected "verifyCycleInputs_listingOf14Ids_failsNamingCounts" 200 "$(listing_json '.[:14]')" \
    "$(listing_counts 14 0 0 1 0)"
listing_rejected "verifyCycleInputs_listingOf16Ids_failsNamingCounts" 200 \
    "$(listing_json '. + [{id: instrument(16)}]')" "$(listing_counts 16 0 0 0 1)"
listing_rejected "verifyCycleInputs_listingWithNonCanonicalId_failsNamingCounts" 200 \
    "$(listing_json '.[4].id = "../x"')" "$(listing_counts 15 1 0 1 0)"
listing_rejected "verifyCycleInputs_listingWithTwoEnvelopes_failsAsUnreadable" 200 \
    "$LISTING_OK$LISTING_OK" "status 200 with $unreadable"
listing_rejected "verifyCycleInputs_listingWithTrailingText_failsAsUnreadable" 200 "$LISTING_OK x" \
    "status 200 with $unreadable"
listing_rejected "verifyCycleInputs_listingStatus503_failsNamingStatus" 503 "" "status 503"
verify_rejected "verifyCycleInputs_insightsShortfallAndListingMismatch_namesBoth" 200 \
    "$(insights_json '.[4].quantity = "5"')" 200 "$LISTING_OK" 0 \
    "insights status 200, $(profile_counts 15 14 0 14 14), instrument listing $(listing_counts 15 0 0 0 1)"
verify_rejected "verifyCycleInputs_insightsStatus503_namesStatusAndUnheldListing" 503 "" 200 \
    "$LISTING_OK" 0 "insights status 503, instrument listing $(listing_counts 15 0 0 0 15)"
verify_rejected "verifyCycleInputs_nonCanonicalInstrumentId_qualifiesButFailsNamingCounts" 200 \
    "$(insights_json '.[4].instrumentId = "../../x"')" 200 "$LISTING_OK" 1 \
    "insights status 200, $(profile_counts 15 15 1 14 14), instrument listing $(listing_counts 15 0 0 0 1)"
verify_rejected "verifyCycleInputs_repeatedInstrumentId_qualifiesButFailsNamingCounts" 200 \
    "$(insights_json '.[4].instrumentId = .[5].instrumentId')" 200 "$LISTING_OK" 1 \
    "insights status 200, $(profile_counts 15 15 0 15 14), instrument listing $(listing_counts 15 0 0 0 1)"
preset_refused "verifyCycleInputs_pathTraversalPreset_refusedWithoutRequest" "../../evil"
preset_refused "verifyCycleInputs_nonHexPreset_refusedWithoutRequest" \
    "a0000000-0000-4000-8000-00000000000g"
preset_refused "verifyCycleInputs_upperCasePreset_refusedWithoutRequest" \
    "$(account 2 | tr '[:lower:]' '[:upper:]')"
preset_refused "verifyCycleInputs_pathPreset_refusedWithoutRequest" "x/../y"

# verify_after_presets CHECK STATUS BODY INSIGHTS INPUTS_ERROR QUALIFIES REQUESTS:
# fetch_presets answered STATUS and BODY, which are not 25 distinct canonical presets, and
# account 2's insights answered INSIGHTS. verify_cycle_inputs still profiles every preset id
# fetch_presets kept, with REQUESTS GETs in all, records QUALIFIES as their INPUT_QUALIFIES,
# and fails naming INPUTS_ERROR: PRESETS_ERROR, then any account's shortfall.
verify_after_presets() {
    local rc=0
    reset_state
    stub_reply GET "$PRESETS_URL" "$2" "$3"
    stub_reply GET "$INSIGHTS_URL/$(account 2)" 200 "$4"
    fetch_presets || true
    : >"$test_dir/requests"
    verify_cycle_inputs || rc=$?
    expect_eq "exit status" "$rc" 1
    expect_eq "INPUTS_ERROR" "$INPUTS_ERROR" "$5"
    expect_eq "INPUT_QUALIFIES" "${INPUT_QUALIFIES[*]}" "$6"
    expect_eq "requests" "$(request_count)" "$7"
    conclude "$1"
}

verify_after_presets "verifyCycleInputs_presetsStatus503_failsWithPresetsErrorAndNoRequest" 503 \
    "" "$INSIGHTS_OK" \
    "GET presets gave status 503; exactly 25 distinct canonical account ids are needed" "" 0
verify_after_presets "verifyCycleInputs_threePresets_profilesEachAndFailsNamingPresetCounts" 200 \
    "$(presets_json 3)" "$INSIGHTS_OK" "$(presets_counts 3 0 0)" "1 1 1" 6
verify_after_presets "verifyCycleInputs_duplicatedPreset_profilesItOnceAndFailsNamingPresetCounts" \
    200 "$(presets_json 3 '. + [.[0]]')" "$INSIGHTS_OK" "$(presets_counts 4 0 1)" "1 1 1" 6
verify_after_presets "verifyCycleInputs_threePresetsOneShort_failsNamingPresetCountsAndShortfall" \
    200 "$(presets_json 3)" "$(insights_json '.[4].quantity = 0')" \
    "$(presets_counts 3 0 0); $SHORTFALL_PREFIX [$(account 2)] insights status 200, $(profile_counts 15 14 0 14 14), instrument listing $(listing_counts 15 0 0 0 1);" \
    "1 0 1" 6

# ---------------------------------------------------------------------------------------------
# preflight_inputs and select_insights_account

# run_preflight: preflight_inputs with its output in $test_dir/preflight.out, then forgets its
# requests, so a later expectation sees only the requests made after it.
run_preflight() {
    local rc=0
    preflight_inputs >"$test_dir/preflight.out" 2>&1 || rc=$?
    expect_eq "preflight_inputs exit status" "$rc" 0
    : >"$test_dir/requests"
}

# select_fails CHECK SELECT_ERROR: select_insights_account fails naming SELECT_ERROR, selects
# nothing and makes no request.
select_fails() {
    local rc=0
    select_insights_account || rc=$?
    expect_eq "exit status" "$rc" 1
    expect_eq "SELECT_ERROR" "$SELECT_ERROR" "$2"
    expect_eq "SELECTED_ACCOUNT" "$SELECTED_ACCOUNT" ""
    expect_eq "requests" "$(request_count)" 0
    conclude "$1"
}

# select_succeeds CHECK ACCOUNT: select_insights_account selects ACCOUNT with no request.
select_succeeds() {
    local rc=0
    select_insights_account || rc=$?
    expect_eq "exit status" "$rc" 0
    expect_eq "SELECTED_ACCOUNT" "$SELECTED_ACCOUNT" "$2"
    expect_eq "SELECT_ERROR" "$SELECT_ERROR" ""
    expect_eq "requests" "$(request_count)" 0
    conclude "$1"
}

check="preflightInputs_everyPresetVerified_printsPassAndSetsVerified"
reset_state
use_valid_presets
run_preflight
expect_eq "output" "$(cat "$test_dir/preflight.out")" "PASS cycle inputs"
expect_eq "INPUTS_VERIFIED" "$INPUTS_VERIFIED" 1
conclude "$check"

select_succeeds "selectInsightsAccount_firstPresetVerified_selectsItWithoutRequest" "$(account 1)"

check="preflightInputs_listingShortfall_printsFailAndLeavesUnverified"
reset_state
use_three_presets
stub_reply GET "$LISTING_URL$(account 2)" 200 "$(listing_json '.[:14]')"
run_preflight
expect_eq "output" "$(cat "$test_dir/preflight.out")" \
    "FAIL cycle inputs: $SHORTFALL_PREFIX [$(account 2)] instrument listing $(listing_counts 14 0 0 1 0);"
expect_eq "INPUTS_VERIFIED" "$INPUTS_VERIFIED" 0
conclude "$check"

check="preflightInputs_presetsError_printsFailWithoutRequest"
reset_state
stub_reply GET "$PRESETS_URL" 503 ""
fetch_presets || true
: >"$test_dir/requests"
preflight_rc=0
preflight_inputs >"$test_dir/preflight.out" 2>&1 || preflight_rc=$?
expect_eq "exit status" "$preflight_rc" 0
expect_eq "output" "$(cat "$test_dir/preflight.out")" "FAIL cycle inputs: $PRESETS_ERROR"
expect_eq "INPUTS_VERIFIED" "$INPUTS_VERIFIED" 0
expect_eq "requests" "$(request_count)" 0
conclude "$check"

select_fails "selectInsightsAccount_noPresetRead_failsWithPresetsError" "$PRESETS_ERROR"

check="selectInsightsAccount_noPresetRecordedWithoutPresetsError_failsNamingIt"
reset_state
PRESETS_ERROR=""
INPUTS_VERIFIED=0
INPUT_IDS=()
select_fails "$check" "no preset account id was read"

# A preset list short of 25, its first preset without 15 positive allocations: the cycle
# inputs fail on both, and the p95 account is still the first preset that qualifies.
check="preflightInputs_shortPresetList_printsFailNamingShortfallAndLeavesUnverified"
reset_state
stub_reply GET "$PRESETS_URL" 200 "$(presets_json 3)"
stub_reply GET "$INSIGHTS_URL/$(account 1)" 200 "$(insights_json '.[0].quantity = 0')"
fetch_presets || true
run_preflight
expect_eq "output" "$(cat "$test_dir/preflight.out")" \
    "FAIL cycle inputs: $(presets_counts 3 0 0); $SHORTFALL_PREFIX [$(account 1)] insights status 200, $(profile_counts 15 14 0 14 14), instrument listing $(listing_counts 15 0 0 0 1);"
expect_eq "INPUTS_VERIFIED" "$INPUTS_VERIFIED" 0
conclude "$check"

select_succeeds "selectInsightsAccount_shortPresetList_selectsFirstQualifyingPreset" "$(account 2)"

reset_state
use_three_presets
stub_reply GET "$INSIGHTS_URL/$(account 1)" 200 "$(insights_json '.[0].quantity = "5"')"
stub_reply GET "$INSIGHTS_URL/$(account 2)" 404 '{"error":"Account not found"}'
run_preflight
select_succeeds "selectInsightsAccount_earlierPresetsFailInsights_selectsFirstQualifyingPreset" \
    "$(account 3)"

reset_state
use_three_presets
stub_reply GET "$INSIGHTS_URL/$(account 1)" 200 "$(insights_json '.[0].quantity = 0')"
stub_reply GET "$LISTING_URL$(account 2)" 200 "$(listing_json '.[:14]')"
run_preflight
expect_eq "INPUTS_VERIFIED" "$INPUTS_VERIFIED" 0
select_succeeds "selectInsightsAccount_firstQualifyingPresetListingShortfall_selectsIt" \
    "$(account 2)"

# One case per instrumentId the cycle workload cannot use: name | jq edit of account 1's
# allocations. Its 15 allocations each still hold a numeric quantity > 0, so it is the p95
# account while the cycle inputs fail on it.
while IFS='|' read -r check edit; do
    reset_state
    use_three_presets
    stub_reply GET "$INSIGHTS_URL/$(account 1)" 200 "$(insights_json "$edit")"
    run_preflight
    expect_eq "INPUTS_VERIFIED" "$INPUTS_VERIFIED" 0
    select_succeeds "$check" "$(account 1)"
done <<'EOF'
selectInsightsAccount_firstPresetNonCanonicalInstrumentId_selectsItWithInputsUnverified|.[4].instrumentId = "../../x"
selectInsightsAccount_firstPresetRepeatedInstrumentId_selectsItWithInputsUnverified|.[4].instrumentId = .[5].instrumentId
EOF

reset_state
use_three_presets
DEFAULT_INSIGHTS="$(insights_json '.[0].quantity = 0')"
run_preflight
no_preset_error="no preset account has exactly 15 allocations, each with a numeric quantity > 0:"
for ((k = 1; k <= 3; k++)); do
    no_preset_error="$no_preset_error [$(account "$k")] status 200, $(profile_counts 15 14 0 14 14);"
done
select_fails "selectInsightsAccount_noPresetQualifies_failsNamingEveryPresetsCounts" \
    "$no_preset_error"

# The record of a passed preflight stays in place, so only the missing marker can refuse.
reset_state
use_three_presets
run_preflight
unset INPUTS_VERIFIED
select_fails "selectInsightsAccount_beforePreflight_failsClosed" \
    "the preset inputs were not verified before the account was selected"

# ---------------------------------------------------------------------------------------------
# post_alert

# reset_alerts: empties perf.sh's owned and expected alert files and answers the POST with a
# created alert.
reset_alerts() {
    reset_state
    : >"$RUN_DIR/owned"
    : >"$RUN_DIR/expected"
    stub_reply POST "$ALERTS_URL" 201 "{\"id\":\"$ALERT_ID\",\"enabled\":true,\"armingRevision\":1}"
}

# post_body_sent CHECK ACCOUNT TYPE INSTRUMENT DIRECTION THRESHOLD BODY: post_alert sends
# exactly BODY in one POST.
post_body_sent() {
    local rc=0
    reset_alerts
    post_alert "$2" "$3" "$4" "$5" "$6" || rc=$?
    expect_eq "exit status" "$rc" 0
    expect_eq "requests" "$(cat "$test_dir/requests")" "POST $ALERTS_URL"
    expect_eq "request body" "$(cat "$test_dir/request-body")" "$7"
    conclude "$1"
}

# post_token_refused CHECK THRESHOLD: post_alert refuses THRESHOLD before any request.
post_token_refused() {
    local rc=0
    reset_alerts
    post_alert "$(account 1)" TARGET_PRICE "$(instrument 1)" ABOVE "$2" || rc=$?
    expect_eq "exit status" "$rc" 1
    expect_eq "CREATE_ERROR" "${CREATE_ERROR-unset}" "threshold [$2] is not a plain decimal token"
    expect_eq "requests" "$(request_count)" 0
    expect_eq "owned file size" "$(file_size "$RUN_DIR/owned")" 0
    conclude "$1"
}

# post_answered CHECK STATUS BODY RC CREATE_ERROR OWNED EXPECTED: post_alert answered STATUS
# and BODY returns RC, names CREATE_ERROR on failure, and leaves OWNED and EXPECTED in the
# owned and expected files.
post_answered() {
    local rc=0
    reset_alerts
    stub_reply POST "$ALERTS_URL" "$2" "$3"
    CREATE_ERROR=""
    post_alert "$(account 1)" TARGET_PRICE "$(instrument 1)" ABOVE "$MAX_THRESHOLD" || rc=$?
    expect_eq "exit status" "$rc" "$4"
    expect_eq "CREATE_ERROR" "$CREATE_ERROR" "$5"
    expect_eq "owned file" "$(cat "$RUN_DIR/owned")" "$6"
    expect_eq "expected file" "$(cat "$RUN_DIR/expected")" "$7"
    conclude "$1"
}

# plain_body THRESHOLD: the body post_alert sends for account 1 and instrument 1.
plain_body() {
    printf '{"accountId":"%s","type":"TARGET_PRICE","instrumentId":"%s","direction":"ABOVE","threshold":%s}' \
        "$(account 1)" "$(instrument 1)" "$1"
}

post_body_sent "postAlert_quotesBackslashesControlCharactersInStrings_jsonEscapesThem" \
    'acc"1\x' "TYPE\\" $'inst\nrument\tx' 'ABOVE"' "1" \
    '{"accountId":"acc\"1\\x","type":"TYPE\\","instrumentId":"inst\nrument\tx","direction":"ABOVE\"","threshold":1}'
post_body_sent "postAlert_domainMaximum_appendsTheExactToken" "$(account 1)" TARGET_PRICE \
    "$(instrument 1)" ABOVE "$MAX_THRESHOLD" "$(plain_body 9999999999.99999999)"
post_body_sent "postAlert_trailingZeros_appendsTheTokenUnchanged" "$(account 1)" TARGET_PRICE \
    "$(instrument 1)" ABOVE "100.10000000" "$(plain_body 100.10000000)"
post_body_sent "postAlert_negativeFraction_appendsTheTokenUnchanged" "$(account 1)" TARGET_PRICE \
    "$(instrument 1)" ABOVE "-0.5" "$(plain_body -0.5)"
post_body_sent "postAlert_zero_appendsTheTokenUnchanged" "$(account 1)" TARGET_PRICE \
    "$(instrument 1)" ABOVE "0" "$(plain_body 0)"
post_token_refused "postAlert_exponentToken_refusedBeforeRequest" "1e5"
post_token_refused "postAlert_upperCaseExponentToken_refusedBeforeRequest" "1E5"
post_token_refused "postAlert_leadingZeroToken_refusedBeforeRequest" "01"
post_token_refused "postAlert_trailingDotToken_refusedBeforeRequest" "1."
post_token_refused "postAlert_leadingDotToken_refusedBeforeRequest" ".5"
post_token_refused "postAlert_plusSignToken_refusedBeforeRequest" "+1"
post_token_refused "postAlert_trailingSpaceToken_refusedBeforeRequest" "1.5 "
post_token_refused "postAlert_emptyToken_refusedBeforeRequest" ""
post_token_refused "postAlert_nanToken_refusedBeforeRequest" "NaN"
post_token_refused "postAlert_decimalCommaToken_refusedBeforeRequest" "1,5"
post_token_refused "postAlert_hexToken_refusedBeforeRequest" "0x10"
post_token_refused "postAlert_jsonFragmentToken_refusedBeforeRequest" '1,"accountId":"other"'
post_answered "postAlert_created201_recordsLowerCasedOwnedIdAndRevision" 201 \
    "{\"id\":\"$(tr '[:lower:]' '[:upper:]' <<<"$ALERT_ID")\",\"enabled\":true,\"armingRevision\":1}" 0 "" \
    "$ALERT_ID" "$ALERT_ID,1"
post_answered "postAlert_created201WithoutReadableId_failsOwningNothing" 201 \
    '{"enabled":true,"armingRevision":1}' 1 \
    "201 without a readable id; the alert may exist without an id this run knows; cleanup looks for it among the account's alerts" "" ""
post_answered "postAlert_created201WithoutRevision_recordsOwnedIdOnly" 201 \
    "{\"id\":\"$ALERT_ID\",\"enabled\":true}" 1 \
    "201 for alert [$ALERT_ID] whose armingRevision is not the JSON integer 1" "$ALERT_ID" ""
post_answered "postAlert_created201AtRevision2_recordsOwnedIdOnly" 201 \
    "{\"id\":\"$ALERT_ID\",\"enabled\":true,\"armingRevision\":2}" 1 \
    "201 for alert [$ALERT_ID] whose armingRevision is not the JSON integer 1" "$ALERT_ID" ""
post_answered "postAlert_created201WithoutEnabled_recordsOwnedIdOnly" 201 \
    "{\"id\":\"$ALERT_ID\",\"armingRevision\":1}" 1 \
    "201 for alert [$ALERT_ID] whose enabled is not the JSON boolean true" "$ALERT_ID" ""
post_answered "postAlert_created201EnabledAsString_recordsOwnedIdOnly" 201 \
    "{\"id\":\"$ALERT_ID\",\"enabled\":\"true\",\"armingRevision\":1}" 1 \
    "201 for alert [$ALERT_ID] whose enabled is not the JSON boolean true" "$ALERT_ID" ""
post_answered "postAlert_created201Disabled_recordsOwnedIdOnly" 201 \
    "{\"id\":\"$ALERT_ID\",\"enabled\":false,\"armingRevision\":1}" 1 \
    "201 for alert [$ALERT_ID] whose enabled is not the JSON boolean true" "$ALERT_ID" ""
post_answered "postAlert_rejected400_failsNamingStatus" 400 '{"error":"invalid_threshold"}' 1 \
    "status 400" "" ""
post_answered "postAlert_transportError_failsNamingPossiblyCreatedAlert" 000 "" 1 \
    "transport error ($TRANSPORT_ERROR); the alert may exist without an id this run knows; cleanup looks for it among the account's alerts" "" ""

# ---------------------------------------------------------------------------------------------
# Isolation

check="perfInputsSuite_everyCheck_callsNeitherDockerNorCurl"
expect_eq "unexpected docker and curl calls" "$(cat "$test_dir/unexpected")" ""
conclude "$check"

summarize
if [[ "$checks_failed" -ne 0 ]]; then
    exit 1
fi
