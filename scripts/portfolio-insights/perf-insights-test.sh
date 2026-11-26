#!/usr/bin/env bash
# Tests the insights p95 measurement of scripts/portfolio-insights/perf.sh:
#   - classify_insights_request: a request counts only for curl exit 0, status 200 and a
#     readable time_total;
#   - insights_p95: the p95 is the 190th sorted value of exactly 200 valid timings, and no p95
#     comes from any other sample;
#   - insights_trace and insights_trace_nonce: every request gets its own W3C traceparent;
#   - insights_trace_durations: the server share reads only the measured account's log lines
#     whose trace id belongs to a valid timed request;
#   - measure_insights end to end, with curl and broker_logs replaced by fakes and the account
#     chosen by perf.sh's own select_insights_account from the record preflight_inputs leaves:
#     any failed request or stray timing record fails the check without a p95, a p95 of 500 ms
#     or more fails it, a clean run passes on the 190th timing with a trace-matched server
#     share, which stays unreported when no log line matches, and a record that leaves no
#     qualifying account fails `insights p95 account` before any request.
# The functions and constants come from perf.sh itself, without running its main body: each
# column-0 definition and assignment the tests need is extracted and evaluated, so the code in
# this tree is the code tested. No docker and no running stack are needed.
#
# Usage: scripts/portfolio-insights/perf-insights-test.sh [--help]
#   --help  Show this help and exit
#
# Prints one PASS or FAIL line per check and a final SUMMARY line. Exits 0 when every check
# passes, 1 when any check fails or perf.sh cannot be loaded, and 2 on a usage error.
# The run's temporary files are removed on exit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERF_SH="$SCRIPT_DIR/perf.sh"

# The account measured in the end-to-end runs, another account, and a fixed run nonce.
ACCOUNT="5c2e1f0a-3b4d-4e6f-8a9b-0c1d2e3f4a5b"
OTHER_ACCOUNT="9d8c7b6a-5f4e-4d3c-8b2a-1f0e9d8c7b6a"
NONCE="0123456789abcdef"
# The insights status and counts verify_cycle_inputs records for a preset with 15 held
# instruments, and for one whose single zero quantity leaves 14 held.
QUALIFYING_INSIGHTS="status 200, 15 allocations, 15 with a numeric quantity > 0, 0 without a canonical instrumentId, 15 held on 15 distinct instruments"
UNHELD_INSIGHTS="status 200, 15 allocations, 14 with a numeric quantity > 0, 0 without a canonical instrumentId, 14 held on 14 distinct instruments"
W3C_TRACEPARENT_RE='^00-[0-9a-f]{32}-[0-9a-f]{16}-01$'

