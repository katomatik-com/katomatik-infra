# Keycloak as the homelab IDP — and gating ArgoCD with OIDC SSO

How a self-hosted Keycloak is stood up in the cluster, how its realm/client
configuration is managed, and how ArgoCD's UI is put behind it. The *why* lives in
[ADR-0009](../adr/0009-self-hosted-keycloak-idp.md) (self-hosted Keycloak),
[ADR-0011](../adr/0011-neon-managed-postgres.md) (Neon Postgres),
[ADR-0014](../adr/0014-keycloak-operator.md) (the Operator) and
[ADR-0015](../adr/0015-keycloak-config-via-terraform.md) (config via Terraform).

## The core split: instance vs configuration

The single most important idea here. Two different things get called "Keycloak",
they are owned by two different tools, and confusing them causes most of the pain:

| | What it is | Owner |
|---|---|---|
| **Instance** | the StatefulSet, its database, hostname, TLS/proxy behaviour, Ingress | **Keycloak Operator**, via ArgoCD (`manifests/keycloak/`) |
| **Configuration** | realms, clients, client scopes, protocol mappers, groups, users | **Terraform** (`terraform/keycloak/`) |

Why the split isn't arbitrary: the instance is a *Kubernetes workload*, so it belongs
to the GitOps reconciler ([ADR-0003](../adr/0003-argocd-only-gitops-helmfile-dropped.md)).
The configuration is reached only through Keycloak's **admin REST API** — and
API-driven config is what Terraform is for in this repo already (Cloudflare,
[ADR-0005](../adr/0005-terraform-for-cloudflare-external-layer.md); Neon,
[ADR-0011](../adr/0011-neon-managed-postgres.md)).

> **The trap that forced this.** The Operator *does* ship
> `KeycloakRealmImport`, and it looks like the GitOps-native answer. It is
> **create-only**: if the realm already exists, the import is skipped silently —
> the CR reports success and nothing happens. Adding a client to a live realm is
> therefore impossible, and the alternative `KeycloakOIDCClient` CRD is `v2alpha1`
> with no `publicClient` or PKCE fields. Full story in
> [ADR-0015](../adr/0015-keycloak-config-via-terraform.md).

## Part 1 — the instance

`manifests/keycloak/keycloak.yaml` is a `Keycloak` CR; the Operator turns it into a
StatefulSet. Four settings carry all the subtlety:

- **`db.url` → Neon, direct (not pooled), `sslmode=require`.** Neon's pooler is
  PgBouncer in transaction mode, which breaks Keycloak's Liquibase advisory locks and
  pgJDBC prepared statements. Keycloak brings its own (Agroal) pool anyway. Credentials
  come from the KSOPS-decrypted `keycloak-db` Secret
  ([ADR-0012](../adr/0012-argocd-sops-decryption-ksops.md)); host and database name sit
  in plaintext in the CR because that field *is* plaintext in Git.
- **`hostname: auth.katomatik.com`** — a **fixed** public hostname. Keycloak uses it to
  build every browser-facing URL and, crucially, the OIDC `issuer`. See Part 3.
- **`http.httpEnabled` + `proxy.headers: xforwarded`** — TLS terminates at
  Cloudflare/Traefik, so Keycloak itself speaks HTTP and *trusts* `X-Forwarded-*` to
  know the request was really HTTPS. Without the proxy setting Keycloak sees plain HTTP
  and refuses to issue cookies/redirects correctly; with it set but no trusted proxy in
  front, a client could spoof those headers. Both halves are required together.
- **`ingress.enabled: false`** — the Operator's own Ingress would publish *everything*.
  Instead `manifests/keycloak/ingress.yaml` routes **only public paths** (`/realms`,
  `/resources`).

**`/admin` is deliberately not routed** — Traefik 404s it, so the admin console is not
reachable from the internet at all. Admin access is:

```sh
kubectl -n keycloak port-forward svc/keycloak-service 8080:8080
# console at http://localhost:8080/admin  (only while this runs)
```

This is *reachability* control on top of Keycloak's own admin RBAC — defence in depth,
and it costs nothing in a single-operator lab.

## Part 2 — the configuration

`terraform/keycloak/` is a **second, separate** Terraform root module. Two ways it
differs from `terraform/`, both forced by the decision above:

- **Local state and local execution** (no `cloud {}` block). HCP's remote runners are on
  the internet; the admin API deliberately is not. The run must happen next to the
  kubeconfig.
- **Reached over the port-forward** — provider `url = http://localhost:8080`.

> Terraform never recurses into subdirectories, so the two root modules are fully
> independent despite the nesting. One wrinkle: `terraform/` is an HCP *CLI-driven*
> workspace and uploads its whole working directory, subdirectories included — hence
> `terraform/.terraformignore` excluding `keycloak/`, whose local state file holds
> secrets.

