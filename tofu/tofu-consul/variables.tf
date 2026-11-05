# All values come from ansible (role cluster_tofu writes secrets/generated/cluster.auto.tfvars.json),
# so there is exactly one place that knows the cluster parameters: ansible/inventory/group_vars.

variable "consul_address" {
  description = "host:port of a consul server https api (the tunnel, see scripts/tunnel.sh)"
  type        = string
}

variable "ca_file" {
  description = "Cluster CA, trusted for both apis"
  type        = string
}

variable "consul_token" {
  description = "Consul initial_management token (pre-generated, so no acl bootstrap race)"
  type        = string
  sensitive   = true
}

variable "datacenter" {
  type = string
}

variable "nodes" {
  description = "Every cluster node name: each gets a consul agent token (node identity)"
  type        = list(string)
}
