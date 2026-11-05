# Test job for `task smoke -- connect`, not part of the deployment: two services with envoy sidecars
# (consul connect), count-api and a client that reaches it through the mesh on localhost:9001.
# Needs: cni plugins + bridge netfilter on the client, the grpc/tls port of the local consul agent,
# the consul binary on the client, docker for the sidecar image, and an intention client -> count-api.

variable "datacenter" {
  type = string
}

job "connect-test" {
  datacenters = [var.datacenter]
  type        = "service"

  group "api" {
    network {
      mode = "bridge"
    }

    service {
      name = "count-api"
      port = "9001"

      connect {
        sidecar_service {}
      }
    }

    task "api" {
      driver = "docker"

      config {
        image = "hashicorpdev/counter-api:v3"
      }
    }
  }

  group "client" {
    network {
      mode = "bridge"
    }

    service {
      name = "count-client"

      connect {
        sidecar_service {
          proxy {
            upstreams {
              destination_name = "count-api"
              local_bind_port  = 9001
            }
          }
        }
      }
    }

    task "client" {
      driver = "docker"

      config {
        image   = "busybox:1.37"
        command = "sh"
        args    = ["-c", "while true; do sleep 3600; done"]
      }
    }
  }
}
