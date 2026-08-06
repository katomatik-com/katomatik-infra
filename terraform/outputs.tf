# Outputs for the credential hand-off. After apply, these feed the cloudflared
# credential that Ansible deploys (SOPS-encrypted). See docs/terraform-cloudflare.md.

output "tunnel_id" {
  description = "New tunnel UUID — set as cloudflared_tunnel_id in group_vars."
  value       = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
}

# The nameservers Cloudflare assigned to each zone. Set BOTH at that domain's
# registrar to activate it — a zone stays "Pending" (and nothing resolves)
# until the registrar delegates to these.
#
# Now a MAP keyed by apex rather than a bare list, since there can be more than
# one zone. Read one domain's pair with:
#   terraform output -json zone_name_servers | jq '."kurtcebe.nl"'
output "zone_name_servers" {
  description = "Per-zone nameserver pair — point the registrar at these to activate a zone."
  value       = { for name, zone in cloudflare_zone.this : name => zone.name_servers }
}

# The full cloudflared credentials-file content, ready to SOPS-encrypt.
# Sensitive because it embeds the tunnel secret. Retrieve with:
#   terraform output -raw tunnel_credentials_json
output "tunnel_credentials_json" {
  description = "cloudflared credential JSON (AccountTag/TunnelID/TunnelSecret)."
  value = jsonencode({
    AccountTag   = cloudflare_zero_trust_tunnel_cloudflared.homelab.account_tag
    TunnelID     = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
    TunnelSecret = random_bytes.tunnel_secret.base64
  })
  sensitive = true
}


# Neon (Keycloak project). The connection URI is the DIRECT endpoint (not the
# pooler) — Keycloak runs Liquibase migrations + its own Agroal pool, which the
# transaction-mode pooler would break. Retrieve for the SOPS-encrypted DB secret:
#   terraform output -raw keycloak_db_connection_uri
output "keycloak_project_id" {
  description = "Neon project ID for Keycloak."
  value       = neon_project.keycloak.id
}
output "keycloak_db_connection_uri" {
  description = "Direct connection URI for the Keycloak database (contains credentials)."
  value       = neon_project.keycloak.connection_uri
  sensitive   = true
}
output "keycloak_db_default_branch_id" {
  description = "Default branch ID of the Keycloak Neon project."
  value       = neon_project.keycloak.default_branch_id
}
output "keycloak_db_user" {
  description = "Database role Keycloak connects as."
  value       = neon_project.keycloak.database_user
}