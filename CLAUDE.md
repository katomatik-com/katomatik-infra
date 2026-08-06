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

## Where things live — docs vs open work
- **Documentation stays in Git** (`docs/adr/`, `docs/guides/`): it is code-adjacent, it
  ships in the same commit as the config it explains, and the repo is public. → ADR-0017
- **Open work is tracked in Jira**, project **`KI` (katomatik-infra)** at
  `katomatik.atlassian.net` — one epic per initiative, and each issue records *why* an
  item was deferred, not just what it is. Don't start a parallel TODO list in the repo.
- `.plan/securing-apps.md` is a **frozen snapshot**, not the working list. It is
  gitignored, so never delete from it — there is no history to recover.
- Docs are kept true by reconciliation, not memory: **`/docs-drift-audit`** checks every
  factual claim in `docs/` against live state collected by **`scripts/ground-truth.sh`**
  (HCP + local Terraform, `kubectl`, public HTTP, `git log`). It must run locally — the
  cluster API is LAN-only and the Keycloak workspace keeps local state, so CI cannot see
  either. The collector gathers no secrets and writes outside the repo; a source that
  fails makes its claims UNVERIFIABLE rather than silently confirmed.

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
