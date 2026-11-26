#!/usr/bin/env bash
# Unit tests of scripts/portfolio-insights/loadgen-check.sh. The script is sourced, which defines
# its functions without running it. Docker, Compose, HTTP and database calls are replaced by
# stubs inside each test, so no stack is needed.
#
# Usage: scripts/portfolio-insights/loadgen-check-test.sh [--help]
#   --help  Show this help and exit
#
# Every function named test_* runs in its own subshell with a fresh run directory, so the stubs
# and state of one test never reach another. The script's own PASS, FAIL and INFO lines go to
# $RUN_DIR/report for the test to assert on. Prints one PASS or FAIL line per assertion and a
# final SUMMARY line. Exits 0 when every assertion passes, 1 when any fails or a test makes no
# assertion, and 2 on a usage error or a missing tool. Temporary files are removed on exit.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
    "") ;;
    --help)
        sed -n '6,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "Unknown option: $1" >&2
        sed -n '6,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
        exit 2
        ;;
esac

for t_tool in jq awk sed comm; do
    if ! command -v "$t_tool" >/dev/null 2>&1; then
        echo "Missing required tool: $t_tool" >&2
        exit 2
    fi
done

# shellcheck source-path=SCRIPTDIR
# shellcheck source=loadgen-check.sh
source "$TEST_DIR/loadgen-check.sh"

T_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pi-loadgen-test.XXXXXX")"
trap 'rm -rf "$T_ROOT"' EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------------------------------------
# Assertions and fixtures

t_pass() {
    echo "PASS $1"
}

t_fail() {
    echo "FAIL $1: $2"
}

# t_eq NAME EXPECTED ACTUAL: PASS NAME when ACTUAL equals EXPECTED.
t_eq() {
    if [[ "$2" == "$3" ]]; then
        t_pass "$1"
    else
        t_fail "$1" "expected [$2], got [$3]"
    fi
}

# t_report_has NAME LINE: PASS NAME when the script reported exactly LINE.
t_report_has() {
    if grep -qxF -- "$2" "$RUN_DIR/report"; then
        t_pass "$1"
    else
        t_fail "$1" "no report line [$2] in [$(tr '\n' '|' <"$RUN_DIR/report")]"
    fi
}

# The script's reporting, captured in the run directory instead of stdout.
pass() {
    passed=$((passed + 1))
    echo "PASS $1" >>"$RUN_DIR/report"
}

fail() {
    failed=$((failed + 1))
    echo "FAIL $1: $2" >>"$RUN_DIR/report"
}

info() {
    echo "INFO $*" >>"$RUN_DIR/report"
}

# t_fresh_run_dir: a new run directory holding the files main() creates, and main()'s defaults.
t_fresh_run_dir() {
    RUN_DIR="$(mktemp -d "$T_ROOT/run.XXXXXX")"
    : >"$RUN_DIR/owned"
    : >"$RUN_DIR/deleted"
    : >"$RUN_DIR/new-owned"
    : >"$RUN_DIR/verdicts"
    : >"$RUN_DIR/report"
    PROJECT="pi-test"
    COMPOSE_ARGS=(-f compose.dev.yaml)
    BASE_URL="http://localhost"
    WEIGHT="1"
    MINUTES="35"
    OUT_FILE="$RUN_DIR/loadgen-families.md"
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
    WINDOW_LABEL=""
    WINDOW_SINCE=""
    LOADGEN_PAUSED=0
    TABLE_WRITTEN=0
    PROBE_DEADLINE=""
    LOG_PROBE_DETAIL=""
    STARTED_AT="2026-01-01T00:00:00Z"
}

# ---------------------------------------------------------------------------------------------
# Run-B drain and owned-id audit (quiescent, creates_in_flight, observe_window, audit_owned_ids)

# Fixture ids, all invented.
T_DRAIN_ALERT_1="0a1b2c3d-0000-4000-8000-000000000001"
T_DRAIN_ALERT_2="0a1b2c3d-0000-4000-8000-000000000002"
T_DRAIN_RUN_1="5e1f2a3b-0000-4000-8000-00000000000a"
T_DRAIN_RUN_2="5e1f2a3b-0000-4000-8000-00000000000b"
# A window's first line, of another family's visit, which no other fixture line repeats.
T_DRAIN_FIRST_LINE="[2026-01-01 00:00:05+00:00][worker:1][INFO]: Running visit [deposit_and_buy]"
# 2026-01-01T00:00:00Z, where the fake clock of t_drain_stubs starts.
T_DRAIN_CLOCK_START=1767225600

# t_drain_line RUN MESSAGE: a line of portfolio_insights_alert visit RUN as loadgen-core logs it.
t_drain_line() {
    echo "[2026-01-01 00:00:10+00:00][worker:0][visit:$VISIT][id:$1][INFO]: $2"
}

# t_drain_opened RUN: visit RUN starts and opens the page.
t_drain_opened() {
    echo "[2026-01-01 00:00:09+00:00][worker:0][INFO]: Running visit [$VISIT]"
    t_drain_line "$1" "Opening portfolio insights page"
}

# t_drain_created RUN ID: visit RUN opens the page and creates alert ID.
t_drain_created() {
    t_drain_opened "$1"
    t_drain_line "$1" "Created alert [$2] threshold [1000000.40271936]"
}

# t_drain_resolved RUN ID HOW: visit RUN creates alert ID and resolves it HOW: ui, api or absent.
t_drain_resolved() {
    t_drain_created "$1" "$2"
    if [[ "$3" == "absent" ]]; then
        t_drain_line "$1" "Alert [$2] already absent"
    else
        t_drain_line "$1" "Deleted alert [$2] via $3"
    fi
}

# t_drain_stubs: replaces the clock, Compose, loadgen's output and the database of the drain and
# the audit, in the calling test's subshell only.
#   - date -u +%s and now_rfc3339 read the fake clock in $RUN_DIR/clock; sleep advances it.
#   - compose appends its arguments to $RUN_DIR/compose.calls and fails for a subcommand listed
#     in $RUN_DIR/compose.fail. compose_within, the bounded form the stop, pause, unpause and
#     kill use, runs compose without the time limit, which harness-test.sh covers.
#   - loadgen_logs prints $RUN_DIR/logs.N on its Nth read, the highest N there is from then on,
#     and $RUN_DIR/logs.final, when it exists, once Compose has stopped or killed loadgen. A
#     fixture holding the line !unreadable makes the read fail with the LOG_PROBE_DETAIL the
#     real read sets for a log Docker could not give.
#   - db_query appends its SQL to $RUN_DIR/db.sql and prints the count in $RUN_DIR/db.count.
t_drain_stubs() {
    echo "$T_DRAIN_CLOCK_START" >"$RUN_DIR/clock"
    echo 0 >"$RUN_DIR/logs.n"
    echo 0 >"$RUN_DIR/db.count"
    : >"$RUN_DIR/compose.calls"
    : >"$RUN_DIR/compose.fail"
    : >"$RUN_DIR/db.sql"
    date() {
        if [[ "$*" == "-u +%s" ]]; then
            cat "$RUN_DIR/clock"
        elif [[ "$*" == "-u +%Y-%m-%dT%H:%M:%SZ" ]]; then
            epoch_to_rfc3339 "$(cat "$RUN_DIR/clock")"
        else
            command date "$@"
        fi
    }
    sleep() {
        echo $(($(cat "$RUN_DIR/clock") + $1)) >"$RUN_DIR/clock"
    }
    compose() {
        echo "$*" >>"$RUN_DIR/compose.calls"
        ! grep -qxF -- "$1" "$RUN_DIR/compose.fail"
    }
    compose_within() {
        shift
        compose "$@"
    }
    loadgen_logs() {
        local n file
        n=$(($(cat "$RUN_DIR/logs.n") + 1))
        echo "$n" >"$RUN_DIR/logs.n"
        while [[ ! -f "$RUN_DIR/logs.$n" && $n -gt 1 ]]; do
            n=$((n - 1))
        done
        file="$RUN_DIR/logs.$n"
        if [[ -f "$RUN_DIR/logs.final" ]] && grep -qE '^(stop|kill) ' "$RUN_DIR/compose.calls"; then
            file="$RUN_DIR/logs.final"
        fi
        LOG_PROBE_DETAIL=""
        if grep -qxF '!unreadable' "$file"; then
            LOG_PROBE_DETAIL="loadgen logs unreadable, exit 1 (see $RUN_DIR/compose.log)"
            return 1
        fi
        cat "$file"
    }
    db_query() {
        echo "$1" >>"$RUN_DIR/db.sql"
        cat "$RUN_DIR/db.count"
    }
}

