# katomatik-authdemo — the Phase 2 Spring Boot app: a throwaway service whose only
# job is to exercise the auth flow end to end (native OIDC client, ADR-0010) and
# enforce role-based access in-app.
#
# CONFIDENTIAL, unlike the ArgoCD client next door which is PUBLIC + PKCE. The
# difference is not stylistic: ArgoCD does the code→token exchange in the browser,
# where no secret can survive. A Spring server-side app has a backend, so the
# exchange happens server-to-server and a real client secret is both possible and
# preferable — it authenticates the client itself, not just the user's possession
# of a code.
resource "keycloak_openid_client" "authdemo" {
  realm_id  = keycloak_realm.katomatik.id
  client_id = "katomatik-authdemo"
  name      = "Katomatik Auth Demo"
  enabled   = true

  access_type = "CONFIDENTIAL" # has a secret; read it from `terraform output`

  standard_flow_enabled = true
  # Password grant OFF: it sends the user's password to the client and is
  # deprecated in OAuth 2.1. The app uses the browser redirect flow, and the
  # Phase 2 verification is browser-based, so nothing needs it.
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false
  service_accounts_enabled     = false

  # PKCE enforced, same as the ArgoCD client — but for a different reason, and only
  # after checking rather than assuming.
  #
  # The old Spring Security behaviour (6.x) was to apply PKCE automatically ONLY to
  # public clients, which would make enforcing S256 here break every login. That is
  # no longer true: Spring Security 7 sends a code challenge for confidential clients
  # too. VERIFIED against the running app — the authorization request it builds
  # carries `code_challenge_method=S256` with no extra configuration.
  #
  # So this is defence in depth rather than a substitute for the secret: the secret
  # authenticates the client, PKCE additionally binds the authorization code to the
  # session that requested it, killing code-interception even if a redirect leaks.
  pkce_code_challenge_method = "S256"

  # Spring Security's callback path is /login/oauth2/code/{registrationId}, and
  # the registration is named `keycloak` in application.yaml — so this URI is
  # dictated by Spring's convention, not chosen freely. Keycloak matches it
  # exactly; a mismatch is the classic "Invalid parameter: redirect_uri".
  #
  # Port 8081, NOT 8080: tf.sh port-forwards Keycloak's admin API to localhost:8080,
  # so the app would collide with it on Spring Boot's default port.
  valid_redirect_uris = [
    "http://localhost:${var.authdemo_local_port}/login/oauth2/code/keycloak",
  ]

  # After logout Spring sends the user to the app root, not to the callback path,
  # so "+" (reuse valid_redirect_uris) would be wrong here — unlike the ArgoCD client.
  valid_post_logout_redirect_uris = [
    "http://localhost:${var.authdemo_local_port}/*",
  ]

  # No web_origins: the token exchange is server-side, so no browser ever makes a
  # cross-origin call to Keycloak. Left unset (Keycloak computes it) rather than
  # set to a value that implies a CORS need that doesn't exist.

  # NOTE: deliberately NOT declaring keycloak_openid_client_default_scopes here.
  # The ArgoCD client needs it because it adds `groups`; this client only needs
  # Keycloak's own defaults. Declaring that resource would put an authoritative
  # list under management for no benefit — and get it wrong at the first change.
}

# --- Roles --------------------------------------------------------------------
# CLIENT roles, not realm roles: these live inside this client, so "admin" here
# means nothing anywhere else in the realm. As the fleet grows, that isolation is
# what stops one app's ADMIN from silently becoming authority in another.
#
# Lowercase names are Keycloak's idiom. The Spring-specific `ROLE_` prefix and
# upper-casing belong in the app's authorities converter, not in the IDP — keeping
# the framework's convention out of the identity data.
resource "keycloak_role" "authdemo_user" {
  realm_id    = keycloak_realm.katomatik.id
  client_id   = keycloak_openid_client.authdemo.id
  name        = "user"
  description = "Ordinary user of katomatik-authdemo — grants /user/**"
}

