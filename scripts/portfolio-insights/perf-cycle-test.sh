#!/usr/bin/env bash
# Unit tests for the armed-set read, cycle-sample selection and follow-up recording of perf.sh,
# run without a stack, Docker or a database:
#   - read_armed_set splits the query's time row off the id,revision rows on both dialects and
#     sets ARMED_AT from it, and fails when that row is missing, repeated or unreadable;
#   - select_cycle_sample reads from T, the database time of the query that verified the owned
#     set, so a cycle line logged before T is never the sample, even while the check runs;
#   - it rejects an unclean sample and re-arms; after a re-arm it reads from a new T, and when
#     nothing was re-armed it reads on in the same window; a failing step fails with its reason;
#   - record_follow_ups fills a slot only with a clean follow-up whose owned set is unchanged,
#     continues the same way after an unclean one, and fails `cycle follow-ups` on any shortfall;
#   - the wait for the first line of a verified window, in either function, ends two intervals
#     plus the margin after its T, the owned-set check and the window's first log read counted;
#   - that wait parses the window's first log read before reading again, so a qualifying line
#     already in it is used, and no log read that ends after its wait's deadline is used;
#   - measure_cycle measures nothing unless the cycle inputs check of preflight_inputs passed,
#     counts no time row as an armed alert, and records the follow-ups after a failing
#     `cycle < 10 s` verdict as well.
# The functions and constants under test are read from perf.sh in this directory without
# running its main body. Only the pieces that reach the stack (HTTP, Docker logs, the database)
# or the clock are replaced by scripted fakes, defined after loading. SECONDS is an ordinary
# variable that only the fakes advance: the sleep fake advances it and the scripted clock
# instead of waiting, so every bounded wait reaches its deadline at once.
#
# Usage: scripts/portfolio-insights/perf-cycle-test.sh [--help]
#   --help  Show this help and exit
#
# Prints one PASS or FAIL line per test and a final SUMMARY line. Exits 0 when every test
# passes, 1 when any test fails, and 2 on a usage error. The run's temporary directory is
# removed on exit.

set -euo pipefail

PERF_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/perf.sh"
# The perf.sh pieces under test, loaded in this order. No other perf.sh function is loaded; the
# fakes below stand in for the stack-facing ones.
LOADED_CONSTANTS="PRESET_COUNT HOLDINGS_EXPECTED ALERTS_PER_ACCOUNT TARGET_PRICE_PER_ACCOUNT
ALERTS_EXPECTED MAX_THRESHOLD CYCLE_LIMIT_MS LOG_STEP_SECONDS MAX_REJECTED_SAMPLES
FOLLOW_UP_CYCLES CYCLE_WAIT_MARGIN_SECONDS CYCLE_MARKER CYCLE_RE ARMED_TIME_RE"
LOADED_FUNCTIONS="pass fail info dec_to_units armed_sql read_armed_set
parse_cycle_line cycle_is_clean cycle_summary_text read_window wait_cycle_line open_verified_window
select_cycle_sample record_follow_ups measure_cycle"
# The scripted clock reads FIXED_T at 0 s.
FIXED_T="2026-01-01T00:00:00Z"
# The armed-set query's default answer: no armed alert, and its time row as db_query prints it.
DEFAULT_TIME_ROW="at,2026-01-01t00:00:00.000000"
# read_armed_set's text for the failed query: the last db-error.log lines, then the empty query
# output, each line ending in a space.
OUTAGE_ERROR="armed-set query failed: scripted outage  "
REARM_FAILURE="PATCH alert [00000001-0000-4000-8000-000000000000] gave status 503"
# measure_cycle's only line when the cycle inputs check did not pass.
NOT_MEASURED_LINE="INFO cycle not measured: the cycle inputs check did not pass"
# read_window's detail for a log read that ended at or after its wait's deadline.
LATE_READ_DETAIL="broker-service logs read ended after the wait deadline and was discarded"

