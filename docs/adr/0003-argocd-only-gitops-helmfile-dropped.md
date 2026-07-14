# ADR-0003: GitOps reconciler — ArgoCD only (app-of-apps), Helmfile dropped

## Status

Accepted — 2026-07-14.

## Context

The original stack listed **both** Helmfile and ArgoCD ("Helm + Helmfile" for
packaging/deployment, ArgoCD for GitOps). On closer look these overlap: both
reconcile a set of Helm releases to a declared state. Running both means two
controllers answering the same question — the two-sources-of-truth trap this
project has avoided everywhere else (Ansible stops at the cluster boundary in
[ADR-0001](0001-k3s-single-node-custom-ansible-role.md); the Cloudflare Tunnel
keeps routing in Git in [ADR-0002](0002-cloudflare-tunnel-host-daemon-to-traefik.md)).

How production GitOps actually runs, for the ArgoCD world:

- **One in-cluster reconciler** — ArgoCD — watches Git and self-heals drift.
- **Helm doesn't disappear**; it becomes ArgoCD's *rendering engine*. ArgoCD
  reads Helm charts + values natively, so you never run `helm install` and you
  don't need Helmfile to orchestrate releases.
- **The chicken-and-egg** (ArgoCD cannot GitOps-install itself) is solved by a
  **single one-time bootstrap**, then the **app-of-apps** pattern takes over —
  a root `Application` points at a Git folder of more `Application`s, and ArgoCD
  manages everything from there, *including its own upgrades*.

Helmfile's genuine niche is the **push / "CIOps"** model — no in-cluster agent,
CI runs `helmfile apply`. That is an **alternative to** ArgoCD, not a companion
to it. The project's goal is to *understand* the tools, which is not served by
cargo-culting a redundant pairing.

## Decision

**Use ArgoCD as the sole in-cluster GitOps reconciler.** Specifically:

- **Helm stays as the chart/packaging format**; ArgoCD renders charts. We do
  **not** run `helm install` for the running lab, and we do **not** use Helmfile
  in the critical path.
- **Adopt app-of-apps.** A root `Application` (committed to Git) points at a
  directory of `Application`s; ArgoCD reconciles all of them — Traefik
  replacement, Prometheus, Keycloak, apps — and an `Application` for ArgoCD
  itself makes its upgrades GitOps too.
- **One documented bootstrap**, run by hand from the Mac (Ansible stays at the
  cluster boundary, per ADR-0001).
- **Helmfile is dropped from the critical path.** If we learn it, it will be a
  self-contained side-exercise clearly labelled "alternative approach, not part
  of the running lab" — mirroring `docs/helm-basics.md`.

### The bootstrap in practice — the "run once"

All from the Mac, with `export KUBECONFIG=~/.kube/homelab.config`:

```sh
# 1. Add the Argo Helm repo and PIN the chart version (same discipline as k3s).
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm search repo argo/argo-cd --versions | head    # pick + pin a version

# 2. Install ArgoCD once. This is the single imperative step.
helm install argo-cd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version <pinned-version> \
  -f argocd/values.yaml                             # committed values file

# 3. Grab the initial admin password (stored in a Secret by the chart).
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Then **commit the app-of-apps root `Application`**, which includes an
`Application` that manages `argo-cd` from the same chart + values in Git. After
the first sync, ArgoCD owns its own lifecycle and step 2 is never repeated.

Version pinning: don't hardcode a version in this ADR — find and pin the current
chart at bootstrap time via `helm search repo argo/argo-cd --versions`.

## Consequences

**Positive**

- **Single source of truth** per component; no competing reconcilers.
- **Simpler** than Helmfile + ArgoCD, and **faithful to real production** —
  this is the mainstream ArgoCD pattern, so the learning transfers.
- You still learn Helm (as ArgoCD's engine) and the genuinely production-grade
  **app-of-apps** pattern; ArgoCD **self-manages** after bootstrap.
- The Ansible/cluster boundary from ADR-0001 is preserved — the bootstrap is a
  manual `helm`/`kubectl` step, not an Ansible task.

**Negative / trade-offs**

- **One imperative step outside GitOps** (the bootstrap). Unavoidable
  chicken-and-egg; minimised to a single documented command, then superseded by
  self-management.
- **Ownership hand-off nuance:** the bootstrap `helm install` creates a Helm
  release; once an ArgoCD `Application` reconciles the same objects, that
  original release metadata becomes vestigial (ArgoCD applies rendered
  manifests, it doesn't track Helm releases). Harmless, but worth knowing. An
  alternative bootstrap is `helm template … | kubectl apply` to avoid creating a
  Helm release at all.
- **We don't learn Helmfile as part of the lab** — mitigated by the optional
  side-exercise.

**Alternatives considered**

- *Helmfile bootstraps ArgoCD, ArgoCD owns apps* (the earlier proposal) —
  rejected: Helmfile-for-bootstrap is artificial and puts a redundant tool in
  the critical path.
- *Helmfile-only / CIOps, no ArgoCD* — rejected: gives up continuous
  reconciliation, drift detection, and the ArgoCD UI we want to learn.
- *Raw `kubectl apply -f install.yaml` bootstrap* — viable and simple; we prefer
  the Helm chart so the version is pinned and self-management reuses the same
  chart source.
