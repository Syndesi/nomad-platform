terraform {
  required_version = ">= 1.9"

  # State lives in the cluster repo: path and plugin dir come from the caller (role tofu_stage, scripts/tofu-enc.sh)
  backend "local" {}

  required_providers {
    consul = {
      source  = "hashicorp/consul"
      version = "~> 2.22"
    }
  }
}
