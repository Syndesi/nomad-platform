# The monitoring server: logs (Loki), metrics (Prometheus), alerts (Alertmanager), dashboards (Grafana, database in Postgres) and the status page (Gatus).
# ONE allocation on ONE node (client meta monitoring = true, cluster_monitoring_node): all tasks share the network namespace and talk over 127.0.0.1,
# and everything except two web uis listens on 127.0.0.1 only. What is reachable from outside the allocation:
#   - Loki and Prometheus (remote write) through their Connect sidecars: only the agents' service "monitoring-vector" may connect (intentions, tofu-consul);
#   - Grafana and Gatus on a published port of the node (cluster network), behind traefik's internal entry point (VPN + authelia-internal), and
#     Grafana's own login is the OIDC login of authelia-internal (no header trust: any container of the cluster can reach the port);
#   - Alertmanager only from Grafana (127.0.0.1): its alerts go out to ntfy.
# A change to the job (not to a template) replaces the whole allocation, i.e. every task restarts once; the data is on host volumes.
# Secrets: the Nomad variable nomad/jobs/monitoring-server (tofu-nomad). Docs: docs/monitoring.md

variable "datacenter" {
  type = string
}
# common variables of every job of the platform (cluster_jobs_common_vars); not used here
variable "domain" {
  type    = string
  default = ""
}
variable "tls_resolver" {
  type    = string
  default = ""
}
variable "zone" {
  type = string
}
variable "cluster_domain" {
  type = string
}
variable "retention_days" {
  type    = number
  default = 45
}
variable "postgres_image" {
  type = string
}
variable "loki_image" {
  type = string
}
variable "prometheus_image" {
  type = string
}
variable "alertmanager_image" {
  type = string
}
variable "grafana_image" {
  type = string
}
variable "gatus_image" {
  type = string
}
# host ports (the cluster network only; traefik's file provider routes to them)
variable "grafana_port" {
  type    = number
  default = 3300
}
variable "gatus_port" {
  type    = number
  default = 8480
}
# the ingress node (public names are checked through traefik there), authelia-internal (grafana's OIDC token exchange) and ntfy (where alerts go)
variable "ingress_addr" {
  type = string
}
variable "authelia_internal_addr" {
  type = string
}
variable "ntfy_addr" {
  type = string
}
variable "oidc" {
  type    = bool
  default = false
}
variable "ntfy_topic" {
  type    = string
  default = "alerts"
}
# uids of the images (the host volumes belong to them, nomad role)
variable "uid_postgres" {
  type    = string
  default = "70"
}
variable "uid_loki" {
  type    = string
  default = "10001"
}
variable "uid_prometheus" {
  type    = string
  default = "65534"
}
variable "uid_grafana" {
  type    = string
  default = "472"
}
variable "uid_gatus" {
  type    = string
  default = "65534"
}
# the name of the cluster in the status page
variable "cluster_name" {
  type = string
}
# the cluster's own Prometheus rules: {"groups": [...]} as json ("" = none)
variable "extra_rules" {
  type    = string
  default = ""
}

