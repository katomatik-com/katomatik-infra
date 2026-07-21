# Non-secret config (safe to commit). The account ID is on the Cloudflare
# dashboard (any zone → Overview → the "API" box on the right). The zone is now
# created by Terraform (cloudflare_zone.primary), so no Zone ID is needed here —
# after apply, read the assigned nameservers from `terraform output`.

cloudflare_account_id = "cf331c406ef912b5bd246bc2b21e42b2"
cloudflare_zone_name  = "katomatik.com"

tunnel_name = "homelab"
hostnames   = ["argocd"]
