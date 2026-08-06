# Securing an app with OIDC — Spring Security as a relying party

The app-side companion to [keycloak-oidc-sso.md](keycloak-oidc-sso.md), which covers the
IDP itself. That guide ends where a *client* begins; this one picks up there: how an
application that speaks OIDC natively ([ADR-0010](../adr/0010-native-oidc-oauth2-proxy-fallback.md))
turns "Keycloak says you are demo-admin" into "you may not open `/user/hello`".

The worked example is **`katomatik-authdemo`**, a deliberately small Spring Boot service
at `https://authdemo.katomatik.com` whose only job is to exercise this flow end to end.
Its source lives in its own repo
([katomatik-com/katomatik-authdemo](https://github.com/katomatik-com/katomatik-authdemo));
the Keycloak side is `terraform/keycloak/client-authdemo.tf` and the deployment is
`manifests/katomatik-authdemo/`. The design decisions are
[ADR-0016](../adr/0016-authdemo-app-auth-design.md).

Nothing here is Spring-specific in its *reasoning* — the traps are OIDC traps that any
relying party meets. Only the class names change.

## The dividing line

One idea makes everything else follow: **Keycloak asserts who you are and what roles you
hold; the app decides what those roles unlock.** Keycloak knows nothing about URL paths,
and the app never manages users.

| Concern | Owner |
|---|---|
| Realm, client, roles, protocol mappers, test users | **Terraform** (`terraform/keycloak/`) |
| Which URL needs which authority | **The app** (`SecurityConfig`) |
| Turning claims into authorities | **The app** (`GrantedAuthoritiesMapper`) |
| Where the app runs, and its public URL | **ArgoCD** (`manifests/katomatik-authdemo/`) |

Every confusing failure in this phase came from a boundary being crossed by accident:
role names shaped for Spring living in Keycloak, or the app trying to derive a URL that
only the infrastructure knows.

## Client roles, realm roles, and groups

Keycloak offers three ways to say "this person is an admin", and they are not
interchangeable.

- **Realm roles** — one flat namespace across the whole realm. `admin` means *the same
  thing* to every client that reads it.
- **Client roles** — defined *inside* a client. `katomatik-authdemo`'s `admin` and some
  future `katomatik-wiki`'s `admin` are unrelated objects that merely share a name.
- **Groups** — collections of *users*, which may in turn carry roles. A group is a
  statement about people, not about permissions.

**authdemo uses client roles.** With one app the choice looks arbitrary; with five it is
the difference between "admin of the demo app" and "admin of everything". A realm role
called `admin` would be granted to a person once and then silently mean authority in
every app added later — precisely the failure mode where someone gets production access
because they were given a role in a toy app. Client roles make the blast radius the
client.

**ArgoCD deliberately uses groups instead**, and the contrast is the point. ArgoCD's
`policy.csv` maps a *subject name* to a role:

```
g, argocd-admins, role:admin
```

The question it answers is "which **people** are ArgoCD admins?" — membership, not
capability — and ArgoCD's own RBAC engine already supplies the permission vocabulary
(`role:admin`, `role:readonly`). Inventing a client role would mean maintaining a second
permission model that ArgoCD would only flatten back into the same policy line.

The rule of thumb this leaves:

> **Roles when the app enforces its own permissions; groups when the app already has a
> permission model and only needs to know who is in what.** Client roles when the name
> should mean nothing outside that app; realm roles only for something genuinely
> realm-wide (`realm-admin`, `employee`).

One practical consequence, easy to trip over: **`groups` had to be created as a real
client SCOPE**, because Keycloak populates group claims for nobody by default and
*rejects* a request for a scope it does not know (see
[Part 3 of the Keycloak guide](keycloak-oidc-sso.md#part-3--what-an-oidc-login-actually-requires)).
The `roles` claim needs no such thing here, because its mapper is attached to the client
itself rather than to a scope — so authdemo requests only `openid profile email` and the
claim arrives anyway. Same goal, two different mechanisms; knowing which one you are
using tells you whether the app has to ask for it.

## Confidential vs public + PKCE — why the two clients differ

The realm holds two clients configured almost oppositely:

| | `argocd` | `katomatik-authdemo` |
|---|---|---|
| Access type | **PUBLIC** (no secret) | **CONFIDENTIAL** (client secret) |
| Where the code→token exchange happens | in the **browser** | **server-to-server** |
| PKCE | S256, enforced | S256, enforced |
| What authenticates the client | nothing — PKCE proves the *request* | the secret |

The deciding question is never "which is more secure", it is **where the token exchange
runs**. ArgoCD's UI performs it in the browser, so a "confidential" secret would have to
be shipped to the browser to be used — at which point it is not a secret, only a
liability with a rotation schedule. PKCE replaces it with a per-request proof: nothing to
store, rotate, or leak into Git.

A Spring server-side app has a backend. The browser never sees the secret; it is read
from an environment variable populated by a SOPS-encrypted Secret
([ADR-0012](../adr/0012-argocd-sops-decryption-ksops.md)) and used on a direct
back-channel call to Keycloak. That buys something PKCE alone cannot: **the client itself
is authenticated**, not merely the possession of an authorization code.

### PKCE on a confidential client — check the wire, not the lore

Both clients enforce `pkce_code_challenge_method = "S256"`, which contradicts widely
repeated advice. The advice is not wrong, it is *stale*: **Spring Security 6** applied
PKCE automatically only to public clients, so enforcing S256 on a confidential client
made every login fail with "Missing parameter: code_challenge". That was recorded here as
fact, and it was wrong for **Spring Security 7**, which sends a challenge for confidential
clients too.

The way to settle it takes one command — ask the app for the authorization request it
actually builds, and read it:

```sh
curl -s -o /dev/null -w '%{redirect_url}\n' \
  https://authdemo.katomatik.com/oauth2/authorization/keycloak | tr '&' '\n'
```

```
https://auth.katomatik.com/realms/katomatik/protocol/openid-connect/auth?response_type=code
client_id=katomatik-authdemo
scope=openid%20profile%20email
state=...
redirect_uri=https://authdemo.katomatik.com/login/oauth2/code/keycloak
nonce=...
code_challenge=f-Lz4__Sm15kjp7t2GMQ0yBVIH4Q-prGoHrInynU0oU
code_challenge_method=S256
```

`code_challenge_method=S256`, with no configuration asked for it. So enforcing PKCE is
free defence in depth here: the secret authenticates the client, and PKCE additionally
binds the authorization code to the session that requested it — a leaked redirect still
yields nothing.

The lesson generalises past this one parameter: **version-specific lore about a framework
is a hypothesis, and the wire is the experiment.** This one turned a "can't do that" note
into a security improvement.

## The ID-token trap

The single most expensive thing to get wrong, because it fails *silently*.

Keycloak ships a built-in **client roles** mapper inside the shared `roles` client scope.
It looks like exactly what you want, and it writes
`resource_access.<client>.roles` — **to the access token only**. Its `id.token.claim` is
unset.

Spring's OIDC *login* builds the `OidcUser`, and therefore its authorities, from the
**ID token**. Put those two facts together and the result is an application where:

- login succeeds,
- no error appears in any log,
- every user arrives with **zero roles**,
- and every protected path returns 403 for everyone.

Nothing in that picture points at the token; it looks like a broken authorities mapper.
The fix is a dedicated mapper with `add_to_id_token = true`:

```hcl
resource "keycloak_openid_user_client_role_protocol_mapper" "authdemo_roles" {
  client_id_for_role_mappings = keycloak_openid_client.authdemo.client_id
  claim_name                  = "roles"
  multivalued                 = true

  add_to_id_token     = true   # ← the one that matters for an OIDC login
  add_to_access_token = true
  add_to_userinfo     = true
}
```

Three deliberate choices in there:

- **Per-client, not by editing the shared `roles` scope.** Flipping the built-in mapper
  would change token contents for every current and future client in the realm — a
  realm-wide edit to fix one app.
- **A flat `roles` claim instead of Keycloak's nested `resource_access.<client>.roles`.**
  Scoping the mapper to one client makes the nesting redundant and the Spring side
  trivial. *Learning simplification*: a token consumed by several services should keep
  the standard nested shape, which is self-describing about which client each role
  belongs to.
- **All three destinations set**, so the same roles are visible whether the app reads the
  ID token, validates a bearer access token, or calls `/userinfo`. Consistency costs
  nothing and removes a whole category of "works in one code path" bugs.

**Check the token before writing any code.** Keycloak's admin API will generate an
example ID token for a given user and client
(`.../clients/<id>/evaluate-scopes/generate-example-id-token?userId=<uid>`). That is how
this was caught here — the example token showed `roles: ["user"]` present and
`resource_access` absent, confirming both the need for the mapper and that it worked,
before a line of Java existed. After deployment the same evidence is in `/me`, which
prints the raw claim next to the granted authorities:

```json
{"preferredUsername":"demo-user",
 "rolesClaimFromKeycloak":["user"],
 "grantedAuthorities":["OIDC_USER","ROLE_USER","SCOPE_email","SCOPE_openid","SCOPE_profile"]}
```

Seeing both is what makes a mapping bug obvious: `roles: ["admin"]` with no matching
`ROLE_ADMIN` means the mapper didn't fire; an empty `roles` means Keycloak, not Spring,
is the problem.

## From claim to authority

Keycloak stores role names in *its* idiom — lowercase, unprefixed: `user`, `admin`.
Spring Security's idiom is an authority string with a `ROLE_` prefix, and `hasRole("USER")`
looks for exactly `ROLE_USER`. Something has to bridge the two, and **the bridge belongs
on the Spring side**:

```java
@Bean
GrantedAuthoritiesMapper userAuthoritiesMapper() {
    return authorities -> {
        Set<GrantedAuthority> mapped = new HashSet<>();
        for (GrantedAuthority authority : authorities) {
            mapped.add(authority);                       // keep OIDC_USER, SCOPE_*
            if (authority instanceof OidcUserAuthority oidcAuthority) {
                List<String> roles = oidcAuthority.getIdToken().getClaimAsStringList("roles");
                if (roles != null) {
                    roles.stream()
                        .map(role -> "ROLE_" + role.toUpperCase(Locale.ROOT))
                        .map(SimpleGrantedAuthority::new)
                        .forEach(mapped::add);
                }
            }
        }
        return mapped;
    };
}
```

Why not just name the Keycloak role `ROLE_ADMIN` and skip the mapper? Because that bakes
one framework's naming convention into the *identity data*, which every other client in
the realm then has to read and ignore. A Python or Go relying party would be reading
`ROLE_` prefixes for no reason. **Identity data stays framework-neutral; the framework's
conventions stay in the framework.** The same argument is why the upper-casing happens
here and not in Terraform.

Two smaller details worth copying:

- **The original authorities are kept, not replaced.** `OIDC_USER` and `SCOPE_*` stay
  alongside the new `ROLE_*` entries, so `/me` shows which authorities came from the
  standard flow and which from this mapping.
- **URL rules live in one place** (`SecurityConfig`), not in `@PreAuthorize` annotations
  scattered across controllers. For an app this size the whole access-control policy
  should be readable on one screen:

  ```java
  .requestMatchers("/", "/error", "/favicon.ico", "/public/**").permitAll()
  .requestMatchers("/user/**").hasRole("USER")
  .requestMatchers("/admin/**").hasRole("ADMIN")
  .anyRequest().authenticated()
  ```

  `/public/**` is not decoration — it is the **control case**. If it ever starts
  redirecting to Keycloak, the security rules are wrong, not the roles.

## Logging out: CSRF, and how far the logout reaches

### Why the landing page is rendered, not static

Spring Security protects `POST /logout` with CSRF, so the form must carry a `_csrf`
token. A static HTML file has no way to obtain one — it is generated per session. That
one fact is why the landing page goes through a controller and a Thymeleaf template
instead of sitting in `static/`:

```html
<form method="post" th:action="@{/logout}">
  <button type="submit">Log out</button>
</form>
```

`th:action` rather than a plain `action` is load-bearing: it routes through Spring
Security's `CsrfRequestDataValueProcessor`, which appends the hidden input. Verifiable
from outside:

```sh
curl -s https://authdemo.katomatik.com/ | grep -o '<input[^>]*_csrf[^>]*>'
# <input type="hidden" name="_csrf" value="..."/>

curl -s -o /dev/null -w '%{http_code}\n' -X POST https://authdemo.katomatik.com/logout
# 403 — no token, no logout
```

Both alternatives are worse. Allowing `GET /logout` removes CSRF protection from logout
entirely — and a logout CSRF is a real nuisance attack, not a theoretical one. Reading
the token from a cookie in JavaScript means opting out of the BREACH mitigation Spring
Security applies by default. Rendering one small page is the cheapest correct answer.

### Local logout vs RP-initiated logout

There are **two independent sessions**: the app's own session cookie, and Keycloak's SSO
session cookie on `auth.katomatik.com`. Clearing only the first is *local logout* — and
it produces the behaviour that looks like a bug and is not: click "log out", click "log
in", and you are straight back in with no password prompt. That is single sign-on working
(the same behaviour is documented for ArgoCD in
[the Keycloak guide](keycloak-oidc-sso.md#logging-out-and-why-you-get-straight-back-in)).

**RP-initiated logout** ends the Keycloak session too. In Spring that is one handler:

```java
.logout(logout -> logout.logoutSuccessHandler(
    new OidcClientInitiatedLogoutSuccessHandler(clientRegistrationRepository)));
```

It redirects the browser to Keycloak's `end_session_endpoint` with an `id_token_hint`,
and Keycloak returns the browser to a **registered** post-logout URI. Observed on the
wire — the response to a valid `POST /logout`:

```
302 → https://auth.katomatik.com/realms/katomatik/protocol/openid-connect/logout
        ?id_token_hint=eyJhbGciOi...&post_logout_redirect_uri=https://authdemo.katomatik.com/
```

Keycloak 22+ refuses that redirect unless the URI is registered, hence
`valid_post_logout_redirect_uris` on the client. Note it is **not** `"+"` here (which
means "reuse the redirect URIs"): Spring returns the user to the app *root*, not to the
`/login/oauth2/code/keycloak` callback path. ArgoCD is the opposite case and `"+"` is
right for it.

**Know the blast radius: this ends the session for every app.** After authdemo's logout,
ArgoCD asks for a password again too. That is correct — it is what single sign-*out*
means — but it is a shared-fate behaviour worth deciding on rather than discovering. It
is also what makes the app *testable*: without it, logging in as the second test user is
impossible without clearing cookies by hand.

Proof it really ends the SSO session, rather than just the local one:

```sh
# after completing the logout redirect chain, ask for authorization again
curl -sL -b jar -c jar https://authdemo.katomatik.com/oauth2/authorization/keycloak \
  | grep -c 'type="password"'
# 1  → Keycloak presents a login form, so the SSO session is genuinely gone
```

> **Currently inconsistent, on purpose-for-now:** authdemo does RP-initiated logout;
> ArgoCD does local logout only. The `logoutURL` snippet that closes the gap is in the
> [Keycloak guide](keycloak-oidc-sso.md#logging-out-and-why-you-get-straight-back-in),
> and the ArgoCD client already carries the registered post-logout URI for it.

## `/me`, and why it serves two representations

`/me` is the page the app exists for: subject, issuer, every ID-token claim, the raw
`roles` claim, and the resulting authorities. It is also what the verification scripts
parse. Those two audiences want different things, and the same path serves both by
**content negotiation** on the `Accept` header — two handlers differing only in
`produces`:

```java
@GetMapping(value = "/me", produces = MediaType.TEXT_HTML_VALUE)   // browser → rendered page
@GetMapping(value = "/me", produces = MediaType.APPLICATION_JSON_VALUE)  // script → JSON
```

This is not polish for its own sake. Turning `/me` into a human-readable page *by
replacing* the JSON would have broken every automated check of the RBAC behaviour — the
kind of regression that is only noticed weeks later when a check that quietly stopped
proving anything is trusted anyway. A human gets something readable, a script gets
something parseable, neither is compromised for the other.

Deliberately absent from **both** representations: the raw ID and access tokens. They are
bearer credentials — anything holding one can impersonate the user until it expires — so
they do not belong on a page that might be screenshotted or in a response that might be
pasted into an issue. The *claims* are safe to show; the *token* is not.

## Verifying the whole thing without a browser

The RBAC matrix is the deliverable, and clicking through four URLs as two users is both
tedious and unrepeatable. The authorization-code flow is only HTTP, so `curl` with a
cookie jar can drive all of it — including the Keycloak login form.

The trick is that Keycloak's login page carries the session and execution state in the
form's `action` URL. Scrape it, post credentials to it, and follow the redirect home:

```sh
APP=https://authdemo.katomatik.com
JAR=$(mktemp)

# 1. Ask for a protected page; follow the redirects to Keycloak's login form.
page=$(curl -sL -c "$JAR" -b "$JAR" "$APP/me")

# 2. The form action carries the state Keycloak needs back.
action=$(printf '%s' "$page" | grep -o 'action="[^"]*"' | head -1 \
         | sed 's/action="//;s/"$//;s/&amp;/\&/g')

# 3. Post the credentials; follow the callback back into the app.
curl -sL -c "$JAR" -b "$JAR" -o /dev/null \
  --data-urlencode "username=demo-user" --data-urlencode "password=$PW" "$action"

# 4. The jar now holds an authenticated session. Check every path.
for p in /public/ping /me /user/hello /admin/hello; do
  printf '%-16s %s\n' "$p" "$(curl -s -o /dev/null -w '%{http_code}' -b "$JAR" "$APP$p")"
done
```

The password comes from Terraform, never from the shell history:
`./tf.sh output -raw authdemo_test_password`.

Run for both users, the current output against the deployed app:

| Path | logged out | `demo-user` | `demo-admin` |
|---|---|---|---|
| `/public/ping` | 200 | 200 | 200 |
| `/me` | 302 → Keycloak | 200 | 200 |
| `/user/hello` | 302 → Keycloak | **200** | **403** |
| `/admin/hello` | 302 → Keycloak | **403** | **200** |

**The 403s are the interesting cells, and they are only meaningful because the two test
users hold disjoint roles.** If `demo-admin` also had `user`, a passing `/user/hello`
would prove nothing — everything passes when one account holds every role. Disjoint roles
turn each 403 into positive evidence that a specific role is enforced independently.
Designing the *fixtures* for falsifiability matters as much as the assertions.

*Learning simplification, worth naming*: those test users have non-temporary passwords so
this loop is not interrupted by a forced password change. Never do that for a human's
account — contrast the real admin, which is created with `temporary = true` precisely so
the value that passed through Terraform state stops being a working credential at first
login.

## What the cluster adds

Two failures appear only once the app is behind the tunnel, and both are covered in the
Keycloak guide rather than repeated here:
[Deploying a relying party behind the tunnel](keycloak-oidc-sso.md#deploying-a-relying-party-behind-the-tunnel)
— Traefik overwriting `X-Forwarded-Proto` (so the app cannot derive its own HTTPS URL and
the redirect URI must be pinned), and `runAsNonRoot` requiring a numeric `USER` in the
image.

The first one leaves a trace you can still see from outside, which is a nice way to
internalise it. An unauthenticated request gets an entry-point redirect built from what
the app *believes* about the request:

```sh
curl -s -o /dev/null -w '%{redirect_url}\n' https://authdemo.katomatik.com/me
# http://authdemo.katomatik.com/oauth2/authorization/keycloak     ← http, derived
```

…while the authorization request it sends to Keycloak carries
`redirect_uri=https://authdemo.katomatik.com/...` — because that one is **pinned** via
`SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_KEYCLOAK_REDIRECT_URI` in the Deployment.
Derived scheme wrong, pinned value right, in the same request. The same reasoning applies
to `APP_POST_LOGOUT_REDIRECT_URI`: it too is compared exactly by Keycloak, and it too
would otherwise be built as `http://`.

Three values must agree exactly, and nothing checks them for you:

1. the Ingress host (`manifests/katomatik-authdemo/ingress.yaml`),
2. the pinned redirect URI (the Deployment's env),
3. `valid_redirect_uris` on the Keycloak client (`terraform/keycloak/client-authdemo.tf`).

The localhost entries in (3) are kept after deployment on purpose: this app exists to be
poked at, and losing the ability to run it locally against the real IDP would defeat that.
Plain `http://` is acceptable *only* because loopback is not routable — never register
`http://` for a real host.

## Traps worth knowing

- **The registration id is not a free choice.** Spring builds its callback path as
  `/login/oauth2/code/{registrationId}`, and Keycloak matches redirect URIs exactly.
  Renaming the `keycloak:` key in `application.yaml` breaks login with *"Invalid
  parameter: redirect_uri"* and nothing in the message hints at the cause.
- **The issuer must be the public URL, even for local development.** It is an identity,
  not an address: Spring rejects any token whose `iss` claim differs from what it was
  configured with. A `localhost` port-forward is fine for the admin *API* and useless for
  a browser flow.
- **Roles in the ID token, not just the access token** — the trap above. Worth restating
  because the failure is silent.
- **Port 8081, not 8080.** `terraform/keycloak/tf.sh` port-forwards Keycloak's admin API
  to `localhost:8080`, which is Spring Boot's default. Running both means one of them
  fails in a way that looks like a Keycloak problem.
- **A missing client secret should be fatal at startup.** `${KEYCLOAK_CLIENT_SECRET}`
  with no default means the app refuses to boot rather than serving a login that
  mysteriously fails at the token exchange.

## Follow-up (deliberately not done)

- **A shared Thymeleaf layout fragment** — the CSS is duplicated across `index`, `me` and
  `error`.
- **`/favicon.ico` 404s**, which is noise in devtools and a blank tab icon.
- **`readOnlyRootFilesystem`** on the pod: it needs an `emptyDir` for Tomcat's `/tmp`,
  and untested hardening that breaks the pod is worse than none.
- **Automating the image-tag bump** into this repo. It is a manual edit today — the same
  as `katomatik-web` — and worth doing deliberately rather than by accident.
