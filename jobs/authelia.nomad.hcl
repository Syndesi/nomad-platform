# Authelia: the forward-auth in front of nomad / consul / traefik, with a second factor (TOTP).
# Config and users live in the Nomad variable nomad/jobs/authelia (written by ansible role cluster_jobs from
# the cluster's authelia.yml + secrets), so no secret is part of this spec.
# The sqlite database (totp secrets, devices, bans) is on the host volume "authelia" (/srv/authelia on the node, made by the nomad role),
# so the job is bound to the nodes that have it (client meta authelia = true: the servers by default) and survives redeployments.
# The rendered config (session secret, storage key, password hashes) goes to secrets/ (not readable through `nomad alloc fs`), mode 0600.
# Port 9091 is published on the node's cluster address; the firewall's forward chain drops it for everything outside the cluster.
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

    update {
      auto_revert = false
    }

    service {
      name     = "authelia"
      port     = "http"
      provider = "consul"
      tags = concat([
        "traefik.enable=true",
        "traefik.http.routers.authelia.rule=Host(`auth.${var.domain}`)",
        "traefik.http.routers.authelia.entrypoints=websecure",
        "traefik.http.routers.authelia.tls=true",
        # the portal under the name of the local proxy (auth-cli): hybrid post-quantum key exchange only, see traefik/dynamic.yml.tpl
        "traefik.http.routers.authelia-cli.rule=Host(`auth-cli.${var.domain}`)",
        "traefik.http.routers.authelia-cli.entrypoints=websecure",
        "traefik.http.routers.authelia-cli.tls=true",
        "traefik.http.routers.authelia-cli.tls.options=pq-only@file",
        "traefik.http.routers.authelia-cli.service=authelia",
        "traefik.http.routers.authelia.service=authelia",
        # The forward-auth middleware lives with the service, so it follows authelia wherever it
        # runs and disappears (routes using it stop answering) when authelia is down.
        # $${...} stays literal in HCL; nomad fills in the real address when it registers the tags.
        "traefik.http.middlewares.authelia.forwardAuth.address=http://$${NOMAD_ADDR_http}/api/authz/forward-auth",
        "traefik.http.middlewares.authelia.forwardAuth.trustForwardHeader=true",
        # only what authelia needs: the session cookie, the forwarding headers and Accept / X-Requested-With (without them authelia answers 401 instead of a redirect). By default traefik copies ALL request headers, i.e. also
        # X-Nomad-Token / X-Consul-Token of the cli proxy, to authelia (plain http, possibly another node).
        "traefik.http.middlewares.authelia.forwardAuth.authRequestHeaders=Cookie,Accept,X-Requested-With,X-Forwarded-For,X-Forwarded-Proto,X-Forwarded-Host,X-Forwarded-Uri,X-Forwarded-Method",
        "traefik.http.middlewares.authelia.forwardAuth.authResponseHeaders=Remote-User,Remote-Groups,Remote-Name,Remote-Email",
        ], var.tls_resolver != "" ? [
        "traefik.http.routers.authelia.tls.certresolver=${var.tls_resolver}",
        "traefik.http.routers.authelia-cli.tls.certresolver=${var.tls_resolver}",
      ] : [])

      check {
        type     = "http"
        path     = "/api/health"
        interval = "10s"
        timeout  = "3s"
      }
    }

    task "authelia" {
      driver = "docker"

      volume_mount {
        volume      = "authelia"
        destination = "/data"
        read_only   = false
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