usage() {
    cat <<'EOF'
Usage: scripts/portfolio-insights/perf-insights-test.sh [--help]
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

passed=0
failed=0
work=""
reasons=()

# Set by the code loaded from perf.sh. Declared here, so a name the loaded code no longer sets
# shows up as a failed check rather than an unbound variable.
WARMUP_REQUESTS=""
TIMED_REQUESTS=""
REQUEST_SECONDS=""
REQUEST_PROBLEM=""
INSIGHTS_TRACE_ID=""
INSIGHTS_TRACEPARENT=""

# Steer the fakes below: request numbers that fail (space-padded list), the exit status and
# -w output they give, the time_total every timed request reports instead of its own, the
# request at which curl adds a stray line to the timing records, which insights log lines
# broker_logs prints, and whether awk fails inside measure_insights; and the preflight record
# of the measured account: INPUTS_VERIFIED (empty leaves it unset), INPUT_HELD and
# INPUT_INSIGHTS. By default it is the record of a passed preflight.
FAKE_FAIL_INDEXES=""
FAKE_FAIL_RC=0
FAKE_FAIL_OUT=""
FAKE_TIMED_SECONDS=""
FAKE_STRAY_RECORD_AT=0
FAKE_LOG_MODE="timed"
FAKE_AWK_FAILS=0
FAKE_INPUTS_VERIFIED=1
FAKE_INPUT_HELD=1
FAKE_INPUT_INSIGHTS="$QUALIFYING_INSIGHTS"

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

cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$work" ]]; then
        rm -rf "$work"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# load_function NAME: evaluates perf.sh's column-0 definition of NAME, from its "NAME() {" line
# to the first "}" line after it. Carriage returns are dropped, so a CRLF checkout loads too.
load_function() {
    local definition
    definition="$(awk -v start="$1() {" '{ sub(/\r$/, "") } $0 == start { found = 1 } found { print } found && $0 == "}" { exit }' "$PERF_SH")"
    if [[ -z "$definition" || "${definition##*$'\n'}" != "}" ]]; then
        abort "perfScript_load_definesTestedNames" "no column-0 definition of $1() in $PERF_SH"
    fi
    eval "$definition"
}

# load_constant NAME: evaluates perf.sh's one column-0 assignment of NAME.
load_constant() {
    local count line
    count="$(grep -c "^$1=" "$PERF_SH" || true)"
    if [[ "$count" != 1 ]]; then
        abort "perfScript_load_definesTestedNames" "$PERF_SH assigns $1 at column 0 $count times, expected once"
    fi
    line="$(grep "^$1=" "$PERF_SH" | tr -d '\r')"
    eval "$line"
}

expect_equal() {
    if [[ "$1" != "$2" ]]; then
        reasons+=("$3 is [$1], expected [$2]")
    fi
}

expect_line() {
    if ! grep -qxF -- "$2" "$1"; then
        reasons+=("$(basename "$1") has no line [$2]")
    fi
}

expect_no_text() {
    if grep -qF -- "$2" "$1"; then
        reasons+=("$(basename "$1") contains [$2]")
    fi
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

# The value a line NAME=VALUE of FILE gives NAME.
report_value() {
    sed -n "s/^$2=//p" "$1"
}

# Fake curl for measure_insights: reads the request number back from the parent id of the
# traceparent header it was sent, records the header, and prints the -w output of a 200 with a
# time that depends on the number. Warm-ups take 9 s; timed request k takes 2 to 400 ms, a
# permutation of k, so the 190th sorted value is 380 ms. FAKE_FAIL_INDEXES fail instead.
# At request FAKE_STRAY_RECORD_AT it appends a line that is no timing to the run's records.
# shellcheck disable=SC2317,SC2329 # Called by measure_insights, which is loaded from perf.sh.
curl() {
    local traceparent="" index k seconds
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "-H" && "${2:-}" == "traceparent: "* ]]; then
            traceparent="${2#traceparent: }"
        fi
        shift
    done
    if [[ ! "$traceparent" =~ $W3C_TRACEPARENT_RE ]]; then
        printf '000 0.000000'
        return 2
    fi
    echo "$traceparent" >>"$work/sent"
    index=$((16#${traceparent:36:16}))
    if [[ "$FAKE_FAIL_INDEXES" == *" $index "* ]]; then
        printf '%s' "$FAKE_FAIL_OUT"
        return "$FAKE_FAIL_RC"
    fi
    if [[ $index -le $WARMUP_REQUESTS ]]; then
        seconds="9.000000"
    elif [[ -n "$FAKE_TIMED_SECONDS" ]]; then
        seconds="$FAKE_TIMED_SECONDS"
    else
        k=$((index - WARMUP_REQUESTS))
        printf -v seconds '0.%06d' $((((k * 37) % 200 + 1) * 2 * 1000))
    fi
    if [[ $index -eq $FAKE_STRAY_RECORD_AT ]]; then
        echo "stray" >>"$RUN_DIR/insights-times"
    fi
    printf '200 %s' "$seconds"
}

# Fake broker_logs: one insights line per traceparent curl recorded, with durationMs 9000 for a
# warm-up and k for timed request k, plus the same trace ids under another account and lines of
# other events. With FAKE_LOG_MODE=unmatched only the other account's and trace-less lines appear.
# shellcheck disable=SC2317,SC2329 # Called by measure_insights, which is loaded from perf.sh.
broker_logs() {
    local traceparent trace index duration
    echo "Alert evaluation cycle finished: alerts [0] triggered [0] failed [0] skipped [0] outcome [completed] duration [3] ms | AlertEvaluationService"
    while IFS= read -r traceparent; do
        trace="${traceparent:3:32}"
        index=$((16#${traceparent:36:16}))
        duration=9000
        if [[ $index -gt $WARMUP_REQUESTS ]]; then
            duration=$((index - WARMUP_REQUESTS))
        fi
        if [[ "$FAKE_LOG_MODE" == "timed" ]]; then
            printf 'Portfolio insights for account [%s] holdings [15] value [1234.5] risk [MEDIUM] duration [%s] ms trace [%s]      | PortfolioInsightsService\n' \
                "$ACCOUNT" "$duration" "$trace"
        fi
        printf 'Portfolio insights for account [%s] holdings [15] value [99] risk [LOW] duration [7777] ms trace [%s]      | PortfolioInsightsService\n' \
            "$OTHER_ACCOUNT" "$trace"
    done <"$work/sent"
    printf 'Portfolio insights for account [%s] holdings [15] value [1234.5] risk [MEDIUM] duration [8888] ms trace []      | PortfolioInsightsService\n' \
        "$ACCOUNT"
}

# run_measure_insights NAME: runs measure_insights in a subshell, with set -e in force and
# perf.sh's reporting replaced by CHECK lines, and writes its output, its exit status and the
# report values to $work/NAME.out. The run directory and the recorded traceparents start empty.
# The preflight record holds the measured account alone, as the FAKE_INPUT* values set it,
# with the presets read and its instrument listing matched.
run_measure_insights() {
    local out="$work/$1.out" status
    rm -rf "$work/run"
    mkdir "$work/run"
    : >"$work/sent"
    set +e
    # shellcheck disable=SC2317,SC2329,SC2034 # The functions and values serve measure_insights.
    (
        set -e
        RUN_DIR="$work/run"
        INSIGHTS_URL="http://perf-insights-test.invalid/broker-service/v1/portfolio/insights"
        PRESETS_ERROR=""
        if [[ -n "$FAKE_INPUTS_VERIFIED" ]]; then
            INPUTS_VERIFIED="$FAKE_INPUTS_VERIFIED"
        else
            unset INPUTS_VERIFIED
        fi
        INPUT_IDS=("$ACCOUNT")
        INPUT_HELD=("$FAKE_INPUT_HELD")
        INPUT_INSIGHTS=("$FAKE_INPUT_INSIGHTS")
        INPUT_LISTING=("")
        pass() { echo "CHECK PASS $1"; }
        fail() { echo "CHECK FAIL $1: $2"; }
        info() { echo "CHECK INFO $*"; }
        if [[ $FAKE_AWK_FAILS -eq 1 ]]; then
            awk() { return 2; }
        fi
        measure_insights
        echo "R_INSIGHTS_ACCOUNT=$R_INSIGHTS_ACCOUNT"
        echo "R_INSIGHTS_P95=$R_INSIGHTS_P95"
        echo "R_INSIGHTS_VERDICT=$R_INSIGHTS_VERDICT"
        echo "R_SERVER_SHARE=$R_SERVER_SHARE"
    ) >"$out" 2>&1
    status=$?
    set -e
    echo "EXIT=$status" >>"$out"
}

# timings_file FILE: 200 distinct timings from 0.060 to 12.000 s in shuffled order, so the 190th
# sorted value is 11.400 and a text sort would misplace every value of 10 s or more.
timings_file() {
    local k ms
    : >"$1"
    for ((k = 1; k <= 200; k++)); do
        ms=$((((k * 37) % 200 + 1) * 60))
        printf '%d.%03d\n' $((ms / 1000)) $((ms % 1000)) >>"$1"
    done
}

work="$(mktemp -d -t perf-insights-test.XXXXXX)"

if [[ ! -f "$PERF_SH" ]]; then
    abort "perfScript_load_definesTestedNames" "$PERF_SH not found"
fi
for name in HOLDINGS_EXPECTED HTTP_TIMEOUT_SECONDS LOG_SKEW_MARGIN_SECONDS WARMUP_REQUESTS \
    TIMED_REQUESTS INSIGHTS_P95_RANK TIME_TOTAL_RE TRACE_NONCE_RE INSIGHTS_REASONS_SHOWN \
    INSIGHTS_LIMIT_SECONDS INSIGHTS_TRACE_RE R_INSIGHTS_ACCOUNT R_INSIGHTS_P95 \
    R_INSIGHTS_VERDICT R_SERVER_SHARE; do
    load_constant "$name"
done
for name in dec_to_units units_to_dec seconds_to_ms nearest_rank epoch_to_rfc3339 \
    insights_trace_nonce insights_trace classify_insights_request insights_p95 \
    insights_trace_durations select_insights_account measure_insights; do
    load_function "$name"
done
check="perfScript_load_definesTestedNames"
expect_equal "$WARMUP_REQUESTS" 10 "WARMUP_REQUESTS"
expect_equal "$TIMED_REQUESTS" 200 "TIMED_REQUESTS"
expect_equal "$INSIGHTS_P95_RANK" 190 "INSIGHTS_P95_RANK"
conclude "$check"
total=$((WARMUP_REQUESTS + TIMED_REQUESTS))

# classify_insights_request: name | curl exit | -w output | outcome | reason, or time for a sample.
while IFS='|' read -r check rc out outcome detail; do
    if classify_insights_request "$rc" "$out"; then
        expect_equal "sample" "$outcome" "outcome"
        expect_equal "$REQUEST_SECONDS" "$detail" "REQUEST_SECONDS"
    else
        expect_equal "failure" "$outcome" "outcome"
        expect_equal "$REQUEST_PROBLEM" "$detail" "REQUEST_PROBLEM"
    fi
    conclude "$check"
done <<'EOF'
classifyInsightsRequest_curlExit28WithStatus200_isFailure|28|200 15.000123|failure|transport error (curl exit 28, status 200)
classifyInsightsRequest_curlExit18WithStatus200_isFailure|18|200 0.120000|failure|transport error (curl exit 18, status 200)
classifyInsightsRequest_curlExit23WithStatus200_isFailure|23|200 0.120000|failure|transport error (curl exit 23, status 200)
classifyInsightsRequest_curlExit7WithoutResponse_isFailure|7|000 0.001000|failure|transport error (curl exit 7, status 000)
classifyInsightsRequest_curlFailedWithoutOutput_isFailure|6||failure|transport error (curl exit 6, status none)
classifyInsightsRequest_status503_isFailure|0|503 0.010000|failure|status 503
classifyInsightsRequest_missingTimeTotal_isFailure|0|200|failure|unreadable time_total []
classifyInsightsRequest_emptyTimeTotal_isFailure|0|200 |failure|unreadable time_total []
classifyInsightsRequest_nonNumericTimeTotal_isFailure|0|200 n/a|failure|unreadable time_total [n/a]
classifyInsightsRequest_commaDecimalTimeTotal_isFailure|0|200 0,120000|failure|unreadable time_total [0,120000]
classifyInsightsRequest_completeTransfer_isSample|0|200 0.123456|sample|0.123456
classifyInsightsRequest_wholeSecondTimeTotal_isSample|0|200 1|sample|1
EOF

# insights_p95 on exactly 200 valid timings.
check="insightsP95_exactly200KnownTimings_returns190thSortedValue"
timings_file "$work/times"
p95_status=0
p95="$(insights_p95 "$work/times")" || p95_status=$?
expect_equal "$p95_status" 0 "exit status"
expect_equal "$p95" "11.400" "p95"
conclude "$check"

# insights_p95 refuses every other sample: name | how the 200 timings are changed.
while IFS='|' read -r check change; do
    timings_file "$work/times"
    case "$change" in
        drop-one) sed -i '$d' "$work/times" ;;
        add-one) echo "0.001" >>"$work/times" ;;
        unreadable) sed -i '57s/.*/abc/' "$work/times" ;;
        empty-line) sed -i '57s/.*//' "$work/times" ;;
        no-final-newline) printf '%s' "$(cat "$work/times")" >"$work/times.new" && mv "$work/times.new" "$work/times" ;;
        missing) rm -f "$work/times" ;;
    esac
    p95_status=0
    p95="$(insights_p95 "$work/times")" || p95_status=$?
    if [[ $p95_status -eq 0 ]]; then
        reasons+=("exit status 0, expected a refusal")
    fi
    expect_equal "$p95" "" "printed p95"
    conclude "$check"
