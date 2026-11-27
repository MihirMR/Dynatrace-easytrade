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

for t_tool in jq awk sed comm sha256sum base64; do
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
    LOADGEN_IMAGE_AT_START=""
    LOADGEN_HASH_AT_START=""
    LOADGEN_CONFIG_AT_START=""
    LOADGEN_STARTED_AT=""
    RESTORE_ERROR=""
    LOADGEN_ID_AT_START=""
    LOADGEN_TWIN=""
    TWIN_ERROR=""
    TWIN_REMOVED=""
    TWIN_DETAIL=""
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
    PROBE_DEADLINE=""
    LOG_PROBE_DETAIL=""
    STARTED_AT="2026-01-01T00:00:00Z"
    # The run lock under this run directory, never the shared /tmp main() uses.
    LOCK_ROOT="$RUN_DIR"
    LOCK_DIR=""
    LOCK_HELD=0
    LOCK_ERROR=""
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
#     kill use, appends "SUBCOMMAND LIMIT" to $RUN_DIR/compose.limits, moves the clock on by the
#     seconds $RUN_DIR/takes.SUBCOMMAND holds, as a call answering that late whatever its limit,
#     and runs compose without the time limit, which harness-test.sh covers.
#   - loadgen_logs prints $RUN_DIR/logs.N on its Nth read, the highest N there is from then on,
#     and $RUN_DIR/logs.final, when it exists, once Compose has stopped or killed loadgen. A
#     fixture holding the line !unreadable makes the read fail with the LOG_PROBE_DETAIL the
#     real read sets for a log Docker could not give. The Nth read takes the seconds
#     $RUN_DIR/takes.logs.N holds on the clock.
#   - db_query appends its SQL to $RUN_DIR/db.sql and prints the count in $RUN_DIR/db.count.
t_drain_stubs() {
    echo "$T_DRAIN_CLOCK_START" >"$RUN_DIR/clock"
    echo 0 >"$RUN_DIR/logs.n"
    echo 0 >"$RUN_DIR/db.count"
    : >"$RUN_DIR/compose.calls"
    : >"$RUN_DIR/compose.fail"
    : >"$RUN_DIR/compose.limits"
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
        echo "$2 $1" >>"$RUN_DIR/compose.limits"
        if [[ -f "$RUN_DIR/takes.$2" ]]; then
            echo $(($(cat "$RUN_DIR/clock") + $(cat "$RUN_DIR/takes.$2"))) >"$RUN_DIR/clock"
        fi
        shift
        compose "$@"
    }
    loadgen_logs() {
        local n file
        n=$(($(cat "$RUN_DIR/logs.n") + 1))
        echo "$n" >"$RUN_DIR/logs.n"
        if [[ -f "$RUN_DIR/takes.logs.$n" ]]; then
            echo $(($(cat "$RUN_DIR/clock") + $(cat "$RUN_DIR/takes.logs.$n"))) >"$RUN_DIR/clock"
        fi
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

test_audit_owned_ids_idsUnreadable_failsOwnedIdChecksClosed() {
    local c fault evidence
    # FAULT;EVIDENCE: what fails once run B's window is closed and its unresolved ids owned, and
    # the evidence check. Every create is resolved, so ids taken for an empty set would pass the
    # audit; the created and rows checks fail rather than count none or query none. The observed
    # set of created ids becoming unreadable fails the evidence check too; comm failing to compare
    # the window's created and resolved ids fails only the checks that read them.
    for c in "observed set unreadable;FAIL owned-id evidence: @IDS@, so not every create can be proven" \
        "union comparison fails;PASS owned-id evidence: the final output keeps every created id, resolution and first line an earlier read saw"; do
        IFS=';' read -r fault evidence <<<"$c"
        (
            local ids
            t_fresh_run_dir
            t_drain_stubs
            t_drain_window
            ids="the alert ids run B's reads logged could not be read or written in $RUN_DIR"
            {
                t_drain_resolved "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" ui
                t_drain_resolved "$T_DRAIN_RUN_2" "$T_DRAIN_ALERT_2" api
            } >"$RUN_DIR/logs.1"
            # close_or_abort as the script defines it, under another name, for the stub to call.
            eval "t_close_or_abort() $(declare -f close_or_abort | sed 1d)"
            # shellcheck disable=SC2329 # Invoked by audit_owned_ids.
            close_or_abort() {
                t_close_or_abort "$@"
                if [[ "$fault" == "observed set unreadable" ]]; then
                    rm -f "$RUN_DIR/observed-created-B"
                    mkdir "$RUN_DIR/observed-created-B"
                fi
            }
            # shellcheck disable=SC2329 # Invoked by audit_owned_ids.
            comm() {
                if [[ "$fault" == "union comparison fails" && $WINDOW_UNREAD -eq 0 &&
                    "${*: -1}" == "$RUN_DIR/ids.resolved.union" ]]; then
                    return 2
                fi
                command comm "$@"
            }
            # The failed read's own error message is not under test.
            audit_owned_ids 2>/dev/null
            t_eq "audit_owned_ids fails the checks reading the window's ids when the $fault" \
                "PASS owned-id quiescence: Q at 2026-01-01T00:00:01Z with 2 created alerts, all resolved, and no create in flight; loadgen killed while paused|PASS run B loadgen stopped|${evidence//@IDS@/$ids}|FAIL owned-id audit: $ids, so no create can be paired with its resolution|PASS owned-id in flight: every visit that opened the page logged a create outcome|PASS owned-id outcomes: 0 lines report an alert left in place or an unknown outcome since 2026-01-01T00:00:00Z|FAIL owned-id created: $ids, so the alerts created in run B cannot be counted|FAIL owned-id rows: $ids, so no Alerts row was counted" \
                "$(t_drain_checks)"
            t_eq "audit_owned_ids queries no row when the $fault" "" "$(t_drain_queried)"
            t_eq "audit_owned_ids records FAIL verdicts for the window's ids when the $fault" FAIL \
                "$(verdict_of B "$VISIT")"
        )
    done
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
# Loadgen at start (alert_visits_in_flight, secure_loadgen_at_start, main)

# The start time of the loadgen container found at start, as docker inspect gives it.
T_AT_START_SINCE="2025-12-31T23:00:00.123456789Z"

test_alert_visits_in_flight_visitLines_countsVisitsBeforeTheirOutcome() {
    local row label expected message
    local id="$T_DRAIN_ALERT_1"
    # LABEL|EXPECTED|MESSAGE: visit 1 opens the page, then logs MESSAGE; a MESSAGE of - adds none.
    for row in "page opened|1|-" \
        "page opened, alert created|1|Created alert [$id] threshold [1000000.40271936]" \
        "deleted via ui|0|Deleted alert [$id] via ui" \
        "deleted via api|0|Deleted alert [$id] via api" \
        "already absent|0|Alert [$id] already absent" \
        "left in place|0|Alert [$id] left in place: 403" \
        "unconfirmed create|0|Create unconfirmed threshold [1000000.40271936], outcome unknown" \
        "no instrument options|0|$NO_OPTIONS_LINE" \
        "page unavailable|0|$PAGE_UNAVAILABLE_LINE" \
        "feature lost before submit|0|$FEATURE_LOST_LINE" \
        "visit error|0|$ERROR_MARKER"; do
        IFS='|' read -r label expected message <<<"$row"
        {
            t_drain_opened "$T_DRAIN_RUN_1"
            if [[ "$message" != "-" ]]; then
                t_drain_line "$T_DRAIN_RUN_1" "$message"
            fi
        } >"$RUN_DIR/visit.log"
        t_eq "alert_visits_in_flight after [$label]" "$expected" "$(alert_visits_in_flight "$RUN_DIR/visit.log")"
    done
    # A create whose opening line came before the output read: in flight until its outcome.
    t_drain_line "$T_DRAIN_RUN_1" "Created alert [$id] threshold [1000000.40271936]" >"$RUN_DIR/created.log"
    t_eq "alert_visits_in_flight counts a create read without its opening line" 1 \
        "$(alert_visits_in_flight "$RUN_DIR/created.log")"
    t_drain_line "$T_DRAIN_RUN_1" "Deleted alert [$id] via ui" >>"$RUN_DIR/created.log"
    t_eq "alert_visits_in_flight ends that visit at its outcome" 0 "$(alert_visits_in_flight "$RUN_DIR/created.log")"
    {
        t_drain_resolved "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" ui
        t_drain_opened "$T_DRAIN_RUN_2"
    } >"$RUN_DIR/two.log"
    t_eq "alert_visits_in_flight counts the one open visit of two" 1 "$(alert_visits_in_flight "$RUN_DIR/two.log")"
    echo "[2026-01-01 00:00:10+00:00][worker:0][visit:deposit_and_buy][id:$T_DRAIN_RUN_1][INFO]: $OPENING_LINE" \
        >"$RUN_DIR/other.log"
    t_eq "alert_visits_in_flight ignores another visit's line" 0 "$(alert_visits_in_flight "$RUN_DIR/other.log")"
}

# The full ID of the loadgen container found at start, invented, and its first 12 hex digits.
T_AT_START_CID="4c6f6164676e00000000000000000000000000000000000000000000000000a1"
T_AT_START_SHORT="4c6f6164676e"

# t_at_start_stubs RUNNING FLAG: loadgen found at start with weight 2, running when RUNNING is 1,
# with the flag at FLAG, and the drain's clock, Compose and output stubbed (t_drain_stubs). http
# records each request in $RUN_DIR/http-calls and answers none. That loadgen is the container
# T_AT_START_CID, last started at T_AT_START_SINCE ($RUN_DIR/lg-started), in the state
# $RUN_DIR/lg-state holds: running, paused or exited. On top of t_drain_stubs:
#   - compose ps -a -q loadgen prints $RUN_DIR/lg-cid, that ID unless a test changes it, and a
#     pause, unpause or kill that succeeds changes lg-state as Docker would. The subcommand in
#     $RUN_DIR/compose.fail.once fails once, and the run is interrupted (exit 130, as the INT trap
#     does) right after the subcommand in $RUN_DIR/compose.exit.after.
#   - docker inspect --type container --format {{json .State}} answers for that ID from lg-state
#     and lg-started, and fails while $RUN_DIR/lg-inspect-fail exists; hard_timeout runs docker
#     without the time limit, which harness-test.sh covers.
#   - sleep N interrupts the run (exit 130) when N is in $RUN_DIR/sleep.exit.
t_at_start_stubs() {
    t_drain_stubs
    if [[ "$1" == "1" ]]; then
        LOADGEN_AT_START="running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=2"
        echo running >"$RUN_DIR/lg-state"
    else
        LOADGEN_AT_START="stopped, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=2"
        echo exited >"$RUN_DIR/lg-state"
    fi
    LOADGEN_WAS_RUNNING="$1"
    FLAG_INITIAL="$2"
    LOADGEN_STARTED_AT="$T_AT_START_SINCE"
    echo "$T_AT_START_CID" >"$RUN_DIR/lg-cid"
    echo "$T_AT_START_SINCE" >"$RUN_DIR/lg-started"
    : >"$RUN_DIR/compose.fail.once"
    : >"$RUN_DIR/compose.exit.after"
    : >"$RUN_DIR/sleep.exit"
    : >"$RUN_DIR/http-calls"
    # shellcheck disable=SC2329 # Invoked only if the code under test sends a request.
    http() {
        echo "$*" >>"$RUN_DIR/http-calls"
        HTTP_STATUS="000"
        HTTP_ERROR="not expected"
        HTTP_BODY=""
    }
    compose() {
        local state=""
        echo "$*" >>"$RUN_DIR/compose.calls"
        if grep -qxF -- "$1" "$RUN_DIR/compose.fail"; then
            return 1
        fi
        if grep -qxF -- "$1" "$RUN_DIR/compose.fail.once"; then
            : >"$RUN_DIR/compose.fail.once"
            return 1
        fi
        case "$*" in
            "ps -a -q loadgen") cat "$RUN_DIR/lg-cid" ;;
            "pause loadgen") state=paused ;;
            "unpause loadgen") state=running ;;
            "kill -s SIGKILL loadgen") state=exited ;;
        esac
        if [[ -n "$state" ]]; then
            echo "$state" >"$RUN_DIR/lg-state"
        fi
        if grep -qxF -- "$1" "$RUN_DIR/compose.exit.after"; then
            exit 130
        fi
    }
    hard_timeout() {
        shift
        "$@"
    }
    # shellcheck disable=SC2329 # Invoked by hard_timeout, as loadgen_run_state calls it.
    docker() {
        if [[ "$*" == "inspect --type container --format {{json .State}} $T_AT_START_CID" &&
            ! -f "$RUN_DIR/lg-inspect-fail" ]]; then
            jq -c -n --arg status "$(cat "$RUN_DIR/lg-state")" --arg started "$(cat "$RUN_DIR/lg-started")" \
                '{Status: $status, Running: ($status != "exited"), Paused: ($status == "paused"),
                    StartedAt: $started}' | tr -d '\r'
            return 0
        fi
        echo "Error: No such container: ${*: -1}" >&2
        return 1
    }
    sleep() {
        if grep -qxF -- "$1" "$RUN_DIR/sleep.exit"; then
            exit 130
        fi
        echo $(($(cat "$RUN_DIR/clock") + $1)) >"$RUN_DIR/clock"
    }
}

# t_at_start_run: secure_loadgen_at_start in a subshell, which an abort ends, leaving its status
# and the state cleanup reads in $RUN_DIR/at-start.state, and the container ID it recorded in
# $RUN_DIR/at-start.cid.
t_at_start_run() {
    local rc=0
    (
        trap 'echo "LOADGEN_TOUCHED=$LOADGEN_TOUCHED LOADGEN_PAUSED=$LOADGEN_PAUSED FLAG_TOUCHED=$FLAG_TOUCHED WINDOW_OPEN=$WINDOW_OPEN AT_START_DRAINING=$AT_START_DRAINING" >"$RUN_DIR/at-start.state"; echo "$LOADGEN_CID_AT_START" >"$RUN_DIR/at-start.cid"' EXIT
        secure_loadgen_at_start
    ) || rc=$?
    echo "status $rc $(cat "$RUN_DIR/at-start.state")" >"$RUN_DIR/at-start.state"
}

# t_at_start_then_cleanup: secure_loadgen_at_start in a subshell that ends through the script's
# EXIT trap, as a run does after an abort or an interrupt. cleanup's own output goes to
# $RUN_DIR/cleanup.out and the subshell's exit status to $RUN_DIR/cleanup.status.
t_at_start_then_cleanup() {
    local rc=0
    (
        trap cleanup EXIT
        secure_loadgen_at_start
    ) >"$RUN_DIR/cleanup.out" 2>&1 || rc=$?
    echo "$rc" >"$RUN_DIR/cleanup.status"
}

# t_at_start_workload: loadgen's output at start: a visit whose alert was deleted via the UI, one
# that left its alert in place on a 403 long before, and an unconfirmed create.
t_at_start_workload() {
    echo "$T_DRAIN_FIRST_LINE"
    t_drain_resolved "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" ui
    t_drain_created "$T_DRAIN_RUN_2" "$T_DRAIN_ALERT_2"
    t_drain_line "$T_DRAIN_RUN_2" "Alert [$T_DRAIN_ALERT_2] left in place: 403"
    t_drain_opened 5e1f2a3b-0000-4000-8000-00000000000c
    t_drain_line 5e1f2a3b-0000-4000-8000-00000000000c "Create unconfirmed threshold [1000000.40271936], outcome unknown"
}

# t_at_start_in_flight: loadgen's output at start, kept first and read running by the drain, then
# a visit that opens the page between that read and the pause and never ends, so the frozen output
# holds it in flight and the drain unpauses loadgen.
t_at_start_in_flight() {
    t_at_start_workload >"$RUN_DIR/logs.1"
    cp "$RUN_DIR/logs.1" "$RUN_DIR/logs.2"
    {
        cat "$RUN_DIR/logs.1"
        t_drain_opened 5e1f2a3b-0000-4000-8000-00000000000d
    } >"$RUN_DIR/logs.3"
}

test_secure_loadgen_at_start_runningWithFlagOn_drainsToQAndOwnsNothing() {
    local prefix="INFO loadgen at start (not this run's, not deleted)"
    t_at_start_stubs 1 true
    t_at_start_workload >"$RUN_DIR/logs.1"
    t_at_start_run
    t_report_has "secure_loadgen_at_start passes at Q, naming the kept output" \
        "PASS loadgen at start: Q at 2026-01-01T00:00:01Z with no $VISIT visit in flight; loadgen killed while paused; its output since $T_AT_START_SINCE is kept in $RUN_DIR/at-start.log"
    t_eq "secure_loadgen_at_start reads the container's ID, then pauses and kills loadgen while the flag is on" \
        "ps -a -q loadgen|pause loadgen|kill -s SIGKILL loadgen" "$(t_drain_calls)"
    t_eq "secure_loadgen_at_start records the ID of the container it drained" "$T_AT_START_CID" \
        "$(cat "$RUN_DIR/at-start.cid")"
    t_eq "secure_loadgen_at_start sends no request, so the flag is untouched" "" "$(cat "$RUN_DIR/http-calls")"
    t_eq "secure_loadgen_at_start leaves loadgen touched for cleanup, no window open and the drain over at Q" \
        "status 0 LOADGEN_TOUCHED=1 LOADGEN_PAUSED=0 FLAG_TOUCHED=0 WINDOW_OPEN=0 AT_START_DRAINING=0" \
        "$(cat "$RUN_DIR/at-start.state")"
    t_eq "secure_loadgen_at_start keeps the frozen output at Q" "$(cat "$RUN_DIR/logs.1")" \
        "$(cat "$RUN_DIR/at-start.log")"
    t_eq "secure_loadgen_at_start owns none of that workload's alerts" "" "$(t_drain_owned)"
    t_report_has "secure_loadgen_at_start reports the unresolved create as not this run's" \
        "$prefix: alert [$T_DRAIN_ALERT_2] was logged as created and never resolved"
    t_report_has "secure_loadgen_at_start reports the alert left in place by its parsed fields" \
        "$prefix: alert [$T_DRAIN_ALERT_2] left in place: 403"
    t_report_has "secure_loadgen_at_start reports the unconfirmed create by its marker" \
        "$prefix: unconfirmed create, threshold [1000000.40271936], outcome unknown"
}

test_secure_loadgen_at_start_visitStaysInFlight_unpausesAndEndsWithNothingChanged() {
    t_at_start_stubs 1 true
    t_at_start_in_flight
    t_at_start_run
    t_report_has "secure_loadgen_at_start fails without Q, stating nothing was changed" \
        "FAIL loadgen at start: not quiescent within 180s: 1 $VISIT visits between opening the page or creating an alert and its outcome; nothing was changed: loadgen runs on as at start and the flag is untouched"
    t_eq "secure_loadgen_at_start unpauses loadgen after the frozen output showed the visit" \
        "ps -a -q loadgen|pause loadgen|unpause loadgen" "$(t_drain_calls)"
    t_eq "secure_loadgen_at_start ends the run with loadgen untouched for cleanup" \
        "status 1 LOADGEN_TOUCHED=0 LOADGEN_PAUSED=0 FLAG_TOUCHED=0 WINDOW_OPEN=0 AT_START_DRAINING=0" \
        "$(cat "$RUN_DIR/at-start.state")"
    t_eq "secure_loadgen_at_start without Q sends no request" "" "$(cat "$RUN_DIR/http-calls")"
    t_eq "secure_loadgen_at_start without Q owns nothing" "" "$(t_drain_owned)"
}

