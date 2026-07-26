# The `katomatik` realm — the identity domain for katomatik's apps and users.
# ONE realm for now (single admin + small user base); split out a second realm
# only if a genuinely distinct security domain appears.
#
# This realm was originally created by a `KeycloakRealmImport` CR. That CR is
# create-only (it will not update an existing realm — ADR-0015), so ownership
# moves here: the realm is IMPORTED into state (see import.tf), not recreated,
# which keeps its internal ID and any users it holds.

resource "keycloak_realm" "katomatik" {
  realm        = var.realm
  enabled      = true
  display_name = "Katomatik"

  # --- Login behaviour -------------------------------------------------------
  # Self-registration OFF: accounts are created deliberately, not by strangers
  # who find the public login page.
  registration_allowed = false
  # Log in with email as well as username — one less thing to remember.
  login_with_email_allowed = true

  # Both of these need working SMTP, which the realm does not have yet, so they
  # stay off rather than half-working: a "reset password" link that never sends
  # an email is worse than no link at all. Flip both on with an smtp_server
  # block once mail is configured.
  reset_password_allowed = false
  verify_email           = false

  # --- Transport ------------------------------------------------------------
  # "external" = HTTPS required for external requests, plain HTTP tolerated
  # from private addresses. That combination is exactly what this setup needs:
  # public traffic is HTTPS-only via Traefik/Cloudflare, while the admin API
  # over the localhost port-forward stays reachable on HTTP.
  ssl_required = "external"

  # Algorithm Keycloak signs tokens with. Pinned to the value the realm is
  # already using rather than omitted: this attribute is optional but NOT
  # computed, so leaving it out makes Terraform send null and *clear* a live
  # setting — the first import plan showed exactly that (`RS256 -> None`).
  # RS256 is also what ArgoCD's OIDC verifier expects.
  default_signature_algorithm = "RS256"

  # --- Credentials ----------------------------------------------------------
  # A minimum length plus "password must not be the username". Keycloak's
  # default is NO policy at all, which is not defensible for an internet-facing
  # auth server. `(undefined)` is Keycloak's own storage form for a clause that
  # takes no argument — matching it here avoids a perpetual diff.
  password_policy = "length(12) and notUsername(undefined)"

  # Safety catch: refuse to let Terraform delete this realm. Without it, a
  # careless `destroy` — or any change Terraform decides needs a replacement —
  # takes every user in the realm with it. Set to false only when you genuinely
  # mean to tear the realm down.
  terraform_deletion_protection = true
}

# --- The `groups` client scope ------------------------------------------------
# Keycloak does NOT put group membership in tokens by default, and it REJECTS a
# request for a scope it doesn't know. So "groups" has to exist as a real client
# scope before any relying party can ask for it.
#
# This is realm-level, deliberately not ArgoCD-specific: the Spring app in
# Phase 2 will attach the same scope rather than define its own.
resource "keycloak_openid_client_scope" "groups" {
  realm_id    = keycloak_realm.katomatik.id
  name        = "groups"
  description = "Group memberships, as a 'groups' claim (used for RBAC by relying parties)"

  # Advertise "groups" in the token's own `scope` claim, so a resource server
  # can see which scopes were actually granted.
  include_in_token_scope = true
}

# The mapper that does the actual work: read the user's groups, write them into
# the token under a claim named `groups`.
resource "keycloak_openid_group_membership_protocol_mapper" "groups" {
  realm_id        = keycloak_realm.katomatik.id
  client_scope_id = keycloak_openid_client_scope.groups.id
  name            = "groups"
  claim_name      = "groups"

  # full_path = false emits bare names ("argocd-admins") instead of paths
  # ("/argocd-admins"). This has to agree with what argocd-rbac-cm matches on —
  # a leading slash here means every RBAC rule silently stops matching.
  full_path = false

  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}
