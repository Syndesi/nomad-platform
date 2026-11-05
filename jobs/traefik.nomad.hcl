# Traefik: ingress on the nomad server node (client meta traefik=true).
#  - consul catalog provider: jobs publish routers through service tags (authelia does)
#  - file provider: nomad / consul / traefik dashboard, all behind the authelia forward-auth
# Reaches the local consul / nomad over https. No host path is mounted: the cluster CA (public) comes from the nomad
# variable like the secrets do: the consul token and the CA from nomad/jobs/traefik (tofu-nomad), the ingress cert + key
# ("internal" mode, made on the ingress node) from nomad/jobs/traefik/traefik (role cluster_jobs).
#
# wireguard = true: traefik runs in the allocation's own bridge network, together with a wireguard client (prestart
# sidecar, config from nomad/jobs/traefik/traefik/wireguard, readable by that task only). The tunnel lives in the
# allocation's network namespace: no host service can drop it, and a restart of the allocation rebuilds it. Traefik then
# reaches consul and nomad on the node's cluster address instead of 127.0.0.1.

variable "datacenter" {
  type = string
}
variable "image" {
  type = string
}
variable "domain" {
  type = string
}
variable "consul_port" {
  type = number
}
variable "nomad_port" {
  type = number
}
variable "wireguard" {
  type    = bool
  default = false
}
variable "wireguard_image" {
  type    = string
  default = ""
}
# the tunnel counts as down when its newest handshake is older than this (seconds). With PersistentKeepalive = 25 a handshake
# happens every ~2 minutes.
variable "wireguard_max_handshake_age" {
  type    = number
  default = 300
}
# directory of the text templates next to this file (traefik/*.tpl). Absolute path, or relative to where `nomad job run` is started.
variable "templates_dir" {
  type    = string
  default = "traefik"
}
# 0 = no metrics. Otherwise prometheus metrics on their own entry point and port (not the web ports), registered as the consul service
# "traefik-metrics". Bound to the allocation's address, never to the tunnel.
variable "metrics_port" {
  type    = number
  default = 0
}
# networks that stay reachable directly (not through the tunnel): the cluster subnet, so traefik still reaches consul, nomad
# and the services on the nodes although the tunnel's AllowedIPs is 0.0.0.0/0. The host address and the allocation's name
# servers (dns of the host) are always added.
variable "wireguard_bypass" {
  type    = list(string)
  default = []
}
# "" = certificates from the cluster CA (cert in the nomad variable), otherwise the resolver name
variable "tls_resolver" {
  type    = string
  default = ""
}
variable "acme_server" {
  type    = string
  default = ""
}
variable "acme_email" {
  type    = string
  default = ""
}

