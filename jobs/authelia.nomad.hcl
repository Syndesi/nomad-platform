# Authelia: the forward-auth in front of nomad / consul / traefik, with a second factor (TOTP).
# Config and users live in the Nomad variable nomad/jobs/authelia (written by ansible role cluster_jobs from
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
  datacenters = [var.datacenter]
  type        = "service"

  constraint {
    attribute = "${meta.authelia}"
    value     = "true"
  }

  group "authelia" {
    network {
      port "http" {
        static = 9091
      }
    }

    volume "authelia" {
      type      = "host"
      read_only = false
      source    = "authelia"
    }

    # the server certificate of authelia (https), made on the node: the key never leaves it
    volume "authelia-tls" {
      type      = "host"
      read_only = true
      source    = "authelia-tls"
    }

    update {
      auto_revert = false
    }

    service {
      name     = "authelia"
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
        tls_server_name = "authelia.service.consul"
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
{{ with nomadVar "nomad/jobs/authelia" }}{{ .configuration }}{{ end }}
EOT
        destination = "secrets/configuration.yml"
        perms       = "0600"
        # nomad writes templates as root: hand them to the task user
        uid = var.user == "" ? 0 : parseint(var.user, 10)
        gid = var.user == "" ? 0 : parseint(var.user, 10)
      }

      template {
        data        = <<EOT
{{ with nomadVar "nomad/jobs/authelia" }}{{ .users }}{{ end }}
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
