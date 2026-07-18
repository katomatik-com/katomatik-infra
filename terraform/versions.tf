# Terraform + provider versions, HCP backend, and the Cloudflare provider.
# See ADR-0005 and docs/terraform-cloudflare.md.

terraform {
  required_version = ">= 1.9"

  # HCP Terraform (remote state + remote execution). Runs happen in HCP with the
  # sensitive CLOUDFLARE_API_TOKEN env var injected; state lives in HCP.
  cloud {
    organization = "kurt_homelab"
    workspaces {
      name = "homelab"
    }
  }

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
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