job "traefik" {
  datacenters = [var.datacenter]
  type        = "service"

  constraint {
    attribute = "${meta.traefik}"
    value     = "true"
  }

  group "traefik" {
    update {
      auto_revert = true
    }

    volume "traefik" {
      type      = "host"
      read_only = false
      source    = "traefik"
    }

    network {
      mode = var.wireguard ? "bridge" : "host"
      port "http" {
        static = 80
        to     = 80
      }
      port "https" {
        static = 443
        to     = 443
      }
      dynamic "port" {
        labels   = ["metrics"]
        for_each = var.metrics_port > 0 ? ["metrics"] : []
        content {
          static = var.metrics_port
          to     = var.metrics_port
        }
      }
    }

    # a service of its own: the metrics are for the cluster (a scraper finds them through consul), traefik never routes them
    dynamic "service" {
      for_each = var.metrics_port > 0 ? ["metrics"] : []
      content {
        name     = "traefik-metrics"
        port     = "metrics"
        provider = "consul"
        tags     = ["metrics", "prometheus"]

        check {
          type     = "tcp"
          interval = "10s"
          timeout  = "3s"
        }
      }
    }

    service {
      name     = "traefik"
      port     = "https"
      provider = "consul"
      # no traefik tags on purpose: they would make the consul catalog provider generate a backend for this service
      # (http://<node>:443, a TLS port) that nothing uses; the dashboard router is in the file provider below
      tags = []

      check {
        type     = "tcp"
        interval = "10s"
        timeout  = "3s"
      }
    }

    # the tunnel is healthy while it keeps handshaking. A service of its own (the check of "traefik" is a tcp check that stays green
    # with a dead tunnel). The check runs every 30s inside the wireguard container, on the node itself (no traffic leaves it);
    # three failures in a row restart the wireguard task, which rebuilds the tunnel in the same network namespace.
    dynamic "service" {
      for_each = var.wireguard ? ["tunnel"] : []
      content {
        name     = "traefik-tunnel"
        provider = "consul"
        tags     = []

        check {
          type     = "script"
          task     = "wireguard"
          command  = "/bin/sh"
          args     = ["/health.sh"]
          interval = "30s"
          timeout  = "10s"

          check_restart {
            limit = 3
            grace = "90s"
          }
        }
      }
    }

    dynamic "task" {
      labels   = ["wireguard"]
      for_each = var.wireguard ? ["wireguard"] : []

      content {
        driver = "docker"

        lifecycle {
          hook    = "prestart"
          sidecar = true
        }

        # the wg-quick config (with the private key) is only visible to this task
        template {
          data        = <<EOT
{{ with nomadVar "nomad/jobs/traefik/traefik/wireguard" }}{{ .conf }}{{ end }}
EOT
          destination = "secrets/wg/wg0.conf"
          perms       = "0600"
        }

        # direct routes for the bypass networks, in place before the tunnel installs its default route: the image runs the scripts
        # of /custom-cont-init.d before it brings the tunnel up (wg-quick's policy rules keep using the more specific routes of
        # the main table). The host address and the allocation's name servers are always included. Script: traefik/wg-routes.sh.tpl
        template {
          data        = file("${var.templates_dir}/wg-routes.sh.tpl")
          destination = "local/routes.sh"
          perms       = "0755"
        }

        # the health check of the tunnel (service "traefik-tunnel" above) runs this script inside the container
        template {
          data        = file("${var.templates_dir}/wg-health.sh.tpl")
          destination = "local/health.sh"
          perms       = "0755"
        }

        # parameters of the templates above (jobs/traefik/*.tpl), read there with {{ env "..." }}
        env {
          WG_BYPASS            = join(" ", var.wireguard_bypass)
          WG_MAX_HANDSHAKE_AGE = var.wireguard_max_handshake_age
          TPL_METRICS_PORT     = var.metrics_port
        }

        config {
          image   = var.wireguard_image
          cap_add = ["net_admin"]
          sysctl = {
            "net.ipv4.conf.all.src_valid_mark" = "1"
          }
          volumes = ["secrets/wg:/config/wg_confs", "local/routes.sh:/custom-cont-init.d/10-routes.sh:ro", "local/health.sh:/health.sh:ro"]
        }

        resources {
          cpu    = 50
          memory = 64
        }
      }
    }

    task "traefik" {
      driver = "docker"

      volume_mount {
        volume      = "traefik"
        destination = "/acme"
        read_only   = false
      }

      # the cluster CA (public): traefik verifies consul and nomad with it
      template {
        data        = <<EOT
{{ with nomadVar "nomad/jobs/traefik" }}{{ .ca_cert }}{{ end }}
EOT
        destination = "secrets/ca.pem"
      }

      # Static config as a file: traefik takes EITHER file, cli args OR env (the others are ignored),
      # and this is the only way to keep the consul token out of the job spec / process list. Text: traefik/static.yml.tpl
      template {
        data        = file("${var.templates_dir}/static.yml.tpl")
        destination = "secrets/traefik.yml"
        perms       = "0600"
      }

      # default certificate in "internal" mode (made on the node, nomad variable written by the cluster_jobs role); with an ACME
      # resolver there is no such variable, so there is no such template either (it would wait for the variable forever)
      dynamic "template" {
        for_each = var.tls_resolver == "" ? ["ingress.pem"] : []
        content {
          data        = <<EOT
{{ with nomadVar "nomad/jobs/traefik/traefik" }}{{ .ingress_cert }}{{ end }}
EOT
          destination = "secrets/ingress.pem"
        }
      }
      dynamic "template" {
        for_each = var.tls_resolver == "" ? ["ingress.key"] : []
        content {
          data        = <<EOT
{{ with nomadVar "nomad/jobs/traefik/traefik" }}{{ .ingress_key }}{{ end }}
EOT
          destination = "secrets/ingress.key"
          perms       = "0600"
        }
      }

      # nomad / consul / dashboard behind the authelia forward-auth (the middleware comes from authelia's service tags), TLS options,
      # default certificate. Text: traefik/dynamic.yml.tpl
      template {
        data        = file("${var.templates_dir}/dynamic.yml.tpl")
        destination = "secrets/dynamic/cluster.yml"
        perms       = "0600"
      }

      # parameters of the templates above (jobs/traefik/*.tpl), read there with {{ env "..." }}
      env {
        TPL_WIREGUARD    = var.wireguard
        TPL_DOMAIN       = var.domain
        TPL_METRICS_PORT = var.metrics_port
        TPL_CONSUL_PORT  = var.consul_port
        TPL_NOMAD_PORT   = var.nomad_port
        TPL_TLS_RESOLVER = var.tls_resolver
        TPL_ACME_SERVER  = var.acme_server
        TPL_ACME_EMAIL   = var.acme_email
      }

      config {
        image        = var.image
        network_mode = var.wireguard ? null : "host"
        args         = ["--configFile=/secrets/traefik.yml"]
      }

      resources {
        cpu    = 250
        memory = 256
      }
    }
  }
}
