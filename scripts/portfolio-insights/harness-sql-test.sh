#!/usr/bin/env bash
# Tests the SQL helpers of the Portfolio Insights harnesses against real databases, on SQL Server
# and on PostgreSQL:
#   - read_armed_set of perf.sh, with armed_sql and db_query: a fresh database gives an empty set,
#     armed rows give exactly their sorted lower-case id,revision lines while disabled and
#     triggered rows are left out, and a failing client is a failed read, never a set;
#   - db_count_ids of loadgen-check.sh, with db_count_chunk and db_query: no ids count 0 without a
#     query, listed ids count exactly the rows present, a list longer than one chunk sums every
#     chunk's query, a non-canonical id is refused before any SQL reaches the database, and a
#     failing client is a failed count that carries the client's error.
# One disposable container per dialect runs an image built from src/db/mssql or src/db/postgres,
# so the schema of this checkout is the one queried. The checkout's perf.sh and loadgen-check.sh
# are sourced, each in its own subshell, and their helpers run unchanged. Only the Compose
# boundary is routed: `docker compose ... exec -T db ARGS...` runs ARGS in the dialect's
# container with docker exec -i, so the container's own sqlcmd or psql runs the helpers' SQL with
# the container's own SA_PASSWORD or local postgres role, as in a live run.
#
# Usage: scripts/portfolio-insights/harness-sql-test.sh [--mssql-image IMAGE] [--postgres-image IMAGE]
#   --mssql-image IMAGE     SQL Server image built from src/db/mssql (default: easytrade-db-mssql)
#   --postgres-image IMAGE  PostgreSQL image built from src/db/postgres (default: easytrade-db-postgres)
#   --help                  Show this help and exit
#
# Build the images from this checkout first, for example:
#   docker build -t easytrade-db-mssql src/db/mssql
#   docker build -t easytrade-db-postgres src/db/postgres
# These are the image names compose.dev.yaml uses for DB_TYPE=mssql and DB_TYPE=postgres.
#
# Prints one PASS or FAIL line per check, where a check run on both dialects names each failing
# row, and a final SUMMARY line. Exits 0 when every check passes, 1 when any check fails or a
# container cannot be removed, and 2 on a usage error or when docker, curl or jq is missing (the
# sourced harnesses require all three).
# The containers this run created, their volumes and the run's temporary files are removed on
# exit, and the seeded rows with them. Containers are addressed by the IDs docker printed, never
# by their names, and publish no port.

set -euo pipefail

# Git Bash otherwise rewrites container paths such as /opt/mssql-tools to C:/Program Files/Git/...; other shells ignore it.
export MSYS_NO_PATHCONV=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# The sourced harnesses resolve their compose file from the current directory, and docker.exe on
# Windows cannot read /c/... paths, so host paths stay relative to the repository root.
cd "$REPO_ROOT"

PERF_SH="scripts/portfolio-insights/perf.sh"
LOADGEN_CHECK_SH="scripts/portfolio-insights/loadgen-check.sh"
DIALECTS=(mssql postgres)
# A container's initialisation raises no event to wait on, so readiness is polled every
# POLL_STEP_SECONDS up to a deadline, as the harnesses themselves wait. The testing convention's
# rule against sleeping cannot be met by this wait; nothing else in this file waits.
READY_TIMEOUT_SECONDS=300
POLL_STEP_SECONDS=2
# The PostgreSQL entrypoint runs the init scripts on a temporary server that accepts local
# connections, and logs this line once it has stopped that server and before the final one starts.
PG_INIT_DONE='PostgreSQL init process complete'
# loadgen-check.sh's ID_CHUNK_SIZE; the chunk check also compares the sourced value with it.
CHUNK_SIZE=100
CHUNK_SEED_COUNT=150

# Synthetic canonical lower-case alert ids. The armed-set fixture holds two armed alerts, at
# revisions 1 and 3 and inserted in the reverse of their sorted order, one disabled alert and one
# triggered alert. Their hex letters show that SQL Server's upper-case GUID text is lower-cased.
ARMED_REV1_ID="f0000000-0000-4000-8000-00000000000a"
ARMED_REV3_ID="0b000000-0000-4000-8000-0000000000b3"
DISABLED_ID="0d000000-0000-4000-8000-0000000000d2"
TRIGGERED_ID="0e000000-0000-4000-8000-0000000000e1"

