# ADR-0018: Host a second domain in the katomatik account; Cloudflare layer becomes multi-zone

## Status

Accepted — 2026-08-07. **Revises the account framing of
[ADR-0007](0007-dedicated-katomatik-cloudflare-hcp-accounts.md)** (which stays
Accepted — its clean-room account cut is untouched).

## Context

The lab needed to serve a second public site, `kurtcebe.nl` (a small static
landing page), alongside `katomatik.com`. That sounds like "add another app",
but it collided with an earlier decision.

ADR-0007 rebuilt the external layer in a Cloudflare + HCP account **dedicated to
the katomatik project**, and explicitly listed the `kurtcebe.nl` zone among the
old-account orphans being wound down. Serving that domain here reverses part of
that framing: the "dedicated" account now holds a differently-branded domain.

Four forces shaped the *how*:

- **A Cloudflare Tunnel is account-bound.** A `<tunnel-id>.cfargotunnel.com`
  CNAME only resolves for zones in the **same Cloudflare account**. A second
  account would therefore mean a second tunnel, a second cloudflared credential,
  and a second host daemon — for one static page.
- **Traefik already routes by `Host`.** Nothing in the cluster is
  domain-specific; a new hostname is a new `Ingress` rule, not new plumbing
  (ADR-0002, ADR-0008).
- **The Terraform layer was single-zone by construction** — one
  `cloudflare_zone.primary`, a scalar `cloudflare_zone_name`, a flat `hostnames`
  list, and one hardcoded apex record. A second apex simply did not fit.
- **Cloudflare will not activate a domain that is active in another account.**
  The old personal account still held the `kurtcebe.nl` zone, so the domain had
  to be released before it could be created here.

## Decision

**Serve both domains from one account, one tunnel, one workspace, and one repo —
and generalise the Terraform from "the zone" to "a map of zones".**

- **Reuse the existing Cloudflare account, HCP workspace (`katomatik-com`), and
  tunnel.** A second domain adds *no* infrastructure: no tunnel, no credential
  rotation, no Ansible change. The tunnel and `random_bytes` resources stay
  singular and shared.
- **Replace `cloudflare_zone_name` + `hostnames` with a single `zones` map keyed
  by apex.** `for_each` drives the zone and the apex record; a `locals` block
  flattens the map into one entry per subdomain record, keyed `<zone>/<label>`.
  Adding a domain is now a tfvars entry, not a copy of the resources.
- **Re-address the existing resources with `moved {}` blocks, not
  `terraform state mv`.** Renaming addresses while the remote objects stay put
  would otherwise read as destroy-plus-create of live production DNS. `moved`
  ships in the same commit, is reviewable in the diff, and applies inside the
  normal HCP run — preserving ADR-0007's avoidance of state surgery. The
  acceptance test was the plan itself: **0 to add, 0 to destroy.**
- **Sequence the cutover as release-then-delegate**: delete the zone in the old
  account *first*, then create it here, and only then change the registrar's
  nameservers.
- **Keep the apex + `www` 301 pattern** from ADR-0008 — `www.kurtcebe.nl`
  redirects to the apex via a Traefik `Middleware`, matching `katomatik.com`.

## Consequences

**Positive**

- **A new domain is a tfvars entry.** Zone, apex record, and subdomain records
  all follow from one map key; there is a single code path rather than a
  per-domain copy that drifts.
- **No new moving parts.** One tunnel, one cloudflared, one Traefik, one HCP
  workspace serve every domain. The marginal cost of domain *n+1* is a DNS
  record and an `Ingress` rule.
- **The refactor was provably safe.** Address moves are declarative and were
  verified by a zero-destroy plan before apply; the existing domain's records
  kept their Cloudflare IDs.

**Negative / trade-offs**

- **Shared blast radius.** One API token, one workspace, one state file, one
  `apply` now covers both domains. A bad change or a revoked token affects
  everything, where separate accounts would have contained it. This is the
  deliberate reversal of ADR-0007's isolation argument, accepted because the
  isolation was buying little at homelab scale and costing a whole tunnel.
- **Names now under-describe their contents.** The workspace `katomatik-com` and
  the repo `katomatik-infra` hold a domain that is neither. Tracked as KI-24.
- **Map keys are load-bearing.** The apex key and subdomain labels build every
  resource address, so *renaming or removing* one is a real destroy — only
  additions are free. A rename needs its own `moved` block.
- **A cutover window with two claimants.** Until the old zone is deleted, both
  accounts' nameservers can answer for the domain, and resolvers holding a
  cached NS RRset (TTL 86400 at the child) may keep asking the old pair and get
  an authoritative "no such record" — a *lame delegation*. Release-then-delegate
  keeps that window closed; doing it in the other order would have made
  resolution depend on which nameserver a resolver happened to ask.
- **Registrar delegation stays manual** — the same irreducible step as ADR-0007.
- **The duplication ADR-0008 predicted has arrived.** `manifests/kurtcebenl-web/`
  is near-identical to `manifests/katomatik-web/`. ADR-0008 named exactly this as
  the trigger to revisit Helm or Kustomize; we consciously duplicated once more
  rather than introduce templating in the same change as a DNS refactor. The
  third static site should force the question.

**Alternatives considered**

- *A second Cloudflare account (and tunnel) for kurtcebe.nl* — rejected: the
  account boundary forces a second tunnel and credential for a static page,
  tripling the moving parts to isolate something with no independent
  availability or billing requirement.
- *A second HCP workspace sharing the account* — rejected: the tunnel ID would
  have to cross workspaces (a data source or a hardcoded value), reintroducing
  the cross-state coupling ADR-0007 was glad to avoid.
- *A local Terraform module instantiated per domain* — rejected for now: with two
  near-identical zones, a `for_each` map expresses the same thing with less
  machinery. Worth revisiting if domains start differing structurally.
- *Duplicating the zone resources in a flat second copy* — rejected: no state
  churn, but it duplicates the pattern and rots on the third domain.

## Related

- [ADR-0007](0007-dedicated-katomatik-cloudflare-hcp-accounts.md) — established
  the dedicated accounts and Terraform-owned zone; this **revises its account
  framing** and generalises the zone into a map.
- [ADR-0005](0005-terraform-for-cloudflare-external-layer.md) — why the external
  layer is Terraform at all.
- [ADR-0002](0002-cloudflare-tunnel-host-daemon-to-traefik.md) — the single
  catch-all tunnel that makes one tunnel per *account* (not per domain) work.
- [ADR-0008](0008-app-delivery-plain-manifests-and-apex-routing.md) — the
  per-app manifests and apex + `www` routing pattern reused here, and the source
  of the templating question this ADR reopens.