# t_drain_window: run B's log window, open as run_window leaves it for audit_owned_ids.
t_drain_window() {
    WINDOW_LABEL="B"
    WINDOW_OPEN=1
    WINDOW_START="2026-01-01T00:00:00Z"
    WINDOW_SINCE="2026-01-01T00:00:00Z"
    DIALECT="postgres"
}

# t_drain_calls: the Compose commands run so far, separated by |.
t_drain_calls() {
    paste -s -d '|' "$RUN_DIR/compose.calls" | tr -d '\r'
}

# t_drain_queried: the alert ids the owned-id rows query asked the database about.
t_drain_queried() {
    { grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$RUN_DIR/db.sql" || true; } |
        join_lines
}

# t_drain_owned: the ids owned for deletion on exit, sorted and unique.
t_drain_owned() {
    LC_ALL=C sort -u "$RUN_DIR/owned" | join_lines
}

# t_drain_checks: the PASS and FAIL lines the script reported, separated by |.
t_drain_checks() {
    { grep -E '^(PASS|FAIL) ' "$RUN_DIR/report" || true; } | paste -s -d '|' - | tr -d '\r'
}

test_audit_owned_ids_allClean_passesEveryCheck() {
    t_drain_stubs
    t_drain_window
    {
        t_drain_resolved "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" ui
        t_drain_resolved "$T_DRAIN_RUN_2" "$T_DRAIN_ALERT_2" api
    } >"$RUN_DIR/logs.1"
    audit_owned_ids
    t_eq "audit_owned_ids passes every owned-id check of a clean final output" \
        "PASS owned-id quiescence: Q at 2026-01-01T00:00:01Z with 2 created alerts, all resolved, and no create in flight; loadgen killed while paused|PASS run B loadgen stopped|PASS owned-id evidence: the final output keeps every created id, resolution and first line an earlier read saw|PASS owned-id audit: 2 created alerts, each deleted via ui, via api or already absent|PASS owned-id in flight: every visit that opened the page logged a create outcome|PASS owned-id outcomes: 0 lines report an alert left in place or an unknown outcome since 2026-01-01T00:00:00Z|PASS owned-id created: 2 alerts created in run B|PASS owned-id rows: no Alerts row carries any of the 2 created ids" \
        "$(t_drain_checks)"
    t_eq "audit_owned_ids stops loadgen only by the kill of the paused container at Q" \
        "pause loadgen|kill -s SIGKILL loadgen" "$(t_drain_calls)"
}

test_audit_owned_ids_createLoggedAfterLastRunningRead_judgedOnFinalSet() {
    t_drain_stubs
    t_drain_window
    t_drain_resolved "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" ui >"$RUN_DIR/logs.1"
    # Logged between the last running read and the pause: only the frozen and final output hold
    # the second create.
    {
        cat "$RUN_DIR/logs.1"
        t_drain_resolved "$T_DRAIN_RUN_2" "$T_DRAIN_ALERT_2" absent
    } >"$RUN_DIR/logs.2"
    audit_owned_ids
    t_eq "audit_owned_ids queries the rows of the create logged after the last running read" \
        "$T_DRAIN_ALERT_1 $T_DRAIN_ALERT_2" "$(t_drain_queried)"
    t_report_has "audit_owned_ids judges the resolution of the create logged after the last running read" \
        "PASS owned-id audit: 2 created alerts, each deleted via ui, via api or already absent"
    t_report_has "audit_owned_ids counts the create logged after the last running read" \
        "PASS owned-id created: 2 alerts created in run B"
}

test_audit_owned_ids_quiescenceDeadlineExpired_failsAndOwnsFinalSet() {
    t_drain_stubs
    t_drain_window
    t_drain_created "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" >"$RUN_DIR/logs.1"
    # The stop at the deadline follows one more create, which no running read saw.
    {
        cat "$RUN_DIR/logs.1"
        t_drain_created "$T_DRAIN_RUN_2" "$T_DRAIN_ALERT_2"
    } >"$RUN_DIR/logs.final"
    echo 2 >"$RUN_DIR/db.count"
    audit_owned_ids
    t_report_has "audit_owned_ids fails quiescence at the deadline" \
        "FAIL owned-id quiescence: not quiescent within 180s: unresolved: $T_DRAIN_ALERT_1; ownership cannot be established"
    t_eq "audit_owned_ids still stops loadgen after the deadline" "stop --timeout 0 loadgen" "$(t_drain_calls)"
    t_report_has "audit_owned_ids fails the audit with every unresolved create of the final output" \
        "FAIL owned-id audit: not resolved by loadgen, deleted on exit: $T_DRAIN_ALERT_1 $T_DRAIN_ALERT_2"
    t_eq "audit_owned_ids owns every unresolved create of the final output" \
        "$T_DRAIN_ALERT_1 $T_DRAIN_ALERT_2" "$(t_drain_owned)"
    t_eq "audit_owned_ids queries the rows of the whole final set" \
        "$T_DRAIN_ALERT_1 $T_DRAIN_ALERT_2" "$(t_drain_queried)"
}

test_audit_owned_ids_finalOutputWithOpenedVisit_failsInFlight() {
    t_drain_stubs
    t_drain_window
    t_drain_resolved "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" ui >"$RUN_DIR/logs.1"
    # The final output holds a visit that opened the page and logged no create outcome.
    {
        cat "$RUN_DIR/logs.1"
        t_drain_opened "$T_DRAIN_RUN_2"
    } >"$RUN_DIR/logs.final"
    audit_owned_ids
    t_report_has "audit_owned_ids fails a visit of the final output that has no create outcome" \
        "FAIL owned-id in flight: 1 visits opened the page and logged no create outcome, so their alerts cannot be tied to an id"
}

test_audit_owned_ids_rowsRemaining_failsAndOwnsIds() {
    t_drain_stubs
    t_drain_window
    {
        t_drain_resolved "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" ui
        t_drain_resolved "$T_DRAIN_RUN_2" "$T_DRAIN_ALERT_2" api
    } >"$RUN_DIR/logs.1"
    echo 1 >"$RUN_DIR/db.count"
    audit_owned_ids
    t_report_has "audit_owned_ids fails when an Alerts row remains" \
        "FAIL owned-id rows: 1 of 2 created ids still have an Alerts row; they are deleted on exit"
    t_eq "audit_owned_ids owns the counted ids for deletion on exit" \
        "$T_DRAIN_ALERT_1 $T_DRAIN_ALERT_2" "$(t_drain_owned)"
}

test_audit_owned_ids_countQueryFails_failsRows() {
    t_drain_stubs
    t_drain_window
    t_drain_resolved "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" ui >"$RUN_DIR/logs.1"
    db_query() {
        echo "psql: connection refused" >>"$RUN_DIR/db-error.log"
        return 1
    }
    audit_owned_ids
    t_report_has "audit_owned_ids fails the rows check when the count query fails" \
        "FAIL owned-id rows: count query failed: psql: connection refused"
}

test_audit_owned_ids_noCreate_failsCreatedAndSkipsRows() {
    t_drain_stubs
    t_drain_window
    {
        t_drain_opened "$T_DRAIN_RUN_1"
        t_drain_line "$T_DRAIN_RUN_1" "Alert instrument options did not load, no alert created"
    } >"$RUN_DIR/logs.1"
    audit_owned_ids
    t_report_has "audit_owned_ids fails a run B without a create" \
        "FAIL owned-id created: 0 alerts created in run B; the visit never created an alert"
    t_report_has "audit_owned_ids skips the rows query without a created id" \
        "INFO owned-id rows: skipped, no created id to count"
    t_eq "audit_owned_ids queries no row without a created id" "" "$(t_drain_queried)"
}

test_creates_in_flight_noCreateOutcome_closesWindow() {
    local outcome
    # The visit's no-create outcomes while the feature is lost, logged before the worker's error
    # line for the failed visit arrives.
    for outcome in "Portfolio insights page unavailable, no alert created" \
        "Portfolio insights feature lost before submit, no alert created"; do
        t_fresh_run_dir
        {
            t_drain_opened "$T_DRAIN_RUN_1"
            t_drain_line "$T_DRAIN_RUN_1" "$outcome"
        } >"$RUN_DIR/B.log"
        t_eq "creates_in_flight counts no visit in flight after [$outcome]" 0 \
            "$(creates_in_flight "$RUN_DIR/B.log")"
    done
}

test_drain_loadgen_frozenOutputNotQuiescent_unpausesAndRetries() {
    local rc=0
    t_drain_stubs
    t_drain_window
    t_drain_resolved "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" ui >"$RUN_DIR/logs.1"
    # A visit opens the page between the running read and the pause, so both frozen reads show a
    # create in flight; the visit completes once loadgen runs on.
    {
        cat "$RUN_DIR/logs.1"
        t_drain_opened "$T_DRAIN_RUN_2"
    } >"$RUN_DIR/logs.2"
    cp "$RUN_DIR/logs.2" "$RUN_DIR/logs.3"
    {
        cat "$RUN_DIR/logs.2"
        t_drain_line "$T_DRAIN_RUN_2" "Created alert [$T_DRAIN_ALERT_2] threshold [1000000.40271936]"
        t_drain_line "$T_DRAIN_RUN_2" "Deleted alert [$T_DRAIN_ALERT_2] via ui"
    } >"$RUN_DIR/logs.4"
    drain_loadgen || rc=$?
    t_eq "drain_loadgen reaches Q after a frozen output that is not quiescent" 0 "$rc"
    t_eq "drain_loadgen unpauses loadgen, then pauses and kills it" \
        "pause loadgen|unpause loadgen|pause loadgen|kill -s SIGKILL loadgen" "$(t_drain_calls)"
    t_eq "drain_loadgen describes Q after the retry" \
        "Q at 2026-01-01T00:00:07Z with 2 created alerts, all resolved, and no create in flight; loadgen killed while paused" \
        "$DRAIN_DETAIL"
}

# t_drain_failure CASE PAUSED DETAIL: drain_loadgen in a fresh run directory fails with DETAIL,
# in which @RUN_DIR@ stands for that directory, and leaves LOADGEN_PAUSED at PAUSED. CASE logs
# makes every read of loadgen's output fail; pause, kill and unpause make that Compose
# subcommand fail.
t_drain_failure() {
    (
        local rc=0
        t_fresh_run_dir
        t_drain_stubs
        t_drain_window
        t_drain_resolved "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" ui >"$RUN_DIR/logs.1"
        case "$1" in
            logs)
                echo '!unreadable' >"$RUN_DIR/logs.1"
                ;;
            unpause)
                echo unpause >"$RUN_DIR/compose.fail"
                {
                    cat "$RUN_DIR/logs.1"
                    t_drain_opened "$T_DRAIN_RUN_2"
                } >"$RUN_DIR/logs.2"
                ;;
            *)
                echo "$1" >"$RUN_DIR/compose.fail"
                ;;
        esac
        drain_loadgen || rc=$?
        t_eq "drain_loadgen fails when $1 fails" 1 "$rc"
        t_eq "drain_loadgen detail when $1 fails" "${3//@RUN_DIR@/$RUN_DIR}" "$DRAIN_DETAIL"
        t_eq "drain_loadgen LOADGEN_PAUSED when $1 fails" "$2" "$LOADGEN_PAUSED"
    )
}