test_secure_loadgen_at_start_killFails_endsWithLoadgenLeftForCleanup() {
    t_at_start_stubs 1 true
    t_at_start_workload >"$RUN_DIR/logs.1"
    echo kill >"$RUN_DIR/compose.fail"
    t_at_start_run
    t_report_has "secure_loadgen_at_start fails naming the kill and the unpause in place on exit" \
        "FAIL loadgen at start: killing the paused loadgen failed, exit 1 (see $RUN_DIR/compose.log); loadgen may be left paused, and cleanup unpauses it in place rather than recreating it"
    t_eq "secure_loadgen_at_start leaves the paused loadgen touched, short of Q, for cleanup" \
        "status 1 LOADGEN_TOUCHED=1 LOADGEN_PAUSED=1 FLAG_TOUCHED=0 WINDOW_OPEN=0 AT_START_DRAINING=1" \
        "$(cat "$RUN_DIR/at-start.state")"
}

# t_at_start_late_kill: the at-start drain of a running loadgen with the flag on whose kill, sent
# one second in, after the frozen output's two reads, ends in the drain deadline's second: loadgen
# has ended, yet the drain claims no Q.
t_at_start_late_kill() {
    t_at_start_stubs 1 true
    t_at_start_workload >"$RUN_DIR/logs.1"
    echo $((QUIESCE_TIMEOUT_SECONDS - 1)) >"$RUN_DIR/takes.kill"
}

test_secure_loadgen_at_start_killEndsAtDeadline_failsAndCleanupRecreatesEndedLoadgen() {
    t_at_start_late_kill
    t_at_start_run
    t_report_has "secure_loadgen_at_start fails without Q, naming loadgen as not running as at start" \
        "FAIL loadgen at start: paused loadgen killed at or after the drain deadline of $QUIESCE_TIMEOUT_SECONDS s, so no Q; loadgen is not shown running as at start, so cleanup puts it back: in place while it runs, recreated once it has ended"
    t_eq "secure_loadgen_at_start pauses and kills loadgen once, sending no unpause" \
        "ps -a -q loadgen|pause loadgen|kill -s SIGKILL loadgen" "$(t_drain_calls)"
    t_eq "secure_loadgen_at_start leaves the ended loadgen touched, short of Q, for cleanup" \
        "status 1 LOADGEN_TOUCHED=1 LOADGEN_PAUSED=0 FLAG_TOUCHED=0 WINDOW_OPEN=0 AT_START_DRAINING=1" \
        "$(cat "$RUN_DIR/at-start.state")"
    t_fresh_run_dir
    t_at_start_late_kill
    t_at_start_then_cleanup
    t_report_has "cleanup finds loadgen at start ended by the late kill" \
        "INFO cleanup: loadgen at start (container $T_AT_START_SHORT) has ended (status exited), so no visit of its workload is in flight; its output since $T_AT_START_SINCE is kept in $RUN_DIR/at-start.log before it is recreated"
    t_eq "cleanup recreates the loadgen the late kill ended, through restore_loadgen" 1 \
        "$(t_calls_count '^up -d .*--force-recreate.* loadgen$')"
    t_eq "cleanup never unpauses the loadgen the late kill ended" 0 "$(t_calls_count '^unpause loadgen$')"
}

test_secure_loadgen_at_start_containerNotAsSetupFound_endsWithNothingChanged() {
    local row label switch value detail
    local restarted="2026-01-01T00:30:00Z"
    # LABEL;SWITCH;VALUE;DETAIL: VALUE goes to $RUN_DIR/SWITCH (t_at_start_stubs) before the step.
    for row in "ID unreadable;compose.fail;ps;reading loadgen's container ID failed, exit 1 (see @RUN_DIR@/compose.log)" \
        "no container ID;lg-cid;;loadgen's container ID is [], not a full container ID cleanup could inspect again" \
        "state unreadable;lg-inspect-fail;1;reading the state of loadgen's container $T_AT_START_SHORT failed, exit 1 (see @RUN_DIR@/compose.log)" \
        "restarted since setup;lg-started;$restarted;loadgen's container $T_AT_START_SHORT is [status running, paused false, started $restarted] instead of [status running, paused false, started $T_AT_START_SINCE] as setup found it"; do
        IFS=';' read -r label switch value detail <<<"$row"
        (
            t_fresh_run_dir
            t_at_start_stubs 1 true
            t_at_start_workload >"$RUN_DIR/logs.1"
            printf '%s\n' "$value" >"$RUN_DIR/$switch"
            t_at_start_run
            t_report_has "secure_loadgen_at_start fails before the drain when the container's $label" \
                "FAIL loadgen at start: ${detail//@RUN_DIR@/$RUN_DIR}; nothing was changed"
            t_eq "secure_loadgen_at_start neither pauses nor kills loadgen when the container's $label" \
                "ps -a -q loadgen" "$(t_drain_calls)"
            t_eq "secure_loadgen_at_start leaves loadgen untouched when the container's $label" \
                "status 1 LOADGEN_TOUCHED=0 LOADGEN_PAUSED=0 FLAG_TOUCHED=0 WINDOW_OPEN=0 AT_START_DRAINING=0" \
                "$(cat "$RUN_DIR/at-start.state")"
        )
    done
}

# The INFO line cleanup reports once it has put the container found at start back in place.
T_AT_START_RECOVERED="INFO cleanup: loadgen at start recovered in place: running as at start (container $T_AT_START_SHORT), not recreated"

# t_calls_count REGEX: how many Compose commands run so far match the extended REGEX.
t_calls_count() {
    grep -cE -- "$1" "$RUN_DIR/compose.calls" || true
}

test_cleanup_atStartDrainShortOfQ_recoversLoadgenInPlaceWithoutRecreate() {
    local row label switch value unpauses status
    # LABEL;SWITCH;VALUE;UNPAUSES;STATUS: VALUE written to $RUN_DIR/SWITCH (t_at_start_stubs)
    # makes the drain fail or the run be interrupted short of Q; UNPAUSES is the number of unpause
    # commands the drain and cleanup run together, STATUS the run's exit status.
    for row in "the drain's unpause fails;compose.fail.once;unpause;2;1" \
        "an interrupt between the drain's polls;sleep.exit;$QUIESCE_STEP_SECONDS;1;130" \
        "an interrupt while loadgen is paused;sleep.exit;$QUIESCE_FLUSH_STEP_SECONDS;1;130" \
        "an interrupt after an unpause, before LOADGEN_PAUSED clears;compose.exit.after;unpause;1;130"; do
        IFS=';' read -r label switch value unpauses status <<<"$row"
        (
            t_fresh_run_dir
            t_at_start_stubs 1 true
            t_at_start_in_flight
            printf '%s\n' "$value" >"$RUN_DIR/$switch"
            t_at_start_then_cleanup
            t_report_has "cleanup after $label reports loadgen at start recovered in place" "$T_AT_START_RECOVERED"
            t_report_has "cleanup after $label passes" "PASS cleanup"
            t_eq "cleanup after $label unpauses loadgen only if it is paused" "$unpauses" \
                "$(t_calls_count '^unpause loadgen$')"
            t_eq "cleanup after $label neither recreates nor removes loadgen" 0 "$(t_calls_count '^(up|rm) ')"
            t_eq "cleanup after $label leaves the container found at start running" running \
                "$(cat "$RUN_DIR/lg-state")"
            t_eq "the run after $label exits with its own status" "$status" "$(cat "$RUN_DIR/cleanup.status")"
        )
    done
}

# t_at_start_not_recoverable_row LABEL STATE SWITCH VALUE DETAIL UNPAUSES: one row of the case
# below, which runs it in a subshell, so the run state it sets ends with the row.
t_at_start_not_recoverable_row() {
    local label="$1" state="$2" switch="$3" value="$4" detail="$5" unpauses="$6"
    t_fresh_run_dir
    t_at_start_stubs 1 true
    # What an interrupted at-start drain leaves for cleanup.
    LOADGEN_CID_AT_START="$T_AT_START_CID"
    AT_START_DRAINING=1
    LOADGEN_PAUSED=1
    echo "$state" >"$RUN_DIR/lg-state"
    printf '%s\n' "$value" >"$RUN_DIR/$switch"
    t_cleanup
    t_report_has "cleanup fails naming loadgen at start when its $label" \
        "FAIL cleanup: loadgen at start (container $T_AT_START_SHORT) ${detail//@RUN_DIR@/$RUN_DIR}"
    t_eq "cleanup tries to unpause loadgen at start only if it is paused, when its $label" "$unpauses" \
        "$(t_calls_count '^unpause loadgen$')"
    t_eq "cleanup neither recreates nor removes loadgen at start when its $label" 0 \
        "$(t_calls_count '^(up|rm) ')"
    t_eq "cleanup leaves loadgen at start $state when its $label" "$state" "$(cat "$RUN_DIR/lg-state")"
}

test_cleanup_atStartLoadgenNotRecoverable_failsWithoutRecreate() {
    local row label state switch value detail unpauses
    local restarted="2026-01-01T00:30:00Z" why="not recreated, since a visit of its workload may be in flight"
    # LABEL;STATE;SWITCH;VALUE;DETAIL;UNPAUSES: the container found at start is in STATE, short of
    # Q, when cleanup runs, with VALUE written to $RUN_DIR/SWITCH (t_at_start_stubs); DETAIL is the
    # cleanup problem, in which @RUN_DIR@ stands for the run directory, and UNPAUSES the number of
    # unpause commands cleanup runs.
    for row in "unpause fails;paused;compose.fail;unpause;left paused, $why: unpausing loadgen failed, exit 1 (see @RUN_DIR@/compose.log);1" \
        "state unreadable;running;lg-inspect-fail;1;unverified, $why: reading its state failed, exit 1 (see @RUN_DIR@/compose.log);0" \
        "restarted since start;running;lg-started;$restarted;is [status running, paused false, started $restarted] instead of [status running, paused false, started $T_AT_START_SINCE] as at start, $why;0"; do
        IFS=';' read -r label state switch value detail unpauses <<<"$row"
        (t_at_start_not_recoverable_row "$label" "$state" "$switch" "$value" "$detail" "$unpauses")
    done
}

test_cleanup_interruptedAfterAtStartKill_keepsOutputAndRecreates() {
    local row label final kept
    # LABEL;FINAL;KEPT: FINAL is the output loadgen gives once killed, final for its output at
    # start and one line more, or the marker of an unreadable read; KEPT is the INFO tail cleanup
    # reports, in which @RUN_DIR@ stands for the run directory.
    for row in "readable;final;is kept in @RUN_DIR@/at-start.log before it is recreated" \
        "unreadable;!unreadable;could not be kept before it is recreated: loadgen logs unreadable, exit 1 (see @RUN_DIR@/compose.log)"; do
        IFS=';' read -r label final kept <<<"$row"
        (
            t_fresh_run_dir
            t_at_start_stubs 1 true
            t_at_start_workload >"$RUN_DIR/logs.1"
            if [[ "$final" == "final" ]]; then
                {
                    cat "$RUN_DIR/logs.1"
                    echo "[2026-01-01 00:00:12+00:00][worker:1][INFO]: Running visit [deposit_and_buy]"
                } >"$RUN_DIR/logs.final"
            else
                echo "$final" >"$RUN_DIR/logs.final"
            fi
            # Interrupted right after the kill at Q, before the step records that Q was reached.
            echo kill >"$RUN_DIR/compose.exit.after"
            t_at_start_then_cleanup
            t_report_has "cleanup finds loadgen at start ended after the kill, its output $label" \
                "INFO cleanup: loadgen at start (container $T_AT_START_SHORT) has ended (status exited), so no visit of its workload is in flight; its output since $T_AT_START_SINCE ${kept//@RUN_DIR@/$RUN_DIR}"
            if [[ "$final" == "final" ]]; then
                t_eq "cleanup keeps the ended container's final output before the recreate" \
                    "$(cat "$RUN_DIR/logs.final")" "$(cat "$RUN_DIR/at-start.log")"
            else
                t_eq "cleanup keeps the output read at start when the final output is unreadable" \
                    "$(cat "$RUN_DIR/logs.1")" "$(cat "$RUN_DIR/at-start.log")"
            fi
            # restore_loadgen's own result is the subject of the restore tests below.
            t_eq "cleanup recreates the ended loadgen through restore_loadgen, its output $label" 1 \
                "$(t_calls_count '^up -d .*--force-recreate.* loadgen$')"
            t_eq "cleanup never unpauses the ended loadgen, its output $label" 0 \
                "$(t_calls_count '^unpause loadgen$')"
        )
    done
}

test_secure_loadgen_at_start_flagOffOrStopped_keepsOutputWithoutDrain() {
    local row running flag detail
    # RUNNING|FLAG|DETAIL
    for row in "1|false|running with the flag off, so no visit creates or deletes an alert; not drained" \
        "0|true|stopped, so no visit can be in flight" \
        "0|false|stopped, so no visit can be in flight"; do
        IFS='|' read -r running flag detail <<<"$row"
        (
            t_fresh_run_dir
            t_at_start_stubs "$running" "$flag"
            t_at_start_workload >"$RUN_DIR/logs.1"
            t_at_start_run
            t_report_has "secure_loadgen_at_start passes loadgen running $running with the flag $flag" \
                "PASS loadgen at start: $detail; its output since $T_AT_START_SINCE is kept in $RUN_DIR/at-start.log"
            t_eq "secure_loadgen_at_start runs no Compose command with loadgen running $running and the flag $flag" \
                "" "$(t_drain_calls)"
            t_eq "secure_loadgen_at_start reads the output once with loadgen running $running and the flag $flag" \
                1 "$(cat "$RUN_DIR/logs.n")"
            t_eq "secure_loadgen_at_start keeps that output with loadgen running $running and the flag $flag" \
                "$(cat "$RUN_DIR/logs.1")" "$(cat "$RUN_DIR/at-start.log")"
            t_eq "secure_loadgen_at_start leaves loadgen untouched with loadgen running $running and the flag $flag" \
                "status 0 LOADGEN_TOUCHED=0 LOADGEN_PAUSED=0 FLAG_TOUCHED=0 WINDOW_OPEN=0 AT_START_DRAINING=0" \
                "$(cat "$RUN_DIR/at-start.state")"
            t_report_has "secure_loadgen_at_start reports the unresolved create with loadgen running $running and the flag $flag" \
                "INFO loadgen at start (not this run's, not deleted): alert [$T_DRAIN_ALERT_2] was logged as created and never resolved"
            t_eq "secure_loadgen_at_start owns nothing with loadgen running $running and the flag $flag" "" "$(t_drain_owned)"
        )
    done
}

test_secure_loadgen_at_start_noContainer_passesWithoutReading() {
    t_at_start_stubs 0 true
    LOADGEN_AT_START="no container"
    t_at_start_run
    t_report_has "secure_loadgen_at_start passes without a container" \
        "PASS loadgen at start: no container, so no visit of an earlier workload can be in flight"
    t_eq "secure_loadgen_at_start reads no output without a container" 0 "$(cat "$RUN_DIR/logs.n")"
    t_eq "secure_loadgen_at_start runs no Compose command without a container" "" "$(t_drain_calls)"
}

test_secure_loadgen_at_start_outputUnreadable_endsWithNothingChanged() {
    t_at_start_stubs 1 true
    echo '!unreadable' >"$RUN_DIR/logs.1"
    t_at_start_run
    t_report_has "secure_loadgen_at_start fails when the output cannot be kept" \
        "FAIL loadgen at start: reading loadgen's output since it started at $T_AT_START_SINCE: loadgen logs unreadable, exit 1 (see $RUN_DIR/compose.log); nothing was changed"
    t_eq "secure_loadgen_at_start without its output runs no Compose command" "" "$(t_drain_calls)"
    t_eq "secure_loadgen_at_start without its output leaves loadgen untouched" \
        "status 1 LOADGEN_TOUCHED=0 LOADGEN_PAUSED=0 FLAG_TOUCHED=0 WINDOW_OPEN=0 AT_START_DRAINING=0" \
        "$(cat "$RUN_DIR/at-start.state")"
    (
        t_fresh_run_dir
        t_at_start_stubs 1 true
        LOADGEN_STARTED_AT="-"
        t_at_start_run
        t_report_has "secure_loadgen_at_start fails on a start time it cannot read from" \
            "FAIL loadgen at start: loadgen's start time - is not an RFC 3339 time, so its output cannot be read; nothing was changed"
        t_eq "secure_loadgen_at_start reads no output without a start time" 0 "$(cat "$RUN_DIR/logs.n")"
    )
}

test_main_steps_securesLoadgenAtStartBetweenSetupAndRunA() {
    local step
    T_STEPS="$RUN_DIR/steps"
    : >"$T_STEPS"
    (
        # Every step main runs records its name, so only the order is under test.
        parse_options() {
            BASE_URL="http://localhost"
            COMPOSE_FILES=("compose.dev.yaml")
            PROJECT="pi-test"
            WEIGHT="1"
            MINUTES="35"
            OUT_FILE=""
            RESUME_RUN_DIR=""
        }
        for step in check_tools setup secure_loadgen_at_start run_a run_b flag_off_window finish_run cleanup; do
            eval "$step() { echo $step >>\"\$T_STEPS\"; }"
        done
        TMPDIR="$RUN_DIR"
        main --project pi-test
    ) >/dev/null 2>&1 || true
    t_eq "main secures loadgen at start after setup and before run A switches the flag" \
        "check_tools setup secure_loadgen_at_start run_a run_b flag_off_window finish_run cleanup" \
        "$(join_lines <"$T_STEPS")"
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
# Image IDs, both invented: the one loadgen runs at start, and one its image reference names after
# a rebuild.
T_IMAGE_A="sha256:a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a7b8"
T_IMAGE_B="sha256:b2c3d4e5f6a7b2c3d4e5f6a7b2c3d4e5f6a7b2c3d4e5f6a7b2c3d4e5f6a7b8c9"
T_IMAGE_REF="pi-test-loadgen"
T_STARTED_AT="2026-01-01T00:00:00.123456789Z"

# t_config_hash TOKEN: the 64-hex config hash the docker stub's Compose gives loadgen: a SHA-256 of
# the other settings in $RUN_DIR/t-settings and TOKEN, the base64 of the weight value loadgen's
# environment gets, or - when the compose files do not declare the weight.
t_config_hash() {
    local sum
    sum="$(printf 'settings=%s weight=%s' "$(cat "$RUN_DIR/t-settings")" "$1" | sha256sum)"
    printf '%s' "${sum:0:64}"
}

# t_compose_weight_token: the weight token (t_config_hash) of the loadgen the stub's Compose would
# create now, from t-declared and this shell's PORTFOLIO_INSIGHTS_ALERT_WEIGHT, as
# ${PORTFOLIO_INSIGHTS_ALERT_WEIGHT:-0} interpolates it.
t_compose_weight_token() {
    if [[ "$(cat "$RUN_DIR/t-declared")" == "1" ]]; then
        printf '%s' "${PORTFOLIO_INSIGHTS_ALERT_WEIGHT:-0}" | base64 -w0
    else
        printf '%s' "-"
    fi
}

# t_env_weight_token: the weight token (t_config_hash) of the container environment in
# $RUN_DIR/t-env: the base64 of its PORTFOLIO_INSIGHTS_ALERT_WEIGHT value, or - without one.
t_env_weight_token() {
    jq -r 'first(.[]? | select(startswith("PORTFOLIO_INSIGHTS_ALERT_WEIGHT="))
        | ltrimstr("PORTFOLIO_INSIGHTS_ALERT_WEIGHT=") | @base64) // "-"' "$RUN_DIR/t-env" 2>/dev/null |
        tr -d '\r\n'
}

