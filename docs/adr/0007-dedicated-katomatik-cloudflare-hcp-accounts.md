# ADR-0007: Dedicated katomatik Cloudflare + HCP accounts; Terraform owns the zone

## Status

Accepted — 2026-07-21. **Extends [ADR-0005](0005-terraform-for-cloudflare-external-layer.md).**

> **Update (2026-08-07):** the *account framing* below — accounts "dedicated to
> the katomatik project", with the `kurtcebe.nl` zone listed among the orphans
> being wound down — is **revised by
> [ADR-0018](0018-second-domain-multi-zone-cloudflare.md)**. That domain is now
> served from *this* account, sharing its tunnel and workspace, and the
> single-zone Terraform shape described here (`cloudflare_zone.primary`,
> `cloudflare_zone_name`, a flat `hostnames` list) is generalised into a `zones`
> map. The core decisions of *this* ADR — dedicated accounts as a clean-room cut,
> and Terraform owning the zone — **stand unchanged.**

## Context

The project rebranded from `kurtcebe.nl` to `katomatik.com` and moved to a new
public repo (`katomatik-com/katomatik-infra`; see
[ADR-0006](0006-public-repo-anonymous-https.md)). The external Cloudflare layer
(ADR-0005) still lived in the old setup:

- a **personal Cloudflare account** tied to `kurtcebe.nl`;
- HCP state + remote execution in org `kurt_homelab`, workspace `homelab`;
- the **zone created by hand** in the Cloudflare dashboard and passed to
  Terraform as an input (`cloudflare_zone_id`) — Terraform owned only the tunnel
  and the DNS records *inside* that zone.

For the new site we wanted clean separation — a Cloudflare account dedicated to
the katomatik project (its own ownership/billing, the old one wound down), a
matching HCP org/workspace, and the **zone itself under IaC** instead of
click-ops. Three forces shaped *how*:

- A **Cloudflare API token is scoped to one account** — a new-account token
  cannot read or destroy old-account resources, so Terraform can't "move" them.
- **HCP `cloud {}` workspaces hold independent state**; there is no cross-org
  state migration here — a new workspace simply starts empty.
- The **Cloudflare Tunnel is account-bound** — a new account means a *new tunnel*
  (new ID + secret + credential), forcing a cloudflared credential rotation.

## Decision

Rebuild the external layer in **dedicated accounts as a clean-room cut**, not a
migration.

- Move state + execution to a **new HCP org/workspace** (`katomatik` /
  `katomatik-com`, CLI-driven, Remote execution) and the Cloudflare resources to
  a **new, dedicated Cloudflare account**.
- **Terraform now creates and owns the zone** via `cloudflare_zone.primary`,
  replacing the dashboard-created zone. The input is now `cloudflare_zone_name`
  (the apex domain); the zone ID is a computed reference used by the DNS records.
- Because the fresh HCP workspace starts with **empty state**, no state
  migration and **no `terraform state` surgery** is needed: `terraform init`
  then `apply` creates the zone, tunnel, and DNS records fresh. The `apply` plan
  is **all-creates, zero-destroys** — the proof the cut is clean.
- The old HCP workspace and old-account resources (old tunnel, DNS, the
  `kurtcebe.nl` zone) are **abandoned as orphans**, removed later by hand or by
  deleting the old accounts.
- The zone is created **"Pending"**; activation needs a one-time **nameserver
  delegation at the registrar** — the one step no IaC tool can do. Terraform
  surfaces the assigned pair via the `zone_name_servers` output.
- The new account **recreates the tunnel**, so the cloudflared credential is
  rotated in the same change: new `cloudflared_tunnel_id` in `group_vars`, a
  re-encrypted SOPS credential, and an Ansible redeploy (per ADR-0005 Part 5).

## Consequences

**Positive**

- The katomatik project is cleanly isolated in its own Cloudflare + HCP accounts
  (ownership, billing, and blast-radius separation); the `kurtcebe.nl`-era
  account can be retired wholesale.
- The zone is now **fully IaC** — reproducible, reviewable, no click-ops, one
  fewer manual dashboard step to drift.
- The clean-room approach **avoided fragile state surgery**: an empty new
  workspace yields an all-creates plan with nothing to destroy across accounts —
  much safer than a two-token, cross-account migration.

**Negative / trade-offs**

- Old-account resources and the old HCP workspace are **orphaned** until deleted
  — dangling state and possible cost if the old accounts aren't wound down.
- The token needs **Zone : Edit on *all zones*** (to create the zone) — broader
  than the previous single-zone read, a small step away from least privilege.
- The **registrar nameserver change** remains an irreducible manual step to
  activate the zone.
- Recreating the tunnel forced another credential rotation (bundled here so it
  happened once).

## Related

- [ADR-0005](0005-terraform-for-cloudflare-external-layer.md) — established
  Terraform for the external Cloudflare layer; this **extends** it to *create*
  the zone and moves the whole layer to dedicated accounts.
- [ADR-0006](0006-public-repo-anonymous-https.md) — public repo + HTTPS, the
  repo half of the same katomatik rebrand.
- [ADR-0002](0002-cloudflare-tunnel-host-daemon-to-traefik.md) — the tunnel
  topology the credential rotation serves.
