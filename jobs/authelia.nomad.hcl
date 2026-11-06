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
      tags = concat([
        "traefik.enable=true",
        "traefik.http.routers.authelia.rule=Host(`auth.${var.domain}`)",
        "traefik.http.routers.authelia.entrypoints=websecure",
        "traefik.http.routers.authelia.tls=true",
        # an ops name: hybrid post-quantum key exchange only, see traefik/dynamic.yml.tpl
        "traefik.http.routers.authelia.tls.options=pq-only@file",
        "traefik.http.routers.authelia.service=authelia",
        "traefik.http.services.authelia.loadbalancer.server.scheme=https",
        "traefik.http.services.authelia.loadbalancer.serversTransport=cluster-ca@file",
        # The forward-auth middleware lives with the service, so it follows authelia wherever it
        # runs and disappears (routes using it stop answering) when authelia is down.
        # $${...} stays literal in HCL; nomad fills in the real address when it registers the tags.
        # authelia serves https with the node's certificate (names: the cluster address among them); traefik verifies it with the cluster CA
        "traefik.http.middlewares.authelia.forwardAuth.address=https://$${NOMAD_ADDR_http}/api/authz/forward-auth",
        "traefik.http.middlewares.authelia.forwardAuth.tls.ca=/secrets/ca.pem",
        "traefik.http.middlewares.authelia.forwardAuth.trustForwardHeader=true",
        # only what authelia needs: the session cookie, the forwarding headers and Accept / X-Requested-With (without them authelia answers 401 instead of a redirect). By default traefik copies ALL request headers, i.e. also
        # X-Nomad-Token / X-Consul-Token of command line tools, to authelia (plain http, possibly another node).
        "traefik.http.middlewares.authelia.forwardAuth.authRequestHeaders=Cookie,Accept,X-Requested-With,X-Forwarded-For,X-Forwarded-Proto,X-Forwarded-Host,X-Forwarded-Uri,X-Forwarded-Method",
        "traefik.http.middlewares.authelia.forwardAuth.authResponseHeaders=Remote-User,Remote-Groups,Remote-Name,Remote-Email",
        ], var.tls_resolver != "" ? [
        "traefik.http.routers.authelia.tls.certresolver=${var.tls_resolver}",
      ] : [])

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