# t_container_json ID NUMBER IMAGE HASH STARTED RUNNING CPU RESTART ENV_FILE DEPENDS REPLACE ULIMITS:
# the docker inspect object of stub loadgen container ID, pi-test-loadgen-NUMBER, as the engine
# gives the fields loadgen_identity and loadgen_config_snapshot read: image ID IMAGE, created from
# T_IMAGE_REF with config hash HASH, the depends_on label DEPENDS and, unless REPLACE is empty, the
# replace label REPLACE; last started at STARTED; the JSON environment in ENV_FILE (null when it
# is no JSON); CpuShares CPU, restart policy RESTART and the ulimits named in ULIMITS, in that
# order. Running when RUNNING is 1, it has the endpoint addresses and DNS names, and the null
# OomKillDisable, the engine gives a started container; otherwise none, and false, as created.
t_container_json() {
    jq -c -n --arg id "$1" --arg number "$2" --arg image "$3" --arg ref "$T_IMAGE_REF" --arg hash "$4" \
        --arg started "$5" --arg running "$6" --argjson cpu "$7" --arg restart "$8" --rawfile env "$9" \
        --arg depends "${10}" --arg replace "${11}" --arg ulimits "${12}" '
        ("pi-test-loadgen-" + $number) as $name | ($running == "1") as $up
        | {Id: $id, Name: ("/" + $name), Image: $image,
            Config: {Hostname: $id, Image: $ref, Env: ($env | fromjson? // null),
                Labels: ({"com.docker.compose.service": "loadgen", "com.docker.compose.config-hash": $hash,
                    "com.docker.compose.container-number": $number, "com.docker.compose.depends_on": $depends}
                    + (if $replace == "" then {} else {"com.docker.compose.replace": $replace} end))},
            HostConfig: {CpuShares: $cpu, OomKillDisable: (if $up then null else false end),
                RestartPolicy: {Name: $restart, MaximumRetryCount: 0},
                Ulimits: ($ulimits | split(" ") | map({Name: ., Soft: 0, Hard: 0}))},
            NetworkSettings: {Networks: {"pi-test_default": {Aliases: [$name, "loadgen"],
                DNSNames: (if $up then [$name, "loadgen", $id[0:12]] else null end),
                IPAddress: (if $up then "172.18.0.5" else "" end), IPAMConfig: null, Links: null,
                DriverOpts: null, GwPriority: 0}}},
            State: {StartedAt: $started}}' | tr -d '\r'
}

# t_loadgen_fixture CID RUNNING ENV [DECLARED]: a project whose loadgen container CID (none when
# empty) runs when RUNNING is 1 and has the JSON environment ENV, answered by a docker stub. The
# container runs T_IMAGE_A, created from T_IMAGE_REF, which names T_IMAGE_A (t-ref-image), and its
# config-hash label is the t_config_hash of the settings in t-settings and its weight. Each
# compose up or rm of loadgen is logged to $RUN_DIR/docker-calls with the
# PORTFOLIO_INSIGHTS_ALERT_WEIGHT it was called with, then applied: up makes a new container,
# running for -d, that runs the image in t-ref-image with the config hash of the stub's Compose
# now (t_compose_weight_token), and whose weight is Compose's ${PORTFOLIO_INSIGHTS_ALERT_WEIGHT:-0},
# or absent when DECLARED is 0, as with compose files lacking the declaration; config --hash loadgen
# prints that hash and config --no-interpolate whether the weight is declared. The files t-fail,
# t-inspect-fail, t-identity-fail, t-image-missing, t-config-fail, t-declare-fail and t-exits in
# $RUN_DIR make up and rm fail, every inspect of loadgen fail, only its {{json .}} inspect fail,
# the image reference name no image, config --hash fail, config --no-interpolate fail, and a
# started container exit. hard_timeout, which bounds those calls, runs the stub here without the
# time limit, which harness-test.sh covers.
# Every docker call is also logged to $RUN_DIR/docker-all. docker inspect --format '{{json .}}'
# answers t_container_json of the container, with the CpuShares in t-cpu and the restart policy
# in t-restart, which docker update would change and a recreate resets to Compose's 0 and always.
# The twin check_loadgen_restorable creates, up --no-start ... --scale loadgen=2, is logged as an
# up is and becomes container lg-twin (t-twin-cid), not started, as Compose creates loadgen now:
# its environment and ulimits in another order, number 2, another depends_on label; docker rm
# --force --volumes ID is logged as "docker rm ..." and removes it. t-twin-create-fail makes the
# create fail before it creates the twin, t-twin-create-fail-late after, t-twin-none create none,
# t-twin-inspect-fail fail its inspect, t-twin-rm-fail fail its removal, t-twin-rm-fail-once only
# the first one, t-twin-rm-noop leave it in place while succeeding, t-ps-fail fail every
# ps -a -q loadgen, t-ps-fail-with-twin fail those while a twin exists, and t-vanish-after-env
# remove loadgen's container once its environment has been read.
t_loadgen_fixture() {
    echo "$1" >"$RUN_DIR/t-cid"
    echo "$2" >"$RUN_DIR/t-running"
    echo "$3" >"$RUN_DIR/t-env"
    echo "${4:-1}" >"$RUN_DIR/t-declared"
    echo "as at start" >"$RUN_DIR/t-settings"
    echo "$T_IMAGE_A" >"$RUN_DIR/t-image"
    echo "$T_IMAGE_A" >"$RUN_DIR/t-ref-image"
    echo "$T_STARTED_AT" >"$RUN_DIR/t-started"
    echo 0 >"$RUN_DIR/t-cpu"
    echo always >"$RUN_DIR/t-restart"
    : >"$RUN_DIR/t-replace"
    : >"$RUN_DIR/t-twin-cid"
    t_config_hash "$(t_env_weight_token)" >"$RUN_DIR/t-label"
    : >"$RUN_DIR/docker-calls"
    : >"$RUN_DIR/docker-all"
    hard_timeout() {
        shift
        "$@"
    }
    docker() {
        local weight="${PORTFOLIO_INSIGHTS_ALERT_WEIGHT-(unset)}" cid twin
        echo "$*" >>"$RUN_DIR/docker-all"
        cid="$(cat "$RUN_DIR/t-cid")"
        twin="$(cat "$RUN_DIR/t-twin-cid")"
        if [[ "$1" == "rm" ]]; then
            echo "docker $*" >>"$RUN_DIR/docker-calls"
            if [[ -f "$RUN_DIR/t-twin-rm-fail" || -f "$RUN_DIR/t-twin-rm-fail-once" ]]; then
                rm -f "$RUN_DIR/t-twin-rm-fail-once"
                echo "Error response from daemon: simulated removal failure" >&2
                return 1
            fi
            if [[ "$*" == "rm --force --volumes $twin" && -n "$twin" && ! -f "$RUN_DIR/t-twin-rm-noop" ]]; then
                : >"$RUN_DIR/t-twin-cid"
            fi
            return 0
        fi
        if [[ "$1 $2" == "image inspect" ]]; then
            if [[ "$*" == "image inspect --format {{.Id}} $T_IMAGE_REF" && ! -f "$RUN_DIR/t-image-missing" ]]; then
                cat "$RUN_DIR/t-ref-image"
                return 0
            fi
            echo "Error response from daemon: No such image: ${*: -1}" >&2
            return 1
        fi
        if [[ "$1" == "inspect" ]]; then
            if [[ "${*: -1}" == "db-adapter-1" ]]; then
                echo '["DB_TYPE=postgres"]'
            elif [[ -n "$cid" && "${*: -1}" == "$cid" && "$3" == "{{json .Config.Env}}" &&
                ! -f "$RUN_DIR/t-inspect-fail" ]]; then
                cat "$RUN_DIR/t-env"
                if [[ -f "$RUN_DIR/t-vanish-after-env" ]]; then
                    : >"$RUN_DIR/t-cid"
                fi
            elif [[ -n "$cid" && "${*: -1}" == "$cid" && "$3" == "{{json .}}" &&
                ! -f "$RUN_DIR/t-inspect-fail" && ! -f "$RUN_DIR/t-identity-fail" ]]; then
                t_container_json "$cid" 1 "$(cat "$RUN_DIR/t-image")" "$(cat "$RUN_DIR/t-label")" \
                    "$(cat "$RUN_DIR/t-started")" "$(cat "$RUN_DIR/t-running")" "$(cat "$RUN_DIR/t-cpu")" \
                    "$(cat "$RUN_DIR/t-restart")" "$RUN_DIR/t-env" "" "$(cat "$RUN_DIR/t-replace")" "core nofile"
            elif [[ -n "$twin" && "${*: -1}" == "$twin" && "$3" == "{{json .}}" &&
                ! -f "$RUN_DIR/t-twin-inspect-fail" ]]; then
                cat "$RUN_DIR/t-twin.json"
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
            "config --hash loadgen")
                if [[ -f "$RUN_DIR/t-config-fail" ]]; then
                    echo "simulated compose failure" >&2
                    return 1
                fi
                echo "loadgen $(t_config_hash "$(t_compose_weight_token)")"
                ;;
            "config --no-interpolate --format json")
                if [[ -f "$RUN_DIR/t-declare-fail" ]]; then
                    echo "simulated compose failure" >&2
                    return 1
                fi
                # shellcheck disable=SC2016 # The declaration is Compose's text, never expanded.
                jq -c -n --arg declared "$(cat "$RUN_DIR/t-declared")" '{services: {loadgen: {environment:
                    ({EASYTRADE_URL: "http://reverse-proxy"} + (if $declared == "1" then
                        {PORTFOLIO_INSIGHTS_ALERT_WEIGHT: "${PORTFOLIO_INSIGHTS_ALERT_WEIGHT:-0}"} else {} end))}}}'
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
                if [[ -f "$RUN_DIR/t-ps-fail" || (-n "$twin" && -f "$RUN_DIR/t-ps-fail-with-twin") ]]; then
                    echo "simulated compose failure" >&2
                    return 1
                fi
                if [[ -n "$cid" ]]; then
                    echo "$cid"
                fi
                if [[ -n "$twin" ]]; then
                    echo "$twin"
                fi
                ;;
            # check_loadgen_restorable's twin, created without starting it as Compose creates loadgen
            # now, with the weight it is called with.
            "up --no-start --no-deps --no-recreate --no-build --pull never --scale loadgen=2 loadgen")
                echo "$* | weight $weight" >>"$RUN_DIR/docker-calls"
                if [[ -f "$RUN_DIR/t-twin-create-fail" ]]; then
                    echo "simulated compose failure" >&2
                    return 1
                fi
                if [[ ! -f "$RUN_DIR/t-twin-none" ]]; then
                    if [[ "$(cat "$RUN_DIR/t-declared")" == "1" ]]; then
                        jq -c -n --arg entry "PORTFOLIO_INSIGHTS_ALERT_WEIGHT=${PORTFOLIO_INSIGHTS_ALERT_WEIGHT:-0}" \
                            '[$entry, "EASYTRADE_URL=http://reverse-proxy"]' | tr -d '\r' >"$RUN_DIR/t-twin-env"
                    else
                        echo "$T_NO_WEIGHT" >"$RUN_DIR/t-twin-env"
                    fi
                    t_container_json lg-twin 2 "$(cat "$RUN_DIR/t-ref-image")" \
                        "$(t_config_hash "$(t_compose_weight_token)")" "0001-01-01T00:00:00Z" 0 0 always \
                        "$RUN_DIR/t-twin-env" "reverse-proxy:service_started:false" "" "nofile core" \
                        >"$RUN_DIR/t-twin.json"
                    echo lg-twin >"$RUN_DIR/t-twin-cid"
                fi
                if [[ -f "$RUN_DIR/t-twin-create-fail-late" ]]; then
                    echo "simulated compose failure after the create" >&2
                    return 1
                fi
                ;;
            # A window's recreate, and restore_loadgen's bounded recreates, which neither build nor
            # pull.
            "up -d --no-deps --force-recreate loadgen" | \
                "up -d --no-deps --force-recreate --no-build --pull never loadgen" | \
                "up --no-start --no-deps --force-recreate --no-build --pull never loadgen" | \
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
                # The container it replaces, and what Compose sets that docker update may have
                # changed on that one.
                echo "$cid" >"$RUN_DIR/t-replace"
                echo loadgen-recreated >"$RUN_DIR/t-cid"
                echo 0 >"$RUN_DIR/t-cpu"
                echo always >"$RUN_DIR/t-restart"
                cp "$RUN_DIR/t-ref-image" "$RUN_DIR/t-image"
                t_config_hash "$(t_compose_weight_token)" >"$RUN_DIR/t-label"
                if [[ "$2" == "-d" && ! -f "$RUN_DIR/t-exits" ]]; then
                    echo 1 >"$RUN_DIR/t-running"
                    echo "2026-01-01T01:00:00.000000001Z" >"$RUN_DIR/t-started"
                else
                    echo 0 >"$RUN_DIR/t-running"
                    echo "0001-01-01T00:00:00Z" >"$RUN_DIR/t-started"
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

# t_stub_flag_service: http answers 200 with the flag off and modifiable, as a ready stack does:
# every field feature-flag-service serializes from flag/model.go's Flag.
t_stub_flag_service() {
    http() {
        HTTP_STATUS="200"
        HTTP_ERROR=""
        HTTP_BODY="{\"id\":\"$FLAG_ID\",\"enabled\":false,\"name\":\"Portfolio insights\",\"description\":\"Demo feature, not financial advice.\",\"isModifiable\":true,\"tag\":\"feature\"}"
    }
}

# t_capture_start: records loadgen at start as setup does, with the image ID, config hash,
# effective configuration, start time and container ID check_loadgen_restorable records, whether
# or not the container is restorable.
t_capture_start() {
    local identity
    LOADGEN_AT_START="$(loadgen_state && printf x)"
    LOADGEN_AT_START="${LOADGEN_AT_START%x}"
    if [[ "$LOADGEN_AT_START" == running,* ]]; then
        LOADGEN_WAS_RUNNING=1
    fi
    identity="$(loadgen_identity "$RUN_DIR/loadgen-at-start.config.json")"
    IFS=$'\t' read -r LOADGEN_IMAGE_AT_START LOADGEN_HASH_AT_START _ LOADGEN_STARTED_AT LOADGEN_ID_AT_START \
        <<<"$identity"
    if [[ -n "$identity" ]]; then
        LOADGEN_CONFIG_AT_START="$RUN_DIR/loadgen-at-start.config.json"
    fi
}

# t_short HASH: the first 12 hex digits of HASH, a digest with or without its sha256: prefix.
t_short() {
    local hex="${1#sha256:}"
    printf '%s' "${hex:0:12}"
}

# t_weight_hash VALUE: the config hash the docker stub's Compose gives loadgen with the declared
# weight VALUE and the settings in t-settings.
t_weight_hash() {
    t_config_hash "$(printf '%s' "$1" | base64 -w0)"
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
    local i hash identity restorable calls config
    local twin_create="up --no-start --no-deps --no-recreate --no-build --pull never --scale loadgen=2 loadgen"
    local cids=(lg-1 lg-1 "")
    local running=(1 0 0)
    local envs=("$T_WEIGHT_2" "$T_NO_WEIGHT" '[]')
    # The second row's compose files drop the weight's declaration, as an override file can, so
    # its container, which has no weight entry, is restorable through the unset-weight recreate.
    local declared=(1 0 1)
    local expected=("running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=2" "stopped, PORTFOLIO_INSIGHTS_ALERT_WEIGHT unset"
        "no container")
    # The twin is created with the weight at start, set or unset, never the shell's, and removed.
    local twin_weights=(2 "(unset)" "")
    # A shell value that differs from the weight at start: the restorability check predicts the
    # hash under the weight the restore sets, not this one.
    export PORTFOLIO_INSIGHTS_ALERT_WEIGHT=5
    for i in "${!cids[@]}"; do
        t_fresh_run_dir
        t_loadgen_fixture "${cids[$i]}" "${running[$i]}" "${envs[$i]}" "${declared[$i]}"
        t_stub_flag_service
        hash="$(cat "$RUN_DIR/t-label")"
        identity="$T_IMAGE_A $hash $T_STARTED_AT lg-1"
        restorable="PASS loadgen restorable: image ID $(t_short "$T_IMAGE_A") ($T_IMAGE_REF) and config hash $(t_short "$hash"), as these compose files give it, and a twin created from them, now removed, matched its effective configuration"
        calls="$(printf '%s\n' "$twin_create | weight ${twin_weights[$i]}" "docker rm --force --volumes lg-twin")"
        config="$RUN_DIR/loadgen-at-start.config.json"
        if [[ -z "${cids[$i]}" ]]; then
            identity="   "
            restorable="PASS loadgen restorable: no loadgen container at start; the one this run creates is removed on exit"
            calls=""
            config=""
        fi
        setup
        t_eq "setup records loadgen at start as [${expected[$i]}]" \
            "${expected[$i]}; was running ${running[$i]}" "$LOADGEN_AT_START; was running $LOADGEN_WAS_RUNNING"
        t_report_has "setup reports loadgen at start as [${expected[$i]}]" \
            "INFO db type postgres; loadgen at start: ${expected[$i]}"
        t_report_has "setup passes loadgen at start [${expected[$i]}] as restorable" "$restorable"
        t_eq "setup records the image ID, config hash, start time and container ID of loadgen at start [${expected[$i]}]" \
            "$identity" "$LOADGEN_IMAGE_AT_START $LOADGEN_HASH_AT_START $LOADGEN_STARTED_AT $LOADGEN_ID_AT_START"
        t_eq "setup records the effective configuration of loadgen at start [${expected[$i]}]" \
            "$config" "$LOADGEN_CONFIG_AT_START"
        t_eq "setup creates and removes one twin, and changes nothing else, with loadgen at start [${expected[$i]}]" \
            "$calls" "$(cat "$RUN_DIR/docker-calls")"
        t_eq "setup leaves no twin and loadgen at start as it was [${expected[$i]}]" \
            "twin [] tracked [] loadgen [${cids[$i]}] running [${running[$i]}]" \
            "twin [$(cat "$RUN_DIR/t-twin-cid")] tracked [$LOADGEN_TWIN] loadgen [$(cat "$RUN_DIR/t-cid")] running [$(cat "$RUN_DIR/t-running")]"
        t_eq "setup leaves the shell's weight with loadgen at start [${expected[$i]}]" 5 \
            "$PORTFOLIO_INSIGHTS_ALERT_WEIGHT"
    done
}

