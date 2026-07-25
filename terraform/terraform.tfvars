# Non-secret config (safe to commit). The account ID is on the Cloudflare
# dashboard (any zone → Overview → the "API" box on the right). The zone is now
# created by Terraform (cloudflare_zone.primary), so no Zone ID is needed here —
# after apply, read the assigned nameservers from `terraform output`.

cloudflare_account_id = "cf331c406ef912b5bd246bc2b21e42b2"
cloudflare_zone_name  = "katomatik.com"

tunnel_name = "homelab"
# Subdomains routed through the tunnel. The apex (katomatik.com) is NOT here —
# it's handled by cloudflare_dns_record.apex in cloudflare.tf (CNAME flattening).
# "www" gets a record so Traefik can 301 it to the apex (manifests/katomatik-web).
hostnames = ["argocd", "www", "auth"]

# Non-secret organization_id for our Neon database
neon_organization_id = "org-gentle-mud-12759690"
