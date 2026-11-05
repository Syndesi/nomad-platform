output "nomad_tokens" {
  description = "deployer, readonly, ui => secret id"
  sensitive   = true
  value       = { for k, v in nomad_acl_token.client : k => v.secret_id }
}
