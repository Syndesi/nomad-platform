# The databases of both Authelia instances (authelia, authelia-internal): ONE Postgres with two databases (and two users, each only on its own) for the
# storage (second factors, devices, bans) and ONE Redis for the sessions (database 0 = authelia, 1 = authelia-internal). Both run on runc, outside gVisor:
# real file locking and shared memory for the database, and `pg_dump` (task backup) reads a consistent snapshot while Authelia keeps running.
# They are reachable through the Consul mesh only (services authelia-postgres / authelia-redis, sidecars on runc): the databases listen on 127.0.0.1 of this
# allocation. Intentions (tofu-consul): only the mesh services of the two Authelia jobs may connect. Both also need their password.
# Runs on the node of Authelia (client meta authelia = true): the data is in the host volume "authelia-db" (nomad role). Redis keeps nothing on disk:
# a restart of Redis logs everybody out, the second factors are in Postgres. Secrets: Nomad variable nomad/jobs/authelia-db (tofu-nomad), as files.

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
variable "postgres_image" {
  type = string
}
variable "redis_image" {
  type = string
}
variable "uid_postgres" {
  type    = string
  default = "70"
}
variable "uid_redis" {
  type    = string
  default = "999"
}
variable "postgres_port" {
  type    = number
  default = 5432
}
variable "redis_port" {
  type    = number
  default = 6379
}

job "authelia-db" {
  datacenters = [var.datacenter]
  type        = "service"

  constraint {
    attribute = "${meta.authelia}"
    value     = "true"
  }

  group "authelia-db" {
    network {
      mode = "bridge"
    }

    update {
      auto_revert      = true
      min_healthy_time = "10s"
    }

    volume "authelia-db" {
      type      = "host"
      read_only = false
      source    = "authelia-db"
    }

    service {
      name     = "authelia-postgres"
      port     = "${var.postgres_port}"
      provider = "consul"
      tags     = []
      connect {
        sidecar_service {}
        # runc: envoy is the network heavy part and a hardened, well audited image
        sidecar_task {
          resources {
            cpu    = 100
            memory = 128
          }
          config {
            runtime = "runc"
          }
        }
      }
    }
    service {
      name     = "authelia-redis"
      port     = "${var.redis_port}"
      provider = "consul"
      tags     = []
      connect {
        sidecar_service {}
        sidecar_task {
          resources {
            cpu    = 100
            memory = 128
          }
          config {
            runtime = "runc"
          }
        }
      }
    }
    # health: the databases answer inside their own containers
    service {
      name     = "authelia-db"
      provider = "consul"
      tags     = []
      check {
        type     = "script"
        task     = "postgres"
        command  = "pg_isready"
        args     = ["-h", "127.0.0.1", "-p", "${var.postgres_port}"]
        interval = "30s"
        timeout  = "5s"
      }
    }

    task "postgres" {
      driver = "docker"
      user   = var.uid_postgres

      volume_mount {
        volume      = "authelia-db"
        destination = "/var/lib/postgresql/data"
      }

      # files, not environment variables: the environment of a container is visible in `docker inspect` (and the docker api that vector reads)
      template {
        data        = "{{ with nomadVar \"nomad/jobs/authelia-db\" }}{{ .postgres_password }}{{ end }}"
        destination = "secrets/postgres_password"
        perms       = "0400"
        uid         = parseint(var.uid_postgres, 10)
        gid         = parseint(var.uid_postgres, 10)
      }
      # runs once, when the data directory is empty (initdb): the two databases and their owners. The passwords are hex strings.
      template {
        data        = <<-EOT
          #!/bin/sh
          set -e
          {{ with nomadVar "nomad/jobs/authelia-db" -}}
          psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<'SQL'
          CREATE ROLE authelia LOGIN PASSWORD '{{ .authelia_password }}';
          CREATE DATABASE authelia OWNER authelia;
          CREATE ROLE authelia_internal LOGIN PASSWORD '{{ .authelia_internal_password }}';
          CREATE DATABASE authelia_internal OWNER authelia_internal;
          REVOKE ALL ON DATABASE authelia FROM PUBLIC;
          REVOKE ALL ON DATABASE authelia_internal FROM PUBLIC;
          SQL
          {{- end }}
        EOT
        destination = "secrets/10-authelia.sh"
        perms       = "0500"
        uid         = parseint(var.uid_postgres, 10)
        gid         = parseint(var.uid_postgres, 10)
      }
      env {
        POSTGRES_PASSWORD_FILE = "/secrets/postgres_password"
        POSTGRES_USER          = "postgres"
        PGDATA                 = "/var/lib/postgresql/data/pgdata"
      }

      config {
        # runc: a database from an official image without network access except the mesh (see the header)
        runtime         = "runc"
        image           = var.postgres_image
        args            = ["-c", "listen_addresses=127.0.0.1", "-c", "port=${var.postgres_port}", "-c", "max_connections=30", "-c", "shared_buffers=32MB"]
        volumes         = ["secrets/10-authelia.sh:/docker-entrypoint-initdb.d/10-authelia.sh:ro"]
        cap_drop        = ["ALL"]
        readonly_rootfs = true
        mount {
          type   = "tmpfs"
          target = "/tmp"
          tmpfs_options {
            size = 16777216
          }
        }
        mount {
          type   = "tmpfs"
          target = "/var/run/postgresql"
          tmpfs_options {
            size = 1048576
          }
        }
      }

      resources {
        cpu        = 300
        memory     = 192
        memory_max = 384
      }
    }

    task "redis" {
      driver = "docker"
      user   = var.uid_redis

      template {
        data        = <<-EOT
          bind 127.0.0.1
          port ${var.redis_port}
          protected-mode yes
          {{ with nomadVar "nomad/jobs/authelia-db" }}requirepass {{ .redis_password }}{{ end }}
          # sessions only, nothing on disk
          save ""
          appendonly no
          dir /tmp
          maxmemory 64mb
          maxmemory-policy volatile-lru
        EOT
        destination = "secrets/redis.conf"
        perms       = "0400"
        uid         = parseint(var.uid_redis, 10)
        gid         = parseint(var.uid_redis, 10)
      }

      config {
        runtime         = "runc"
        image           = var.redis_image
        args            = ["/secrets/redis.conf"]
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
        cpu        = 100
        memory     = 64
        memory_max = 128
      }
    }
  }
}