usage() {
    cat <<'EOF'
Usage: scripts/portfolio-insights/perf-cycle-test.sh [--help]
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

tests_passed=0
tests_failed=0
test_number=0
current_test=""
summarized=0
work=""
status=0
declare -a verify_appends=() verify_errors=() verify_times=() verify_at=() poll_appends=()
declare -a verify_seconds=() read_seconds=()

test_pass() {
    tests_passed=$((tests_passed + 1))
    echo "PASS $current_test"
}

test_fail() {
    tests_failed=$((tests_failed + 1))
    echo "FAIL $current_test: $1"
}

summarize() {
    summarized=1
    echo "SUMMARY ${tests_passed} passed, ${tests_failed} failed"
}

# A failed prerequisite leaves nothing meaningful to test, so the run stops there.
abort() {
    current_test="$1"
    test_fail "$2"
    summarize
    exit 1
}

# An unexpected error stops the run before its summary; it is reported against the test that
# was running, on the run's own output (fd 3) even while a test redirects stdout, and a
# passing status becomes 1.
cleanup() {
    local status=$? last=""
    trap - EXIT
    if [[ $summarized -eq 0 ]]; then
        if [[ -n "${RUN_DIR:-}" && -s "$RUN_DIR/out" ]]; then
            last="; last output: $(tail -n 3 "$RUN_DIR/out" | tr '\r\n' '  ')"
        fi
        {
            test_fail "the run stopped with status $status before its summary$last"
            summarize
        } >&3
        if [[ $status -eq 0 ]]; then
            status=1
        fi
    fi
    if [[ -n "$work" ]]; then
        rm -rf "$work"
    fi
    exit "$status"
}
exec 3>&1
trap cleanup EXIT
trap 'exit 130' INT TERM

# Flattens a captured output file into one line for a FAIL reason.
one_line() {
    tr '\r\n' '  ' <"$1"
}

current_test="perfSh_definitionsUnderTest_loadWithoutMainBody"
work="$(mktemp -d -t perf-cycle-test.XXXXXX)"
if [[ ! -f "$PERF_SH" ]]; then
    abort "$current_test" "$PERF_SH not found"
fi
# Carriage returns are dropped, so a checkout with CRLF line endings loads the same text.
tr -d '\r' <"$PERF_SH" >"$work/perf.sh"

# Prints the first column-0 assignment of constant NAME in perf.sh; fails when there is none.
perf_constant() {
    grep -m 1 -E "^$1=" "$work/perf.sh"
}

# Prints the column-0 definition of function NAME in perf.sh, from its "NAME() {" line to the
# first "}" line after it; fails when there is none.
perf_function() {
    awk -v name="$1" '
        $0 == name "() {" { inside = 1 }
        inside { print }
        inside && $0 == "}" { found = 1; exit }
        END { exit found ? 0 : 1 }
    ' "$work/perf.sh"
}

for name in $LOADED_CONSTANTS; do
    if ! definition="$(perf_constant "$name")"; then
        abort "$current_test" "perf.sh assigns no constant $name at column 0"
    fi
    eval "$definition"
done
for name in $LOADED_FUNCTIONS; do
    if ! definition="$(perf_function "$name")"; then
        abort "$current_test" "perf.sh defines no function $name at column 0"
    fi
    eval "$definition"
done
test_pass

# Fakes for the stack-facing pieces, over a scripted clock: clock counts whole seconds after
# FIXED_T. The broker log is $RUN_DIR/visible.log, one "STAMP LINE" record per line, where STAMP
# is the Docker timestamp that `compose logs --since` filters on. A scripted record joins it
# while an owned-set check runs (verify_appends, by check from 1) or when a poll sleeps
# (poll_appends, by sleep from 1); one without a STAMP of its own is stamped with the clock at
# that moment. Each check advances the clock by a second and sets ARMED_AT, the time of its
# query, to the clock or to verify_times[n]; verify_at[n] keeps it. verify_errors fails a
# check, by number, with its text. Time spent outside sleeps is scripted too: check n takes
# verify_seconds[n] seconds more, and log read n (log_reads counts them from 1) takes
# read_seconds[n], each on SECONDS and the clock alike.

# From here on SECONDS is an ordinary variable that only the fakes advance.
unset SECONDS

# clock_stamp SECONDS: the RFC3339 time SECONDS whole seconds after FIXED_T.
clock_stamp() {
    printf '2026-01-01T%02d:%02d:%02dZ\n' $(($1 / 3600)) $(($1 % 3600 / 60)) $(($1 % 60))
}

# log_record RECORDS: appends each line of RECORDS to the broker log, stamping a line that has
# no stamp of its own with the clock now.
log_record() {
    local record
    while IFS= read -r record; do
        if [[ ! "$record" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
            record="$(clock_stamp "$clock") $record"
        fi
        printf '%s\n' "$record" >>"$RUN_DIR/visible.log"
    done <<<"$1"
}

# broker_logs SINCE: the records stamped at or after SINCE, without their stamps, as
# `compose logs --since SINCE --no-log-prefix` prints them. Stamps compare as fixed-width text
# once each fraction is padded to nine digits. As perf.sh's own, it starts no read once
# PROBE_DEADLINE, the deadline of the cycle wait reading, has passed, and fails at once instead,
# counting no read.
broker_logs() {
    if [[ -n "${PROBE_DEADLINE:-}" && $SECONDS -ge $PROBE_DEADLINE ]]; then
        return 1
    fi
    log_reads=$((log_reads + 1))
    SECONDS=$((SECONDS + ${read_seconds[$log_reads]:-0}))
    clock=$((clock + ${read_seconds[$log_reads]:-0}))
    if [[ $logs_unreadable -eq 1 ]]; then
        return 1
    fi
    awk -v since="$1" '
        function fixed(t, frac) {
            frac = substr(t, 20)
            sub(/[Zz]$/, "", frac)
            sub(/^\./, "", frac)
            while (length(frac) < 9) {
                frac = frac "0"
            }
            return substr(t, 1, 19) "." frac
        }
        BEGIN { from = fixed(since) }
        fixed($1) >= from { print substr($0, length($1) + 2) }
    ' "$RUN_DIR/visible.log"
}

sleep() {
    SECONDS=$((SECONDS + $1))
    clock=$((clock + $1))
    sleep_calls=$((sleep_calls + 1))
    if [[ -n "${poll_appends[$sleep_calls]:-}" ]]; then
        log_record "${poll_appends[$sleep_calls]}"
    fi
}

verify_owned_set() {
    verify_calls=$((verify_calls + 1))
    SECONDS=$((SECONDS + ${verify_seconds[$verify_calls]:-0}))
    clock=$((clock + 1 + ${verify_seconds[$verify_calls]:-0}))
    ARMED_AT="${verify_times[$verify_calls]:-$(clock_stamp "$clock")}"
    verify_at[verify_calls]="$ARMED_AT"
    if [[ -n "${verify_appends[$verify_calls]:-}" ]]; then
        log_record "${verify_appends[$verify_calls]}"
    fi
    if [[ -n "${verify_errors[$verify_calls]:-}" ]]; then
        OWNED_ERROR="${verify_errors[$verify_calls]}"
        return 1
    fi
}

# db_query SQL: the armed-set query, which perf.sh's own read_armed_set sends from a command
# substitution. It keeps SQL in $RUN_DIR/db-sql and prints $RUN_DIR/db-rows, the rows as
# db_query prints them; with armed_query_fails it fails as a SQL error does, its message in
# db-error.log and nothing on stdout.
db_query() {
    printf '%s\n' "$1" >"$RUN_DIR/db-sql"
    if [[ $armed_query_fails -eq 1 ]]; then
        echo "scripted outage" >>"$RUN_DIR/db-error.log"
        return 1
    fi
    cat "$RUN_DIR/db-rows"
}

# rearm_missing re-arms rearm_count alerts, as REARMED reports. With logs_fail_after_rearm, the
# broker logs become unreadable once the re-arm succeeds, so the next verified window cannot
# open.
rearm_missing() {
    if [[ $rearm_fails -eq 1 ]]; then
        REARM_ERROR="$REARM_FAILURE"
        return 1
    fi
    if [[ $logs_fail_after_rearm -eq 1 ]]; then
        logs_unreadable=1
    fi
    REARMED="$rearm_count"
    info "re-armed $REARMED owned alerts missing from the armed set"
}

# Each created alert joins the expected owned set at revision 1, as a 201 records it.
create_alert() {
    created_alerts=$((created_alerts + 1))
    printf '%08x-0000-4000-8000-000000000000,1\n' "$created_alerts" >>"$RUN_DIR/expected"
}

# start_test NAME: fresh fake state and run directory for test NAME. The owned set holds
# ALERTS_EXPECTED alerts at revision 1, the database holds no armed alert, the scripted log is
# empty, the clock reads FIXED_T, every re-arm re-arms one alert, the dialect is PostgreSQL and
# the interval is 60 s, so a first line is awaited for 150 s and a follow-up for 90 s. The
# cycle inputs are unverified (INPUTS_VERIFIED 0) until measure_presets records them.
# shellcheck disable=SC2034 # The perf.sh functions loaded through eval read these.
start_test() {
    current_test="$1"
    test_number=$((test_number + 1))
    RUN_DIR="$work/$test_number"
    mkdir "$RUN_DIR"
    awk -v n="$ALERTS_EXPECTED" \
        'BEGIN { for (i = 1; i <= n; i++) printf "%08x-0000-4000-8000-000000000000,1\n", i }' \
        >"$RUN_DIR/expected"
    : >"$RUN_DIR/visible.log"
    echo "$DEFAULT_TIME_ROW" >"$RUN_DIR/db-rows"
    verify_appends=()
    verify_errors=()
    verify_times=()
    verify_at=()
    poll_appends=()
    verify_seconds=()
    read_seconds=()
    verify_calls=0
    sleep_calls=0
    log_reads=0
    clock=0
    logs_unreadable=0
    logs_fail_after_rearm=0
    armed_query_fails=0
    rearm_fails=0
    rearm_count=1
    created_alerts=0
    DIALECT="postgres"
    status=0
    passed=0
    failed=0
    EVAL_INTERVAL=60
    INPUTS_VERIFIED=0
    R_CYCLE_VERDICT="not measured"
    R_CYCLE_REJECTIONS="0"
    R_FOLLOW_UPS="n/a"
    CYCLE_T=""
    CYCLE_DEADLINE=""
    CYCLE_INDEX=0
    CYCLE_LINE=""
    LOG_SINCE=""
    LOG_BASE=0
    LOG_PROBE_DETAIL=""
    WINDOW_READ_HELD=0
    OWNED_ERROR=""
    ARMED_ERROR=""
    ARMED_AT=""
    REARM_ERROR=""
    REARMED=0
    SECONDS=0
}

# cycle_line ALERTS TRIGGERED FAILED SKIPPED OUTCOME DURATION: a cycle summary line as the
# broker's console logger prints it, with its timestamp, padding and caller name.
cycle_line() {
    printf '[2026-01-01 00:00:05] Information: %s: alerts [%s] triggered [%s] failed [%s] skipped [%s] outcome [%s] duration [%s] ms        | RunCycleAsync\n' \
        "$CYCLE_MARKER" "$1" "$2" "$3" "$4" "$5" "$6"
}

# clean_line DURATION: a clean cycle line over the whole owned set.
clean_line() {
    cycle_line "$ALERTS_EXPECTED" 0 0 0 completed "$1"
}

# shows ALERTS TRIGGERED FAILED SKIPPED OUTCOME DURATION: the reason perf.sh gives for an
# unclean line with these values.
shows() {
    echo "cycle line shows alerts [$1] triggered [$2] failed [$3] skipped [$4] outcome [$5] duration [$6] ms"
}

# accepted_sample DURATION: the window an accepted sample leaves behind. T is the clock now, the
# window starts at T, and the sample's clean line, logged at T, is its first cycle line, which
# CYCLE_INDEX points at.
# shellcheck disable=SC2034 # record_follow_ups, loaded through eval, reads these.
accepted_sample() {
    CYCLE_T="$(clock_stamp "$clock")"
    LOG_SINCE="$CYCLE_T"
    LOG_BASE=0
    log_record "$(clean_line "$1")"
    CYCLE_INDEX=1
}

# Runs select_cycle_sample in this shell, as measure_cycle does; output in $RUN_DIR/out, the
# return status in status.
run_select() {
    select_cycle_sample >"$RUN_DIR/out" 2>&1 || status=$?
}

# Runs record_follow_ups in this shell, as measure_cycle does: an unexpected error ends the run.
run_follow_ups() {
    record_follow_ups >"$RUN_DIR/out" 2>&1
}

# Runs measure_cycle in this shell, as the main body does: an unexpected error ends the run.
run_measure() {
    measure_cycle >"$RUN_DIR/out" 2>&1
}

# expect_selected LINE: select_cycle_sample accepted LINE.
expect_selected() {
    if [[ $status -eq 0 && "$CYCLE_LINE" == "$1" ]]; then
        test_pass
    else
        test_fail "status $status with line '$CYCLE_LINE', expected status 0 with '$1'; output: $(one_line "$RUN_DIR/out")"
    fi
}

# expect_selected_since LINE SINCE: select_cycle_sample accepted LINE, read in the window that
# starts at SINCE.
expect_selected_since() {
    if [[ $status -eq 0 && "$CYCLE_LINE" == "$1" && "$LOG_SINCE" == "$2" ]]; then
        test_pass
    else
        test_fail "status $status with line '$CYCLE_LINE' in the window since '$LOG_SINCE', expected status 0 with '$1' since '$2'; output: $(one_line "$RUN_DIR/out")"
    fi
}

# expect_selected_at LINE SINCE ELAPSED READS: select_cycle_sample accepted LINE, read in the
# window that starts at SINCE, and ended with SECONDS at ELAPSED after READS log reads.
expect_selected_at() {
    if [[ $status -eq 0 && "$CYCLE_LINE" == "$1" && "$LOG_SINCE" == "$2" && $SECONDS -eq $3 && $log_reads -eq $4 ]]; then
        test_pass
    else
        test_fail "status $status with line '$CYCLE_LINE' in the window since '$LOG_SINCE' at ${SECONDS}s after $log_reads log reads, expected status 0 with '$1' since '$2' at ${3}s after $4 log reads; output: $(one_line "$RUN_DIR/out")"
    fi
}

# expect_line LINE: the code under test printed exactly LINE.
expect_line() {
    if grep -qxF -- "$1" "$RUN_DIR/out"; then
        test_pass
    else
        test_fail "no output line '$1'; output: $(one_line "$RUN_DIR/out")"
    fi
}

# expect_line_at LINE ELAPSED [READS]: the code under test printed exactly LINE and ended with
# SECONDS at ELAPSED, after READS log reads when READS is given.
expect_line_at() {
    if grep -qxF -- "$1" "$RUN_DIR/out" && [[ $SECONDS -eq $2 && ($# -lt 3 || $log_reads -eq $3) ]]; then
        test_pass
    else
        test_fail "ended at ${SECONDS}s after $log_reads log reads, expected line '$1' at ${2}s${3:+ after $3 log reads}; output: $(one_line "$RUN_DIR/out")"
    fi
}

# expect_cycle_checks LINE...: the `cycle < 10 s` and `cycle follow-ups` check lines printed
# are exactly LINE..., in order.
expect_cycle_checks() {
    local printed wanted
    printed="$(grep -E '^(PASS|FAIL) cycle (< 10 s|follow-ups)' "$RUN_DIR/out" || true)"
    wanted="$(printf '%s\n' "$@")"
    if [[ "$printed" == "$wanted" ]]; then
        test_pass
    else
        test_fail "check lines '$(tr '\n' '|' <<<"$printed")', expected '$(tr '\n' '|' <<<"$wanted")'; output: $(one_line "$RUN_DIR/out")"
    fi
}

# expect_follow_ups VALUE: record_follow_ups left R_FOLLOW_UPS at VALUE.
expect_follow_ups() {
    if [[ "$R_FOLLOW_UPS" == "$1" ]]; then
        test_pass
    else
        test_fail "R_FOLLOW_UPS is '$R_FOLLOW_UPS', expected '$1'; output: $(one_line "$RUN_DIR/out")"
    fi
}

# expect_follow_ups_since LINE VALUE SINCE: record_follow_ups printed exactly the check line
# LINE, left R_FOLLOW_UPS at VALUE and read its last line in the window that starts at SINCE.
expect_follow_ups_since() {
    if grep -qxF -- "$1" "$RUN_DIR/out" && [[ "$R_FOLLOW_UPS" == "$2" && "$LOG_SINCE" == "$3" ]]; then
        test_pass
    else
        test_fail "R_FOLLOW_UPS '$R_FOLLOW_UPS' in the window since '$LOG_SINCE', expected line '$1' with '$2' since '$3'; output: $(one_line "$RUN_DIR/out")"
    fi
}

# Runs read_armed_set in this shell, as verify_owned_set and measure_cycle do; output in
# $RUN_DIR/out, the return status in status.
run_read_armed() {
    read_armed_set >"$RUN_DIR/out" 2>&1 || status=$?
}

# armed_rows: the rows read_armed_set wrote to $RUN_DIR/armed, joined by ";".
armed_rows() {
    if [[ -f "$RUN_DIR/armed" ]]; then
        paste -sd ';' "$RUN_DIR/armed"
    fi
}

# armed_set_suffix DIALECT: how the armed-set query ends on DIALECT: the armed filter, the
# statement-time row and the ordering.
armed_set_suffix() {
    if [[ "$1" == "mssql" ]]; then
        echo "WHERE [Enabled] = 1 AND [TriggeredAt] IS NULL UNION ALL SELECT 'at,' + CONVERT(varchar(27), SYSUTCDATETIME(), 126) ORDER BY 1"
    else
        echo "WHERE \"Enabled\" = true AND \"TriggeredAt\" IS NULL UNION ALL SELECT 'at,' || to_char(statement_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US') ORDER BY 1"
    fi
}

# measure_presets: what a passed preflight_inputs leaves for measure_cycle, and an empty owned
# set that its workload fills. The PRESET_COUNT preset accounts are in $RUN_DIR/presets; each
# one's HOLDINGS_EXPECTED distinct canonical instrument ids are in $RUN_DIR/held-ID, sorted, as
# insights_profile writes them; and INPUTS_VERIFIED is 1.
# shellcheck disable=SC2034 # measure_cycle, loaded through eval, reads INPUTS_VERIFIED.
measure_presets() {
    local id
    : >"$RUN_DIR/expected"
    awk -v n="$PRESET_COUNT" \
        'BEGIN { for (i = 1; i <= n; i++) printf "%08x-0000-4000-a000-000000000000\n", i }' \
        >"$RUN_DIR/presets"
    while IFS= read -r id; do
        awk -v n="$HOLDINGS_EXPECTED" \
            'BEGIN { for (i = 1; i <= n; i++) printf "%08x-0000-4000-9000-000000000000\n", i }' \
            >"$RUN_DIR/held-$id"
    done <"$RUN_DIR/presets"
    INPUTS_VERIFIED=1
}

# read_armed_set, through perf.sh's own armed_sql

# One case per dialect: the query perf.sh sends carries the statement-time row.
for dialect in mssql postgres; do
    start_test "readArmedSet_${dialect}Query_endsWithStatementTimeRow"
    # shellcheck disable=SC2034 # armed_sql, loaded through eval, reads DIALECT.
    DIALECT="$dialect"
    suffix="$(armed_set_suffix "$dialect")"
    run_read_armed
    sent="$(cat "$RUN_DIR/db-sql" 2>/dev/null || true)"
    if [[ $status -eq 0 && "$sent" == *"$suffix" ]]; then
        test_pass
    else
        test_fail "status $status with query '$sent', expected status 0 and a query ending '$suffix'; output: $(one_line "$RUN_DIR/out")"
    fi
done

# The query's answer, as db_query prints it: name | dialect | rows, ";" between them | status |
# ARMED_AT on success or ARMED_ERROR on failure | the armed rows written, ";" between them.
id_a="a0000000-0000-4000-8000-000000000000,1"
id_b="b0000000-0000-4000-8000-000000000000,1"
while IFS='|' read -r name dialect rows want_status want_value want_armed; do
    start_test "$name"
    # shellcheck disable=SC2034 # armed_sql, loaded through eval, reads DIALECT.
    DIALECT="$dialect"
    tr ';' '\n' <<<"$rows" >"$RUN_DIR/db-rows"
    run_read_armed
    if [[ $want_status -eq 0 ]]; then
        got_value="$ARMED_AT"
    else
        got_value="$ARMED_ERROR"
    fi
    got_armed="$(armed_rows)"
    if [[ $status -eq $want_status && "$got_value" == "$want_value" && "$got_armed" == "$want_armed" ]] &&
        [[ $status -eq 0 || -z "$ARMED_AT" ]]; then
        test_pass
    else
        test_fail "status $status with ARMED_AT '$ARMED_AT', ARMED_ERROR '$ARMED_ERROR' and armed rows '$got_armed'; expected status $want_status with '$want_value' and armed rows '$want_armed'"
    fi
done <<EOF
readArmedSet_postgresSixDigitFraction_setsArmedAtAndSortedIdRows|postgres|$id_b;at,2026-11-26t01:49:38.151857;$id_a|0|2026-11-26T01:49:38.151857Z|$id_a;$id_b
readArmedSet_mssqlSevenDigitFraction_setsArmedAt|mssql|at,2026-11-26t01:49:38.1518570;$id_a|0|2026-11-26T01:49:38.1518570Z|$id_a
readArmedSet_mssqlZeroFractionOmitted_setsArmedAtWithoutFraction|mssql|at,2026-11-26t01:49:38|0|2026-11-26T01:49:38Z|
readArmedSet_uppercaseTimeRow_setsArmedAt|postgres|AT,2026-11-26T01:49:38.151857Z|0|2026-11-26T01:49:38.151857Z|
readArmedSet_lowercaseZoneSuffix_setsArmedAt|mssql|$id_a;at,2026-11-26t01:49:38.1518570z|0|2026-11-26T01:49:38.1518570Z|$id_a
readArmedSet_onlyTimeRow_writesEmptyArmedSet|postgres|$DEFAULT_TIME_ROW|0|2026-01-01T00:00:00.000000Z|
readArmedSet_missingTimeRow_failsWithCount|postgres|$id_a;$id_b|1|armed-set query returned 0 time rows instead of 1|
readArmedSet_emptyAnswer_failsWithCount|mssql||1|armed-set query returned 0 time rows instead of 1|
readArmedSet_duplicateTimeRow_failsWithCount|mssql|at,2026-11-26t01:49:38.1518570;$id_a;at,2026-11-26t01:49:39|1|armed-set query returned 2 time rows instead of 1|
readArmedSet_timeWithoutSeparator_failsUnreadable|postgres|at,2026-11-26 01:49:38.151857|1|armed-set query returned an unreadable time row [at,2026-11-26 01:49:38.151857]|
readArmedSet_tenDigitFraction_failsUnreadable|mssql|at,2026-11-26t01:49:38.1234567890|1|armed-set query returned an unreadable time row [at,2026-11-26t01:49:38.1234567890]|
EOF

start_test "readArmedSet_queryFails_failsWithDatabaseError"
armed_query_fails=1
run_read_armed
if [[ $status -eq 1 && "$ARMED_ERROR" == "$OUTAGE_ERROR" && -z "$ARMED_AT" ]]; then
    test_pass
else
    test_fail "status $status with ARMED_ERROR '$ARMED_ERROR' and ARMED_AT '$ARMED_AT', expected status 1 with '$OUTAGE_ERROR' and no ARMED_AT"
fi

# select_cycle_sample

# A qualifying line logged while the owned set is being verified, but stamped after T, the
# time of the query, is the sample; the setup-count line beside it is ignored.
start_test "selectCycleSample_lineLoggedDuringCheckAfterT_isSelected"
verify_appends[1]="$(cycle_line 960 0 0 0 completed 800)
$(clean_line 2222)"
run_select
expect_selected_since "$(clean_line 2222)" "${verify_at[1]}"

# A qualifying line logged during the check but stamped before T is not the sample, however
# fast: the first line after T is, at 12,000 ms.
start_test "selectCycleSample_qualifyingLineLoggedDuringCheckBeforeT_isNotSelected"
verify_times[1]="2026-01-01T00:00:01.151857Z"
verify_appends[1]="2026-01-01T00:00:01.151856900Z $(clean_line 25)"
poll_appends[1]="$(clean_line 12000)"
run_select
expect_selected_since "$(clean_line 12000)" "2026-01-01T00:00:01.151857Z"

start_test "selectCycleSample_qualifyingLineLoggedBeforeT_isSkipped"
log_record "$(clean_line 1111)"
poll_appends[1]="$(clean_line 3333)"
run_select
expect_selected "$(clean_line 3333)"

# A re-arm opens a new window at the new T (check 3): the clean line logged during the sample
# check, before that T, is ignored.
start_test "selectCycleSample_triggeredSampleRearmed_readsFromNewT"
verify_appends[1]="$(cycle_line "$ALERTS_EXPECTED" 2 0 0 completed 1500)"
verify_appends[2]="$(clean_line 1999)"
verify_appends[3]="$(clean_line 2600)"
run_select
expect_selected_since "$(clean_line 2600)" "${verify_at[3]}"

# With nothing re-armed, reading goes on in the same window: the clean line already logged
# after the rejected one is the sample, without another poll.
start_test "selectCycleSample_rejectedSampleNothingRearmed_selectsNextLoggedLineInSameWindow"
rearm_count=0
verify_appends[1]="$(cycle_line "$ALERTS_EXPECTED" 0 1 0 completed 1500)
$(clean_line 2700)"
run_select
expect_selected_since "$(clean_line 2700)" "${verify_at[1]}"

start_test "selectCycleSample_rejectedSampleNothingRearmedNoFurtherLine_failsAtDeadline"
rearm_count=0
verify_appends[1]="$(cycle_line "$ALERTS_EXPECTED" 0 0 2 completed 1500)"
run_select
expect_line "FAIL cycle < 10 s: no cycle line rendered alerts [$ALERTS_EXPECTED] within 150s after ${verify_at[1]}; rejected: sample 1: $(shows "$ALERTS_EXPECTED" 0 0 2 completed 1500)"

start_test "selectCycleSample_logsUnreadableAtT_failsCycleCheck"
logs_unreadable=1
run_select
expect_line "FAIL cycle < 10 s: broker-service logs unreadable (see $RUN_DIR/compose.log)"

start_test "selectCycleSample_ownedSetDiffersAtT_failsOwnedSetCheck"
verify_errors[1]="the armed set and the $ALERTS_EXPECTED owned alerts differ in 2 id,revision rows"
run_select
expect_line "FAIL cycle owned set: the armed set and the $ALERTS_EXPECTED owned alerts differ in 2 id,revision rows"

start_test "selectCycleSample_ownedRevisionNotOne_failsOwnedSetCheck"
sed -i '1s/,1$/,2/' "$RUN_DIR/expected"
run_select
expect_line "FAIL cycle owned set: owned alerts carry revisions [1 2], all must be 1"

start_test "selectCycleSample_onlySetupCountAfterT_failsAtDeadline"
poll_appends[1]="$(cycle_line 990 0 0 0 completed 900)"
run_select
expect_line "FAIL cycle < 10 s: no cycle line rendered alerts [$ALERTS_EXPECTED] within 150s after ${verify_at[1]}"

start_test "selectCycleSample_threeRejectedSamples_failsNoCleanSample"
verify_appends[1]="$(cycle_line "$ALERTS_EXPECTED" 2 0 0 completed 1500)"
verify_appends[3]="$(cycle_line "$ALERTS_EXPECTED" 0 1 0 completed 1600)"
verify_appends[5]="$(cycle_line "$ALERTS_EXPECTED" 0 0 4 completed 1700)"
run_select
expect_line "FAIL cycle < 10 s: no clean sample: sample 1: $(shows "$ALERTS_EXPECTED" 2 0 0 completed 1500); sample 2: $(shows "$ALERTS_EXPECTED" 0 1 0 completed 1600); sample 3: $(shows "$ALERTS_EXPECTED" 0 0 4 completed 1700)"

# One case per re-arm step that can fail after a rejected sample; with nothing re-armed, the
# owned-set check that precedes reading on in the same window.
for step in armedQuery rearm logs ownedSet ownedSetNothingRearmed; do
    start_test "selectCycleSample_${step}FailsAfterRejectedSample_failsCycleCheck"
    verify_appends[1]="$(cycle_line "$ALERTS_EXPECTED" 2 0 0 completed 1500)"
    rejected="sample 1: $(shows "$ALERTS_EXPECTED" 2 0 0 completed 1500)"
    case "$step" in
        armedQuery)
            armed_query_fails=1
            expected="FAIL cycle < 10 s: no clean sample: $OUTAGE_ERROR; $rejected"
            ;;
        rearm)
            rearm_fails=1
            expected="FAIL cycle < 10 s: no clean sample: re-arming failed, $REARM_FAILURE; $rejected"
            ;;
        logs)
            logs_fail_after_rearm=1
            expected="FAIL cycle < 10 s: broker-service logs unreadable (see $RUN_DIR/compose.log)"
            ;;
        ownedSet)
            verify_errors[3]="the armed set and the $ALERTS_EXPECTED owned alerts differ in 1 id,revision rows"
            expected="FAIL cycle < 10 s: no clean sample: after re-arming ${verify_errors[3]}; $rejected"
            ;;
        ownedSetNothingRearmed)
            rearm_count=0
            verify_errors[3]="the armed set and the $ALERTS_EXPECTED owned alerts differ in 1 id,revision rows"
            expected="FAIL cycle < 10 s: no clean sample: after re-arming ${verify_errors[3]}; $rejected"
            ;;
    esac
    run_select
    expect_line "$expected"
done

# record_follow_ups

start_test "recordFollowUps_twoCleanCycles_passesCheck"
accepted_sample 2000
log_record "$(clean_line 1200)"
poll_appends[1]="$(clean_line 1300)"
run_follow_ups
expect_line "PASS cycle follow-ups"

start_test "recordFollowUps_twoCleanCycles_recordsBothDurations"
accepted_sample 2000
log_record "$(clean_line 1200)"
poll_appends[1]="$(clean_line 1300)"
run_follow_ups
expect_follow_ups "1200 ms, 1300 ms"

start_test "recordFollowUps_uncleanCycleFirst_doesNotConsumeSlot"
accepted_sample 2000
log_record "$(cycle_line "$ALERTS_EXPECTED" 1 0 0 completed 1400)"
verify_appends[2]="$(clean_line 1250)"
poll_appends[1]="$(clean_line 1260)"
run_follow_ups
expect_follow_ups "1250 ms, 1260 ms"

# A re-arm opens a new window at the new T (check 2): the clean line logged before it is not a
# follow-up.
start_test "recordFollowUps_uncleanCycleRearmed_ignoresLinesBeforeNewT"
accepted_sample 2000
log_record "$(cycle_line "$ALERTS_EXPECTED" 1 0 0 completed 1400)
$(clean_line 200)"
verify_appends[2]="$(clean_line 1250)"
poll_appends[1]="$(clean_line 1260)"
run_follow_ups
expect_follow_ups_since "PASS cycle follow-ups" "1250 ms, 1260 ms" "${verify_at[2]}"

# With nothing re-armed, reading goes on in the same window: the two clean lines already logged
# after the unclean one are the follow-ups.
start_test "recordFollowUps_uncleanCycleNothingRearmed_countsTwoLoggedCleanLines"
rearm_count=0
accepted_sample 2000
log_record "$(cycle_line "$ALERTS_EXPECTED" 0 1 0 completed 1400)
$(clean_line 200)
$(clean_line 300)"
run_follow_ups
expect_follow_ups_since "PASS cycle follow-ups" "200 ms, 300 ms" "$FIXED_T"

start_test "recordFollowUps_uncleanCycleNothingRearmedNoFurtherLine_failsWithShortfall"
rearm_count=0
accepted_sample 2000
log_record "$(cycle_line "$ALERTS_EXPECTED" 0 0 3 completed 1400)"
run_follow_ups
expect_line "FAIL cycle follow-ups: 0 of 2 clean follow-up cycles recorded; follow-up 1: $(shows "$ALERTS_EXPECTED" 0 0 3 completed 1400); follow-up 2: no cycle line within 90s"

start_test "recordFollowUps_ownedSetChangedAfterCleanLine_rejectsFollowUp"
accepted_sample 2000
log_record "$(clean_line 1100)"
verify_errors[1]="the armed set and the $ALERTS_EXPECTED owned alerts differ in 1 id,revision rows"
verify_appends[2]="$(clean_line 1210)"
poll_appends[1]="$(clean_line 1220)"
run_follow_ups
expect_follow_ups "1210 ms, 1220 ms"

start_test "recordFollowUps_uncleanLineAndSetChange_rejectsWithBothReasons"
accepted_sample 2000
log_record "$(cycle_line "$ALERTS_EXPECTED" 3 0 0 completed 1400)"
verify_errors[1]="the armed set and the $ALERTS_EXPECTED owned alerts differ in 3 id,revision rows"
armed_query_fails=1
run_follow_ups
expect_line "FAIL cycle follow-ups: 0 of 2 clean follow-up cycles recorded; follow-up 1: $(shows "$ALERTS_EXPECTED" 3 0 0 completed 1400), ${verify_errors[1]}; $OUTAGE_ERROR"

start_test "recordFollowUps_waitTimesOut_failsWithShortfall"
accepted_sample 2000
poll_appends[1]="$(clean_line 1200)"
run_follow_ups
expect_line "FAIL cycle follow-ups: 1 of 2 clean follow-up cycles recorded; follow-up 2: no cycle line within 90s"

start_test "recordFollowUps_noLineOverOwnedSetAfterRearm_failsWithShortfall"
accepted_sample 2000
log_record "$(cycle_line "$ALERTS_EXPECTED" 1 0 0 completed 1400)"
poll_appends[1]="$(cycle_line 990 0 0 0 completed 900)"
run_follow_ups
expect_line "FAIL cycle follow-ups: 0 of 2 clean follow-up cycles recorded; follow-up 1: $(shows "$ALERTS_EXPECTED" 1 0 0 completed 1400); follow-up 2: no cycle line rendered alerts [$ALERTS_EXPECTED] within 150s after ${verify_at[2]}"

start_test "recordFollowUps_maxRejectedUncleanCycles_failsCheck"
accepted_sample 2000
log_record "$(cycle_line "$ALERTS_EXPECTED" 1 0 0 completed 1400)"
verify_appends[2]="$(cycle_line "$ALERTS_EXPECTED" 0 1 0 completed 1500)"
verify_appends[4]="$(cycle_line "$ALERTS_EXPECTED" 0 0 0 failed 1600)"
run_follow_ups
expect_line "FAIL cycle follow-ups: 0 of 2 clean follow-up cycles recorded; follow-up 1: $(shows "$ALERTS_EXPECTED" 1 0 0 completed 1400); follow-up 2: $(shows "$ALERTS_EXPECTED" 0 1 0 completed 1500); follow-up 3: $(shows "$ALERTS_EXPECTED" 0 0 0 failed 1600); stopped after $MAX_REJECTED_SAMPLES unclean follow-up cycles"

# One case per re-arm step that can fail after an unclean follow-up; with nothing re-armed, the
# owned-set check that precedes reading on in the same window.
for step in armedQuery rearm logs ownedSet ownedSetNothingRearmed; do
    start_test "recordFollowUps_${step}FailsAfterUncleanCycle_failsWithReason"
    accepted_sample 2000
    log_record "$(cycle_line "$ALERTS_EXPECTED" 1 0 0 completed 1400)"
    shortfall="FAIL cycle follow-ups: 0 of 2 clean follow-up cycles recorded; follow-up 1: $(shows "$ALERTS_EXPECTED" 1 0 0 completed 1400)"
    case "$step" in
        armedQuery)
            armed_query_fails=1
            expected="$shortfall; $OUTAGE_ERROR"
            ;;
        rearm)
            rearm_fails=1
            expected="$shortfall; re-arming failed, $REARM_FAILURE"
            ;;
        logs)
            logs_fail_after_rearm=1
            expected="$shortfall; broker-service logs unreadable (see $RUN_DIR/compose.log)"
            ;;
        ownedSet)
            verify_errors[2]="the armed set and the $ALERTS_EXPECTED owned alerts differ in 1 id,revision rows"
            expected="$shortfall; after re-arming ${verify_errors[2]}"
            ;;
        ownedSetNothingRearmed)
            rearm_count=0
            verify_errors[2]="the armed set and the $ALERTS_EXPECTED owned alerts differ in 1 id,revision rows"
            expected="$shortfall; after re-arming ${verify_errors[2]}"
            ;;
    esac
    run_follow_ups
    expect_line "$expected"
