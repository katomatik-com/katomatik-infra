# The Cloudflare side of the tunnel: the tunnel itself + one proxied CNAME per
# hostname. cloudflared's routing config stays host-side in Ansible (config_src
# = "local"); Terraform only owns these Cloudflare objects (ADR-0005).

# We generate the tunnel secret ourselves so we know it (the resource does not
# export it) and can build the cloudflared credential from the outputs.
resource "random_bytes" "tunnel_secret" {
  length = 32 # Cloudflare requires >= 32 bytes, base64-encoded
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "homelab" {
  account_id    = var.cloudflare_account_id
  name          = var.tunnel_name
  config_src    = "local" # routing lives in /etc/cloudflared/config.yml (Ansible)
  tunnel_secret = random_bytes.tunnel_secret.base64
}

# One proxied CNAME per hostname → <tunnel-id>.cfargotunnel.com. Proxied records
# must use ttl = 1 (automatic).
resource "cloudflare_dns_record" "app" {
  for_each = toset(var.hostnames)

  zone_id = var.cloudflare_zone_id
  name    = each.value
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "Managed by Terraform — routes ${each.value} through the homelab tunnel"
}
