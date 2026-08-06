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

Use the wrapper — `./tf.sh` opens the port-forward, waits for the admin API to
actually answer, reads the admin credentials out of the cluster Secret, runs
Terraform, and closes the tunnel again even if the run fails:

```sh
cd terraform/keycloak

# Initial password for the admin account (forced to change at first login).
# Leading space keeps it out of shell history under HIST_IGNORE_SPACE.
 export TF_VAR_admin_initial_password='<pick something >=12 chars>'

terraform init      # first time only
./tf.sh plan
./tf.sh apply
```

`TF_VAR_admin_initial_password` stays your job on purpose: the wrapper will not
invent a value that ends up in state. Leave it unset and Terraform prompts.

Doing it by hand is two terminals — the tunnel has to stay up for the whole run:

```sh
# terminal 1
kubectl -n keycloak port-forward svc/keycloak-service 8080:8080

# terminal 2
export KEYCLOAK_USER=$(kubectl -n keycloak get secret keycloak-initial-admin \
  -o jsonpath='{.data.username}' | base64 -d)
export KEYCLOAK_PASSWORD=$(kubectl -n keycloak get secret keycloak-initial-admin \
  -o jsonpath='{.data.password}' | base64 -d)
terraform plan
```

Sanity check that the tunnel is up before blaming the provider:

```sh
curl -s -o /dev/null -w '%{http_code}\n' \
  http://localhost:8080/realms/master/.well-known/openid-configuration   # 200
```

## Getting values out

Everything a relying party needs comes from outputs, so nothing has to be copied
by hand or hunted for in the admin console:

```sh
./tf.sh output                                    # non-secret values
./tf.sh output -raw authdemo_client_secret        # the Spring app's OIDC secret
./tf.sh output -raw authdemo_test_password        # demo-user / demo-admin login
```

Secrets are marked `sensitive`, so a bare `./tf.sh output` prints `<sensitive>`
and only `-raw` reveals them — you have to ask deliberately.

Safe to use in command substitution:

```sh
export KEYCLOAK_CLIENT_SECRET=$(./tf.sh output -raw authdemo_client_secret)
```

The wrapper writes its own `==>` progress lines to **stderr** precisely so this
works. If they went to stdout, the variable would capture
`==> closing port-forward` instead of the secret — a genuinely nasty bug, since
the app would then fail authentication with a value that *looks* set.

## Relationship to `terraform/` (the parent directory)

They are independent root modules. Terraform never recurses into
subdirectories, so the parent's `plan`/`apply` cannot see or touch anything
here — separate state, separate lock file, separate backend.

One wrinkle worth knowing: the parent is an HCP *CLI-driven* workspace, and
those upload the working directory (subdirectories included) to HCP as a
configuration version. The files here would be inert there, but this workspace's
local `terraform.tfstate` holds secrets, so `terraform/.terraformignore`
excludes `keycloak/` explicitly rather than relying on default ignore rules.

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
- **Optional-but-NOT-computed attributes get CLEARED if you don't declare them.**
  The recurring hazard with this provider — four occurrences so far, including one
  that would have cancelled a forced password change, and one where adding
  `security_defenses.brute_force_detection` would have wiped all eight live
  security headers because the sibling `headers` sub-block wasn't declared.
  Server defaults → pin them. State the server or a user mutates
  (`required_actions`, `first_name`/`last_name`) → `ignore_changes`. Declare a
  parent block → declare all its siblings too.
- **Read the attribute-level diff on every plan**, not just the `Plan: N to…`
  counts — that is the only place these show up. Then require `No changes.`

## Follow-up hardening (not done yet)

- **Dedicated Terraform service account** instead of the bootstrap
  `keycloak-initial-admin` superuser: a confidential client with
  `service_accounts_enabled` and only the `realm-management` roles needed.
- **SMTP**, which in turn unlocks `verify_email` / `reset_password_allowed`.
- **Remote state** if this ever stops being a single-operator laptop workflow.
