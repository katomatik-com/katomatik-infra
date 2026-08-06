# ADR-0017: Documentation stays in Git; open work is tracked in Jira

## Status

Accepted — 2026-08-06.

## Context

Two different artifacts had been living in the same repo and being treated alike:

- **Decisions and guides** (`docs/adr/`, `docs/guides/`) — durable explanations of *why*
  the infrastructure is the way it is, written alongside the config they describe.
- **Open work** (`.plan/securing-apps.md`) — a 550-line working file tracking phases,
  status and a backlog of deferred items.

The second was the weaker artifact by a distance. `.plan/` is gitignored, so the backlog
existed on exactly one Mac: no history, not visible from the server or anywhere else, and
recoverable from nothing if the file were lost. Every working session began by re-reading
it to find the dozen items that were actually open.

A `katomatik.atlassian.net` site now exists with both Jira and Confluence, which raised
the real question: if the backlog moves to Jira, should the documentation move to
Confluence too?

A third force is worth naming, because it cuts the other way. Documentation is this
project's largest output, and it makes a great many *checkable factual claims* —
hostnames, image tags, ports, redirect URIs, which paths are routed, what a given curl
returns. Those claims drift as the infrastructure changes underneath them, and drift is
silent. Any decision about where docs live has to account for how they are kept true.

## Decision

**Documentation stays in Git. Open work moves to Jira. They are different artifacts with
different lifecycles, and the split is along that line — not along "old vs new tooling".**

- **ADRs and guides stay in `docs/`,** for four reasons that are all consequences of
  code-adjacency:
  - An ADR's value comes from landing **in the same commit** as the config it explains,
    being reviewable as a diff, and superseding its predecessor through history rather
    than a page edit. Split them from the repo and drift becomes the default.
  - The repo is **public by design** ([ADR-0006](0006-public-repo-anonymous-https.md)),
    and the docs are most of what makes it legible to anyone else. Confluence puts them
    behind a login for an audience of one.
  - The **link graph assumes one repo**: the README doc map, ADR cross-references, guide
    anchors, and code comments that point at `docs/guides/…`.
  - **Docs-as-code is itself part of what this project exists to learn**, and the working
    style depends on it — sessions read `docs/` directly from the working copy.
- **Open work is tracked in Jira project `KI` (katomatik-infra)**, one epic per
  initiative. An issue carries not just the task but **the reason it was deferred**, which
  is the part that was expensive to reconstruct from a plan file.
- **`.plan/securing-apps.md` is frozen, not deleted** — it is the source the issues were
  written from, and being gitignored it has no history to recover from.
- **Confluence is reserved for material that is genuinely not code-adjacent** — a project
  overview, the account inventory (pointers, never values), the manual bootstrap runbook —
  and links out to GitHub rather than duplicating it. **Nothing has been moved there**;
  that scope is a proposal until something is actually written.
- **Docs are kept true by a reconciliation pass, not by discipline.** `/docs-drift-audit`
  (`.claude/commands/`) marks every factual claim in `docs/` as CONFIRMED, STALE or
  UNVERIFIABLE against ground truth collected by `scripts/ground-truth.sh` — HCP and local
  Terraform outputs, `kubectl`, public HTTP behaviour, `git log`. The collector gathers **no
  secrets** by construction and writes **outside** the repo, and its `summary.txt` marks
  each source `OK` or `FAILED` so an unreachable source produces UNVERIFIABLE rather than a
  silent pass.

That last point is what turns a weakness into an argument. Docs that live next to the code
**can be mechanically reconciled against the running system**; a Confluence page cannot be
diffed against `terraform show`.

## Consequences

**Positive**

- The backlog is durable, queryable, and reachable from any machine — with history, which
  it never had.
- Documentation keeps code-adjacency: same commit, same review, same public repo.
- The *reasoning* behind every deferred item survives in the issue rather than in one long
  file that only one person reads.
- Doc rot becomes **detectable** rather than a matter of remembering, and the audit is
  possible precisely because docs and ground truth are reachable from the same working
  copy.

**Negative / trade-offs**

- **Two systems to keep straight.** A decision lives in Git; the work item that produced
  it lives in Jira. The convention that keeps this honest: reference the `KI-…` key in the
  ADR or commit when one drove the other.
- **The public repo no longer tells the whole story** — the open-work list is behind a
  login. Accepted: the repo documents what *is*, the tracker what *isn't yet*.
- **Another external dependency** for a core workflow, in the same family as Cloudflare,
  HCP and Neon ([ADR-0007](0007-dedicated-katomatik-cloudflare-hcp-accounts.md)). If
  Atlassian is down the backlog is unreadable; unlike Neon, nothing user-facing breaks.
- **Jira is reachable only through an interactively-authenticated connector**, and the
  OAuth grant is **single-site** — granting `katomatik.atlassian.net` removed the other
  site. Headless or scheduled sessions may not see Jira at all.
- **The drift audit must run locally.** See the rejected alternative below; this is a real
  constraint, not a preference.

**Learning simplification**

- One Jira project, no sprints, boards or workflow customisation — priorities and labels
  only. Ceremony that a single-operator lab does not need would obscure whether the
  tracker is actually earning its place.

**Alternatives considered**

- **Move ADRs and guides to Confluence.** Rejected for the four code-adjacency reasons
  above. The strongest single one: an ADR that supersedes another is a *commit* in this
  model and a *page edit* in that one, and only the first ties the reasoning to the change
  that motivated it.
- **Mirror the docs into Confluence.** Rejected: two copies with no defined winner is
  worse than either alone, and the sync effort is permanent. Confluence can link to
  GitHub instead.
- **GitHub Issues instead of Jira.** Genuinely viable — free, same repo, native commit
  links. Rejected because learning the Atlassian tooling is an explicit goal here, and
  secondarily because a granular, public list of *known-and-not-yet-hardened* surfaces is
  a more useful document to an attacker than the general "deliberately not done" notes the
  guides already carry.
- **Keep using `.plan/`.** Rejected: one machine, no history, no visibility, and it is
  read start-to-finish to find a handful of live items.
- **Run the drift audit as a scheduled GitHub Actions job** (as originally suggested).
  Rejected *for the live-state half*: the cluster API is `https://homelab.lan:6443` — a
  LAN-only address a hosted runner cannot reach — and `terraform/keycloak` keeps **local**
  state on the Mac, so `terraform show` there is impossible off-machine. A CI job could
  audit only the static subset (docs vs manifests, workflows and git history) while
  silently losing the checks that matter most. Running it locally, where the kubeconfig,
  HCP credentials and local state all already exist, keeps the audit honest. Revisit if a
  self-hosted runner on the node ever exists.