done

# The first line's allowance after T

# One case per verified window whose first log read takes 60 s of the 150 s allowance: the wait
# for the window's first line still ends 150 s after the reading taken just before the owned-set
# check that set its T, not 150 s after that read.
for window in sample rearmedSample rearmedFollowUp; do
    case "$window" in
        sample)
            start_test "selectCycleSample_slowFirstLogRead_waitEndsAllowanceAfterT"
            read_seconds[1]=60
            run_select
            expected="FAIL cycle < 10 s: no cycle line rendered alerts [$ALERTS_EXPECTED] within 150s after ${verify_at[1]}"
            ;;
        rearmedSample)
            start_test "selectCycleSample_slowFirstLogReadAfterRearm_waitEndsAllowanceAfterNewT"
            verify_appends[1]="$(cycle_line "$ALERTS_EXPECTED" 2 0 0 completed 1500)"
            read_seconds[2]=60
            run_select
            expected="FAIL cycle < 10 s: no cycle line rendered alerts [$ALERTS_EXPECTED] within 150s after ${verify_at[3]}; rejected: sample 1: $(shows "$ALERTS_EXPECTED" 2 0 0 completed 1500)"
            ;;
        rearmedFollowUp)
            start_test "recordFollowUps_slowFirstLogReadAfterRearm_waitEndsAllowanceAfterNewT"
            accepted_sample 2000
            log_record "$(cycle_line "$ALERTS_EXPECTED" 1 0 0 completed 1400)"
            read_seconds[2]=60
            run_follow_ups
            expected="FAIL cycle follow-ups: 0 of 2 clean follow-up cycles recorded; follow-up 1: $(shows "$ALERTS_EXPECTED" 1 0 0 completed 1400); follow-up 2: no cycle line rendered alerts [$ALERTS_EXPECTED] within 150s after ${verify_at[2]}"
            ;;
    esac
    expect_line_at "$expected" 150
