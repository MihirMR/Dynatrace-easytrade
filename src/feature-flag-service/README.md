# easyTradeFeatureFlagService

A Go REST service that allows to get and update feature flag data.

Exposes `/version`, `/livez` (liveness) and `/readyz` (readiness) on port `8080`.
See [`feature-flag-service.http`](feature-flag-service.http) for the flag API requests.

## Technologies used

- Golang
- Docker

## Local build instructions

```bash
make build services=feature-flag-service      # build the image from local source
make redeploy services=feature-flag-service   # rebuild and recreate it in the running stack
```

Run `make help` for every target.

## Feature flags

---

Every flag can also be given a startup default via an environment variable. `ENABLE_MODIFY`
(default `true`) controls whether flags may be changed at all through the API.

| Flag id | Env variable | Default | Description |
| --------------------------------- | ------------ | ------- | ----------- |
| `frontend_feature_flag_management` | `ENABLE_FRONTEND_MODIFY` | `true` | When enabled, allows controlling problem pattern feature flags from the main app UI. |
| `db_not_responding` | `ENABLE_DB_NOT_RESPONDING` | `false` | When enabled, the DB not responding will be simulated, causing errors when trying to create any new transactions. |
| `ergo_aggregator_slowdown` | `ENABLE_ERGO_AGGREGATOR_SLOWDOWN` | `false` | When enabled, the Offer Service will respond with a delay to 2 out of the 5 aggregator platforms simulated by `background-service`, causing them to pause queries for 1 hour. |
| `factory_crisis` | `ENABLE_FACTORY_CRISIS` | `false` | When enabled, the factory won't produce new cards, so `background-service` stops processing credit card orders. |
| `credit_card_meltdown` | `ENABLE_CREDIT_CARD_MELTDOWN` | `false` | When enabled, checking the latest credit card order status results in a division by zero error. |
| `credit_card_memory_leak` | `ENABLE_CREDIT_CARD_MEMORY_LEAK` | `false` | When enabled, credit-card-order-service leaks heap until Kubernetes OOM-kills its container, then repeats after each restart. |
| `high_cpu_usage` | `ENABLE_HIGH_CPU_USAGE` | `false` | Causes a slowdown of broker-service response time and increases CPU usage. If deployed on K8s, a CPU resource limit is also applied. |
| `credit_card_validation` | `ENABLE_CREDIT_CARD_VALIDATION` | `false` | When enabled, credit card numbers are validated via the mainframe before deposit/withdraw operations in broker-service are processed. Requires `MAINFRAME_SERVICE_ADDRESS` to be configured in broker-service. |
| `portfolio-insights-enabled` | `ENABLE_PORTFOLIO_INSIGHTS` | `false` | When enabled, shows the simulated Portfolio Insights page, its alerts and notifications, and enables alert evaluation in broker-service. Demo feature, not financial advice. Tag `feature`, not `problem_pattern`, so the `/feature-flags` page (which lists `?tag=problem_pattern`) does not show it. Toggle it with `PUT /v1/flags/portfolio-insights-enabled`. |

### Portfolio insights flag

- **Id**: `portfolio-insights-enabled` is hyphenated by design, unlike the snake_case ids of
  the other flags. It is used exactly as written in the API path and by every consumer:
  broker-service reads it fresh on every decision, and the frontend and loadgen read it with
  a 2 s deadline. An unreachable flag service or a non-200 answer counts as disabled. While
  it is off, every feature endpoint in broker-service answers `403` with
  `{"error":"feature_disabled"}`.
- **Startup default**: `ENABLE_PORTFOLIO_INSIGHTS` sets it. An unset or unparsable value
  means `false`.
- **Restart**: flag state is held in memory only, so a restart restores the configured
  startup default: `false` as shipped, or `true` where `ENABLE_PORTFOLIO_INSIGHTS=true` is
  set. A runtime `PUT` does not survive a restart.
- **Modifiable**: the flag can be changed while `ENABLE_MODIFY` is `true`, the default. With
  `ENABLE_MODIFY=false` it is locked like the problem-pattern flags: a `PUT` returns `400`
  with the message `Can't update a non-modifiable flag [Portfolio insights]`, and only
  `ENABLE_PORTFOLIO_INSIGHTS` at startup decides its state.
- **Declared in**: `compose.yaml` and `compose.dev.yaml`
  (`ENABLE_PORTFOLIO_INSIGHTS: ${ENABLE_PORTFOLIO_INSIGHTS:-false}`), and
  `helm/easytrade/values.yaml` (`feature-flag-service.env.ENABLE_PORTFOLIO_INSIGHTS: "false"`).
- **Requests**: see [`feature-flag-service.http`](feature-flag-service.http) for get, enable,
  disable and `?tag=feature`.

Feature endpoints, the database recreate note and the demo walkthrough: see [Portfolio insights (demo feature)](../../README.md#portfolio-insights-demo-feature). Endpoint reference: [broker-service README](../broker-service/README.md#portfolio-insights-and-alerts).
