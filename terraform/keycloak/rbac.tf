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

# The admin identity — first used to prove the login path end to end.
#
# SIMPLIFICATION, chosen deliberately: this is a SHARED platform credential
# (`katomatik`), not a named personal account. What that costs, so it is not
# discovered the hard way later: audit events and Keycloak sessions attribute
# actions to "katomatik" rather than to a person, so with more than one operator
# there is no way to tell who did what; the credential cannot be revoked for one
# person without locking out everyone; and per-user MFA protects an account
# rather than an individual. Fine for a single-operator lab. The upgrade path is
# named accounts added to the same `argocd-admins` group — permissions come from
# group membership, so no ArgoCD-side change is needed to make that switch.
resource "keycloak_user" "admin" {
  realm_id = keycloak_realm.katomatik.id
  username = var.admin_username
  email    = var.admin_email
  enabled  = true

  # No SMTP in this realm yet (see realm.tf), so an unverified email would mean
  # an unfinishable verification step. Asserted as verified instead — a
  # deliberate learning-stage simplification, not how a real signup should work.
  # NB: admin@katomatik.com must actually exist by the time SMTP is configured,
  # or password-reset mail will silently go nowhere.
  email_verified = true

  # Applied at CREATE time only; later edits here do not rotate the password
  # (that is a credentials API operation, not a user attribute).
  initial_password {
    value = var.admin_initial_password
    # temporary = true adds an UPDATE_PASSWORD required action: Keycloak forces
    # a change at first login, so the value that passed through Terraform state
    # and this shell's environment stops being a working credential immediately.
    temporary = true
  }

  lifecycle {
    # `required_actions` is RUNTIME credential state, owned by Keycloak and the
    # user — not by this file. Keycloak ADDS "UPDATE_PASSWORD" because of
    # temporary = true above, then REMOVES it once the password is changed.
    #
    # Terraform must be told to stay out of it, because the attribute is
    # optional-but-not-computed: with nothing declared here, Terraform reads
    # config as "empty" and plans to strip the action — which would quietly
    # cancel the forced password change and promote a generated throwaway into a
    # permanent credential. (Observed for real on the first post-apply plan.)
    #
    # Declaring `required_actions = ["UPDATE_PASSWORD"]` instead would be worse:
    # after a legitimate password change Terraform would keep re-adding it,
    # forcing another change on every single apply.
    #
    # `first_name` / `last_name` are the same category: PROFILE data owned by
    # whoever holds the account and editable in Keycloak's account console. They
    # were set by hand at first login, and — being optional-but-not-computed —
    # the next plan wanted to null both back out. Ignoring them keeps Terraform
    # from reverting the account console. (If this account's display name ever
    # needs to be authoritative in code, declare the fields instead and accept
    # that Terraform will win over the console.)
    ignore_changes = [required_actions, first_name, last_name]
  }
}

# Membership. `exhaustive = true` means Terraform owns this user's group list
# completely — a group added by hand in the admin console gets removed on the
# next apply. That is the point: drift shows up as a diff instead of quietly
# granting someone admin.
resource "keycloak_user_groups" "admin" {
  realm_id   = keycloak_realm.katomatik.id
  user_id    = keycloak_user.admin.id
  group_ids  = [keycloak_group.argocd_admins.id]
  exhaustive = true
}