usage() {
    cat <<'EOF'
Usage: scripts/portfolio-insights/harness-sql-test.sh [--mssql-image IMAGE] [--postgres-image IMAGE]
  --mssql-image IMAGE     SQL Server image built from src/db/mssql (default: easytrade-db-mssql)
  --postgres-image IMAGE  PostgreSQL image built from src/db/postgres (default: easytrade-db-postgres)
  --help                  Show this help and exit
EOF
}

mssql_image="easytrade-db-mssql"
postgres_image="easytrade-db-postgres"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mssql-image | --postgres-image)
            if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
                echo "Option $1 requires a value." >&2
                usage >&2
                exit 2
            fi
            if [[ "$1" == --mssql-image ]]; then
                mssql_image="$2"
            else
                postgres_image="$2"
            fi
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

for tool in docker curl jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$tool is required on PATH: the sourced perf.sh and loadgen-check.sh check for docker, curl and jq." >&2
        exit 2
    fi
done

passed=0
failed=0
run_dir=""
containers=()
declare -A db_container=() stopped_container=()
container_id=""
sql_out=""
case_no=0
case_dir=""
reasons=()
h_status=""
h_error=""
h_count=""
h_queries=""
h_chunk_size=""
# Set only inside a helper subshell: the container its db service stands for, and the file that
# records each client call routed there.
ROUTE_CONTAINER=""
ROUTE_LOG=""

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
    local status=$? id
    trap - EXIT
    # Each ID is that of a container this run created. docker rm -f exits 0 when that container
    # is already gone, so a failure means it may remain; an earlier failure's status is kept, and
    # a passing run exits 1.
    for id in "${containers[@]}"; do
        if ! docker rm -f -v "$id" >/dev/null 2>&1; then
            echo "Could not remove container ${id}; remove it with: docker rm -f -v ${id}" >&2
            if [[ "$status" -eq 0 ]]; then
                status=1
            fi
        fi
    done
    if [[ -n "$run_dir" ]]; then
        rm -rf "$run_dir"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# docker: the Compose boundary of the sourced harnesses. Inside a helper subshell, which sets
# ROUTE_CONTAINER, `docker compose [-p P] [-f F]... exec -T db ARGS...` runs ARGS in that
# container with docker exec -i, as Compose runs them in the db service's container, and appends
# the call's last argument, the SQL, to ROUTE_LOG. Every other call reaches docker unchanged.
docker() {
    local -a args=("$@")
    local i=1
    if [[ -n "$ROUTE_CONTAINER" && "${args[0]:-}" == compose ]]; then
        while [[ "${args[i]:-}" == -p || "${args[i]:-}" == -f ]]; do
            i=$((i + 2))
        done
        if [[ "${args[i]:-}" == exec && "${args[i + 1]:-}" == -T && "${args[i + 2]:-}" == db ]]; then
            printf '%s\n' "${args[${#args[@]} - 1]}" >>"$ROUTE_LOG"
            command docker exec -i "$ROUTE_CONTAINER" "${args[@]:i+3}"
            return
        fi
    fi
    command docker "$@"
}

# Flattens a captured output file into one line for a FAIL reason.
one_line() {
    tr '\r\n' '  ' <"$1"
}

# last_log_lines DIALECT: the last lines of the dialect container's log on one line.
last_log_lines() {
    tail -n 5 "$run_dir/$1.log" | tr '\r\n' '  '
}

# new_container CHECK NAME DOCKER_ARGUMENT...: runs a docker command that creates a container and
# prints its ID, as docker run -d and docker create do, and sets container_id to that ID, which
# cleanup removes. The run aborts under CHECK when the command fails or prints no ID.
new_container() {
    local check="$1" name="$2"
    shift 2
    if ! docker "$@" >"$run_dir/$name.out" 2>"$run_dir/$name.err"; then
        abort "$check" "docker $1 failed for container ${name}: $(one_line "$run_dir/$name.err")"
    fi
    # The name may belong to a container this run did not create, so cleanup and every later
    # docker call use only the ID that the successful command printed.
    container_id="$(tr -d '\r' <"$run_dir/$name.out")"
    if [[ ! "$container_id" =~ ^[0-9a-f]{64}$ ]]; then
        abort "$check" "docker $1 printed '$(one_line "$run_dir/$name.out")' instead of a container ID, so container ${name} is not removed; remove it with: docker rm -f -v ${name}"
    fi
    containers+=("$container_id")
}

