# Architectural Decision Records (ADRs)

This directory holds the significant architectural decisions for the
homelab, one decision per file. An ADR captures *why* a choice was made —
the forces and trade-offs — not just what the code ends up doing. When a
decision changes, we don't rewrite history: we add a new ADR that
**supersedes** the old one, and flip the old one's status.

## Format

Each ADR follows the same structure (keep it to 1–2 pages):

- **Title** — a unique, sequential identifier and descriptive name,
  e.g. `ADR-0001: Provision single-node k3s via a custom Ansible role`.
- **Status** — `Proposed`, `Accepted`, `Rejected`, or `Superseded`
  (note which ADR supersedes it).
- **Context** — the forces, constraints, and background that made a
  decision necessary.
- **Decision** — the chosen approach, in the active voice.
- **Consequences** — the resulting trade-offs, pros, and cons.

## Naming

`NNNN-short-kebab-case-title.md`, zero-padded and sequential
(`0001-...`, `0002-...`). Numbers are never reused.

## Index

| ADR | Title | Status |
|-----|-------|--------|
| [0001](0001-k3s-single-node-custom-ansible-role.md) | Provision single-node k3s via a custom Ansible role | Accepted |
| [0002](0002-cloudflare-tunnel-host-daemon-to-traefik.md) | Expose services via a host-daemon Cloudflare Tunnel pointed at Traefik | Accepted |
| [0003](0003-argocd-only-gitops-helmfile-dropped.md) | GitOps reconciler — ArgoCD only (app-of-apps), Helmfile dropped | Accepted |
| [0004](0004-argocd-repo-access-deploy-key.md) | ArgoCD reads the private repo via a read-only SSH deploy key | Superseded by [0006](0006-public-repo-anonymous-https.md) |
| [0005](0005-terraform-for-cloudflare-external-layer.md) | Terraform for the external/Cloudflare layer (zone/tunnel/DNS) | Accepted |
| [0006](0006-public-repo-anonymous-https.md) | Public repo — ArgoCD reads it anonymously over HTTPS | Accepted |
| [0007](0007-dedicated-katomatik-cloudflare-hcp-accounts.md) | Dedicated katomatik Cloudflare + HCP accounts; Terraform owns the zone | Accepted |
| [0008](0008-app-delivery-plain-manifests-and-apex-routing.md) | App delivery — plain manifests per app, apex + www routing | Accepted |
| [0009](0009-self-hosted-keycloak-idp.md) | Self-hosted Keycloak as the homelab identity provider | Accepted |
| [0010](0010-native-oidc-oauth2-proxy-fallback.md) | Workload auth via native OIDC; oauth2-proxy as the fallback | Accepted |
| [0011](0011-neon-managed-postgres.md) | Managed external Postgres (Neon) for stateful app data | Accepted |
| [0012](0012-argocd-sops-decryption-ksops.md) | ArgoCD decrypts SOPS secrets via KSOPS | Accepted |
| [0014](0014-keycloak-operator.md) | Deploy Keycloak via the official Keycloak Operator | Accepted (revises 0009 deployment) |
| [0015](0015-keycloak-config-via-terraform.md) | Manage Keycloak realm/client config with Terraform | Accepted (revises 0014 config) |
| [0016](0016-authdemo-app-auth-design.md) | App auth design — client roles, a confidential client, RBAC in the app | Accepted |