test_drain_loadgen_failurePaths_failWithDetail() {
    t_drain_failure logs 0 "not quiescent within 180s: loadgen logs unreadable, exit 1 (see @RUN_DIR@/compose.log)"
    t_drain_failure pause 1 "pausing loadgen failed, exit 1 (see @RUN_DIR@/compose.log)"
    t_drain_failure kill 1 "killing the paused loadgen failed, exit 1 (see @RUN_DIR@/compose.log)"
    t_drain_failure unpause 1 "paused: 1 visits between opening the page and their create outcome; unpausing loadgen failed, exit 1 (see @RUN_DIR@/compose.log)"
}

# t_frozen_failure CASE DETAIL: frozen_log in a fresh run directory fails with DETAIL, in which
# @RUN_DIR@ stands for that directory. CASE unsettled gives every read one line more than the
# read before; unreadable makes every read fail.
t_frozen_failure() {
    (
        local rc=0
        t_fresh_run_dir
        t_drain_stubs
        t_drain_window
        if [[ "$1" == "unreadable" ]]; then
            echo '!unreadable' >"$RUN_DIR/logs.1"
        else
            # shellcheck disable=SC2329 # Invoked by frozen_log through read_window.
            loadgen_logs() {
                local n
                n=$(($(cat "$RUN_DIR/logs.n") + 1))
                echo "$n" >"$RUN_DIR/logs.n"
                seq "$n"
            }
        fi
        frozen_log || rc=$?
        t_eq "frozen_log fails when the output is $1" 1 "$rc"
        t_eq "frozen_log detail when the output is $1" "${2//@RUN_DIR@/$RUN_DIR}" "$POLL_DETAIL"
    )
}

test_frozen_log_outputUnsettledOrUnreadable_fails() {
    t_frozen_failure unsettled "paused loadgen's output still changing after 10s"
    t_frozen_failure unreadable "reading the paused loadgen's output: loadgen logs unreadable, exit 1 (see @RUN_DIR@/compose.log)"
}

# t_stop_case PAUSED CALLS: stop_loadgen with LOADGEN_PAUSED at PAUSED runs exactly CALLS and
# leaves LOADGEN_PAUSED at 0.
t_stop_case() {
    (
        t_fresh_run_dir
        t_drain_stubs
        LOADGEN_PAUSED="$1"
        stop_loadgen
        t_eq "stop_loadgen with LOADGEN_PAUSED=$1 runs [$2]" "$2" "$(t_drain_calls)"
        t_eq "stop_loadgen with LOADGEN_PAUSED=$1 leaves it 0" 0 "$LOADGEN_PAUSED"
    )
}

test_stop_loadgen_pauseState_killsPausedAndStopsRunning() {
    t_stop_case 1 "kill -s SIGKILL loadgen"
    t_stop_case 0 "stop --timeout 0 loadgen"
}

test_close_window_interruptedWhilePaused_killsAndOwnsUnresolved() {
    t_drain_stubs
    t_drain_window
    LOADGEN_PAUSED=1
    t_drain_created "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" >"$RUN_DIR/logs.1"
    # What cleanup runs for a window still open on an interrupt.
    close_window
    t_eq "close_window kills a paused loadgen without thawing it" \
        "kill -s SIGKILL loadgen" "$(t_drain_calls)"
    t_eq "close_window owns the unresolved create of the paused loadgen's output" \
        "$T_DRAIN_ALERT_1" "$(t_drain_owned)"
}

test_observe_window_successiveReads_unionsIdsAndKeepsFirstLine() {
    WINDOW_LABEL="B"
    : >"$RUN_DIR/read.0"
    {
        echo "$T_DRAIN_FIRST_LINE"
        t_drain_resolved "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" ui
    } >"$RUN_DIR/read.1"
    # A later read after log rotation: the first read's lines are gone.
    t_drain_created "$T_DRAIN_RUN_2" "$T_DRAIN_ALERT_2" >"$RUN_DIR/read.2"
    observe_window "$RUN_DIR/read.0"
    t_eq "observe_window records no first line from an empty read" \
        "" "$(cat "$RUN_DIR/observed-first-B")"
    observe_window "$RUN_DIR/read.1"
    observe_window "$RUN_DIR/read.2"
    observe_window "$RUN_DIR/read.1"
    t_eq "observed_ids holds the created ids of every read, each once" \
        "$T_DRAIN_ALERT_1 $T_DRAIN_ALERT_2" "$(observed_ids created | join_lines)"
    t_eq "observed_ids holds the resolutions of every read" \
        "$T_DRAIN_ALERT_1" "$(observed_ids resolved | join_lines)"
    t_eq "observe_window keeps the first line of the first read holding a line" \
        "$T_DRAIN_FIRST_LINE" "$(cat "$RUN_DIR/observed-first-B")"
    WINDOW_LABEL="A"
    t_eq "observed_ids of a window no read was observed for is empty" \
        "" "$(observed_ids created | join_lines)"
}

test_window_started_firstRead_recordsFirstLineAndIds() {
    t_drain_stubs
    t_drain_window
    {
        echo "$T_DRAIN_FIRST_LINE"
        t_drain_created "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1"
    } >"$RUN_DIR/logs.1"
    window_started
    t_eq "window_started records the first line of start.log as the window's first line" \
        "$T_DRAIN_FIRST_LINE" "$(cat "$RUN_DIR/observed-first-B")"
    t_eq "window_started records the created ids of start.log" \
        "$T_DRAIN_ALERT_1" "$(observed_ids created | join_lines)"
}

test_watch_progress_progressRead_recordsObservedIds() {
    t_drain_stubs
    t_drain_window
    WINDOW_START_EPOCH="$T_DRAIN_CLOCK_START"
    t_drain_resolved "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" api >"$RUN_DIR/logs.1"
    # Two steps: the read due at the window's end is skipped, so the first step's read is the
    # one observed.
    watch_progress B $((T_DRAIN_CLOCK_START + 2 * PROGRESS_STEP_SECONDS))
    t_eq "watch_progress records the created ids of its read" \
        "$T_DRAIN_ALERT_1" "$(observed_ids created | join_lines)"
    t_eq "watch_progress records the resolutions of its read" \
        "$T_DRAIN_ALERT_1" "$(observed_ids resolved | join_lines)"
}