# db_try DIALECT SQL: runs SQL in the dialect's container with its own client, which exits
# non-zero on any SQL error, and leaves the output in $run_dir/sql.out. Returns the client's
# status.
db_try() {
    if [[ "$1" == mssql ]]; then
        # shellcheck disable=SC2016 # $SA_PASSWORD and $1 expand in the container's shell.
        docker exec "${db_container[mssql]}" bash -c \
            '/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -d TradeManagement -b -h -1 -W -Q "$1"' \
            _ "SET NOCOUNT ON; $2" >"$run_dir/sql.out" 2>&1 </dev/null
    else
        docker exec "${db_container[postgres]}" psql -v ON_ERROR_STOP=1 -U postgres -d TradeManagement -At -c "$2" \
            >"$run_dir/sql.out" 2>&1 </dev/null
    fi
}

# db_sql DIALECT CHECK SQL: db_try that aborts the run under CHECK when the client fails, and
# otherwise leaves the output, without carriage returns, in sql_out.
db_sql() {
    local status=0
    db_try "$1" "$3" || status=$?
    if [[ $status -ne 0 ]]; then
        abort "$2" "$1 query failed with status ${status}: $3 -> $(one_line "$run_dir/sql.out")"
    fi
    sql_out="$(tr -d '\r' <"$run_dir/sql.out")"
}

# alerts_count DIALECT CHECK: sets sql_out to the number of Alerts rows, counted directly.
alerts_count() {
    if [[ "$1" == mssql ]]; then
        db_sql mssql "$2" "SELECT COUNT(*) FROM [dbo].[Alerts];"
    else
        db_sql postgres "$2" 'SELECT count(*) FROM "Alerts";'
    fi
    if [[ ! "$sql_out" =~ ^[0-9]+$ ]]; then
        abort "$2" "direct count of $1 Alerts returned '${sql_out}'"
    fi
}

# insert_alerts DIALECT CHECK TUPLE...: inserts one alert per TUPLE "'ID', ENABLED, REVISION,
# TRIGGERED", ENABLED and TRIGGERED being 0 or 1, in one set-based INSERT on the first seeded
# account and instrument of the image, which both foreign keys require. A triggered alert gets a
# trigger time and value.
insert_alerts() {
    local dialect="$1" check="$2" values
    shift 2
    printf -v values '(%s), ' "$@"
    values="${values%, }"
    if [[ "$dialect" == mssql ]]; then
        db_sql mssql "$check" "INSERT INTO [dbo].[Alerts] ([Id], [AccountId], [Type], [InstrumentId], [Direction], [Threshold], [Enabled], [ArmingRevision], [TriggeredAt], [TriggerValue], [CreatedAt]) SELECT CONVERT(uniqueidentifier, [F].[Id]), (SELECT TOP 1 [Id] FROM [dbo].[Accounts] ORDER BY [Id]), 'TARGET_PRICE', (SELECT TOP 1 [Id] FROM [dbo].[Instruments] ORDER BY [Id]), 'ABOVE', 1, [F].[Enabled], [F].[Revision], CASE WHEN [F].[Triggered] = 1 THEN SYSDATETIMEOFFSET() END, CASE WHEN [F].[Triggered] = 1 THEN 2 END, SYSDATETIMEOFFSET() FROM (VALUES ${values}) AS [F] ([Id], [Enabled], [Revision], [Triggered]);"
    else
        db_sql postgres "$check" "INSERT INTO \"Alerts\" (\"Id\", \"AccountId\", \"Type\", \"InstrumentId\", \"Direction\", \"Threshold\", \"Enabled\", \"ArmingRevision\", \"TriggeredAt\", \"TriggerValue\", \"CreatedAt\") SELECT f.id::uuid, (SELECT \"Id\" FROM \"Accounts\" ORDER BY \"Id\" LIMIT 1), 'TARGET_PRICE', (SELECT \"Id\" FROM \"Instruments\" ORDER BY \"Id\" LIMIT 1), 'ABOVE', 1, f.enabled = 1, f.revision, CASE WHEN f.triggered = 1 THEN now() END, CASE WHEN f.triggered = 1 THEN 2 END, now() FROM (VALUES ${values}) AS f (id, enabled, revision, triggered);"
    fi
}

