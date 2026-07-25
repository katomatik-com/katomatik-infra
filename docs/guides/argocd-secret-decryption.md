# Secret decryption in GitOps — how ArgoCD turns encrypted Git into plaintext Secrets

A conceptual guide to *how* encrypted secrets in Git become running Kubernetes
`Secret`s, the options for doing it, and where the decryption key lives. This is
the background reading behind the decision in
[ADR-0012](../adr/0012-argocd-sops-decryption-ksops.md) (mechanism) and the
planned [ADR-0013](../adr/) (key management via AWS KMS). For the hands-on SOPS
setup, see [sops-age-setup.md](sops-age-setup.md).

## The core problem

Our Git repo is the source of truth, and it is **public**, so secrets in it must
be **encrypted at rest** (SOPS + age — see `CLAUDE.md`). But Kubernetes needs a
**plaintext** `Secret` object to run a pod. So something, somewhere, must turn
ciphertext → plaintext using the private key — and it must happen **before** the
manifest is applied to the cluster.

The entire decision reduces to one question: **where does that decryption step
live, and how is it wired in?**

## Where decryption must happen: the repo-server

ArgoCD has two relevant components:

- **argocd-repo-server** — clones the repo and *renders* it into final Kubernetes
  manifests (it runs `helm template`, `kustomize build`, or reads plain YAML).
  This is the "Git → manifests" factory.
- **argocd-application-controller** — takes the rendered manifests, diffs them
  against the live cluster, and applies the difference.

Decryption **must** happen inside the repo-server's rendering step — it is the
only point between "raw Git" and "applied to cluster". Every option below is just
a different way to hook a `sops -d` into the repo-server. That is the whole game.

> **Consequence to internalise:** to decrypt in the repo-server, a **decryption
> capability must live in the cluster** (a key, or a credential that can call a
> key service). Until this point our age key only existed on the Mac (Ansible
> decrypts host-side). This is a real, new exposure — see *Key management* below.

## The render-time decryptors (the "SOPS-in-Git" family)

All three keep encrypted files in Git and decrypt them as ArgoCD renders.

### KSOPS — a kustomize generator plugin
Kustomize can run "generators" that emit resources. KSOPS is a generator that,
given a config listing encrypted files, decrypts them into plaintext `Secret`s
during `kustomize build`.

Wiring: an **init container** installs `ksops` + `kustomize` into the repo-server;
enable `--enable-alpha-plugins --enable-exec`; mount the key; the secret app is a
`kustomization.yaml` with a `generators:` entry → a `ksops` config → the
`*.sops.yaml` files.

- **Character:** the secret is "just another kustomize resource" — declarative and
  git-native. Costs: it **requires kustomize**, the init-container binary versions
  are the classic time-sink, and the alpha-plugin flags can break across ArgoCD
  upgrades.

### CMP sidecar running `sops -d`
ArgoCD lets you register a **Config Management Plugin (CMP)** — your own renderer,
run as a **sidecar** on the repo-server. Its `generate` command runs `sops -d`
over plain manifests; whatever it prints to stdout becomes the rendered output.

Wiring: add a sidecar (image has `sops` + the key) via the argo-cd Helm values;
give it a small plugin spec; mark the secret app to use it.

- **Character:** **no kustomize** (plain manifests stay plain), transparent, and
  decoupled from ArgoCD internals so it tends to survive upgrades better. Cost:
  you own the plugin glue and the sidecar image.

### argocd-vault-plugin (AVP)
A different model — **placeholder substitution**. You leave markers like
`<path:secret/foo#key>` in manifests; AVP fetches real values from a **backend**
(Vault, cloud secret managers, or SOPS) and substitutes them.

- **Character:** powerful with a real backend, multi-backend — but more machinery
  than one key and a handful of secrets warrant.

| | **KSOPS** | **CMP sidecar (`sops -d`)** | **AVP** |
|---|---|---|---|
| Mechanism | kustomize generator | your own renderer sidecar | placeholder substitution |
| Needs kustomize? | **Yes** | No — plain manifests | No |
| Key/creds in cluster? | Yes | Yes | Yes (if SOPS backend) |
| Wiring | init container + alpha-plugin flags | sidecar + plugin spec | sidecar + backend config |
| Upgrade fragility | Higher (alpha plugins) | Lower (just a container) | Medium |
| Learning | kustomize + KRM plugins | ArgoCD's native plugin API | secret backends / Vault |
| Best when | you want kustomize anyway | you want minimal, durable glue | you have a real backend |