done <<'EOF'
insightsP95_199Timings_isRefused|drop-one
insightsP95_201Timings_isRefused|add-one
insightsP95_unreadableTiming_isRefused|unreadable
insightsP95_emptyLine_isRefused|empty-line
insightsP95_unterminatedLastTiming_isRefused|no-final-newline
insightsP95_missingFile_isRefused|missing
EOF

check="insightsTrace_firstRequest_buildsW3cTraceparent"
INSIGHTS_TRACE_ID=""
INSIGHTS_TRACEPARENT=""
if ! insights_trace "$NONCE" 1; then
    reasons+=("insights_trace $NONCE 1 failed")
fi
expect_equal "$INSIGHTS_TRACE_ID" "${NONCE}0000000000000001" "INSIGHTS_TRACE_ID"
expect_equal "$INSIGHTS_TRACEPARENT" "00-${NONCE}0000000000000001-0000000000000001-01" "INSIGHTS_TRACEPARENT"
conclude "$check"

# Every request of a run, warm-ups included: a well-formed header whose trace id is the one
# recorded for the request and whose parent id is not the invalid all-zero value.
check="insightsTrace_everyRequestOfARun_isWellFormedW3c"
: >"$work/trace-ids"
for ((i = 1; i <= total; i++)); do
    if ! insights_trace "$NONCE" "$i"; then
        reasons+=("insights_trace $NONCE $i failed")
    elif [[ ! "$INSIGHTS_TRACEPARENT" =~ $W3C_TRACEPARENT_RE ||
        "${INSIGHTS_TRACEPARENT:3:32}" != "$INSIGHTS_TRACE_ID" ||
        "${INSIGHTS_TRACEPARENT:36:16}" == "0000000000000000" ]]; then
        reasons+=("request $i: traceparent [$INSIGHTS_TRACEPARENT] with trace id [$INSIGHTS_TRACE_ID]")
    fi
    echo "$INSIGHTS_TRACE_ID" >>"$work/trace-ids"
