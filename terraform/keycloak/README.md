# `terraform/keycloak` — Keycloak configuration as code

Realms, clients, client scopes, protocol mappers, groups and users for the
in-cluster Keycloak. **Why Terraform and not the operator's CRs:**
[ADR-0015](../../docs/adr/0015-keycloak-config-via-terraform.md) —
`KeycloakRealmImport` is create-only, so it cannot add a client to a realm that
already exists, and `KeycloakOIDCClient` is `v2alpha1` with no `publicClient` or
PKCE fields.

Division of labour:

| Layer | Owner |
| --- | --- |
| Keycloak **instance** (StatefulSet, DB, hostname, Ingress) | Keycloak Operator via ArgoCD (`manifests/keycloak/`) — [ADR-0014](../../docs/adr/0014-keycloak-operator.md) |
| Keycloak **configuration** (realm, clients, groups, mappers, users) | this workspace — [ADR-0015](../../docs/adr/0015-keycloak-config-via-terraform.md) |
| ArgoCD's own OIDC/RBAC settings | ArgoCD Helm values (`argocd/values.yaml`) |

## How this differs from `terraform/`

The sibling workspace (Cloudflare + Neon) uses **HCP** for state and remote
execution. This one is **local for both**, on purpose: HCP's runners are on the
internet, and the Keycloak admin API is never exposed there. Runs happen here,
next to the kubeconfig, over a port-forward.

Consequence: **`terraform.tfstate` is a local file containing secrets** (the
test user's initial password). It is covered by `.gitignore` (`*.tfstate`) — keep
it that way. Losing it is not fatal; every resource here can be re-imported.

## Running it

Two terminals. First, the tunnel to the admin API — the provider talks to
`localhost:8080`, so this must stay up for the whole run:

```sh
kubectl -n keycloak port-forward svc/keycloak-service 8080:8080
```

Then, in a second terminal, the credentials. These are read from the
environment, never from a `.tfvars` file, so nothing sensitive is written to
disk in this directory:

```sh
cd terraform/keycloak

# Bootstrap admin account, straight out of the cluster Secret.
export KEYCLOAK_USER=$(kubectl -n keycloak get secret keycloak-initial-admin \
  -o jsonpath='{.data.username}' | base64 -d)
export KEYCLOAK_PASSWORD=$(kubectl -n keycloak get secret keycloak-initial-admin \
  -o jsonpath='{.data.password}' | base64 -d)

# Initial password for the test admin (forced to change at first login).
# Leading space keeps it out of shell history if HIST_IGNORE_SPACE is set.
 export TF_VAR_test_admin_password='<pick something >=12 chars>'

terraform init      # first time only
terraform plan
terraform apply
```

Sanity check that the credentials work before blaming the provider:

```sh
curl -s -o /dev/null -w '%{http_code}\n' \
  http://localhost:8080/realms/master/.well-known/openid-configuration   # 200
```

## First-run only: the realm import

The `katomatik` realm already exists (the operator's `KeycloakRealmImport`
created it). `import.tf` adopts it into state rather than recreating it, so the
realm keeps its internal ID and its users. The first plan should say:

```
Plan: N to add, 1 to change, 0 to destroy.
```

`0 to destroy` is the line that matters. **Delete `import.tf` after that first
successful apply** — the migration is finished and the block is then noise.

## Gotchas worth remembering

- **The admin console is not exposed.** `/admin` is not routed through the
  Ingress (Traefik 404s it). Everything admin-side happens over the
  port-forward, including this workspace.
- **Terraform needs a *running* port-forward.** `connection refused` from the
  provider almost always means the tunnel died, not a config error.
- **`keycloak_openid_client_default_scopes` is authoritative.** It replaces the
  client's default-scope list. Removing an entry detaches that scope.
- **`full_path` on the groups mapper must stay `false`.** `true` emits
  `/argocd-admins` and every ArgoCD RBAC rule stops matching.
- **Realms are protected.** `terraform_deletion_protection = true` on the realm
  blocks a destroy that would take all users with it.

## Follow-up hardening (not done yet)

- **Dedicated Terraform service account** instead of the bootstrap
  `keycloak-initial-admin` superuser: a confidential client with
  `service_accounts_enabled` and only the `realm-management` roles needed.
- **Brute-force detection** (`security_defenses`) and **SMTP**, which in turn
  unlocks `verify_email` / `reset_password_allowed`.
- **Remote state** if this ever stops being a single-operator laptop workflow.
