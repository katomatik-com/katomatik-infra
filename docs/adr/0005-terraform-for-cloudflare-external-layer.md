# ADR-0005: Terraform for the external/Cloudflare layer

## Status

Accepted — 2026-07-17. **Implementation deferred** to its own phase, after the
Cloudflare Tunnel is working end to end (ArgoCD exposed manually first).
**Extended by [ADR-0007](0007-dedicated-katomatik-cloudflare-hcp-accounts.md)** —
Terraform now also creates the zone, in dedicated katomatik accounts.

## Context

Each tool in the stack owns a layer:

- **Ansible** → the host/OS (over SSH),
- **ArgoCD / Helm** → in-cluster state (GitOps),
- **…and nothing** → **external cloud / SaaS state.**

The Cloudflare Tunnel phase exposed that gap. The Cloudflare **zone config**, the
**tunnel**, and the **DNS records** are external cloud state that fits neither
Ansible (not the host) nor ArgoCD (not the cluster). We currently create them by
hand — `cloudflared tunnel create`, `cloudflared tunnel route dns`, and the
dashboard — which is neither reproducible nor declarative. A per-hostname manual
CLI step is the odd one out in an otherwise automated setup.

This is a learning project, and **Terraform is the industry-standard tool for
this layer** and a highly transferable skill — arguably more valuable than
Helmfile, which we dropped (ADR-0003).

## Decision

**Adopt Terraform as the IaC tool for external/cloud resources, starting with
Cloudflare.** Terraform owns the Cloudflare **zone** (settings), the **tunnel**
(`cloudflare_zero_trust_tunnel_cloudflared` + its config), and the **DNS
records** (CNAMEs to the tunnel).

- **Boundaries unchanged.** Ansible still installs/runs `cloudflared` on the host
  (ADR-0002); ArgoCD still owns the cluster (ADR-0003). Terraform manages
  *neither* host nor cluster resources — only the Cloudflare side.
- **Recreate, don't import.** The manually-created tunnel (`cee9c4b7…`) will be
  **recreated** by Terraform for clean state — *not* `terraform import`. This
  produces a **new tunnel ID and secret**, so the codify phase must update
  `cloudflared_tunnel_id` in `group_vars` and re-encrypt the new credential
  (`cloudflared-credentials.sops.yaml`), then re-run the Ansible role.
- **Layout:** Terraform config lives in `terraform/`.
- **external-dns** is noted as a *possible future complement* for dynamic
  per-Ingress DNS records; for now Terraform owns the static zone/tunnel/DNS.

### What the future build phase will include (not now)

1. A Cloudflare **API token** (scoped to the zone + Zero-Trust/tunnel perms) —
   stored via SOPS or passed as an env/`TF_VAR`, **never committed plaintext**.
2. `terraform/` with the provider, the tunnel, its config, and DNS resources.
3. `.gitignore` entries for Terraform's **sensitive state** (`*.tfstate*`,
   `.terraform/`, secret `*.tfvars`).
4. A runbook (`docs/guides/terraform-cloudflare.md`) superseding the manual
   `tunnel create` / `route dns` steps.

## Consequences

**Positive**

- External infra becomes **reproducible and declarative**; the manual
  Cloudflare steps become code.
- Clean, complete layer separation: **host = Ansible, cluster = ArgoCD, external
  = Terraform.**
- Learn Terraform — a core DevOps skill and the project's point.

**Negative / trade-offs**

- A new tool and a **state file that is sensitive** (it holds the tunnel
  secret): must be gitignored and protected; a remote/encrypted backend is a
  later consideration.
- Another credential to manage (the Cloudflare API token).
- **One-time churn:** recreating the tunnel changes its ID/secret, so the
  credential must be re-encrypted and the host redeployed once.
- Terraform's imperative `apply` is outside ArgoCD's continuous reconciliation
  (run from CLI/CI) — acceptable and normal for external infra.

**Alternatives considered**

- *Ansible task* (`delegate_to: localhost` running `cloudflared route dns`) —
  rejected: wrong layer, imperative, and declares hostnames in two places.
- *external-dns only* — rejected as the primary owner: it doesn't manage the
  zone or the tunnel. Better later as a *complement* for per-Ingress records.
- *Stay manual* — rejected: not reproducible.
- *Crossplane* (cloud infra as k8s CRDs, GitOps-native) — heavier, and Terraform
  is the more transferable skill to learn first.

## Related

- [ADR-0002](0002-cloudflare-tunnel-host-daemon-to-traefik.md) — the tunnel
  architecture Terraform will provision the Cloudflare side of.
- Supersedes the manual `cloudflared tunnel create` / `route dns` steps in
  `docs/guides/cloudflare-tunnel-setup.md`.
