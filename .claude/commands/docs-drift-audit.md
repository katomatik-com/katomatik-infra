---
description: Reconcile docs/ against the live system and report every stale factual claim
argument-hint: "[optional path or topic to scope the audit, e.g. docs/guides/keycloak-oidc-sso.md]"
---

Act as a **documentation drift auditor** for this repository.

Documentation here is a derived artifact that must match reality
([ADR-0017](../../docs/adr/0017-docs-in-git-backlog-in-jira.md)). Your job is to establish
what is actually running, compare it against what the docs claim, and report the gap.

Scope for this run: **$ARGUMENTS** — if that is empty, audit all of `docs/` plus
`README.md` and `CLAUDE.md`.

## Step 1 — Establish ground truth

**Run the collector first. Everything else depends on it:**

```sh
DIR=$(scripts/ground-truth.sh)   # prints the output directory; progress goes to stderr
cat "$DIR/summary.txt"
```

It gathers the live system into one directory: cluster workloads, images, ingress hosts
and paths, ArgoCD app sync/health, `argocd-cm`, the Keycloak CR, Terraform outputs and
resource inventories from **both** workspaces, public HTTP status codes, the OIDC
discovery document, and recent git history. Read the files you need from `$DIR` — do not
re-run the commands by hand.

**If the script does not run, or you did not run it, the audit does not proceed.** Say so
and stop. An audit that skips this step reports "all confirmed" because it never looked,
which is worse than no audit at all.

**`summary.txt` is the honesty check.** Each collector is listed `OK` or `FAILED` —
sources fail for real and expected reasons (the cluster API is `homelab.lan:6443`, so it
is unreachable off the LAN; the Keycloak workspace needs a port-forward; HCP needs
credentials). **Every claim that a FAILED source would have covered must be reported
UNVERIFIABLE**, never assumed.

Two things the collector deliberately does not give you, to fetch yourself only if a
specific claim needs them:

- **Rendered manifests**, where they differ from source: `helm template` for chart-based
  apps, the kustomize+ksops path for the secret apps.
- **Authenticated behaviour** — e.g. the authdemo RBAC matrix, which needs a driven login
  (the curl flow in `docs/guides/securing-an-app-with-oidc.md`).

Never infer live state from the docs you are auditing — that is circular, and it is
exactly the failure this audit exists to catch.

## Step 2 — Audit the claims

Read every file in scope. For each **checkable factual claim** — hostnames, domains, image
tags, ports, redirect URIs, versions, provider accounts, which paths are routed, what a
given request returns, where a secret lives, what a flag is set to — mark it:

- **CONFIRMED** — verified against ground truth just now.
- **STALE** — contradicted by ground truth.
- **UNVERIFIABLE** — could not be checked this run; say which source was missing.

Prose about *why* a choice was made is not a factual claim. Do not mark reasoning stale.

## Step 3 — Report before changing anything

A table: file · the claim as written · current reality · the commit where it drifted
(`git log -S` on the value is usually enough to find it).

## Step 4 — Fix, carefully

- **Update only forward-looking docs**: guides, READMEs, runbooks.
- **Never rewrite a historical ADR.** An ADR records a decision *as it was made*. If it no
  longer holds, add a superseded-by note at the top and write a NEW ADR — the house rule
  in `CLAUDE.md`. A blanket rename that rewrites ADR history has caused real damage here
  before.
- Fix the claim, not the surrounding prose. A drift audit is not an editing pass.
- If a doc is stale because the *system* is wrong rather than the doc, say so and stop —
  that is a bug report, not a doc fix.

## Step 5 — Flag anything that looks like a security problem

Exposed management endpoints, plaintext secrets committed, overly broad ingress rules,
credentials in prose or examples. Report; do not fix silently.

## Guardrails

- **Never print a secret value.** The collector is built not to gather any (`terraform
  output` redacts sensitive values; secrets are listed by name and type only), and it
  aborts if a credential reaches its output anyway. That backstop protects the collector,
  not you: if you run `terraform show` or `kubectl get secret -o jsonpath` by hand you will
  get live credentials, and base64 is *not* encryption. Report that a secret exists and
  where; never what it is.
- **The collector writes outside the repo** (a `mktemp -d` under `$TMPDIR`), deliberately —
  this repo is public and a dump of live infrastructure state has no business near
  `git add`. Do not move it inside, and do not paste its contents into a doc.
- **Do not commit or push.** Show the report and the proposed diff, and wait for an
  explicit go-ahead.
- Prefer read-only commands. Nothing in this audit should mutate the cluster, the realm, or
  any Terraform state.
- If the audit finds work worth doing rather than a doc to fix, that belongs in **Jira
  (project KI)**, not in a new file.
