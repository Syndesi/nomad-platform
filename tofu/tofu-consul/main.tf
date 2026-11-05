provider "consul" {
  address    = var.consul_address
  scheme     = "https"
  datacenter = var.datacenter
  ca_file    = var.ca_file
  token      = var.consul_token
}

# ---- consul: policies -------------------------------------------------------------------------

resource "consul_acl_policy" "traefik" {
  name        = "traefik"
  description = "traefik consulCatalog provider (read only)"
  rules       = <<-EOT
    agent_prefix "" { policy = "read" }
    node_prefix "" { policy = "read" }
    service_prefix "" { policy = "read" }
  EOT
}

resource "consul_acl_policy" "nomad_agent" {
  name        = "nomad-agent"
  description = "nomad agents register themselves as services"
  rules       = <<-EOT
    agent_prefix "" { policy = "read" }
    node_prefix "" { policy = "read" }
    service_prefix "" { policy = "write" }
  EOT
}

# Consul DNS: every agent answers dns queries with this token (acl.tokens.dns in its config), so the anonymous token
# (what a request without a token gets) has no policy at all: no token, no access.
resource "consul_acl_policy" "dns" {
  name        = "dns"
  description = "consul dns lookups (acl.tokens.dns of the agents)"
  rules       = <<-EOT
    node_prefix "" { policy = "read" }
    service_prefix "" { policy = "read" }
    query_prefix "" { policy = "read" }
  EOT
}

# ---- consul: tokens ---------------------------------------------------------------------------

# One node-identity token per node = the agent token in that node's consul config.
resource "consul_acl_token" "agent" {
  for_each    = toset(var.nodes)
  description = "agent ${each.key}"

  node_identities {
    node_name  = each.key
    datacenter = var.datacenter
  }
}

resource "consul_acl_token" "service" {
  for_each = {
    traefik     = "traefik"
    nomad-agent = "nomad-agent"
    readonly    = "builtin/global-read-only"
    dns         = "dns"
  }
  description = "${each.key} (managed by opentofu)"
  policies    = [each.value]
  depends_on  = [consul_acl_policy.traefik, consul_acl_policy.nomad_agent, consul_acl_policy.dns]
}

data "consul_acl_token_secret_id" "agent" {
  for_each    = consul_acl_token.agent
  accessor_id = each.value.id
}

data "consul_acl_token_secret_id" "service" {
  for_each    = consul_acl_token.service
  accessor_id = each.value.id
}

# ---- tokens: sensitive outputs ----------------------------------------------------------------------
# They live in the (client-side encrypted) state and nowhere else; ansible reads them with
# `tofu output -json` when it renders the agent configs.
