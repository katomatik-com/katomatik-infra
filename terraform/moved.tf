# State re-addressing for the single-zone → multi-zone refactor (KI-28).
#
# WHY THIS FILE EXISTS
#
# Terraform state maps a resource ADDRESS to a real remote object. It diffs by
# that address, not by identity. Going from one hardcoded domain to a `zones`
# map renamed every zone-shaped address while leaving the Cloudflare objects
# themselves completely untouched:
#
#   cloudflare_zone.primary          → cloudflare_zone.this["katomatik.com"]
#   cloudflare_dns_record.app[label] → cloudflare_dns_record.subdomain["katomatik.com/<label>"]
#   cloudflare_dns_record.apex       → cloudflare_dns_record.apex["katomatik.com"]
#
# Without these blocks Terraform reads each old address as "in state but gone
# from config" (destroy) and each new one as "in config but missing from state"
# (create) — a plan that DESTROYS AND RECREATES live production DNS. The apex
# and the argocd/auth/authdemo records would stop resolving mid-apply, and a
# recreated ZONE is assigned new nameservers, breaking the registrar delegation
# too.
#
# A `moved` block renames the state entry instead: it is pure bookkeeping, no
# provider call, no request to Cloudflare. Terraform processes it before
# computing the diff, so config and state line up and the plan shows no change.
#
# WHY NOT `terraform state mv`
#
# State lives in HCP, so the imperative form would reach into remote state from
# a laptop instead of running where every other change runs — and it would leave
# no trace in the diff. `moved` ships in the same commit as the refactor, gets
# reviewed with it, and applies identically under HCP remote execution.
# ADR-0007 deliberately avoided state surgery; this keeps that property.
#
# LIFECYCLE
#
# These are one-shot. After the apply lands, state holds the new addresses and
# the blocks match nothing and cost nothing; they can be dropped in a later
# cleanup commit. Deleting them BEFORE that apply re-arms the destroy/create.

moved {
  from = cloudflare_zone.primary
  to   = cloudflare_zone.this["katomatik.com"]
}

# The subdomain records: the resource was renamed (app → subdomain) AND re-keyed
# ("argocd" → "katomatik.com/argocd"), so every existing key needs its own block.
# This key set must match terraform.tfvars exactly — a label present in one and
# missing here silently falls back to the destroy/create described above, which
# is why the acceptance test is the PLAN OUTPUT, not a reading of this file.
moved {
  from = cloudflare_dns_record.app["argocd"]
  to   = cloudflare_dns_record.subdomain["katomatik.com/argocd"]
}

moved {
  from = cloudflare_dns_record.app["www"]
  to   = cloudflare_dns_record.subdomain["katomatik.com/www"]
}

moved {
  from = cloudflare_dns_record.app["auth"]
  to   = cloudflare_dns_record.subdomain["katomatik.com/auth"]
}

moved {
  from = cloudflare_dns_record.app["authdemo"]
  to   = cloudflare_dns_record.subdomain["katomatik.com/authdemo"]
}

# The apex kept its resource name but gained for_each, so it moves from a single
# unkeyed instance to a keyed one.
moved {
  from = cloudflare_dns_record.apex
  to   = cloudflare_dns_record.apex["katomatik.com"]
}