# The changes t_restorable_case makes to the docker stub's state before setup, one per function.
# shellcheck disable=SC2329 # Each runs through t_restorable_case.
t_settings_changed() {
    echo "other settings" >"$RUN_DIR/t-settings"
}
# shellcheck disable=SC2329 # Runs through t_restorable_case.
t_image_rebuilt() {
    echo "$T_IMAGE_B" >"$RUN_DIR/t-ref-image"
}
# shellcheck disable=SC2329 # Runs through t_restorable_case.
t_image_missing() {
    touch "$RUN_DIR/t-image-missing"
}
# t_weight_unset_at_start: a container without a weight entry, created from compose files that did
# not declare it.
# shellcheck disable=SC2329 # Runs through t_restorable_case.
t_weight_unset_at_start() {
    echo "$T_NO_WEIGHT" >"$RUN_DIR/t-env"
    t_config_hash - >"$RUN_DIR/t-label"
}
# t_weight_empty_at_start: a container whose weight entry is empty, created from compose files
# that leave an empty value empty.
# shellcheck disable=SC2329 # Runs through t_restorable_case.
t_weight_empty_at_start() {
    echo '["EASYTRADE_URL=http://reverse-proxy","PORTFOLIO_INSIGHTS_ALERT_WEIGHT="]' >"$RUN_DIR/t-env"
    t_weight_hash "" >"$RUN_DIR/t-label"
}
# shellcheck disable=SC2329 # Runs through t_restorable_case.
t_identity_unreadable() {
    touch "$RUN_DIR/t-identity-fail"
}
# shellcheck disable=SC2329 # Runs through t_restorable_case.
t_config_hash_fails() {
    touch "$RUN_DIR/t-config-fail"
}
# shellcheck disable=SC2329 # Runs through t_restorable_case.
t_declaration_unreadable() {
    touch "$RUN_DIR/t-declare-fail"
}

# t_restorable_case DETAIL CHANGE...: setup, in a fresh run directory, of a project whose loadgen
# runs with weight 2 under compose files declaring it, after each CHANGE function alters the
# stub's state, ends with "FAIL loadgen restorable: DETAIL" as its only check, with no container
# changed and no request sent. In DETAIL, @RUN_DIR@ stands for that directory, @START@ for the
# short config hash of the container, @NOW@ for the one the stub's Compose gives loadgen with
# weight 2 and @ZERO@ for the one with weight 0.
t_restorable_case() {
    (
        local detail="$1" change changes
        shift
        changes="$*"
        t_fresh_run_dir
        t_loadgen_fixture lg-1 1 "$T_WEIGHT_2"
        : >"$RUN_DIR/http-calls"
        http() {
            echo "$1 $2" >>"$RUN_DIR/http-calls"
            HTTP_STATUS="000"
            HTTP_ERROR="not expected"
            HTTP_BODY=""
        }
        for change in "$@"; do
            "$change"
        done
        detail="${detail//@RUN_DIR@/$RUN_DIR}"
        detail="${detail//@START@/$(t_short "$(cat "$RUN_DIR/t-label")")}"
        detail="${detail//@NOW@/$(t_short "$(t_weight_hash 2)")}"
        detail="${detail//@ZERO@/$(t_short "$(t_weight_hash 0)")}"
        (setup) >/dev/null 2>&1 || true
        t_report_has "setup refuses loadgen after [$changes]" "FAIL loadgen restorable: $detail"
        # Besides the run lock, which setup takes before it reads anything.
        t_eq "setup refusing loadgen after [$changes] reports no other check" 1 \
            "$(grep -E '^(PASS|FAIL) ' "$RUN_DIR/report" | grep -cvF 'PASS run lock: ')"
        t_eq "setup refusing loadgen after [$changes] changes no container" "" "$(cat "$RUN_DIR/docker-calls")"
        t_eq "setup refusing loadgen after [$changes] sends no request" "" "$(cat "$RUN_DIR/http-calls")"
    )
}

test_check_loadgen_restorable_unrestorableStates_failsBeforeAnyChange() {
    local prefix="a recreate from these compose files would not give loadgen back as it is, so the run changes nothing: "
    local hash_differs="these compose files give loadgen config hash @NOW@ under its weight at start, its container has @START@"
    local zero="these compose files give loadgen config hash @ZERO@ under its weight at start, its container has @START@"
    local rebuilt
    rebuilt="its image reference $T_IMAGE_REF now names image ID $(t_short "$T_IMAGE_B"), its container runs $(t_short "$T_IMAGE_A")"
    # The shell's own weight, which the prediction never uses: it sets the weight at start, or
    # leaves it unset.
    export PORTFOLIO_INSIGHTS_ALERT_WEIGHT=5
    t_restorable_case "$prefix$hash_differs" t_settings_changed
    t_restorable_case "$prefix$rebuilt" t_image_rebuilt
    t_restorable_case "${prefix}its image reference $T_IMAGE_REF names no image a recreate could run: docker image inspect failed, exit 1 (see @RUN_DIR@/compose.log)" \
        t_image_missing
    t_restorable_case "$prefix$hash_differs; $rebuilt" t_settings_changed t_image_rebuilt
    # A weight entry unset or empty, which compose files declaring ${PORTFOLIO_INSIGHTS_ALERT_WEIGHT:-0}
    # never give a container.
    t_restorable_case "$prefix$zero; its PORTFOLIO_INSIGHTS_ALERT_WEIGHT is unset, and these compose files always declare it" \
        t_weight_unset_at_start
    t_restorable_case "$prefix$zero; its PORTFOLIO_INSIGHTS_ALERT_WEIGHT is empty, and these compose files always declare it" \
        t_weight_empty_at_start
}

test_check_loadgen_restorable_dockerCallFails_failsNamingCall() {
    t_restorable_case "reading loadgen's image, config hash and effective configuration failed, exit 1 (see @RUN_DIR@/compose.log)" \
        t_identity_unreadable
    t_restorable_case "docker compose config --hash loadgen failed, exit 1 (see @RUN_DIR@/compose.log)" \
        t_config_hash_fails
    t_restorable_case "a recreate from these compose files would not give loadgen back as it is, so the run changes nothing: these compose files give loadgen config hash @ZERO@ under its weight at start, its container has @START@; whether these compose files declare PORTFOLIO_INSIGHTS_ALERT_WEIGHT is unknown: docker compose config --no-interpolate failed, exit 1 (see @RUN_DIR@/compose.log)" \
        t_weight_unset_at_start t_declaration_unreadable
}

test_predicted_loadgen_hash_outputWithoutHash_failsAndLogsIt() {
    local rc=0
    t_loadgen_fixture lg-1 1 "$T_WEIGHT_2"
    t_capture_start
    compose_within() {
        echo "loadgen"
    }
    predicted_loadgen_hash >/dev/null || rc=$?
    t_eq "predicted_loadgen_hash fails on output without a hash" 1 "$rc"
    t_eq "predicted_loadgen_hash logs that output" \
        "docker compose config --hash loadgen printed no hash: loadgen" "$(cat "$RUN_DIR/compose.log")"
}

test_short_digest_values_printsShortDigestNoneOrQuoted() {
    local i
    local values=("$T_IMAGE_A" "${T_IMAGE_A#sha256:}" "" "-" "not a digest" "${T_IMAGE_A^^}")
    local expected=("$(t_short "$T_IMAGE_A")" "$(t_short "$T_IMAGE_A")" none none 'not\ a\ digest'
        "$(printf '%q' "${T_IMAGE_A^^}")")
    for i in "${!values[@]}"; do
        t_eq "short_digest of [${values[$i]}]" "${expected[$i]}" "$(short_digest "${values[$i]}")"
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
    t_eq "restore_loadgen recreates loadgen started with its weight 2 after the run's weight 1, neither building nor pulling" \
        "$(printf '%s\n' "up -d --no-deps --force-recreate loadgen | weight 1" \
            "up -d --no-deps --force-recreate --no-build --pull never loadgen | weight 2")" "$(cat "$RUN_DIR/docker-calls")"
    t_eq "restore_loadgen verifies loadgen running with weight 2" \
        "0 [] running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=2" "$rc [$RESTORE_ERROR] $(loadgen_state)"
    t_eq "restore_loadgen leaves loadgen with its image ID and config hash at start" \
        "$LOADGEN_IMAGE_AT_START $LOADGEN_HASH_AT_START" "$(loadgen_identity | cut -f 1,2 | tr '\t' ' ')"
}

test_restore_loadgen_stoppedWithWeight2_recreatesWithoutStarting() {
    local rc=0
    unset PORTFOLIO_INSIGHTS_ALERT_WEIGHT
    t_loadgen_fixture lg-1 0 "$T_WEIGHT_2"
    t_capture_start
    recreate_loadgen 1
    restore_loadgen || rc=$?
    t_eq "restore_loadgen recreates a loadgen stopped at start with --no-start and weight 2" \
        "up --no-start --no-deps --force-recreate --no-build --pull never loadgen | weight 2" \
        "$(sed -n '2p' "$RUN_DIR/docker-calls")"
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
    t_eq "restore_loadgen recreates loadgen without the shell's weight, neither building nor pulling" \
        "up -d --no-deps --force-recreate --no-build --pull never loadgen | weight (unset)" \
        "$(cat "$RUN_DIR/docker-calls")"
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
    t_report_has "cleanup reports loadgen restored as at start, naming every verified field" \
        "INFO cleanup: loadgen restored as at start: running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=2, image ID $(t_short "$T_IMAGE_A"), config hash $(t_short "$(t_weight_hash 2)"), effective configuration verified as recorded at start"
    t_report_has "cleanup passes after the restore" "PASS cleanup"
}

test_cleanup_weightWithControlCharacters_restoresItByteExactAndPrintsItQuoted() {
    local after hash
    unset PORTFOLIO_INSIGHTS_ALERT_WEIGHT
    t_loadgen_fixture lg-1 1 '["EASYTRADE_URL=http://reverse-proxy","PORTFOLIO_INSIGHTS_ALERT_WEIGHT=2\r\n"]'
    # The container's own hash, from that weight's bytes as docker inspect's JSON gives them.
    hash="$(cat "$RUN_DIR/t-label")"
    t_capture_start
    recreate_loadgen 1
    t_cleanup
    after="$(loadgen_state && printf x)"
    t_eq "cleanup restores a weight ending in a carriage return and a line feed byte for byte" \
        "running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=2"$'\r\n'"x" "$after"
    t_report_has "cleanup prints that weight quoted, on one line" \
        "INFO cleanup: loadgen restored as at start: running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=\$'2\\r\\n', image ID $(t_short "$T_IMAGE_A"), config hash $(t_short "$hash"), effective configuration verified as recorded at start"
    t_report_has "cleanup passes after that restore" "PASS cleanup"
}

test_cleanup_restoredStateDiffers_failsNamingExpectedAndActual() {
    local i
    local -a expected
    # The weight unset at start against compose files declaring it, which also changes the config
    # hash and the environment, and a container that exits.
    local envs=("$T_NO_WEIGHT" "$T_WEIGHT_2")
    local exits=(0 1)
    unset PORTFOLIO_INSIGHTS_ALERT_WEIGHT
    for i in "${!envs[@]}"; do
        t_fresh_run_dir
        t_loadgen_fixture lg-1 1 "${envs[$i]}"
        expected=(
            "expected [running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT unset] as at start, got [running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=0]; config hash $(t_short "$(t_weight_hash 0)") instead of $(t_short "$(t_config_hash -)") as at start; Config.Env differs from the one at start"
            "expected [running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=2] as at start, got [stopped, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=2]")
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
    local cids=(lg-1 lg-1 "" lg-1 lg-1)
    local envs=("$T_WEIGHT_2" "$T_NO_WEIGHT" '[]' "$T_WEIGHT_2" "$T_WEIGHT_2")
    local declared=(1 0 1 1 1)
    local switches=(t-fail t-fail t-fail t-inspect-fail t-identity-fail)
    local expected=("recreating loadgen as [running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=2] failed, exit 1"
        "recreating loadgen as [running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT unset] failed, exit 1"
        "removing the loadgen container this run created failed, exit 1"
        "reading loadgen's state after the restore failed, exit 1"
        "reading loadgen's image, config hash and effective configuration after the restore failed, exit 1")
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

test_cleanup_identityChangedDuringRun_failsNamingEachDifferingField() {
    local i change image_differs hash_differs
    local -a expected
    local changes=(t_image_rebuilt t_settings_changed "t_image_rebuilt t_settings_changed")
    unset PORTFOLIO_INSIGHTS_ALERT_WEIGHT
    for i in "${!changes[@]}"; do
        t_fresh_run_dir
        t_loadgen_fixture lg-1 1 "$T_WEIGHT_2"
        t_capture_start
        recreate_loadgen 1
        # The image rebuilt, or the compose files changed, while the run went on.
        # shellcheck disable=SC2086 # The row splits into one function name per word.
        for change in ${changes[$i]}; do
            "$change"
        done
        image_differs="image ID $(t_short "$T_IMAGE_B") instead of $(t_short "$T_IMAGE_A") as at start"
        hash_differs="config hash $(t_short "$(t_weight_hash 2)") instead of $(t_short "$LOADGEN_HASH_AT_START") as at start"
        expected=("$image_differs" "$hash_differs" "$image_differs; $hash_differs")
        t_cleanup
        t_report_has "cleanup fails naming what differs after [${changes[$i]}]" \
            "FAIL cleanup: loadgen not restored: ${expected[$i]}"
        t_eq "cleanup still recreates loadgen with its weight at start after [${changes[$i]}]" \
            "up -d --no-deps --force-recreate --no-build --pull never loadgen | weight 2" \
            "$(sed -n '2p' "$RUN_DIR/docker-calls")"
    done
}

# ---------------------------------------------------------------------------------------------
# Effective configuration and the twin (loadgen_config_snapshot, snapshot_differences,
# loadgen_twin_check, remove_loadgen_twin)

# The changes docker update makes to a container after Compose created it, which its config hash
# does not show and its twin does, one per function, applied to the stub's container at start.
# shellcheck disable=SC2329 # Runs through t_twin_refusal_case and the restore cases.
t_cpu_shares_updated() {
    echo 128 >"$RUN_DIR/t-cpu"
}
# shellcheck disable=SC2329 # Runs through t_twin_refusal_case and the restore cases.
t_restart_policy_updated() {
    echo no >"$RUN_DIR/t-restart"
}
# t_second_loadgen_container: a second loadgen container in the project before the run, as a
# scale-up leaves one.
# shellcheck disable=SC2329 # Runs through t_twin_refusal_case.
t_second_loadgen_container() {
    echo lg-2 >"$RUN_DIR/t-twin-cid"
}

# t_twin_refusal_case DETAIL CALLS TWIN LEFT CHANGE...: setup, in a fresh run directory, of a
# project whose loadgen runs with weight 2 under compose files declaring it, after each CHANGE
# alters the stub's state (a function, or +FILE, which creates that switch file in $RUN_DIR),
# ends with "FAIL loadgen restorable: DETAIL" as its only check besides the run lock and before
# any request, with the container found at start as it was, the docker calls CALLS logged (their
# docker-calls lines joined by ;), container TWIN left beside it (none when empty) and
# LOADGEN_TWIN at LEFT on exit, which cleanup reads. @RUN_DIR@ in DETAIL stands for that directory.
t_twin_refusal_case() {
    (
        local detail="$1" calls="$2" twin="$3" left="$4" lf=$'\n' change changes before rc=0
        shift 4
        changes="$*"
        t_fresh_run_dir
        t_loadgen_fixture lg-1 1 "$T_WEIGHT_2"
        : >"$RUN_DIR/http-calls"
        http() {
            echo "$1 $2" >>"$RUN_DIR/http-calls"
            HTTP_STATUS="000"
            HTTP_ERROR="not expected"
            HTTP_BODY=""
        }
        for change in "$@"; do
            if [[ "$change" == +* ]]; then
                touch "$RUN_DIR/${change#+}"
            else
                "$change"
            fi
        done
        before="$(cat "$RUN_DIR/t-cid" "$RUN_DIR/t-running" "$RUN_DIR/t-env" "$RUN_DIR/t-cpu" "$RUN_DIR/t-restart" | join_lines)"
        detail="${detail//@RUN_DIR@/$RUN_DIR}"
        (
            trap 'echo "LOADGEN_TWIN=$LOADGEN_TWIN FLAG_TOUCHED=$FLAG_TOUCHED LOADGEN_TOUCHED=$LOADGEN_TOUCHED" >"$RUN_DIR/setup.state"' EXIT
            setup
        ) >/dev/null 2>&1 || rc=$?
        t_report_has "setup refuses loadgen after [$changes]" "FAIL loadgen restorable: $detail"
        t_eq "setup refusing loadgen after [$changes] ends the run before any other check or request" \
            "status 1, 1 check, 0 requests" \
            "status $rc, $(grep -E '^(PASS|FAIL) ' "$RUN_DIR/report" | grep -cvF 'PASS run lock: ') check, $(grep -c . "$RUN_DIR/http-calls" || true) requests"
        t_eq "setup refusing loadgen after [$changes] makes only the twin's docker calls" "${calls//;/$lf}" \
            "$(cat "$RUN_DIR/docker-calls")"
        t_eq "setup refusing loadgen after [$changes] leaves loadgen at start as it was" "$before" \
            "$(cat "$RUN_DIR/t-cid" "$RUN_DIR/t-running" "$RUN_DIR/t-env" "$RUN_DIR/t-cpu" "$RUN_DIR/t-restart" | join_lines)"
        t_eq "setup refusing loadgen after [$changes] leaves twin [$twin] tracked as [$left], the flag and loadgen untouched" \
            "twin [$twin] LOADGEN_TWIN=$left FLAG_TOUCHED=0 LOADGEN_TOUCHED=0" \
            "twin [$(cat "$RUN_DIR/t-twin-cid")] $(cat "$RUN_DIR/setup.state")"
    )
}

test_loadgen_config_snapshot_perContainerFields_leftOutOfTheComparison() {
    local i filter twin hash="stub-config-hash"
    local -a filters expected
    echo "$T_WEIGHT_2" >"$RUN_DIR/env-a"
    echo '["PORTFOLIO_INSIGHTS_ALERT_WEIGHT=2","EASYTRADE_URL=http://reverse-proxy"]' >"$RUN_DIR/env-b"
    # Container lg-1, running as at start, and lg-twin as Compose creates it, not started: they
    # differ in their IDs, names, hostnames, numbers, depends_on and replace labels, own aliases,
    # DNS names, addresses, OomKillDisable null and false, and the order of the environment and
    # the ulimits.
    t_container_json lg-1 1 "$T_IMAGE_A" "$hash" "$T_STARTED_AT" 1 0 always "$RUN_DIR/env-a" "" "" \
        "core nofile" | loadgen_config_snapshot >"$RUN_DIR/a.json"
    twin="$(t_container_json lg-twin 2 "$T_IMAGE_A" "$hash" "0001-01-01T00:00:00Z" 0 0 always \
        "$RUN_DIR/env-b" "reverse-proxy:service_started:false" lg-0 "nofile core")"
    t_eq "loadgen_config_snapshot keeps no field naming one container or derived while it runs" 0 \
        "$(grep -c -e lg-1 -e pi-test-loadgen-1 -e 172.18 -e DNSNames -e Hostname -e container-number \
            -e com.docker.compose.replace -e depends_on "$RUN_DIR/a.json" || true)"
    # FILTER on the twin's docker inspect object, and the field the comparison then names, none
    # for a field the snapshot leaves out.
    filters=('.' '.Config.Hostname = "loadgen-host"' '.NetworkSettings.Networks["pi-test_default"].MacAddress = "02:42:ac:12:00:05"'
        '.HostConfig.CpuShares = 128' '.Config.Labels["com.docker.compose.version"] = "5.3.1"'
        '.NetworkSettings.Networks["pi-test_default"].Aliases += ["lg-alias"]'
        '.NetworkSettings.Networks.other = {Aliases: ["lg-alias"]}' '.HostConfig.OomKillDisable = true')
    expected=("" "" "" "its HostConfig.CpuShares is 0, a recreate gives 128"
        "its Config.Labels.com.docker.compose.version is absent, a recreate gives 5.3.1"
        "its Networks.pi-test_default.Aliases differs from what a recreate gives"
        "its Networks.other is absent, a recreate gives a map"
        "its HostConfig.OomKillDisable is false, a recreate gives true")
    for i in "${!filters[@]}"; do
        filter="${filters[$i]}"
        jq -c "$filter" <<<"$twin" | tr -d '\r' | loadgen_config_snapshot >"$RUN_DIR/b.json"
        t_eq "loadgen_config_snapshot of a running container and its created twin after [$filter]" \
            "${expected[$i]}" "$(snapshot_differences "$RUN_DIR/a.json" "$RUN_DIR/b.json" check)"
    done
}

test_snapshot_differences_valueKinds_namesFieldsWithoutListContents() {
    local i out
    local -a filters modes expected
    echo '{"Config": {"Env": ["A=1"], "Labels": {"com.docker.compose.config-hash": "h1"}},
        "HostConfig": {"CpuShares": 0}, "Image": "sha256:1", "Networks": {}}' | jq -S . | tr -d '\r' >"$RUN_DIR/a.json"
    filters=('.HostConfig.CpuShares = 128' '.HostConfig.CpuShares = 128' '.Config.Labels.note = "a\nb c"'
        '.Config.Env = ["A=secret-7d1e"]' '.Config.Labels["x y"] = ""'
        '.Image = "sha256:2" | .Config.Labels["com.docker.compose.config-hash"] = "h2"'
        '.Config.Labels["com.docker.compose.image"] = "sha256:2"')
    modes=(check restore check check restore check check)
    expected=("its HostConfig.CpuShares is 0, a recreate gives 128" "HostConfig.CpuShares 128 instead of 0 as at start"
        "its Config.Labels.note is absent, a recreate gives \$'a\\nb c'" "its Config.Env differs from what a recreate gives"
        "Config.Labels.\"x y\" '' instead of absent as at start" "" "")
    for i in "${!filters[@]}"; do
        jq -S "${filters[$i]}" "$RUN_DIR/a.json" | tr -d '\r' >"$RUN_DIR/b.json"
        out="$(snapshot_differences "$RUN_DIR/a.json" "$RUN_DIR/b.json" "${modes[$i]}")"
        t_eq "snapshot_differences in mode ${modes[$i]} after [${filters[$i]}]" "${expected[$i]}" "$out"
        t_eq "snapshot_differences prints no list content after [${filters[$i]}]" 0 \
            "$(grep -c secret-7d1e <<<"$out" || true)"
    done
    jq -S '.HostConfig += ([range(12)] | map({key: "X\(. + 10)", value: 1}) | from_entries)' "$RUN_DIR/a.json" |
        tr -d '\r' >"$RUN_DIR/b.json"
    out="$(snapshot_differences "$RUN_DIR/a.json" "$RUN_DIR/b.json" check)"
    t_eq "snapshot_differences names the first $SNAPSHOT_FIELDS_SHOWN of 12 differing fields and counts the rest" \
        "11 lines, first [its HostConfig.X10 is absent, a recreate gives 1], last [2 more fields differ]" \
        "$(grep -c . <<<"$out") lines, first [$(sed -n '1p' <<<"$out")], last [$(sed -n '$p' <<<"$out")]"
    t_eq "snapshot_differences fails on a missing configuration" "fails" \
        "$(snapshot_differences "$RUN_DIR/a.json" "$RUN_DIR/absent.json" check >/dev/null 2>&1 && echo passes || echo fails)"
}

