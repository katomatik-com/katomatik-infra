# Outputs for the credential hand-off. After apply, these feed the cloudflared
# credential that Ansible deploys (SOPS-encrypted). See docs/terraform-cloudflare.md.

output "tunnel_id" {
  description = "New tunnel UUID — set as cloudflared_tunnel_id in group_vars."
  value       = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
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
