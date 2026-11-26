# Helm charts

## Description
Helm charts used to deploy *easytrade* on Kubernetes cluster using Helm 3+.

## Charts
List of helm charts:
- `easytrade` - Umbrella Helm chart to deploy multiple instances of `app` chart with different configuration.
- `easytrade/charts/app` - Helm chart for single microservice

## Installation

### Prerequisites
- Kubernetes 1.19+
- Helm 3.0+

### Install the chart

```bash
helm install $RELEASE_NAME oci://europe-docker.pkg.dev/dynatrace-demoability/helm/easytrade --version $CHART_VERSION
```

## Configuration

### Global Values

The following table lists the configurable global parameters and their default values.

| Parameter | Description | Default |
|-----------|-------------|---------|
| `global.image.baseRepository` | Base Docker registry URL for all services | `"europe-docker.pkg.dev/dynatrace-demoability/docker/easytrade"` |
| `global.image.tag` | Default image tag for all services | `latest` |
| `global.labels` | Additional labels to add to all resources | `{}` |
| `global.env` | Environment variables to add to all pods | `{}` |
| `global.dynatrace.version` | Dynatrace version identifier | `1.1.1` |
| `global.database.type` | Database backend: `mssql` or `postgres` | `mssql` |
| `global.database.name` | Database name | `TradeManagement` |
| `global.database.password` | Password used when no existing secret is given | `"yourStrong(!)Password"` |
| `global.database.existingSecret.name` | Read the DB password from this secret instead | `""` |
| `global.database.existingSecret.key` | Key within that secret | `password` |

> **NOTE:** `global.database.type` selects which connection string is rendered into the
> `<release>-connection-strings` secret. It does **not** enable the matching database
> workload - keep it in sync with `db-mssql.enabled` / `db-postgres.enabled` yourself.
> Any value other than `mssql` or `postgres` fails the render.

### Service Configuration

Each service can be configured individually. All services share the same configuration structure:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `<service>.enabled` | Enable/disable the service | `true` |
| `<service>.image.repository` | Override the image repository for this service | Uses `global.image.baseRepository/<service>` |
| `<service>.image.tag` | Override the image tag for this service | Uses `global.image.tag` |
| `<service>.replicaCount` | Number of replicas | `1` |
| `<service>.workloadType` | Workload type: `deployment` or `statefulset` | `deployment` |
| `<service>.env` | Environment variables (key-value pairs) | `{}` |
| `<service>.envFromSecret` | Environment variables from secrets | `{}` |
| `<service>.resources.requests` | Resource requests (CPU, memory) | Service-specific |
| `<service>.resources.limits` | Resource limits (CPU, memory) | Service-specific |
| `<service>.service.enabled` | Create Kubernetes Service | `false` |
| `<service>.service.port` | Service port | `80` |
| `<service>.service.ports` | Multiple ports configuration | `[]` |
| `<service>.service.annotations` | Service annotations | `{}` |
| `<service>.rbac.create` | Create RBAC resources | `false` |
| `<service>.rbac.rules` | RBAC rules for Role | `[]` |
| `<service>.persistence.enabled` | Enable persistence (for StatefulSet) | `false` |
| `<service>.persistence.size` | Persistent volume size | `10Gi` |
| `<service>.persistence.mountPath` | Mount path for persistent volume | `""` |

### Available Services

The easytrade chart includes the following microservices:

- `background-service` - Consolidated data aggregation, content/pricing generation, credit-card manufacture/courier simulation, and (Kubernetes-only) problem-pattern operator
- `broker-service` - Trading broker service
- `credit-card-order-service` - Credit card order processing
- `db-mssql` - Microsoft SQL Server database (StatefulSet, enabled by default)
- `db-postgres` - PostgreSQL database (StatefulSet, disabled by default)
- `db-adapter` - gRPC service exposing the database behind a stable interface (pluggable backend: MSSQL/Postgres)
- `feature-flag-service` - Feature flag management
- `frontend` - React frontend application
- `loadgen` - Load generator
- `offer-service` - Offer management
- `pricing-service` - Pricing calculation
- `reverse-proxy` - Nginx reverse proxy
- `user-service` - Account and authentication service

The chart also deploys the simulated **Portfolio Insights and Alerts** demo feature: portfolio
figures, a concentration-risk badge, and target-price or profit/loss alerts with in-app
notifications. It uses simulated data and is **not financial advice**. It is gated end to end
by the feature flag `portfolio-insights-enabled`, which is off by default, so the shipped
values keep the feature off and the loadgen workload unchanged. Enable it at install time with
`--set feature-flag-service.env.ENABLE_PORTFOLIO_INSIGHTS="true"`, and optionally drive it from
loadgen with `--set loadgen.env.PORTFOLIO_INSIGHTS_ALERT_WEIGHT="1"`:

```bash
helm upgrade --install easytrade ./helm/easytrade -n easytrade --create-namespace \
  --set feature-flag-service.env.ENABLE_PORTFOLIO_INSIGHTS="true" \
  --set loadgen.env.PORTFOLIO_INSIGHTS_ALERT_WEIGHT="1"
```

The endpoints, runtime toggling and the demo walkthrough are in [Portfolio insights (demo feature)](../../README.md#portfolio-insights-demo-feature).

### Example Configurations

#### Minimal installation with specific services

```yaml
global:
  image:
    tag: "v1.0.0"

# Enable only core services
user-service:
  enabled: true
broker-service:
  enabled: true
db-mssql:
  enabled: true
frontend:
  enabled: true
reverse-proxy:
  enabled: true

# Disable all other services
background-service:
  enabled: false
loadgen:
  enabled: false
# ... etc
```

#### Custom environment variables

```yaml
global:
  env:
    DT_RELEASE_STAGE: production
    DT_RELEASE_VERSION: "1.2.3"
  labels:
    environment: prod
    team: platform

broker-service:
  enabled: true
  env:
    CUSTOM_CONFIG: "value"
    LOG_LEVEL: "debug"
```

**Portfolio Insights variables.** `values.yaml` declares three variables for the Portfolio
Insights demo feature. Their defaults keep the feature off and the loadgen workload unchanged.

| Variable | Service (values key) | Default | Purpose |
|----------|----------------------|---------|---------|
| `ENABLE_PORTFOLIO_INSIGHTS` | `feature-flag-service.env` | `"false"` | Startup default of the `portfolio-insights-enabled` flag. A restart restores this value. It can be toggled at runtime with `PUT /v1/flags/portfolio-insights-enabled` unless `ENABLE_MODIFY` is `false` |
| `ALERT_EVALUATION_INTERVAL_SECONDS` | `broker-service.env` | `"60"` | Seconds between alert evaluation cycles. Valid range 1–4294967; any other value falls back to 60 with a warning |
| `PORTFOLIO_INSIGHTS_ALERT_WEIGHT` | `loadgen.env` | `"0"` | Weight of the `portfolio_insights_alert` visit. `0` keeps it off (opt-in), so the existing workload is unchanged |

The values-file equivalent of the `--set` demo values in [Available Services](#available-services):

```yaml
feature-flag-service:
  env:
    ENABLE_PORTFOLIO_INSIGHTS: "true"
loadgen:
  env:
    PORTFOLIO_INSIGHTS_ALERT_WEIGHT: "1"
```

Write these values as quoted strings, as `values.yaml` does; the chart renders every `env`
entry into the pod as a quoted string.

#### Database with persistence

```yaml
db-mssql:
  enabled: true
  workloadType: statefulset
  persistence:
    enabled: true
    size: 50Gi
    mountPath: /var/opt/mssql
  resources:
    requests:
      cpu: 500m
      memory: 2Gi
    limits:
      cpu: "2"
      memory: 4Gi
```

**Getting the Portfolio Insights `Alerts` table.** The table ships inside the `db-mssql` and
`db-postgres` images (`sql-alerts.sql` and `13-alerts.sql`), so a database initialised from an
image that contains the script has it. An existing database needs one of the steps below.

- **Init scripts are not enough.** They never add the `Alerts` table to an existing database.
  - PostgreSQL runs its init scripts only for an empty data directory.
  - Restarting a persistent MSSQL database is not a way to get the table either. MSSQL reruns
    its whole script list on every start without stopping on errors, and against surviving
    data that duplicates the seeded holdings. A `helm upgrade` that changes the database image
    restarts its pod too.
- **Persistence off (the default).** `persistence` is commented out for `db-mssql` and
  `db-postgres` in `values.yaml`, so a new database pod starts empty and initialises the full
  schema, `Alerts` included, from the new image.
- **Persistence on** (`persistence.enabled: true` with a `mountPath`, as in the example above).
  `helm uninstall` leaves the StatefulSet's PersistentVolumeClaim in place, so a reinstall
  reuses the old data. A fresh database needs that PVC deleted explicitly, and deleting it
  **destroys the data**. The chart's volume claim template is named `data` and the StatefulSet
  is `<release>-db-mssql` or `<release>-db-postgres`, so the PVC is `data-<release>-db-mssql-0`
  or `data-<release>-db-postgres-0` (for example `data-easytrade-db-mssql-0`):

  ```bash
  helm uninstall <release> -n <namespace>
  kubectl get pvc -n <namespace>          # confirm the name
  kubectl delete pvc data-<release>-db-mssql-0 -n <namespace>
  helm upgrade --install <release> ./helm/easytrade -n <namespace> -f custom-values.yaml
  ```

- **Keeping existing data.** Back up the database first, then apply the dialect's script once,
  by hand, inside the running database pod. Both scripts are guarded
  (`IF OBJECT_ID(...) IS NULL` / `CREATE TABLE IF NOT EXISTS`), so a repeat is harmless.
  - MSSQL: the image keeps its scripts in `/my-app`, and `SA_PASSWORD` is the pod's
    secret-backed environment variable:

    ```bash
    kubectl exec -n <namespace> <release>-db-mssql-0 -- bash -c \
      '/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -b -I -i /my-app/sql-alerts.sql'
    ```

  - PostgreSQL: the image keeps its scripts in `/docker-entrypoint-initdb.d`:

    ```bash
    kubectl exec -n <namespace> <release>-db-postgres-0 -- \
      psql -v ON_ERROR_STOP=1 -U postgres -d TradeManagement -f /docker-entrypoint-initdb.d/13-alerts.sql
    ```

  - A pod still running an older image has no such file. Copy the script in from a checkout
    first, for example
    `kubectl cp src/db/mssql/sql-scripts/sql-alerts.sql <namespace>/<release>-db-mssql-0:/tmp/sql-alerts.sql`,
    and pass `/tmp/sql-alerts.sql` instead.

The per-dialect script layout is in [`src/db/README.md`](../../src/db/README.md), and the
general procedure in the root README's [Database](../../README.md#database) section.

#### Service with RBAC

```yaml
background-service:
  enabled: true
  rbac:
    create: true
    rules:
      - apiGroups: [""]
        resources: ["services", "pods", "events"]
        verbs: ["get", "list", "watch", "create", "delete", "patch", "update"]
      - apiGroups: ["apps"]
        resources: ["deployments", "replicasets"]
        verbs: ["get", "list", "watch", "create", "delete", "patch", "update"]
```

#### Multiple ports configuration

```yaml
<service>:
  enabled: true
  service:
    enabled: true
    ports:
      - port: 8080
        targetPort: 8080
        protocol: TCP
        name: http
      - port: 9090
        targetPort: 9090
        protocol: TCP
        name: metrics
```

## Upgrading

```bash
helm upgrade easytrade ./helm/easytrade -n easytrade -f custom-values.yaml
```

## Uninstalling

```bash
helm uninstall easytrade -n easytrade
```

## Development

The root `Makefile` wraps install and uninstall:

```bash
make k8s-install          # upgrade --install from this local chart
make k8s-install-remote   # upgrade --install from the published OCI chart
make k8s-uninstall
```

Release name, namespace and chart path are overridable:
`make k8s-install HELM_RELEASE=easytrade-test HELM_NAMESPACE=easytrade-test`.

> **NOTE:** These targets do **not** resolve subchart dependencies for you. Run
> `helm dependency update helm/easytrade` yourself after changing `Chart.yaml`.

### Update dependencies

Required before linting, templating or installing — the umbrella chart declares 13
`file://./charts/app` dependencies that must be packaged into `charts/` first.

```bash
helm dependency update helm/easytrade
```

This writes `Chart.lock` and `charts/app-0.1.0.tgz`; both are build artifacts and
are gitignored.

### Lint the chart

```bash
helm lint helm/easytrade
```

### Template rendering

```bash
# Render templates to verify output (values.yaml is the chart's default values file)
helm template easytrade helm/easytrade

# The same render on PostgreSQL instead of MSSQL
helm template easytrade helm/easytrade --set global.database.type=postgres --set db-mssql.enabled=false --set db-postgres.enabled=true

# Debug mode
helm install easytrade ./helm/easytrade --dry-run --debug
```

[Verifying a stack](../../README.md#verifying-a-stack) in the root README checks the three
Portfolio Insights variables in the rendered Deployments on both dialects, and installs each
dialect into its own disposable namespace.

## References
- https://helm.sh/docs/howto/charts_tips_and_tricks/#complex-charts-with-many-dependencies
- [Helm Documentation](https://helm.sh/docs/)
- [Kubernetes Documentation](https://kubernetes.io/docs/home/)