test_check_loadgen_restorable_containerChangedOutsideCompose_failsBeforeAnyChangeAndRemovesTwin() {
    local prefix="a recreate from these compose files would not give loadgen back as it is, so the run changes nothing: "
    local suffix="; the twin that shows it is removed"
    local cpu="its HostConfig.CpuShares is 128, a recreate gives 0"
    local restart="its HostConfig.RestartPolicy differs from what a recreate gives"
    local calls="up --no-start --no-deps --no-recreate --no-build --pull never --scale loadgen=2 loadgen | weight 2;docker rm --force --volumes lg-twin"
    # The shell's own weight, which the twin never gets: it is created with the weight at start.
    export PORTFOLIO_INSIGHTS_ALERT_WEIGHT=5
    t_twin_refusal_case "$prefix$cpu$suffix" "$calls" "" "" t_cpu_shares_updated
    t_twin_refusal_case "$prefix$restart$suffix" "$calls" "" "" t_restart_policy_updated
    t_twin_refusal_case "$prefix$cpu; $restart$suffix" "$calls" "" "" t_cpu_shares_updated t_restart_policy_updated
}

test_check_loadgen_restorable_twinStepFails_failsNamingStepAndTracksAnyTwinLeft() {
    local create="up --no-start --no-deps --no-recreate --no-build --pull never --scale loadgen=2 loadgen | weight 2"
    local rm="docker rm --force --volumes lg-twin" log="(see @RUN_DIR@/compose.log)"
    t_twin_refusal_case "creating a twin loadgen container failed, exit 1 $log; no twin is left and nothing else was changed" \
        "$create" "" "" +t-twin-create-fail
    t_twin_refusal_case "creating a twin loadgen container failed, exit 1 $log; no twin is left and nothing else was changed" \
        "$create;$rm" "" "" +t-twin-create-fail-late
    t_twin_refusal_case "creating a twin loadgen container gave 0 new loadgen containers instead of 1; none is left and nothing else was changed" \
        "$create" "" "" +t-twin-none
    t_twin_refusal_case "reading the twin loadgen container's effective configuration failed, exit 1 $log; the twin is removed and nothing else was changed" \
        "$create;$rm" "" "" +t-twin-inspect-fail
    t_twin_refusal_case "twin loadgen container lg-twin not removed: removing twin loadgen container lg-twin failed, exit 1 $log; cleanup removes it on exit" \
        "$create;$rm" lg-twin lg-twin +t-twin-rm-fail
    t_twin_refusal_case "twin loadgen container lg-twin not removed: twin loadgen container lg-twin is still listed after its removal; cleanup removes it on exit" \
        "$create;$rm" lg-twin lg-twin +t-twin-rm-noop
    t_twin_refusal_case "listing loadgen's containers after creating its twin failed, exit 1 $log; cleanup removes the twin on exit" \
        "$create" lg-twin unknown +t-ps-fail-with-twin
    t_twin_refusal_case "the project has 2 loadgen containers, and a restore recreates one only; nothing was changed" \
        "" lg-2 "" t_second_loadgen_container
}

test_loadgen_twin_check_containerOrRecordUnusable_failsNamingCause() {
    local i rc
    local switches=(t-ps-fail t-gone "" "")
    local ids=(lg-1 lg-1 lg-0 lg-1)
    local configs=(recorded recorded recorded absent)
    local -a expected
    for i in "${!switches[@]}"; do
        t_fresh_run_dir
        t_loadgen_fixture lg-1 1 "$T_WEIGHT_2"
        t_capture_start
        expected=("listing loadgen's containers failed, exit 1 (see $RUN_DIR/compose.log); nothing was changed|"
            "loadgen's container was removed while setup read it; nothing was changed|"
            "loadgen's container was replaced while setup read it; nothing was changed|"
            "comparing loadgen's effective configuration with its twin's failed (see $RUN_DIR/compose.log); the twin is removed and nothing else was changed|up --no-start --no-deps --no-recreate --no-build --pull never --scale loadgen=2 loadgen | weight 2 docker rm --force --volumes lg-twin")
        case "${switches[$i]}" in
            t-gone) : >"$RUN_DIR/t-cid" ;;
            ?*) touch "$RUN_DIR/${switches[$i]}" ;;
        esac
        LOADGEN_ID_AT_START="${ids[$i]}"
        if [[ "${configs[$i]}" == absent ]]; then
            LOADGEN_CONFIG_AT_START="$RUN_DIR/absent.config.json"
        fi
        rc=0
        loadgen_twin_check "$LOADGEN_CONFIG_AT_START" || rc=$?
        t_eq "loadgen_twin_check fails after [${switches[$i]:-container ID ${ids[$i]}}, configuration ${configs[$i]}]" \
            "1 ${expected[$i]}" "$rc $TWIN_DETAIL|$(join_lines <"$RUN_DIR/docker-calls")"
        t_eq "loadgen_twin_check leaves no twin after [${switches[$i]:-container ID ${ids[$i]}}, configuration ${configs[$i]}]" \
            "twin [] tracked []" "twin [$(cat "$RUN_DIR/t-twin-cid")] tracked [$LOADGEN_TWIN]"
    done
}

test_cleanup_twinLeftByRestorabilityCheck_removesItOrFailsNamingCall() {
    local i switch
    local -a expected
    # TRACKED is LOADGEN_TWIN on exit and TWIN the stub's twin container; SWITCHES break calls.
    local tracked=(lg-twin unknown unknown lg-twin unknown lg-twin)
    local twins=(lg-twin lg-twin "" lg-twin lg-twin lg-twin)
    local switches=("" "" "" t-twin-rm-fail t-ps-fail "t-twin-rm-noop t-ps-fail-with-twin")
    local calls=(1 1 0 1 0 1)
    local left=("" "" "" lg-twin lg-twin lg-twin)
    for i in "${!tracked[@]}"; do
        t_fresh_run_dir
        t_loadgen_fixture lg-1 1 "$T_WEIGHT_2"
        echo "${twins[$i]}" >"$RUN_DIR/t-twin-cid"
        LOADGEN_ID_AT_START=lg-1
        LOADGEN_TWIN="${tracked[$i]}"
        # shellcheck disable=SC2086 # The row splits into one switch file per word.
        for switch in ${switches[$i]}; do
            touch "$RUN_DIR/$switch"
        done
        expected=("INFO cleanup: twin loadgen container lg-twin removed; no twin loadgen container is left|PASS cleanup"
            "INFO cleanup: twin loadgen container lg-twin removed; no twin loadgen container is left|PASS cleanup"
            "INFO cleanup: no twin loadgen container is left|PASS cleanup"
            "FAIL cleanup: twin loadgen container not removed: removing twin loadgen container lg-twin failed, exit 1 (see $RUN_DIR/compose.log)"
            "FAIL cleanup: twin loadgen container not removed: listing loadgen's containers to find its twin failed, exit 1 (see $RUN_DIR/compose.log)"
            "FAIL cleanup: twin loadgen container not removed: listing loadgen's containers after removing its twin failed, exit 1 (see $RUN_DIR/compose.log)")
        (cleanup) >"$RUN_DIR/cleanup.out" 2>&1 || true
        t_eq "cleanup with twin [${twins[$i]}] tracked as [${tracked[$i]}] after [${switches[$i]}]" "${expected[$i]}" \
            "$(grep -E '^(INFO cleanup: |PASS cleanup|FAIL cleanup)' "$RUN_DIR/report" | paste -s -d '|' - | tr -d '\r')"
        t_eq "cleanup removes twin [${twins[$i]}] tracked as [${tracked[$i]}] by its ID only after [${switches[$i]}]" \
            "${calls[$i]} removals, twin [${left[$i]}], loadgen [lg-1]" \
            "$(grep -c '^docker rm --force --volumes lg-twin$' "$RUN_DIR/docker-calls" || true) removals, twin [$(cat "$RUN_DIR/t-twin-cid")], loadgen [$(cat "$RUN_DIR/t-cid")]"
    done
}

test_setup_twinRemovalFailsOnce_cleanupRemovesTwinOnExit() {
    local rc=0
    t_loadgen_fixture lg-1 1 "$T_WEIGHT_2"
    t_stub_flag_service
    touch "$RUN_DIR/t-twin-rm-fail-once"
    (
        trap cleanup EXIT
        setup
    ) >"$RUN_DIR/run.out" 2>&1 || rc=$?
    t_report_has "setup fails the check naming the twin it could not remove" \
        "FAIL loadgen restorable: twin loadgen container lg-twin not removed: removing twin loadgen container lg-twin failed, exit 1 (see $RUN_DIR/compose.log); cleanup removes it on exit"
    t_report_has "cleanup removes that twin on exit" \
        "INFO cleanup: twin loadgen container lg-twin removed; no twin loadgen container is left"
    t_report_has "cleanup passes with the twin removed" "PASS cleanup"
    t_eq "the run creates the twin once, removes it twice and leaves loadgen at start as it was" \
        "status 1|up --no-start --no-deps --no-recreate --no-build --pull never --scale loadgen=2 loadgen | weight 2 docker rm --force --volumes lg-twin docker rm --force --volumes lg-twin|twin [] loadgen [lg-1] running [1]" \
        "status $rc|$(join_lines <"$RUN_DIR/docker-calls")|twin [$(cat "$RUN_DIR/t-twin-cid")] loadgen [$(cat "$RUN_DIR/t-cid")] running [$(cat "$RUN_DIR/t-running")]"
}

test_check_loadgen_restorable_containerRemovedWhileSetupReadIt_failsWithNothingChanged() {
    local rc=0
    t_loadgen_fixture lg-1 1 "$T_WEIGHT_2"
    # loadgen_state reads the container; it is gone when check_loadgen_restorable reads it again.
    touch "$RUN_DIR/t-vanish-after-env"
    : >"$RUN_DIR/http-calls"
    http() {
        echo "$1 $2" >>"$RUN_DIR/http-calls"
        HTTP_STATUS="000"
        HTTP_ERROR="not expected"
        HTTP_BODY=""
    }
    (
        trap 'echo "LOADGEN_AT_START=[$LOADGEN_AT_START] FLAG_TOUCHED=$FLAG_TOUCHED LOADGEN_TOUCHED=$LOADGEN_TOUCHED LOADGEN_TWIN=[$LOADGEN_TWIN]" >"$RUN_DIR/setup.state"' EXIT
        setup
    ) >/dev/null 2>&1 || rc=$?
    t_report_has "check_loadgen_restorable fails when loadgen's container is gone as it reads it" \
        "FAIL loadgen restorable: loadgen's container was removed while setup read it; nothing was changed"
    t_eq "check_loadgen_restorable ends the run there, with loadgen at start recorded and no other check" \
        "status 1, 1 check, LOADGEN_AT_START=[running, PORTFOLIO_INSIGHTS_ALERT_WEIGHT=2]" \
        "status $rc, $(grep -E '^(PASS|FAIL) ' "$RUN_DIR/report" | grep -cvF 'PASS run lock: ') check, $(sed 's/ FLAG_TOUCHED.*//' "$RUN_DIR/setup.state")"
    t_eq "check_loadgen_restorable makes no docker call that creates, changes or removes a container" "" \
        "$(grep -E '(^| )(up|rm|create|update|start|stop|restart|kill|pause|unpause)( |$)' "$RUN_DIR/docker-all" || true)"
    # loadgen_identity finds no container, so its docker inspect never runs: the branch under test,
    # not the twin step's own check of the container list.
    t_eq "check_loadgen_restorable stops at the empty identity, its last docker call the container list" \
        "0 inspects of the configuration, last call [ps -a -q loadgen]" \
        "$(grep -cF '{{json .}}' "$RUN_DIR/docker-all" || true) inspects of the configuration, last call [$(sed -n '$p' "$RUN_DIR/docker-all" | sed 's/^compose -p pi-test -f compose.dev.yaml //')]"
    t_eq "check_loadgen_restorable leaves the flag and loadgen untouched and no twin to remove" \
        "FLAG_TOUCHED=0 LOADGEN_TOUCHED=0 LOADGEN_TWIN=[]" "$(sed 's/^.*\] FLAG_TOUCHED/FLAG_TOUCHED/' "$RUN_DIR/setup.state")"
    t_eq "check_loadgen_restorable sends no request" "" "$(cat "$RUN_DIR/http-calls")"
}

test_restore_loadgen_effectiveConfigurationDiffers_failsNamingEachField() {
    local i change
    local -a expected
    # BEFORE changes the container before setup records it; AFTER changes that record.
    local before=(t_cpu_shares_updated t_restart_policy_updated "t_cpu_shares_updated t_restart_policy_updated" "" "")
    local after=("" "" "" unrecorded absent)
    unset PORTFOLIO_INSIGHTS_ALERT_WEIGHT
    for i in "${!before[@]}"; do
        t_fresh_run_dir
        t_loadgen_fixture lg-1 1 "$T_WEIGHT_2"
        # shellcheck disable=SC2086 # The row splits into one function name per word.
        for change in ${before[$i]}; do
            "$change"
        done
        t_capture_start
        case "${after[$i]}" in
            unrecorded) LOADGEN_CONFIG_AT_START="" ;;
            absent) LOADGEN_CONFIG_AT_START="$RUN_DIR/absent.config.json" ;;
        esac
        expected=("HostConfig.CpuShares 0 instead of 128 as at start"
            "HostConfig.RestartPolicy differs from the one at start"
            "HostConfig.CpuShares 0 instead of 128 as at start; HostConfig.RestartPolicy differs from the one at start"
            "no effective configuration was recorded at start to verify it against"
            "its effective configuration could not be compared with the one at start (see $RUN_DIR/compose.log)")
        recreate_loadgen 1
        t_cleanup
        t_report_has "cleanup fails naming what the restore did not give back after [${before[$i]}${after[$i]}]" \
            "FAIL cleanup: loadgen not restored: ${expected[$i]}"
        t_eq "cleanup still recreates loadgen with its weight at start after [${before[$i]}${after[$i]}]" \
            "up -d --no-deps --force-recreate --no-build --pull never loadgen | weight 2" \
            "$(sed -n '2p' "$RUN_DIR/docker-calls")"
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

