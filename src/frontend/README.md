# EasyTrade Frontend

The EasyTrade web UI: a React single-page app built with Vite and served by nginx in the
container image. It talks to the backend through the reverse proxy, so every request goes to
the same origin the page was loaded from.

## Technologies

- React 18 + TypeScript (strict)
- Vite
- React Router 7 (data router: route loaders + `lazy` components)
- TanStack Query v5 (server-state cache)
- Plain CSS
- lightweight-charts (price charts)
- Docker (nginx runtime image)
- Vitest + Testing Library

## Local development

```bash
npm install
npm run dev        # dev server on :3000
npm run build      # production build to dist/
npm run build-test # tsc && vitest --run
npm run lint       # eslint
npm test        # Vitest
npm run format     # prettier
```

The dev server only serves the frontend. For anything that talks to a backend run the full stack from the repo root:

```bash
make start
```

Run `make help` for every target.
The app is then at `http://localhost`

```bash
make build services=frontend      # build the image from local source
make redeploy services=frontend   # rebuild and recreate it in the running stack
```

## Features

- dark UI theme
- Buy and sell instruments at the current price, or place a long buy/sell
  disposition at a chosen price and duration
- Portfolio value chart and transaction history
- Credit card ordering, status tracking and revocation
- Problem-pattern feature flags (`/feature-flags`) and service versions
  (`/version`)
- **Portfolio Insights (simulated demo, not financial advice)** at `/insights`:
  portfolio totals, unrealized P/L, allocations, largest position and a risk
  badge, plus price and profit/loss alerts with in-app notifications
  - Gated by the feature flag `portfolio-insights-enabled` (tag `feature`,
    default off). The "Portfolio Insights" sidebar link
    (`#nav-portfolio-insights`) and the page appear only while the flag reads
    `true`. The flag is not listed on `/feature-flags`, which shows only
    `problem_pattern` flags; toggle it through the flag service API (see the
    link below).
  - The flag is revalidated every 15 s while the tab is visible (no polling
    while it is hidden), and immediately on window focus and on reconnect;
    each read has a 2 s deadline. An unreachable flag service or any invalid
    answer counts as off.
  - When the flag turns off (a `false` read, or a
    `403 {"error":"feature_disabled"}` from any insights or alert request), the
    frontend shuts the feature down: the link disappears, cached insights and
    alert data are removed, in-flight requests are cancelled and late results
    discarded, and an open `/insights` page leaves for `/home`. A direct visit
    to `/insights` while the flag is off redirects to `/home`. When the flag
    turns on again, the data is loaded afresh.
  - Triggered alerts raise one Toast per alert arming per browser tab. The
    deduplication key `${accountId}:${id}:${armingRevision}` is kept in
    `sessionStorage` under `portfolio-insights.notified`, so a reload does not
    repeat a Toast, an independently opened tab shows it once more, and a
    re-armed alert that triggers again toasts again. The server's
    `acknowledged` flag is the state of record, shown in the notifications
    list; "Acknowledge" removes the item.
  - Endpoints, the startup variable `ENABLE_PORTFOLIO_INSIGHTS`, the
    database-recreate note and a demo walkthrough: see
    [Portfolio insights (demo feature)](../../README.md#portfolio-insights-demo-feature).

---

## ⚠ The loadgen contract

`src/loadgen/src/selectors.ts` drives the synthetic traffic generator with
**XPath selectors bound to specific DOM ids and element tags**, for example:

```
//h5[@id="instrumentPrice"]      //p[@id="order-id"]
//button[@id="submitButton"]     //input[@id="amount"]
```

It also matches the `instrument-card` and `owned-instrument` **class names**.

Changing or removing one of those ids, changing the element's tag, or renaming
those classes **breaks load generation**, and nothing in this project's tests
will catch it. Check `selectors.ts` before touching markup, and keep ids unique.

### Portfolio Insights ids and classes

The `portfolio_insights_alert` visit binds further selectors in
`src/loadgen/src/selectors.ts`, and the browser check
`src/loadgen/verification/portfolio-insights-page-check.mjs` reads the page by
the ids and classes below. Changing or removing one of them, changing an
element's tag, or renaming one of the classes **breaks load generation or the
browser check**. Check both files before touching this markup.

Bound by `selectors.ts`, so the element tag matters:

- `a#nav-portfolio-insights`: the sidebar `NavLink`, rendered only while the
  flag is on
- `div#portfolio-insights`: the page root
- `select#alert-type`, `select#alert-instrument` and `select#alert-direction`;
  an `option[@value!=""]` of `select#alert-instrument` signals that the
  instruments have loaded
- `input#alert-threshold` (`type="text"`, `inputMode="decimal"`)
- `button#alert-submit`
- `output#alert-created-id`, rendered after each 201: `value` is the new alert
  id and `data-threshold` the submitted threshold text
- `output#alert-deleted-id`, rendered after each DELETE 204: `value` is the
  deleted id
- `li[data-alert-id="<id>"]` alert rows, and their `button.alert-delete`

Other ids, used by the tests and the browser check: `insights-total-value`,
`insights-total-invested`, `insights-unrealized-pnl`,
`insights-unrealized-pnl-percent`, `insights-largest-position`,
`insights-risk-badge`, `insights-allocations` (the allocation table),
`insights-empty-state`, `insights-loading`, `insights-error`,
`insights-disclaimer`, `alerts-panel`, `alert-form`, `alert-form-error`,
`alerts-list`, `alerts-empty` and `alert-notifications`.

Classes: `alert-item`, `alert-toggle`, `alert-disable`, `alert-delete`,
`alert-notification` (on items that also carry the `data-notification-id` the
browser check reads) and `alert-acknowledge`. The browser check also observes
the existing `.toast-container` / `.toast` elements of `ToastContext`.

The page avoids the ids `submitButton`, `amount`, `price` and `time` that
existing selectors use, and no existing id, class or `/feature-flags`
behaviour changed.

## data-dt-\* attributes

NOTE: data-dt-\* attributes (e.g. data-dt-name, data-dt-children-name, data-dt-features)
are Dynatrace RUM instrumentation tags used for tracking user interactions in analytics.
They are likely not strictly required for the application to function.
