# step-ca: the always-online intermediate CA of the cluster (its intermediate certificate is signed by the offline root, name-constrained to the
# cluster's domains and <cluster_name>.internal). It issues the short-lived certificates (7 days) of the internal routers (ACME, tls-alpn-01),
# the service certificates (wstunnel) and, through `nomad alloc exec`, the certificates of the VPN devices.
# Never reachable from outside its allocation, except through the Consul service mesh:
#   - it listens on 127.0.0.1:9000 in its own (bridge) network namespace; there is no Nomad port, no host port;
#   - the only way in is its Connect sidecar, and Consul's intentions are deny by default: only the service "traefik-acme" (traefik's group)
#     may connect (tofu-consul);
#   - operators reach it with `nomad alloc exec` (management token), i.e. inside the namespace.
# The dnsmasq next to it is the resolver for the ACME validation (step-ca --resolver): every name in the zone resolves to the ingress node's cluster
# address, where traefik's published 443 answers the tls-alpn-01 challenge.
# Config, keys and password: the Nomad variable nomad/jobs/step-ca (tofu-nomad), rendered into /secrets (not readable through `nomad alloc fs`).
# The database (issued certificates, ACME accounts and orders; no key) is on the host volume "step-ca"; `task backup` copies it.

variable "datacenter" {
  type = string
}
# common variables of every job of the platform (cluster_jobs_common_vars); step-ca does not use these two
variable "domain" {
  type    = string
  default = ""
}
variable "tls_resolver" {
  type    = string
  default = ""
}
variable "image" {
  type = string
}
variable "dnsmasq_image" {
  type = string
}
# the zone (<cluster_name>.internal) and the address its names resolve to for the ACME validation: the ingress node's cluster address
variable "zone" {
  type = string
}
variable "ingress_addr" {
  type = string
}
# host volume (client config of the nomad role): the database
variable "data_volume" {
  type    = string
  default = "step-ca"
}
# the user of the image (step); owns the database folder
variable "user" {
  type    = string
  default = "1000"
}

job "step-ca" {
  datacenters = [var.datacenter]
  type        = "service"

  # only on the nodes that have the volume (client meta stepca = true)
  constraint {
    attribute = "${meta.stepca}"
    value     = "true"
  }

  group "step-ca" {
    network {
      mode = "bridge"
    }

    volume "step-ca" {
      type      = "host"
      read_only = false
      source    = var.data_volume
    }

    update {
      auto_revert = false
    }

    service {
      name     = "step-ca"
      port     = "9000"
      provider = "consul"
      tags     = []

      connect {
        sidecar_service {}
        # runc: envoy is the network heavy part and a hardened, well audited image; the app stays in gVisor (cluster_gvisor_*)
        sidecar_task {
          # default of nomad is 250 MHz; the ingress node is booked out otherwise
          resources {
            cpu    = 100
            memory = 128
          }
          config {
            runtime = "runc"
          }
        }
      }

      # step-ca answers on 127.0.0.1 only: the check runs inside the task
      check {
        type     = "script"
        task     = "step-ca"
        command  = "step"
        args     = ["ca", "health", "--ca-url", "https://127.0.0.1:9000", "--root", "/secrets/root.pem"]
        interval = "15s"
        timeout  = "5s"
      }
    }

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
listen-address=127.0.0.1
bind-interfaces
address=/${var.zone}/${var.ingress_addr}
local=/#/
EOT
        destination = "local/dnsmasq.conf"
      }

      config {
        # runc: dnsmasq subscribes to rtnetlink multicast groups to follow the interfaces, which gVisor does not implement ("cannot create netlink socket")
        runtime         = "runc"
        image           = var.dnsmasq_image
        entrypoint      = ["dnsmasq"]
        args            = ["-k", "-C", "/local/dnsmasq.conf"]
        cap_drop        = ["ALL"]
        cap_add         = ["NET_BIND_SERVICE", "SETUID", "SETGID"]
        readonly_rootfs = true
      }

      resources {
        cpu        = 100
        memory     = 128
        memory_max = 256
      }
    }

    task "step-ca" {
      driver = "docker"

      user = var.user

      volume_mount {
        volume      = "step-ca"
        destination = "/db"
        read_only   = false
      }

      template {
        data        = "{{ with nomadVar \"nomad/jobs/step-ca\" }}{{ .ca_json }}{{ end }}"
        destination = "secrets/ca.json"
        perms       = "0600"
        uid         = parseint(var.user, 10)
        gid         = parseint(var.user, 10)
      }
      template {
        data        = "{{ with nomadVar \"nomad/jobs/step-ca\" }}{{ .root }}{{ end }}"
        destination = "secrets/root.pem"
        perms       = "0644"
        uid         = parseint(var.user, 10)
        gid         = parseint(var.user, 10)
      }
      template {
        data        = "{{ with nomadVar \"nomad/jobs/step-ca\" }}{{ .intermediate }}{{ end }}"
        destination = "secrets/intermediate.pem"
        perms       = "0644"
        uid         = parseint(var.user, 10)
        gid         = parseint(var.user, 10)
      }
      template {
        data        = "{{ with nomadVar \"nomad/jobs/step-ca\" }}{{ .intermediate_key }}{{ end }}"
        destination = "secrets/intermediate.key"
        perms       = "0600"
        uid         = parseint(var.user, 10)
        gid         = parseint(var.user, 10)
      }
      template {
        data        = "{{ with nomadVar \"nomad/jobs/step-ca\" }}{{ .password }}{{ end }}"
        destination = "secrets/password"
        perms       = "0600"
        uid         = parseint(var.user, 10)
        gid         = parseint(var.user, 10)
      }
      # the template of the device certificates (CN only, client auth only)
      template {
        data        = "{{ with nomadVar \"nomad/jobs/step-ca\" }}{{ .client_template }}{{ end }}"
        destination = "secrets/client.tpl"
        perms       = "0644"
        uid         = parseint(var.user, 10)
        gid         = parseint(var.user, 10)
      }

      config {
        image      = var.image
        entrypoint = ["/usr/local/bin/step-ca"]
        args = [
          "/secrets/ca.json",
          "--password-file", "/secrets/password",
          "--resolver", "127.0.0.1:53",
        ]
        # the binary carries a file capability (net_bind_service): without it in the bounding set the exec fails ("operation not permitted")
        cap_drop        = ["ALL"]
        cap_add         = ["NET_BIND_SERVICE"]
        readonly_rootfs = true
        mount {
          type   = "tmpfs"
          target = "/tmp"
          tmpfs_options {
            size = 16777216
          }
        }
      }

      resources {
        cpu        = 500
        memory     = 256
        memory_max = 512
      }
    }
  }
}