# t_flag_off_window BREAKDOWN [LINE...]: runs flag_off_window with the flag, loadgen and log reads
# stubbed. Its B-flag-off.log holds the visit's skip line, no create, a cumulative stats line
# whose breakdown, BREAKDOWN, flag_off_window saves as breakdown-B-flag-off.json, and then each
# LINE, logged after that breakdown and before the stop.
t_flag_off_window() {
    local line
    {
        echo "[2026-01-01 00:00:01+00:00][worker:0][INFO]: Running visit [order_credit_card]"
        echo "[2026-01-01 00:00:02+00:00][worker:1][INFO]: Running visit [$VISIT]"
        echo "[2026-01-01 00:00:02+00:00][worker:1][visit:$VISIT][id:7d0c8a52-0b8e-4d4e-9a49-2f1c0e6b9a11][INFO]: $SKIP_LINE"
        t_stats_line "$1"
        for line in "${@:2}"; do
            echo "$line"
        done
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
    # close_or_abort closes the window as in a run: loadgen's stop succeeds, and its final
    # output is the fixture.
    stop_loadgen() {
        :
    }
    loadgen_logs() {
        cat "$RUN_DIR/fixture.log"
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
# Owned-id one-to-one audit (owned_id_violations, audit_owned_ids)

# The second fixture visit and alert, upper-cased as a log line may carry them.
T_PAIR_RUN_2_UPPER="5E1F2A3B-0000-4000-8000-00000000000B"
T_PAIR_ALERT_2_UPPER="0A1B2C3D-0000-4000-8000-000000000002"

# t_untagged_line MESSAGE: a worker line without a visit tag, a form sanitize_loadgen_log keeps.
t_untagged_line() {
    echo "[2026-01-01 00:00:10+00:00][worker:0][INFO]: $1"
}

# t_pairing_log CASE: run B's output for CASE: clean, or one way of breaking the rule that each
# visit creates one alert and resolves it once, after the create.
t_pairing_log() {
    case "$1" in
        clean)
            # Interleaved visits; the second logs its create, visit id and alert id, upper-cased
            # and its resolution lower-cased.
            t_drain_created "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1"
            t_drain_opened "$T_PAIR_RUN_2_UPPER"
            t_drain_line "$T_PAIR_RUN_2_UPPER" "Created alert [$T_PAIR_ALERT_2_UPPER] threshold [1000000.40271937]"
            t_drain_line "$T_DRAIN_RUN_1" "Deleted alert [$T_DRAIN_ALERT_1] via ui"
            t_drain_line "$T_DRAIN_RUN_2" "Alert [$T_DRAIN_ALERT_2] already absent"
            ;;
        "one id created by two visits")
            t_drain_created "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1"
            t_drain_created "$T_DRAIN_RUN_2" "$T_DRAIN_ALERT_1"
            t_drain_line "$T_DRAIN_RUN_1" "Deleted alert [$T_DRAIN_ALERT_1] via ui"
            ;;
        "one id resolved twice")
            t_drain_resolved "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" ui
            t_drain_line "$T_DRAIN_RUN_1" "Alert [$T_DRAIN_ALERT_1] already absent"
            ;;
        "one visit creating two alerts")
            t_drain_created "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1"
            t_drain_line "$T_DRAIN_RUN_1" "Created alert [$T_DRAIN_ALERT_2] threshold [1000000.40271937]"
            t_drain_line "$T_DRAIN_RUN_1" "Deleted alert [$T_DRAIN_ALERT_1] via ui"
            t_drain_line "$T_DRAIN_RUN_1" "Deleted alert [$T_DRAIN_ALERT_2] via api"
            ;;
        "a resolution by another visit")
            t_drain_created "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1"
            t_drain_line "$T_DRAIN_RUN_2" "Deleted alert [$T_DRAIN_ALERT_1] via api"
            ;;
        "a resolution before its create")
            t_drain_opened "$T_DRAIN_RUN_1"
            t_drain_line "$T_DRAIN_RUN_1" "Deleted alert [$T_DRAIN_ALERT_1] via ui"
            t_drain_line "$T_DRAIN_RUN_1" "Created alert [$T_DRAIN_ALERT_1] threshold [1000000.40271936]"
            ;;
        "a resolution without a create")
            t_drain_resolved "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" ui
            t_drain_line "$T_DRAIN_RUN_2" "Alert [$T_DRAIN_ALERT_2] already absent"
            ;;
        "an untagged create")
            t_untagged_line "Created alert [$T_DRAIN_ALERT_1] threshold [1000000.40271936]"
            t_drain_line "$T_DRAIN_RUN_1" "Deleted alert [$T_DRAIN_ALERT_1] via ui"
            ;;
        "an untagged resolution")
            t_drain_created "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1"
            t_untagged_line "Deleted alert [$T_DRAIN_ALERT_1] via ui"
            ;;
        "a breach and an unresolved create")
            t_drain_created "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1"
            t_drain_line "$T_DRAIN_RUN_1" "Created alert [$T_DRAIN_ALERT_2] threshold [1000000.40271937]"
            t_drain_line "$T_DRAIN_RUN_1" "Deleted alert [$T_DRAIN_ALERT_1] via ui"
            ;;
    esac
}

test_audit_owned_ids_createResolutionPairing_passesOnlyOneToOne() {
    local c scenario owned line
    # SCENARIO|OWNED|LINE: run B's output is t_pairing_log SCENARIO; the audit reports LINE and
    # cleanup owns OWNED.
    for c in "clean||PASS owned-id audit: 2 created alerts, each deleted via ui, via api or already absent" \
        "one id created by two visits||FAIL owned-id audit: not one-to-one: $T_DRAIN_ALERT_1 created again" \
        "one id resolved twice||FAIL owned-id audit: not one-to-one: $T_DRAIN_ALERT_1 resolved again" \
        "one visit creating two alerts||FAIL owned-id audit: not one-to-one: $T_DRAIN_ALERT_2 second create of its visit" \
        "a resolution by another visit||FAIL owned-id audit: not one-to-one: $T_DRAIN_ALERT_1 resolved by another visit" \
        "a resolution before its create||FAIL owned-id audit: not one-to-one: $T_DRAIN_ALERT_1 resolved before its create" \
        "a resolution without a create||FAIL owned-id audit: not one-to-one: $T_DRAIN_ALERT_2 resolved without a create" \
        "an untagged create||FAIL owned-id audit: not one-to-one: $T_DRAIN_ALERT_1 created without the visit tag" \
        "an untagged resolution||FAIL owned-id audit: not one-to-one: $T_DRAIN_ALERT_1 resolved without the visit tag" \
        "a breach and an unresolved create|$T_DRAIN_ALERT_2|FAIL owned-id audit: not one-to-one: $T_DRAIN_ALERT_2 second create of its visit; not resolved by loadgen, deleted on exit: $T_DRAIN_ALERT_2"; do
        IFS='|' read -r scenario owned line <<<"$c"
        t_fresh_run_dir
        t_drain_stubs
        t_drain_window
        t_pairing_log "$scenario" >"$RUN_DIR/logs.1"
        audit_owned_ids
        t_report_has "audit_owned_ids judges $scenario" "$line"
        t_eq "audit_owned_ids owns the unresolved ids of $scenario" "$owned" "$(t_drain_owned)"
    done
}

test_owned_id_violations_unreadLines_reportsNothing() {
    # After one clean pair, each line would be a breach if it were read as a create or a
    # resolution: its alert id is not a canonical UUID, or its message is no resolution.
    {
        t_drain_resolved "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" ui
        t_drain_line "$T_DRAIN_RUN_1" "Created alert [------------------------------------] threshold [1000000.40271937]"
        t_drain_line "$T_DRAIN_RUN_2" "Created alert [{$T_DRAIN_ALERT_2}] threshold [1000000.40271938]"
        t_drain_line "$T_DRAIN_RUN_2" "Deleted alert [$T_DRAIN_ALERT_2] via smoke"
        t_drain_line "$T_DRAIN_RUN_2" "Alert [$T_DRAIN_ALERT_2] left in place: 500"
        t_drain_line "$T_DRAIN_RUN_2" "Create unconfirmed threshold [1000000.40271939], outcome unknown"
    } >"$RUN_DIR/B.log"
    t_eq "owned_id_violations reads only canonical creates and resolutions" "" \
        "$(owned_id_violations "$RUN_DIR/B.log")"
}

# ---------------------------------------------------------------------------------------------
# Window close on every outcome (close_window, close_or_abort, cleanup)

# t_close_fixture LEG: run B's window, open after a read that logged the unresolved create of
# T_DRAIN_ALERT_1, under the drain's stubs. LEG stop makes loadgen's stop fail; read lets the
# stop succeed and makes the final read fail.
t_close_fixture() {
    t_drain_stubs
    t_drain_window
    t_drain_created "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" >"$RUN_DIR/logs.1"
    read_window "$RUN_DIR/progress.log"
    if [[ "$1" == "stop" ]]; then
        echo stop >"$RUN_DIR/compose.fail"
    else
        echo '!unreadable' >"$RUN_DIR/logs.final"
    fi
}

test_close_window_stopOrFinalReadFails_ownsObservedUnresolvedAndFails() {
    local c leg open reads error
    # LEG;WINDOW_OPEN;READS;CLOSE_ERROR, in which @RUN_DIR@ stands for the run directory. READS
    # counts the reads of loadgen's output: the earlier one, and the final one unless the stop
    # failed, as no read may start while loadgen may still run.
    for c in "stop;1;1;compose stop loadgen failed, exit 1 (see @RUN_DIR@/compose.log)" \
        "read;0;2;reading the window since 2026-01-01T00:00:00Z: loadgen logs unreadable, exit 1 (see @RUN_DIR@/compose.log)"; do
        IFS=';' read -r leg open reads error <<<"$c"
        (
            local rc=0
            t_fresh_run_dir
            t_close_fixture "$leg"
            close_window || rc=$?
            t_eq "close_window fails when the $leg fails" 1 "$rc"
            t_eq "close_window error when the $leg fails" "${error//@RUN_DIR@/$RUN_DIR}" "$CLOSE_ERROR"
            t_eq "close_window WINDOW_OPEN and WINDOW_UNREAD when the $leg fails" "$open 1" \
                "$WINDOW_OPEN $WINDOW_UNREAD"
            t_eq "close_window reads of loadgen's output when the $leg fails" "$reads" \
                "$(cat "$RUN_DIR/logs.n")"
            t_eq "close_window owns the unresolved create an earlier read saw when the $leg fails" \
                "$T_DRAIN_ALERT_1" "$(t_drain_owned)"
            t_eq "close_window lists that create as just owned when the $leg fails" \
                "$T_DRAIN_ALERT_1" "$(join_lines <"$RUN_DIR/new-owned")"
        )
    done
}

test_close_or_abort_closeFails_reportsOwnedIdsBeforeAbort() {
    local c leg error rc
    # LEG;DETAIL: the failed check's detail, in which @RUN_DIR@ stands for the run directory.
    for c in "stop;compose stop loadgen failed, exit 1 (see @RUN_DIR@/compose.log)" \
        "read;reading the window since 2026-01-01T00:00:00Z: loadgen logs unreadable, exit 1 (see @RUN_DIR@/compose.log)"; do
        IFS=';' read -r leg error <<<"$c"
        t_fresh_run_dir
        t_close_fixture "$leg"
        rc=0
        (close_or_abort "run B") || rc=$?
        t_eq "close_or_abort ends the run when the $leg fails" 1 "$rc"
        t_eq "close_or_abort reports the just-owned create, then fails, when the $leg fails" \
            "INFO run B: alert [$T_DRAIN_ALERT_1] was logged as created and never resolved by loadgen; it is deleted on exit|FAIL run B loadgen stopped: ${error//@RUN_DIR@/$RUN_DIR}" \
            "$(paste -s -d '|' "$RUN_DIR/report" | tr -d '\r')"
    done
}

test_cleanup_windowUnread_retriesReadAndOwnsNewIds() {
    local c retry owned deleted verdict
    # RETRY;OWNED;DELETED;VERDICT: cleanup's second read of a stopped loadgen's window, after the
    # closing read failed, either reads a create no earlier read saw or fails again. Either way
    # the create the earlier read saw is deleted, and loadgen is not stopped again.
    for c in "reads;$T_DRAIN_ALERT_2;2 of 2;PASS cleanup" \
        "fails;;1 of 1;FAIL cleanup: loadgen stopped, but its window was not read: reading the window since 2026-01-01T00:00:00Z: loadgen logs unreadable, exit 1 (see @RUN_DIR@/compose.log)"; do
        IFS=';' read -r retry owned deleted verdict <<<"$c"
        t_fresh_run_dir
        t_close_fixture read
        close_window || true
        if [[ "$retry" == "reads" ]]; then
            {
                t_drain_created "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1"
                t_drain_created "$T_DRAIN_RUN_2" "$T_DRAIN_ALERT_2"
            } >"$RUN_DIR/logs.final"
        fi
        : >"$RUN_DIR/http.calls"
        http() {
            echo "$1 $2" >>"$RUN_DIR/http.calls"
            HTTP_ERROR=""
            HTTP_STATUS="204"
            HTTP_BODY=""
            if [[ "$1" == "GET" ]]; then
                HTTP_STATUS="200"
                HTTP_BODY="{\"id\":\"$FLAG_ID\",\"enabled\":true,\"name\":\"Portfolio insights\",\"description\":\"Demo feature, not financial advice.\",\"isModifiable\":true,\"tag\":\"feature\",\"enabledAt\":\"2026-01-01T00:00:00Z\"}"
            fi
        }
        TABLE_WRITTEN=1
        (cleanup) >/dev/null 2>&1 || true
        t_eq "cleanup reads the window of a stopped loadgen again without stopping it when the retry $retry" \
            "stop --timeout 0 loadgen" "$(t_drain_calls)"
        if [[ -n "$owned" ]]; then
            t_report_has "cleanup reports the create its retry read found" \
                "INFO cleanup: alert [$owned] was logged as created and never resolved by loadgen; it is deleted on exit"
        fi
        t_eq "cleanup deletes every owned create when the retry $retry" \
            "$(printf 'DELETE %s/%s\n' "$ALERTS_URL" "$T_DRAIN_ALERT_1" ${owned:+"$ALERTS_URL" "$owned"} | join_lines)" \
            "$(grep '^DELETE ' "$RUN_DIR/http.calls" | join_lines)"
        t_report_has "cleanup counts the owned creates deleted when the retry $retry" \
            "INFO cleanup: $deleted owned alerts deleted or already absent"
        t_report_has "cleanup verdict when the retry $retry" "${verdict//@RUN_DIR@/$RUN_DIR}"
    done
}

# t_record FILE: FILE's lines separated by |, or "absent" when there is no FILE.
t_record() {
    if [[ -e "$1" ]]; then
        paste -s -d '|' "$1" | tr -d '\r'
    else
        echo absent
    fi
}

# t_close_fault FAULT: makes one step of run B's close fail as an I/O error would, in the calling
# subshell only. FAULT is one of:
#   none           nothing fails;
#   stats line     grep fails reading run B's final output for the breakdown's stats line;
#   covered lines  head fails cutting the lines up to that stats line from the final output;
#   late lines     tail fails cutting the lines after that stats line from the final output;
#   error lines    grep fails reading those lines for visit errors;
#   counts         sed fails reading the visit errors it counts;
#   move           mv fails moving the late stretch's counts into place;
#   whole window   cp fails copying a final output that lacks the stats line.
t_close_fault() {
    case "$1" in
        "covered lines")
            # shellcheck disable=SC2329 # Invoked by close_window.
            head() {
                if [[ "${*: -1}" == "$RUN_DIR/B.log" ]]; then
                    echo "head: error reading '$RUN_DIR/B.log': Input/output error" >&2
                    return 1
                fi
                command head "$@"
            }
            ;;
        "whole window")
            # shellcheck disable=SC2329 # Invoked by close_window.
            cp() {
                if [[ "${1:-}" == "$RUN_DIR/B.log" ]]; then
                    echo "cp: error reading '$RUN_DIR/B.log': Input/output error" >&2
                    return 1
                fi
                command cp "$@"
            }
            ;;
        "stats line" | "error lines")
            T_CLOSE_FAULT_FILE="$RUN_DIR/B.log"
            if [[ "$1" == "error lines" ]]; then
                T_CLOSE_FAULT_FILE="$RUN_DIR/B.late.part"
            fi
            # shellcheck disable=SC2329 # Invoked by close_window.
            grep() {
                if [[ "${*: -1}" == "$T_CLOSE_FAULT_FILE" ]]; then
                    echo "grep: $T_CLOSE_FAULT_FILE: Input/output error" >&2
                    return 2
                fi
                command grep "$@"
            }
            ;;
        "late lines")
            # shellcheck disable=SC2329 # Invoked by close_window.
            tail() {
                if [[ "${*: -1}" == "$RUN_DIR/B.log" ]]; then
                    echo "tail: error reading '$RUN_DIR/B.log': Input/output error" >&2
                    return 1
                fi
                command tail "$@"
            }
            ;;
        counts)
            # shellcheck disable=SC2329 # Invoked by close_window.
            sed() {
                if [[ "${*: -1}" == "$RUN_DIR/B.late.errors" ]]; then
                    echo "sed: read error on $RUN_DIR/B.late.errors: Input/output error" >&2
                    return 4
                fi
                command sed "$@"
            }
            ;;
        move)
            # shellcheck disable=SC2329 # Invoked by close_window.
            mv() {
                if [[ "${*: -1}" == "$RUN_DIR/errors-late-B" ]]; then
                    echo "mv: cannot move to '$RUN_DIR/errors-late-B': Read-only file system" >&2
                    return 1
                fi
                command mv "$@"
            }
            ;;
    esac
}