done
conclude "$check"

check="insightsTrace_everyRequestOfARun_hasUniqueTraceId"
expect_equal "$(LC_ALL=C sort -u "$work/trace-ids" | wc -l | tr -d ' ')" "$total" "distinct trace ids"
conclude "$check"

# insights_trace refuses input that cannot make a valid trace context: name | nonce | index.
while IFS='|' read -r check nonce index; do
    if insights_trace "$nonce" "$index"; then
        reasons+=("insights_trace [$nonce] [$index] succeeded with [$INSIGHTS_TRACEPARENT]")
    fi
    conclude "$check"
done <<'EOF'
insightsTrace_indexZero_isRefused|0123456789abcdef|0
insightsTrace_negativeIndex_isRefused|0123456789abcdef|-1
insightsTrace_octalLookingIndex_isRefused|0123456789abcdef|010
insightsTrace_nonNumericIndex_isRefused|0123456789abcdef|abc
insightsTrace_shortNonce_isRefused|0123456789abcde|1
insightsTrace_upperCaseNonce_isRefused|0123456789ABCDEF|1
EOF

check="insightsTraceNonce_urandomReadable_returnsSixteenHexDigits"
nonce="$(insights_trace_nonce)"
if [[ ! "$nonce" =~ ^[0-9a-f]{16}$ ]]; then
    reasons+=("nonce [$nonce] is not 16 lowercase hex digits")
