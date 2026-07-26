# Keycloak *configuration* workspace — realms, clients, groups, mappers.
# See ADR-0015. The Keycloak *instance* is Operator-managed (ADR-0014); this
# workspace owns everything inside it that the admin REST API exposes.
#
# Deliberately DIFFERENT from ../ (the Cloudflare/Neon workspace) in two ways:
#
#   1. LOCAL state + LOCAL execution (no `cloud {}` block). HCP's remote runners
#      live on the internet and cannot reach an in-cluster ClusterIP service;
#      the Keycloak admin API is never exposed publicly (ADR-0015), so the run
#      has to happen here, next to the kubeconfig.
#   2. Reached over `kubectl port-forward` (see README.md), not a public URL.
#
# Consequence to keep in mind: terraform.tfstate is a LOCAL file containing
# secrets (e.g. the test user's password). .gitignore blocks *.tfstate.

terraform {
  required_version = ">= 1.9"

  # Explicit local backend — the default, but stated so the contrast with the
  # HCP-backed workspace next door is obvious rather than implied.
  backend "local" {}

  required_providers {
    keycloak = {
      source  = "keycloak/keycloak"
      version = "~> 5.8"
    }
  }
}

# Auth to the Keycloak admin REST API.
#
# `admin-cli` is a built-in PUBLIC client in the master realm, so this is the
# password grant (resource-owner) flow: no client secret, just admin username +
# password. Those two never appear in Git — the provider reads them from the
# KEYCLOAK_USER / KEYCLOAK_PASSWORD environment variables, the same "secrets
# come from the environment, not the HCL" pattern the Cloudflare and Neon
# providers use next door.
#
# Interim: the bootstrap `keycloak-initial-admin` account (full superuser).
# Hardening follow-up: a dedicated service-account client with only the
# realm-management roles Terraform actually needs.
provider "keycloak" {
  client_id = "admin-cli"
  url       = var.keycloak_url
  # username = from $KEYCLOAK_USER
  # password = from $KEYCLOAK_PASSWORD
}
