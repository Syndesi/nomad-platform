# Authelia: the forward-auth with a second factor (TOTP). Run twice (cluster_jobs_list): "authelia" for the public names (port 9091) and
# "authelia-internal" for the zone behind the VPN (port 9092, variables name / port / data_volume / tls_volume): own config, secrets, database,
# TOTP seeds and bans. The text below says "authelia" for either.
# Config and users live in the Nomad variable nomad/jobs/<name> (written by tofu-nomad from
# the cluster's authelia.yml + secrets), so no secret is part of this spec.
# The sqlite database (totp secrets, devices, bans) is on the host volume "authelia" (/srv/authelia on the node, made by the nomad role),
# so the job is bound to the nodes that have it (client meta authelia = true: the servers by default) and survives redeployments.
# The rendered config (session secret, storage key, password hashes) goes to secrets/ (mounted as /secrets, not readable through `nomad alloc fs`), mode 0600.
# Port 9091 (https) is published on the node's cluster address; the firewall's forward chain drops it for everything outside the cluster.
# Hardened like traefik: not root (variable user: the id owns the database folder and the key), all capabilities dropped, a read-only root
# filesystem. Backed up by `task backup`. Never run it with auto_revert: a failed upgrade may already have migrated the database, and an older image
# cannot read a newer schema.

variable "datacenter" {
  type = string
}
variable "image" {
  type = string
}
variable "domain" {
  type = string
}
# job and service name, and the Nomad variable (nomad/jobs/<name>) with the config
variable "name" {
  type    = string
  default = "authelia"
}
variable "port" {
  type    = number
  default = 9091
}
# host volumes (client config, fragment 55-authelia.hcl): the database folder and the folder with the certificate
variable "data_volume" {
  type    = string
  default = "authelia"
}
variable "tls_volume" {
  type    = string
  default = "authelia-tls"
}
# The user id authelia runs as (it owns the database folder and reads its key); "" = the image's own user (root)
variable "user" {
  type    = string
  default = ""
}
# Fingerprint of the server certificates of the authelia nodes (made by role cluster_tls, mounted from the node): authelia reads its
# certificate when it starts, so a renewed one has to change the job (this variable) to restart it.
variable "tls_fingerprint" {
  type    = string
  default = ""
}
# "" = certs come from the cluster CA (traefik default cert), otherwise name of the ACME resolver
variable "tls_resolver" {
  type    = string
  default = ""
}

job "authelia" {
  id          = var.name
  name        = var.name
  datacenters = [var.datacenter]
  type        = "service"

  constraint {
    attribute = "${meta.authelia}"
    value     = "true"
  }

  group "authelia" {
    network {
      port "http" {
        static = var.port
      }
    }

    volume "authelia" {
      type      = "host"
      read_only = false
      source    = var.data_volume
    }

    # the server certificate of authelia (https), made on the node: the key never leaves it
    volume "authelia-tls" {
      type      = "host"
      read_only = true
      source    = var.tls_volume
    }

    update {
      auto_revert = false
    }

    service {
      name     = var.name
      port     = "http"
      provider = "consul"
      # No traefik tags on purpose: the router, the forward-auth middleware and the service of authelia are in traefik's file provider
      # (jobs/traefik/dynamic.yml.tpl). Tags are written by whoever submits a job and must not define the login portal or the middleware.
      tags = []

      check {
        type     = "http"
        protocol = "https"
        # the check is made by the consul agent of the node, which verifies the certificate with the system roots (role cluster_tls puts the cluster CA there); the
        # address is the node's, the name is one of the names in the certificate
        tls_server_name = "${var.name}.service.consul"
        path            = "/api/health"
        interval        = "10s"
        timeout         = "3s"
      }
    }

    task "authelia" {
      driver = "docker"

      user = var.user # "" = the image's own user

      volume_mount {
        volume      = "authelia"
        destination = "/data"
        read_only   = false
      }

      volume_mount {
        volume      = "authelia-tls"
        destination = "/tls"
        read_only   = true
      }

      env {
        TLS_FINGERPRINT = var.tls_fingerprint
      }

      template {
        data        = <<EOT
{{ with nomadVar "nomad/jobs/${var.name}" }}{{ .configuration }}{{ end }}
EOT
        destination = "secrets/configuration.yml"
        perms       = "0600"
        # nomad writes templates as root: hand them to the task user
        uid = var.user == "" ? 0 : parseint(var.user, 10)
        gid = var.user == "" ? 0 : parseint(var.user, 10)
      }

      template {
        data        = <<EOT
{{ with nomadVar "nomad/jobs/${var.name}" }}{{ .users }}{{ end }}
EOT
        destination = "secrets/users.yml"
        perms       = "0600"
        # nomad writes templates as root: hand them to the task user
        uid = var.user == "" ? 0 : parseint(var.user, 10)
        gid = var.user == "" ? 0 : parseint(var.user, 10)
      }

      config {
        image   = var.image
        ports   = ["http"]
        # the rendered files are in the task's secrets directory (/secrets), which nomad hands to the task user; a subdirectory would be root's
        args = ["--config", "/secrets/configuration.yml"]
        # nothing but its own files: no capability (port 9091 needs none), a read-only root filesystem (config, database and certificate
        # are mounts, /tmp a small tmpfs)
        cap_drop        = ["ALL"]
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
        cpu    = 250
        memory = 256
      }
    }
  }
}
