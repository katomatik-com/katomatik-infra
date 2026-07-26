# Non-secret configuration for this workspace, committed to Git — same
# convention as ../terraform.tfvars. Secrets never appear here; they arrive
# through the environment (see README.md and tf.sh).

# --- The platform admin account -----------------------------------------------
# Who gets admin on ArgoCD, via membership of the `argocd-admins` group. These
# have no defaults in variables.tf on purpose, so this file is the single,
# reviewable place that decision is recorded.
#
# A SHARED credential, chosen deliberately over named personal accounts — see
# the trade-off spelled out on keycloak_user.admin in rbac.tf.
admin_username = "katomatik"
admin_email    = "admin@katomatik.com"
