# ADR-0012: ArgoCD decrypts SOPS secrets via KSOPS

## Status

Accepted — 2026-07-24.

## Context

The secrets strategy is SOPS + age (`CLAUDE.md`): encrypt secret *values* in
YAML, commit the ciphertext to this public repo, and decrypt at render time. So
far the only encrypted secret — the Cloudflare Tunnel credential — is decrypted
**host-side by Ansible** on the Mac ([ADR-0002](0002-cloudflare-tunnel-host-daemon-to-traefik.md)),
which never involved the cluster.

The first component that needs an **in-cluster** secret is Keycloak (its Neon
database URL). That secret must exist as a Kubernetes `Secret`, which means
something has to turn ciphertext → plaintext **inside ArgoCD's rendering step** —
the only point between "raw Git" and "applied to cluster". That step lives in the
**argocd-repo-server** (it runs `helm template` / `kustomize build` / plain-dir
reads). ArgoCD has no decryption capability wired up today, so we must choose
one. The realistic options are all ways to hook a `sops -d` into the repo-server:

- **KSOPS** — a kustomize *generator* plugin that decrypts SOPS files into
  plaintext `Secret`s during `kustomize build`.
- **Config Management Plugin (CMP) sidecar** — a sidecar on the repo-server whose
  `generate` command runs `sops -d` over plain manifests.
- **argocd-vault-plugin** — placeholder substitution from a backend; SOPS is one
  backend.
- A *different school* — Sealed Secrets / External Secrets Operator — already
  rejected in the secrets strategy (cluster-bound key / needs a backend).

A tension to weigh: [ADR-0008](0008-app-delivery-plain-manifests-and-apex-routing.md)
deliberately keeps our own workloads as **plain manifests, not kustomize**. KSOPS
*requires* a kustomization wrapper for the secrets it generates.

## Decision

**Use KSOPS for ArgoCD-side SOPS decryption, scoped to secret Applications only.**
Concretely:

- **An init container installs `ksops` + `kustomize`** into the argocd-repo-server
  (configured through the argo-cd Helm `values.yaml`, our single source of truth
  for ArgoCD — [ADR-0003](0003-argocd-only-gitops-helmfile-dropped.md)).
- **Enable the plugin flags** `--enable-alpha-plugins --enable-exec` via
  `kustomize.buildOptions` in `argocd-cm`.
- **Secret-bearing apps become a kustomization** — a `kustomization.yaml` with a
  `generators:` entry → a `ksops` generator config → the `*.sops.yaml` file(s).
  This is a **deliberate, scoped exception to ADR-0008**: kustomize enters the
  repo *only* for secret generation; ordinary workloads stay plain manifests.
- **The decryption key is a one-time bootstrap Secret** mounted into the
  repo-server. For now this is a **dedicated in-cluster age key — not the master
  (Ansible) key** — so the cluster can only decrypt what is encrypted to it, and
  the crown-jewel key never leaves the Mac. Secrets are encrypted to that cluster
  key *and* the master key (multi-recipient), so the Mac remains a break-glass
  decryptor.
- **Key management hardens to AWS KMS later.** Managed KMS (cluster gets a
  scoped, revocable, audited `kms:Decrypt` capability instead of holding a key)
  is the intended end state, deferred to get Keycloak running first. It will get
  its own ADR when implemented; migration is a `sops updatekeys` recipient swap.

## Consequences

**Positive**

- Secrets are "just another kustomize resource" — declarative and git-native; the
  encrypted file is the desired state, same as the rest of the lab.
- Teaches **kustomize generators + KRM/exec plugins** — transferable knowledge,
  and kustomize is worth knowing regardless.
- **Small blast radius**: KSOPS touches only the secrets Application; the Keycloak
  workload itself is the bitnami Helm chart, and other apps stay plain manifests.
- Keeps SOPS + age (portable key, readable diffs) — the reasons it was chosen.

**Negative / trade-offs**

- **Introduces kustomize**, against ADR-0008's plain-manifest default — accepted
  because it is scoped to secrets and clearly documented here.
- **Setup fiddliness**: the `ksops`/`kustomize` binary versions in the init
  container are the classic time-sink.
- **Upgrade fragility**: the alpha exec-plugin mechanism is a moving target;
  since ArgoCD self-upgrades via Git ([ADR-0003](0003-argocd-only-gitops-helmfile-dropped.md)),
  a future bump may need a fixup. The CMP fallback is cleaner here.
- **A decryption secret now lives in the cluster** (the age key today, an AWS
  credential once on KMS). Mitigated by scoping the key to this cluster and by
  the planned move to a revocable/audited KMS capability.

**Alternatives considered**

- *CMP sidecar running `sops -d`* — keeps plain manifests (no kustomize),
  lower-maintenance, more decoupled from ArgoCD internals. Rejected for now
  because we want the kustomize/KSOPS learning; kept as the clean fallback if the
  KSOPS version-wrangling becomes annoying.
- *argocd-vault-plugin* — placeholder substitution; more machinery than one age
  key and a handful of secrets warrant. Revisit only alongside a real backend.
- *Sealed Secrets / External Secrets Operator* — a different topology already
  rejected by the SOPS + age decision (cluster-bound key / requires a backend).
