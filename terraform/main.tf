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

# The Cloudflare zone for the domain. Terraform manages the zone object, but the
# domain must already be registered elsewhere, and after apply its nameservers
# must be pointed at the two Cloudflare assigns (see the zone_name_servers
# output). The zone stays "Pending" until that one-time registrar change is done.
resource "cloudflare_zone" "primary" {
  account = {
    id = var.cloudflare_account_id
  }
  name = var.cloudflare_zone_name
  type = "full" # Cloudflare as primary DNS — the nameserver-delegation model
}

# One proxied CNAME per hostname → <tunnel-id>.cfargotunnel.com. Proxied records
# must use ttl = 1 (automatic).
resource "cloudflare_dns_record" "app" {
  for_each = toset(var.hostnames)

  zone_id = cloudflare_zone.primary.id
  name    = each.value
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "Managed by Terraform — routes ${each.value} through the homelab tunnel"
}
