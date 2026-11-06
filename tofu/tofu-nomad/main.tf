locals {
  ca_pem = file(var.ca_file)
}

provider "consul" {
  address    = var.consul_address
  scheme     = "https"
  datacenter = var.datacenter
  ca_file    = var.ca_file
  token      = var.consul_token
}

provider "nomad" {
  address   = var.nomad_address
  ca_file   = var.ca_file
  secret_id = var.nomad_token
}

# ---- consul <-> nomad workload identity (what `nomad setup consul` does) -------------------------
# Needs a running nomad: consul fetches the JWKS url when the auth method is created. The consul
# side of the agents (policies, tokens) is the earlier stage, tofu-consul.

# Policy of the role that tasks get when they log in with their workload identity.
resource "consul_acl_policy" "nomad_tasks" {
  name        = "policy-nomad-tasks"
  description = "nomad tasks (workload identity): read the catalog, and the kv prefixes the cluster lists (none by default)"
  rules = join("\n", concat(
    [
      "node_prefix \"\" { policy = \"read\" }",
      "service_prefix \"\" { policy = \"read\" }",
    ],
    [for p in var.task_kv_prefixes : "key_prefix \"${p}\" { policy = \"read\" }"],
  ))
}

resource "consul_acl_auth_method" "nomad_workloads" {
  name           = "nomad-workloads"
  type           = "jwt"
  display_name   = "nomad-workloads"
  description    = "Login method for Nomad workloads using workload identities"
  token_locality = "local"

  config_json = jsonencode({
    JWKSURL          = var.nomad_jwks_url
    JWKSCACert       = local.ca_pem
    JWTSupportedAlgs = ["RS256"]
    BoundAudiences   = ["consul.io"]
    ClaimMappings = {
      nomad_namespace  = "nomad_namespace"
      nomad_job_id     = "nomad_job_id"
      nomad_task       = "nomad_task"
      nomad_service    = "nomad_service"
      consul_namespace = "consul_namespace"
    }
  })
}

resource "consul_acl_role" "nomad_tasks" {
  name        = "nomad-default-tasks"
  description = "Role for Nomad tasks using workload identities"
  policies    = [consul_acl_policy.nomad_tasks.name]
}

resource "consul_acl_binding_rule" "services" {
  auth_method = consul_acl_auth_method.nomad_workloads.name
  description = "Binding rule for Nomad services authenticated using a workload identity"
  selector    = "\"nomad_service\" in value"
  bind_type   = "service"
  bind_name   = "$${value.nomad_service}"
}

resource "consul_acl_binding_rule" "tasks" {
  auth_method = consul_acl_auth_method.nomad_workloads.name
  description = "Binding rule for Nomad tasks authenticated using a workload identity"
  selector    = "\"nomad_service\" not in value"
  bind_type   = "role"
  # one role for the tasks of every nomad namespace (a role per namespace would have to exist before its first task logs in)
  bind_name  = consul_acl_role.nomad_tasks.name
  depends_on = [consul_acl_role.nomad_tasks]
}

# ---- nomad acl -----------------------------------------------------------------------------------

resource "nomad_acl_policy" "deployer" {
  name        = "deployer"
  description = "ansible / ci - run jobs and write the nomad variables they read"
  rules_hcl   = <<-EOT
    namespace "*" {
      policy = "write"
      variables {
        path "nomad/jobs/*" { capabilities = ["read", "write", "list", "destroy"] }
        # written by tofu-nomad with the management token: authelia's config (session secret, storage key, password hashes) and traefik's
        # tokens. The deployer neither reads nor changes them (the more specific path wins over the glob above).
        path "nomad/jobs/authelia" { capabilities = ["deny"] }
        path "nomad/jobs/traefik" { capabilities = ["deny"] }
      }
    }
    host_volume "*" { policy = "write" }
    node { policy = "read" }
    agent { policy = "read" }
  EOT
}

resource "nomad_acl_policy" "readonly" {
  name        = "readonly"
  description = "look but do not touch"
  rules_hcl   = <<-EOT
    namespace "*" { policy = "read" }
    node { policy = "read" }
    agent { policy = "read" }
  EOT
}

# What traefik adds to requests that come through authelia and carry no nomad token of their own (the web ui: nodes and jobs, nothing
# else). There is no "anonymous" policy: a request without a token gets nothing, whoever sends it.
resource "nomad_acl_policy" "ui" {
  name        = "ui"
  description = "fallback of the web ui behind authelia: look at nodes and jobs (no logs, variables, exec, changes)"
  rules_hcl   = <<-EOT
    namespace "*" { capabilities = ["list-jobs", "read-job"] }
    node { policy = "read" }
  EOT
}

resource "nomad_acl_token" "client" {
  for_each = {
    deployer = nomad_acl_policy.deployer.name
    readonly = nomad_acl_policy.readonly.name
    ui       = nomad_acl_policy.ui.name
  }
  name     = "${var.datacenter}-${each.key}"
  type     = "client"
  policies = [each.value]
}

# ---- nomad variables: job config and secrets (the jobs themselves are run with `nomad job run`) ----

resource "nomad_variable" "authelia" {
  path = "nomad/jobs/authelia"
  items = {
    configuration = var.authelia_configuration
    users         = var.authelia_users
  }
}

resource "nomad_variable" "traefik" {
  path = "nomad/jobs/traefik"
  items = {
    consul_token = var.traefik_consul_token
    # the nomad token traefik adds for web ui requests without one (policy "ui")
    nomad_ui_token = nomad_acl_token.client["ui"].secret_id
    # public; the job renders it into the task, so no host path has to be mounted
    ca_cert = local.ca_pem
  }
}
