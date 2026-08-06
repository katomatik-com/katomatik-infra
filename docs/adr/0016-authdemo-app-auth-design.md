# ADR-0016: App auth design — client roles, a confidential client, and RBAC in the app

## Status

Accepted — 2026-08-06. Applies [ADR-0010](0010-native-oidc-oauth2-proxy-fallback.md)
(native OIDC in-app) to the first real relying party, `katomatik-authdemo`, and fixes the
per-app pattern the rest of the fleet will follow. Configuration is managed under
[ADR-0015](0015-keycloak-config-via-terraform.md).

## Context

[ADR-0010](0010-native-oidc-oauth2-proxy-fallback.md) settled the *principle* — a
workload that can speak OIDC is an OIDC client, and oauth2-proxy is only for workloads
that cannot — but deliberately deferred the client *shape* to the app's own build phase.
Building `katomatik-authdemo` (Spring Boot 4.1 / Spring Security 7, deployed at
`https://authdemo.katomatik.com`) forced three questions that every future app will meet
in the same order:

- **What shape should authorization data take?** Keycloak offers realm roles, client
  roles, and groups. ArgoCD already uses **groups**, because its own RBAC engine maps a
  group name to a built-in role (`g, argocd-admins, role:admin`) and the only open
  question is which people are members. An app with no permission model of its own is a
  different case: it must define both the vocabulary *and* the enforcement.
- **Confidential or public + PKCE?** The existing `argocd` client is PUBLIC + PKCE
  because its code→token exchange runs in the browser, where no secret can survive. A
  Spring server-side app is not in that position.
- **Where is access control enforced?** In the app, or in front of it.

A fourth constraint appeared during implementation and shaped the design: Keycloak's
built-in client-roles mapper writes `resource_access.<client>.roles` to the **access
token only**, while Spring's OIDC login builds its authorities from the **ID token**. The
mismatch does not error — it produces successful logins with zero roles.

## Decision

**Use client roles, a confidential client, and enforce RBAC inside the app.**
Specifically, for `katomatik-authdemo` and as the default for future self-authenticating
apps:

- **Client roles, not realm roles.** `user` and `admin` are defined *on the
  `katomatik-authdemo` client*, so those names carry no authority anywhere else in the
  realm. Realm roles are reserved for something genuinely realm-wide. Groups remain the
  right tool where an app supplies its own permission model and only needs membership —
  ArgoCD keeps using them.
- **A CONFIDENTIAL client**, with the secret delivered as a SOPS-encrypted Secret
  ([ADR-0012](0012-argocd-sops-decryption-ksops.md)) and read from the environment. The
  code→token exchange is server-to-server, so the secret authenticates the *client*, not
  just possession of an authorization code.
- **PKCE (S256) enforced as well**, on the confidential client. Verified on the wire:
  Spring Security 7 sends `code_challenge_method=S256` for confidential clients, unlike
  Spring Security 6. Defence in depth, not a substitute for the secret.
- **A dedicated protocol mapper with `add_to_id_token = true`**, scoped to this client
  and emitting a flat `roles` claim — attached to the *client*, not to the shared `roles`
  client scope, so no other client's tokens change.
- **Keycloak keeps its own idiom; Spring keeps its own.** Role names stay lowercase and
  unprefixed in Keycloak; the `ROLE_` prefix and upper-casing are applied by a
  `GrantedAuthoritiesMapper` in the app.
- **RBAC enforced in the app**, in one `SecurityConfig` filter chain rather than
  annotations spread across controllers — `/user/**` needs `ROLE_USER`, `/admin/**` needs
  `ROLE_ADMIN`, `/public/**` stays anonymous as a control case.
- **RP-initiated logout**, ending the Keycloak SSO session and not only the local one,
  with the post-logout redirect URI registered explicitly (not `"+"`, since Spring returns
  to the app root rather than the callback path).

The reasoning and the traps are written up in
[securing-an-app-with-oidc.md](../guides/securing-an-app-with-oidc.md).

## Consequences

**Positive**

- **Blast radius equals the client.** Granting someone `admin` in one app can never
  become authority in another — the failure mode where a role in a toy app confers
  production access is structurally impossible.
- **A real client credential**, which a browser-based flow cannot have, plus PKCE's
  binding of the code to the session that requested it.
- **Identity data stays framework-neutral.** A future Go or Python relying party reads
  `user`/`admin`, not Spring's `ROLE_` convention.
- **The whole access policy is readable on one screen**, and the app sees the identity
  directly — which is the learning goal ADR-0010 protected by rejecting a front proxy.
- **A repeatable per-app recipe**: client + client roles + ID-token mapper + confidential
  secret via SOPS + pinned public URLs.

**Negative / trade-offs**

- **Client roles do not compose across apps.** Someone who should be admin everywhere
  must be granted the role in each client. Correct for isolation, more work at scale; the
  answer when it hurts is composite roles or group-carried roles, not realm roles.
- **A secret now exists** — to encrypt, deliver, and eventually rotate. Rotation is
  manual today (`terraform apply` plus a re-encrypted SOPS file and a pod restart).
- **A per-client protocol mapper is per-app boilerplate**, and forgetting it produces the
  silent zero-roles failure rather than an error.
- **RP-initiated logout signs the user out of every app**, ArgoCD included. Correct, and
  a shared-fate behaviour to be aware of.
- **Two clients configured oppositely in the same realm** (public+PKCE vs
  confidential+PKCE) — more to hold in your head than one uniform pattern, which is why
  the contrast is documented rather than smoothed over.

**Learning simplifications, deliberately not production practice**

- **A flat `roles` claim** instead of Keycloak's nested
  `resource_access.<client>.roles`. Fine for one client; a token consumed by several
  services should keep the self-describing standard shape.
- **Test users with non-temporary passwords** (`demo-user`, `demo-admin`), so repeated
  login testing is not interrupted by a forced password change. Their roles are
  **disjoint** on purpose: a 403 is then positive evidence that each role is enforced
  independently.
- **`email_verified` asserted** rather than proven, because the realm has no SMTP yet.

**Alternatives considered**

- *Realm roles* — simpler, and they compose across apps. Rejected: a single flat
  namespace means a role granted for one app silently applies to every app added later.
- *Groups, as ArgoCD uses* — right when the app already has a permission model to map
  onto (ArgoCD's `role:admin`). Rejected here: this app has no such model, so groups
  would need roles attached anyway, adding a level of indirection with nothing to show
  for it.
- *A public client + PKCE, mirroring ArgoCD* — uniform, and it would avoid a secret
  entirely. Rejected: the app has a backend, so it can hold a credential and thereby
  authenticate *itself*; declining that is throwing away a protection that is free here.
- *Editing the shared `roles` client scope* to add the ID token to the built-in mapper —
  one change instead of one per client. Rejected: it alters token contents for every
  current and future client in the realm to fix one app.
- *`ROLE_`-prefixed names in Keycloak*, removing the need for a mapper — rejected as
  leaking one framework's convention into shared identity data.
- *oauth2-proxy in front* — rejected by [ADR-0010](0010-native-oidc-oauth2-proxy-fallback.md);
  it would hide the identity from the app, which is the thing being learned.
