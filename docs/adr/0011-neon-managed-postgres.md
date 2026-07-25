# ADR-0011: Managed external Postgres (Neon) for stateful app data

## Status

Accepted — 2026-07-24.

## Context

Keycloak ([ADR-0009](0009-self-hosted-keycloak-idp.md)) needs a relational
database, and future apps likely will too. On a **single node**, running Postgres
in-cluster costs memory/compute and brings real operational burden — PVCs,
backups, HA — and **database operations are not this layer's learning goal**
(auth is).

The lab already has an established pattern of **offloading undifferentiated infra
to managed services**: the Cloudflare Tunnel for the edge
([ADR-0002](0002-cloudflare-tunnel-host-daemon-to-traefik.md)) and HCP for
Terraform state ([ADR-0005](0005-terraform-for-cloudflare-external-layer.md),
[ADR-0007](0007-dedicated-katomatik-cloudflare-hcp-accounts.md)). A managed
Postgres fits that same philosophy.

## Decision

**Use Neon (managed serverless Postgres) for stateful application data.**
Specifically:

- **One Neon *project* per app** (Keycloak gets its own). The free-tier quotas are
  **per project** (0.5 GB storage + 100 compute-hours each; 100 projects free as
  of 2026-01-15), so project-per-app **maximises free resources** *and* gives
  clean isolation — no shared compute/blast-radius, no cross-database
  `PUBLIC CONNECT` worry. Each project holds its own database + role.
- **EU region, set per project** in Terraform (region is immutable and *not* an
  account default).
- **Direct connection string, not the pooler.** Neon's pooler is PgBouncer in
  transaction mode, which breaks Keycloak's Liquibase advisory locks and pgJDBC
  server-side prepared statements; Keycloak keeps its own (Agroal) pool anyway.
  (The app's DB pool is sized down to fit the small free-tier compute's connection
  slots.)
- **Managed as code** via the community **`kislerdm/neon`** Terraform provider
  (Neon-sponsored, not official — **version-pinned**), extending the external
  layer of [ADR-0005](0005-terraform-for-cloudflare-external-layer.md). The Neon
  **API token** is a sensitive HCP variable; the **account** is a manual,
  out-of-band prerequisite (like the Cloudflare/HCP accounts,
  [ADR-0007](0007-dedicated-katomatik-cloudflare-hcp-accounts.md)).
- **The per-app DB credential reaches the cluster** as a SOPS-encrypted Secret,
  decrypted by ArgoCD via KSOPS
  ([ADR-0012](0012-argocd-sops-decryption-ksops.md)).

## Consequences

**Positive**

- Zero database compute/memory on the node; no PVCs, backups, or HA to operate.
- Consistent with the managed-service philosophy already in use; readable
  infrastructure-as-code; the free tier is ample for the lab.
- Per-project isolation means one app's database issues can't touch another's.

**Negative / trade-offs**

- **External dependency for a core service** — if Neon is unavailable, logins fail.
  Acceptable for a home lab; named here.
- **Community (not official) provider** — pinned in `.terraform.lock.hcl`; a
  supply-chain trust to accept knowingly.
- **Scale-to-zero cold starts** add latency to the first request after idle.
- Gives up learning **Postgres-on-Kubernetes** — fine, since it isn't this layer's
  goal; revisit as a dedicated exercise (e.g. CloudNativePG) if desired.
- Some vendor coupling, mitigated: the data is standard Postgres and portable.

**Alternatives considered**

- *In-cluster Postgres* (bitnami subchart or CloudNativePG) — rejected: resource
  cost + operational burden on one node, and DB-ops isn't the learning target.
- *The Keycloak chart's bundled Postgres, shared by other apps* — rejected: a
  bundled subchart is lifecycle-coupled to its release; sharing it creates hidden
  coupling between apps.
- *One shared Neon project, a database per app* — rejected once per-project quotas
  made **project-per-app** strictly better on both free resources and isolation.
