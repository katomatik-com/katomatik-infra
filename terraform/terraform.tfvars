# Non-secret config (safe to commit). The account ID is on the Cloudflare
# dashboard (any zone → Overview → the "API" box on the right). Zones are
# created by Terraform (cloudflare_zone.this), so no Zone ID is needed here —
# after apply, read the assigned nameservers from `terraform output`.

cloudflare_account_id = "cf331c406ef912b5bd246bc2b21e42b2"

tunnel_name = "homelab"

# Every domain served through the tunnel, keyed by apex. One tunnel covers them
# all — a cfargotunnel.com CNAME resolves for any zone in this Cloudflare
# account, and Traefik routes by Host header from there.
#
# `hostnames` lists SUBDOMAIN labels only. Each apex is created automatically by
# cloudflare_dns_record.apex (CNAME flattening) and must NOT be listed.
#
# These keys and labels are load-bearing for the refactor in moved.tf: they
# build the resource addresses that file re-points state at. Adding a hostname
# here is safe; renaming or removing one is a real destroy.
zones = {
  "katomatik.com" = {
    # "www" gets a record so Traefik can 301 it to the apex (manifests/katomatik-web).
    # "authdemo" is the Phase 2/3 Spring app. Its Keycloak client's production redirect
    # URI is built from the same hostname (terraform/keycloak/variables.tf authdemo_url) —
    # the two must agree, or login breaks on "Invalid parameter: redirect_uri".
    hostnames = ["argocd", "www", "auth", "authdemo"]
  }

  # The personal landing page (KI-26). Reuses the existing tunnel — a second
  # domain needs no second tunnel and no cloudflared credential rotation.
  # "www" is here only so Traefik can 301 it to the apex; the apex record
  # itself is automatic (manifests/kurtcebenl-web).
  "kurtcebe.nl" = {
    hostnames = ["www"]
  }
}

# Non-secret organization_id for our Neon database
neon_organization_id = "org-gentle-mud-12759690"
