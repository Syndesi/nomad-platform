# Authelia: the forward-auth in front of nomad / consul / traefik, with a second factor (TOTP).
# Config and users live in the Nomad variable nomad/jobs/authelia (written by ansible role cluster_jobs from
# the cluster's authelia.yml + secrets), so no secret is part of this spec.
# The sqlite database (totp secrets, devices, bans) is on the host volume "authelia" (/srv/authelia on the node, made by the nomad role),
# so the job is bound to the nodes that have it (client meta authelia = true: the servers by default) and survives redeployments.
# The rendered config (session secret, storage key, password hashes) goes to secrets/ (not readable through `nomad alloc fs`), mode 0600.
# Port 9091 (https) is published on the node's cluster address; the firewall's forward chain drops it for everything outside the cluster.
# Backed up by `task backup`. Never run it with auto_revert: a failed upgrade may already have migrated the database, and an older image
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
        # the check comes from the node itself to its own address; the certificate is checked where it matters (traefik)
        tls_skip_verify = true
        path            = "/api/health"
        interval        = "10s"
        timeout         = "3s"
      }
    }

    task "authelia" {
      driver = "docker"

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
        destination = "secrets/config/configuration.yml"
        perms       = "0600"
      }

      template {
        data        = <<EOT
{{ with nomadVar "nomad/jobs/authelia" }}{{ .users }}{{ end }}
EOT
        destination = "secrets/config/users.yml"
        perms       = "0600"
      }

      config {
        image   = var.image
        ports   = ["http"]
        volumes = ["secrets/config:/config"]
      }

      resources {
        cpu    = 250
        memory = 256
      }
    }
  }
}
