# ADR-0006: Public repo — ArgoCD reads it anonymously over HTTPS

## Status

Accepted — 2026-07-21. **Supersedes [ADR-0004](0004-argocd-repo-access-deploy-key.md).**

## Context

The repo moved to a new home (`katomatik-com/katomatik-infra`) to back the
`katomatik.com` site, and in the process was made **public**.

[ADR-0004](0004-argocd-repo-access-deploy-key.md) is built on a premise that no
longer holds: that the repo is **private**, so ArgoCD needs an out-of-band
read-only SSH deploy key to clone it. ADR-0004 in fact *considered* making the
repo public (its "Option A") and rejected it on the grounds that there was "no
need to expose the lab's infra." That trade-off has now been made deliberately —
the repo is public — so the credential question reopens.

A public repo can be cloned **anonymously**, but only over the right protocol:

- **HTTPS** (`https://github.com/...`) — GitHub serves public repos to anyone,
  no credential.
- **SSH** (`git@github.com:...`) — SSH *always* authenticates, even for a public
  repo. Keeping the SSH URLs would mean keeping a deploy key purely to satisfy
  the transport, for no security benefit.

Since the repo's contents are already public, an SSH deploy key buys nothing.
The only reason to keep one would be to keep the private-repo access pattern
alive as a learning exercise — but that skill isn't lost: later phases will
introduce **private** repos (app source, private charts) that genuinely need
ADR-0004's mechanism.

## Decision

ArgoCD reads the repo **anonymously over its public HTTPS URL**; no repository
credential is used.

- Both Application manifests reference the repo by HTTPS
  (`https://github.com/katomatik-com/katomatik-infra.git`) — the root
  app-of-apps (`argocd/root-app.yaml`) and the ArgoCD self-manage app
  (`apps/argocd.yaml`).
- The out-of-band `repo-homelab` Secret from ADR-0004 is **deleted** by hand
  (`kubectl -n argocd delete secret repo-homelab`). ArgoCD does not manage it:
  it was never in Git and no Application owns it, so ArgoCD will not prune it —
  removal is manual.
- No GitHub deploy key needs removing on the new repo: the ADR-0004 key was
  registered on the *old* repo (`kurtcebe/homelab`), which was never migrated.

## Consequences

**Positive**

- **No bootstrap credential for repo read.** One fewer out-of-band secret to
  create, store, back up, and rotate. The remaining bootstrap secrets are the
  ArgoCD admin password and the age key.
- **Simpler and honest to reality** — the URL scheme now matches the repo's
  actual visibility, instead of authenticating against a repo anyone can read.
- Anonymous HTTPS needs no known-hosts / SSH host-key handling.

**Negative / trade-offs**

- **The lab's infrastructure is now publicly readable** — topology, hostnames,
  and config are visible to anyone. This is acceptable because secret *values*
  are SOPS-encrypted ciphertext (safe in public) and the committed Cloudflare
  IDs are identifiers, not credentials. Still, it is a wider exposure than the
  private repo of ADR-0004.
- **Read is open; write is not.** Anonymous HTTPS grants clone/read only.
  Pushing still requires authentication (the maintainer's `gh` credential), so
  GitOps integrity is unaffected.
- The private-repo deploy-key pattern is no longer exercised here; it returns
  when a genuinely private source (app code, private charts) is added.

## Related

- [ADR-0004](0004-argocd-repo-access-deploy-key.md) — superseded; the
  private-repo + SSH deploy key approach this replaces.
- [ADR-0003](0003-argocd-only-gitops-helmfile-dropped.md) — ArgoCD reconciles
  from Git, which is what makes repo read access a requirement at all.