resource "keycloak_role" "authdemo_admin" {
  realm_id    = keycloak_realm.katomatik.id
  client_id   = keycloak_openid_client.authdemo.id
  name        = "admin"
  description = "Administrator of katomatik-authdemo — grants /admin/**"
}

# --- Getting the roles into the token Spring actually reads --------------------
# THE non-obvious part of this whole file.
#
# Keycloak's built-in "client roles" mapper (in the shared `roles` client scope)
# writes resource_access.<client>.roles into the ACCESS token only — its
# id.token.claim is unset. But Spring Security's OIDC *login* builds the OidcUser,
# and therefore its authorities, from the **ID token**. So with only the built-in
# mapper the app authenticates fine and every user arrives with no roles at all —
# a silent, confusing failure.
#
# Fixed per-client rather than by editing the shared `roles` scope, which would
# change token contents for every current and future client in the realm.
resource "keycloak_openid_user_client_role_protocol_mapper" "authdemo_roles" {
  realm_id  = keycloak_realm.katomatik.id
  client_id = keycloak_openid_client.authdemo.id
  name      = "authdemo-client-roles"

  # Scope the mapper to THIS client's roles only, so the claim can be a flat
  # `roles` array instead of Keycloak's nested resource_access.<client>.roles.
  # A deliberate simplification: one app, one claim, trivial to read in Spring.
  # (Keeping the nested standard shape would be the choice for a token consumed
  # by several services.)
  client_id_for_role_mappings = keycloak_openid_client.authdemo.client_id
  claim_name                  = "roles"
  claim_value_type            = "String"
  multivalued                 = true

  # The ID token is the one that matters for Spring's login. The others are set
  # too so the same roles are visible to a resource-server-style check and to
  # /userinfo — consistent claims wherever the app looks.
  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}

# --- Test users ---------------------------------------------------------------
# Two accounts with DISJOINT roles, on purpose. Making the admin a superset of the
# user would hide mapping bugs: with disjoint roles, `demo-admin` getting 403 on
# /user/** is a positive signal that each role is enforced independently, rather
# than everything passing because one account holds every role.
locals {
  authdemo_test_users = {
    "demo-user" = {
      first_name = "Demo"
      last_name  = "User"
      role_id    = keycloak_role.authdemo_user.id
    }
    "demo-admin" = {
      first_name = "Demo"
      last_name  = "Admin"
      role_id    = keycloak_role.authdemo_admin.id
    }
  }
}

resource "keycloak_user" "authdemo_test" {
  for_each = local.authdemo_test_users

  realm_id   = keycloak_realm.katomatik.id
  username   = each.key
  email      = "${each.key}@katomatik.com"
  first_name = each.value.first_name
  last_name  = each.value.last_name
  enabled    = true
  # No SMTP on this realm, and these are disposable test identities.
  email_verified = true

  initial_password {
    value = var.test_user_password
    # temporary = false — unlike the real admin account. These exist to be logged
    # in as, repeatedly, while testing the protected paths; a forced password
    # change on every fresh apply would interrupt the very loop they support.
    # TEST-ONLY simplification: never do this for a human's account.
    temporary = false
  }

  lifecycle {
    # Same footgun as the admin user: `required_actions` is runtime state Keycloak
    # mutates, and is optional-but-not-computed, so an undeclared value reads as
    # empty and gets cleared. first_name/last_name ARE declared above, so they
    # stay under Terraform's control here (these are provisioned test accounts,
    # not someone's personal profile).
    ignore_changes = [required_actions]
  }
}

resource "keycloak_user_roles" "authdemo_test" {
  for_each = local.authdemo_test_users

  realm_id = keycloak_realm.katomatik.id
  user_id  = keycloak_user.authdemo_test[each.key].id
  role_ids = [each.value.role_id]

  # Terraform owns each test user's role list completely — a role granted by hand
  # in the console disappears on the next apply, so privilege drift shows up as a
  # diff instead of quietly making a test pass.
  exhaustive = true
}
