# The monitoring agent: Vector on every client node (system job). It ships
#   - the logs of every container (docker socket; labels: host, nomad job / task / namespace, level) and Tetragon's event log to Loki,
#   - the metrics of the node (Nomad, Consul, Tetragon, itself) and of every consul service tagged `metrics` that runs on this node to Prometheus
#     (remote write); vector scrapes, Prometheus only stores,
#   - on the node of the monitoring server only: what happens in the cluster (Nomad nodes joining / leaving / draining, allocations and their restarts,
#     deployments, Consul health checks changing status), polled from the APIs, once per change, to Loki. Docs: docs/monitoring.md
# Loki and Prometheus are reached through the Consul mesh (the sidecar of the service "monitoring-vector"; intentions let only this service in).
# The config is jobs/monitoring-agent/vector.yaml.tpl (a Nomad template, delimiters [[ ]]); tokens: the Nomad variable nomad/jobs/monitoring-agent (tofu-nomad).

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
variable "templates_dir" {
  type = string
}
variable "image" {
  type = string
}
variable "nomad_port" {
  type = number
}
variable "consul_port" {
  type = number
}
variable "tetragon_port" {
  description = "0 = no tetragon metrics"
  type        = number
}
variable "tetragon_log" {
  description = "true: ship Tetragon's event log"
  type        = bool
}

job "monitoring-agent" {
  datacenters = [var.datacenter]
  type        = "system"

  group "monitoring-agent" {
    network {
      mode = "bridge"
    }

    update {
      auto_revert = false
    }

    volume "vector" {
      type   = "host"
      source = "monitoring-vector"
    }
    volume "docker-sock" {
      type      = "host"
      source    = "monitoring-docker-sock"
      read_only = true
    }
    dynamic "volume" {
      for_each = var.tetragon_log ? ["tetragon"] : []
      labels   = ["tetragon-log"]
      content {
        type      = "host"
        source    = "monitoring-tetragon-log"
        read_only = true
      }
    }

    # The mesh identity of the agent: upstream only (nothing listens on the nominal port). Intentions: only this service may connect to Loki and Prometheus.
    service {
      name     = "monitoring-vector"
      port     = "9"
      provider = "consul"
      tags     = []

      connect {
        sidecar_service {
          proxy {
            upstreams {
              destination_name = "monitoring-loki"
              local_bind_port  = 3100
            }
            upstreams {
              destination_name = "monitoring-prometheus"
              local_bind_port  = 9090
            }
          }
        }
      }
    }

    task "vector" {
      driver = "docker"
      # root inside the container (the docker socket, tetragon's root-only log directory), but without capabilities and with a read-only root filesystem
      user = "0"

      # templates that read the consul catalog (services) log in to consul with the task's workload identity (policy-nomad-tasks: read the catalog)
      identity {
        name = "consul_default"
        aud  = ["consul.io"]
        ttl  = "1h"
      }

      env {
        NODE_NAME           = "${node.unique.name}"
        NODE_IP             = "${attr.unique.network.ip-address}"
        MONITORING_NODE     = "${meta.monitoring}"
        NOMAD_PORT          = "${var.nomad_port}"
        CONSUL_PORT         = "${var.consul_port}"
        TETRAGON_PORT       = "${var.tetragon_port}"
        TETRAGON_LOG        = "${var.tetragon_log}"
        VECTOR_LOG          = "info"
        VECTOR_WATCH_CONFIG = "false"
      }

      volume_mount {
        volume      = "vector"
        destination = "/var/lib/vector"
      }
      volume_mount {
        volume      = "docker-sock"
        destination = "/var/run/docker.sock"
        read_only   = true
      }
      dynamic "volume_mount" {
        for_each = var.tetragon_log ? ["tetragon"] : []
        content {
          volume      = "tetragon-log"
          destination = "/tetragon"
          read_only   = true
        }
      }

      template {
        data            = file("${var.templates_dir}/vector.yaml.tpl")
        destination     = "secrets/vector.yaml"
        left_delimiter  = "[["
        right_delimiter = "]]"
        # the list of metric targets follows the consul catalog: vector reloads its config on SIGHUP
        change_mode   = "signal"
        change_signal = "SIGHUP"
      }
      template {
        data        = "{{ with nomadVar \"nomad/jobs/monitoring-agent\" }}{{ .ca_cert }}{{ end }}"
        destination = "secrets/ca.pem"
        perms       = "0644"
      }

      config {
        image           = var.image
        args            = ["--config", "/secrets/vector.yaml"]
        cap_drop        = ["ALL"]
        readonly_rootfs = true
      }

      resources {
        cpu    = 200
        memory = 192
      }
    }
  }
}
