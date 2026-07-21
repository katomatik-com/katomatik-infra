# ADR-0004: ArgoCD reads the private repo via a read-only SSH deploy key

## Status

Superseded by [ADR-0006](0006-public-repo-anonymous-https.md) — 2026-07-21.
(Accepted 2026-07-14.) The repo was made public and moved to
`katomatik-com/katomatik-infra`; ArgoCD now reads it anonymously over HTTPS, so
this deploy-key credential no longer applies. The mechanism below remains the
reference for the private repos introduced in later phases.

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
  credential cannot be, by definition). See **Setup steps** below for the exact
  commands.
- All Application manifests reference the repo by its **SSH URL**
  (`git@github.com:katomatik-com/katomatik-infra.git`) so they match this credential. GitHub's
  host key is already in ArgoCD's shipped `argocd-ssh-known-hosts-cm`, so no
  known-hosts step is needed.

## Setup steps (reproducible)

All from the control node (the Mac); for the `kubectl` steps
`export KUBECONFIG=~/.kube/homelab.config` first.

1. **Generate the read-only deploy keypair** — ed25519, **no passphrase** so
   ArgoCD can use it non-interactively:

   ```sh
   ssh-keygen -t ed25519 -C "argocd-homelab-deploy" \
     -f ~/.ssh/homelab_argocd_deploy -N ""
   ```

2. **Register the PUBLIC key as a read-only GitHub deploy key** — omitting
   `--allow-write` keeps it read-only:

   ```sh
   gh repo deploy-key add ~/.ssh/homelab_argocd_deploy.pub \
     -R katomatik-com/katomatik-infra --title argocd-readonly
   gh repo deploy-key list -R katomatik-com/katomatik-infra      # verify
   ```

3. **Apply the PRIVATE key as an ArgoCD repository Secret** — `--from-file`
   keeps the key out of your shell history. The
   `argocd.argoproj.io/secret-type=repository` label is what makes ArgoCD treat
   the Secret as a credential; **without the label it is silently ignored** and
   git falls back to a (nonexistent) SSH agent, failing with
   `SSH agent requested but SSH_AUTH_SOCK not-specified`:

   ```sh
   kubectl -n argocd create secret generic repo-homelab \
     --from-literal=type=git \
     --from-literal=url=git@github.com:katomatik-com/katomatik-infra.git \
     --from-file=sshPrivateKey="$HOME/.ssh/homelab_argocd_deploy"
   kubectl -n argocd label secret repo-homelab \
     argocd.argoproj.io/secret-type=repository
   ```

4. **Verify** the credential is registered and complete:

   ```sh
   kubectl -n argocd get secret repo-homelab -o json \
     | jq '{labels: .metadata.labels, keys: (.data | keys)}'
   # expect the repository label and ["sshPrivateKey","type","url"]
   ```

   In the UI, **Settings → Repositories** should list the SSH URL as
   **Successful**. The Secret's `url` must match the Applications' `repoURL`
   byte-for-byte, or no credential matches.

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
