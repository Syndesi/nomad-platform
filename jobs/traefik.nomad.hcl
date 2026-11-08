# Traefik: ingress on the nomad server node (client meta traefik=true).
#  - consul catalog provider: jobs publish routers through service tags (apps do)
#  - file provider: authelia (portal and forward-auth middleware), nomad / consul / traefik dashboard, all behind the authelia forward-auth
# Reaches the local consul / nomad over https. No host path is mounted: the cluster CA (public) comes from the nomad
# variable like the secrets do: the consul token and the CA from nomad/jobs/traefik (tofu-nomad), the ingress cert + key
# ("internal" mode, made on the ingress node) from nomad/jobs/traefik/traefik (role cluster_jobs).
#
# Traefik runs in the allocation's own network namespace ("cni/egress"), with prestart sidecars that share it:
#  - vpn       wireguard SERVER (wg1) for the internal services; config from nomad/jobs/traefik/traefik/vpn (task "vpn" only)
#  - wstunnel  carries the wireguard udp over tcp/443 (routed by traefik with SNI passthrough), requires a client certificate, forwards to 127.0.0.1:51820 only
#  - dnsmasq   dns for the VPN clients, on the wg1 address only
#  - wireguard (wireguard = true) a wireguard CLIENT of an uplink, config from nomad/jobs/traefik/traefik/wireguard (task "wireguard" only)
# The tunnels live in the allocation's network namespace: no host service can drop them, and a restart of the allocation rebuilds them. Traefik
# reaches consul and nomad on the node's cluster address instead of 127.0.0.1. Entry points: websecure (public, authelia), vpn (internal, authelia-internal).

