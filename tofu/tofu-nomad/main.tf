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
        path "nomad/jobs/authelia-internal" { capabilities = ["deny"] }
        path "nomad/jobs/traefik" { capabilities = ["deny"] }
        path "nomad/jobs/step-ca" { capabilities = ["deny"] }
        path "nomad/jobs/traefik/traefik/vpn" { capabilities = ["deny"] }
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

# ---- projects: CI and third party apps (docs/projects.md) ---------------------------------------------------------
# A namespace, a policy that reaches that namespace and nothing else, and a token. The token is stable: it is only replaced when the project is
# removed from cluster_projects, when the state is lost, or on purpose (`task project:rotate`), because it lives in the CI of someone else.
locals {
  default_capabilities = ["submit-job", "read-job", "list-jobs", "dispatch-job", "read-logs", "read-job-scaling", "scale-job", "alloc-lifecycle", "csi-mount-volume"]
  projects = { for k, v in var.projects : k => {
    namespace         = coalesce(v.namespace, k)
    capabilities      = distinct(concat(local.default_capabilities, v.extra_capabilities))
    host_volume_rules = join("\n", [for hv in v.host_volumes : "host_volume \"${hv}\" { policy = \"write\" }"])
  } }
}

resource "nomad_namespace" "project" {
  for_each    = local.projects
  name        = each.value.namespace
  description = "project ${each.key} (managed by opentofu)"
}

resource "nomad_acl_policy" "project" {
  for_each    = local.projects
  name        = "project-${each.key}"
  description = "project ${each.key}: run and change jobs in the namespace ${each.value.namespace}, the variables of its jobs, nothing else"
  rules_hcl   = <<-EOT
    namespace "${each.value.namespace}" {
      # no alloc-exec / alloc-node-exec by default (a shell in a container of the project), no sentinel-override
      capabilities = ${jsonencode(each.value.capabilities)}
      variables {
        path "nomad/jobs/*" { capabilities = ["read", "write", "list", "destroy"] }
      }
    }
    ${each.value.host_volume_rules}
    node { policy = "read" }
  EOT
}

resource "nomad_acl_token" "project" {
  for_each = local.projects
  name     = "${var.datacenter}-project-${each.key}"
  type     = "client"
  policies = [nomad_acl_policy.project[each.key].name]
}

# What the controller works with (tofu, backup, restore, the second factors) once the bootstrap token (`nomad acl bootstrap` with the pre-generated
# secret) is handed over and deleted (role nomad_acl, tasks handover). Same power; the difference is that its secret is only in the encrypted state.
resource "nomad_acl_token" "ops" {
  name = "${var.datacenter}-ops"
  type = "management"
}

# ---- nomad variables: job config and secrets (the jobs themselves are run with `nomad job run`) ----

resource "nomad_variable" "authelia" {
  path = "nomad/jobs/authelia"
  items = {
    configuration = var.authelia_configuration
    users         = var.authelia_users
  }
}

resource "nomad_variable" "authelia_internal" {
  path = "nomad/jobs/authelia-internal"
  items = {
    configuration = var.authelia_internal_configuration
    users         = var.authelia_internal_users
  }
}

# the VPN server's wireguard config (private key, preshared keys): only the task "vpn" of traefik's group reads this path
resource "nomad_variable" "vpn" {
  path = "nomad/jobs/traefik/traefik/vpn"
  items = {
    wg_conf = var.vpn_wg_conf
  }
}

# step-ca's ca.json, the encrypted intermediate key and its password, the provisioner keys: only the job step-ca reads this path
resource "nomad_variable" "stepca" {
  count = length(var.stepca_items) > 0 ? 1 : 0
  path  = "nomad/jobs/step-ca"
  items = var.stepca_items
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
