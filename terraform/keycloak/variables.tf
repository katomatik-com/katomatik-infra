# Non-secret inputs. Secrets come from the environment, never from Git:
#   KEYCLOAK_USER / KEYCLOAK_PASSWORD  → admin API auth (provider, versions.tf)
#   TF_VAR_admin_initial_password      → the admin account's initial password
# See README.md for the exact export lines.

variable "keycloak_url" {
  description = <<-EOT
    Admin REST API base URL. Points at the `kubectl port-forward` tunnel, NOT
    at auth.katomatik.com — the admin API is deliberately not exposed publicly
    (ADR-0015). Keycloak's fixed `hostname` setting only rewrites *browser*
    redirects, so REST calls over localhost work fine.
  EOT
  type        = string
  default     = "http://localhost:8080"
}

variable "keycloak_public_url" {
  description = <<-EOT
    Public browser-facing Keycloak URL. Used to build the OIDC issuer that
    relying parties (ArgoCD) must be configured with — this, not keycloak_url,
    is what ends up in argocd-cm.
  EOT
  type        = string
  default     = "https://auth.katomatik.com"
}

variable "realm" {
  description = "The single realm that is katomatik's identity domain."
  type        = string
  default     = "katomatik"
}

variable "argocd_url" {
  description = "Public ArgoCD URL — origin for the client's redirect URIs."
  type        = string
  default     = "https://argocd.katomatik.com"
}

variable "argocd_cli_sso_port" {
  description = <<-EOT
    Localhost port `argocd login --sso` spins up a throwaway callback server on
    (the CLI's --sso-port default). Its redirect URI must also be registered on
    the client, or CLI SSO login fails while the browser flow works.
  EOT
  type        = number
  default     = 8085
}

// Deliberately NO defaults on the two below: they decide who holds admin on
// ArgoCD. A default would let a run quietly grant that to whoever the default
// names. Values live in terraform.tfvars (committed — they are not secrets).

variable "admin_username" {
  description = "Username of the platform admin account (member of argocd-admins)."
  type        = string
}

variable "admin_email" {
  description = "Email for that account. ArgoCD displays it as the logged-in identity."
  type        = string
}

variable "admin_initial_password" {
  description = <<-EOT
    INITIAL password for the admin account, set as a *temporary* credential —
    Keycloak forces a change at first login, so this value stops being a working
    credential the moment it is used. Supply via
    `export TF_VAR_admin_initial_password=...`; it lands in the LOCAL
    terraform.tfstate (gitignored), never in Git.
  EOT
  type        = string
  sensitive   = true
}