fi
conclude "$check"

check="insightsTraceNonce_urandomUnreadable_fallsBackToSixteenHexDigits"
# shellcheck disable=SC2317,SC2329 # od is called by insights_trace_nonce.
nonce="$(
    od() { return 1; }
    insights_trace_nonce
)"
if [[ ! "$nonce" =~ ^[0-9a-f]{16}$ ]]; then
    reasons+=("nonce [$nonce] is not 16 lowercase hex digits")
fi
conclude "$check"

# insights_trace_durations: two timed lines (12 ms, 7 ms) for listed trace ids T1 and T2, T3
# listed without a line of its own, plus one more line per case: name | extra line | durations.
T1="${NONCE}00000000000000a1"
T2="${NONCE}00000000000000a2"
T3="${NONCE}00000000000000a3"
printf '%s\n' "$T1" "$T2" "$T3" >"$work/traces"
insights_line() {
    printf 'Portfolio insights for account [%s] holdings [15] value [1234.5] risk [MEDIUM] duration [%s] ms trace [%s]      | PortfolioInsightsService' "$1" "$2" "$3"
}
while IFS='|' read -r check extra expected; do
    {
        echo "Alert created [x] for account [$ACCOUNT] | AlertService"
        insights_line "$ACCOUNT" 12 "$T1"
        echo
        insights_line "$ACCOUNT" 7 "$T2"
        echo
        case "$extra" in
            warm-up) insights_line "$ACCOUNT" 9000 "${NONCE}0000000000000001" ;;
            other-account) insights_line "$OTHER_ACCOUNT" 8000 "$T3" ;;
            no-trace) insights_line "$ACCOUNT" 6000 "" ;;
            repeated) insights_line "$ACCOUNT" 5000 "$T1" ;;
            decimal) insights_line "$ACCOUNT" 3.5 "$T3" ;;
        esac
        echo
    } >"$work/insights.log"
    durations="$(insights_trace_durations "$ACCOUNT" "$work/insights.log" "$work/traces" | paste -sd, -)"
    expect_equal "$durations" "$expected" "durations"
    conclude "$check"
