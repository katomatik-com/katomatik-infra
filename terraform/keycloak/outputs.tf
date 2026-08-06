# The values relying parties have to be configured with. Printing them here
# keeps the ArgoCD side (argocd/values.yaml) honest: the issuer and client ID
# in that file should be copies of these, not independently-typed guesses.

output "oidc_issuer" {
  description = "OIDC issuer for the katomatik realm — goes into argocd-cm's oidc.config."
  value       = "${var.keycloak_public_url}/realms/${keycloak_realm.katomatik.realm}"
}

output "oidc_discovery_url" {
  description = "Discovery document — curl this to verify the realm is publicly reachable."
  value       = "${var.keycloak_public_url}/realms/${keycloak_realm.katomatik.realm}/.well-known/openid-configuration"
}

output "argocd_client_id" {
  description = "clientID for argocd-cm (public client — there is no secret to output)."
  value       = keycloak_openid_client.argocd.client_id
}

output "argocd_admins_group" {
  description = "Group name that argocd-rbac-cm's policy.csv must match on."
  value       = keycloak_group.argocd_admins.name
}

# --- katomatik-authdemo (Phase 2) ---------------------------------------------

output "authdemo_client_id" {
  description = "clientID for the Spring app's application.yaml."
  value       = keycloak_openid_client.authdemo.client_id
}

output "authdemo_client_secret" {
  description = <<-EOT
    Client secret for the Spring app. CONFIDENTIAL client, so unlike ArgoCD there
    IS a secret here. Read it with `terraform output -raw authdemo_client_secret`
    and pass it to the app as an environment variable — never commit it. Phase 3
    SOPS-encrypts it for the cluster.
  EOT
  value       = keycloak_openid_client.authdemo.client_secret
  sensitive   = true
}

output "authdemo_roles" {
  description = "Client role names the app maps to Spring authorities (ROLE_USER / ROLE_ADMIN)."
  value       = [keycloak_role.authdemo_user.name, keycloak_role.authdemo_admin.name]
}

output "authdemo_test_password" {
  description = <<-EOT
    Password shared by both authdemo test users (demo-user / demo-admin), for
    logging in at https://authdemo.katomatik.com.

    Read it from the RESOURCE rather than from var.test_user_password, so it
    still works in a shell where that variable isn't exported — the value lives
    in state either way. Retrieve with:
      ./tf.sh output -raw authdemo_test_password

    These are disposable TEST identities with non-temporary passwords: a
    deliberate simplification so repeated login testing isn't interrupted. Never
    provision a human's account this way.
  EOT
  value       = keycloak_user.authdemo_test["demo-user"].initial_password[0].value
  sensitive   = true
}

output "authdemo_test_users" {
  description = "Test usernames and the single client role each one holds (deliberately disjoint)."
  value = {
    for u, cfg in local.authdemo_test_users :
    keycloak_user.authdemo_test[u].username => (u == "demo-admin" ? "admin" : "user")
  }
}
