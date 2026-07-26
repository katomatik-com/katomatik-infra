# ADR-0015: Manage Keycloak realm/client configuration with Terraform

## Status

Accepted — 2026-07-26. Revises the realm/client **configuration** approach of
[ADR-0014](0014-keycloak-operator.md) (which planned `KeycloakRealmImport` /
`KeycloakOIDCClient` CRs). The Keycloak *instance* decision in ADR-0014 stands;
only *config management* changes here.

## Context

The Keycloak **instance** is Operator-managed ([ADR-0014](0014-keycloak-operator.md)).
For **configuration** (realms, clients, roles, groups, protocol mappers) we planned
to use the operator's CRs. Implementing Phase 1 (add an ArgoCD OIDC client) exposed
hard limits:

- **`KeycloakRealmImport` is create-only.** The docs state it *"only supports
  creation of new realms and does not update or delete those"*; if the realm exists,
  the import is skipped ([keycloak.org/operator/realm-import](https://www.keycloak.org/operator/realm-import),
  [issue #21974](https://github.com/keycloak/keycloak/issues/21974)). Confirmed
  empirically: adding the `argocd` client to the CR synced in ArgoCD, but the
  operator never re-imported (Job untouched, `Done=True`, client absent).
- **`KeycloakOIDCClient` is `v2alpha1`** (alpha) and its schema is too limited — no
  `publicClient`, PKCE attributes, or `standardFlowEnabled` — so it can't express the
  clients we need.

So the operator's declarative *config* story can't manage clients/groups/mappers
**incrementally** — and we need to add clients over time (ArgoCD now, the Spring app
later) **without** recreating the realm and losing runtime data (users).

## Decision

**Manage Keycloak realm/client/role/group/mapper configuration with the Terraform
Keycloak provider** (`keycloak/terraform-provider-keycloak`). The Operator owns the
**instance**; Terraform owns the **config**. Specifically:

- A **separate, locally-run** Terraform workspace at `terraform/keycloak/`.
- It authenticates to the Keycloak **admin REST API** over
  `kubectl port-forward svc/keycloak-service 8080:8080` (provider
  `url = http://localhost:8080`), with admin credentials (bootstrap
  `keycloak-initial-admin` now; a dedicated Terraform service-account client later).
  **The admin API/console stays private — never exposed.** The fixed-`hostname`
  browser redirect does **not** affect REST calls (proven: `kcadm` managed the realm
  over `localhost:8080`).
- **Drop the `KeycloakRealmImport` CR**; Terraform becomes the source of truth for
  Keycloak config.
- Rationale: consistent with the IaC split already in use — **API-driven config →
  Terraform** (Cloudflare [ADR-0005](0005-terraform-for-cloudflare-external-layer.md),
  Neon [ADR-0011](0011-neon-managed-postgres.md)); **in-cluster workloads → ArgoCD**
  ([ADR-0003](0003-argocd-only-gitops-helmfile-dropped.md)). Keycloak config is
  API-driven, so Terraform is its natural home.

## Consequences

**Positive**

- Proper **incremental** CRUD for clients/groups/mappers — no realm recreation, no
  losing users; real `plan`/`apply` diffs.
- A mature, well-documented provider instead of create-only / alpha operator CRs.
- **Admin API stays private** (port-forward only); no public `/admin`.
- Architecturally consistent with the existing Terraform layer.

**Negative / trade-offs**

- **Keycloak config is not ArgoCD-GitOps** — it's Terraform. A deliberate split
  (config via Terraform, workloads via ArgoCD).
- A **separate, locally-run** workspace (not HCP remote like the Cloudflare/Neon one)
  — HCP remote execution can't reach the in-cluster admin API. Two TF execution
  contexts to keep straight.
- Applies need a **running port-forward** (manual; scriptable).
- Terraform needs **admin credentials** (bootstrap initial-admin → a dedicated
  service-account client is the follow-up hardening).

**Alternatives considered**

- *`KeycloakRealmImport`* — create-only; can't update existing realms. Rejected for
  config (still usable for a one-time realm bootstrap, but we consolidate on Terraform).
- *`KeycloakOIDCClient` / `KeycloakSAMLClient` CRs* — `v2alpha1`, too limited
  (no publicClient/PKCE). Revisit if they mature.
- *Recreate the realm on each change* — destroys users; rejected.
- *`kcadm` scripts* — imperative, not declarative; rejected as the primary tool
  (still handy for one-off admin operations).