done <<'EOF'
insightsTraceDurations_timedTraceLines_returnsDurationsInLogOrder|none|12,7
insightsTraceDurations_warmUpTraceLine_isIgnored|warm-up|12,7
insightsTraceDurations_otherAccountLine_isIgnored|other-account|12,7
insightsTraceDurations_lineWithoutTraceId_isIgnored|no-trace|12,7
insightsTraceDurations_repeatedTraceId_countsOnce|repeated|12,7
insightsTraceDurations_decimalDuration_isKept|decimal|12,7,3.5
EOF

check="insightsTraceDurations_noTimedTraceIds_returnsNothing"
: >"$work/no-traces"
durations="$(insights_trace_durations "$ACCOUNT" "$work/insights.log" "$work/no-traces")"
expect_equal "$durations" "" "durations"
conclude "$check"

# measure_insights end to end, every request valid.
FAKE_FAIL_INDEXES=""
FAKE_LOG_MODE="timed"
run_measure_insights clean
clean="$work/clean.out"

check="measureInsights_allRequestsValid_passesOn190thTiming"
expect_line "$clean" "EXIT=0"
expect_line "$clean" "CHECK PASS insights p95 < 500 ms"
expect_line "$clean" "CHECK INFO insights p95 380 ms: the 190th of 200 sorted curl time_total values through the reverse proxy"
expect_equal "$(report_value "$clean" R_INSIGHTS_P95)" "380 ms" "R_INSIGHTS_P95"
expect_equal "$(report_value "$clean" R_INSIGHTS_VERDICT)" "PASS" "R_INSIGHTS_VERDICT"
conclude "$check"

check="measureInsights_allRequestsValid_serverShareMatchesTimedTraceIds"
expect_equal "$(report_value "$clean" R_SERVER_SHARE)" \
    "median 100 ms, p95 190 ms over 200 of 200 timed requests, matched by trace id" "R_SERVER_SHARE"
conclude "$check"

check="measureInsights_everyRequest_sendsItsOwnTraceparent"
expect_equal "$(wc -l <"$work/sent" | tr -d ' ')" "$total" "requests sent"
expect_equal "$(LC_ALL=C sort -u "$work/sent" | wc -l | tr -d ' ')" "$total" "distinct traceparents"
conclude "$check"

