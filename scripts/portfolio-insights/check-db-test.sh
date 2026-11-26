#!/usr/bin/env bash
# Tests the [dbo].[Alerts] row-count classification of src/db/mssql/debug/check-db.sh
# against a disposable SQL Server container built from src/db/mssql:
#   - a counted table exits 0 with its count row and the full report;
#   - an incomplete count batch exits 1 with a diagnostic after the full report;
#   - an existing table whose count produced no row exits 1 with the diagnostic and
#     without the missing notice, after the full report;
#   - a missing table exits 1 with its notice after the full report;
#   - a client failure stops the report and returns the client's exit status.
# The checkout's src/db/mssql/debug scripts are copied into the container, so the
# scripts in this tree are the ones tested.
#
# Usage: scripts/portfolio-insights/check-db-test.sh [--image IMAGE]
#   --image IMAGE  SQL Server image built from src/db/mssql (default: easytrade-db-mssql)
#   --help         Show this help and exit
#
# Build the image from this checkout first, for example:
#   docker build -t easytrade-db-mssql src/db/mssql
# easytrade-db-mssql is the image name compose.dev.yaml uses for DB_TYPE=mssql.
#
# Prints one PASS or FAIL line per check and a final SUMMARY line. Exits 0 when every
# check passes, 1 when any check fails or the container cannot be removed, and 2 on a usage
# error or when docker is missing.
# The container this run created, its volumes and the run's temporary files are removed on
# exit. The container is addressed by the ID docker run printed, never by its name.

set -euo pipefail

# Git Bash otherwise rewrites container paths such as /opt/mssql-tools to C:/Program Files/Git/...; other shells ignore it.
export MSYS_NO_PATHCONV=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Host paths stay relative to the repository root: docker.exe on Windows cannot read /c/... paths.
cd "$REPO_ROOT"

DEBUG_DIR="src/db/mssql/debug"
READY_TIMEOUT_SECONDS=300
POLL_STEP_SECONDS=2
MISSING_NOTICE='Table [dbo].[Alerts] is missing; sql-alerts.sql must be applied.'
UNCOUNTED_DIAGNOSTIC='The [dbo].[Alerts] row count could not be produced'
# A fixed value that is not the container's SA password, used to provoke a login failure.
WRONG_SA_PASSWORD='not-the-sa-password'

usage() {
    cat <<'EOF'
Usage: scripts/portfolio-insights/check-db-test.sh [--image IMAGE]
  --image IMAGE  SQL Server image built from src/db/mssql (default: easytrade-db-mssql)
  --help         Show this help and exit
EOF
}

image="easytrade-db-mssql"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)
            if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
                echo "Option --image requires a value." >&2
                usage >&2
                exit 2
            fi
            image="$2"
            shift 2
            ;;
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

if ! command -v docker >/dev/null 2>&1; then
    echo "docker is required on PATH." >&2
    exit 2
fi

passed=0
failed=0
container=""
run_dir=""
sql_out=""
check_db_status=0
check_db_out=""
check_db_err=""
reasons=()

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
    # container is empty or the ID of the container this run created. docker rm -f exits 0 when
    # that container is already gone, so a failure means it may remain; an earlier failure's
    # status is kept, and a passing run exits 1.
    if [[ -n "$container" ]] && ! docker rm -f -v "$container" >/dev/null 2>&1; then
        echo "Could not remove container ${container}; remove it with: docker rm -f -v ${container}" >&2
        if [[ "$status" -eq 0 ]]; then
            status=1
        fi
    fi
    if [[ -n "$run_dir" ]]; then
        rm -rf "$run_dir"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Flattens a captured output file into one line for a FAIL reason.
one_line() {
    tr '\r\n' '  ' <"$1"
}

# Runs one query in the container with the container's own SA password; -b turns any
# SQL error into a nonzero exit. On failure the run aborts under CHECK; on success the
# output is left in sql_out.
sql_or_abort() {
    local check="$1" query="$2"
    if ! docker exec "$container" bash -c \
        "/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P \"\$SA_PASSWORD\" -d TradeManagement -b -h -1 -W -Q \"\$1\"" \
        _ "$query" >"$run_dir/sql.out" 2>&1; then
        abort "$check" "query failed: ${query} -> $(one_line "$run_dir/sql.out")"
    fi
    sql_out="$(tr -d '\r' <"$run_dir/sql.out")"
}