test_drain_loadgen_runningAndFrozenReads_recordObservedIds() {
    t_drain_stubs
    t_drain_window
    # The running read and the frozen reads each hold an id the other lacks.
    t_drain_resolved "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" ui >"$RUN_DIR/logs.1"
    t_drain_resolved "$T_DRAIN_RUN_2" "$T_DRAIN_ALERT_2" api >"$RUN_DIR/logs.2"
    drain_loadgen
    t_eq "drain_loadgen records the created ids of its running and frozen reads" \
        "$T_DRAIN_ALERT_1 $T_DRAIN_ALERT_2" "$(observed_ids created | join_lines)"
    t_eq "drain_loadgen records the resolutions of its running and frozen reads" \
        "$T_DRAIN_ALERT_1 $T_DRAIN_ALERT_2" "$(observed_ids resolved | join_lines)"
}

test_audit_owned_ids_finalOutputLostResolvedCreate_failsEvidenceAndRows() {
    t_drain_stubs
    t_drain_window
    {
        echo "$T_DRAIN_FIRST_LINE"
        t_drain_resolved "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" ui
        t_drain_resolved "$T_DRAIN_RUN_2" "$T_DRAIN_ALERT_2" api
    } >"$RUN_DIR/logs.1"
    # Log rotation dropped the first visit's lines before the final read.
    t_drain_resolved "$T_DRAIN_RUN_2" "$T_DRAIN_ALERT_2" api >"$RUN_DIR/logs.final"
    echo 1 >"$RUN_DIR/db.count"
    audit_owned_ids
    t_report_has "audit_owned_ids fails the evidence a lost create leaves" \
        "FAIL owned-id evidence: the final output lost lines an earlier read saw (log rotation): 1 created ids and 1 resolutions missing, first line missing, so not every create can be proven"
    t_report_has "audit_owned_ids judges the resolution of the lost create" \
        "PASS owned-id audit: 2 created alerts, each deleted via ui, via api or already absent"
    t_report_has "audit_owned_ids counts the lost create" \
        "PASS owned-id created: 2 alerts created in run B"
    t_eq "audit_owned_ids queries the rows of the lost create" \
        "$T_DRAIN_ALERT_1 $T_DRAIN_ALERT_2" "$(t_drain_queried)"
    t_report_has "audit_owned_ids fails the rows check of the lost create" \
        "FAIL owned-id rows: 1 of 2 created ids still have an Alerts row; they are deleted on exit"
    t_eq "audit_owned_ids owns the lost create for deletion on exit" \
        "$T_DRAIN_ALERT_1 $T_DRAIN_ALERT_2" "$(t_drain_owned)"
}

test_audit_owned_ids_finalOutputLostUnresolvedCreate_judgesAndOwnsIt() {
    t_drain_stubs
    t_drain_window
    {
        echo "$T_DRAIN_FIRST_LINE"
        t_drain_created "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1"
    } >"$RUN_DIR/logs.1"
    # The stop at the quiescence deadline follows log rotation, which dropped the unresolved
    # create from the final read.
    t_drain_resolved "$T_DRAIN_RUN_2" "$T_DRAIN_ALERT_2" ui >"$RUN_DIR/logs.final"
    audit_owned_ids
    t_report_has "audit_owned_ids fails the evidence of an unresolved create the final read lost" \
        "FAIL owned-id evidence: the final output lost lines an earlier read saw (log rotation): 1 created ids and 0 resolutions missing, first line missing, so not every create can be proven"
    t_report_has "audit_owned_ids fails the audit with the lost unresolved create" \
        "FAIL owned-id audit: not resolved by loadgen, deleted on exit: $T_DRAIN_ALERT_1"
    t_eq "audit_owned_ids queries the rows of the lost unresolved create" \
        "$T_DRAIN_ALERT_1 $T_DRAIN_ALERT_2" "$(t_drain_queried)"
    t_eq "audit_owned_ids owns the lost unresolved create for deletion on exit" \
        "$T_DRAIN_ALERT_1" "$(t_drain_owned)"
}

# t_first_line_case CASE LINE: audit_owned_ids, in a fresh run directory, of a run B whose
# running read begins with T_DRAIN_FIRST_LINE, whose frozen reads add a later create, and whose
# final read keeps every id and, for CASE kept, that first line too. It reports LINE as its
# owned-id evidence check.
t_first_line_case() {
    (
        t_fresh_run_dir
        t_drain_stubs
        t_drain_window
        {
            echo "$T_DRAIN_FIRST_LINE"
            t_drain_resolved "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" ui
        } >"$RUN_DIR/logs.1"
        {
            cat "$RUN_DIR/logs.1"
            t_drain_resolved "$T_DRAIN_RUN_2" "$T_DRAIN_ALERT_2" absent
        } >"$RUN_DIR/logs.2"
        if [[ "$1" == "kept" ]]; then
            cp "$RUN_DIR/logs.2" "$RUN_DIR/logs.final"
        else
            grep -vxF -- "$T_DRAIN_FIRST_LINE" "$RUN_DIR/logs.2" >"$RUN_DIR/logs.final"
        fi
        audit_owned_ids
        t_report_has "audit_owned_ids evidence of a final read with its first line $1" "$2"
    )
}

test_audit_owned_ids_finalOutputFirstLine_judgesEvidence() {
    t_first_line_case kept \
        "PASS owned-id evidence: the final output keeps every created id, resolution and first line an earlier read saw"
    t_first_line_case missing \
        "FAIL owned-id evidence: the final output lost lines an earlier read saw (log rotation): 0 created ids and 0 resolutions missing, first line missing, so not every create can be proven"
}

test_close_window_finalOutputLostObservedCreate_ownsIt() {
    t_drain_stubs
    t_drain_window
    t_drain_created "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" >"$RUN_DIR/logs.1"
    # An interrupt after log rotation dropped the unresolved create from the final read.
    t_drain_resolved "$T_DRAIN_RUN_2" "$T_DRAIN_ALERT_2" ui >"$RUN_DIR/logs.final"
    read_window "$RUN_DIR/progress.log"
    # What cleanup runs for a window still open on an interrupt.
    close_window
    report_new_owned "cleanup"
    t_eq "close_window owns the unresolved create only an earlier read saw" \
        "$T_DRAIN_ALERT_1" "$(t_drain_owned)"
    t_report_has "report_new_owned names the create only an earlier read saw" \
        "INFO cleanup: alert [$T_DRAIN_ALERT_1] was logged as created and never resolved by loadgen; it is deleted on exit"
}

# ---------------------------------------------------------------------------------------------
# Loadgen log sanitizing (loadgen_logs)

# Fixture values, all invented: no preset password ever appears in a fixture.
T_LOG_SECRET="pi-test-not-a-password"
T_LOG_STAMP="[2026-01-01 00:05:00+00:00]"
T_LOG_ID="2b9d6f1e-7c4a-4e3b-8d2f-6a1c9e0b7d53"
T_LOG_TAGS="[worker:2][visit:portfolio_insights_alert][id:5f0c2a6e-3b1d-4c8e-9a7f-1e2d3c4b5a69]"
T_LOG_BREAKDOWN='{"deposit_and_buy_success":{"total":11,"avgDurationMs":20345.5,"failRate":0},'\
'"portfolio_insights_alert":{"total":3,"avgDurationMs":1520,"failRate":5.551115123125783e-17}}'
# The cumulative stats line of loadgen-core 1.3.36 (statsRunner.js) for T_LOG_BREAKDOWN, and the
# two timeframe lines that follow it.
T_LOG_CUMULATIVE="${T_LOG_STAMP}[stats:runner][INFO]: The loadgen has been running since [Thu, 01 Jan 2026 00:00:00 GMT] and generated [14] visits with fail rate [0.00] and a rate of [2.80/m], detailed breakdown [$T_LOG_BREAKDOWN]"
T_LOG_LAST_5M="${T_LOG_STAMP}[stats:runner][INFO]: In the last [5m] loadgen has generated [14] visits with fail rate [0.00] and a rate of [2.80/m], detailed breakdown [$T_LOG_BREAKDOWN]"
T_LOG_LAST_1H="${T_LOG_STAMP}[stats:runner][INFO]: In the last [1h] loadgen has generated [0] visits with fail rate [0.00] and a rate of [0.00/m], detailed breakdown [{}]"

# t_loadgen_output LINE...: stubs compose so that "compose logs" prints the LINEs as raw loadgen
# output, each wrapped in colour codes and ended with a carriage return. loadgen_logs reads
# through compose_within, which runs that stub here without the time limit.
t_loadgen_output() {
    local line
    for line in "$@"; do
        printf '\033[32m%s\033[39m\r\n' "$line"
    done >"$RUN_DIR/loadgen.raw"
    # shellcheck disable=SC2329 # Invoked by loadgen_logs through compose_within.
    compose() {
        if [[ "$1" == "logs" ]]; then
            cat "$RUN_DIR/loadgen.raw"
        fi
    }
    # shellcheck disable=SC2329 # Invoked by loadgen_logs.
    compose_within() {
        shift
        compose "$@"
    }
}

