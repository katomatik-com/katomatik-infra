# Non-secret inputs. Values live in terraform.tfvars (committed). The secret
# (the API token) is NOT here — it's the sensitive CLOUDFLARE_API_TOKEN env var
# in HCP, read directly by the provider.

variable "cloudflare_account_id" {
  description = "Cloudflare account ID (Dashboard → any zone → Overview → API)."
  type        = string
}

variable "tunnel_name" {
  description = "Name of the Cloudflare Tunnel."
  type        = string
  default     = "homelab"
}

# Replaces the old single-domain pair (cloudflare_zone_name + hostnames), which
# could only ever describe ONE zone. Keyed by apex so a zone's name is its
# identity — that key ends up in every resource address, so it must be stable.
variable "zones" {
  description = <<-EOT
    Domains served through the tunnel, keyed by apex (e.g. "katomatik.com").
    `hostnames` lists the SUBDOMAIN labels to create records for, relative to
    the zone. The apex record is always created and must NOT be listed here.
  EOT
  type = map(object({
    hostnames = optional(list(string), [])
  }))
}

variable "neon_organization_id" {
  description = "Neon Organization ID (Organization -> settings -> General Info)."
  type        = string
}
