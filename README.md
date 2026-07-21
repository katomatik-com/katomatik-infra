# Homelab

A single-node home server built the slow way — Ansible, k3s, GitOps, and IaC —
to *understand* the DevOps / Kubernetes / GitOps tooling, not just get it
running. Every significant decision is written down as an ADR so the reasoning
survives, not just the resulting config.

Public infrastructure for **katomatik.com** (ArgoCD runs at `argocd.katomatik.com`).

## Hardware

- M1 MacBook (16 GB RAM, ~165 GB allocated to Linux), dual-boot Fedora Asahi
  Remix (headless) + macOS.
- KPN Box 12 over WiFi (no ethernet yet); the server is reachable on the LAN as
  `homelab.lan`.

## Stack

| Layer | Choice | Notes |
|---|---|---|
| OS | Fedora Asahi Remix (headless) | |
| Config management | Ansible | OS-level setup only — stops at the cluster boundary |
| Kubernetes | k3s (single node) | bundled Traefik kept — [ADR-0001](docs/adr/0001-k3s-single-node-custom-ansible-role.md) |
| Packaging | Helm | chart format, rendered by ArgoCD (not run by hand) |
| GitOps | ArgoCD (app-of-apps) | self-manages after bootstrap; Helmfile dropped — [ADR-0003](docs/adr/0003-argocd-only-gitops-helmfile-dropped.md) |
| Secrets | SOPS + age | values encrypted in Git, decrypted at render time |
| Ingress | Traefik | bundled with k3s |
| Tunnel | Cloudflare Tunnel | `cloudflared` host daemon → Traefik — [ADR-0002](docs/adr/0002-cloudflare-tunnel-host-daemon-to-traefik.md) |
| External / IaC | Terraform | Cloudflare zone/tunnel/DNS, state in HCP — [ADR-0005](docs/adr/0005-terraform-for-cloudflare-external-layer.md) / [0007](docs/adr/0007-dedicated-katomatik-cloudflare-hcp-accounts.md) |

*Planned:* Prometheus + Grafana (observability), Keycloak + PostgreSQL (auth),
and my own web apps.

## Repo layout

```
.
├── ansible/          # OS setup: base, k3s, cloudflared roles + site.yml
├── argocd/           # ArgoCD bootstrap values + app-of-apps root
├── apps/             # ArgoCD Application manifests
├── terraform/        # Cloudflare zone/tunnel/DNS (state in HCP)
├── docs/             # how-to guides (per phase)
│   └── adr/          # Architectural Decision Records — the "why"
├── .sops.yaml        # which files SOPS encrypts, and to which age key
└── CLAUDE.md         # working conventions for AI-assisted sessions
```

## Documentation

Two kinds, kept deliberately separate:

- **How-to guides** (`docs/`) — reproducible, per-phase walkthroughs:
  - [Ansible bootstrap](docs/guides/ansible-bootstrap.md) — two fresh machines → "Ansible can manage my server"
  - [Helm basics](docs/guides/helm-basics.md)
  - [SOPS + age setup](docs/guides/sops-age-setup.md)
  - [Cloudflare Tunnel](docs/guides/cloudflare-tunnel-setup.md)
  - [Terraform — Cloudflare](docs/guides/terraform-cloudflare.md)
- **Decisions** (`docs/adr/`) — *why* each choice was made, and what was rejected.
  Start at the [ADR index](docs/adr/README.md).

## Getting started

The **control node** is your Mac; the **managed host** is the server.

1. Install tooling on the Mac:
   ```sh
   brew install ansible
   ansible-galaxy collection install -r ansible/requirements.yml
   ```
2. Do the first run via the [Ansible bootstrap guide](docs/guides/ansible-bootstrap.md)
   — it walks password auth → SSH keys → hardening without locking yourself out.
3. Fill the placeholders in `ansible/inventory/hosts.ini` and
   `ansible/group_vars/all.yml`, then:
   ```sh
   cd ansible && ansible-playbook site.yml
   ```
4. Later layers (k3s, Cloudflare Tunnel, Terraform) each have their own guide
   linked above.

## Secrets

Never commit plaintext secrets — `.gitignore` blocks the danger files, and
values are encrypted with **SOPS + age** (the age private key is never
committed). Setup: [docs/guides/sops-age-setup.md](docs/guides/sops-age-setup.md).