test_loadgen_logs_unreadLine_dropped() {
    local i out
    local -a scenarios=(
        "a DEBUG input value"
        "a login line"
        "an allow-listed message at HTTP level"
        "an unknown INFO message"
        "an untagged line"
        "a continuation line"
        "a browser pool line"
        "a stats line with a text field"
        "a running line with an invalid visit name"
        "a visit error with an invalid visit tag"
        "a created line with a malformed id"
        "a created line with a text marker"
        "an allow-listed message with trailing text"
    )
    local -a lines=(
        "$T_LOG_STAMP${T_LOG_TAGS}[DEBUG]: action [inputHandle] for handle [//input[@id=\"password\"]] with value [$T_LOG_SECRET]"
        "$T_LOG_STAMP${T_LOG_TAGS}[INFO]: Logging in as user [x]"
        "$T_LOG_STAMP${T_LOG_TAGS}[HTTP]: Opening portfolio insights page"
        "$T_LOG_STAMP${T_LOG_TAGS}[INFO]: Typed [$T_LOG_SECRET]"
        "[INFO]: Opening portfolio insights page"
        "    at login (value $T_LOG_SECRET)"
        "${T_LOG_STAMP}[pool:main][INFO]: Started [1/1] browsers with pids [[19]]"
        "${T_LOG_STAMP}[stats:runner][INFO]: The loadgen has been running since [Thu, 01 Jan 2026 00:00:00 GMT] and generated [1] visits with fail rate [0.00] and a rate of [0.20/m], detailed breakdown [{\"x\":{\"total\":1,\"note\":\"$T_LOG_SECRET\",\"failRate\":0}}]"
        "${T_LOG_STAMP}[worker:2][INFO]: Running visit [$T_LOG_SECRET]"
        "${T_LOG_STAMP}[worker:2][visit:$T_LOG_SECRET][id:5f0c2a6e-3b1d-4c8e-9a7f-1e2d3c4b5a69][WARN]: Worker had error when running visit: [Error]"
        "$T_LOG_STAMP${T_LOG_TAGS}[INFO]: Created alert [$T_LOG_SECRET] threshold [1000000.40271936]"
        "$T_LOG_STAMP${T_LOG_TAGS}[INFO]: Created alert [$T_LOG_ID] threshold [$T_LOG_SECRET]"
        "$T_LOG_STAMP${T_LOG_TAGS}[INFO]: Opening portfolio insights page $T_LOG_SECRET"
    )
    for i in "${!lines[@]}"; do
        t_fresh_run_dir
        t_loadgen_output "${lines[$i]}"
        out="$(loadgen_logs 2026-01-01T00:00:00Z)"
        t_eq "loadgen_logs drops ${scenarios[$i]}" "" "$out"
    done
}

test_loadgen_logs_allowListedLine_keptByteExact() {
    local line out message
    # The messages as src/loadgen/src/helpers/portfolioInsights.ts, visits/portfolioInsightsAlert.ts
    # and loadgen-core print them.
    local -a lines=(
        "${T_LOG_STAMP}[worker:2][INFO]: Running visit [portfolio_insights_alert]"
        "$T_LOG_STAMP${T_LOG_TAGS}[INFO]: Flag [portfolio-insights-enabled] is off, skipping portfolio insights visit"
        "$T_LOG_STAMP${T_LOG_TAGS}[INFO]: Opening portfolio insights page"
        "$T_LOG_STAMP${T_LOG_TAGS}[WARN]: Alert instrument options did not load, no alert created"
        "$T_LOG_STAMP${T_LOG_TAGS}[WARN]: Portfolio insights page unavailable, no alert created"
        "$T_LOG_STAMP${T_LOG_TAGS}[WARN]: Portfolio insights feature lost before submit, no alert created"
        "$T_LOG_STAMP${T_LOG_TAGS}[INFO]: Created alert [$T_LOG_ID] threshold [1000000.40271936]"
        "$T_LOG_STAMP${T_LOG_TAGS}[WARN]: Create unconfirmed threshold [1000000.40271936], outcome unknown"
        "$T_LOG_STAMP${T_LOG_TAGS}[INFO]: Deleted alert [$T_LOG_ID] via ui"
        "$T_LOG_STAMP${T_LOG_TAGS}[INFO]: Deleted alert [$T_LOG_ID] via api"
        "$T_LOG_STAMP${T_LOG_TAGS}[INFO]: Alert [$T_LOG_ID] already absent"
        "$T_LOG_STAMP${T_LOG_TAGS}[WARN]: Alert [$T_LOG_ID] left in place: 403"
        "$T_LOG_STAMP${T_LOG_TAGS}[ERROR]: Worker had error when running visit"
        "$T_LOG_CUMULATIVE"
        "$T_LOG_LAST_5M"
        "$T_LOG_LAST_1H"
    )
    for line in "${lines[@]}"; do
        t_fresh_run_dir
        t_loadgen_output "$line"
        out="$(loadgen_logs 2026-01-01T00:00:00Z)"
        message="${line#*]: }"
        t_eq "loadgen_logs keeps [${message:0:60}] byte for byte" "$line" "$out"
    done
}

test_loadgen_logs_visitErrorWithSecret_projectedAndCounted() {
    local tags="[worker:1][visit:deposit_and_buy_success][id:0e5a7c3b-9d2f-4b6a-8c1e-3f7d9b2a6c40]"
    t_loadgen_output \
        "$T_LOG_STAMP${tags}[WARN]: Worker had error when running visit: [Error: login refused for $T_LOG_SECRET]" \
        "$T_LOG_STAMP${tags}[WARN]: Worker had error when running visit: [TimeoutError: Waiting for selector failed]"
    t_eq "error_counts counts both projected visit errors" "2 deposit_and_buy_success" \
        "$(error_counts 2026-01-01T00:00:00Z)"
    t_eq "loadgen_logs keeps the visit error without its detail" \
        "$T_LOG_STAMP${tags}[WARN]: Worker had error when running visit" \
        "$(sed -n '1p' "$RUN_DIR/errors.log")"
    t_eq "loadgen_logs keeps no secret of a visit error" 0 \
        "$(grep -c -F "$T_LOG_SECRET" "$RUN_DIR/errors.log" || true)"
}

test_loadgen_logs_leftInPlaceStatus_projectedToToken() {
    local c status token out
    # STATUS;TOKEN: the visit logged STATUS, the sanitized line carries TOKEN.
    for c in "timeout;timeout" "error;error" "4031;error" "$T_LOG_SECRET;error" \
        "connect ECONNREFUSED 10.0.0.7:8080;error"; do
        IFS=';' read -r status token <<<"$c"
        t_fresh_run_dir
        t_loadgen_output "$T_LOG_STAMP${T_LOG_TAGS}[WARN]: Alert [$T_LOG_ID] left in place: $status"
        out="$(loadgen_logs 2026-01-01T00:00:00Z)"
        t_eq "loadgen_logs reduces left-in-place status [$status] to $token" \
            "$T_LOG_STAMP${T_LOG_TAGS}[WARN]: Alert [$T_LOG_ID] left in place: $token" "$out"
    done
}

test_extract_breakdown_sanitizedStatsLine_parsesBreakdown() {
    t_loadgen_output \
        "${T_LOG_STAMP}[worker:0][INFO]: Running visit [deposit_and_buy_success]" \
        "${T_LOG_STAMP}[worker:0][visit:deposit_and_buy_success][id:0e5a7c3b-9d2f-4b6a-8c1e-3f7d9b2a6c40][DEBUG]: action [inputHandle] for handle [x] with value [$T_LOG_SECRET]" \
        "$T_LOG_CUMULATIVE" "$T_LOG_LAST_5M" "$T_LOG_LAST_1H"
    loadgen_logs 2026-01-01T00:00:00Z >"$RUN_DIR/stats.log"
    t_eq "extract_breakdown parses the sanitized cumulative stats line" "$T_LOG_BREAKDOWN" \
        "$(extract_breakdown "$RUN_DIR/stats.log" "$RUN_DIR/stats.line")"
    t_eq "extract_breakdown saves the cumulative stats line" "$T_LOG_CUMULATIVE" \
        "$(cat "$RUN_DIR/stats.line")"
    # close_window matches that line exactly in a later read of the same output.
    loadgen_logs 2026-01-01T00:00:00Z >"$RUN_DIR/B.log"
    t_eq "a second read holds the same stats line at the same position" 2 \
        "$(grep -n -x -F -f "$RUN_DIR/stats.line" "$RUN_DIR/B.log" | sed -n '1s/:.*//p')"
}

