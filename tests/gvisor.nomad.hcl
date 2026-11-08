# Test job for `task smoke`, not part of the deployment: one container per docker runtime on every client node, to check what the runtimes do.
#   default: no `runtime` in the task, nomad's bridge: the cluster's default (runsc-host unless cluster_gvisor_default_runtime says otherwise)
#   runc:    the opt-out, `runtime = "runc"`
#   strict:  `runtime = "runsc"` (gVisor with its own network stack) on docker's bridge: a single container task, no nomad network namespace, no sidecars

variable "datacenter" {
  type = string
}

variable "clients" {
  type = number
}

job "gvisor-test" {
  datacenters = [var.datacenter]
  type        = "service"

  group "default" {
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

  group "runc" {
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
        runtime = "runc"
        image   = "busybox:1.37"
        command = "sh"
        args    = ["-c", "while true; do sleep 3600; done"]
      }
    }
  }

  group "strict" {
    count = var.clients

    constraint {
      operator = "distinct_hosts"
      value    = "true"
    }

    task "t" {
      driver = "docker"

      config {
        runtime      = "runsc"
        network_mode = "bridge"
        image        = "busybox:1.37"
        command      = "sh"
        args         = ["-c", "while true; do sleep 3600; done"]
      }
    }
  }
}