done

# An owned-set check that takes the whole allowance leaves no time for the window's first log
# read: none starts, and the cycle check fails saying so.
start_test "selectCycleSample_ownedSetCheckOutlastsAllowance_failsWithoutLogRead"
verify_seconds[1]=150
run_select
expect_line_at "FAIL cycle < 10 s: broker-service logs probe not started: no time left of the 150s allowance after ${verify_at[1]}" 150 0

# One case per log read of the first-line wait that holds a qualifying line but ends after the
# 150 s allowance: the window's first read, ending at 150 s, and a poll read, ending at 155 s.
# Neither line is the sample, and the cycle check fails saying the read ended late.
for late_read in windowFirst poll; do
    case "$late_read" in
        windowFirst)
            start_test "selectCycleSample_firstWindowReadEndsAfterAllowance_failsWithLateReadDetail"
            verify_appends[1]="$(clean_line 2222)"
            read_seconds[1]=150
            run_select
            expected="FAIL cycle < 10 s: $LATE_READ_DETAIL"
            elapsed=150
            reads=1
            ;;
        poll)
            start_test "selectCycleSample_pollReadEndsAfterAllowance_failsWithLateReadDetail"
            poll_appends[1]="$(clean_line 2222)"
            read_seconds[2]=150
            run_select
            expected="FAIL cycle < 10 s: no cycle line rendered alerts [$ALERTS_EXPECTED] within 150s after ${verify_at[1]}; last read: $LATE_READ_DETAIL"
            elapsed=155
            reads=2
            ;;
    esac
    expect_line_at "$expected" "$elapsed" "$reads"