# measure_insights with failed requests: name | failing requests | curl exit | -w output |
# the failure list of the FAIL line.
while IFS='|' read -r check indexes rc out failures; do
    FAKE_FAIL_INDEXES=" $indexes "
    FAKE_FAIL_RC="$rc"
    FAKE_FAIL_OUT="$out"
    run_measure_insights failed
    expect_line "$work/failed.out" "EXIT=0"
    expect_line "$work/failed.out" "CHECK FAIL insights p95 < 500 ms: $failures (curl messages in $work/run/curl-error.log)"
    expect_no_text "$work/failed.out" "CHECK PASS insights p95 < 500 ms"
    expect_no_text "$work/failed.out" "CHECK INFO insights p95 "
    expect_equal "$(report_value "$work/failed.out" R_INSIGHTS_P95)" "n/a" "R_INSIGHTS_P95"
    expect_equal "$(report_value "$work/failed.out" R_INSIGHTS_VERDICT)" "FAIL" "R_INSIGHTS_VERDICT"
    conclude "$check"
    cp "$work/failed.out" "$work/failed-$rc-${indexes// /-}.out"
done <<'EOF'
measureInsights_curlExit28WithStatus200_failsWithoutP95|57|28|200 15.001234|1 of 210 requests failed, so no p95 is computed: request 57: transport error (curl exit 28, status 200)
measureInsights_warmUpStatus503_failsWithoutP95|3|0|503 0.010000|1 of 210 requests failed, so no p95 is computed: request 3: status 503
measureInsights_unreadableTimeTotal_failsWithoutP95|12|0|200 |1 of 210 requests failed, so no p95 is computed: request 12: unreadable time_total []
measureInsights_sevenFailedRequests_namesFirstFiveAndCountsAll|20 30 40 50 60 70 80|0|502 0.010000|7 of 210 requests failed, so no p95 is computed: request 20: status 502; request 30: status 502; request 40: status 502; request 50: status 502; request 60: status 502; and 2 more
EOF

# Request 57 is timed request 47: its duration leaves the server share, and the other 199 stay.
check="measureInsights_failedTimedRequest_serverShareCountsOnlyValidTimedRequests"
failed57="$work/failed-28-57.out"
expect_equal "$(report_value "$failed57" R_SERVER_SHARE)" \
    "median 101 ms, p95 191 ms over 199 of 200 timed requests, matched by trace id" "R_SERVER_SHARE"
expect_line "$failed57" "CHECK INFO insights server share: 1 of 200 timed requests are left out, as failed requests or without a log line carrying their trace id"
conclude "$check"

check="measureInsights_noTraceMatchedLogLine_leavesServerShareUnreported"
FAKE_FAIL_INDEXES=""
FAKE_LOG_MODE="unmatched"
run_measure_insights unmatched
expect_line "$work/unmatched.out" "EXIT=0"
expect_line "$work/unmatched.out" "CHECK PASS insights p95 < 500 ms"
expect_line "$work/unmatched.out" "CHECK INFO insights server share: no insights log line of account [$ACCOUNT] carries the trace id of a valid timed request"
expect_equal "$(report_value "$work/unmatched.out" R_SERVER_SHARE)" "n/a" "R_SERVER_SHARE"
conclude "$check"
FAKE_LOG_MODE="timed"

check="measureInsights_traceMatchingFails_leavesServerShareUnreported"
FAKE_AWK_FAILS=1
run_measure_insights awk-fails
FAKE_AWK_FAILS=0
expect_line "$work/awk-fails.out" "EXIT=0"
expect_line "$work/awk-fails.out" "CHECK PASS insights p95 < 500 ms"
expect_line "$work/awk-fails.out" "CHECK INFO insights server share: the insights log lines could not be matched to the timed trace ids"
expect_equal "$(report_value "$work/awk-fails.out" R_SERVER_SHARE)" "n/a" "R_SERVER_SHARE"
conclude "$check"

check="measureInsights_strayTimingRecord_failsWithoutP95"
FAKE_STRAY_RECORD_AT=100
run_measure_insights stray
FAKE_STRAY_RECORD_AT=0
expect_line "$work/stray.out" "EXIT=0"
expect_line "$work/stray.out" "CHECK FAIL insights p95 < 500 ms: 201 timing records were kept instead of exactly 200 valid ones, so no p95 is computed"
expect_equal "$(report_value "$work/stray.out" R_INSIGHTS_P95)" "n/a" "R_INSIGHTS_P95"
expect_equal "$(report_value "$work/stray.out" R_INSIGHTS_VERDICT)" "FAIL" "R_INSIGHTS_VERDICT"
conclude "$check"

