# Terraform — Cloudflare zone / tunnel / DNS

Codifies the **external Cloudflare layer** as IaC (ADR-0005): the tunnel and its
DNS records. Ansible still runs `cloudflared` on the host and owns
`config.yml`; ArgoCD still owns the cluster. State + runs live in **HCP
Terraform** (remote execution), so the Cloudflare API token never touches your
Mac.

This supersedes the manual `cloudflared tunnel create` / `route dns` steps in
`docs/cloudflare-tunnel-setup.md`.

## Prerequisites

- Terraform CLI (`brew install hashicorp/tap/terraform`) + `terraform login`.
- An HCP Terraform org + **CLI-driven** workspace with **Execution Mode =
  Remote** (Settings → General). This lab: org `kurt_homelab`, workspace
  `homelab` (see `terraform/versions.tf`).
- A Cloudflare API token (below), added to the workspace.

---

## Part 1 — Cloudflare API token

Create a **custom token** (My Profile → API Tokens). The **working, minimal**
permission set — note the tunnel permission is **Account**-scoped, not zone:

| Scope | Permission | Level |
|---|---|---|
| Zone `katomatik.com` | DNS | **Write** (Edit) |
| Zone `katomatik.com` | Zone | **Read** |
| Account `<account-id>` | Cloudflare Tunnel | **Write** (Edit) |
| Account `<account-id>` | Account Settings | **Read** |

> The #1 pitfall: the **Cloudflare Tunnel** permission must be granted on the
> **"Entire account"** resource. A token scoped only to the zone gives
> **403** on the `cfd_tunnel` API. (In older token UIs this permission may show
> as **"Argo Tunnel (Legacy)"** — same thing.)

**Verify the token before trusting it** (both must print `true`):

```sh
TOKEN='cfat_...'; ACCT='<account-id>'; ZONE='<zone-id>'
# tunnel permission (the exact endpoint Terraform uses)
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$ACCT/cfd_tunnel" | jq '.success'
# DNS records permission
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records?per_page=1" | jq '.success'
```
(Account-owned tokens start with `cfat_` and verify at
`/accounts/<id>/tokens/verify`, **not** `/user/tokens/verify`.)

**Add it to HCP:** workspace → Variables → **Environment variable** (not
Terraform variable), name **exactly `CLOUDFLARE_API_TOKEN`**, mark **Sensitive**.
The Cloudflare provider reads this env var directly (see `provider "cloudflare"
{}` in `versions.tf`). In a remote run, HCP injects it.

---

## Part 2 — Config values

`terraform/terraform.tfvars` (committed, non-secret) — fill the two IDs from the
dashboard (open `katomatik.com` → Overview → the "API" box shows both):

```hcl
cloudflare_account_id = "<account-id>"
cloudflare_zone_id    = "<zone-id>"
tunnel_name = "homelab"
hostnames   = ["argocd"]
```

---

## Part 3 — Init + plan

```sh
cd terraform
terraform init      # downloads providers, links the HCP workspace
terraform plan      # expect: 3 to add (random_bytes + tunnel + 1 dns_record)
```

---

## Part 4 — Migrate (recreate) + apply

We **recreate** the tunnel (ADR-0005), so clear the old one first or you'll
collide on the tunnel name + the existing `argocd` CNAME:

```sh
ssh <user>@homelab.lan 'sudo systemctl stop cloudflared'   # argocd down (planned)
#   dashboard: Zero Trust → Networks → Tunnels → delete the old tunnel
#              DNS → delete the argocd CNAME
terraform apply     # review → yes
```

---

## Part 5 — Credential hand-off to Ansible

The new tunnel has a **new ID and secret**. Update **both** places, or cloudflared
connects to the wrong/deleted tunnel:

```sh
# 1. tunnel ID → group_vars
terraform output -raw tunnel_id      # → ansible/group_vars/all.yml : cloudflared_tunnel_id

# 2. credential → the SOPS file (new AccountTag/TunnelID/TunnelSecret)
terraform output -raw tunnel_credentials_json | jq
sops ../ansible/roles/cloudflared/files/cloudflared-credentials.sops.yaml   # replace the 3 values

# 3. redeploy cloudflared onto the new tunnel
cd ../ansible && ansible-playbook site.yml -K
```

> Both updates matter. If only the SOPS credential is updated but
> `cloudflared_tunnel_id` in `group_vars` is stale, `config.yml` still names the
> old tunnel → cloudflared logs `Unauthorized: Tunnel not found` and the site
> returns Cloudflare **530**.

---

## Part 6 — Verify

```sh
ssh <user>@homelab.lan 'systemctl status cloudflared --no-pager | tail -6'  # "Registered tunnel connection" x4
cloudflared tunnel info homelab            # active connections
curl -sSI https://argocd.katomatik.com | head -1   # HTTP/2 200
```

---

## Adding more hostnames later

1. Add the subdomain to `hostnames` in `terraform.tfvars` → `terraform apply`
   (creates the CNAME). No cloudflared change (catch-all → Traefik).
2. Add a Kubernetes Ingress for it (committed, ArgoCD applies).

## Troubleshooting (what bit us)

- **403 on `cfd_tunnel`** → token lacks **Cloudflare Tunnel: Write** *or* it isn't
  scoped to the **entire account**.
- **401 on `cfd_tunnel`** → HCP holds an **invalid/stale** token value (sensitive
  vars are write-only, so you can't see it — overwrite it). Rolling a token
  invalidates the old value immediately.
- **Nothing changes after updating the token** → you edited the wrong HCP
  variable *category*; it must be **Environment variable**, not Terraform
  variable.
- **`Tunnel not found` / 530** → `config.yml`'s `tunnel:` ID doesn't match a live
  tunnel — update `cloudflared_tunnel_id` in `group_vars` and re-run Ansible.
