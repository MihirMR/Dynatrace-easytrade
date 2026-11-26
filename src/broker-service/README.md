# EasyTradeBrokerService

This service manages account balances and processes trades. It leverages gRPC to communicate with the `db-adapter` service for data persistence.

## Technologies used

- .NET 10 (ASP.NET Core)
- Docker
- gRPC

## Local build instructions

### Standard .NET Development

```bash
dotnet build
dotnet test test/BrokerService.test.csproj
dotnet run --project src/BrokerService.csproj
```
### Docker Build

From the repository root:

```bash
make build services=broker-service      # build the image from local source
make redeploy services=broker-service   # rebuild and recreate it in the running stack
```

`make` handles the build context and the shared `src/proto/` definitions for you. Run
`make help` for every target.

## Endpoints

See [`broker-service.http`](broker-service.http) for the full request collection - run it
straight from your editor. Plus `/version`, `/livez` and `/readyz`.

## Portfolio insights and alerts

A simulated demo feature, **not financial advice**: portfolio figures plus price and
profit/loss alerts, computed from the existing holdings, trades and generated prices. It is
gated end to end by the feature flag `portfolio-insights-enabled`, which is off by default.

Demo walkthrough, the three variables (`ENABLE_PORTFOLIO_INSIGHTS`, `ALERT_EVALUATION_INTERVAL_SECONDS`, `PORTFOLIO_INSIGHTS_ALERT_WEIGHT`) and the database recreate note: see [Portfolio insights (demo feature)](../../README.md#portfolio-insights-demo-feature).
Runnable requests are in [`broker-service.http`](broker-service.http).

### Feature flag

Enable the flag with `PUT /v1/flags/portfolio-insights-enabled` and `{"enabled": true}` on
feature-flag-service (see
[`feature-flag-service.http`](../feature-flag-service/feature-flag-service.http)), or at
startup with `ENABLE_PORTFOLIO_INSIGHTS=true`.

The broker reads the flag **fresh on every decision**, with no cache, unlike the
problem-pattern flags, which are cached for **FEATURE_FLAG_CACHE_DURATION_S**. The read goes
through the registered OpenFeature provider with a **2 s deadline** and fails closed:

| Flag service answer | Result | Log |
| --- | --- | --- |
| `enabled: true` | Enabled | none |
| `enabled: false` | Disabled | none |
| Non-200, such as an unknown flag | Disabled | The connector's existing Warning |
| Transport failure, unreadable JSON or timeout | Disabled | Warning `Portfolio insights flag unreadable, treating as disabled`, with `reason` (`timeout` or the exception type) |

While the flag is disabled:

- all seven endpoints answer **403** with `Content-Type: application/json` and exactly
  `{"error":"feature_disabled"}`. The flag is read while the request is routed, before the
  problem-pattern middleware, and the gate, a resource filter that runs before model binding,
  answers from that decision, so even a malformed body or a missing `accountId` gets 403. The
  2 s is the flag read's deadline: with a hung flag service the 403 is answered once that read
  gives up, and the tests check that it arrives within 3 s;
- a non-GUID path segment matches no route and returns 404, with the flag on or off;
- the alert evaluator does nothing: no db-adapter, pricing or metric activity.

A disable takes effect on the next request, and for the evaluator at the start of its next
cycle.

### Endpoint reference

Besides the errors listed, every endpoint can answer `403` (flag off) and `503` (db-adapter
failure). A db-adapter call that gets no reply within 10 s, the alert call budget
`AlertRepository.CallTimeout`, is such a failure, so a hung db-adapter answers 503 once that
budget has passed rather than holding the request.

| Method and path | Request | Success | Errors |
| --- | --- | --- | --- |
| `GET /v1/portfolio/insights/{accountId}` | none | 200 insights body | 404 unknown account; 503 pricing unavailable |
| `POST /v1/alerts` | `{accountId, type, instrumentId, direction, threshold}` | 201 alert: `enabled: true`, `armingRevision: 1`, `triggeredAt` and `triggerValue` null, `acknowledged: false`; no `Location` header | 400 binding (malformed JSON; quoted, exponent or out-of-domain `threshold`); 400 missing field, inexact `type` or `direction`, `TARGET_PRICE` threshold ≤ 0, or `PROFIT_LOSS` for an instrument the account does not hold with quantity > 0; 404 unknown account or instrument |
| `GET /v1/alerts?accountId=` | none | 200 `{"results": [...]}`, `createdAt` descending, then `id` descending; `{"results": []}` when none | 400 missing or non-GUID `accountId`; 404 unknown account |
| `PATCH /v1/alerts/{id}` | `{"enabled": bool}` | 200 updated alert. `true` re-arms: clears `triggeredAt`, `triggerValue` and `acknowledged`, and sets `armingRevision + 1`. `false` only disables and keeps trigger data | 400 missing or null `enabled`; 404 unknown alert |
| `DELETE /v1/alerts/{id}` | none | 204; removes the alert and its notification | 404 unknown alert |
| `GET /v1/alerts/notifications?accountId=&unacknowledged=true` | none | 200 `{"results": [...]}`: alerts whose current arming triggered, `triggeredAt` descending. `unacknowledged=true` keeps only unacknowledged ones; absent or `false` returns all | 400 missing or non-GUID `accountId`, or non-boolean `unacknowledged`; 404 unknown account |
| `POST /v1/alerts/{id}/acknowledge` | none | 204. Acknowledges the notification of the current arming; a no-op, still 204, when it has not triggered | 404 unknown alert |

- Rule violations return the existing `ErrorResponse` `{"statusCode": n, "message": "..."}`.
  A body or query that cannot bind returns ASP.NET Core's automatic 400 problem response.
  The 403 body is exactly `{"error":"feature_disabled"}`.
- `POST /v1/alerts` checks run in this order, and the first failure answers: gate, binding,
  fields, account, instrument, holding.
- "Unknown account" means the account has no balance row.
- Enum values are exact and case-sensitive: `TARGET_PRICE`, `PROFIT_LOSS`, `ABOVE`, `BELOW`,
  `LOW`, `MEDIUM`, `HIGH`. JSON is camelCase, and decimals are JSON numbers.
- `accountId` is taken from the path, query or body as on the existing endpoints, with no
  authentication. The alert-id endpoints have no ownership check.

### Response shapes

Insights:

- `totalValue`, `totalInvested`, `unrealizedPnl`, `unrealizedPnlPercent`;
- `allocations[]` of `{instrumentId, name, quantity, value, percent}`;
- `largestPosition`: an allocation, or `null`;
- `riskLevel`: `LOW`, `MEDIUM`, `HIGH`, or `null`.

Alerts, and every notification, use one shape:

| Field | Type | Notes |
| --- | --- | --- |
| `id` | GUID string | Generated by the database |
| `accountId`, `instrumentId` | GUID string | As created |
| `type` | `TARGET_PRICE` or `PROFIT_LOSS` | |
| `direction` | `ABOVE` or `BELOW` | |
| `threshold` | number | A price for `TARGET_PRICE`, a percentage for `PROFIT_LOSS` |
| `enabled` | boolean | User intent; a trigger does not change it |
| `armingRevision` | integer | 1 at creation, plus 1 on each enable |
| `triggeredAt` | ISO-8601 string or `null` | Stamped by db-adapter at the trigger |
| `triggerValue` | number or `null` | The observed price or P/L percent, rounded to 8 places |
| `acknowledged` | boolean | |
| `createdAt` | ISO-8601 string | Stamped by db-adapter |

The threshold is a plain JSON number: not quoted, no exponent, and at most 10 integer and 8
fractional digits once trailing zeros are removed. A `TARGET_PRICE` threshold must be > 0, so
its smallest value is `0.00000001`. A `PROFIT_LOSS` threshold is a percentage and may be
negative. Nothing is rounded.

### Insights calculation and cost basis

- Inputs come through the existing data access: holdings, instrument names, trades and the
  account balance through db-adapter, plus one latest-prices call to pricing-service.
- A holding is an owned instrument with quantity > 0. With none, the endpoint returns zero
  totals, `allocations: []` and `null` `largestPosition` and `riskLevel`, and never calls
  pricing.
- The price is the latest candle's `Close`; candles tied on timestamp go to the greater close,
  then the greater open. A pricing failure, a price fetch with no reply within the same 10 s
  budget, or an empty price list while holdings exist, returns 503. A holding without a
  candle is valued at 0.
- `value = quantity × close`, `totalValue = Σ value`, `totalInvested = Σ cost basis`.
  `unrealizedPnl` and `unrealizedPnlPercent` are 0 when `totalInvested` is 0. `percent` is
  the share of `totalValue`, and 0 when `totalValue` is 0.
- Allocations are ordered by value descending, then `instrumentId`. The largest position is
  the highest value; ties go to the lowest `instrumentId`.
- Risk follows the largest share: `LOW` below 25 %, `MEDIUM` from 25 % to 50 % with both ends
  inclusive, `HIGH` above 50 %.
- Prices are used signed, every division is guarded against zero, and nothing is rounded on
  the server.

Cost basis is not stored, so it is derived from the account's retained trades:

- Executed trades are `buy` and `sell` with `transactionHappened = true`, and `longbuy` and
  `longsell` with `tradeClosed = true` and the exact status `Long buy transaction finished!` or
  `Long sell transaction finished!`. Every other row is ignored.
- Executed trades replay in `timestampOpen` order, then `id`, at average cost. Fees are
  excluded.
- Quantity older than the retained trades (seed data, trades purged after 24 h) forms an
  opening lot `Q0 = max(0, quantity − bought + sold)` valued at the latest price, so it
  carries no unrealized P/L.
- Example: 10 seeded units and a buy of 5 at 100, so 15 held, with a latest close of 110:
  cost basis 1,600, value 1,650, P/L 50.

Two approximations remain: seeded holdings show near-zero P/L, and the replay order of long
trades is approximate, because their execution time is not persisted.

### Alert evaluation

`AlertEvaluationSchedulerService` is a second hosted service beside the long-trade scheduler.
It runs one cycle at startup, then one every `ALERT_EVALUATION_INTERVAL_SECONDS` on a
`PeriodicTimer`, so cycles never overlap in one process. Each cycle:

1. reads the flag once, and stops when it is off or unreadable;
2. lists the armed alerts (enabled and not triggered) of every account, and fetches the latest
   prices once;
3. observes each alert's value: `TARGET_PRICE` uses the latest close and needs no holding,
   `PROFIT_LOSS` uses the holding's P/L % under the cost-basis rule;
4. triggers on a strict crossing: `ABOVE` when value > threshold, `BELOW` when
   value < threshold. Equality never triggers.

- Skips are logged as Warnings: `no_holding` (a `PROFIT_LOSS` alert without a positive
  holding) and `no_price` (no candle for the instrument).
- A per-alert failure is logged and counted, and the cycle continues.
- The cycle fails, with no alert evaluated, when listing alerts or fetching prices fails, or
  when prices come back empty while armed alerts exist. The next tick retries.
- Work runs with a bounded parallelism of 8: one item per `TARGET_PRICE` alert and one per
  account with `PROFIT_LOSS` alerts, so each account's positions load once per cycle.

**One notification per arming.** A trigger is a single conditional write in db-adapter
(`TriggerAlert`) that matches only an enabled, untriggered row at the listed
`armingRevision`. Repeated evaluation, overlapping cycles, concurrent replicas and stale
snapshots after a re-arm therefore produce exactly one notification per
`(id, armingRevision)`. `PATCH {"enabled": true}` re-arms the alert with a new revision.

Scripts read the cycle summary line, which starts with the marker
`Alert evaluation cycle finished`:

```text
Alert evaluation cycle finished: alerts [n] triggered [n] failed [n] skipped [n] outcome [completed|failed] duration [n] ms
```

### Environment variable

| Environment variable | Default | Description |
| --- | --- | --- |
| `ALERT_EVALUATION_INTERVAL_SECONDS` | `60` | Seconds between evaluation cycles. Valid range 1–4294967; any other value, or unset, falls back to 60 with the Warning `Invalid ALERT_EVALUATION_INTERVAL_SECONDS [<value>], using 60`. Declared in `compose.yaml`, `compose.dev.yaml` and `helm/easytrade/values.yaml`. |

The flag's own variable, `ENABLE_PORTFOLIO_INSIGHTS`, belongs to feature-flag-service; see
[its README](../feature-flag-service/README.md).

### Metrics

Meter `EasyTrade.BrokerService`, created through `IMeterFactory`
(`System.Diagnostics.Metrics`, no extra package):

| Name | Instrument | Unit | Tags | Recorded |
| --- | --- | --- | --- | --- |
| `easytrade.broker.portfolio.calculation.duration` | `Histogram<double>` | `s` | none | Each successful insights calculation |
| `easytrade.broker.alerts.evaluation.duration` | `Histogram<double>` | `s` | `cycle.outcome` | Each cycle that passed its flag check and completed or failed; not on cancellation |
| `easytrade.broker.alerts.triggered` | `Counter<long>` | `{alert}` | `alert.type` | Each successful trigger |
| `easytrade.broker.alerts.evaluation.failed` | `Counter<long>` | `{alert}` | `alert.type` | Each per-alert failure |

The insights and alert log events carry `accountId` and `alertId` as named fields, and the
insights line ends with `trace [<id>]`. Request-path calls carry the request's trace context
through the existing HTTP and gRPC clients; evaluator calls carry none.

### Database

Alerts are stored in the new `Alerts` table through db-adapter's `AlertService` (see
[`ADAPTER_SERVICES.md`](../proto/ADAPTER_SERVICES.md)). Init scripts do not add the table to
an existing database.