# Counts the rows of dbo.TABLE directly; the count is left in sql_out.
count_rows_or_abort() {
    local check="$1" table="$2"
    sql_or_abort "$check" "SET NOCOUNT ON; SELECT COUNT(*) FROM [dbo].[${table}];"
    if [[ ! "$sql_out" =~ ^[0-9]+$ ]]; then
        abort "$check" "direct count of dbo.${table} returned '${sql_out}'"
    fi
}

# Runs the checkout's check-db.sh in the container and captures stdout, stderr and the
# exit status separately. Arguments after NAME are extra docker exec options.
run_check_db() {
    local name="$1"
    shift
    check_db_out="$run_dir/${name}.out"
    check_db_err="$run_dir/${name}.err"
    check_db_status=0
    docker exec "$@" "$container" ./debug/check-db.sh >"$check_db_out" 2>"$check_db_err" ||
        check_db_status=$?
}

expect_status() {
    if [[ "$check_db_status" -ne "$1" ]]; then
        reasons+=("exit status ${check_db_status}, expected $1 (stderr: $(one_line "$check_db_err"))")
    fi
}

expect_line() {
    if ! grep -qxF -- "$2" "$1"; then
        reasons+=("$(basename "$1") has no line '$2'")
    fi
}

expect_no_line() {
    if grep -qxF -- "$2" "$1"; then
        reasons+=("$(basename "$1") has the line '$2'")
    fi
}

expect_text() {
    if ! grep -qF -- "$2" "$1"; then
        reasons+=("$(basename "$1") lacks '$2'")
    fi
}

