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
  description = "A Nomad management token: the ops token, or the bootstrap token (given to `nomad acl bootstrap` by ansible) until it is handed over"
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

variable "authelia_internal_configuration" {
  type      = string
  sensitive = true
}

variable "authelia_internal_users" {
  type      = string
  sensitive = true
}

variable "vpn_wg_conf" {
  description = "wg-quick config of the VPN server in traefik's allocation (private key and the peers with their preshared keys)"
  type        = string
  sensitive   = true
}

variable "task_kv_prefixes" {
  description = "Consul KV prefixes that nomad tasks (workload identity) may read; empty = no KV access"
  type        = list(string)
  default     = []
}

variable "stepca_items" {
  description = "items of the nomad variable nomad/jobs/step-ca (ca.json, root, intermediate and its encrypted key, password, template); empty = no step-ca"
  type        = map(string)
  sensitive   = true
  default     = {}
}
