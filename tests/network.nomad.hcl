# Test job for `task smoke`, not part of the deployment: one container of each kind on every client node, to check what containers can reach.
#   bridge: nomad's bridge (and docker0): no internet, no public dns
#   egress: the network with internet access (mode = "cni/egress"): both

variable "datacenter" {
  type = string
}

variable "clients" {
  type = number
}

job "network-test" {
  datacenters = [var.datacenter]
  type        = "service"

  group "bridge" {
    count = var.clients

    constraint {
      operator = "distinct_hosts"
      value    = "true"
    }

    network {
      mode = "bridge"
    }

    task "t" {
      driver = "docker"

      config {
        image   = "busybox:1.37"
        command = "sh"
        args    = ["-c", "while true; do sleep 3600; done"]
      }
    }
  }

  group "egress" {
    count = var.clients

    constraint {
      operator = "distinct_hosts"
      value    = "true"
    }

    network {
      mode = "cni/egress"
    }

    task "t" {
      driver = "docker"

      config {
        image   = "busybox:1.37"
        command = "sh"
        args    = ["-c", "while true; do sleep 3600; done"]
      }
    }
  }
}
