# ADR-0014: Deploy Keycloak via the official Keycloak Operator

## Status

Accepted — 2026-07-24. Revises the deployment mechanism of
[ADR-0009](0009-self-hosted-keycloak-idp.md) (which chose the bitnami Helm chart);
that ADR's IDP decision otherwise stands.

> **Update (2026-07-26):** the realm/client **configuration** approach below
> (`KeycloakRealmImport` / `KeycloakOIDCClient` CRs) is superseded by
> [ADR-0015](0015-keycloak-config-via-terraform.md) — realm-import is create-only, so
> config moves to the Terraform Keycloak provider. The operator's role narrows to the
> **instance**; the rest of this ADR stands.

## Context

[ADR-0009](0009-self-hosted-keycloak-idp.md) chose self-hosted Keycloak, to be
deployed via the **bitnami Keycloak Helm chart**. That path has since become
untenable:

- **Bitnami discontinued its free images/charts in 2025.** The images moved out of
  `docker.io/bitnami/*`; the old ones were archived under `bitnamilegacy` **with no
  future security patches**, and current images sit behind the paid "Bitnami Secure
  Images" program. For a **public-facing auth server**, running an unpatched image
  is not acceptable, and paying for it is off-scope for a home lab.

A replacement is needed. Surveying the options:

- **Keycloak Operator** — the Keycloak team's official Kubernetes-native path
  (CRD-based), built on the **actively-maintained official image**
  (`quay.io/keycloak/keycloak`).
- **codecentric `keycloakx`** — a community Helm chart wrapping the official image.
- **A first-party Helm chart** — none mature exists; the Keycloak project's k8s
  story is the Operator, not a chart.

## Decision

**Deploy Keycloak via the official Keycloak Operator.** Specifically:

- **Install the operator** (its CRDs + controller) as an ArgoCD `Application` from
  the official release manifests, **version-pinned** (same discipline as the k3s
  and ArgoCD pins).
- **Declare the instance with a `Keycloak` CR** — official image, **external Neon**
  database ([ADR-0011](0011-neon-managed-postgres.md)) via a KSOPS-decrypted Secret
  ([ADR-0012](0012-argocd-sops-decryption-ksops.md)), hostname `auth.katomatik.com`,
  production mode (trusts Traefik's `X-Forwarded-*`, HTTPS enforced), and a
  **small DB connection pool** to fit the free-tier Neon compute.
- **Declare realm configuration with `KeycloakRealmImport` CR(s)** — the realm, its
  OIDC clients (ArgoCD, the Spring app), and roles, as **Git-managed YAML** that
  ArgoCD reconciles.

## Consequences

**Positive**

- **Official, actively-patched image** — the security posture a public-facing auth
  server requires (the specific thing bitnami's legacy image can't give).
- **GitOps-native, end to end.** Both the *instance* (`Keycloak` CR) and its
  *realm/client/role configuration* (`KeycloakRealmImport` CR) are declarative
  resources ArgoCD reconciles — no click-ops. Identity config lives in Git:
  reviewable in PRs, **self-healing** against UI drift, and **reproducible** on a
  rebuild. When we gate ArgoCD (Phase 1) and wire the Spring app (Phase 2/3), each
  OIDC **client** is committed YAML, not console clicks.
- **Teaches operators + CRDs** — a core Kubernetes pattern, squarely on-goal for a
  learning lab.

**Negative / trade-offs**

- **More concept than a single Helm release** — an operator plus CRDs to learn and
  install. Accepted; the operator *is* the officially-supported path and the
  learning is on-goal.
- **Realm import manages declarative *config*, not runtime *data*.** End-user
  accounts live in Postgres/Neon (correct — never in Git). Update semantics for an
  already-imported realm are version-specific, and client secrets need careful
  handling via Secrets.
- **Another controller** running on the single node (modest overhead).

**Alternatives considered**

- *Bitnami Helm chart* (ADR-0009's original) — rejected: free distribution
  discontinued; only an unpatched legacy image or a paid program remain.
- *codecentric `keycloakx`* — viable (Helm + official image), but community-
  maintained and not GitOps-native for realm configuration; rejected in favour of
  the official operator's declarative CRs.
- *A single generic Helm chart* — no official, maintained chart fills the gap.
