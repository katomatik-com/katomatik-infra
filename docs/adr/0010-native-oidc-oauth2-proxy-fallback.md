# ADR-0010: Workload auth via native OIDC; oauth2-proxy as the fallback

## Status

Accepted — 2026-07-24.

## Context

With Keycloak as the IdP ([ADR-0009](0009-self-hosted-keycloak-idp.md)), every
workload we want to protect has to authenticate against it. There are two
integration patterns:

- **Native OIDC** — the workload itself speaks OIDC (it *is* an OIDC client),
  handling login, session/token, and role mapping in-process.
- **Forward-auth proxy** — an edge component (e.g. **oauth2-proxy** behind a
  Traefik `ForwardAuth` middleware) authenticates the request *before* it reaches
  a workload that has no auth of its own.

The workloads we care about actually split three ways by capability:

- **The Spring demo app** — has a real backend; can speak OIDC natively.
- **ArgoCD** — ships with built-in OIDC support.
- **`katomatik-web`** — a *static* site ([ADR-0008](0008-app-delivery-plain-manifests-and-apex-routing.md));
  no backend, so it *cannot* authenticate itself.

## Decision

**Prefer each workload's native OIDC; reserve oauth2-proxy / forward-auth only for
workloads that cannot authenticate themselves.** Specifically:

- **Spring app → in-app OIDC.** Spring Security as an OIDC **client**; roles from
  Keycloak map to Spring `GrantedAuthority`, and RBAC is enforced in-app. This is
  required for the learning goal — the app's principal-details page must see the
  identity *inside* the app, which a front proxy would hide.
- **ArgoCD → its built-in OIDC** (`argocd-cm` → Keycloak). No proxy.
- **oauth2-proxy → the fallback**, used *only* for auth-less workloads (e.g. if we
  ever gate the static `katomatik-web`). It is not the default and never fronts a
  workload that already speaks OIDC.

This yields a reusable rule for every future app: *does it speak OIDC itself? Then
it's an OIDC client. If not, put oauth2-proxy in front.*

## Consequences

**Positive**

- Fewest moving parts per app; no redundant proxy in front of apps that already do
  OIDC.
- Teaches the full OIDC flow **inside** the application — the point of the demo.
- A clear, reusable decision rule for onboarding future workloads.

**Negative / trade-offs**

- Each language/app must implement OIDC itself — some duplicated effort across a
  polyglot fleet (the price of not hiding auth behind one proxy).
- Auth-less workloads still need the proxy path, so the lab must eventually learn
  *both* mechanisms — accepted, since they cover genuinely different cases.
- The client *shape* (server-side session via `oauth2Login` vs stateless bearer
  tokens via `oauth2ResourceServer`) is deferred to the app's own build phase —
  this ADR fixes only the *native-OIDC-preferred* principle, not the per-app flow.

**Alternatives considered**

- *oauth2-proxy in front of everything* — uniform, but it hides identity from the
  app (breaking the principal-details learning goal) and is redundant wherever
  native OIDC exists.
- *App-local users (Spring's own user store)* — teaches Spring Security but nothing
  about IdPs/OIDC; a dead end for the central-SSO goal.