test_created_ids_uppercaseSanitizedId_recognised() {
    t_loadgen_output \
        "${T_LOG_STAMP}[worker:2][visit:portfolio_insights_alert][id:5F0C2A6E-3B1D-4C8E-9A7F-1E2D3C4B5A69][INFO]: Created alert [2B9D6F1E-7C4A-4E3B-8D2F-6A1C9E0B7D53] threshold [1000000.40271936]"
    loadgen_logs 2026-01-01T00:00:00Z >"$RUN_DIR/B.log"
    t_eq "created_ids recognises an upper-case id after sanitizing" "$T_LOG_ID" \
        "$(created_ids "$RUN_DIR/B.log")"
}

test_report_outcomes_outcomeLines_printsOnlyParsedFields() {
    t_loadgen_output \
        "$T_LOG_STAMP${T_LOG_TAGS}[WARN]: Alert [2B9D6F1E-7C4A-4E3B-8D2F-6A1C9E0B7D53] left in place: $T_LOG_SECRET" \
        "$T_LOG_STAMP${T_LOG_TAGS}[WARN]: Create unconfirmed threshold [1000000.40271936], outcome unknown"
    loadgen_logs 2026-01-01T00:00:00Z >"$RUN_DIR/B.log"
    { grep -F -e "$LEFT_MARKER" -e "$UNKNOWN_MARKER" "$RUN_DIR/B.log" || true; } >"$RUN_DIR/outcomes"
    # A raw line that never went through the sanitizer.
    echo "Alert [$T_LOG_ID] left in place: $T_LOG_SECRET" >>"$RUN_DIR/outcomes"
    report_outcomes "$RUN_DIR/outcomes"
    t_report_has "report_outcomes prints the id and status token" \
        "INFO outcome: alert [$T_LOG_ID] left in place: error"
    t_report_has "report_outcomes prints the unconfirmed threshold marker" \
        "INFO outcome: unconfirmed create, threshold [1000000.40271936], outcome unknown"
    t_report_has "report_outcomes prints a fixed notice for an unparsed line" \
        "INFO outcome: a line in no known outcome form, not printed"
    t_eq "report_outcomes prints three lines" 3 "$(wc -l <"$RUN_DIR/report" | tr -d ' ')"
    t_eq "report_outcomes prints no raw text" 0 \
        "$(grep -c -F -e "$T_LOG_SECRET" -e "$T_LOG_STAMP" -e "[visit:" "$RUN_DIR/report" || true)"
}

# ---------------------------------------------------------------------------------------------
# Loadgen restore (setup, restore_loadgen, cleanup)

T_WEIGHT_2='["EASYTRADE_URL=http://reverse-proxy","PORTFOLIO_INSIGHTS_ALERT_WEIGHT=2"]'
T_NO_WEIGHT='["EASYTRADE_URL=http://reverse-proxy"]'

# t_loadgen_fixture CID RUNNING ENV [DECLARED]: a project whose loadgen container CID (none when
# empty) runs when RUNNING is 1 and has the JSON environment ENV, answered by a docker stub. Each
# compose up or rm of loadgen is logged to $RUN_DIR/docker-calls with the
# PORTFOLIO_INSIGHTS_ALERT_WEIGHT it was called with, then applied: up makes a new container,
# running for -d, whose weight is Compose's ${PORTFOLIO_INSIGHTS_ALERT_WEIGHT:-0}, or absent when
# DECLARED is 0, as with compose files lacking the declaration. The files t-fail, t-inspect-fail
# and t-exits in $RUN_DIR make up and rm fail, loadgen's inspect fail, and a started container exit.
# hard_timeout, which bounds those calls, runs the stub here without the time limit, which
# harness-test.sh covers.
t_loadgen_fixture() {
    echo "$1" >"$RUN_DIR/t-cid"
    echo "$2" >"$RUN_DIR/t-running"
    echo "$3" >"$RUN_DIR/t-env"
    echo "${4:-1}" >"$RUN_DIR/t-declared"
    : >"$RUN_DIR/docker-calls"
    hard_timeout() {
        shift
        "$@"
    }
    docker() {
        local weight="${PORTFOLIO_INSIGHTS_ALERT_WEIGHT-(unset)}" cid
        cid="$(cat "$RUN_DIR/t-cid")"
        if [[ "$1" == "inspect" ]]; then
            if [[ "${*: -1}" == "db-adapter-1" ]]; then
                echo '["DB_TYPE=postgres"]'
            elif [[ -n "$cid" && "${*: -1}" == "$cid" && "$3" == "{{json .Config.Env}}" &&
                ! -f "$RUN_DIR/t-inspect-fail" ]]; then
                cat "$RUN_DIR/t-env"
            else
                echo "Error: No such object: ${*: -1}" >&2
                return 1
            fi
            return 0
        fi
        shift
        while [[ "${1:-}" == "-p" || "${1:-}" == "-f" ]]; do
            shift 2
        done
        case "$*" in
            "config --services")
                printf '%s\n' broker-service db db-adapter feature-flag-service loadgen reverse-proxy
                ;;
            "ps --status running --services")
                printf '%s\n' broker-service db db-adapter feature-flag-service reverse-proxy
                if [[ -n "$cid" && "$(cat "$RUN_DIR/t-running")" == "1" ]]; then
                    echo loadgen
                fi
                ;;
            "ps -a -q db-adapter")
                echo db-adapter-1
                ;;
            "ps -a -q loadgen")
                if [[ -n "$cid" ]]; then
                    echo "$cid"
                fi
                ;;
            "up -d --no-deps --force-recreate loadgen" | "up --no-start --no-deps --force-recreate loadgen" | \
                "rm --force --stop loadgen")
                echo "$* | weight $weight" >>"$RUN_DIR/docker-calls"
                if [[ -f "$RUN_DIR/t-fail" ]]; then
                    echo "simulated compose failure" >&2
                    return 1
                fi
                if [[ "$1" == "rm" ]]; then
                    : >"$RUN_DIR/t-cid"
                    return 0
                fi
                echo loadgen-recreated >"$RUN_DIR/t-cid"
                if [[ "$2" == "-d" && ! -f "$RUN_DIR/t-exits" ]]; then
                    echo 1 >"$RUN_DIR/t-running"
                else
                    echo 0 >"$RUN_DIR/t-running"
                fi
                if [[ "$(cat "$RUN_DIR/t-declared")" == "1" ]]; then
                    jq -c -n --arg entry "PORTFOLIO_INSIGHTS_ALERT_WEIGHT=${PORTFOLIO_INSIGHTS_ALERT_WEIGHT:-0}" \
                        '["EASYTRADE_URL=http://reverse-proxy", $entry]' | tr -d '\r' >"$RUN_DIR/t-env"
                else
                    echo "$T_NO_WEIGHT" >"$RUN_DIR/t-env"
                fi
                ;;
            *)
                echo "unexpected docker call: $*" >&2
                return 1
                ;;
        esac
    }
}

# t_stub_flag_service: http answers 200 with the flag off and modifiable, as a ready stack does.
t_stub_flag_service() {
    http() {
        HTTP_STATUS="200"
        HTTP_CTYPE="application/json"
        HTTP_ERROR=""
        HTTP_BODY="{\"id\":\"$FLAG_ID\",\"enabled\":false,\"isModifiable\":true}"
    }
}

# t_capture_start: records loadgen at start as setup does.
t_capture_start() {
    LOADGEN_AT_START="$(loadgen_state && printf x)"
    LOADGEN_AT_START="${LOADGEN_AT_START%x}"
    if [[ "$LOADGEN_AT_START" == running,* ]]; then
        LOADGEN_WAS_RUNNING=1
    fi
}

# t_cleanup: cleanup after a run that recreated loadgen, with the table written and no alert
# owned, so restoring loadgen is its only step.
t_cleanup() {
    LOADGEN_TOUCHED=1
    TABLE_WRITTEN=1
    (cleanup) >"$RUN_DIR/cleanup.out" 2>&1 || true
}