check="measureInsights_p95BeyondComparableRange_failsWithoutP95"
FAKE_TIMED_SECONDS="12345678901.5"
run_measure_insights huge
FAKE_TIMED_SECONDS=""
expect_line "$work/huge.out" "EXIT=0"
expect_line "$work/huge.out" "CHECK FAIL insights p95 < 500 ms: the 190th sorted timing [12345678901.5] is beyond the comparable range"
expect_equal "$(report_value "$work/huge.out" R_INSIGHTS_P95)" "n/a" "R_INSIGHTS_P95"
expect_equal "$(report_value "$work/huge.out" R_INSIGHTS_VERDICT)" "FAIL" "R_INSIGHTS_VERDICT"
conclude "$check"

check="measureInsights_p95NotBelowLimit_failsWithP95"
FAKE_TIMED_SECONDS="0.5"
run_measure_insights at-limit
FAKE_TIMED_SECONDS=""
expect_line "$work/at-limit.out" "EXIT=0"
expect_line "$work/at-limit.out" "CHECK FAIL insights p95 < 500 ms: p95 500 ms is not below 500 ms"
expect_equal "$(report_value "$work/at-limit.out" R_INSIGHTS_P95)" "500 ms" "R_INSIGHTS_P95"
expect_equal "$(report_value "$work/at-limit.out" R_INSIGHTS_VERDICT)" "FAIL" "R_INSIGHTS_VERDICT"
conclude "$check"

# measure_insights when the preflight record leaves no qualifying account: name | the measured
# account's INPUTS_VERIFIED (empty leaves it unset) | INPUT_HELD | INPUT_INSIGHTS | the
# SELECT_ERROR of select_insights_account. The account check fails with it before any request,
# and every report value stays at its default.
while IFS='|' read -r check verified held insights select_error; do
    FAKE_INPUTS_VERIFIED="$verified"
    FAKE_INPUT_HELD="$held"
    FAKE_INPUT_INSIGHTS="$insights"
    run_measure_insights unqualified
    unqualified="$work/unqualified.out"
    expect_line "$unqualified" "EXIT=0"
    expect_line "$unqualified" "CHECK FAIL insights p95 account: $select_error"
    expect_no_text "$unqualified" "CHECK PASS"
    expect_no_text "$unqualified" "CHECK INFO"
    expect_equal "$(wc -l <"$work/sent" | tr -d ' ')" 0 "requests sent"
    expect_equal "$(report_value "$unqualified" R_INSIGHTS_ACCOUNT)" "n/a" "R_INSIGHTS_ACCOUNT"
    expect_equal "$(report_value "$unqualified" R_INSIGHTS_P95)" "n/a" "R_INSIGHTS_P95"
    expect_equal "$(report_value "$unqualified" R_INSIGHTS_VERDICT)" "not measured" "R_INSIGHTS_VERDICT"
    expect_equal "$(report_value "$unqualified" R_SERVER_SHARE)" "n/a" "R_SERVER_SHARE"
    conclude "$check"
done <<EOF
measureInsights_noPresetHeld_failsAccountCheckWithoutRequest|0|0|$UNHELD_INSIGHTS|no preset account has exactly 15 allocations, each with a numeric quantity > 0 on a distinct canonical instrumentId: [$ACCOUNT] $UNHELD_INSIGHTS;
measureInsights_inputsNeverVerified_failsAccountCheckWithoutRequest||1|$QUALIFYING_INSIGHTS|the preset inputs were not verified before the account was selected
EOF
FAKE_INPUTS_VERIFIED=1
FAKE_INPUT_HELD=1
FAKE_INPUT_INSIGHTS="$QUALIFYING_INSIGHTS"

summarize
if [[ "$failed" -ne 0 ]]; then
    exit 1
fi
