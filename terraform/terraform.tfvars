# Non-secret config (safe to commit). Fill in the two IDs from the Cloudflare
# dashboard: open kurtcebe.nl → Overview → the "API" box on the right shows both
# the Zone ID and the Account ID.

cloudflare_account_id = "0e467fc5ed24bc17b192ac373f3d8fb8"
cloudflare_zone_id    = "edeb8f72f5cae52aefe628f899a80bcd"

tunnel_name = "homelab"
hostnames   = ["argocd"]