Database recreate note: see [Portfolio insights (demo feature)](../../README.md#portfolio-insights-demo-feature).
Script layout and the per-dialect recreate procedure: [`src/db/README.md`](../db/README.md).

### Limits

Both targets are measured by
[`scripts/portfolio-insights/perf.sh`](../../scripts/portfolio-insights/perf.sh) on both
database dialects, with loadgen stopped:

| Limit | Target | Measured, MSSQL | Measured, PostgreSQL |
| --- | --- | --- | --- |
| Insights p95, account with 15 holdings | Under 500 ms | 33.506 ms, PASS; server side median 14 ms, p95 17 ms | 25.551 ms, PASS; server side median 6 ms, p95 17 ms |
| One evaluation cycle, 1,000 armed alerts | Under 10 s | 47 ms, PASS; next two cycles 56 ms, 49 ms | 47 ms, PASS; next two cycles 46 ms, 50 ms |

The targets assume the shipped topology: `background-service` stays a singleton, and
`feature-flag-service` runs as one instance.

Measured on 2026-11-26 by `perf.sh`, 14 checks passed per dialect, on a Compose dev project
of `compose.dev.yaml` with the whole stack on one Docker host, loadgen stopped, the flag on
and `ALERT_EVALUATION_INTERVAL_SECONDS` at 60. No cycle sample was rejected.

- Insights: the first of the 25 `PRESET` accounts
  (`GET /user-service/api/accounts/presets?limit=25`) with exactly 15 positive holdings.
  After 10 warm-ups, 200 sequential `GET /broker-service/v1/portfolio/insights/{accountId}`
  go through the reverse proxy, each timed by `curl -w '%{time_total}'`; the p95 is the 190th
  sorted time. The server side is the `duration [n] ms` of the broker's insights log line
  for the same 200 requests.
- Cycle: 40 alerts on each of the 25 `PRESET` accounts, 20 `TARGET_PRICE` and 20
  `PROFIT_LOSS`, all `ABOVE 9999999999.99999999`, so 1,000 are armed at revision 1. Before
  any sample is read, a database query of the armed set confirms it equals the 1,000 owned
  ids, all at revision 1. The sample is the first cycle line after that check that renders
  `alerts [1000]`; a line with another count is a cycle that began during setup and is
  skipped. The sample must read
  `alerts [1000] triggered [0] failed [0] skipped [0] outcome [completed]`, and the
  armed-set query, repeated after that line, must still return exactly the owned set. A
  sample with a trigger, skip, failure, another outcome or a changed set is rejected: the
  owned alerts missing from the armed set are re-armed, the set is verified again and the
  next cycle is read. Three rejected samples fail the check as `no clean sample`. The value
  is the accepted sample's `duration [n] ms`. The next two clean cycles are then recorded as
  a check of their own, `cycle follow-ups`. Each must pass the sample's line and owned-set
  checks, but not the 10 s limit; an unclean one is rejected as a sample is and does not
  count. The check fails after three unclean follow-ups or when a cycle line does not arrive
  in time.

To re-measure, run this from the repository root against the running Compose dev stack, one
dialect and one project at a time, never alongside `e2e.sh` or `loadgen-check.sh`:

```bash
bash scripts/portfolio-insights/perf.sh --project <name> --base-url <url> --compose-file compose.dev.yaml
```

The script enables the flag and stops loadgen itself, and restores both on exit. It prints
one PASS or FAIL line per check and a `REPORT` block with both values, the database type and
the host, and exits 0 only when every check passes.

**If a limit is missed:**

1. Audit the measured path against the design. A cycle makes one latest-prices call, and one
   positions load (holdings and trades) per account with `PROFIT_LOSS` alerts, at most 8 at a
   time. An insights request checks the balance and loads holdings, then loads instrument
   names, trades and latest prices together, the prices in one pricing-service call. Unit
   tests in `AlertEvaluationTests` and `PortfolioInsightsTests` pin these counts; run them
   from `src/broker-service`:

   ```bash
   dotnet test BrokerService.sln --filter "FullyQualifiedName~RunCycle_ManyProfitLossAccounts_ShouldLoadEachOnceAtMostEightAtATime|FullyQualifiedName~GetInsights_Scenario_ShouldMatchContract|FullyQualifiedName~GetHoldingPositions_SuppliedPrices_ShouldReadOnlyHoldingsAndTradesOnce"
   ```

   On the stack, pricing-service logs each request as `Request finished` with
   `GET /v1/prices/latest`. With the flag on, alerts armed and no other traffic, expect one
   per evaluation cycle and one a minute from the existing long-trade scheduler, so two a
   minute at the 60 s interval. Read them with
   `docker compose -p <project> logs --since <T> pricing-service`, where `<T>` is a UTC time
   such as `2026-11-26T00:40:00Z`.
2. A deviation is a defect. Fix it, then re-measure with the same verified workload by
   rerunning `perf.sh` unchanged: it re-runs the input checks (25 presets with 15 positive
   holdings and listed instruments, no armed alert) and the owned-set check before measuring,
   and repeats the owned-set check after each cycle sample and follow-up cycle.
3. The concurrency bound of 8 is not changed, and no caching or schema work is added.
4. If the limit is still missed, record the measured value from the `REPORT` block, its
   database type and its cause in this section, and in the run report, as a known limit.

## Problem patterns

### Db not responding

When enabled, no new records will be added to Trade table, as they will fail. Problem pattern can be enabled using the api provided with the feature flag service.

### High CPU usage

When enabled every request will be delayed by **HIGH_CPU_USAGE_REQUEST_DELAY_MS** or default value if env var not set. During this time Collatz conjecture will be calculated for random numbers on to add a significant load to cpu. It will be run on **HIGH_CPU_USAGE_CONCURRENCY** tasks.

### Credit card validation

When enabled, the `cardNumber` field from deposit and withdraw request bodies is validated against the mainframe before the operation is processed. If the mainframe deems the card invalid, the request is rejected with a `400` response.

If the mainframe is unreachable, returns an error, or `MAINFRAME_SERVICE_ADDRESS` is not configured, the middleware fails open and the request proceeds normally. This means `MAINFRAME_SERVICE_ADDRESS` is only required when the flag is enabled.

The problem patterns are toggled through the feature flag service. The responses from the service are cached for **FEATURE_FLAG_CACHE_DURATION_S** or the default value if the env var is not set.

| Environment variable | Description |
| -------------------- | ----------- |
| `MAINFRAME_SERVICE_ADDRESS` | Base URL of the mainframe service (e.g. `https://<mainframe-host>:<port>`). Only required when the flag is enabled. |