Runs go through the wrapper, which opens the tunnel, waits for the API to actually
answer, injects admin credentials straight from the cluster Secret, and tears the tunnel
down on any exit path:

```sh
cd terraform/keycloak
 export TF_VAR_admin_initial_password='...'   # leading space: kept out of shell history
./tf.sh plan
./tf.sh apply
```

Credentials are never in Git: the provider reads `KEYCLOAK_USER` / `KEYCLOAK_PASSWORD`
from the environment — the same "secrets come from the environment" pattern the
Cloudflare and Neon providers use.

**Adopting the pre-existing realm.** The realm was originally created by the retired
`KeycloakRealmImport` CR, so Terraform had to take it over *without* recreating it (a
recreate destroys every user). That was a one-shot config-driven `import` block:

```hcl
import {
  to = keycloak_realm.katomatik
  id = "katomatik"          # keycloak_realm.id is the realm NAME; internal_id is the UUID
}
```

`0 to destroy` in the plan is the line that proves adoption rather than replacement.
Deleting the CR did **not** delete the realm — the Operator never deletes realms, which
is also why a renamed CR orphans the old realm (clean up with `kcadm delete realms/x`).

## Part 3 — what an OIDC login actually requires

Four things, each of which fails in a confusing way if wrong.

**1. The issuer is an identity, not an address.** The client fetches
`<issuer>/.well-known/openid-configuration` and then **rejects any token whose `iss`
claim doesn't match** what it was configured with. Keycloak's fixed `hostname` means it
always advertises `https://auth.katomatik.com/realms/katomatik` — even when you reach it
over `localhost`. That's exactly why the port-forward works for the REST API but would be
useless for a browser flow.

**2. A public client + PKCE, not a client secret.** ArgoCD performs the code→token
exchange **in the browser**. A "confidential" client secret would have to be shipped to
the browser to be used, at which point it is not a secret. PKCE replaces it with a
per-request proof: there is no credential to store, rotate, or leak into Git. Set
`pkce_code_challenge_method = "S256"` to *enforce* it — otherwise the client still
accepts a `plain` exchange and the interception attack stays open.

**3. `groups` must be a client SCOPE, not just a mapper.** Keycloak puts group
membership in tokens for nobody by default, *and* it **rejects a request for a scope it
doesn't know**. So RBAC needs both halves: a client scope named `groups` (so the scope
can be requested) and a group-membership protocol mapper inside it (so a claim is
actually produced). It's defined realm-level so the Phase 2 app reuses it rather than
redefining it.

**4. Redirect URIs are matched exactly.** A wrong path here is the single most common
cause of `Invalid parameter: redirect_uri`. ArgoCD uses `/auth/callback` — *including*
under PKCE — plus `http://localhost:8085/auth/callback` for `argocd login --sso`.
`web_origins` is also required, because the browser-side token exchange is a
cross-origin request.

## Part 4 — wiring ArgoCD

All of it lives in `argocd/values.yaml` (ArgoCD self-manages from Git):

```yaml
configs:
  cm:
    admin.enabled: "true"        # BREAK-GLASS — see below
    oidc.config: |
      name: Keycloak
      issuer: https://auth.katomatik.com/realms/katomatik
      clientID: argocd
      enablePKCEAuthentication: true
      requestedScopes: [openid, profile, email, groups]
  rbac:
    policy.csv: |
      g, argocd-admins, role:admin
```

Three things worth understanding rather than copying:

- **Keycloak asserts membership; ArgoCD grants permissions.** Keycloak says "this
  identity is in `argocd-admins`"; `policy.csv` maps that name to `role:admin`. Keycloak
  knows nothing about ArgoCD roles. The group name is the contract — and the mapper's
  `full_path = false` matters, because `/argocd-admins` would silently match nothing.
- **`policy.default` is left EMPTY — deny by default.** A successful Keycloak login on
  its own grants *nothing*. Setting it to `role:readonly` would hand every account in the
  realm — including future *app* users with no business here — read access to every
  manifest in the cluster.
- **The local `admin` account stays enabled as break-glass.** If Keycloak is down, Neon
  is unreachable, or `oidc.config` is wrong, it is the only way back in — and ArgoCD is
  what would have to fix it. Disabling it is a hardening step for *after* SSO is trusted.

Setting `oidc.config` bypasses Dex entirely (Dex is only used when `dex.config` is set).
`argocd-server` picks the ConfigMap change up without a restart; if the login button
doesn't appear, `kubectl -n argocd rollout restart deploy/argocd-server`.

## Part 5 — verifying without opening a browser