test_container_env_entry_environmentShapes_printsEntryOrFails() {
    local i actual cr=$'\r' lf=$'\n'
    local -a expected
    # The last two values hold a carriage return and a line feed, which the entry keeps. Their
    # expected entries take them from variables in a plain assignment: Git Bash drops a carriage
    # return from an array assigned by local, and from $'\r' in any array assignment.
    local cids=(lg-1 lg-1 lg-1 lg-1 lg-1 "" lg-1 lg-1 lg-1 lg-1)
    local envs=("$T_WEIGHT_2" '["PORTFOLIO_INSIGHTS_ALERT_WEIGHT="]'
        '["PORTFOLIO_INSIGHTS_ALERT_WEIGHT_MAX=9","PORTFOLIO_INSIGHTS_ALERT_WEIGHT=3"]'
        "$T_NO_WEIGHT" 'null' '[]' "$T_WEIGHT_2" 'not json'
        '["PORTFOLIO_INSIGHTS_ALERT_WEIGHT=2\r"]' '["PORTFOLIO_INSIGHTS_ALERT_WEIGHT=2\n0"]')
    local inspect_fails=(0 0 0 0 0 0 1 0 0 0)
    expected=("PORTFOLIO_INSIGHTS_ALERT_WEIGHT=2" "PORTFOLIO_INSIGHTS_ALERT_WEIGHT="
        "PORTFOLIO_INSIGHTS_ALERT_WEIGHT=3" "" "" "fails" "fails" "fails"
        "PORTFOLIO_INSIGHTS_ALERT_WEIGHT=2$cr" "PORTFOLIO_INSIGHTS_ALERT_WEIGHT=2${lf}0")
    for i in "${!cids[@]}"; do
        rm -f "$RUN_DIR/t-inspect-fail"
        t_loadgen_fixture "${cids[$i]}" 1 "${envs[$i]}"
        if [[ ${inspect_fails[$i]} -eq 1 ]]; then
            touch "$RUN_DIR/t-inspect-fail"
        fi
        actual="$(container_env_entry loadgen PORTFOLIO_INSIGHTS_ALERT_WEIGHT)" || actual="fails"
        t_eq "container_env_entry of container [${cids[$i]}] env ${envs[$i]} inspect failing ${inspect_fails[$i]}" \
            "${expected[$i]}" "$actual"
    done
}

test_setup_loadgenAtStart_recordsStateAndWeight() {
    local i
    local cids=(lg-1 lg-1 "")
    local running=(1 0 0)
    local envs=("$T_WEIGHT_2" "$T_NO_WEIGHT" '[]')
    local expected=("running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=2" "stopped, PORTFOLIO_INSIGHTS_ALERT_WEIGHT unset"
        "no container")
    for i in "${!cids[@]}"; do
        t_fresh_run_dir
        t_loadgen_fixture "${cids[$i]}" "${running[$i]}" "${envs[$i]}"
        t_stub_flag_service
        setup
        t_eq "setup records loadgen at start as [${expected[$i]}]" \
            "${expected[$i]}; was running ${running[$i]}" "$LOADGEN_AT_START; was running $LOADGEN_WAS_RUNNING"
        t_report_has "setup reports loadgen at start as [${expected[$i]}]" \
            "INFO db type postgres; loadgen at start: ${expected[$i]}"
    done
}

test_setup_loadgenUninspectable_failsReadiness() {
    t_loadgen_fixture lg-1 1 "$T_WEIGHT_2"
    touch "$RUN_DIR/t-inspect-fail"
    t_stub_flag_service
    (setup) >/dev/null 2>&1 || true
    t_report_has "setup fails readiness when loadgen cannot be inspected" \
        "FAIL readiness: reading loadgen's container state failed, exit 1 (see $RUN_DIR/compose.log)"
}

test_restore_loadgen_runningWithWeight2_recreatesStartedWithWeight2() {
    local rc=0
    unset PORTFOLIO_INSIGHTS_ALERT_WEIGHT
    t_loadgen_fixture lg-1 1 "$T_WEIGHT_2"
    t_capture_start
    recreate_loadgen 1
    restore_loadgen || rc=$?
    t_eq "restore_loadgen recreates loadgen started with its weight 2 after the run's weight 1" \
        "$(printf '%s\n' "up -d --no-deps --force-recreate loadgen | weight 1" \
            "up -d --no-deps --force-recreate loadgen | weight 2")" "$(cat "$RUN_DIR/docker-calls")"
    t_eq "restore_loadgen verifies loadgen running with weight 2" \
        "0 [] running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=2" "$rc [$RESTORE_ERROR] $(loadgen_state)"
}

test_restore_loadgen_stoppedWithWeight2_recreatesWithoutStarting() {
    local rc=0
    unset PORTFOLIO_INSIGHTS_ALERT_WEIGHT
    t_loadgen_fixture lg-1 0 "$T_WEIGHT_2"
    t_capture_start
    recreate_loadgen 1
    restore_loadgen || rc=$?
    t_eq "restore_loadgen recreates a loadgen stopped at start with --no-start and weight 2" \
        "up --no-start --no-deps --force-recreate loadgen | weight 2" "$(sed -n '2p' "$RUN_DIR/docker-calls")"
    t_eq "restore_loadgen verifies loadgen stopped with weight 2" \
        "0 [] stopped, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=2" "$rc [$RESTORE_ERROR] $(loadgen_state)"
}

test_restore_loadgen_noContainerAtStart_removesCreatedContainer() {
    local rc=0
    t_loadgen_fixture "" 0 '[]'
    t_capture_start
    recreate_loadgen 1
    restore_loadgen || rc=$?
    t_eq "restore_loadgen removes the loadgen container the run created" \
        "rm --force --stop loadgen | weight (unset)" "$(sed -n '2p' "$RUN_DIR/docker-calls")"
    t_eq "restore_loadgen verifies no loadgen container remains" \
        "0 [] no container" "$rc [$RESTORE_ERROR] $(loadgen_state)"
}

test_restore_loadgen_weightUnsetAtStart_recreatesWithWeightUnset() {
    local rc=0
    export PORTFOLIO_INSIGHTS_ALERT_WEIGHT=5
    t_loadgen_fixture lg-1 1 "$T_NO_WEIGHT" 0
    t_capture_start
    restore_loadgen || rc=$?
    t_eq "restore_loadgen recreates loadgen without the shell's weight" \
        "up -d --no-deps --force-recreate loadgen | weight (unset)" "$(cat "$RUN_DIR/docker-calls")"
    t_eq "restore_loadgen verifies loadgen running with the weight unset, leaving the shell's value" \
        "0 [] running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT unset; shell 5" \
        "$rc [$RESTORE_ERROR] $(loadgen_state); shell $PORTFOLIO_INSIGHTS_ALERT_WEIGHT"
}

test_cleanup_loadgenRestored_reportsStateAsAtStartAndPasses() {
    unset PORTFOLIO_INSIGHTS_ALERT_WEIGHT
    t_loadgen_fixture lg-1 1 "$T_WEIGHT_2"
    t_capture_start
    recreate_loadgen 1
    t_cleanup
    t_report_has "cleanup reports loadgen restored as at start" \
        "INFO cleanup: loadgen restored as at start: running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=2"
    t_report_has "cleanup passes after the restore" "PASS cleanup"
}

test_cleanup_weightWithControlCharacters_restoresItByteExactAndPrintsItQuoted() {
    local after
    unset PORTFOLIO_INSIGHTS_ALERT_WEIGHT
    t_loadgen_fixture lg-1 1 '["EASYTRADE_URL=http://reverse-proxy","PORTFOLIO_INSIGHTS_ALERT_WEIGHT=2\r\n"]'
    t_capture_start
    recreate_loadgen 1
    t_cleanup
    after="$(loadgen_state && printf x)"
    t_eq "cleanup restores a weight ending in a carriage return and a line feed byte for byte" \
        "running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=2"$'\r\n'"x" "$after"
    t_report_has "cleanup prints that weight quoted, on one line" \
        "INFO cleanup: loadgen restored as at start: running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=\$'2\\r\\n'"
    t_report_has "cleanup passes after that restore" "PASS cleanup"
}

test_cleanup_restoredStateDiffers_failsNamingExpectedAndActual() {
    local i
    # The weight unset at start against compose files declaring it, and a container that exits.
    local envs=("$T_NO_WEIGHT" "$T_WEIGHT_2")
    local exits=(0 1)
    local expected=(
        "expected [running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT unset] as at start, got [running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=0]"
        "expected [running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=2] as at start, got [stopped, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=2]")
    unset PORTFOLIO_INSIGHTS_ALERT_WEIGHT
    for i in "${!envs[@]}"; do
        t_fresh_run_dir
        t_loadgen_fixture lg-1 1 "${envs[$i]}"
        t_capture_start
        if [[ ${exits[$i]} -eq 1 ]]; then
            touch "$RUN_DIR/t-exits"
        fi
        t_cleanup
        t_report_has "cleanup fails naming expected and actual loadgen: ${expected[$i]}" \
            "FAIL cleanup: loadgen not restored: ${expected[$i]}"
    done
}