# hide_alerts DIALECT CHECK and restore_alerts DIALECT CHECK rename the Alerts table away and
# back: in between, the database looks like one created before the table was added.
hide_alerts() {
    if [[ "$1" == mssql ]]; then
        db_sql mssql "$2" "EXEC sp_rename 'dbo.Alerts', 'Alerts_hidden';"
    else
        db_sql postgres "$2" 'ALTER TABLE "Alerts" RENAME TO "Alerts_hidden";'
    fi
}

restore_alerts() {
    if [[ "$1" == mssql ]]; then
        db_sql mssql "$2" "EXEC sp_rename 'dbo.Alerts_hidden', 'Alerts';"
    else
        db_sql postgres "$2" 'ALTER TABLE "Alerts_hidden" RENAME TO "Alerts";'
    fi
}

# Loads perf.sh, whose guarded main does not run when it is sourced, and sets up the state main
# sets before its traps: perf.sh's own parse_options, check_tools and prepare_run read this
# test's options, check its tools and make a run directory under TMPDIR. Sourcing it from a
# function keeps the linter from reading the script's final steps as part of this file.
load_perf() {
    # shellcheck source-path=SCRIPTDIR source=perf.sh
    source "$PERF_SH"
    parse_options --project harness-sql-test --compose-file compose.dev.yaml
    check_tools
    prepare_run
}

# Loads loadgen-check.sh, whose guarded main does not run when it is sourced.
load_loadgen_check() {
    # shellcheck source-path=SCRIPTDIR source=loadgen-check.sh
    source "$LOADGEN_CHECK_SH"
}

# new_case_dir: sets case_dir to a new directory for one helper run, with an empty routed-call log.
new_case_dir() {
    case_no=$((case_no + 1))
    case_dir="$run_dir/case-$case_no"
    mkdir "$case_dir"
    : >"$case_dir/routed"
}

# count_lines FILE: sets REPLY to the number of lines in FILE.
count_lines() {
    local -a lines=()
    mapfile -t lines <"$1"
    REPLY="${#lines[@]}"
}

# set_text FILE: sets REPLY to FILE's lines joined by "|", to nothing for an empty file, or to
# "<no file>" when FILE does not exist.
set_text() {
    local -a lines=()
    local IFS='|'
    if [[ ! -f "$1" ]]; then
        REPLY="<no file>"
        return 0
    fi
    mapfile -t lines <"$1"
    REPLY="${lines[*]}"
}

# read_result NAME: sets REPLY to the text the helper subshell wrote to case_dir/NAME, or to
# nothing when it wrote none.
read_result() {
    REPLY=""
    if [[ -f "$case_dir/$1" ]]; then
        REPLY="$(<"$case_dir/$1")"
    fi
}

# collect_result SUBSHELL_STATUS SCRIPT: sets h_status, h_error, h_count, h_queries and
# h_chunk_size from the files the helper subshell left in case_dir. A subshell that ended before
# it wrote the helper's status, as when sourcing SCRIPT fails, gives an h_status that says so.
collect_result() {
    if [[ -f "$case_dir/status" ]]; then
        read_result status
        h_status="$REPLY"
        if [[ "$1" -ne 0 ]]; then
            h_status="${h_status}, then the subshell exited $1: $(one_line "$case_dir/subshell.err")"
        fi
    else
        h_status="none: the subshell sourcing $2 exited $1: $(one_line "$case_dir/subshell.err")"
    fi
    read_result error
    h_error="$REPLY"
    read_result count
    h_count="$REPLY"
    read_result chunk-size
    h_chunk_size="$REPLY"
    count_lines "$case_dir/routed"
    h_queries="$REPLY"
}