```sh
# 1. the realm is public and the issuer is right
curl -s https://auth.katomatik.com/realms/katomatik/.well-known/openid-configuration | jq .issuer

# 2. the admin console is NOT public
curl -s -o /dev/null -w '%{http_code}\n' https://auth.katomatik.com/admin   # 404

# 3. ArgoCD advertises the OIDC config
curl -s https://argocd.katomatik.com/api/v1/settings | jq .oidcConfig

# 4. Keycloak accepts a real PKCE authorization request (200 + a login page, not an error)
curl -s -o /dev/null -w '%{http_code}\n' \
  "https://auth.katomatik.com/realms/katomatik/protocol/openid-connect/auth?client_id=argocd\
&response_type=code&redirect_uri=https://argocd.katomatik.com/auth/callback\
&scope=openid+profile+email+groups&state=x&code_challenge_method=S256&code_challenge=<challenge>"
```

Step 4 is the useful one: it exercises the client, the scopes, the redirect URI and the
PKCE method in a single request, before a human ever types a password.

## Brute-force protection

**Keycloak ships this switched OFF.** On an internet-facing login page that is not
defensible on its own, and here three facts compounded: the login page is public, the
admin **username is public** (it's in the committed `terraform.tfvars` of a public repo),
and that admin is a **shared** credential. Individually fine; together they make password
guessing cheap. It lives in `security_defenses.brute_force_detection` on the realm.

Two things about the configuration are worth understanding rather than copying.

**`permanent_lockout = false`, deliberately.** Permanent lockout sounds stronger and is the
wrong choice here: with a shared admin account whose username is publicly known, anyone
could deliberately lock it and nobody could get into Keycloak at all. That trades a
guessing risk for a guaranteed **denial-of-service** — and ArgoCD's local `admin` is
break-glass for *ArgoCD*, not for Keycloak. `max_temporary_lockouts = 0` matters for the
same reason: it stops Keycloak escalating to a permanent lock after N temporary ones.
Temporary lockout with `MULTIPLE` (exponential) backoff makes guessing expensive while a
human who fat-fingered a password waits a minute.

**The quick-login check does most of the work.** `max_login_failures = 10` is not the whole
story. `quick_login_check_milli_seconds = 1000` treats two failures arriving closer together
than a second as machine-speed and applies `minimum_quick_login_wait_seconds` immediately.
Verified against a throwaway account: a scripted 12-attempt burst was locked out after just
**2 counted failures** — the timing detector fired long before the failure counter got near
10. So the failure count governs slow, human-paced guessing; the timing check governs
scripts.

Verify it on a disposable user — never the admin — and read Keycloak's own view:

```sh
curl -s -H "Authorization: Bearer $T" \
  "$R/attack-detection/brute-force/users/<user-id>"
# → {"numFailures":2,"disabled":true,"numTemporaryLockouts":0,...}
# Clear it again with: DELETE $R/attack-detection/brute-force/users
```

`disabled: true` plus the *correct* password being rejected is the proof. Clean up the
throwaway user afterwards, since Terraform doesn't manage it.

> **The trap in this change.** `security_defenses` contains **two sibling sub-blocks** —
> `brute_force_detection` **and** `headers`. Declaring the parent while omitting `headers`
> makes Terraform read those as empty and **clear all eight live security headers** (CSP,
> HSTS, X-Frame-Options …) as a side effect of adding brute-force protection. Read the live
> `browserSecurityHeaders` from the admin API first and pin them in a `headers` block. Same
> footgun as below, one level deeper.

## Logging out, and why you get straight back in

**Expected behaviour, not a bug:** after logging out of ArgoCD, clicking "Log in via
Keycloak" signs you straight back in with no password prompt.

There are **two independent sessions**. ArgoCD's logout clears only its own session
cookie. The **Keycloak SSO session** (its own cookie, on `auth.katomatik.com`) is still
valid, so the next authorization request is satisfied silently. That is precisely what
single sign-on means — one IdP session serving many applications — and it is why the
second app you onboard won't ask for a password at all.

The session ends on its own via the realm's SSO idle / max lifespans, or when you log out
of Keycloak's own account console.

To make ArgoCD's logout *also* end the Keycloak session (RP-initiated logout), add to
`oidc.config`:

```yaml
logoutURL: https://auth.katomatik.com/realms/katomatik/protocol/openid-connect/logout?id_token_hint={{token}}&post_logout_redirect_uri={{logoutRedirectURL}}
```

ArgoCD substitutes both placeholders. Keycloak 22+ refuses a post-logout redirect unless
the target is registered, which the client already handles with
`valid_post_logout_redirect_uris = ["+"]` ("reuse the redirect URIs"). Worth doing where
a browser may be shared, since otherwise "log out" does not really log out.

## Deploying a relying party behind the tunnel

Two failures that only appear in the cluster — neither can be reproduced locally, which
is what makes them expensive.

**Traefik overwrites `X-Forwarded-Proto`, so an app cannot derive its own HTTPS URL.**
TLS terminates at Cloudflare; cloudflared then speaks plain HTTP to Traefik. Traefik,
correctly, does not trust forwarded headers from an untrusted client and rewrites
`X-Forwarded-Proto` to the scheme it actually received — `http`. Any app that builds
absolute URLs from the request therefore believes it is running on HTTP.

For OIDC this is fatal in a specific way: Spring expands `{baseUrl}` in its
`redirect-uri` to `http://<host>/login/oauth2/code/keycloak`, Keycloak compares it
against the registered `https://` URI, and every login dies on *"Invalid parameter:
redirect_uri"*. Setting Spring's `server.forward-headers-strategy: framework` is correct
and worth having, but it cannot help when the proxy never sends the header.

The fix is the one Keycloak itself already uses: **tell the app its public URL rather
than letting it guess**. Keycloak has `hostname: https://auth.katomatik.com` in its CR;
the Spring app gets `SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_KEYCLOAK_REDIRECT_URI`
in its Deployment. Three things must then agree exactly: the Ingress host, that pinned
URI, and the redirect URI registered on the Keycloak client in Terraform.

> The alternative — configuring Traefik's `forwardedHeaders.trustedIPs` to trust
> cloudflared — would fix this for every app at once. It is deliberately not done:
> trusting `X-Forwarded-*` is only safe if nothing else can reach Traefik, and that is
> a cluster-wide security decision deserving its own ADR rather than a side effect of
> deploying one app.

**`runAsNonRoot: true` requires a NUMERIC `USER` in the image.** The kubelet verifies
the user is not root *before* starting the container, and it will not read `/etc/passwd`
inside the image to resolve a name. An image ending in `USER app` fails admission with
*"container has runAsNonRoot and image has non-numeric user (app), cannot verify user is
non-root"* — even though the user genuinely is non-root. Declare an explicit UID
(`adduser -u 10001 ...` / `USER 10001`) and mirror it as `runAsUser` in the pod spec.
Docker enforces none of this, so `docker run` will never catch it.

## Traps worth knowing

- **Terraform attributes that are optional but NOT computed get cleared if you don't
  declare them.** This is *the* recurring hazard with this provider — it has bitten **four
  times** so far, in three different shapes:
  1. **A server default**: `keycloak_realm.default_signature_algorithm` planned
     `RS256 -> None`. Fix — pin the live value in config.
  2. **Runtime credential state**: `keycloak_user.required_actions` planned to strip
     `UPDATE_PASSWORD`, which would have cancelled the forced password change and promoted
     a throwaway generated password into a permanent credential. Fix —
     `lifecycle { ignore_changes = [...] }`, *not* declaring the value, since Keycloak
     clears that action once the password is changed and Terraform would re-add it forever.
  3. **User-owned profile data**: `keycloak_user.first_name` / `last_name`, set by hand at
     first login, planned back to `None` — Terraform reverting the account console. Fix —
     `ignore_changes` again.
  4. **A sibling sub-block**: adding `security_defenses.brute_force_detection` while
     omitting the `headers` sub-block would have cleared all eight live security headers.
     Fix — read them from the admin API and pin them.

  Rule of thumb: **server defaults → pin them; state the server or a user mutates →
  `ignore_changes`; and when you declare a parent block, declare *all* of its siblings.**
- **Always read the attribute-level diff**, after an import *and* after every subsequent
  change — never just `Plan: N to add, N to change`. Every bug above was invisible in the
  counts; one of them only surfaced because an unrelated change forced a plan. Require a
  literal `No changes.` afterwards. A `terraform show -json <planfile>` piped through a
  script that flags any `value -> null` transition is worth the twenty lines.
- **`keycloak_openid_client_default_scopes` is authoritative** — it *replaces* the list.
  The six built-ins (`acr basic email profile roles web-origins`) must be listed
  alongside `groups`, or they are silently detached.
- **Terraform needs a running port-forward.** `connection refused` from the provider
  almost always means the tunnel died, not a config error.

## Follow-up hardening (deliberately not done)

- **A dedicated Terraform service account** instead of the bootstrap
  `keycloak-initial-admin` superuser: a confidential client with
  `service_accounts_enabled` and only the `realm-management` roles needed.
- **Disable ArgoCD's local `admin`** once SSO is trusted.
- **Named personal accounts.** The current `katomatik` admin is a deliberate *shared*
  credential: audit events can't attribute actions to a person, access can't be revoked
  for one person, and MFA protects an account rather than an individual. The upgrade path
  is named users added to the same `argocd-admins` group — no ArgoCD-side change needed.
- **SMTP** on the realm, which in turn unlocks `verify_email` and
  `reset_password_allowed`.
- **An access gate in front of the admin console**, so it can be reachable but protected
  by a Keycloak admin group (Keycloak guarding its own console).