done

# One case per verified window whose first log read holds a qualifying line and ends 145 s into
# the 150 s allowance, while the next read would end after it: the wait parses the window's
# first read before reading again, so that line is used and that wait needs no further read.
for window in sample rearmedSample rearmedFollowUp; do
    case "$window" in
        sample)
            start_test "selectCycleSample_lineInSlowFirstWindowRead_isSelectedWithoutRereading"
            verify_appends[1]="$(clean_line 2222)"
            read_seconds[1]=145
            read_seconds[2]=60
            run_select
            expect_selected_at "$(clean_line 2222)" "${verify_at[1]}" 145 1
            ;;
        rearmedSample)
            start_test "selectCycleSample_lineInSlowFirstReadAfterRearm_isSelectedWithoutRereading"
            verify_appends[1]="$(cycle_line "$ALERTS_EXPECTED" 2 0 0 completed 1500)"
            verify_appends[3]="$(clean_line 2600)"
            read_seconds[2]=145
            read_seconds[3]=60
            run_select
            expect_selected_at "$(clean_line 2600)" "${verify_at[3]}" 145 2
            ;;
        rearmedFollowUp)
            # The 60 s read is then the next follow-up's, well within that wait's 90 s.
            start_test "recordFollowUps_lineInSlowFirstReadAfterRearm_isRecordedWithoutRereading"
            accepted_sample 2000
            log_record "$(cycle_line "$ALERTS_EXPECTED" 1 0 0 completed 1400)"
            verify_appends[2]="$(clean_line 1250)"
            read_seconds[2]=145
            read_seconds[3]=60
            poll_appends[1]="$(clean_line 1260)"
            run_follow_ups
            expect_follow_ups_since "PASS cycle follow-ups" "1250 ms, 1260 ms" "${verify_at[2]}"
            ;;
    esac