# run_read_armed_set DIALECT CONTAINER: in a subshell, sources perf.sh with its db service routed
# to CONTAINER and runs read_armed_set for DIALECT with RUN_DIR set to case_dir, where the helper
# writes the set to armed. Then collect_result.
run_read_armed_set() {
    local subshell=0
    (
        ROUTE_CONTAINER="$2"
        ROUTE_LOG="$case_dir/routed"
        TMPDIR="$case_dir"
        load_perf
        RUN_DIR="$case_dir"
        DIALECT="$1"
        ARMED_ERROR=""
        rc=0
        read_armed_set || rc=$?
        printf '%s' "$rc" >"$case_dir/status"
        printf '%s' "$ARMED_ERROR" >"$case_dir/error"
    ) >"$case_dir/subshell.out" 2>"$case_dir/subshell.err" || subshell=$?
    collect_result "$subshell" "$PERF_SH"
}

# run_db_count_ids DIALECT CONTAINER: in a subshell, sources loadgen-check.sh with its db service
# routed to CONTAINER and runs db_count_ids for DIALECT on the ids in case_dir/ids, with RUN_DIR
# set to case_dir. Then collect_result.
run_db_count_ids() {
    local subshell=0
    (
        ROUTE_CONTAINER="$2"
        ROUTE_LOG="$case_dir/routed"
        load_loadgen_check
        RUN_DIR="$case_dir"
        DIALECT="$1"
        PROJECT="harness-sql-test"
        COMPOSE_ARGS=(-f compose.dev.yaml)
        rc=0
        db_count_ids "$case_dir/ids" || rc=$?
        printf '%s' "$rc" >"$case_dir/status"
        printf '%s' "$DB_ERROR" >"$case_dir/error"
        printf '%s' "$DB_COUNT" >"$case_dir/count"
        printf '%s' "$ID_CHUNK_SIZE" >"$case_dir/chunk-size"
    ) >"$case_dir/subshell.out" 2>"$case_dir/subshell.err" || subshell=$?
    collect_result "$subshell" "$LOADGEN_CHECK_SH"
}

# expect ROW EXPECTED ACTUAL: records a reason when the two differ.
expect() {
    if [[ "$2" != "$3" ]]; then
        reasons+=("$1: expected [$2], got [$3]")
    fi
}

