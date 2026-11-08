# Monitoring: logs, metrics, alerts, status

Every cluster gets a small monitoring stack by default (`cluster_monitoring_enabled`, set it to `false` for none). It is built to be looked at and extended, not to
come with finished dashboards: **no dashboards are deployed**, the data sources are.

```
 every client node                                the monitoring node (cluster_monitoring_node)
┌────────────────────────────┐   Consul mesh     ┌─────────────────────────────────────────────────────────┐
│ Vector (monitoring-agent)  │──── logs ────────▶│ Loki          (logs, 45 days)                           │
│  - container logs (docker) │──── metrics ─────▶│ Prometheus    (metrics, 45 days; remote write receiver) │
│  - Tetragon events         │  intentions: only │ Alertmanager  (groups, silences, sends)  ──▶ ntfy ──▶ 📱 │
│  - scrapes this node:      │  "monitoring-     │ Grafana       (grafana.<zone>, login: authelia)         │
│    Nomad, Consul, Tetragon,│   vector" may     │ Postgres      (Grafana's database, nothing else)        │
│    tagged services         │   connect         │ Gatus         (status.<zone>)                           │
│  - (one node) cluster      │                   └─────────────────────────────────────────────────────────┘
│    events from the APIs    │                    ntfy (ntfy.<domain>, PUBLIC): the phone app / web app
└────────────────────────────┘
```

| What | Where | Reachable by |
|---|---|---|
| Grafana | `https://grafana.<zone>` (`<zone>` = `cluster_internal_zone`, `<cluster_name>.internal`) | VPN, people's devices, authelia-internal (second factor) **and** Grafana's own login (user `admin`, see "Login") |
| Status page (Gatus) | `https://status.<zone>` | VPN, people's devices, authelia-internal |
| ntfy | `https://ntfy.<cluster_domain>` | **public**; ntfy's own accounts (`deny-all` by default) |
| Loki, Prometheus | inside the monitoring allocation | only the Vector agents, through the Consul mesh |
| Alertmanager | inside the monitoring allocation (`127.0.0.1`) | Grafana (it is a data source, silences are made there), Prometheus, Loki |

Everything of the server is **one Nomad allocation** (job `monitoring-server`) on one node: the tasks talk over `127.0.0.1`, only Grafana and Gatus have a published port
(for Traefik), Loki and Prometheus have a Connect sidecar each. A change to the job (a new image tag) restarts all of its tasks once; the data is in host volumes.
Where it runs: `cluster_monitoring_node` (a client; default the server node if it is a client, else the first client). Changing it moves the stack to
another node with **empty** data (the old data stays in `cluster_monitoring_dir` of the old node).

## What is collected

**Logs** (Loki; every container, through the docker socket): the line as it is, plus the labels `host`, `job` (the Nomad job), `task`, `namespace`, `level`
(`debug|info|warn|error|unknown`, from a JSON field `level`/`severity` or the words in the line) and `source`. Few labels on purpose (every combination is a stream):
the rest you filter at query time (`{job="authelia"} | json | status >= 500`).

