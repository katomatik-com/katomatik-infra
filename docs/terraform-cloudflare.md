# Terraform — Cloudflare zone / tunnel / DNS

Codifies the **external Cloudflare layer** as IaC (ADR-0005, ADR-0007): the
zone, the tunnel, and its DNS records. Ansible still runs `cloudflared` on the host and owns
`config.yml`; ArgoCD still owns the cluster. State + runs live in **HCP
Terraform** (remote execution), so the Cloudflare API token never touches your
Mac.

This supersedes the manual `cloudflared tunnel create` / `route dns` steps in
`docs/cloudflare-tunnel-setup.md`.

## Prerequisites

- Terraform CLI (`brew install hashicorp/tap/terraform`) + `terraform login`.
- An HCP Terraform org + **CLI-driven** workspace with **Execution Mode =
  Remote** (Settings → General). This lab: org `katomatik`, workspace
  `katomatik-com` (see `terraform/versions.tf`).
- A Cloudflare API token (below), added to the workspace.

---

## Part 1 — Cloudflare API token

Create a **custom token** (My Profile → API Tokens). The **working, minimal**
permission set — Terraform now **creates the zone**, so the Zone permissions
must be **Edit** and scoped to **All zones** (the zone doesn't exist yet, so you
can't pick it individually); the tunnel permission is **Account**-scoped:

| Scope | Permission | Level |
|---|---|---|
| Zone → *All zones from the account* | Zone | **Edit** — *lets Terraform create the zone* |
| Zone → *All zones from the account* | DNS | **Edit** |
| Account `<account-id>` | Cloudflare Tunnel | **Edit** |
| Account `<account-id>` | Account Settings | **Read** |

> Two pitfalls: (1) the **Cloudflare Tunnel** permission must be granted on the
> **"Entire account"** resource — a token scoped only to a zone gives **403** on
> the `cfd_tunnel` API (in older UIs this shows as **"Argo Tunnel (Legacy)"**).
> (2) **Zone : Read is not enough** now that Terraform creates the zone — it
> needs **Zone : Edit** on *All zones*, or `terraform apply` fails to create it.

**Verify the token before trusting it** — pre-apply the zone doesn't exist yet,
so only the tunnel (account) endpoint is checkable now; the DNS-records check
needs a `<zone-id>`, so run it **after** Part 4 once Terraform has created the zone:

```sh
TOKEN='cfat_...'; ACCT='<account-id>'
# tunnel permission (the exact endpoint Terraform uses) — must print `true`
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$ACCT/cfd_tunnel" | jq '.success'
# DNS records permission — only after the zone exists (ZONE='<zone-id>')
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

`terraform/terraform.tfvars` (committed, non-secret). The **account ID** is on
the account home (right sidebar) or any zone's Overview → "API" box. The **zone
is created by Terraform** (`cloudflare_zone.primary`), so you give its *name*,
not an ID:

```hcl
cloudflare_account_id = "<account-id>"
cloudflare_zone_name  = "katomatik.com"
tunnel_name = "homelab"
hostnames   = ["argocd"]
```

---

## Part 3 — Init + plan

```sh
cd terraform
terraform init      # downloads providers, links the HCP workspace
terraform plan      # expect: 4 to add (random_bytes + zone + tunnel + 1 dns_record)
```

---

## Part 4 — Apply + delegate nameservers

```sh
terraform apply     # review → yes  (creates the zone [Pending] + tunnel + CNAME)
```

Terraform creates the zone, but it stays **Pending** until the domain's
nameservers point at Cloudflare. Read the assigned pair and set **both** at your
**registrar** for the domain:

```sh
terraform output zone_name_servers   # e.g. arnold.ns.cloudflare.com / linda.ns.cloudflare.com
```

The zone flips to **Active** once Cloudflare sees the delegation (minutes–hours);
nothing under it resolves until then.

> **Reusing an existing account/workspace?** If a tunnel of the same name or an
> `argocd` CNAME already exists there, clear them first (Zero Trust → Networks →
> Tunnels; DNS → the CNAME) or `apply` collides. A fresh Cloudflare account with
> an empty HCP workspace (how this lab is now set up — ADR-0007) has nothing to
> clear.

---

## Part 5 — Credential hand-off to Ansible

The new tunnel has a **new ID and secret**. Update **both** places, or cloudflared
connects to the wrong/deleted tunnel:

```sh
# 1. tunnel ID → group_vars
terraform output -raw tunnel_id      # → ansible/group_vars/all.yml : cloudflared_tunnel_id

# 2. credential → the SOPS file (new AccountTag/TunnelID/TunnelSecret)
terraform output -raw tunnel_credentials_json | jq
sops ../ansible/roles/cloudflared/files/cloudflared-credentials.sops.yaml   # replace all 3 values
#    NB: a NEW account changes AccountTag too — not just TunnelID/TunnelSecret.

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
