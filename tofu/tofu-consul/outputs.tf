output "agent_tokens" {
  description = "node name => secret id of its agent token"
  sensitive   = true
  value       = { for k, v in data.consul_acl_token_secret_id.agent : k => v.secret_id }
}

output "service_tokens" {
  description = "traefik, nomad-agent, readonly, dns => secret id"
  sensitive   = true
  value       = { for k, v in data.consul_acl_token_secret_id.service : k => v.secret_id }
}