# error_text PREFIX FRAGMENT: sets REPLY to "PREFIX...FRAGMENT" when h_error starts with PREFIX
# and holds FRAGMENT after it, ignoring case, and otherwise to h_error itself.
error_text() {
    local error="${h_error,,}" prefix="${1,,}" fragment="${2,,}"
    REPLY="$h_error"
    if [[ "$error" == "$prefix"* && "${error#"$prefix"}" == *"$fragment"* ]]; then
        REPLY="$1...$2"
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

# alert_id PREFIX N: sets REPLY to the Nth synthetic canonical alert id under an 8-digit PREFIX.
alert_id() {
    printf -v REPLY '%s-0000-4000-8000-%012d' "$1" "$2"
}

run_dir="$(mktemp -d -t harness-sql-test.XXXXXX)"

# ---------------------------------------------------------------------------------------------
# One disposable database per dialect

mssql_ready="mssqlContainer_freshStart_createsAlertsTableWithoutSqlError"
postgres_ready="postgresContainer_freshStart_createsAlertsTable"

# SQL Server requires upper case, lower case, a digit and a symbol; the random part makes the
# password unique per run. It reaches docker only through the environment, never the command
# line, and the helpers read it inside the container.
if ! random_hex="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" ||
    [[ ! "$random_hex" =~ ^[0-9a-f]{32}$ ]]; then
    abort "$mssql_ready" "could not read 16 random bytes from /dev/urandom for the database passwords"
fi
name_suffix="$(date +%s)-$$-$RANDOM"

# ACCEPT_EULA has the value the image sets; the memory limits keep SQL Server from sizing itself
# for the host.
SA_PASSWORD="Pw9!${random_hex}" new_container "$mssql_ready" "harness-sql-test-mssql-${name_suffix}" \
    run -d --pull never --name "harness-sql-test-mssql-${name_suffix}" --memory 4g \
    -e ACCEPT_EULA=Y -e MSSQL_MEMORY_LIMIT_MB=2048 -e SA_PASSWORD "$mssql_image"
db_container[mssql]="$container_id"
POSTGRES_PASSWORD="Pw9!${random_hex}" new_container "$postgres_ready" "harness-sql-test-postgres-${name_suffix}" \
    run -d --pull never --name "harness-sql-test-postgres-${name_suffix}" \
    -e POSTGRES_PASSWORD -e POSTGRES_DB=TradeManagement "$postgres_image"
db_container[postgres]="$container_id"

# read_log CHECK DIALECT: writes the dialect container's log to $run_dir/DIALECT.log, and aborts
# under CHECK when the container has stopped.
read_log() {
    if ! docker logs "${db_container[$2]}" >"$run_dir/$2.log" 2>&1; then
        abort "$1" "docker logs failed: $(last_log_lines "$2")"
    fi
    if [[ "$(docker container inspect -f '{{.State.Running}}' "${db_container[$2]}" 2>/dev/null)" != true ]]; then
        abort "$1" "the $2 container stopped during initialisation: $(last_log_lines "$2")"
    fi
}

# run-initialization.sh logs "Setup done" after its last script, whether or not the scripts
# succeeded, so the log must also hold no SQL error and the table must exist.
deadline=$((SECONDS + READY_TIMEOUT_SECONDS))
while true; do
    read_log "$mssql_ready" mssql
    if grep -q '^Setup done' "$run_dir/mssql.log"; then
        break
    fi
    if [[ $SECONDS -ge $deadline ]]; then
        abort "$mssql_ready" "Setup done was not logged within ${READY_TIMEOUT_SECONDS} s: $(last_log_lines mssql)"
    fi
    sleep "$POLL_STEP_SECONDS"
done
if sql_error="$(grep -Em1 'Msg [0-9]+, Level (1[1-9]|2[0-5]),' "$run_dir/mssql.log")"; then
    abort "$mssql_ready" "initialisation logged: ${sql_error}"
fi
db_sql mssql "$mssql_ready" "SELECT CASE WHEN OBJECT_ID(N'dbo.Alerts', N'U') IS NULL THEN 0 ELSE 1 END;"
if [[ "$sql_out" != 1 ]]; then
    abort "$mssql_ready" "dbo.Alerts does not exist; the image predates sql-alerts.sql, rebuild it with: docker build -t ${mssql_image} src/db/mssql"
fi
pass "$mssql_ready"

# A failed init script stops the PostgreSQL container. After the init line the poll waits for the
# final server to answer a query on "Alerts"; a missing table ends it at once.
deadline=$((SECONDS + READY_TIMEOUT_SECONDS))
while true; do
    read_log "$postgres_ready" postgres
    if grep -qF "$PG_INIT_DONE" "$run_dir/postgres.log"; then
        if db_try postgres 'SELECT 1 FROM "Alerts" LIMIT 1;'; then
            break
        fi
        if grep -qF 'relation "Alerts" does not exist' "$run_dir/sql.out"; then
            abort "$postgres_ready" "\"Alerts\" does not exist; the image predates 13-alerts.sql, rebuild it with: docker build -t ${postgres_image} src/db/postgres"
        fi
    fi
    if [[ $SECONDS -ge $deadline ]]; then
        abort "$postgres_ready" "\"Alerts\" could not be queried within ${READY_TIMEOUT_SECONDS} s: $(last_log_lines postgres)"
    fi
    sleep "$POLL_STEP_SECONDS"
done
pass "$postgres_ready"

# ---------------------------------------------------------------------------------------------
# perf.sh: read_armed_set

check="readArmedSet_freshDatabase_writesEmptySet"
for dialect in "${DIALECTS[@]}"; do
    new_case_dir
    # A line left by an earlier read must not survive an empty result.
    echo "${ARMED_REV1_ID},1" >"$case_dir/armed"
    run_read_armed_set "$dialect" "${db_container[$dialect]}"
    set_text "$case_dir/armed"
    expect "$dialect" "status=0 error=[] queries=1 set=[]" \
        "status=${h_status} error=[${h_error}] queries=${h_queries} set=[${REPLY}]"
done
conclude "$check"

check="readArmedSet_armedDisabledAndTriggeredRows_writesSortedArmedIdRevisionLines"
for dialect in "${DIALECTS[@]}"; do
    insert_alerts "$dialect" "$check" "'${ARMED_REV1_ID}', 1, 1, 0" "'${ARMED_REV3_ID}', 1, 3, 0" \
        "'${DISABLED_ID}', 0, 2, 0" "'${TRIGGERED_ID}', 1, 1, 1"
    new_case_dir
    run_read_armed_set "$dialect" "${db_container[$dialect]}"
    set_text "$case_dir/armed"
    expect "$dialect" "status=0 error=[] set=[${ARMED_REV3_ID},3|${ARMED_REV1_ID},1]" \
        "status=${h_status} error=[${h_error}] set=[${REPLY}]"
done
conclude "$check"

check="readArmedSet_clientFails_returnsOneWithClientErrorAndNoSet"
# A db container that is not running: one created from the dialect's image and never started.
for dialect in "${DIALECTS[@]}"; do
    if [[ "$dialect" == mssql ]]; then
        image="$mssql_image"
    else
        image="$postgres_image"
    fi
    new_container "$check" "harness-sql-test-${dialect}-stopped-${name_suffix}" \
        create --pull never --name "harness-sql-test-${dialect}-stopped-${name_suffix}" "$image"
    stopped_container[$dialect]="$container_id"
done
# The client's own error for a database without the Alerts table.
declare -A missing_table_error=(
    [mssql]="Invalid object name 'dbo.Alerts'"
    [postgres]='relation "Alerts" does not exist'
)
for dialect in "${DIALECTS[@]}"; do
    for row in "db container not running" "Alerts table missing"; do
        new_case_dir
        if [[ "$row" == "db container not running" ]]; then
            fragment="is not running"
            run_read_armed_set "$dialect" "${stopped_container[$dialect]}"
        else
            fragment="${missing_table_error[$dialect]}"
            hide_alerts "$dialect" "$check"
            run_read_armed_set "$dialect" "${db_container[$dialect]}"
            restore_alerts "$dialect" "$check"
        fi
        set_text "$case_dir/armed"
        armed_set="$REPLY"
        error_text "armed-set query failed: " "$fragment"
        expect "$dialect, $row" "status=1 error=[armed-set query failed: ...${fragment}] set=[<no file>]" \
            "status=${h_status} error=[${REPLY}] set=[${armed_set}]"
    done
done
conclude "$check"

# ---------------------------------------------------------------------------------------------
# loadgen-check.sh: db_count_ids

check="dbCountIds_noIds_setsZeroCountWithoutQuery"
for dialect in "${DIALECTS[@]}"; do
    for row in "empty file" "blank lines only"; do
        new_case_dir
        if [[ "$row" == "empty file" ]]; then
            : >"$case_dir/ids"
        else
            printf '\n\n' >"$case_dir/ids"
        fi
        run_db_count_ids "$dialect" "${db_container[$dialect]}"
        expect "$dialect, $row" "status=0 count=0 error=[] queries=0" \
            "status=${h_status} count=${h_count} error=[${h_error}] queries=${h_queries}"
    done
done
conclude "$check"

check="dbCountIds_presentAndAbsentIds_countsPresentRowsInOneQuery"
alert_id ab000000 1
absent_first="$REPLY"
alert_id ab000000 2
absent_second="$REPLY"
for dialect in "${DIALECTS[@]}"; do
    new_case_dir
    printf '%s\n' "$ARMED_REV1_ID" "$absent_first" "$DISABLED_ID" "$TRIGGERED_ID" "$absent_second" \
        "$ARMED_REV3_ID" >"$case_dir/ids"
    run_db_count_ids "$dialect" "${db_container[$dialect]}"
    expect "$dialect" "status=0 count=4 error=[] queries=1" \
        "status=${h_status} count=${h_count} error=[${h_error}] queries=${h_queries}"
done
conclude "$check"

check="dbCountIds_moreIdsThanOneChunk_sumsEveryChunkQuery"
chunk_ids=()
chunk_tuples=()
for ((n = 1; n <= CHUNK_SEED_COUNT; n++)); do
    alert_id c1000000 "$n"
    chunk_ids+=("$REPLY")
    chunk_tuples+=("'${REPLY}', 1, 1, 0")
done
# Five present ids, then two absent ones, repeated: every chunk holds rows that are present.
interleaved_ids=()
for ((n = 0; n < CHUNK_SEED_COUNT / 5; n++)); do
    interleaved_ids+=("${chunk_ids[@]:n*5:5}")
    alert_id ab000000 $((100 + n * 2))
    interleaved_ids+=("$REPLY")
    alert_id ab000000 $((101 + n * 2))
    interleaved_ids+=("$REPLY")
done
for dialect in "${DIALECTS[@]}"; do
    insert_alerts "$dialect" "$check" "${chunk_tuples[@]}"
    for row in "exactly one chunk" "one id over one chunk" "present and absent ids over three chunks"; do
        new_case_dir
        case "$row" in
            "exactly one chunk")
                printf '%s\n' "${chunk_ids[@]:0:CHUNK_SIZE}" >"$case_dir/ids"
                present=$CHUNK_SIZE
                listed=$CHUNK_SIZE
                ;;
            "one id over one chunk")
                printf '%s\n' "${chunk_ids[@]:0:CHUNK_SIZE+1}" >"$case_dir/ids"
                present=$((CHUNK_SIZE + 1))
                listed=$((CHUNK_SIZE + 1))
                ;;
            *)
                printf '%s\n' "${interleaved_ids[@]}" >"$case_dir/ids"
                present=$CHUNK_SEED_COUNT
                listed=${#interleaved_ids[@]}
                ;;
        esac
        run_db_count_ids "$dialect" "${db_container[$dialect]}"
        expect "$dialect, $row" \
            "status=0 count=${present} error=[] queries=$(((listed + CHUNK_SIZE - 1) / CHUNK_SIZE)) chunk size=${CHUNK_SIZE}" \
            "status=${h_status} count=${h_count} error=[${h_error}] queries=${h_queries} chunk size=${h_chunk_size}"
    done
done
conclude "$check"

check="dbCountIds_nonCanonicalId_refusesBeforeAnyQuery"
upper_id="${ARMED_REV1_ID^^}"
# A canonical id followed by SQL that would delete every alert if it reached the database.
declare -A injection_id=(
    [mssql]="${ARMED_REV1_ID}'); DELETE FROM [dbo].[Alerts]; --"
    [postgres]="${ARMED_REV1_ID}'); DELETE FROM \"Alerts\"; --"
)
for dialect in "${DIALECTS[@]}"; do
    for row in "upper-case UUID" "SQL after a UUID"; do
        if [[ "$row" == "upper-case UUID" ]]; then
            bad_id="$upper_id"
        else
            bad_id="${injection_id[$dialect]}"
        fi
        alerts_count "$dialect" "$check"
        rows_before="$sql_out"
        new_case_dir
        printf '%s\n' "$ARMED_REV3_ID" "$bad_id" "$ARMED_REV1_ID" >"$case_dir/ids"
        run_db_count_ids "$dialect" "${db_container[$dialect]}"
        alerts_count "$dialect" "$check"
        expect "$dialect, $row" \
            "status=1 error=[refusing id [${bad_id}]: not a canonical UUID] queries=0 alerts=${rows_before}" \
            "status=${h_status} error=[${h_error}] queries=${h_queries} alerts=${sql_out}"
    done
done
conclude "$check"

check="dbCountIds_clientFails_returnsOneWithCountQueryError"
for dialect in "${DIALECTS[@]}"; do
    for row in "db container not running" "Alerts table missing"; do
        new_case_dir
        printf '%s\n' "$ARMED_REV1_ID" "$ARMED_REV3_ID" >"$case_dir/ids"
        if [[ "$row" == "db container not running" ]]; then
            fragment="is not running"
            run_db_count_ids "$dialect" "${stopped_container[$dialect]}"
        else
            fragment="${missing_table_error[$dialect]}"
            hide_alerts "$dialect" "$check"
            run_db_count_ids "$dialect" "${db_container[$dialect]}"
            restore_alerts "$dialect" "$check"
        fi
        error_text "count query failed: " "$fragment"
        expect "$dialect, $row" "status=1 error=[count query failed: ...${fragment}]" \
            "status=${h_status} error=[${REPLY}]"
    done
done
conclude "$check"

summarize
if [[ "$failed" -ne 0 ]]; then
    exit 1
fi
