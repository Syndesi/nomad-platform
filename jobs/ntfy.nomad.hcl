# ntfy: push notifications (https://ntfy.<domain>, a PUBLIC name: the phones connect to it). Alertmanager publishes the alerts of the monitoring stack here.
# Access is ntfy's own: `auth-default-access: deny-all`, no sign-up; the users and the token are provisioned from the Nomad variable nomad/jobs/ntfy
# (tofu-nomad): `admin` (you: the web app / phone) and `alertmanager` (a token that can only write to the topic `alerts`).
# Because it is public the authelia rule for ntfy.<domain> is a bypass (the platform adds it, authelia_access_rules): the forward-auth of the public entry point
# cannot be answered by the ntfy app. The host port (cluster network only) is for Alertmanager and the status page, which talk to ntfy directly.
# Runs on the node of the monitoring server (client meta monitoring = true). Docs: docs/monitoring.md

variable "datacenter" {
  type = string
}
variable "domain" {
  type = string
}
variable "tls_resolver" {
  type    = string
  default = ""
}
variable "image" {
  type = string
}
variable "port" {
  type    = number
  default = 8580
}
variable "uid" {
  type    = string
  default = "65534"
}
variable "topic" {
  type    = string
  default = "alerts"
}

job "ntfy" {
  datacenters = [var.datacenter]
  type        = "service"

  group "ntfy" {
    constraint {
      attribute = "${meta.monitoring}"
      value     = "true"
    }

    network {
      mode = "bridge"
      port "http" {
        static = var.port
        to     = 8080
      }
      port "metrics" {
        to = 9090
      }
    }

    update {
      auto_revert      = true
      min_healthy_time = "10s"
    }

    volume "ntfy" {
      type   = "host"
      source = "monitoring-ntfy"
    }

    service {
      name     = "ntfy"
      port     = "http"
      provider = "consul"
      tags = [
        "traefik.enable=true",
        "traefik.http.routers.ntfy.rule=Host(`ntfy.${var.domain}`)",
        "traefik.http.routers.ntfy.entrypoints=websecure",
        "traefik.http.routers.ntfy.tls=true",
        "traefik.http.routers.ntfy.tls.certresolver=${var.tls_resolver}",
      ]
      check {
        type     = "http"
        path     = "/v1/health"
        interval = "30s"
        timeout  = "5s"
      }
    }
    # picked up by the agents' vector (consul tag `metrics`)
    service {
      name     = "ntfy-metrics"
      port     = "metrics"
      provider = "consul"
      tags     = ["metrics"]
    }

    task "ntfy" {
      driver = "docker"
      user   = var.uid

      volume_mount {
        volume      = "ntfy"
        destination = "/var/lib/ntfy"
      }

      env {
        NTFY_BASE_URL             = "https://ntfy.${var.domain}"
        NTFY_LISTEN_HTTP          = ":8080"
        NTFY_BEHIND_PROXY         = "true"
        NTFY_CACHE_FILE           = "/var/lib/ntfy/cache.db"
        NTFY_ATTACHMENT_CACHE_DIR = "/var/lib/ntfy/attachments"
        NTFY_AUTH_FILE            = "/var/lib/ntfy/user.db"
        NTFY_AUTH_DEFAULT_ACCESS  = "deny-all"
        NTFY_ENABLE_LOGIN         = "true"
        NTFY_ENABLE_SIGNUP        = "false"
        NTFY_LOG_FORMAT           = "json"
        NTFY_LOG_LEVEL            = "info"
        NTFY_ENABLE_METRICS       = "true"
        NTFY_METRICS_LISTEN_HTTP  = ":9090"
        NTFY_WEB_ROOT             = "app"
      }

      # the users, their access and the token are in a config file, not in environment variables: the environment of a container is visible in
      # `docker inspect` (and the docker api that vector reads). The rest of the settings (not secret) stay in the env block above.
      template {
        data        = <<-EOT
          {{ with nomadVar "nomad/jobs/ntfy" -}}
          auth-users:
            - "admin:{{ .admin_hash }}:admin"
            - "alertmanager:{{ .alertmanager_hash }}:user"
          auth-access:
            - "alertmanager:${var.topic}:write-only"
          auth-tokens:
            - "alertmanager:{{ .alertmanager_token }}:alertmanager"
          {{- end }}
        EOT
        destination = "secrets/server.yml"
        perms       = "0400"
        uid         = parseint(var.uid, 10)
        gid         = parseint(var.uid, 10)
      }

      config {
        image           = var.image
        args            = ["serve", "--config", "/secrets/server.yml"]
        ports           = ["http", "metrics"]
        cap_drop        = ["ALL"]
        readonly_rootfs = true
      }

      resources {
        cpu    = 100
        memory = 96
      }
    }
  }
}
