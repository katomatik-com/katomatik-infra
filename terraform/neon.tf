# See also https://neon.com/docs/reference/terraform
# A Neon project is the top-level container for your Postgres databases, 
# branches, and endpoints.
resource "neon_project" "keycloak" {
  name      = "homelab-keycloak"
  pg_version = 17 # pinned to a version Keycloak officially tests against (not newest-by-default)
  region_id = "aws-eu-central-1" # Frankfurt
  org_id    = var.neon_organization_id
  # free accounts have maximum retention window of 6 hours (21600 seconds)
  history_retention_seconds = 21600

  # Configure default branch settings (optional)
  branch {
    name          = "production"
    database_name = "keycloak_db"
    role_name     = "keycloak_admin"
  }
  
  # Configure default endpoint settings (optional)
  default_endpoint_settings {
    autoscaling_limit_min_cu = 0.25
    autoscaling_limit_max_cu = 1.0
    # suspend_timeout_seconds  = 300 # only available for paid plans
  }
}

