# Terraform + provider versions, HCP backend, and the Cloudflare provider.
# See ADR-0005 and docs/terraform-cloudflare.md.

terraform {
  required_version = ">= 1.9"

  # HCP Terraform (remote state + remote execution). Runs happen in HCP with the
  # sensitive CLOUDFLARE_API_TOKEN env var injected; state lives in HCP.
  cloud {
    organization = "katomatik"
    workspaces {
      name = "katomatik-com"
    }
  }

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    neon = { # not official provider, but it's mentioned at https://neon.com/docs/reference/terraform
      source  = "kislerdm/neon"
      version = "~> 0.15.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# The Cloudflare provider reads the API token from the CLOUDFLARE_API_TOKEN
# environment variable (the sensitive HCP workspace variable) — nothing here.
provider "cloudflare" {}

# the Neon provider reads the API token from the NEON_API_KEY environment 
# variable (the sensitive HCP workspace variable) — nothing here).
provider "neon" {}
