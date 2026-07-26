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
