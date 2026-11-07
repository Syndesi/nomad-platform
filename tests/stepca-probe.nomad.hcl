# Negative test (task smoke -- connect): a workload WITHOUT an intention to step-ca must not reach it through the mesh. It binds step-ca as an upstream
# like traefik does; consul's default-deny intentions have to close the connection (no answer to /health and to the ACME directory).
variable "datacenter" {
  type = string
}
job "stepca-probe" {
  datacenters = [var.datacenter]
  type        = "batch"
  group "probe" {
    network { mode = "bridge" }
    service {
      name = "stepca-probe"
      port = "9"
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
    task "curl" {
      driver = "docker"
      config {
        image   = "alpine:3.22"
        command = "sh"
        args    = ["-c", "apk add -q curl >/dev/null 2>&1; sleep 8; echo RESULT; curl -sk --max-time 8 -o /dev/null -D - https://127.0.0.1:9000/health | head -1; echo rc=$?; curl -sk --max-time 8 https://127.0.0.1:9000/acme/acme/directory | head -c 200; echo; echo DONE"]
      }
      resources {
        cpu    = 100
        memory = 64
      }
    }
  }
}
