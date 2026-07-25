# ADR-0009: Self-hosted Keycloak as the homelab identity provider

## Status

Accepted — 2026-07-24.

> **Update (2026-07-24):** the *deployment mechanism* described below (the bitnami
> Helm chart) is **superseded by [ADR-0014](0014-keycloak-operator.md)** — Keycloak
> is now deployed via the official Keycloak Operator, because Bitnami discontinued
> its free images/charts in 2025. The core decision of *this* ADR — self-hosted
> Keycloak as the IDP for admin surfaces and app login — **stands unchanged.**

## Context

The next layer of the lab is securing applications: giving a public-facing app
**real user accounts + role-based access control**, and gating **admin surfaces**
(the ArgoCD UI, future dashboards) so only the operator can reach them. Both need
an **identity provider (IdP)**. The project's goal is to *understand* auth, not
just switch it on (`CLAUDE.md`).

The candidates span very different categories:

- **Keycloak** — a mature, standalone IdP server; language-agnostic OIDC / OAuth2
  / SAML authority. Apps in any language are clients of it.
- **Authentik** — a lighter self-hosted IdP; similar role, less ubiquitous.
- **Cloudflare Access** — external, managed identity, integrates with the tunnel
  we already run ([ADR-0002](0002-cloudflare-tunnel-host-daemon-to-traefik.md)).
- **Better Auth / Neon Auth** — a TypeScript in-app auth *library* (Better Auth),
  optionally managed by Neon storing users in a `neon_auth` schema.

Constraints and forces: a **single node** (resource-conscious); **public-facing**
from day one; a **mixed-language fleet** (a Spring/Java demo app + ArgoCD + future
apps); and above all the **learning goal** — the whole reason this layer exists is
to learn how identity and auth actually work.

## Decision

**Self-host Keycloak, in-cluster, as the single IdP for both admin surfaces and
application login.** Specifically:

- **Keycloak over the alternatives** because it is the **canonical, best-documented**
  OIDC provider for our Spring app, **production-grade** for the public-facing role,
  **language-agnostic** (serves Spring + ArgoCD + anything future), and it teaches
  the **industry standard** — which *is* the learning goal.
- **Cloudflare Access rejected** — external identity is a dead end for *owning*
  user accounts, and leans further on a single vendor.
- **Authentik rejected** — lighter, but Keycloak is the named learning target and
  has the deeper tutorial ecosystem for Spring.
- **Better Auth / Neon Auth rejected (for now)** — they are TypeScript-library
  shaped; cross-language / central-IdP use rests on Better Auth's OIDC-provider
  plugin, which its own docs flag *not production-ready*. Decisively, offloading
  auth to a managed service removes **the exact thing this project exists to
  learn** (the DB-offload logic in [ADR-0011](0011-neon-managed-postgres.md)
  *inverts* here — DB ops isn't the goal, auth is).
- **Deployment:** the bitnami Keycloak Helm chart (a third-party chart, per
  [ADR-0008](0008-app-delivery-plain-manifests-and-apex-routing.md)) as an ArgoCD
  `Application`, in **production mode**, backed by external Neon
  ([ADR-0011](0011-neon-managed-postgres.md)).

## Consequences

**Positive**

- Learn a real, standard IdP: realms, clients, OIDC/OAuth2 flows, and RBAC from
  the provider side — transferable well beyond this lab.
- One IdP serves the whole mixed fleet; the same instance gates ArgoCD *and*
  authenticates the app.
- Owns the accounts and the identity data outright — no external identity vendor.

**Negative / trade-offs**

- **Heaviest option on a single node** — a JVM plus a database — versus a managed
  service that would give that compute/memory back. Acknowledged and accepted.
- Real operational surface: realms, clients, upgrades, a public-facing auth store
  to keep healthy.
- **Revisit triggers:** priorities shift from *learning* → *shipping*; the fleet
  becomes TypeScript + Neon Data-API shaped; or node resource pressure becomes
  acute. Any of these would reopen Neon Auth / a managed IdP.

**Alternatives considered**

- *Authentik* — lighter self-hosted IdP; rejected as off the primary learning
  target with less Spring-focused material.
- *Cloudflare Access* — managed external identity; rejected — can't own accounts,
  deepens single-vendor reliance.
- *Better Auth (self-run TS microservice)* / *Neon Auth (managed)* — excellent for
  in-app TS auth, but a poor central IdP for a Java+ArgoCD fleet, and offloading
  auth defeats the learning purpose.
