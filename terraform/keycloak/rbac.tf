# Who gets to do what — the Keycloak half of ArgoCD's RBAC.
#
# The split to keep straight: Keycloak asserts *membership* ("this person is in
# argocd-admins"), ArgoCD decides *permissions* (argocd-rbac-cm maps that group
# name to role:admin). Keycloak knows nothing about ArgoCD's roles, and ArgoCD
# never manages users. Group name and RBAC rule must agree exactly.

resource "keycloak_group" "argocd_admins" {
  realm_id = keycloak_realm.katomatik.id
  name     = "argocd-admins"
}

# Phase 1's test identity: one human, to prove the login path end to end.
resource "keycloak_user" "test_admin" {
  realm_id = keycloak_realm.katomatik.id
  username = var.test_admin_username
  email    = var.test_admin_email
  enabled  = true

  # No SMTP in this realm yet (see realm.tf), so an unverified email would mean
  # an unfinishable verification step. Asserted as verified instead — a
  # deliberate learning-stage simplification, not how a real signup should work.
  email_verified = true

  # Applied at CREATE time only; later edits here do not rotate the password
  # (that is a credentials API operation, not a user attribute).
  initial_password {
    value = var.test_admin_password
    # temporary = true adds an UPDATE_PASSWORD required action: Keycloak forces
    # a change at first login, so the value that passed through Terraform state
    # and this shell's environment stops being a working credential immediately.
    temporary = true
  }
}

# Membership. `exhaustive = true` means Terraform owns this user's group list
# completely — a group added by hand in the admin console gets removed on the
# next apply. That is the point: drift shows up as a diff instead of quietly
# granting someone admin.
resource "keycloak_user_groups" "test_admin" {
  realm_id   = keycloak_realm.katomatik.id
  user_id    = keycloak_user.test_admin.id
  group_ids  = [keycloak_group.argocd_admins.id]
  exhaustive = true
}