expect_no_text() {
    if grep -qF -- "$2" "$1"; then
        reasons+=("$(basename "$1") contains '$2'")
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

run_dir="$(mktemp -d -t check-db-test.XXXXXX)"

copy_check="checkDbScripts_copyFromCheckout_replacesImageCopies"
if [[ ! -f "$DEBUG_DIR/check-db.sh" || ! -f "$DEBUG_DIR/_sqlcmd.sh" ]]; then
    abort "$copy_check" "${DEBUG_DIR}/check-db.sh or _sqlcmd.sh not found under ${REPO_ROOT}"
fi

# SQL Server requires upper case, lower case, a digit and a symbol; the random part makes the
# password unique per run. It reaches docker only through the environment, never the command line.
ready_check="mssqlContainer_freshStart_logsSetupDoneWithinDeadline"
if ! random_hex="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" ||
    [[ ! "$random_hex" =~ ^[0-9a-f]{32}$ ]]; then
    abort "$ready_check" "could not read 16 random bytes from /dev/urandom for the SA password"
fi

container_name="check-db-test-$(date +%s)-$$-$RANDOM"
if ! SA_PASSWORD="Pw9!${random_hex}" docker run -d --pull never --name "$container_name" \
    --memory 4g -e MSSQL_MEMORY_LIMIT_MB=2048 -e SA_PASSWORD \
    "$image" >"$run_dir/run.out" 2>"$run_dir/run.err"; then
    abort "$ready_check" "docker run failed for image ${image}: $(one_line "$run_dir/run.err")"
fi
# The name may belong to a container this run did not create, so cleanup and every later
# docker call use only the ID that the successful docker run printed.
printed_id="$(tr -d '\r' <"$run_dir/run.out")"
if [[ ! "$printed_id" =~ ^[0-9a-f]{64}$ ]]; then
    abort "$ready_check" "docker run printed '$(one_line "$run_dir/run.out")' instead of a container ID, so container ${container_name} is not removed; remove it with: docker rm -f -v ${container_name}"
fi
container="$printed_id"

# run-initialization.sh logs "Setup done" after its last script, whether or not the scripts succeeded.
deadline=$(($(date +%s) + READY_TIMEOUT_SECONDS))
while true; do
    if ! docker logs "$container" >"$run_dir/init.log" 2>&1; then
        abort "$ready_check" "docker logs failed: $(one_line "$run_dir/init.log")"
    fi
    if grep -q '^Setup done' "$run_dir/init.log"; then
        break
    fi
    if [[ "$(docker container inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" != true ]]; then
        abort "$ready_check" "container stopped before Setup done: $(tail -n 5 "$run_dir/init.log" | tr '\r\n' '  ')"
    fi
    if [[ "$(date +%s)" -ge "$deadline" ]]; then
        abort "$ready_check" "Setup done was not logged within ${READY_TIMEOUT_SECONDS} s"
    fi
    sleep "$POLL_STEP_SECONDS"
done
pass "$ready_check"

# "Setup done" is no evidence of success, so the initialisation log must hold no SQL error.
init_check="mssqlContainer_initialisation_logsNoSqlErrorAtLevel11OrAbove"
if sql_error="$(grep -Em1 'Msg [0-9]+, Level (1[1-9]|2[0-5]),' "$run_dir/init.log")"; then
    abort "$init_check" "initialisation logged: ${sql_error}"
fi
pass "$init_check"

table_check="mssqlContainer_initialisation_createsAlertsTable"
sql_or_abort "$table_check" "SET NOCOUNT ON; SELECT CASE WHEN OBJECT_ID(N'dbo.Alerts', N'U') IS NULL THEN 0 ELSE 1 END;"
if [[ "$sql_out" != 1 ]]; then
    abort "$table_check" "dbo.Alerts does not exist; the image predates sql-alerts.sql, rebuild it with: docker build -t ${image} src/db/mssql"
fi
pass "$table_check"

if ! docker cp "$DEBUG_DIR/." "$container:/my-app/debug" >"$run_dir/cp.out" 2>&1; then
    abort "$copy_check" "docker cp failed: $(one_line "$run_dir/cp.out")"
fi
pass "$copy_check"

# a. A counted table: exit 0, its count row equals a direct count, and the report is complete.
check="checkDb_alertsCounted_exitsZeroWithCountRow"
count_rows_or_abort "$check" Alerts
alerts_before="$sql_out"
sql_or_abort "$check" "SET NOCOUNT ON; INSERT INTO [dbo].[Alerts] ([AccountId], [Type], [InstrumentId], [Direction], [Threshold], [CreatedAt]) OUTPUT INSERTED.[Id] SELECT (SELECT TOP 1 [Id] FROM [dbo].[Accounts] ORDER BY [Id]), 'TARGET_PRICE', (SELECT TOP 1 [Id] FROM [dbo].[Instruments] ORDER BY [Id]), 'ABOVE', 1, SYSDATETIMEOFFSET() FROM (VALUES (1), (2)) AS [Fixture] ([N]);"
alert_ids=()
while IFS= read -r alert_id; do
    if [[ "$alert_id" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
        alert_ids+=("'${alert_id}'")
    fi
done <<<"$sql_out"
if [[ ${#alert_ids[@]} -ne 2 ]]; then
    abort "$check" "fixture insert returned ${#alert_ids[@]} alert ids, expected 2"
fi
count_rows_or_abort "$check" Alerts
alerts_direct="$sql_out"
if [[ "$alerts_direct" -ne $((alerts_before + 2)) ]]; then
    abort "$check" "direct count of dbo.Alerts is ${alerts_direct}, expected $((alerts_before + 2))"
fi
run_check_db counted
alert_id_list="$(printf '%s, ' "${alert_ids[@]}")"
sql_or_abort "$check" "DELETE FROM [dbo].[Alerts] WHERE [Id] IN (${alert_id_list%, });"
expect_status 0
expect_line "$check_db_out" "Alerts|${alerts_direct}"
expect_no_line "$check_db_out" "$MISSING_NOTICE"
expect_line "$check_db_out" "=== Accounts ==="
expect_line "$check_db_out" "=== Latest Price Per Instrument ==="
expect_no_text "$check_db_err" "$UNCOUNTED_DIAGNOSTIC"
conclude "$check"

# b. An incomplete count batch: hiding a counted table fails the batch with Msg 208, which
# sqlcmd still exits 0 on without -b. Exit 1 with the diagnostic, after the full report.
check="checkDb_countBatchIncomplete_exitsOneWithDiagnostic"
sql_or_abort "$check" "EXEC sp_rename 'dbo.CreditCards', 'CreditCards_checkdb_hidden';"
run_check_db uncounted
sql_or_abort "$check" "EXEC sp_rename 'dbo.CreditCards_checkdb_hidden', 'CreditCards';"
expect_status 1
if grep -q '^Alerts|' "$check_db_out"; then
    reasons+=("$(basename "$check_db_out") has an Alerts count row")
fi
expect_no_line "$check_db_out" "$MISSING_NOTICE"
expect_text "$check_db_err" "$UNCOUNTED_DIAGNOSTIC"
expect_line "$check_db_out" "=== Accounts ==="
expect_line "$check_db_out" "=== Latest Price Per Instrument ==="
conclude "$check"

# c. An existing table whose count produced no row: a row-level security filter predicate that
# divides by zero for every row fails the dynamic Alerts count with Msg 8134, while the rest of
# the batch still runs. A clustered-index disable cannot stand in for it, because its Msg 8655
# aborts the whole batch. Exit 1 with the diagnostic, no missing notice, the other counts and
# the full report.
check="checkDb_alertsExistUncounted_exitsOneWithoutMissingNotice"
count_rows_or_abort "$check" Instruments
instruments_direct="$sql_out"
# The predicate runs only for a stored row, so one fixture row makes the count fail.
sql_or_abort "$check" "SET NOCOUNT ON; INSERT INTO [dbo].[Alerts] ([AccountId], [Type], [InstrumentId], [Direction], [Threshold], [CreatedAt]) OUTPUT INSERTED.[Id] SELECT (SELECT TOP 1 [Id] FROM [dbo].[Accounts] ORDER BY [Id]), 'TARGET_PRICE', (SELECT TOP 1 [Id] FROM [dbo].[Instruments] ORDER BY [Id]), 'ABOVE', 1, SYSDATETIMEOFFSET();"
if [[ ! "$sql_out" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    abort "$check" "fixture insert returned '${sql_out}' instead of one alert id"
fi
uncounted_alert_id="$sql_out"
sql_or_abort "$check" "CREATE FUNCTION [dbo].[Alerts_checkdb_failing_filter] (@Threshold DECIMAL (18, 8)) RETURNS TABLE WITH SCHEMABINDING AS RETURN SELECT 1 AS [Visible] WHERE 1 / (@Threshold - @Threshold) = 1;"
sql_or_abort "$check" "CREATE SECURITY POLICY [dbo].[Alerts_checkdb_failing_policy] ADD FILTER PREDICATE [dbo].[Alerts_checkdb_failing_filter]([Threshold]) ON [dbo].[Alerts] WITH (STATE = ON);"
run_check_db alerts-uncounted
# The filter predicate also applies to DELETE, so the policy goes before the fixture row.
sql_or_abort "$check" "DROP SECURITY POLICY [dbo].[Alerts_checkdb_failing_policy]; DROP FUNCTION [dbo].[Alerts_checkdb_failing_filter];"
sql_or_abort "$check" "DELETE FROM [dbo].[Alerts] WHERE [Id] = '${uncounted_alert_id}';"
expect_status 1
if grep -q '^Alerts|' "$check_db_out"; then
    reasons+=("$(basename "$check_db_out") has an Alerts count row")
fi
expect_no_line "$check_db_out" "$MISSING_NOTICE"
expect_text "$check_db_err" "$UNCOUNTED_DIAGNOSTIC"
expect_line "$check_db_out" "Instruments|${instruments_direct}"
expect_line "$check_db_out" "=== Accounts ==="
expect_line "$check_db_out" "=== Latest Price Per Instrument ==="
conclude "$check"

# d. A missing table: exit 1 with the missing notice, the other counts and the full report.
check="checkDb_alertsMissing_exitsOneAfterFullReport"
count_rows_or_abort "$check" Instruments
instruments_direct="$sql_out"
sql_or_abort "$check" "DROP TABLE [dbo].[Alerts];"
run_check_db missing
expect_status 1
expect_line "$check_db_out" "$MISSING_NOTICE"
expect_line "$check_db_out" "Instruments|${instruments_direct}"
expect_line "$check_db_out" "=== Accounts ==="
expect_line "$check_db_out" "=== Latest Price Per Instrument ==="
expect_no_text "$check_db_err" "$UNCOUNTED_DIAGNOSTIC"
conclude "$check"

# e. A client failure: a wrong password makes the count's sqlcmd fail; check-db.sh exits with
# the client's own status and stops at the row counts.
check="checkDb_clientLoginFails_propagatesClientExitStatus"
client_status=0
docker exec -e "SA_PASSWORD=${WRONG_SA_PASSWORD}" "$container" bash -c \
    "/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P \"\$SA_PASSWORD\" -d TradeManagement -Q 'SELECT 1'" \
    >"$run_dir/client.out" 2>&1 || client_status=$?
if [[ "$client_status" -eq 0 ]]; then
    abort "$check" "the direct client exited 0 with a wrong SA password"
fi
run_check_db login -e "SA_PASSWORD=${WRONG_SA_PASSWORD}"
expect_status "$client_status"
expect_no_line "$check_db_out" "=== Accounts ==="
expect_text "$check_db_err" "Login failed for user 'sa'"
conclude "$check"

summarize
if [[ "$failed" -ne 0 ]]; then
    exit 1
fi
