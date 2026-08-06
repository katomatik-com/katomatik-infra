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
| Identity | Keycloak | self-hosted IDP at `auth.katomatik.com`; Operator-managed instance, config in Terraform — [ADR-0009](docs/adr/0009-self-hosted-keycloak-idp.md) / [0014](docs/adr/0014-keycloak-operator.md) / [0015](docs/adr/0015-keycloak-config-via-terraform.md) |
| Database | Neon (managed Postgres) | external, one project per app — [ADR-0011](docs/adr/0011-neon-managed-postgres.md) |

ArgoCD's UI is gated by Keycloak SSO (OIDC + PKCE); admin comes from the
`argocd-admins` group, and Keycloak's own admin console is not exposed publicly.
`katomatik-authdemo` (`authdemo.katomatik.com`) is a small Spring Boot service that
logs in against the same realm and enforces role-based access in-app — the worked
example behind [ADR-0016](docs/adr/0016-authdemo-app-auth-design.md).

*Planned:* Prometheus + Grafana (observability), and my own web apps.

## Repo layout

```
.
├── ansible/          # OS setup: base, k3s, cloudflared roles + site.yml
├── argocd/           # ArgoCD bootstrap values + app-of-apps root
├── apps/             # ArgoCD Application manifests (one per app)
├── manifests/        # plain Kubernetes YAML per app (referenced by apps/)
├── terraform/        # Cloudflare zone/tunnel/DNS (state in HCP)
│   └── keycloak/     # Keycloak realm/client config — SEPARATE workspace, local state
│                     #   (HCP runners can't reach the in-cluster admin API)
├── docs/
│   ├── guides/       # how-to guides (per phase)
│   └── adr/          # Architectural Decision Records — the "why"
├── .sops.yaml        # which files SOPS encrypts, and to which age key
└── CLAUDE.md         # working conventions for AI-assisted sessions
```

## Documentation

Two kinds, kept deliberately separate:

- **How-to guides** (`docs/guides/`) — reproducible, per-phase walkthroughs:
  - [Ansible bootstrap](docs/guides/ansible-bootstrap.md) — two fresh machines → "Ansible can manage my server"
  - [Helm basics](docs/guides/helm-basics.md)
  - [SOPS + age setup](docs/guides/sops-age-setup.md)
  - [ArgoCD secret decryption](docs/guides/argocd-secret-decryption.md) — how encrypted Git becomes plaintext Secrets (KSOPS, CMP, KMS vs Vault)
  - [Cloudflare Tunnel](docs/guides/cloudflare-tunnel-setup.md)
  - [Terraform — Cloudflare](docs/guides/terraform-cloudflare.md)
  - [Keycloak + OIDC SSO](docs/guides/keycloak-oidc-sso.md) — self-hosted IDP, and putting ArgoCD behind it
  - [Securing an app with OIDC](docs/guides/securing-an-app-with-oidc.md) — the app side: roles vs groups, the ID-token trap, in-app RBAC
  - [Adding an app](docs/guides/add-an-app.md) — deploy a workload and serve it at a public hostname
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
