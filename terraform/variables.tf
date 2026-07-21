# Non-secret inputs. Values live in terraform.tfvars (committed). The secret
# (the API token) is NOT here — it's the sensitive CLOUDFLARE_API_TOKEN env var
# in HCP, read directly by the provider.

variable "cloudflare_account_id" {
  description = "Cloudflare account ID (Dashboard → any zone → Overview → API)."
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Zone ID for katomatik.com (Dashboard → the zone → Overview → API)."
  type        = string
}

variable "tunnel_name" {
  description = "Name of the Cloudflare Tunnel."
  type        = string
  default     = "homelab"
}

variable "hostnames" {
  description = "Subdomains routed through the tunnel (relative to the zone)."
  type        = list(string)
  default     = ["argocd"]
}
