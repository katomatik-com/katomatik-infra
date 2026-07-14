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
| [0004](0004-argocd-repo-access-deploy-key.md) | ArgoCD reads the private repo via a read-only SSH deploy key | Accepted |
