output "nomad_tokens" {
  description = "deployer, readonly, ui, ops => secret id"
  sensitive   = true
  value       = merge({ for k, v in nomad_acl_token.client : k => v.secret_id }, { ops = nomad_acl_token.ops.secret_id })
}
