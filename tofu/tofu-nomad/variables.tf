# Filled by ansible (a tfvars file on tmpfs, role tofu_stage): the cluster parameters keep a single
# home in the cluster repo (inventory/group_vars), and the secrets never touch a disk in clear text.

variable "consul_address" {
  description = "host:port of the consul https api (tunnel)"
  type        = string
}

variable "consul_token" {
  description = "Consul initial_management token"
  type        = string
  sensitive   = true
}

variable "nomad_jwks_url" {
  description = "Where consul fetches the keys that verify nomad workload identities"
  type        = string
}

variable "nomad_address" {
  type = string
}

variable "ca_file" {
  type = string
}

variable "nomad_token" {
  description = "Nomad management token (given to `nomad acl bootstrap` by ansible)"
  type        = string
  sensitive   = true
}

variable "datacenter" {
  type = string
}

variable "traefik_consul_token" {
  description = "The consul token traefik reads the catalog with (output of tofu-consul)"
  type        = string
  sensitive   = true
}

variable "authelia_configuration" {
  type      = string
  sensitive = true
}

variable "authelia_users" {
  type      = string
  sensitive = true
}

variable "task_kv_prefixes" {
  description = "Consul KV prefixes that nomad tasks (workload identity) may read; empty = no KV access"
  type        = list(string)
  default     = []
}
