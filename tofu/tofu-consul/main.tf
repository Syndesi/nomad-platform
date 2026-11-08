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
    # What the controller works with (tofu, backup, restore) once the bootstrap token (`initial_management`) is handed over and deleted
    # (role consul, tasks handover). Same power; the difference is that its secret is in no config file of any node.
    ops = "global-management"
    dns = "dns"
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

# ---- projects (docs/projects.md): a consul token for those that ask for one (consul_rules = the policy, HCL) -----------
locals {
  consul_projects = { for k, v in var.projects : k => v if trimspace(v.consul_rules) != "" }
}

resource "consul_acl_policy" "project" {
  for_each    = local.consul_projects
  name        = "project-${each.key}"
  description = "project ${each.key} (managed by opentofu)"
  rules       = each.value.consul_rules
}

resource "consul_acl_token" "project" {
  for_each    = local.consul_projects
  description = "project ${each.key} (managed by opentofu)"
  policies    = [consul_acl_policy.project[each.key].name]
}

data "consul_acl_token_secret_id" "project" {
  for_each    = consul_acl_token.project
  accessor_id = each.value.id
}

# ---- tokens: sensitive outputs ----------------------------------------------------------------------
# They live in the (client-side encrypted) state and nowhere else; ansible reads them with
# `tofu output -json` when it renders the agent configs.

# ---- consul connect: intentions (default deny) -------------------------------------------------
# step-ca is reachable through the mesh only. Only the service "traefik-acme" (traefik's group: its ACME client and the renewal of the service
# certificates) may connect; everything else is denied by the explicit "*" source, whatever the ACL default policy is.
resource "consul_config_entry" "stepca_intentions" {
  count = var.stepca_enabled ? 1 : 0
  name  = "step-ca"
  kind  = "service-intentions"
  config_json = jsonencode({
    Sources = [
      { Name = "traefik-acme", Action = "allow", Precedence = 9 },
      { Name = "*", Action = "deny", Precedence = 1 },
    ]
  })
}
