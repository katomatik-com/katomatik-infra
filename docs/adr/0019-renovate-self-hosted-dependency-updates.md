# ADR-0019: Automate dependency updates with self-hosted Renovate

## Status

Accepted — 2026-08-07.

## Context

Shipping a new build of any app meant hand-editing an image tag in this repo.
With three apps (`katomatik-web`, `katomatik-authdemo`, `kurtcebenl-web`) that
is a papercut, but automating it is not merely a convenience question — it is a
**trust** question, which is why it sat unautomated deliberately.

Four constraints shaped the answer:

- **Whoever automates the bump needs write access to this repo**, and this repo
  defines the cluster. A compromised writer does not just ship a bad image; it
  can change any manifest ArgoCD applies. ArgoCD itself reads anonymously over
  HTTPS today (ADR-0006) and holds no write credential.
- **ArgoCD Image Updater cannot be used.** Its documentation is explicit:
  *"Argo CD Image Updater can only update container images for applications
  whose manifests are rendered using either Kustomize or Helm."* Every app here
  uses plain manifests (ADR-0008), so adopting it would mean adopting Kustomize
  first — letting a tool choice decide an open question (KI-36).
- **The existing tags could not be compared.** Images were tagged with a bare
  git SHA (`f23db80`, `sha-27ecc93`). A SHA has no ordering, so no pull-based
  updater can determine which of two builds is newer. Only strategies that read
  image *metadata* (build timestamp, digest) cope — and those belong to the tool
  just ruled out.
- **Frequency is bursty, not steady.** Every historical bump happened during one
  afternoon of active development, which argues against elaborate machinery.

## Decision

**Run Renovate as a scheduled workflow inside this repo, and make image tags
orderable so it can work at all.**

- **Tag scheme first.** All three app repos now publish
  `<UTC build time>-<short sha>` (e.g. `20260807.201618-5e4fa04`) alongside their
  existing SHA tags. The timestamp gives ordering; the trailing SHA keeps the
  commit readable in the manifest. Seconds are included because two builds in
  one day would otherwise tie, and a tie reads as "nothing newer".
- **Self-hosted, in-repo.** `.github/workflows/renovate.yml` runs hourly using
  the repo's own ephemeral `GITHUB_TOKEN`. No app pipeline, no third-party SaaS
  bot, and not the cluster ever holds write access to the manifests that define
  the cluster.
- **PRs, not automerge.** Every bump is a pull request a human merges. Revisit
  once the loop has proven itself.
- **Scope beyond images.** One config also covers Terraform providers, the
  ArgoCD Helm values, `mise` tools, GitHub Actions, and Ansible collections —
  the last overlapping KI-17.

## Consequences

**Positive**

- **No new trust boundary.** The credential is minted per run and dies with it.
  This was the blocking objection to app-CI push and it is fully avoided.
- **One config, all dependency types.** Image bumps became a subset of
  dependency freshness rather than a bespoke mechanism.
- **Validated before it could write.** `renovate-config-validator` plus a
  `--platform=local --dry-run=full` run confirmed all three images extracted
  with the custom versioning applied and `currentVersion` parsed, before the
  workflow was granted any write ability.

**Negative / trade-offs**

- **An org-wide setting had to be relaxed.** Renovate opens PRs with
  `GITHUB_TOKEN`, which requires *"Allow GitHub Actions to create and approve
  pull requests"*. GitHub bundles **create and approve** into one org-level
  checkbox, so this also permits any workflow in any `katomatik-com` repo to
  approve PRs — a self-approval path around required reviews. Accepted because
  there is a single maintainer; it would deserve revisiting with a second.
- **Vulnerability alerts are unavailable, and say so on every run.** Dependabot
  alerts are enabled on the repo, but `GITHUB_TOKEN` cannot read that endpoint
  whatever permissions it is granted — it requires a PAT or GitHub App. The
  Dependency Dashboard therefore shows *"Cannot access vulnerability alerts"*
  permanently. Two fixes were attempted (`security-events: read`, then
  `osvVulnerabilityAlerts`) and neither cleared it. **Accepted as cosmetic**
  rather than pursued: removing it means adopting the long-lived credential this
  decision exists to avoid.
- **Latency.** Renovate polls; a build is not pushed to the infra repo. Up to an
  hour from image publish to PR, versus seconds for app-CI push.
- **Three silent-failure modes**, all of which look like "Renovate isn't
  running" rather than an error, and all now guarded in config or comments:
  1. The `kubernetes` manager has **no default file pattern** — unconfigured it
     matches nothing. Dry run: 0 files before `managerFilePatterns`, 9 after.
  2. The versioning regex must **not capture the trailing SHA** in
     `compatibility` — that group blocks updates across differing values, so
     every build would look incompatible with the last.
  3. `issues: write` is needed for the Dependency Dashboard. Without it the run
     succeeds, `POST /issues` 403s, and updates deferred by `prHourlyLimit`
     become invisible instead of merely delayed — which is exactly what happened
     on the first real run.

**Alternatives considered**

- *App CI raises a PR into this repo* — rejected: gives three pipelines standing
  write access to the cluster's manifests. Deterministic and immediate, and the
  runner-up.
- *App CI commits directly* — rejected: same access with no review step; a
  compromised app pipeline would deploy straight to the cluster.
- *ArgoCD Image Updater* — rejected: requires Kustomize or Helm sources
  (ADR-0008 uses plain manifests), and would additionally hand the cluster write
  access to the repo that defines it.
- *Hosted Renovate GitHub App* — rejected: fastest to set up, but grants a
  third-party SaaS write access here.
- *Digest pinning (`latest@sha256:…`)* — rejected: avoids the tag-scheme change,
  but the manifest stops showing which commit is deployed.

## Related

- [ADR-0008](0008-app-delivery-plain-manifests-and-apex-routing.md) — plain
  manifests, which ruled out Image Updater; also the source of KI-36.
- [ADR-0006](0006-public-repo-anonymous-https.md) — ArgoCD's anonymous
  read-only access, the property this decision preserves.
- [ADR-0017](0017-docs-in-git-backlog-in-jira.md) — why the deferral reasoning
  lived in Jira (KI-22) until it became a decision worth recording here.
