# ADR-0004: ArgoCD reads the private repo via a read-only SSH deploy key

## Status

Accepted — 2026-07-14.

## Context

This repo is **private**. ArgoCD reconciles from Git (per
[ADR-0003](0003-argocd-only-gitops-helmfile-dropped.md)): its repo-server
clones the repo to render `apps/` and the values files. With no credential,
GitHub rejects the clone (`authentication required: Repository not found`),
ArgoCD cannot compute a diff, and every Application sits in `ComparisonError`.

So ArgoCD needs credentials to **read** the repo. This exposes a bootstrap
chicken-and-egg: **the credential that lets ArgoCD read Git cannot itself live
in that Git repo.** It must be supplied out-of-band. This also corrects an
earlier working assumption that the repo was public and needed no repo
credential — it is private, and this credential is in fact the *first*
out-of-band bootstrap secret, ahead of the SOPS-encrypted values that begin at
the Cloudflare Tunnel phase.

Options considered:

- **A — Make the repo public.** Simplest; SOPS keeps any committed secret values
  safe even in public. Rejected: publishing is effectively irreversible (history
  may be cloned/cached), and there's no need to expose the lab's infra.
- **B — Private + read-only SSH deploy key.** A keypair scoped to *this one repo*,
  read-only, not tied to a user account. **Chosen.**
- **C — Private + fine-grained PAT (HTTPS).** Works with the existing HTTPS URLs
  and no manifest changes, but the token is tied to the user account and needs
  expiry management. Rejected as second choice: a deploy key is more precisely
  scoped and account-independent.

## Decision

ArgoCD authenticates to the private repo with a **read-only SSH deploy key**.

- A dedicated ed25519 keypair is generated on the control node
  (`~/.ssh/homelab_argocd_deploy`), with **no passphrase** so ArgoCD can use it
  non-interactively.
- The **public** key is registered on the GitHub repo as a **read-only** Deploy
  Key (`gh repo deploy-key add … --title argocd-readonly`).
- The **private** key is applied **by hand** as an ArgoCD repository Secret in
  the `argocd` namespace — the out-of-band bootstrap secret. It is **never
  committed**, and does not use SOPS (SOPS is for values *in* Git; this
  credential cannot be, by definition):

  ```sh
  kubectl -n argocd create secret generic repo-homelab \
    --from-literal=type=git \
    --from-literal=url=git@github.com:kurtcebe/homelab.git \
    --from-file=sshPrivateKey="$HOME/.ssh/homelab_argocd_deploy"
  kubectl -n argocd label secret repo-homelab \
    argocd.argoproj.io/secret-type=repository
  ```

- All Application manifests reference the repo by its **SSH URL**
  (`git@github.com:kurtcebe/homelab.git`) so they match this credential. GitHub's
  host key is already in ArgoCD's shipped `argocd-ssh-known-hosts-cm`, so no
  known-hosts step is needed.

## Consequences

**Positive**

- Least-privilege: the key is **read-only** and **scoped to a single repo**;
  it can't push, and it isn't tied to a personal account or its other repos.
- The repo stays private; nothing is published.
- Production-representative — this is how real ArgoCD installs read private Git.
- Revoking access is one click (delete the deploy key) or one `kubectl delete
  secret`.

**Negative / trade-offs**

- One more **out-of-band bootstrap secret** to manage and back up alongside the
  ArgoCD admin password and (later) the age key.
- Manifests use SSH URLs, which are slightly less obvious than HTTPS.
- The private key is a plain file on the control node and a Secret in-cluster
  (not SOPS-encrypted) — acceptable and unavoidable for a bootstrap credential,
  but it is a credential to protect and rotate.

## Related

- [ADR-0003](0003-argocd-only-gitops-helmfile-dropped.md) — ArgoCD reconciles
  from Git, which is what makes repo access a hard requirement.
- The SOPS + age decision (`docs/../secrets`) — distinct: SOPS encrypts values
  committed to Git; this deploy key is applied out-of-band and never committed.