variable "user" {
  type        = string
  default     = ""
  description = "user (id) of the traefik container; empty = the image's (root). Set by the deploy (cluster_traefik_uid, default 65532)"
}

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
# <cluster address>:<port> of authelia (https), where the forward-auth middleware calls it. The node is the first of cluster_authelia_hosts.
variable "authelia_addr" {
  type = string
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
variable "internal_zone" {
  type        = string
  description = "the zone of the internal services (<cluster_name>.internal), reachable on the entry point vpn only"
}
variable "authelia_internal_addr" {
  type        = string
  description = "<cluster address>:<port> of authelia-internal (https), where the forward-auth middleware of the entry point vpn calls it"
}
variable "vpn_host" {
  type        = string
  description = "the name (SNI) the VPN clients connect to on the public 443: traefik passes it through to wstunnel"
}
variable "vpn_server_ip" {
  type = string
}
variable "vpn_subnet_prefix" {
  type    = number
  default = 24
}
variable "vpn_wg_port" {
  type    = number
  default = 51820
}
variable "vpn_wstunnel_port" {
  type    = number
  default = 8444
}
variable "vpn_entrypoint_port" {
  type    = number
  default = 8443
}
variable "vpn_wstunnel_user" {
  type    = string
  default = "65532"
}
variable "vpn_admin_net" {
  type        = string
  description = "CIDR of the VPN addresses of people's devices: the only sources of the ops UIs (nomad., consul., traefik.<zone>)"
}
variable "vpn_project_net" {
  type        = string
  description = "CIDR of the VPN addresses of project devices: the only sources of nomad-api. and consul-api.<zone> (token only, no second factor)"
}
variable "wstunnel_image" {
  type = string
}
variable "dnsmasq_image" {
  type = string
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
# Fingerprint of the ingress certificates on the ingress nodes (internal CA mode; made by role cluster_tls, mounted from the node): a renewed
# certificate changes the job and restarts it.
variable "tls_fingerprint" {
  type    = string
  default = ""
}
# step-ca (the always-online intermediate CA, reached through the Consul mesh): the ACME directory of the resolver "stepca" for the names of the
# internal zone ("" = no step-ca: the zone's wildcard certificate from the node is used). The service "traefik-acme" below is the mesh identity of
# this group (the only one step-ca's intentions let in) and gives it the upstream 127.0.0.1:9000 = step-ca.
variable "stepca_acme_url" {
  type    = string
  default = ""
}
variable "stepca_image" {
  type    = string
  default = ""
}
# lifetime of the certificates in hours: traefik renews them at about 2/3 (certificatesDuration)
variable "stepca_cert_hours" {
  type    = number
  default = 168
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

    # the ingress certificate and key (internal CA mode) are made on the ingress node and mounted from it: the key never leaves the node
    dynamic "volume" {
      labels   = ["ingress-tls"]
      for_each = var.tls_resolver == "" ? ["ingress-tls"] : []
      content {
        type      = "host"
        read_only = true
        source    = "ingress-tls"
      }
    }

    # the certificate of the internal zone (wildcard from the ansible intermediate for now) and the key of wstunnel's, each only for its own task
    volume "internal-tls" {
      type      = "host"
      read_only = true
      source    = "internal-tls"
    }
    # wstunnel's certificate: read by wstunnel, renewed in place by the task vpn-renew (step-ca), made first by role cluster_tls / the deploy
    volume "vpn-tls" {
      type      = "host"
      read_only = false
      source    = "vpn-tls"
    }

    network {
      # the allocation's own network: "cni/egress" (internet access, like the host network; nomad's plain "bridge" has none, see group_vars defaults.yml)
      mode = "cni/egress"
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

    # The mesh identity of this group, upstream only: step-ca (127.0.0.1:9000 in the namespace) for traefik's ACME client and the renewal of
    # wstunnel's certificate. Consul's intentions decide who may talk to step-ca (tofu-consul): this service and nobody else. The port is nominal
    # (nothing listens there and no intention lets anybody connect to this service).
    dynamic "service" {
      for_each = var.stepca_acme_url != "" ? ["stepca"] : []
      content {
        name     = "traefik-acme"
        port     = "9"
        provider = "consul"
        tags     = []

        connect {
          sidecar_service {
            proxy {
              upstreams {
                destination_name = "step-ca"
                local_bind_port  = 9000
              }
            }
          }
        }
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

    # ---- the VPN of the internal services (sidecars of the allocation: they share traefik's network namespace) ----------------------------------

    # wireguard SERVER, interface wg1. It listens on udp 51820 in the namespace only (the port is not published), reached by wstunnel over loopback. The
    # namespace's firewall (traefik/vpn.nft.tpl, loaded by PostUp of the config) lets the VPN reach tcp 443 (redirected to traefik's entry point vpn) and dns
    # on the wg1 address, nothing else; ip forwarding is off, so nothing is routed anywhere. The config (private key, one peer with a preshared key per
    # device) is only visible to this task.
    task "vpn" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = true
      }

      template {
        data        = <<EOT
{{ with nomadVar "nomad/jobs/traefik/traefik/vpn" }}{{ .wg_conf }}{{ end }}
EOT
        destination = "secrets/wg/wg1.conf"
        perms       = "0600"
      }

      template {
        data        = file("${var.templates_dir}/vpn.nft.tpl")
        destination = "local/vpn.nft"
        perms       = "0644"
      }

      env {
        TPL_VPN_PORT      = var.vpn_entrypoint_port
        TPL_WSTUNNEL_PORT = var.vpn_wstunnel_port
        TPL_WG_PORT       = var.vpn_wg_port
      }

      config {
        image   = var.wireguard_image
        cap_add = ["net_admin"]
        sysctl = {
          "net.ipv4.conf.all.src_valid_mark" = "1"
          "net.ipv4.ip_forward"              = "0"
          # the namespace is shared by every task of the allocation: traefik, which is not root, binds 80 / 443 because of this (the value of the host
          # does not reach the namespace; docker's own default for it is 0, set here so that nothing depends on the docker version)
          "net.ipv4.ip_unprivileged_port_start" = "80"
        }
        volumes = ["secrets/wg:/config/wg_confs", "local/vpn.nft:/vpn.nft:ro"]
      }

      resources {
        cpu    = 50
        memory = 64
      }
    }

    # Renews wstunnel's certificate (issued by step-ca, 7 days) at about two thirds of its life, in place: wstunnel watches the files and reloads them.
    # It reaches step-ca through the mesh upstream and authenticates with the certificate itself (no secret); the first certificate is issued by
    # the deploy (`step ca certificate` in step-ca's allocation, role cluster_stepca).
    dynamic "task" {
      labels   = ["vpn-renew"]
      for_each = var.stepca_acme_url != "" ? ["vpn-renew"] : []

      content {
        driver = "docker"
        user   = var.vpn_wstunnel_user

        lifecycle {
          hook    = "poststart"
          sidecar = true
        }

        # keeps trying while step-ca is not there (a restart of the node, an upgrade of the job): the certificate lasts a week
        restart {
          attempts = 20
          interval = "30m"
          delay    = "30s"
          mode     = "delay"
        }

        volume_mount {
          volume      = "vpn-tls"
          destination = "/tls"
          read_only   = false
        }

        template {
          data        = "{{ with nomadVar \"nomad/jobs/traefik\" }}{{ .ca_cert }}{{ end }}"
          destination = "secrets/ca.pem"
          perms       = "0644"
          uid         = parseint(var.vpn_wstunnel_user, 10)
          gid         = parseint(var.vpn_wstunnel_user, 10)
        }

        config {
          image      = var.stepca_image
          entrypoint = ["/usr/local/bin/step"]
          args = [
            "ca", "renew", "--daemon",
            "--ca-url", "https://127.0.0.1:9000",
            "--root", "/secrets/ca.pem",
            "--force",
            "/tls/vpn.pem", "/tls/vpn.key",
          ]
          # the binary carries a file capability (net_bind_service): without it in the bounding set the exec fails
          cap_drop        = ["ALL"]
          cap_add         = ["NET_BIND_SERVICE"]
          readonly_rootfs = true
          mount {
            type   = "tmpfs"
            target = "/tmp"
            tmpfs_options {
              size = 8388608
            }
          }
        }

        resources {
          cpu    = 50
          memory = 48
        }
      }
    }

    # wstunnel carries the wireguard udp over a websocket in TLS. Traefik passes the connections for the name vpn_host through to it (SNI, no TLS
    # termination in traefik), it requires a client certificate (mTLS, the cluster root as the CA: `task vpn:client` signs them) and forwards to
    # 127.0.0.1:51820 and nowhere else (--restrict-to). It is a disguise, not the boundary: the boundary is wireguard.
    task "wstunnel" {
      driver = "docker"

      user = var.vpn_wstunnel_user

      lifecycle {
        hook    = "prestart"
        sidecar = true
      }

      volume_mount {
        volume      = "vpn-tls"
        destination = "/tls"
        read_only   = true
      }

      template {
        data        = <<EOT
{{ with nomadVar "nomad/jobs/traefik" }}{{ .ca_cert }}{{ end }}
EOT
        destination = "secrets/ca.pem"
        uid         = parseint(var.vpn_wstunnel_user, 10)
        gid         = parseint(var.vpn_wstunnel_user, 10)
      }

      env {
        RUST_LOG        = "info"
        TLS_FINGERPRINT = var.tls_fingerprint
      }

      config {
        image      = var.wstunnel_image
        entrypoint = ["/home/app/wstunnel"]
        args = [
          "server", "wss://127.0.0.1:${var.vpn_wstunnel_port}",
          "--restrict-to", "127.0.0.1:${var.vpn_wg_port}",
          "--tls-certificate", "/tls/vpn.pem",
          "--tls-private-key", "/tls/vpn.key",
          "--tls-client-ca-certs", "/secrets/ca.pem",
        ]
        cap_drop        = ["ALL"]
        readonly_rootfs = true
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }

    # dns for the VPN clients: *.<zone> and the zone itself resolve to the wg1 address (traefik's), everything else is NXDOMAIN, no recursion. Listens on
    # that address only (bind-dynamic: it appears when the vpn task has brought wg1 up). Not the node's dnsmasq instances: they are host wide.
    task "dnsmasq" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = true
      }

      template {
        data        = <<EOT
no-resolv
no-hosts
pid-file=
user=root
port=53
listen-address=${var.vpn_server_ip}
bind-dynamic
address=/${var.internal_zone}/${var.vpn_server_ip}
local=/#/
EOT
        destination = "local/dnsmasq.conf"
      }

      config {
        image           = var.dnsmasq_image
        entrypoint      = ["dnsmasq"]
        args            = ["-k", "-C", "/local/dnsmasq.conf"]
        cap_drop        = ["ALL"]
        cap_add         = ["NET_BIND_SERVICE", "NET_ADMIN", "SETUID", "SETGID"]
        readonly_rootfs = true
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }

    task "traefik" {
      driver = "docker"

      user = var.user # "" = the image's own user

      volume_mount {
        volume      = "traefik"
        destination = "/acme"
        read_only   = false
      }

      volume_mount {
        volume      = "internal-tls"
        destination = "/tls-internal"
        read_only   = true
      }

      dynamic "volume_mount" {
        for_each = var.tls_resolver == "" ? ["ingress-tls"] : []
        content {
          volume      = "ingress-tls"
          destination = "/tls"
          read_only   = true
        }
      }

      # the cluster CA (public): traefik verifies consul, nomad and authelia with it
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
        # nomad writes templates as root: the task user has to own what it reads (0600)
        uid = var.user == "" ? 0 : parseint(var.user, 10)
        gid = var.user == "" ? 0 : parseint(var.user, 10)
      }

      # authelia, nomad / consul / dashboard behind the authelia forward-auth (the middleware is defined here), TLS options,
      # default certificate (the files of the volume above). Text: traefik/dynamic.yml.tpl
      template {
        data        = file("${var.templates_dir}/dynamic.yml.tpl")
        destination = "secrets/dynamic/cluster.yml"
        perms       = "0600"
        # nomad writes templates as root: the task user has to own what it reads (0600)
        uid = var.user == "" ? 0 : parseint(var.user, 10)
        gid = var.user == "" ? 0 : parseint(var.user, 10)
      }

      # parameters of the templates above (jobs/traefik/*.tpl), read there with {{ env "..." }}
      env {
        TPL_DOMAIN                 = var.domain
        TPL_ZONE                   = var.internal_zone
        TPL_VPN_HOST               = var.vpn_host
        TPL_VPN_PORT               = var.vpn_entrypoint_port
        TPL_VPN_ADMIN_NET          = var.vpn_admin_net
        TPL_VPN_PROJECT_NET        = var.vpn_project_net
        TPL_WSTUNNEL_PORT          = var.vpn_wstunnel_port
        TPL_AUTHELIA_INTERNAL_ADDR = var.authelia_internal_addr
        TPL_AUTHELIA_ADDR          = var.authelia_addr
        TPL_METRICS_PORT           = var.metrics_port
        TPL_CONSUL_PORT            = var.consul_port
        TPL_NOMAD_PORT             = var.nomad_port
        TPL_TLS_RESOLVER           = var.tls_resolver
        TPL_STEPCA_ACME_URL        = var.stepca_acme_url
        TPL_STEPCA_HOURS           = var.stepca_cert_hours
        # lego (traefik's ACME client) trusts the cluster root in addition to the system roots: step-ca's own certificate is signed by it
        LEGO_CA_CERTIFICATES = "/secrets/ca.pem"
        TPL_ACME_SERVER      = var.acme_server
        TPL_ACME_EMAIL       = var.acme_email
        TLS_FINGERPRINT      = var.tls_fingerprint
      }

      config {
        image = var.image
        args  = ["--configFile=/secrets/traefik.yml"]
        # the internet edge: not root, no capability but the one for ports 80 / 443 (a sysctl of the task vpn lets a non-root user bind them),
        # a read-only root filesystem (config, data and certificates are mounts)
        cap_drop        = ["ALL"]
        cap_add         = ["NET_BIND_SERVICE"]
        readonly_rootfs = true
      }

      resources {
        cpu    = 250
        memory = 256
      }
    }
  }
}
