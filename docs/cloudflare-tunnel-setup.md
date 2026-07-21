# Cloudflare Tunnel — setup & first exposed service

Get the homelab reachable from the internet with **no inbound ports and no
public IP**, via a Cloudflare Tunnel. Architecture (ADR-0002): `cloudflared`
runs as a **host systemd service**, opens an outbound tunnel to Cloudflare, and
forwards everything to **Traefik on `localhost:80`**; per-host routing is done by
Kubernetes Ingress. TLS terminates at Cloudflare — no certs for us.

This is also **SOPS's first real use**: the tunnel credential is encrypted in
Git and decrypted by Ansible at deploy time.

> **Superseded by Terraform for Parts 1 & 4.** The manual `cloudflared tunnel
> create` / `route dns` steps below are now done by Terraform (see
> `docs/terraform-cloudflare.md`, ADR-0005/0007) — kept here as the
> *understand-it* version. **For real setup, follow the Terraform guide.** Parts
> 2, 3, 5, and 6 (SOPS credential, Ansible deploy, ArgoCD Ingress, end-to-end
> test) are still current.

## Prerequisites

- SOPS + age working (`docs/sops-age-setup.md`).
- `katomatik.com` Active on Cloudflare.

---

## Part 1 — Create the tunnel

Install cloudflared and create the tunnel (once). `login` needs a browser.

```sh
brew install cloudflared

# Authorize cloudflared for your Cloudflare zone (opens browser; pick
# katomatik.com). Writes ~/.cloudflared/cert.pem
cloudflared tunnel login

# Create the tunnel. Writes ~/.cloudflared/<TUNNEL-ID>.json (the SECRET) and
# registers a tunnel named "homelab".
cloudflared tunnel create homelab

cloudflared tunnel list          # note the TUNNEL ID (not secret)
```

Put the tunnel ID in `ansible/group_vars/all.yml`:

```yaml
cloudflared_tunnel_id: <your-tunnel-id>
```

> `cert.pem` is an account/zone management cert used by the CLI (`login`,
> `create`, `route dns`). The **running tunnel** only needs the `<ID>.json`
> credential — which Part 2 encrypts.

---

## Part 2 — Encrypt the tunnel credential (SOPS)

The credential (`~/.cloudflared/<ID>.json`) holds `AccountTag`, `TunnelID`,
`TunnelSecret`. Store those three as an encrypted `*.sops.yaml` in the role.
First, see the values:

```sh
cat ~/.cloudflared/cee9c4b7-ce6a-406c-9a9e-f3e2ecf65c07.json
```

Create the encrypted file with the SOPS editor (it encrypts on save, so
plaintext never lands on disk):

```sh
mkdir -p ansible/roles/cloudflared/files
sops ansible/roles/cloudflared/files/cloudflared-credentials.sops.yaml
```

In the editor, replace the template with the three values from the JSON:

```yaml
AccountTag: "<AccountTag from the JSON>"
TunnelID: "cee9c4b7-ce6a-406c-9a9e-f3e2ecf65c07"
TunnelSecret: "<TunnelSecret from the JSON>"
```

Save & quit, then verify it round-trips and is committable:

```sh
sops -d ansible/roles/cloudflared/files/cloudflared-credentials.sops.yaml   # shows plaintext
grep -q ENC ansible/roles/cloudflared/files/cloudflared-credentials.sops.yaml && echo "encrypted ✓"
git check-ignore ansible/roles/cloudflared/files/cloudflared-credentials.sops.yaml || echo "committable ✓"
```

---

## Part 3 — Deploy cloudflared via Ansible

Install the new collection (adds `community.sops`), then run the playbook — the
`cloudflared` play installs cloudflared, decrypts the credential **on your Mac**,
ships it to the server, writes the config, and starts the systemd service.

```sh
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook site.yml -K            # base + k3s are idempotent; cloudflared is new
```

Verify on the server:

```sh
ssh katomatik@homelab.lan 'systemctl status cloudflared --no-pager | head -5'
ssh katomatik@homelab.lan 'journalctl -u cloudflared -n 20 --no-pager'
#   look for: "Registered tunnel connection" (usually 4 connections to CF edge)
```

Or from your Mac (uses `~/.cloudflared/cert.pem`):

```sh
cloudflared tunnel info homelab         # should show active connector(s)
```

---

## Part 4 — Route DNS to the tunnel

Point the hostname at the tunnel (creates a proxied CNAME in Cloudflare):

```sh
cloudflared tunnel route dns homelab argocd.katomatik.com
dig +short argocd.katomatik.com           # resolves to Cloudflare IPs (proxied)
```

---

## Part 5 — Expose the ArgoCD UI (Ingress via GitOps)

`argocd/values.yaml` now sets `global.domain: argocd.katomatik.com` and enables a
Traefik Ingress on `argocd-server`. Commit + push it; ArgoCD (automated sync)
applies the Ingress itself:

```sh
git add argocd/values.yaml && git commit -m "Expose ArgoCD UI via Traefik Ingress" && git push
```

Watch ArgoCD pick it up (or Hard Refresh the `argocd` app in the UI):

```sh
export KUBECONFIG=~/.kube/homelab.config
kubectl -n argocd get ingress            # an ingress for argocd.katomatik.com appears
```

---

## Part 6 — End-to-end test

```sh
curl -sSI https://argocd.katomatik.com | head -5     # expect HTTP 200
```

Then open **https://argocd.katomatik.com** in a browser — the ArgoCD login, served
through Cloudflare's TLS, down the tunnel, via Traefik, to `argocd-server`.
Log in as `admin` (password from `argocd-initial-admin-secret`). You can retire
the `kubectl port-forward` now.

The full chain, proven:

```
browser → Cloudflare (TLS) → tunnel → cloudflared (host) → localhost:80
        → Traefik → Ingress(argocd.katomatik.com) → argocd-server
```

---

## Troubleshooting

- **502 / error page:** cloudflared reached Traefik but got nothing. Check the
  Ingress exists (`kubectl -n argocd get ingress`) and Traefik is on host port 80
  (`kubectl -n kube-system get svc traefik`).
- **530 / 1033:** the tunnel isn't connected — check `systemctl status
  cloudflared` and its journal on the server.
- **DNS not resolving:** the `route dns` CNAME may still be propagating; re-run
  `dig +short argocd.katomatik.com`.
- **Redirect loop / TLS errors:** confirm `server.insecure: true` is set (it is)
  so argocd-server serves plain HTTP behind Traefik.

## Adding more services later

Per hostname it's just two steps — no cloudflared change:
1. `cloudflared tunnel route dns homelab <name>.katomatik.com`
2. add a Kubernetes Ingress for `<name>.katomatik.com` (committed to Git).