test_close_window_lateStretchExtractionFails_failsLateVerdicts() {
    local c fault late covered unknown
    # FAULT;LATE;COVERED;UNKNOWN: the step of run B's close that fails (t_close_fault), the late
    # error counts close_window records, whether it records the counts for the table, and the
    # stretches it reports unknown. Run B's final output holds the breakdown's stats line, except
    # for whole window, and then a visit error of portfolio_insights_alert and one of
    # long_sell_error, so a failed step taken for an empty stretch would pass both run B checks.
    # An earlier close of the window, as before cleanup's retry, left records of its own.
    for c in "none;1 long_sell_error|1 $VISIT;recorded;" \
        "stats line;absent;absent;covered late" \
        "covered lines;1 long_sell_error|1 $VISIT;absent;covered" \
        "late lines;absent;recorded;late" \
        "error lines;absent;recorded;late" \
        "counts;absent;recorded;late" \
        "move;absent;recorded;late" \
        "whole window;absent;absent;covered"; do
        IFS=';' read -r fault late covered unknown <<<"$c"
        (
            local rc=0 stretch reported="" late_log="absent" covered_record="absent" logged="logged"
            local fails=5 rate="$LATE_UNKNOWN" long_sell="run B: $LATE_UNKNOWN" unknown_covered
            local unknown_late
            t_fresh_run_dir
            unknown_covered="INFO window B: its error-line counts for the table are unknown: extracting them from its final output failed (see $RUN_DIR/close-error.log)"
            unknown_late="INFO window B: the visits after the breakdown, through the stop, are unknown: extracting them from its final output failed (see $RUN_DIR/close-error.log)"
            if [[ "$late" != "absent" ]]; then
                rate="1 visit errors after it, through the stop"
                long_sell="failing in run B but not in run A: long_sell_error; failing after the breakdown, through the stop: run B [long_sell_error], run A [none]"
                fails=1
                late_log="$( {
                    t_visit_error "$VISIT"
                    t_visit_error long_sell_error
                    t_drain_created "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1"
                } | paste -s -d '|' -)"
            fi
            # A recorded count for the table is empty: no visit error precedes the stats line.
            if [[ "$covered" == "recorded" ]]; then
                covered_record=""
            fi
            if [[ "$fault" == "none" ]]; then
                logged="empty"
            fi
            for stretch in $unknown; do
                if [[ "$stretch" == "covered" ]]; then
                    reported="$reported|$unknown_covered"
                else
                    reported="$reported|$unknown_late"
                fi
            done
            t_drain_stubs
            t_drain_window
            t_closed_phase A "$T_FLAG_OFF_BREAKDOWN"
            # Run B closed after loadgen stopped, as t_closed_phase closes it.
            WINDOW_LABEL="B"
            printf '%s\n' "$T_FLAG_OFF_BREAKDOWN" >"$RUN_DIR/breakdown-B.json"
            t_stats_line "$T_FLAG_OFF_BREAKDOWN" >"$RUN_DIR/breakdown-B.line"
            {
                echo "$T_DRAIN_FIRST_LINE"
                if [[ "$fault" != "whole window" ]]; then
                    cat "$RUN_DIR/breakdown-B.line"
                fi
                t_visit_error "$VISIT"
                t_visit_error long_sell_error
                t_drain_created "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1"
            } >"$RUN_DIR/logs.1"
            echo 0 >"$RUN_DIR/logs.n"
            echo "9 $VISIT" >"$RUN_DIR/errors-B"
            echo "9 $VISIT" >"$RUN_DIR/errors-late-B"
            : >"$RUN_DIR/B.late.log"
            t_close_fault "$fault"
            close_window 1 || rc=$?
            t_eq "close_window closes run B's window when $fault fails" "0 0 0" \
                "$rc $WINDOW_OPEN $WINDOW_UNREAD"
            t_eq "close_window late error counts when $fault fails" "$late" \
                "$(t_record "$RUN_DIR/errors-late-B")"
            t_eq "close_window late lines when $fault fails" "$late_log" \
                "$(t_record "$RUN_DIR/B.late.log")"
            t_eq "close_window error-line counts for the table when $fault fails" "$covered_record" \
                "$(t_record "$RUN_DIR/errors-B")"
            t_eq "close_window reports the stretches left unknown when $fault fails" \
                "${reported#|}" \
                "$({ grep -F 'INFO window B: ' "$RUN_DIR/report" || true; } | paste -s -d '|' - | tr -d '\r')"
            t_eq "close_window logs why a step failed when $fault fails" "$logged" \
                "$([[ -s "$RUN_DIR/close-error.log" ]] && echo logged || echo empty)"
            t_eq "close_window owns run B's unresolved create when $fault fails" \
                "$T_DRAIN_ALERT_1" "$(t_drain_owned)"
            check_visit_fail_rate "run B" B "$T_FLAG_OFF_BREAKDOWN"
            compare_failures
            t_report_has "check_visit_fail_rate fails run B's failRate when $fault fails" \
                "FAIL run B $VISIT failRate: failRate 0 over 3 visits at the breakdown, but $rate"
            t_report_has "compare_failures fails long_sell when $fault fails" \
                "FAIL run B no new failures long_sell: $long_sell"
            t_eq "compare_failures failed families when $fault fails" "$fails" \
                "$(grep -c '^FAIL run B no new failures ' "$RUN_DIR/report" || true)"
        )
    done
}

test_cleanup_closeEndedAroundOwnership_rereadsWindowAndOwnsEachIdOnce() {
    local c point status reported stopped
    # POINT;STATUS;REPORTED;STOPPED: how run B's close ends once loadgen stopped and its final
    # output was read: INT or TERM lands before the window's unresolved create is owned, or after
    # it is owned but before the window counts as read; or recording that create fails. STATUS is
    # the run's exit status, REPORTED how many times cleanup reports the create as just owned,
    # and STOPPED the failed "loadgen stopped" check, in which @RUN_DIR@ is the run directory.
    for c in "a signal before the transfer;130;1;" "a signal after the transfer;130;0;" \
        "a failed transfer;1;1;FAIL run B loadgen stopped: recording the window's unresolved alert ids in @RUN_DIR@/owned failed"; do
        IFS=';' read -r point status reported stopped <<<"$c"
        (
            local rc=0
            t_fresh_run_dir
            t_drain_stubs
            t_drain_window
            # The final output holds a create no earlier read saw.
            t_drain_created "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" >"$RUN_DIR/logs.1"
            # own_unresolved as the script defines it, under another name, for the stub to call.
            eval "t_own_unresolved() $(declare -f own_unresolved | sed 1d)"
            # The first transfer is where the close ends. A signal ends it as the script's INT and
            # TERM trap does, exiting 130, which runs cleanup, the EXIT trap.
            # shellcheck disable=SC2329 # Invoked by close_window.
            own_unresolved() {
                if [[ ! -e "$RUN_DIR/ended" ]]; then
                    : >"$RUN_DIR/ended"
                    case "$point" in
                        "a signal before the transfer")
                            exit 130
                            ;;
                        "a signal after the transfer")
                            t_own_unresolved "$@"
                            exit 130
                            ;;
                        "a failed transfer")
                            return 1
                            ;;
                    esac
                fi
                t_own_unresolved "$@"
            }
            : >"$RUN_DIR/http.calls"
            # shellcheck disable=SC2329 # Invoked by cleanup.
            http() {
                echo "$1 $2" >>"$RUN_DIR/http.calls"
                HTTP_ERROR=""
                HTTP_STATUS="204"
                HTTP_BODY=""
                if [[ "$1" == "GET" ]]; then
                    HTTP_STATUS="200"
                    HTTP_BODY="{\"id\":\"$FLAG_ID\",\"enabled\":true,\"name\":\"Portfolio insights\",\"description\":\"Demo feature, not financial advice.\",\"isModifiable\":true,\"tag\":\"feature\",\"enabledAt\":\"2026-01-01T00:00:00Z\"}"
                fi
            }
            TABLE_WRITTEN=1
            (
                trap cleanup EXIT
                close_or_abort "run B"
            ) >/dev/null 2>&1 || rc=$?
            t_eq "cleanup exit status when the close ends at $point" "$status" "$rc"
            t_eq "close_or_abort loadgen stopped check when the close ends at $point" \
                "${stopped//@RUN_DIR@/$RUN_DIR}" \
                "$({ grep '^FAIL run B loadgen stopped' "$RUN_DIR/report" || true; } | tr -d '\r')"
            t_eq "cleanup reads the stopped window again, without stopping it, when the close ends at $point" \
                "stop --timeout 0 loadgen; 2 reads" \
                "$(t_drain_calls); $(cat "$RUN_DIR/logs.n") reads"
            t_eq "cleanup owns the window's unresolved create once when the close ends at $point" \
                "$T_DRAIN_ALERT_1" "$(t_record "$RUN_DIR/owned")"
            t_eq "cleanup reports the create as just owned when the close ends at $point" \
                "$reported" \
                "$(grep -cxF "INFO cleanup: alert [$T_DRAIN_ALERT_1] was logged as created and never resolved by loadgen; it is deleted on exit" \
                    "$RUN_DIR/report" || true)"
            t_eq "cleanup deletes the create once when the close ends at $point" \
                "DELETE $ALERTS_URL/$T_DRAIN_ALERT_1" \
                "$(grep '^DELETE ' "$RUN_DIR/http.calls" | join_lines)"
            t_report_has "cleanup verdict when the close ends at $point" "PASS cleanup"
        )
    done
}

# t_fault_once: whether the one-shot fault t_transfer_fault armed is still due, disarming it.
t_fault_once() {
    [[ -e "$RUN_DIR/fault.once" ]] && rm -f "$RUN_DIR/fault.once"
}

# t_transfer_fault STEP: makes one step of own_unresolved, the transfer of a window's unresolved
# ids into the owned list, fail once as an I/O error would, in the calling subshell only. STEP
# is one of:
#   new-owned list  the list of ids just owned cannot be emptied: it is a directory;
#   created ids     sed fails reading the creates of run B's final output;
#   observed ids    the set of created ids an earlier read observed cannot be read: it is a
#                   directory;
#   resolved ids    sed fails reading the resolutions of run B's final output;
#   unresolved ids  comm fails comparing the window's created and resolved ids;
#   owned list      sort fails reading the owned list;
#   new owned ids   comm fails comparing the unresolved ids with the owned list;
#   transfer        cat fails appending the ids just owned to the owned list.
# A step made to fail by a directory fails until t_transfer_restore puts its file back.
t_transfer_fault() {
    T_TRANSFER_FAULT="$1"
    : >"$RUN_DIR/fault.once"
    case "$1" in
        "new-owned list")
            rm -f "$RUN_DIR/new-owned"
            mkdir "$RUN_DIR/new-owned"
            ;;
        "observed ids")
            mv "$RUN_DIR/observed-created-B" "$RUN_DIR/observed-created-B.kept"
            mkdir "$RUN_DIR/observed-created-B"
            ;;
        "created ids" | "resolved ids")
            # shellcheck disable=SC2329 # Invoked by own_unresolved.
            sed() {
                local marker="Created alert"
                if [[ "$T_TRANSFER_FAULT" == "resolved ids" ]]; then
                    marker="Deleted alert"
                fi
                if [[ "${*: -1}" == "$RUN_DIR/B.log" && "$*" == *"$marker"* ]] && t_fault_once; then
                    return 4
                fi
                command sed "$@"
            }
            ;;
        "unresolved ids" | "new owned ids")
            # shellcheck disable=SC2329 # Invoked by own_unresolved.
            comm() {
                local operand="$RUN_DIR/ids.resolved.union"
                if [[ "$T_TRANSFER_FAULT" == "new owned ids" ]]; then
                    operand="$RUN_DIR/owned.sorted"
                fi
                if [[ "${*: -1}" == "$operand" ]] && t_fault_once; then
                    return 2
                fi
                command comm "$@"
            }
            ;;
        "owned list")
            # shellcheck disable=SC2329 # Invoked by own_unresolved.
            sort() {
                if [[ "${*: -1}" == "$RUN_DIR/owned" ]] && t_fault_once; then
                    return 2
                fi
                command sort "$@"
            }
            ;;
        transfer)
            # shellcheck disable=SC2329 # Invoked by own_unresolved.
            cat() {
                if [[ "${1:-}" == "$RUN_DIR/new-owned" ]] && t_fault_once; then
                    return 1
                fi
                command cat "$@"
            }
            ;;
    esac
}

# t_transfer_restore: puts back the file t_transfer_fault replaced with a directory, as when the
# I/O error has passed.
t_transfer_restore() {
    case "$T_TRANSFER_FAULT" in
        "new-owned list")
            rmdir "$RUN_DIR/new-owned"
            : >"$RUN_DIR/new-owned"
            ;;
        "observed ids")
            rmdir "$RUN_DIR/observed-created-B"
            mv "$RUN_DIR/observed-created-B.kept" "$RUN_DIR/observed-created-B"
            ;;
    esac
}

test_close_window_ownershipTransferStepFails_failsAndCleanupOwnsIds() {
    local step
    # Run B's final output holds the unresolved create an earlier read saw and one no earlier read
    # saw. When a step of their transfer into the owned list fails, the close fails and leaves the
    # window unread, owning nothing it could have recorded partly; cleanup's retry, once the I/O
    # error has passed, owns and deletes both, each once.
    for step in "new-owned list" "created ids" "observed ids" "resolved ids" "unresolved ids" \
        "owned list" "new owned ids" transfer; do
        (
            local rc=0
            t_fresh_run_dir
            t_drain_stubs
            t_drain_window
            t_drain_created "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" >"$RUN_DIR/logs.1"
            read_window "$RUN_DIR/progress.log"
            {
                t_drain_created "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1"
                t_drain_created "$T_DRAIN_RUN_2" "$T_DRAIN_ALERT_2"
            } >"$RUN_DIR/logs.final"
            t_transfer_fault "$step"
            # The failed step's own error message is not under test.
            close_window 2>/dev/null || rc=$?
            t_eq "close_window fails when the transfer's $step step fails" 1 "$rc"
            t_eq "close_window error when the transfer's $step step fails" \
                "recording the window's unresolved alert ids in $RUN_DIR/owned failed" "$CLOSE_ERROR"
            t_eq "close_window leaves the stopped window unread when the transfer's $step step fails" \
                "0 1" "$WINDOW_OPEN $WINDOW_UNREAD"
            t_eq "close_window owns no id when the transfer's $step step fails" "" "$(t_drain_owned)"
            t_transfer_restore
            : >"$RUN_DIR/http.calls"
            # shellcheck disable=SC2329 # Invoked by cleanup.
            http() {
                echo "$1 $2" >>"$RUN_DIR/http.calls"
                HTTP_ERROR=""
                HTTP_STATUS="204"
                HTTP_BODY=""
                if [[ "$1" == "GET" ]]; then
                    HTTP_STATUS="200"
                    HTTP_BODY="{\"id\":\"$FLAG_ID\",\"enabled\":true,\"name\":\"Portfolio insights\",\"description\":\"Demo feature, not financial advice.\",\"isModifiable\":true,\"tag\":\"feature\",\"enabledAt\":\"2026-01-01T00:00:00Z\"}"
                fi
            }
            TABLE_WRITTEN=1
            (cleanup) >/dev/null 2>&1 || true
            t_eq "cleanup reads the stopped window again, without stopping it, after the transfer's $step step failed" \
                "stop --timeout 0 loadgen" "$(t_drain_calls)"
            t_eq "cleanup owns both unresolved creates once after the transfer's $step step failed" \
                "$T_DRAIN_ALERT_1|$T_DRAIN_ALERT_2" "$(t_record "$RUN_DIR/owned")"
            t_eq "cleanup deletes both unresolved creates after the transfer's $step step failed" \
                "DELETE $ALERTS_URL/$T_DRAIN_ALERT_1 DELETE $ALERTS_URL/$T_DRAIN_ALERT_2" \
                "$(grep '^DELETE ' "$RUN_DIR/http.calls" | join_lines)"
            t_report_has "cleanup verdict after the transfer's $step step failed" "PASS cleanup"
        )
    done
}

test_read_window_idsNotRecorded_failsWithDetail() {
    local fault
    # FAULT: the record of this read of run B's output that cannot be written: the observed set of
    # created ids or of resolved ids, each a directory here, or the window's first line, which
    # head fails to read.
    for fault in "created set" "resolved set" "first line"; do
        (
            local rc=0
            t_fresh_run_dir
            t_drain_stubs
            t_drain_window
            t_drain_resolved "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" ui >"$RUN_DIR/logs.1"
            case "$fault" in
                "created set") mkdir "$RUN_DIR/observed-created-B" ;;
                "resolved set") mkdir "$RUN_DIR/observed-resolved-B" ;;
                "first line")
                    # shellcheck disable=SC2329 # Invoked by observe_window.
                    head() {
                        if [[ "${*: -1}" == "$RUN_DIR/progress.log" ]]; then
                            return 1
                        fi
                        command head "$@"
                    }
                    ;;
            esac
            read_window "$RUN_DIR/progress.log" 2>/dev/null || rc=$?
            t_eq "read_window fails when the $fault is not recorded" 1 "$rc"
            t_eq "read_window says why when the $fault is not recorded" \
                "recording the alert ids of this read of loadgen's output in $RUN_DIR failed" \
                "$LOG_PROBE_DETAIL"
        )
    done
}

# ---------------------------------------------------------------------------------------------
# Verdicts through the stop (close_window's late stretch, check_visit_fail_rate,
# compare_failures, run_a, run_b, flag_off_window)

# t_visit_error NAME: the worker error line loadgen-core logs for a failed visit NAME, as
# sanitize_loadgen_log keeps it, stamped after the breakdown of t_stats_line.
t_visit_error() {
    echo "[2026-01-01 00:05:10+00:00][worker:1][visit:$1][id:$T_DRAIN_RUN_2][WARN]: $ERROR_MARKER"
}

# t_closed_phase LABEL BREAKDOWN [LINE...]: phase LABEL closed by close_window after loadgen
# stopped, under the drain's stubs. Its breakdown BREAKDOWN is saved as run_window saves it, and
# its final output holds T_DRAIN_FIRST_LINE, that breakdown's stats line and then each LINE.
t_closed_phase() {
    local label="$1" line
    WINDOW_LABEL="$label"
    printf '%s\n' "$2" >"$RUN_DIR/breakdown-$label.json"
    t_stats_line "$2" >"$RUN_DIR/breakdown-$label.line"
    {
        echo "$T_DRAIN_FIRST_LINE"
        cat "$RUN_DIR/breakdown-$label.line"
        for line in "${@:3}"; do
            echo "$line"
        done
    } >"$RUN_DIR/logs.1"
    echo 0 >"$RUN_DIR/logs.n"
    close_window 1
}

# t_reported_before NAME FIRST SECOND: PASS NAME when the script reported exactly the line FIRST,
# and later exactly the line SECOND.
t_reported_before() {
    local first second
    first="$(grep -n -x -F -- "$2" "$RUN_DIR/report" | sed -n '1s/:.*//p')"
    second="$(grep -n -x -F -- "$3" "$RUN_DIR/report" | sed -n '1s/:.*//p')"
    if [[ -n "$first" && -n "$second" && $first -lt $second ]]; then
        t_pass "$1"
    else
        t_fail "$1" "[$2] at report line [$first], [$3] at report line [$second]"
    fi
}

# t_read_fault PROGRAM FILE...: makes PROGRAM, awk or grep, fail with status 2, as on an I/O
# error, whenever its last argument is one of the FILEs, in the calling subshell only. The
# program's error message is left out, so the suite's output holds only its own lines.
t_read_fault() {
    T_READ_FAULT_FILES=("${@:2}")
    case "$1" in
        awk)
            # shellcheck disable=SC2329 # Invoked by the script's late verdicts.
            awk() {
                if t_read_faulted "$@"; then
                    return 2
                fi
                command awk "$@"
            }
            ;;
        grep)
            # shellcheck disable=SC2329 # Invoked by the script's late verdicts.
            grep() {
                if t_read_faulted "$@"; then
                    return 2
                fi
                command grep "$@"
            }
            ;;
    esac
}

