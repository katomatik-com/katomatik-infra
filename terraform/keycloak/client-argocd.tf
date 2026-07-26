# ArgoCD as an OIDC relying party — Phase 1's smoke test for the whole IDP.
#
# PUBLIC client + PKCE, deliberately: ArgoCD's PKCE flow performs the code→token
# exchange in the BROWSER, so any "confidential" client secret would have to be
# shipped to the browser to be used — at which point it is not a secret. PKCE
# replaces it with a per-request proof instead, and there is no credential to
# store, rotate, or leak into Git.
resource "keycloak_openid_client" "argocd" {
  realm_id  = keycloak_realm.katomatik.id
  client_id = "argocd"
  name      = "ArgoCD"
  enabled   = true

  access_type = "PUBLIC" # publicClient=true — no secret

  # Browser redirect (authorization-code) flow only.
  standard_flow_enabled = true
  # Resource-owner password grant: OFF. It sends the user's password straight to
  # the client and is deprecated in OAuth 2.1 — nothing here needs it.
  direct_access_grants_enabled = false
  # Legacy implicit flow: OFF (tokens in the URL fragment).
  implicit_flow_enabled = false
  # Machine-to-machine credentials: OFF, and in fact impossible on a public
  # client — spelled out so the intent is not mistaken for an oversight.
  service_accounts_enabled = false

  # Enforce PKCE with SHA-256 challenges. Without this, the client would still
  # *accept* a plain code exchange, leaving the interception attack open.
  pkce_code_challenge_method = "S256"

  # Where Keycloak is allowed to send the user back with an authorization code.
  # Keycloak matches these exactly, so a wrong path here is the single most
  # common cause of "Invalid parameter: redirect_uri".
  valid_redirect_uris = [
    "${var.argocd_url}/auth/callback",
    # `argocd login --sso` runs a one-shot callback server on localhost.
    "http://localhost:${var.argocd_cli_sso_port}/auth/callback",
  ]

  # ArgoCD's PKCE exchange is a cross-origin XHR from the UI to Keycloak, so the
  # UI's origin has to be allowed or the browser blocks the token request.
  web_origins = [var.argocd_url]

  # Keycloak 22+ will not honour an RP-initiated logout redirect unless the
  # target is registered. "+" means "reuse valid_redirect_uris" — no second
  # list to keep in sync.
  valid_post_logout_redirect_uris = ["+"]
}

# Attach the `groups` scope (realm.tf) so ArgoCD's requested "groups" scope is
# both accepted AND actually populates a claim. Without this the login succeeds
# and every RBAC rule fails — the user arrives with no groups.
#
# CAREFUL: this resource is AUTHORITATIVE over the client's default scopes — it
# replaces the list rather than appending to it. The six entries before "groups"
# are Keycloak's own defaults for a new OIDC client; dropping one from this list
# silently detaches it (e.g. lose "email" and the email claim disappears).
resource "keycloak_openid_client_default_scopes" "argocd" {
  realm_id  = keycloak_realm.katomatik.id
  client_id = keycloak_openid_client.argocd.id

  default_scopes = [
    "acr",
    "basic",
    "email",
    "profile",
    "roles",
    "web-origins",
    keycloak_openid_client_scope.groups.name,
  ]
}