job "monitoring-server" {
  datacenters = [var.datacenter]
  type        = "service"

  group "monitoring" {
    constraint {
      attribute = "${meta.monitoring}"
      value     = "true"
    }

    network {
      mode = "bridge"
      port "grafana" {
        static = var.grafana_port
        to     = 3000
      }
      port "gatus" {
        static = var.gatus_port
        to     = 8080
      }
    }

    update {
      auto_revert      = true
      min_healthy_time = "20s"
      healthy_deadline = "5m"
    }

    volume "postgres" {
      type   = "host"
      source = "monitoring-postgres"
    }
    volume "loki" {
      type   = "host"
      source = "monitoring-loki"
    }
    volume "prometheus" {
      type   = "host"
      source = "monitoring-prometheus"
    }
    volume "alertmanager" {
      type   = "host"
      source = "monitoring-alertmanager"
    }
    volume "grafana" {
      type   = "host"
      source = "monitoring-grafana"
    }
    volume "gatus" {
      type   = "host"
      source = "monitoring-gatus"
    }

    # ---- the mesh: the agents write logs and metrics through these two ----------------------------------------------------------------
    service {
      name     = "monitoring-loki"
      port     = "3100"
      provider = "consul"
      tags     = []
      connect {
        sidecar_service {}
      }
    }
    service {
      name     = "monitoring-prometheus"
      port     = "9090"
      provider = "consul"
      tags     = []
      connect {
        sidecar_service {}
      }
    }

    # ---- the two web uis (published; traefik's file provider has their routers) -----------------------------------------------------
    service {
      name     = "monitoring-grafana"
      port     = "grafana"
      provider = "consul"
      tags     = []
      check {
        type     = "http"
        path     = "/api/health"
        interval = "30s"
        timeout  = "5s"
      }
    }
    service {
      name     = "monitoring-gatus"
      port     = "gatus"
      provider = "consul"
      tags     = []
      check {
        type     = "http"
        path     = "/health"
        interval = "30s"
        timeout  = "5s"
      }
    }

    # ---- Postgres: Grafana's database, nothing else uses it ---------------------------------------------------------------------------
    task "postgres" {
      driver = "docker"
      user   = var.uid_postgres

      lifecycle {
        hook    = "prestart"
        sidecar = true
      }

      volume_mount {
        volume      = "postgres"
        destination = "/var/lib/postgresql/data"
      }

      template {
        data        = <<-EOT
          {{ with nomadVar "nomad/jobs/monitoring-server" }}POSTGRES_PASSWORD={{ .postgres_password }}{{ end }}
        EOT
        destination = "secrets/postgres.env"
        env         = true
      }
      env {
        POSTGRES_USER = "grafana"
        POSTGRES_DB   = "grafana"
        PGDATA        = "/var/lib/postgresql/data/pgdata"
      }

      config {
        image = var.postgres_image
        args  = ["-c", "listen_addresses=127.0.0.1", "-c", "max_connections=50", "-c", "shared_buffers=64MB"]
      }

      resources {
        cpu    = 200
        memory = 256
      }
    }

    # ---- Loki: logs ------------------------------------------------------------------------------------------------------------------------
    task "loki" {
      driver = "docker"
      user   = var.uid_loki

      volume_mount {
        volume      = "loki"
        destination = "/loki"
      }

      template {
        data        = <<-EOT
          auth_enabled: false
          server:
            http_listen_address: 127.0.0.1
            http_listen_port: 3100
            grpc_listen_address: 127.0.0.1
            grpc_listen_port: 9096
            log_level: info
            log_format: json
          common:
            instance_addr: 127.0.0.1
            path_prefix: /loki
            storage:
              filesystem:
                chunks_directory: /loki/chunks
                rules_directory: /loki/rules
            replication_factor: 1
            ring:
              kvstore:
                store: inmemory
          schema_config:
            configs:
              - from: 2020-10-24
                store: tsdb
                object_store: filesystem
                schema: v13
                index:
                  prefix: index_
                  period: 24h
          limits_config:
            retention_period: ${var.retention_days * 24}h
            allow_structured_metadata: true
            volume_enabled: true
          # without the compactor's retention nothing is ever deleted
          compactor:
            working_directory: /loki/compactor
            retention_enabled: true
            delete_request_store: filesystem
          ruler:
            storage:
              type: local
              local:
                directory: /local/rules
            rule_path: /loki/rules-tmp
            alertmanager_url: http://127.0.0.1:9093
            enable_api: false
          analytics:
            reporting_enabled: false
        EOT
        destination = "local/loki.yaml"
      }
      # alert rules on logs (the ruler reads <directory>/<tenant>/*.yaml, the tenant is "fake" without auth)
      template {
        data            = <<-EOT
          groups:
            - name: tetragon
              rules:
                - alert: TetragonEnforcement
                  expr: sum by (host) (count_over_time({job="tetragon"} |= "KPROBE_ACTION_SIGKILL" [5m])) > 0
                  for: 0m
                  labels:
                    severity: warning
                  annotations:
                    summary: "Tetragon killed a process on {{ $labels.host }}"
                    description: "A tracing policy with an enforcing action fired (grep KPROBE_ACTION_SIGKILL in the Tetragon log of the node)."
        EOT
        destination     = "local/rules/fake/tetragon.yaml"
        left_delimiter  = "[["
        right_delimiter = "]]"
      }

      config {
        image = var.loki_image
        args  = ["-config.file=/local/loki.yaml", "-config.expand-env=false"]
      }

      resources {
        cpu    = 500
        memory = 768
      }
    }

    # ---- Prometheus: the metrics store. The agents' vector remote-writes into it; it scrapes only the services of this allocation ------
    task "prometheus" {
      driver = "docker"
      user   = var.uid_prometheus

      volume_mount {
        volume      = "prometheus"
        destination = "/prometheus"
      }

      template {
        data        = <<-EOT
          global:
            scrape_interval: 30s
            evaluation_interval: 30s
          alerting:
            alertmanagers:
              - static_configs:
                  - targets: ["127.0.0.1:9093"]
          rule_files:
            - /local/rules/*.yml
          scrape_configs:
            - job_name: monitoring-server
              static_configs:
                - targets: ["127.0.0.1:9090"]
                  labels: {service: prometheus}
                - targets: ["127.0.0.1:9093"]
                  labels: {service: alertmanager}
                - targets: ["127.0.0.1:3100"]
                  labels: {service: loki}
                - targets: ["127.0.0.1:3000"]
                  labels: {service: grafana}
                - targets: ["127.0.0.1:8080"]
                  labels: {service: gatus}
        EOT
        destination = "local/prometheus.yml"
      }

      # The alert rules: what a platform wants to know. Targets come from the agents (label `job`), so a node that is gone is a series that stops.
      template {
        data            = <<-EOT
          groups:
            - name: platform
              rules:
                - alert: NodeDown
                  expr: time() - max by (host) (max_over_time(timestamp(vector_uptime_seconds)[1d:1m])) > 180
                  for: 1m
                  labels: {severity: critical}
                  annotations:
                    summary: "No metrics from {{ $labels.host }} for 3 minutes (the agent or the node is down)"
                - alert: ScrapeTargetDown
                  expr: up == 0
                  for: 5m
                  labels: {severity: warning}
                  annotations:
                    summary: "{{ $labels.job }} on {{ $labels.host }} does not answer ({{ $labels.instance }})"
                - alert: EndpointDown
                  expr: gatus_results_endpoint_success == 0
                  for: 3m
                  labels: {severity: warning}
                  annotations:
                    summary: "{{ $labels.name }} ({{ $labels.group }}) fails its checks"
                - alert: CertificateExpiresSoon
                  expr: min by (cn) (traefik_tls_certs_not_after) - time() < 86400
                  for: 10m
                  labels: {severity: warning}
                  annotations:
                    summary: "The certificate {{ $labels.cn }} of traefik expires in less than a day (renewal should have happened at two thirds of its life)"
                - alert: TetragonLostEvents
                  expr: increase(tetragon_observer_ringbuf_events_lost_total[10m]) > 0
                  for: 0m
                  labels: {severity: warning}
                  annotations:
                    summary: "Tetragon on {{ $labels.host }} lost events (ring buffer full): the security log has gaps"
                - alert: DiskAlmostFull
                  expr: nomad_client_host_disk_used_percent > 90
                  for: 10m
                  labels: {severity: warning}
                  annotations:
                    summary: "Less than 10 % free on {{ $labels.disk }} of {{ $labels.host }}"
        EOT
        destination     = "local/rules/platform.yml"
        left_delimiter  = "[["
        right_delimiter = "]]"
      }

      template {
        data            = var.extra_rules != "" ? var.extra_rules : "groups: []"
        destination     = "local/rules/extra.yml"
        left_delimiter  = "[["
        right_delimiter = "]]"
      }

      config {
        image = var.prometheus_image
        args = [
          "--config.file=/local/prometheus.yml",
          "--storage.tsdb.path=/prometheus",
          "--storage.tsdb.retention.time=${var.retention_days}d",
          "--web.listen-address=127.0.0.1:9090",
          # vector writes here
          "--web.enable-remote-write-receiver",
        ]
      }

      resources {
        cpu    = 500
        memory = 768
      }
    }

    # ---- Alertmanager: groups the alerts of Prometheus, Loki and Grafana and sends them to ntfy -----------------------------------------
    task "alertmanager" {
      driver = "docker"
      user   = var.uid_prometheus

      # silences and the log of sent notifications
      volume_mount {
        volume      = "alertmanager"
        destination = "/alertmanager"
      }

      template {
        data        = <<-EOT
          route:
            receiver: ntfy
            group_by: [alertname, host]
            group_wait: 30s
            group_interval: 5m
            repeat_interval: 12h
            routes:
              - matchers: [severity="critical"]
                receiver: ntfy
                repeat_interval: 2h
          # a node that is down also fails its targets and checks: only the node alert is sent for it
          inhibit_rules:
            - source_matchers: [alertname="NodeDown"]
              target_matchers: [alertname=~"ScrapeTargetDown|TetragonLostEvents|DiskAlmostFull"]
              equal: [host]
          receivers:
            - name: ntfy
              webhook_configs:
                # ntfy formats the alertmanager payload itself (template=alertmanager)
                - url: http://${var.ntfy_addr}/${var.ntfy_topic}?template=alertmanager
                  send_resolved: true
                  http_config:
                    authorization:
                      type: Bearer
                      credentials: "{{ with nomadVar "nomad/jobs/monitoring-server" }}{{ .ntfy_token }}{{ end }}"
        EOT
        destination = "secrets/alertmanager.yml"
        perms       = "0644"
      }

      config {
        image = var.alertmanager_image
        args = [
          "--config.file=/secrets/alertmanager.yml",
          "--storage.path=/alertmanager",
          "--web.listen-address=127.0.0.1:9093",
          # a single instance: no gossip cluster
          "--cluster.listen-address=",
        ]
      }

      resources {
        cpu    = 100
        memory = 96
      }
    }

    # ---- Grafana ------------------------------------------------------------------------------------------------------------------------------
    task "grafana" {
      driver = "docker"
      user   = var.uid_grafana

      volume_mount {
        volume      = "grafana"
        destination = "/var/lib/grafana"
      }

      template {
        data        = <<-EOT
          {{ with nomadVar "nomad/jobs/monitoring-server" }}
          GF_DATABASE_PASSWORD={{ .postgres_password }}
          GF_SECURITY_SECRET_KEY={{ .grafana_secret_key }}
          GF_SECURITY_ADMIN_PASSWORD={{ .grafana_admin_password }}
          GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET={{ .oidc_client_secret }}
          {{ end }}
        EOT
        destination = "secrets/grafana.env"
        env         = true
      }

      template {
        data        = <<-EOT
          [server]
          protocol = http
          http_addr = 0.0.0.0
          http_port = 3000
          domain = grafana.${var.zone}
          root_url = https://grafana.${var.zone}/
          [database]
          type = postgres
          host = 127.0.0.1:5432
          name = grafana
          user = grafana
          ssl_mode = disable
          [security]
          # the emergency admin (https://grafana.<zone>/login?disableAutoLogin=true); everybody else logs in through authelia
          admin_user = admin
          disable_gravatar = true
          cookie_secure = true
          cookie_samesite = lax
          [users]
          allow_sign_up = false
          allow_org_create = false
          default_theme = system
          [plugins]
          # nothing is installed from the internet (the nodes may have no way out, and a monitoring stack should not need one)
          preinstall_disabled = true
          plugin_admin_enabled = false
          [analytics]
          reporting_enabled = false
          check_for_updates = false
          check_for_plugin_updates = false
          [news]
          news_feed_enabled = false
          %{if var.oidc~}
          [auth]
          oauth_auto_login = true
          [auth.generic_oauth]
          enabled = true
          name = Authelia
          client_id = grafana
          scopes = openid profile email groups
          auth_url = https://auth.${var.zone}/api/oidc/authorization
          # the token exchange goes to authelia-internal directly (the zone's names do not resolve in a container)
          token_url = https://${var.authelia_internal_addr}/api/oidc/token
          api_url = https://${var.authelia_internal_addr}/api/oidc/userinfo
          tls_client_ca = /secrets/ca.pem
          use_pkce = true
          login_attribute_path = preferred_username
          name_attribute_path = name
          email_attribute_path = email
          groups_attribute_path = groups
          role_attribute_path = contains(groups[*], 'admin') && 'GrafanaAdmin' || 'Viewer'
          allow_assign_grafana_admin = true
          auto_login = true
          %{endif~}
          [unified_alerting]
          enabled = true
        EOT
        destination = "local/grafana.ini"
      }
      # the cluster CA, to verify authelia's node certificate
      template {
        data        = "{{ with nomadVar \"nomad/jobs/monitoring-server\" }}{{ .ca_cert }}{{ end }}"
        destination = "secrets/ca.pem"
        perms       = "0644"
      }
      # data sources only (no dashboards: those are made in the ui)
      template {
        data        = <<-EOT
          apiVersion: 1
          datasources:
            - name: Prometheus
              type: prometheus
              uid: prometheus
              url: http://127.0.0.1:9090
              isDefault: true
            - name: Loki
              type: loki
              uid: loki
              url: http://127.0.0.1:3100
            - name: Alertmanager
              type: alertmanager
              uid: alertmanager
              url: http://127.0.0.1:9093
              jsonData:
                implementation: prometheus
                handleGrafanaManagedAlerts: true
        EOT
        destination = "local/provisioning/datasources/datasources.yaml"
      }

      config {
        image = var.grafana_image
        ports = ["grafana"]
        volumes = [
          "local/grafana.ini:/etc/grafana/grafana.ini:ro",
          "local/provisioning:/etc/grafana/provisioning:ro",
        ]
      }

      resources {
        cpu    = 300
        memory = 384
      }
    }

    # ---- Gatus: the status page ---------------------------------------------------------------------------------------------------------
    # Checks the platform's own services directly (in this allocation, or on their node) and every name traefik publishes on the public entry point
    # (consul services with a `traefik.http.routers.<r>.rule=Host(...)` tag) through traefik itself: the request goes to the ingress node's address with
    # the Host header of the name (a container cannot resolve the public names), so the routing and the backend are tested. The certificate is not
    # (no name, no SNI): Prometheus alerts on traefik's own certificate metric. A page behind authelia answers with the redirect to the login: that counts as up.
    task "gatus" {
      driver = "docker"
      user   = var.uid_gatus

      # templates that read the consul catalog (services) log in to consul with the task's workload identity (policy-nomad-tasks: read the catalog)
      identity {
        name = "consul_default"
        aud  = ["consul.io"]
        ttl  = "1h"
      }

      volume_mount {
        volume      = "gatus"
        destination = "/data"
      }

      env {
        GATUS_CONFIG_PATH = "/local/config.yaml"
      }

      template {
        data        = <<-EOT
          metrics: true
          storage:
            type: sqlite
            path: /data/gatus.db
          web:
            port: 8080
          ui:
            title: "${var.cluster_name}"
            header: "${var.cluster_name}"
          endpoints:
            - name: grafana
              group: monitoring
              url: http://127.0.0.1:3000/api/health
              interval: 1m
              conditions: ["[STATUS] == 200"]
            - name: prometheus
              group: monitoring
              url: http://127.0.0.1:9090/-/healthy
              interval: 1m
              conditions: ["[STATUS] == 200"]
            - name: loki
              group: monitoring
              url: http://127.0.0.1:3100/ready
              interval: 1m
              conditions: ["[STATUS] == 200"]
            - name: alertmanager
              group: monitoring
              url: http://127.0.0.1:9093/-/healthy
              interval: 1m
              conditions: ["[STATUS] == 200"]
            - name: ntfy
              group: monitoring
              url: http://${var.ntfy_addr}/v1/health
              interval: 1m
              conditions: ["[STATUS] == 200"]
            - name: authelia-internal
              group: platform
              url: https://${var.authelia_internal_addr}/api/health
              client: {insecure: true}
              interval: 1m
              conditions: ["[STATUS] == 200"]
          {{- range $svc := services }}{{ range $tag := $svc.Tags }}
          {{- if $tag | regexMatch "^traefik\\.http\\.routers\\.[^.]+\\.rule=Host\\(`" }}
          {{- $host := $tag | regexReplaceAll "^[^`]*`([^`]+)`.*$" "$1" }}
            - name: "{{ $host }}"
              group: traefik
              url: https://${var.ingress_addr}/
              headers: {Host: "{{ $host }}"}
              client: {insecure: true, ignore-redirect: true}
              interval: 1m
              conditions: ["[STATUS] == any(200, 204, 301, 302, 303, 307, 308, 401, 403)"]
          {{- end }}{{ end }}{{ end }}
        EOT
        destination = "local/config.yaml"
      }
      config {
        image = var.gatus_image
        ports = ["gatus"]
      }

      resources {
        cpu    = 100
        memory = 96
      }
    }
  }
}