done

# measure_cycle

# One case per INPUTS_VERIFIED short of 1: 0, as a failed preflight_inputs leaves it, and unset,
# as before any preflight. The presets and their held instruments are in place, so the marker
# alone stops measure_cycle: it prints only the not-measured line, sends no armed-set query and
# creates no alert.
while IFS='|' read -r name verified; do
    start_test "$name"
    measure_presets
    if [[ "$verified" == "unset" ]]; then
        unset INPUTS_VERIFIED
    else
        # shellcheck disable=SC2034 # measure_cycle, loaded through eval, reads INPUTS_VERIFIED.
        INPUTS_VERIFIED="$verified"
    fi
    run_measure
    if [[ "$(cat "$RUN_DIR/out")" == "$NOT_MEASURED_LINE" && ! -e "$RUN_DIR/db-sql" &&
        $created_alerts -eq 0 && ! -s "$RUN_DIR/expected" ]]; then
        test_pass
    else
        queried="no armed-set query"
        if [[ -e "$RUN_DIR/db-sql" ]]; then
            queried="an armed-set query"
        fi
        test_fail "$queried and $created_alerts alerts created, output: $(one_line "$RUN_DIR/out"); expected only '$NOT_MEASURED_LINE', no armed-set query and no alert"
    fi
done <<'EOF'
measureCycle_inputsCheckFailed_printsNotMeasuredOnly|0
measureCycle_inputsNeverChecked_printsNotMeasuredOnly|unset
EOF

