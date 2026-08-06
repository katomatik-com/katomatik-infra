# The Cloudflare side of the tunnel: the tunnel itself + one proxied CNAME per
# hostname. cloudflared's routing config stays host-side in Ansible (config_src
# = "local"); Terraform only owns these Cloudflare objects (ADR-0005).
#
# Everything zone-shaped is driven by var.zones (a map keyed by apex), so a new
# domain is a tfvars entry rather than a new copy of these resources. ONE tunnel
# serves all of them: a cfargotunnel.com CNAME resolves for any zone in the same
# Cloudflare account, and Traefik picks the app by Host header.

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

# One Cloudflare zone per domain. Terraform manages the zone object, but the
# domain must already be registered elsewhere, and after apply its nameservers
# must be pointed at the two Cloudflare assigns (see the zone_name_servers
# output). A zone stays "Pending" until that one-time registrar change is done.
resource "cloudflare_zone" "this" {
  for_each = var.zones

  account = {
    id = var.cloudflare_account_id
  }
  name = each.key
  type = "full" # Cloudflare as primary DNS — the nameserver-delegation model
}

# var.zones nests labels inside each zone, but for_each needs a FLAT map — one
# entry per record. Key it "<zone>/<label>" so the resource address reads
# unambiguously in a plan and stays stable when another zone changes.
#
# merge(...)... is the standard flatten idiom: build one map per zone, then
# spread that list into merge as separate arguments.
locals {
  subdomain_records = merge([
    for zone_name, cfg in var.zones : {
      for label in cfg.hostnames :
      "${zone_name}/${label}" => {
        zone  = zone_name
        label = label
        fqdn  = "${label}.${zone_name}"
      }
    }
  ]...)
}

# One proxied CNAME per SUBDOMAIN → <tunnel-id>.cfargotunnel.com. Proxied records
# must use ttl = 1 (automatic).
resource "cloudflare_dns_record" "subdomain" {
  for_each = local.subdomain_records

  zone_id = cloudflare_zone.this[each.value.zone].id
  name    = each.value.label
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "Managed by Terraform — routes ${each.value.fqdn} through the homelab tunnel"
}

# Each apex is a special case: DNS forbids a real CNAME at a zone apex, but
# Cloudflare's CNAME flattening lets a PROXIED apex CNAME resolve to the tunnel
# anyway. Kept separate from the subdomain records because its name is the zone
# itself, not <label>.zone — and because every zone gets exactly one, always.
resource "cloudflare_dns_record" "apex" {
  for_each = var.zones

  zone_id = cloudflare_zone.this[each.key].id
  name    = each.key # the apex, e.g. katomatik.com
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "Managed by Terraform — routes the ${each.key} apex through the homelab tunnel"
}
