# Database images

All of EasyTrade's persistent state lives in one database, `TradeManagement`, served by the
`db` service. This folder holds one Docker build context per dialect: `mssql/` (SQL Server,
the default) and `postgres/`. `DB_TYPE` in the repository's [`.env`](../../.env) selects
which one runs, and `DB_URL` must point at the same dialect.
[db-adapter](../db-adapter/README.md) is the only component that connects to the database;
every other service reaches it over gRPC.

| Where                | What it does with these images                                                                  |
| -------------------- | ----------------------------------------------------------------------------------------------- |
| `compose.dev.yaml`   | Builds `src/db/${DB_TYPE}` and runs it as the `db` service, image `easytrade-db-${DB_TYPE}`     |
| `compose.build.yaml` | Builds `db-mssql` from `src/db/mssql` and `db-postgres` from `src/db/postgres` for the registry |
| `compose.yaml`       | Runs the pre-built `${REGISTRY}/db-${DB_TYPE}:${TAG}` image as the `db` service                 |
| Helm                 | Runs the `db-mssql` StatefulSet (enabled by default) or `db-postgres` (disabled by default)     |

The schema and the seed data ship inside these images. A schema change is a script change in
this folder: it needs no edit to the Compose files or the Helm values, only a rebuilt image
and, for an existing database, the [recreate procedure](#recreating-the-database).

## Layout

```
mssql/
  Dockerfile               SQL Server 2022 Express; sql-scripts/ -> /my-app, debug/ -> /my-app/debug
  sql-scripts/
    entrypoint.sh          starts run-initialization.sh beside sqlservr on every container start
    run-initialization.sh  creates the database, then runs the table scripts from a fixed list
    create-database.sql    CREATE DATABASE TradeManagement
    sql-<table>.sql        one script per table: its schema, and its seed rows where it has any
  debug/
    _sqlcmd.sh             sqlcmd helper sourced by the other debug scripts
    check-db.sh            row counts per table, accounts with balances, latest price per instrument
    show-account.sh        one account's details, balance and owned instruments
postgres/
  Dockerfile               postgres:16-alpine; sql-scripts/ -> /docker-entrypoint-initdb.d/
  sql-scripts/
    NN-<table>.sql         one script per table, run in filename order
```

Both Dockerfiles copy their whole `sql-scripts/` folder, so a new script is picked up without
a Dockerfile change.

## Script order

| Step     | PostgreSQL (`postgres/sql-scripts/`)         | MSSQL (`mssql/sql-scripts/`)                                    |
| -------- | -------------------------------------------- | --------------------------------------------------------------- |
| Database | Created by the base image from `POSTGRES_DB` | `create-database.sql`, retried up to 50 times until it succeeds |
| 1        | `01-packages.sql`                            | `sql-packages.sql`                                              |
| 2        | `02-accounts.sql`                            | `sql-accounts.sql`                                              |
| 3        | `03-balance.sql`                             | `sql-balance.sql`                                               |
| 4        | `04-products.sql`                            | `sql-products.sql`                                              |
| 5        | `05-instruments.sql`                         | `sql-instruments.sql`                                           |
| 6        | `06-pricing.sql`                             | `sql-pricing.sql`                                               |
| 7        | `07-ownedinstruments.sql`                    | `sql-ownedinstruments.sql`                                      |
| 8        | `08-trades.sql`                              | `sql-trades.sql`                                                |
| 9        | `09-balancehistory.sql`                      | `sql-balancehistory.sql`                                        |
| 10       | `10-creditcardorders.sql`                    | `sql-creditcardorders.sql`                                      |
| 11       | `11-creditcardorderstatus.sql`               | `sql-creditcardorderstatus.sql`                                 |
| 12       | `12-creditcards.sql`                         | `sql-creditcards.sql`                                           |
| 13       | `13-alerts.sql`                              | `sql-alerts.sql`                                                |

- **PostgreSQL:** the base image's entrypoint runs every file in `/docker-entrypoint-initdb.d`
  in filename order, so the numeric prefix encodes the dependency order.
- **MSSQL:** `run-initialization.sh` runs `create-database.sql`, then one `sqlcmd` call per
  script in the order the list is written, not by filename. Each script switches to the
  database with `USE [TradeManagement]`. The script prints `Setup done` after the last call
  whether or not every script succeeded.
- Both dialects create the same tables with identical table and column names. Primary keys,
  foreign keys and indexes are named explicitly, with the same names on both (for example
  `PK_Alerts`, `FK_Alerts_Accounts` and `IX_Alerts_AccountId`).
- CHECK constraints and defaults are declared without names. PostgreSQL names each check
  `<Table>_<Column>_check` and gives defaults no name; SQL Server generates `CK__` and `DF__`
  names from truncated table and column names and a hex suffix (for example
  `CK__Alerts__Directio__09A971A2`). Nothing may refer to them by name.
- Check expressions are written per dialect where the types behave differently. Outside
  `Alerts`, the enum checks lowercase the value on PostgreSQL, while SQL Server's
  case-insensitive default collation already ignores case. `Alerts` accepts only the exact
  enum values on both; SQL Server enforces this with a binary collation and `DATALENGTH`.
  PostgreSQL also gives `Alerts` four checks refusing `NaN` and infinite timestamps, which
  the SQL Server types cannot store.
- The two script sets are hand-maintained parallel ports and must be kept in sync.

## Adding a table to both dialects

- [ ] **PostgreSQL:** add `NN-<table>.sql` with the next free prefix, so it sorts after every
      table it references.
- [ ] **MSSQL:** add `sql-<table>.sql` in the `USE [TradeManagement]` / `GO` layout of the
      existing scripts. Add its `sqlcmd` line to `run-initialization.sh` after the scripts it
      depends on (in practice, the end of the list) and before the `END=` line; the existing
      lines keep their order.
- [ ] Add a branch for the table to the row-count `UNION ALL` in `mssql/debug/check-db.sh`.
- [ ] Keep table and column names identical on both dialects; db-adapter quotes identifiers,
      so PascalCase names work on both. Name primary keys, foreign keys and indexes
      explicitly, with the same names on both. CHECK expressions may differ per dialect where
      the types behave differently, and nothing may depend on the generated names of CHECK
      constraints or defaults.
- [ ] Use single-quoted string literals in T-SQL, so the script runs with `QUOTED_IDENTIFIER`
      on or off (for example through `sqlcmd -I`).
- [ ] Guard creation, so a rerun or a manual apply is harmless: `CREATE TABLE IF NOT EXISTS`
      on PostgreSQL, `IF OBJECT_ID(N'dbo.<Table>', N'U') IS NULL` on MSSQL.
- [ ] Put the data access in db-adapter (`src/db-adapter/repository/sql/`), never in another
      service.
- [ ] Neither Dockerfile changes. Existing databases need the
      [recreate procedure](#recreating-the-database).

## Debug scripts (MSSQL)

The MSSQL image ships bash helpers under `debug/`. They run inside the container, whose
working directory is `/my-app`, and connect to `TradeManagement` as `sa` with the
container's own `SA_PASSWORD`.

```sh
# Compose dev stack, from the repository root
docker compose -f compose.dev.yaml exec db ./debug/check-db.sh
docker compose -f compose.dev.yaml exec db ./debug/show-account.sh <account-id>

# Helm: the pod is easytrade-db-mssql-0 for the release name easytrade
kubectl exec -n <namespace> <pod> -- ./debug/check-db.sh
```

- `check-db.sh` prints the row count of every table, `Alerts` included, then all accounts
  with their balances and the latest price per instrument. When `Alerts` is missing it prints
  `Table [dbo].[Alerts] is missing; sql-alerts.sql must be applied.` and exits 1 after the
  full report.
- `show-account.sh` takes one argument, the account to show.

PostgreSQL has no debug scripts; open a `psql` session instead:

```sh
docker compose -f compose.dev.yaml exec db psql -U postgres -d TradeManagement
```

## Recreating the database

The `Alerts` table used by Portfolio Insights ships as `postgres/sql-scripts/13-alerts.sql`
and `mssql/sql-scripts/sql-alerts.sql`. The procedure below gets it, or any table added
later, into a database that was initialised before the script existed.

### Why init scripts do not add it to an existing database

- **PostgreSQL** runs `/docker-entrypoint-initdb.d` only when its data directory is empty.
  In Compose that directory is the anonymous volume the `postgres` base image declares.
  Compose carries it over when it restarts or recreates the `db` container (for example
  `make restart services=db` or `make redeploy services=db`), so the scripts never run again
  against that data.
- **MSSQL** reruns its whole list on every container start and does not stop on errors.
  Against surviving data, the `CREATE` statements and the inserts with fixed keys, such as
  the owner account, fail on what already exists, but every seed insert that takes generated
  ids (`NEWID()`) succeeds again: the preset accounts are added a second time, and
  `sql-ownedinstruments.sql` inserts a holding for each row of
  `Accounts CROSS JOIN Instruments`, so every rerun duplicates the seeded holdings.
  Restarting a persistent MSSQL database is therefore **not** a way to get the table.

### Compose

Neither Compose file declares a named database volume. For a fresh database, from the
repository root:

```sh
make clean   # down --remove-orphans --volumes --rmi local
make start
```

`make clean` removes the stack's containers, their volumes (anonymous ones included) and the
locally built images, so `make start` rebuilds the `db` image from the current scripts and
initialises an empty database. **This deletes all of the stack's data**, with one PostgreSQL
exception.

Once the `db` container has been recreated, the volume Compose carried over (see
[above](#why-init-scripts-do-not-add-it-to-an-existing-database)) is mounted by name, and
Docker does not delete a volume mounted by name when it removes the container. `make clean`
then leaves it behind as a dangling volume that still holds the database's data;
`make start` gets a new, empty volume regardless. The volume carries no Compose project
label, and on a shared engine other stacks leave dangling volumes too, so record its name
before cleaning and remove exactly that volume afterwards:

```sh
# PostgreSQL only: the MSSQL db container mounts no volume, so vol stays empty
vol=$(docker inspect --format '{{range .Mounts}}{{.Name}}{{end}}' \
  "$(docker compose -f compose.dev.yaml ps -aq db)")
make clean
docker volume rm "$vol"   # "no such volume" means make clean already removed it
```

If you did not record it, `docker volume ls -f dangling=true` lists the candidates; remove
the db's with `docker volume rm <volume>`.

With the runtime `compose.yaml`, run `docker compose -f compose.yaml down --volumes`, then
`docker compose -f compose.yaml up -d` with a `TAG` whose `db-${DB_TYPE}` image contains the
script. This deletes that stack's data too, with the same exception: record the volume with
`-f compose.yaml` in the `ps` command above.

### Helm

Persistence is off by default (the commented `persistence` blocks of `db-mssql` and
`db-postgres` in `helm/easytrade/values.yaml`), so a new database pod starts empty and runs
the current scripts.

With persistence enabled, `helm uninstall` (or `make k8s-uninstall`) leaves the
StatefulSet's PersistentVolumeClaim in place. Delete it before reinstalling; for the release
name `easytrade` it is `data-easytrade-db-mssql-0` or `data-easytrade-db-postgres-0`.
**This destroys the data stored in it.**

```sh
helm uninstall easytrade --namespace <namespace>
kubectl get pvc -n <namespace>
kubectl delete pvc -n <namespace> <name>
make k8s-install   # or your usual helm upgrade --install
```

See [`helm/easytrade/README.md`](../../helm/easytrade/README.md) for the persistence values.

### Keeping existing data

Back up the database first (for example with `pg_dump`, or `BACKUP DATABASE` through
`sqlcmd`), then apply the dialect's script once by hand:

| Dialect    | Command                                                                   |
| ---------- | ------------------------------------------------------------------------- |
| PostgreSQL | `psql -v ON_ERROR_STOP=1 -U postgres -d TradeManagement -f 13-alerts.sql` |
| MSSQL      | `sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -b -I -i sql-alerts.sql`     |

On the Compose dev stack, from the repository root:

```sh
# PostgreSQL: pipe the script from the checkout
docker compose -f compose.dev.yaml exec -T db \
  psql -v ON_ERROR_STOP=1 -U postgres -d TradeManagement < src/db/postgres/sql-scripts/13-alerts.sql

# MSSQL: copy the script in, then run it with the container's own SA_PASSWORD
docker compose -f compose.dev.yaml cp src/db/mssql/sql-scripts/sql-alerts.sql db:/tmp/sql-alerts.sql
docker compose -f compose.dev.yaml exec db \
  bash -c '/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -b -I -i /tmp/sql-alerts.sql'
```

Both scripts are guarded, so a second run changes nothing.

### Verify

- **MSSQL:** `./debug/check-db.sh` lists an `Alerts` row and exits 0. `Setup done` in the
  `db` log is not proof of success; on a fresh database the log
  (`docker compose -f compose.dev.yaml logs db`) must show no `Msg <n>, Level 11` or higher
  line.
- **PostgreSQL:** `\d "Alerts"` in `psql` shows the table with `PK_Alerts`, both foreign keys
  (`FK_Alerts_Accounts`, `FK_Alerts_Instruments`) and `IX_Alerts_AccountId`:

  ```sh
  docker compose -f compose.dev.yaml exec db psql -U postgres -d TradeManagement -c '\d "Alerts"'
  ```

- **Every target:** the full fresh-database check of each Compose and Helm target, with the
  typed catalog, the seed and the runtime path, is in
  [Verifying a stack](../../README.md#verifying-a-stack).

## Portfolio Insights

Endpoints, the `portfolio-insights-enabled` flag, its environment variables and the demo walkthrough: see [Portfolio insights (demo feature)](../../README.md#portfolio-insights-demo-feature).
