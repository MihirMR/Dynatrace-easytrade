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

Demo walkthrough, the three variables (`ENABLE_PORTFOLIO_INSIGHTS`,
`ALERT_EVALUATION_INTERVAL_SECONDS`, `PORTFOLIO_INSIGHTS_ALERT_WEIGHT`) and the database
recreate note: see [Portfolio insights (demo feature)](../../README.md#portfolio-insights-demo-feature).
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
  `{"error":"feature_disabled"}`. The gate is a resource filter that runs before model
  binding, so even a malformed body or a missing `accountId` gets 403;
- a non-GUID path segment matches no route and returns 404, with the flag on or off;
- the alert evaluator does nothing: no db-adapter, pricing or metric activity.

A disable takes effect on the next request, and for the evaluator at the start of its next
cycle.

### Endpoint reference

Besides the errors listed, every endpoint can answer `403` (flag off) and `503` (db-adapter
failure).

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
  then the greater open. A pricing failure, or an empty price list while holdings exist,
  returns 503. A holding without a candle is valued at 0.
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
an existing database; see the recreate note in
[the root README](../../README.md#portfolio-insights-demo-feature) and
[`src/db/README.md`](../db/README.md).

### Limits

Both targets are measured by
[`scripts/portfolio-insights/perf.sh`](../../scripts/portfolio-insights/perf.sh) on both
database dialects, with loadgen stopped:

| Limit | Target | Measured (database, host) |
| --- | --- | --- |
| Insights p95, account with 15 holdings | Under 500 ms | not yet recorded; run `perf.sh` |
| One evaluation cycle, 1,000 armed alerts | Under 10 s | not yet recorded; run `perf.sh` |

A missed limit is recorded here with its measured value and cause. The targets assume the
shipped topology: `background-service` stays a singleton, and `feature-flag-service` runs as
one instance.

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