| `source` | Content |
|---|---|
| `docker` | the stdout / stderr of every container (except Vector's own) |
| `tetragon` | Tetragon's event log (`job="tetragon"`, `task` = `exec`, `exit`, `kprobe`; `level="warn"` for an enforcement) |
| `platform` | **what happens in the cluster**, from the Nomad and Consul APIs, one JSON line per change (`job="nomad-events"`): `task="node"` (a node joins, goes down, drains, is eligible or not), `allocation` (placed, running, failed, lost, with the task states and their restarts), `deployment` (running, successful, failed), `health` (a Consul check changes its status: passing, warning, critical). Polled every 30 s, so an event is up to 30 s late; after a restart of the agent on the monitoring node the current state is logged once more |

Application logs are not duplicated: the platform's own services (Nomad, Consul, Docker daemon) are not shipped as log files; what matters from them is in the events.

**Metrics** (Prometheus; Vector scrapes every 30 s and remote-writes, Prometheus only stores and evaluates rules). Every series has `host` (the node) and `job`:

| `job` | Source |
|---|---|
| `nomad` | `/v1/metrics` of the node: the agent, and (`nomad_publish_workload_metrics`, **on** with monitoring) the allocations and tasks: CPU, memory, disk of every container. This is the container metrics, there is no cAdvisor |
| `consul` | `/v1/agent/metrics` of the node |
| `tetragon` | the agent of the runtime security (2112) |
| `vector` | Vector itself (`vector_uptime_seconds` is the heartbeat of a node, rule `NodeDown`) |
| *service name* | every Consul service on this node with the tag `metrics` (below): Traefik (`traefik-metrics`), ntfy, your own |
| (server) | Prometheus, Alertmanager, Loki, Grafana and Gatus scrape each other (Prometheus, `127.0.0.1`); Gatus' `gatus_results_*` is the status of every check |

The series count of Tetragon is high (about 2,250 per node, 1,800 of them two health families that cannot be switched off): see `docs/reference.md`, "Runtime security", for
what to drop. In this stack they are written as they are, on purpose small (30 s interval, one node).

### Metrics endpoints of your own jobs (Consul tags)

A job that exposes Prometheus metrics registers a Consul service with the tag `metrics`; the agent on the node where it runs picks it up within a minute:

```hcl
service {
  name     = "myapp-metrics"
  port     = "metrics"          # a port of the group network, published on the host: the agent is a container, it reaches the node's address
  provider = "consul"
  tags     = ["metrics", "metrics.path=/internal/metrics"]   # path optional (default /metrics)
}
```

| Tag | Meaning |
|---|---|
| `metrics` | scrape this service |
| `metrics.path=/x` | path (default `/metrics`) |
| `metrics.scheme=https` | scheme (default `http`; the certificate is not verified) |
| `metrics.job=name` | the `job` label (default: the service name) |

The port must be a **published** one (`network { port "metrics" { to = 9100 } }`): a port that exists only inside the allocation (the Connect case) is not reachable from the agent.
The firewall lets the cluster reach published job ports and nobody else, so the metrics are not public. A project needs the Consul right to register a service
(`service_prefix "myapp" { policy = "write" }` in its `consul_rules`, `docs/projects.md`); the Nomad namespace does not matter. The status page of the service is not
a second tag: Gatus lists every service that Traefik publishes (a `traefik.http.routers.<r>.rule=Host(...)` tag) by itself.

## Retention

| | Default | Variable |
|---|---|---|
| On the nodes (docker container logs, agent logs, Tetragon's log) | 7 days | `cluster_log_retention_days` (`docs/reference.md`, "Docker, volumes, logs") |
| Loki, Prometheus | 45 days | `cluster_monitoring_retention_days` |

Loki deletes with its compactor (`retention_enabled`; without it nothing would ever be removed). Disk: count with a few GB for the logs of a small cluster; the volumes
are `cluster_monitoring_dir` (`/srv/monitoring`) on the monitoring node, `task backup` includes Grafana's database and nothing else of it.

## Alerting: how it works, and what Alertmanager needs

Four things are involved, and mixing them up is the usual confusion:

1. **Alert rules** decide *that* something is wrong. They are evaluated where the data is: Prometheus (queries on metrics, `groups:` yaml files), Loki's *ruler* (queries on
   logs), and Grafana (the *alert rules* you create in its UI). A rule has an expression, a duration (`for:`, "true for 5 minutes", against flapping), labels and annotations.
2. A firing rule sends an **alert** (labels + annotations + start time) to **Alertmanager** over HTTP, again and again while it fires.
3. **Alertmanager** decides *what happens*: it does not know what is wrong, it only handles alerts. It
   - **groups** alerts (`group_by: [alertname, host]`: ten alerts of one node become one notification; `group_wait` collects for a while before the first one),
   - **deduplicates** (the same alert from several senders, or sent every 30 s, is one),
   - **routes** by labels along a tree (`route:` with `matchers`; e.g. `severity="critical"` repeats every 2 hours, the rest every 12),
   - **inhibits** (`inhibit_rules`: while `NodeDown` fires for a host, the other alerts of that host are muted; it is the cause),
   - **silences** (a temporary mute by label matchers, made in Grafana's Alertmanager view or the API; it is stored on disk),
   - sends the notification to a **receiver** and **resolves** it (`send_resolved: true`) when the alert stops firing.
4. A **receiver** is the integration that delivers: e-mail, Slack, Matrix, PagerDuty, a webhook... Here: a webhook to ntfy.

What Alertmanager needs from you, one by one (all are in `jobs/monitoring-server.nomad.hcl`, the task `alertmanager`):

| Needs | Here |
|---|---|
| A config file: `route`, `receivers`, optional `inhibit_rules`, `time_intervals`, `templates` | rendered as a Nomad template into `/secrets/alertmanager.yml`; secrets come from the Nomad variable `nomad/jobs/monitoring-server` |
| At least one receiver with credentials | `webhook_configs` to `http://<ntfy>/alerts?template=alertmanager` with `Authorization: Bearer <token>` (a token that can only write the topic `alerts`) |
| Somewhere to keep state | a host volume (`monitoring-alertmanager`): the silences and the log of sent notifications survive a restart |
| A way to be found by the senders | `alerting:` in `prometheus.yml`, `ruler.alertmanager_url` in Loki, the data source `Alertmanager` in Grafana (with `handleGrafanaManagedAlerts`: Grafana's own alerts go to the same instance) |
| Clustering decision | one instance, `--cluster.listen-address=` empty (no HA gossip). A second instance would need the gossip port open between them and both listed in the senders |
| A readable notification | ntfy's built-in `alertmanager` template (`?template=alertmanager`) formats the webhook; for another receiver you would write the `templates` yourself |
| An external URL (optional) | links in notifications point there; not set (the UIs are behind the VPN) |

The rules that exist (`monitoring-server`, task `prometheus` and `loki`):

| Alert | When |
|---|---|
| `NodeDown` | no heartbeat of the agent of a host for 3 minutes (a host that is gone for good drops out after a day) |
| `ScrapeTargetDown` | a metrics target (`up == 0`) fails for 5 minutes |
| `EndpointDown` | a Gatus check fails for 3 minutes |
| `CertificateExpiresSoon` | a certificate of Traefik expires within a day (renewal is at two thirds of the life: it did not happen) |
| `TetragonLostEvents` | Tetragon's ring buffer lost events (gaps in the security log) |
| `DiskAlmostFull` | more than 90 % used on a Nomad-reported disk |
| `TetragonEnforcement` (Loki) | a tracing policy killed a process (`KPROBE_ACTION_SIGKILL`) |

Own rules: `cluster_monitoring_extra_rules` (a list of Prometheus rule groups, in the cluster's group_vars), or in the Grafana UI (they go to the same Alertmanager). Own routes
and receivers (e-mail, a second ntfy topic): the Alertmanager config is a template in the job file `jobs/monitoring-server.nomad.hcl` for now, not a variable. Silence an alert:
Grafana, *Alerting, Silences*, select the data source Alertmanager.

ntfy (`https://ntfy.<domain>`): log in with the user `admin` (password: `task secrets:get -- cluster_monitoring_ntfy_admin_password`), subscribe to the topic `alerts` in the web app or the
mobile app (server `https://ntfy.<domain>`). The user `alertmanager` can only publish. iOS push needs the public relay `ntfy.sh` (an `upstream-base-url`): not enabled, it would call home.

## Login

Grafana sits behind authelia-internal (VPN + second factor) and has its own login on top: the user `admin`, password `task secrets:get -- cluster_monitoring_grafana_admin_password`.
Single sign-on with authelia-internal as OpenID Connect provider is prepared (`cluster_monitoring_oidc_enabled`, the provider and the Grafana client are in the configs) but **off**: it does not
work yet. Grafana's server-side calls (token, userinfo) reach authelia on the node's address, and authelia derives its issuer from the Host header: a request with the address and port is
answered with 400, and there is no setting to override it. What is missing is a path for the Grafana allocation to authelia-internal under its name on port 443 (e.g. a Connect upstream on 443
with `auth.<zone>` mapped to it, which needs a sidecar on authelia-internal). Trusting a forward-auth header instead is not an option: any container reaches Grafana's published port.

## Security notes

- **The agent is root-equivalent on its node**: it reads the docker socket (a host volume `monitoring-docker-sock`, read only on the file, but the Docker API behind it can do everything) so that it
  can label the logs. Only the platform's job uses these host volumes; do not hand `monitoring-docker-sock` to a project (`host_volumes` of `cluster_projects`).
- Nomad's `/v1/metrics` answers **without a token** and every container reaches it, and with `nomad_publish_workload_metrics` it names jobs and tasks and their resource use. This is the price of
  the container metrics; set the variable to `false` (or `cluster_monitoring_enabled: false`) if jobs of third parties run in the cluster that must not see the others' names.
- Loki and Prometheus are unauthenticated inside their allocation and reachable only through the mesh (Consul intentions: `monitoring-vector` only). Grafana and Gatus publish a port on the cluster
  network, unauthenticated at that port for Gatus (it only shows status) and with Grafana's own login for Grafana; the *header* of a forward-auth is not trusted anywhere.
- ntfy is public and has its own login; `auth-default-access: deny-all`, no sign-up. Alerts contain host and job names.
- Grafana's local admin password is `cluster_monitoring_grafana_admin_password`; with the OIDC login off it is the way in.
- The tokens of the agents (Nomad policy `monitoring`: read metrics, nodes, allocations, deployments; Consul policy `monitoring`: read catalog and health) are in the Nomad variable
  `nomad/jobs/monitoring-agent`, written by tofu-nomad; the deployer token cannot read it.

## Operating it

```
nomad job status monitoring-server          # one allocation, eight tasks (two of them are the mesh sidecars)
nomad alloc logs -task grafana <alloc>      # or look at it in Loki: {job="monitoring-server", task="grafana"}
task backup                                 # includes a pg_dump of Grafana's database (dashboards, folders, alert rules)
task smoke                                  # checks the stack (server running, agents on every client, Loki / Prometheus answer, Grafana login redirect)
```

Secrets (`task secrets:ensure` adds the monitoring ones to an existing cluster): `cluster_monitoring_postgres_password`, `..._grafana_secret_key`, `..._grafana_admin_password`,
`..._oidc_client_secret` (+ `_hash`, the client of Grafana at authelia-internal), `cluster_authelia_internal_oidc_hmac_secret` and `..._jwks_key` (authelia's OpenID provider),
`..._ntfy_admin_password` / `_hash`, `..._ntfy_alertmanager_hash` / `_token`. Rotating one: delete it from the sops file, `task secrets:ensure`, `task deploy:ansible`.