# One case per armed-set answer at the precondition: the time row is never an armed alert.
while IFS='|' read -r name rows expected; do
    start_test "$name"
    measure_presets
    tr ';' '\n' <<<"$rows" >"$RUN_DIR/db-rows"
    logs_unreadable=1
    run_measure
    expect_line "$expected"
done <<EOF
measureCycle_onlyTimeRowArmed_passesPrecondition|$DEFAULT_TIME_ROW|PASS cycle precondition
measureCycle_oneArmedAlertBesideTimeRow_failsPreconditionWithOne|$DEFAULT_TIME_ROW;c0000000-0000-4000-8000-000000000000,1|FAIL cycle precondition: 1 armed alerts already exist; the measurement needs none besides its own
EOF

start_test "measureCycle_acceptedSampleOverLimit_recordsFollowUpsAfterFailVerdict"
measure_presets
verify_appends[1]="$(clean_line 12000)"
poll_appends[1]="$(clean_line 1200)"
poll_appends[2]="$(clean_line 1300)"
run_measure
expect_cycle_checks "FAIL cycle < 10 s: duration 12000 ms is not below $CYCLE_LIMIT_MS ms" "PASS cycle follow-ups"

# A 25 ms cycle line logged while the owned set is verified, but stamped before T, does not
# pass the limit for the 12,000 ms first line after T.
start_test "measureCycle_fastLineBeforeT_failsLimitOnFirstLineAfterT"
measure_presets
verify_times[1]="2026-01-01T00:00:01.151857Z"
verify_appends[1]="2026-01-01T00:00:01.151856900Z $(clean_line 25)"
poll_appends[1]="$(clean_line 12000)"
poll_appends[2]="$(clean_line 1200)"
poll_appends[3]="$(clean_line 1300)"
run_measure
expect_cycle_checks "FAIL cycle < 10 s: duration 12000 ms is not below $CYCLE_LIMIT_MS ms" "PASS cycle follow-ups"

start_test "measureCycle_noAcceptedSample_skipsFollowUpCheck"
measure_presets
logs_unreadable=1
run_measure
expect_cycle_checks "FAIL cycle < 10 s: broker-service logs unreadable (see $RUN_DIR/compose.log)"

summarize
if [[ $tests_failed -ne 0 ]]; then
    exit 1
fi
