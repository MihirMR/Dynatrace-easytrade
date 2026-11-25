# Easytrade load generator

## About

Load generator for the EasyTrade app based on the implementation using Puppeteer.

## Visits:

| Name                                                | Description                                                                                                                                                                                                |
| --------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| depositAndBuy                                       | Deposit generated value and buys random instrument                                                                                                                                                         |
| depositAndLongBuy                                   | Deposit generated value and long buys random instrument with a generated duration                                                                                                                          |
| longSell                                            | Long sells held instrument with a generated duration                                                                                                                                                       |
| orderCreditCard                                     | Orders card for the user                                                                                                                                                                                   |
| sellAndWithdraw                                     | Sells and withdraw generated amount of assets                                                                                                                                                              |
| portfolioInsightsAlert (`portfolio_insights_alert`) | Opt-in (weight 0 by default); skips while flag `portfolio-insights-enabled` is off or unreadable, otherwise logs in, opens Portfolio Insights, creates one target-price alert and deletes it by its own id |

At visit start `portfolioInsightsAlert` reads `GET <EASYTRADE_URL>/feature-flag-service/v1/flags/portfolio-insights-enabled` with a 2 s deadline. Anything other than a 200 whose body is this flag with `enabled: true` counts as off, and the visit logs `Flag [portfolio-insights-enabled] is off, skipping portfolio insights visit` before opening any page.
Otherwise the alert it creates carries a marker threshold, `1000000.` followed by 8 random digits, and the visit logs `Created alert [<id>] threshold [<marker>]`.
It deletes only that id: through the UI (`Deleted alert [<id>] via ui`) or, as a fallback, through `DELETE /broker-service/v1/alerts/{id}` with a 5 s deadline (`Deleted alert [<id>] via api`, `Alert [<id>] already absent`, or `Alert [<id>] left in place: <status>`, where `<status>` is the HTTP status, `timeout` or `error`).
When the create cannot be confirmed it logs `Create unconfirmed threshold [<marker>], outcome unknown` and deletes nothing; when the instrument options never load it logs `Alert instrument options did not load, no alert created`.
It never touches another alert, so concurrent visits sharing a preset user are safe.