# t_read_faulted ARGS...: whether the last of ARGS is a file t_read_fault made unreadable.
t_read_faulted() {
    local file
    for file in "${T_READ_FAULT_FILES[@]}"; do
        if [[ $# -gt 0 && "${*: -1}" == "$file" ]]; then
            return 0
        fi
    done
    return 1
}

test_run_b_visitErrorAfterBreakdown_failsFailRateAfterStop() {
    local line="FAIL run B $VISIT failRate: failRate 0 over 3 visits at the breakdown, but 1 visit errors after it, through the stop"
    t_drain_stubs
    t_drain_window
    t_closed_phase A "$(t_breakdown 'del(.portfolio_insights_alert)')"
    t_drain_window
    # run_window as it returns after saving run B's breakdown, the window left open.
    run_window() {
        printf '%s\n' "$T_FLAG_OFF_BREAKDOWN" >"$RUN_DIR/breakdown-B.json"
        t_stats_line "$T_FLAG_OFF_BREAKDOWN" >"$RUN_DIR/breakdown-B.line"
    }
    # After the breakdown, a visit deletes its alert through the UI and then fails, as at logout.
    {
        t_drain_resolved "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" ui
        t_stats_line "$T_FLAG_OFF_BREAKDOWN"
        t_drain_resolved "$T_DRAIN_RUN_2" "$T_DRAIN_ALERT_2" ui
        t_visit_error "$VISIT"
    } >"$RUN_DIR/logs.1"
    echo 0 >"$RUN_DIR/logs.n"
    run_b
    t_report_has "run_b fails the failRate of a visit that failed after the breakdown" "$line"
    t_eq "run_b records that failRate verdict" FAIL "$(verdict_of B "$VISIT")"
    t_eq "close_window counts the visit error after the breakdown in its late stretch" \
        "1 $VISIT" "$(cat "$RUN_DIR/errors-late-B")"
    t_eq "close_window keeps the error column to the stretch the breakdown covers" \
        "" "$(cat "$RUN_DIR/errors-B")"
    t_reported_before "run_b judges the breakdown only after loadgen stopped" \
        "PASS run B loadgen stopped" "$line"
}

test_run_b_lateRecordUnreadable_failsFailRateAndComparison() {
    local c unreadable fail_rate runs
    # UNREADABLE;FAILRATE;RUNS: the runs whose late error-line counts, recorded by close_window,
    # awk fails to read, run B's failRate check, and the runs every family's comparison names.
    # Neither run logged a visit error after its breakdown, so a failed read taken for an empty
    # record would pass every check.
    for c in "B;FAIL run B $VISIT failRate: failRate 0 over 3 visits at the breakdown, but $LATE_UNREAD;run B" \
        "A;PASS run B $VISIT failRate: 0 over 3 visits, and no visit error after the breakdown, through the stop;run A" \
        "A B;FAIL run B $VISIT failRate: failRate 0 over 3 visits at the breakdown, but $LATE_UNREAD;run A and run B"; do
        IFS=';' read -r unreadable fail_rate runs <<<"$c"
        (
            local label files=()
            t_fresh_run_dir
            t_drain_stubs
            t_drain_window
            t_closed_phase A "$(t_breakdown 'del(.portfolio_insights_alert)')"
            t_drain_window
            # run_window as it returns after saving run B's breakdown, the window left open.
            # shellcheck disable=SC2329 # Invoked by run_b.
            run_window() {
                printf '%s\n' "$T_FLAG_OFF_BREAKDOWN" >"$RUN_DIR/breakdown-B.json"
                t_stats_line "$T_FLAG_OFF_BREAKDOWN" >"$RUN_DIR/breakdown-B.line"
            }
            {
                t_drain_resolved "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" ui
                t_stats_line "$T_FLAG_OFF_BREAKDOWN"
            } >"$RUN_DIR/logs.1"
            echo 0 >"$RUN_DIR/logs.n"
            for label in $unreadable; do
                files+=("$RUN_DIR/errors-late-$label")
            done
            t_read_fault awk "${files[@]}"
            run_b
            for label in $unreadable; do
                t_eq "close_window records run $label's late error-line counts that the verdicts fail to read" \
                    "recorded" "$([[ -f "$RUN_DIR/errors-late-$label" ]] && echo recorded || echo absent)"
            done
            t_report_has "run_b failRate check when the late record of $runs is unreadable" \
                "$fail_rate"
            t_eq "run_b fails every family's comparison when the late record of $runs is unreadable" 5 \
                "$(grep -cxF -e "FAIL run B no new failures deposit_and_buy: $runs: $LATE_UNREAD" \
                    -e "FAIL run B no new failures deposit_and_long_buy: $runs: $LATE_UNREAD" \
                    -e "FAIL run B no new failures long_sell: $runs: $LATE_UNREAD" \
                    -e "FAIL run B no new failures sell_and_withdraw: $runs: $LATE_UNREAD" \
                    -e "FAIL run B no new failures order_credit_card: $runs: $LATE_UNREAD" \
                    "$RUN_DIR/report" || true)"
        )
    done
}

test_compare_failures_legacyNameFailingAfterBreakdown_judgedThroughStop() {
    local c scenario a_late verdict line
    # SCENARIO;A_LATE;VERDICT;LINE: long_sell_error fails after run B's breakdown, and after run
    # A's too when A_LATE is 1; both breakdowns hold no failure.
    for c in "never in run A;0;FAIL;FAIL run B no new failures long_sell: failing in run B but not in run A: long_sell_error; failing after the breakdown, through the stop: run B [long_sell_error], run A [none]" \
        "after run A's breakdown too;1;PASS;PASS run B no new failures long_sell: failing [long_sell_error], run A failing [long_sell_error]; failing after the breakdown, through the stop: run B [long_sell_error], run A [long_sell_error]"; do
        IFS=';' read -r scenario a_late verdict line <<<"$c"
        t_fresh_run_dir
        t_drain_stubs
        t_drain_window
        if [[ "$a_late" == "1" ]]; then
            t_closed_phase A "$T_FLAG_OFF_BREAKDOWN" "$(t_visit_error long_sell_error)"
        else
            t_closed_phase A "$T_FLAG_OFF_BREAKDOWN"
        fi
        t_closed_phase B "$T_FLAG_OFF_BREAKDOWN" "$(t_visit_error long_sell_error)"
        compare_failures
        t_report_has "compare_failures judges long_sell when it fails $scenario" "$line"
        t_eq "compare_failures long_sell verdict when it fails $scenario" "$verdict" \
            "$(verdict_of B long_sell)"
        t_eq "compare_failures passes the other families when long_sell fails $scenario" 4 \
            "$(grep -cE '^PASS run B no new failures (deposit_and_buy|deposit_and_long_buy|sell_and_withdraw|order_credit_card): ' \
                "$RUN_DIR/report" || true)"
    done
}

test_close_window_finalOutputLacksBreakdownLine_failsLateVerdicts() {
    local c lost label unknown fail_rate
    # LOST;UNKNOWN;FAILRATE: the runs whose final output lost its breakdown's stats line, as log
    # rotation can, the runs compare_failures names, and run B's failRate check.
    for c in "A;run A;PASS run B $VISIT failRate: 0 over 3 visits, and no visit error after the breakdown, through the stop" \
        "B;run B;FAIL run B $VISIT failRate: failRate 0 over 3 visits at the breakdown, but $LATE_UNKNOWN" \
        "A B;run A and run B;FAIL run B $VISIT failRate: failRate 0 over 3 visits at the breakdown, but $LATE_UNKNOWN"; do
        IFS=';' read -r lost unknown fail_rate <<<"$c"
        t_fresh_run_dir
        t_drain_stubs
        t_drain_window
        t_closed_phase A "$T_FLAG_OFF_BREAKDOWN"
        t_closed_phase B "$T_FLAG_OFF_BREAKDOWN"
        # A lost run's final output keeps every line but the stats line, a visit error included.
        for label in $lost; do
            WINDOW_LABEL="$label"
            t_visit_error long_sell_error >"$RUN_DIR/logs.1"
            echo 0 >"$RUN_DIR/logs.n"
            close_window 1
            t_eq "close_window records no late stretch for run $label without its stats line" \
                "no late record" "$([[ -e "$RUN_DIR/errors-late-$label" ]] && echo "recorded" || echo "no late record")"
        done
        compare_failures
        t_eq "compare_failures fails every family while $unknown's late stretch is unknown" 5 \
            "$(grep -cxF -e "FAIL run B no new failures deposit_and_buy: $unknown: $LATE_UNKNOWN" \
                -e "FAIL run B no new failures deposit_and_long_buy: $unknown: $LATE_UNKNOWN" \
                -e "FAIL run B no new failures long_sell: $unknown: $LATE_UNKNOWN" \
                -e "FAIL run B no new failures sell_and_withdraw: $unknown: $LATE_UNKNOWN" \
                -e "FAIL run B no new failures order_credit_card: $unknown: $LATE_UNKNOWN" \
                "$RUN_DIR/report" || true)"
        check_visit_fail_rate "run B" B "$T_FLAG_OFF_BREAKDOWN"
        t_report_has "check_visit_fail_rate of run B when $unknown lost its stats line" "$fail_rate"
    done
}

test_run_a_visitAfterBreakdown_failsNoVisitCheck() {
    local c scenario line
    # SCENARIO;LINE: run A's final output holds its breakdown's stats line and nothing after it,
    # that line and then a visit run, or no stats line, as after log rotation; or it holds that
    # line and nothing after it, but grep fails reading the late lines close_window recorded.
    # LINE is the check.
    for c in "nothing late;PASS run A no $VISIT" \
        "a late visit run;FAIL run A no $VISIT: 1 lines [Running visit [$VISIT]] after the breakdown, through the stop" \
        "no stats line;FAIL run A no $VISIT: $LATE_UNKNOWN" \
        "unreadable late lines;FAIL run A no $VISIT: $LATE_UNREAD"; do
        IFS=';' read -r scenario line <<<"$c"
        t_fresh_run_dir
        t_drain_stubs
        t_drain_window
        WINDOW_LABEL="A"
        # run_window as it returns after saving run A's breakdown, the window left open.
        run_window() {
            t_breakdown 'del(.portfolio_insights_alert)' >"$RUN_DIR/breakdown-A.json"
            t_stats_line "$(cat "$RUN_DIR/breakdown-A.json")" >"$RUN_DIR/breakdown-A.line"
        }
        {
            echo "$T_DRAIN_FIRST_LINE"
            case "$scenario" in
                "nothing late" | "unreadable late lines")
                    t_stats_line "$(t_breakdown 'del(.portfolio_insights_alert)')"
                    ;;
                "a late visit run")
                    t_stats_line "$(t_breakdown 'del(.portfolio_insights_alert)')"
                    t_drain_opened "$T_DRAIN_RUN_1"
                    ;;
            esac
        } >"$RUN_DIR/logs.final"
        if [[ "$scenario" == "unreadable late lines" ]]; then
            (
                t_read_fault grep "$RUN_DIR/A.late.log"
                run_a
            )
        else
            run_a
        fi
        t_report_has "run_a judges $VISIT through the stop with $scenario" "$line"
        t_reported_before "run_a judges $VISIT only after loadgen stopped with $scenario" \
            "PASS run A loadgen stopped" "$line"
    done
}

test_flag_off_window_visitErrorAfterBreakdown_judgesFailRateThroughStop() {
    local c scenario line
    # SCENARIO;LINE: whether the visit fails after the flag-off breakdown, and the check's line.
    for c in "no late failure;PASS flag-off $VISIT failRate: 0 over 3 visits, and no visit error after the breakdown, through the stop" \
        "a late failure;FAIL flag-off $VISIT failRate: failRate 0 over 3 visits at the breakdown, but 1 visit errors after it, through the stop"; do
        IFS=';' read -r scenario line <<<"$c"
        t_fresh_run_dir
        if [[ "$scenario" == "a late failure" ]]; then
            t_flag_off_window "$T_FLAG_OFF_BREAKDOWN" "$(t_visit_error "$VISIT")"
        else
            t_flag_off_window "$T_FLAG_OFF_BREAKDOWN"
        fi
        t_report_has "flag_off_window judges the failRate through the stop with $scenario" "$line"
    done
}

# ---------------------------------------------------------------------------------------------
# Run-B drain deadline (drain_loadgen, drain_call_limit, frozen_log)

# t_drain_limits: the "SUBCOMMAND LIMIT" of each bounded Compose call so far, separated by |.
t_drain_limits() {
    paste -s -d '|' "$RUN_DIR/compose.limits" | tr -d '\r'
}

test_drain_loadgen_dockerCalls_limitedToTimeLeftBeforeDeadline() {
    local rc=0
    t_drain_stubs
    t_drain_window
    QUIESCE_TIMEOUT_SECONDS=30
    DOCKER_CALL_TIMEOUT_SECONDS=22
    # Each pause takes 4 s. The first frozen output has a visit in flight, so the drain unpauses
    # loadgen, and the next read, 10 s in, finds that visit's create resolved.
    echo 4 >"$RUN_DIR/takes.pause"
    t_drain_resolved "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" ui >"$RUN_DIR/logs.1"
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
    t_eq "drain_loadgen reaches Q with every Docker call limited" 0 "$rc"
    t_eq "drain_loadgen limits each Docker call to its bound or the time left, whichever is shorter" \
        "pause 22|unpause 22|pause 20|kill 15" "$(t_drain_limits)"
    t_eq "drain_loadgen reaches Q before its deadline" \
        "Q at 2026-01-01T00:00:15Z with 2 created alerts, all resolved, and no create in flight; loadgen killed while paused" \
        "$DRAIN_DETAIL"
}

# t_drain_deadline_case CASE RC PAUSED CALLS LIMITS DETAIL: drain_loadgen with a 30 s deadline,
# in a fresh run directory, over a run B whose one create its visit deleted. It returns RC with
# DETAIL, leaves LOADGEN_PAUSED at PAUSED and makes the Compose calls CALLS with the limits
# LIMITS. CASE says what takes the time: pausing, the running read takes all 30 s; killing, the
# pause takes 25 s and the second frozen read the 4 s left; unpausing, the same with a visit in
# flight in the frozen output; late kill, the kill answers 2 s after the deadline; kill ending,
# it answers in the deadline's second; kill in the last second, in the second before it.
t_drain_deadline_case() {
    (
        local rc=0
        t_fresh_run_dir
        t_drain_stubs
        t_drain_window
        QUIESCE_TIMEOUT_SECONDS=30
        t_drain_resolved "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" ui >"$RUN_DIR/logs.1"
        case "$1" in
            pausing)
                echo 30 >"$RUN_DIR/takes.logs.1"
                ;;
            killing | unpausing)
                echo 25 >"$RUN_DIR/takes.pause"
                echo 4 >"$RUN_DIR/takes.logs.3"
                ;;
            "late kill")
                echo 31 >"$RUN_DIR/takes.kill"
                ;;
            "kill ending")
                echo 29 >"$RUN_DIR/takes.kill"
                ;;
            "kill in the last second")
                echo 28 >"$RUN_DIR/takes.kill"
                ;;
        esac
        if [[ "$1" == "unpausing" ]]; then
            {
                cat "$RUN_DIR/logs.1"
                t_drain_opened "$T_DRAIN_RUN_2"
            } >"$RUN_DIR/logs.2"
        fi
        drain_loadgen || rc=$?
        t_eq "drain_loadgen status, $1 at the deadline" "$2" "$rc"
        t_eq "drain_loadgen LOADGEN_PAUSED, $1 at the deadline" "$3" "$LOADGEN_PAUSED"
        t_eq "drain_loadgen Compose calls, $1 at the deadline" "$4" "$(t_drain_calls)"
        t_eq "drain_loadgen call limits, $1 at the deadline" "$5" "$(t_drain_limits)"
        t_eq "drain_loadgen detail, $1 at the deadline" "$6" "$DRAIN_DETAIL"
    )
}

test_drain_loadgen_stepDueAtDeadline_startsNoCallAndLeavesPauseState() {
    t_drain_deadline_case pausing 1 0 "" "" \
        "drain deadline of 30 s reached before pausing loadgen"
    t_drain_deadline_case killing 1 1 "pause loadgen" "pause 30" \
        "drain deadline of 30 s reached before killing the paused loadgen"
    t_drain_deadline_case unpausing 1 1 "pause loadgen" "pause 30" \
        "paused: 1 visits between opening the page and their create outcome; drain deadline of 30 s reached before unpausing loadgen"
}

test_drain_loadgen_killEndsAfterDeadline_failsWithoutQ() {
    t_drain_deadline_case "late kill" 1 0 "pause loadgen|kill -s SIGKILL loadgen" "pause 30|kill 29" \
        "paused loadgen killed at or after the drain deadline of 30 s, 2 s late, so no Q"
}

# The kill starts 1 s in, after the frozen read's step. Seen in the deadline's second, it may have
# ended up to a second past the 30 s, so only a kill seen in the second before is Q.
test_drain_loadgen_killEndingNearDeadline_reachesQOnlyBeforeDeadlineSecond() {
    t_drain_deadline_case "kill ending" 1 0 "pause loadgen|kill -s SIGKILL loadgen" "pause 30|kill 29" \
        "paused loadgen killed at or after the drain deadline of 30 s, so no Q"
    t_drain_deadline_case "kill in the last second" 0 0 "pause loadgen|kill -s SIGKILL loadgen" \
        "pause 30|kill 29" \
        "Q at 2026-01-01T00:00:29Z with 1 created alerts, all resolved, and no create in flight; loadgen killed while paused"
}

test_drain_loadgen_neverQuiescent_endsAtLastStepBeforeDeadline() {
    local rc=0
    t_drain_stubs
    t_drain_window
    QUIESCE_TIMEOUT_SECONDS=30
    t_drain_created "$T_DRAIN_RUN_1" "$T_DRAIN_ALERT_1" >"$RUN_DIR/logs.1"
    drain_loadgen || rc=$?
    t_eq "drain_loadgen fails when never quiescent" 1 "$rc"
    t_eq "drain_loadgen keeps the last read's detail" \
        "not quiescent within 30s: unresolved: $T_DRAIN_ALERT_1" "$DRAIN_DETAIL"
    t_eq "drain_loadgen reads every step and ends rather than sleep into its deadline" \
        "6 reads, ended at $((T_DRAIN_CLOCK_START + 25))" \
        "$(cat "$RUN_DIR/logs.n") reads, ended at $(cat "$RUN_DIR/clock")"
}

test_frozen_log_drainDeadlineFirst_failsBeforeSleepingIntoIt() {
    local rc=0
    t_drain_stubs
    t_drain_window
    # An output that never settles: each read holds one line more than the read before.
    # shellcheck disable=SC2329 # Invoked by frozen_log through read_window.
    loadgen_logs() {
        local n
        n=$(($(cat "$RUN_DIR/logs.n") + 1))
        echo "$n" >"$RUN_DIR/logs.n"
        seq "$n"
    }
    PROBE_DEADLINE=$((T_DRAIN_CLOCK_START + 3))
    frozen_log || rc=$?
    t_eq "frozen_log fails at the drain deadline" 1 "$rc"
    t_eq "frozen_log names the drain deadline" \
        "paused loadgen's output still changing at the drain deadline" "$POLL_DETAIL"
    t_eq "frozen_log reads until the step before the drain deadline" \
        "3 reads, ended at $((T_DRAIN_CLOCK_START + 2))" \
        "$(cat "$RUN_DIR/logs.n") reads, ended at $(cat "$RUN_DIR/clock")"
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
