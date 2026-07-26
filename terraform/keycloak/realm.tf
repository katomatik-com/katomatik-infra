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

  # --- Attack surface ---------------------------------------------------------
  security_defenses {
    # Rate-limit password guessing. Keycloak ships this switched OFF, which is
    # indefensible here: the login page is on the public internet AND the admin
    # username is publicly known (it sits in the committed terraform.tfvars of a
    # public repo). Without this, guessing is free and unlimited.
    brute_force_detection {
      # Failures before the account is temporarily locked. Tightened from
      # Keycloak's default of 30 — this realm has a handful of accounts, so
      # there is no legitimate reason to reach double digits.
      max_login_failures = 10

      # TEMPORARY lockout only — deliberately NOT permanent.
      #
      # Permanent lockout sounds stronger and is the wrong choice here: the
      # admin account is a SHARED credential with a PUBLIC username, so anyone
      # could deliberately lock it and nobody could get into Keycloak at all.
      # That trades a guessing risk for a guaranteed denial-of-service, and
      # ArgoCD's local `admin` is break-glass for ArgoCD — NOT for Keycloak.
      # `max_temporary_lockouts = 0` also disables escalation-to-permanent after
      # N temporary lockouts, which would reintroduce the same hazard.
      permanent_lockout      = false
      max_temporary_lockouts = 0

      # Backoff. MULTIPLE grows the wait with each failure (vs LINEAR's fixed
      # step), so a slow-and-patient attacker pays exponentially while a human
      # who fat-fingered their password waits a minute.
      brute_force_strategy     = "MULTIPLE"
      wait_increment_seconds   = 60  # first lockout, then it grows
      max_failure_wait_seconds = 900 # cap at 15 min, so a real user recovers

      # Detects credential-stuffing scripts: two attempts closer together than
      # quick_login_check are treated as machine-speed and get their own
      # minimum wait, independent of the failure count.
      quick_login_check_milli_seconds  = 1000
      minimum_quick_login_wait_seconds = 60

      # Forget the failure count after 12h of good behaviour, so a lockout can
      # never become effectively permanent through accumulated old failures.
      failure_reset_time_seconds = 43200
    }

    # These are PINNED TO THE VALUES KEYCLOAK IS ALREADY SERVING, read off the
    # live realm before this block was written — they are not new policy.
    #
    # Why they must be here at all: `headers` is a sibling sub-block of
    # brute_force_detection inside security_defenses, and these attributes are
    # optional-but-not-computed. Declaring the parent block while omitting
    # `headers` makes Terraform read them as empty and CLEAR every one of them —
    # so adding brute-force protection would have silently stripped the realm's
    # CSP, HSTS and clickjacking defences. Same footgun that tried to null
    # default_signature_algorithm and required_actions.
    headers {
      content_security_policy             = "frame-src 'self'; frame-ancestors 'self'; object-src 'none';"
      content_security_policy_report_only = ""
      referrer_policy                     = "no-referrer"
      strict_transport_security           = "max-age=31536000; includeSubDomains"
      x_content_type_options              = "nosniff"
      x_frame_options                     = "SAMEORIGIN"
      x_robots_tag                        = "none"
      x_xss_protection                    = "1; mode=block"
    }
  }
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