test_cleanup_dockerCommandFails_failsCleanup() {
    local i
    local cids=(lg-1 lg-1 "" lg-1)
    local envs=("$T_WEIGHT_2" "$T_NO_WEIGHT" '[]' "$T_WEIGHT_2")
    local declared=(1 0 1 1)
    local switches=(t-fail t-fail t-fail t-inspect-fail)
    local expected=("recreating loadgen as [running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=2] failed, exit 1"
        "recreating loadgen as [running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT unset] failed, exit 1"
        "removing the loadgen container this run created failed, exit 1"
        "reading loadgen's state after the restore failed, exit 1")
    for i in "${!cids[@]}"; do
        t_fresh_run_dir
        t_loadgen_fixture "${cids[$i]}" 1 "${envs[$i]}" "${declared[$i]}"
        t_capture_start
        touch "$RUN_DIR/${switches[$i]}"
        t_cleanup
        t_report_has "cleanup fails when restoring loadgen [$LOADGEN_AT_START] meets ${switches[$i]}" \
            "FAIL cleanup: loadgen not restored: ${expected[$i]} (see $RUN_DIR/compose.log)"
    done
}

# ---------------------------------------------------------------------------------------------
# Flag-off families (flag_off_window, phase_families)

# A flag-off cumulative breakdown: one completed visit or more in every existing family, the
# rare order_credit_card visit included, and the skipping portfolio_insights_alert at failRate 0.
T_FLAG_OFF_BREAKDOWN='{"deposit_and_buy_success":{"total":4,"avgDurationMs":21000,"failRate":0},'\
'"deposit_and_long_buy_success":{"total":3,"avgDurationMs":23000,"failRate":0},'\
'"long_sell_success":{"total":2,"avgDurationMs":19000,"failRate":0},'\
'"sell_and_withdraw_success":{"total":2,"avgDurationMs":22000,"failRate":0},'\
'"order_credit_card":{"total":1,"avgDurationMs":35000,"failRate":0},'\
'"portfolio_insights_alert":{"total":3,"avgDurationMs":150,"failRate":0}}'

# t_breakdown FILTER: T_FLAG_OFF_BREAKDOWN after the jq FILTER, on one line.
t_breakdown() {
    jq -c "$1" <<<"$T_FLAG_OFF_BREAKDOWN" | tr -d '\r'
}

# t_stats_line BREAKDOWN: the cumulative stats line loadgen-core 1.3.36 prints for BREAKDOWN five
# minutes after its start.
t_stats_line() {
    local total fail_rate rate
    IFS=$'\t' read -r total fail_rate rate < <(jq -r '([.[].total] | add) as $t
        | [$t, ([.[] | .total * .failRate] | add) / $t, $t / 5] | @tsv' <<<"$1" | tr -d '\r')
    printf '[2026-01-01 00:05:00+00:00][stats:runner][INFO]: %sThu, 01 Jan 2026 00:00:00 GMT] and generated [%s] visits with fail rate [%.2f] and a rate of [%.2f/m], detailed breakdown [%s]\n' \
        "$STATS_MARKER" "$total" "$fail_rate" "$rate" "$1"
}

# t_flag_off_window BREAKDOWN: runs flag_off_window with the flag, loadgen and log reads stubbed.
# Its B-flag-off.log holds the visit's skip line, no create and a cumulative stats line whose
# breakdown, BREAKDOWN, flag_off_window saves as breakdown-B-flag-off.json.
t_flag_off_window() {
    {
        echo "[2026-01-01 00:00:01+00:00][worker:0][INFO]: Running visit [order_credit_card]"
        echo "[2026-01-01 00:00:02+00:00][worker:1][INFO]: Running visit [$VISIT]"
        echo "[2026-01-01 00:00:02+00:00][worker:1][visit:$VISIT][id:7d0c8a52-0b8e-4d4e-9a49-2f1c0e6b9a11][INFO]: $SKIP_LINE"
        t_stats_line "$1"
    } >"$RUN_DIR/fixture.log"
    set_flag() {
        pass "$1"
    }
    open_window() {
        WINDOW_LABEL="$2"
        WINDOW_START_EPOCH="$(date -u +%s)"
        WINDOW_START="$(epoch_to_rfc3339 "$WINDOW_START_EPOCH")"
        WINDOW_SINCE="$WINDOW_START"
        WINDOW_OPEN=1
        pass "$1 loadgen weight: $3"
    }
    # The window's only poll is breakdown_since SINCE FILE; this one succeeds at once, writing
    # FILE and its stats line as breakdown_since does.
    poll() {
        local file="${*: -1}"
        extract_breakdown "$RUN_DIR/fixture.log" "${file%.json}.line" >"$file"
    }
    close_or_abort() {
        WINDOW_OPEN=0
        cp "$RUN_DIR/fixture.log" "$RUN_DIR/$WINDOW_LABEL.log"
        pass "$1 loadgen stopped"
    }
    report_new_owned() {
        :
    }
    flag_off_window
}

test_phase_families_flagOffLabel_includesOrderCreditCard() {
    t_eq "phase_families B-flag-off lists every existing family and the visit" \
        "deposit_and_buy deposit_and_long_buy long_sell sell_and_withdraw order_credit_card $VISIT" \
        "$(phase_families B-flag-off)"
}

test_flag_off_window_orderCreditCardCompleted_passesFamilyCheck() {
    t_flag_off_window "$T_FLAG_OFF_BREAKDOWN"
    t_report_has "flag-off order_credit_card family passes" \
        "PASS flag-off family order_credit_card: 1 completed visits (names: order_credit_card)"
    t_eq "flag-off checks all five existing families" 5 \
        "$(grep -c '^PASS flag-off family ' "$RUN_DIR/report" || true)"
    t_eq "flag-off order_credit_card verdict" PASS "$(verdict_of B-flag-off order_credit_card)"
}

test_flag_off_window_orderCreditCardNotCompleted_failsFamilyCheck() {
    local c scenario filter detail
    # SCENARIO;FILTER;DETAIL: the breakdown is T_FLAG_OFF_BREAKDOWN after FILTER.
    for c in "absent;del(.order_credit_card);0 completed visits (names: none)" \
        "failed;.order_credit_card.failRate = 1;0 completed visits (names: order_credit_card)"; do
        IFS=';' read -r scenario filter detail <<<"$c"
        t_fresh_run_dir
        t_flag_off_window "$(t_breakdown "$filter")"
        t_report_has "flag-off order_credit_card family fails when $scenario" \
            "FAIL flag-off family order_credit_card: $detail"
        t_eq "flag-off order_credit_card verdict when $scenario" FAIL \
            "$(verdict_of B-flag-off order_credit_card)"
    done
}

test_table_rows_flagOffLabel_listsOrderCreditCardRow() {
    local c scenario filter verdict row
    # SCENARIO;FILTER;VERDICT;ROW: the breakdown is T_FLAG_OFF_BREAKDOWN after FILTER.
    for c in "drawn;.;PASS;| B-flag-off | order_credit_card | order_credit_card | 1 | 0 | 1 | 0 | PASS |" \
        "not drawn;del(.order_credit_card);FAIL;| B-flag-off | order_credit_card | - | 0 | - | 0 | 0 | FAIL |"; do
        IFS=';' read -r scenario filter verdict row <<<"$c"
        t_fresh_run_dir
        t_breakdown "$filter" >"$RUN_DIR/breakdown-B-flag-off.json"
        : >"$RUN_DIR/errors-B-flag-off"
        record_verdict B-flag-off order_credit_card "$verdict"
        table_rows B-flag-off >"$RUN_DIR/rows"
        if grep -qxF -- "$row" "$RUN_DIR/rows"; then
            t_pass "table_rows B-flag-off lists order_credit_card when $scenario"
        else
            t_fail "table_rows B-flag-off lists order_credit_card when $scenario" \
                "no row [$row] in [$(tr '\n' '|' <"$RUN_DIR/rows")]"
        fi
    done
}

# ---------------------------------------------------------------------------------------------
# Runner

t_run_all() {
    local t out rc total_passed=0 total_failed=0 n_pass n_fail
    for t in $(declare -F | awk '$3 ~ /^test_/ { print $3 }'); do
        rc=0
        out="$( (
            t_fresh_run_dir
            "$t"
        ) 2>&1)" || rc=$?
        if [[ -n "$out" ]]; then
            printf '%s\n' "$out"
        fi
        n_pass="$(grep -c '^PASS ' <<<"$out" || true)"
        n_fail="$(grep -c '^FAIL ' <<<"$out" || true)"
        if [[ $rc -ne 0 ]]; then
            echo "FAIL $t: exited $rc"
            n_fail=$((n_fail + 1))
        elif [[ $((n_pass + n_fail)) -eq 0 ]]; then
            echo "FAIL $t: made no assertion"
            n_fail=$((n_fail + 1))
        fi
        total_passed=$((total_passed + n_pass))
        total_failed=$((total_failed + n_fail))
    done
    echo "SUMMARY $total_passed passed, $total_failed failed"
    [[ $total_failed -eq 0 ]]
}

t_run_all