Endpoints, the database recreate note and the demo walkthrough: see [Portfolio insights (demo feature)](../../README.md#portfolio-insights-demo-feature).

## Environment variables

This is an overview and may be out of date, check [`src/config/getConfig.ts`](src/config/getConfig.ts) for the current setup of env vars

- **EASYTRADE_URL**
  - > REQUIRED
  - the url to easytrade frontend, this must be a valid url (it must contain the protocol)
- **CONCURRENCY**
  - _default:_ 5
  - the number of visits running at the same time
- **BROWSERS**
  - _default:_ 1
  - the number of browsers running at the same time, this doesn't affect the **CONCURRENCY** and should generally be left at 1
- **BROWSER_TTL_MINUTES**
  - _default:_ 60
  - the time to live for browsers, since they tend to cause memory leaks when running for long periods of time restating the browsers is necessary, the time is given in minutes for convenience (to not have to do it in millis)
- **LOG_LEVEL**
  - _default:_ info
  - the log level used in the application
- **RARE_VISITS_INTERVAL_MINUTES**
  - _default:_ 60
  - how often should rare visits be run
- **HEADLESS_MODE**
  - _default:_ headless
  - one of `headless` | `headfull`
- visit data config
  - **DEPOSIT_MIN_VALUE** | **DEPOSIT_MAX_VALUE**
    - _default:_ 500 | 1500
    - when depositing money the amount will be randomly chosen from this range
  - **TRANSACTION_MIN_DURATION** | **TRANSACTION_MAX_DURATION**
    - _default:_ 1 | 24
    - when scheduling transactions the duration will be randomly chosen from this range
  - **WITHDRAW_MIN_VALUE**
    - _default:_ 500
    - the minimum amount of money that will be withdrawn
- load shape config
  - **LOAD_TYPE**
    - _default:_ NYSE
    - one of `constant` | `NYSE`
  - **NYSE_OFF_HOURS_LOAD_FACTOR**:
    - _default:_ 0.7
    - what fraction of load should be generated outside of 14:30-21:00 UTC
  - **RATE_LIMIT_TIMEFRAME_MINUTES**
    - _default:_ 5
    - the timeframe in minutes for which the generated visits are counted, too long time may cause long pauses between visits when the limit of vists in a timeframe has been reached, too short time may lead to visits lasting longer than the timeframe effectively ignoring the limit
  - **RATE_LIMIT_LEARN_TIME_FACTOR**
    - _default:_ 2
    - how many initial timeframes will the loadgen work at it's full capacity and count how many visits it can produce, after that time it will apply the defined limits (e.g. with timeframe set to 5 minuts and lear time factor set to 2 that will take 10 minutes)
- visit weights
  - the weights determine how often each visit will be run in each cycle, this is not random and each visit will be run the same amount of times each cycle, the cycle length depends on the weights and number of visits, if the weights are the same the cycle will run each visit once and repeat
  - **DEPOSIT_AND_BUY_SUCCESS_WEIGHT**
    - _default:_ 1
  - **DEPOSIT_AND_LONG_BUY_ERROR_WEIGHT**
    - _default:_ 1
  - **DEPOSIT_AND_LONG_BUY_SUCCESS_WEIGHT**
    - _default:_ 1
  - **DEPOSIT_AND_LONG_BUY_TIMEOUT_WEIGHT**
    - _default:_ 1
  - **LONG_SELL_ERROR_WEIGHT**
    - _default:_ 1
  - **LONG_SELL_SUCCESS_WEIGHT**
    - _default:_ 1
  - **LONG_SELL_TIMEOUT_WEIGHT**
    - _default:_ 1
  - **SELL_AND_WITHDRAW_SUCCESS_WEIGHT**
    - _default:_ 1
  - **PORTFOLIO_INSIGHTS_ALERT_WEIGHT**
    - _default:_ 0
    - opt-in weight of the `portfolio_insights_alert` visit: a weight of 0 or less drops the visit from the weighted provider, so the default workload is unchanged
    - set it above 0 only together with the `portfolio-insights-enabled` flag on, otherwise every run of the visit only logs its skip line
    - a value that is not a finite number, or a positive value so large relative to the other weights that the weighted provider could not schedule it, is rejected at startup

To run the visit in a demo, start the stack with the flag on and the visit weighted, with no file edit (from the repository root):

```bash
# Compose: set both values for this start, or put the same two lines in .env, which Compose interpolates
ENABLE_PORTFOLIO_INSIGHTS=true PORTFOLIO_INSIGHTS_ALERT_WEIGHT=1 make start

# Helm
helm upgrade --install easytrade helm/easytrade --namespace easytrade --create-namespace \
--set feature-flag-service.env.ENABLE_PORTFOLIO_INSIGHTS="true" \
--set loadgen.env.PORTFOLIO_INSIGHTS_ALERT_WEIGHT="1"
```

On a running stack the flag can also be switched with `PUT /feature-flag-service/v1/flags/portfolio-insights-enabled` and `{"enabled": true}`; the visit reads it again at every visit start.

`PORTFOLIO_INSIGHTS_ALERT_WEIGHT` is declared in `compose.yaml` and `compose.dev.yaml` as `${PORTFOLIO_INSIGHTS_ALERT_WEIGHT:-0}`, and in `helm/easytrade/values.yaml` under `loadgen.env` as `"0"`.

## Local usage

```bash
make build services=loadgen      # build the image from local source
make redeploy services=loadgen   # rebuild and recreate it in the running stack
```

Run `make help` for every target.

In `src/loadgen`, `npm ci && npm test` runs the `node:test` unit suites: `tsc` builds into `build/`, then `node --test "build/**/*.test.js"` runs every compiled test file.

[`verification/portfolio-insights-page-check.mjs`](verification/portfolio-insights-page-check.mjs) is the browser check of the Portfolio Insights page; [`scripts/portfolio-insights/e2e.sh`](../../scripts/portfolio-insights/e2e.sh) runs it. It sits outside `src/`, so neither the build nor the image includes it.

## Health endpoints

- `GET /livez`
  - returns `200 OK` with body `OK`
- `GET /readyz`
  - returns `503 Service Unavailable` until startup is complete
  - returns `200 OK` with body `OK` after startup

The health server listens on port `8080`.

## Technology

- Puppeteer
- Typescript
