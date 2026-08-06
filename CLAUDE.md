# CLAUDE.md — Homelab Project

## Project goal
Learning DevOps, Kubernetes, and GitOps by building a real home lab server.
The goal is understanding the tools, not just getting things running.

Stack, hardware, and repo layout live in [README.md](./README.md). The *why*
behind each choice lives in the ADRs under `docs/adr/`; step-by-step how-tos
live in `docs/`.

## Architectural Decision Records (ADRs)
- Significant architectural decisions are recorded as ADRs under `docs/adr/`,
  one decision per file, so the *reasoning* and trade-offs survive — not just
  the resulting config.
- Each ADR has: **Title** (sequential id + name), **Status** (Proposed /
  Accepted / Rejected / Superseded), **Context**, **Decision** (active voice),
  **Consequences**. Keep to 1–2 pages. Files are named `NNNN-short-title.md`;
  `docs/adr/README.md` is the index and template.
- When a decision changes, add a NEW ADR that supersedes the old one and flip
  the old one's status — don't rewrite history.
- After making a substantive architectural decision in a session, write it up
  as an ADR and add it to the index table in `docs/adr/README.md`. The current
  set is listed there.

## Secrets — SOPS + age
- Encrypt secret *values* in YAML with an age keypair, commit the encrypted
  files to Git, and let ArgoCD decrypt at render time. Chosen over Sealed
  Secrets (cluster-bound key), External Secrets Operator (needs a backend), and
  Vault (too heavy for one node) — SOPS is portable and gives readable diffs.
- Rules:
  - NEVER commit a plaintext secret. `.gitignore` blocks the danger files
    (`age.key`, `*.agekey`, `keys.txt`, unencrypted `*secret*.yaml`).
  - The age private key is the crown jewel: back it up, never commit it; it's
    provided to ArgoCD as a one-time bootstrap secret.
  - Install SOPS + age tooling just before the first component that needs a
    secret — not before.

## Working style & conventions
- One layer at a time — don't jump ahead to the next phase.
- Explain *why*, not just *what*; walk through each significant config or
  playbook section as you write it.
- Flag when something is a learning simplification vs a production best practice.
- **Ansible stops at the cluster boundary.** Ansible installs k3s, manages the
  service, and fetches the kubeconfig back to the Mac. Everything *inside*
  Kubernetes (Traefik config, ArgoCD, apps) is ArgoCD/Helm — never
  `kubectl apply` from Ansible, which would create two competing sources of
  truth.