## A different school: decrypt in-cluster / never-in-Git

The three above are the "decrypt at render time" family. Two well-known
alternatives use a *different topology*, which is why they need no key in the
repo-server:

- **Sealed Secrets** — an in-cluster controller holds its *own* keypair; you
  encrypt with `kubeseal` (public key only) → commit a `SealedSecret` CRD → the
  controller decrypts it inside the cluster. No key you place; but the key is
  **cluster-bound** (backup/DR = backing up that controller's key; can't decrypt
  outside the cluster; not portable).
- **External Secrets Operator** — the value isn't in Git at all; an operator syncs
  it from an external store (Vault, cloud secret manager). Needs a backend to run.

Knowing these exist clarifies our own choice: we picked SOPS + age precisely
because the encrypted values live in Git (readable diffs) and the key is portable
(a file we own), not bound to a cluster or a backend service.

## Key management: what actually holds the key

The uncomfortable part of the render-time family is that a decryption capability
now lives in the cluster. First, **calibrate the risk**: the cluster *already*
holds plaintext secrets — every applied `Secret` sits decrypted in **etcd**. What
a key *adds* is the ability to decrypt **everything else that key protects in Git**
(other apps, history). So the fix is about **scoping the key**, not avoiding keys.

What people do, roughly in order of strength:

1. **Cloud KMS (the production standard).** SOPS can wrap the data key with AWS/GCP/
   Azure KMS instead of a raw key. The cluster is granted *permission to call KMS
   to decrypt* — the key material **never leaves the KMS/HSM**. In-AWS this needs
   no static creds (IRSA); **off-AWS** (like this homelab) the cluster still needs
   an AWS credential, but that credential is **revocable, audited (CloudTrail),
   network-gated, and least-privilege** — a far better secret than the key itself.
2. **A dedicated per-cluster key + multi-recipient.** Generate a *separate* key for
   the cluster; encrypt each secret to **both** your offline master key *and* the
   cluster key. Only the cluster key goes in-cluster, so it can decrypt only that
   cluster's secrets, and the master never leaves your machine. Rotating a leaked
   cluster key is `sops updatekeys`.
3. **Sealed Secrets** — the cluster makes and guards its own key; you never place
   one. Strongest on "no key handed over," at the cost of portability (above).
4. **External Secrets Operator / Vault** — the value never enters Git; the "key"
   becomes an auth credential to the store.

### KMS vs Vault — not the same thing
- **KMS** is a **key custodian + crypto service**: it guards *keys* and performs
  encrypt/decrypt via API. It does **not** store your secrets — in SOPS it only
  wraps the little data key; your secrets stay (encrypted) in Git.
- **Vault** is a whole **secrets platform**: it can *store secret values*, issue
  *dynamic short-lived credentials*, do PKI, and — via its **Transit** engine —
  offer KMS-like encryption. So Vault ⊇ KMS-like function, plus much more, but it
  is a server to operate (or a paid managed tier). `CLAUDE.md` rejected Vault as
  *too heavy for one node*; KMS is the right-sized tool for the one job here.

## What this homelab chose

- **Mechanism: KSOPS**, scoped to secret Applications only — a deliberate,
  documented exception to the plain-manifests default
  ([ADR-0008](../adr/0008-app-delivery-plain-manifests-and-apex-routing.md)),
  chosen for the kustomize/KSOPS learning. Full reasoning:
  [ADR-0012](../adr/0012-argocd-sops-decryption-ksops.md).
- **Key management: interim → target.** For now a **dedicated in-cluster age key**
  (not the master), with secrets encrypted to it *and* the master (break-glass).
  The target is **AWS KMS** (option 1 above), deferred to get Keycloak running
  first; migration is a `sops updatekeys` recipient swap. To be written up as
  ADR-0013 when implemented.
