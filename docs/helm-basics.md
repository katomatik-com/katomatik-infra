# Helm basics — a hands-on walkthrough

A guided, **throwaway** exercise to understand what Helm actually does before we
codify anything. You install a small real chart, look at what landed in the
cluster, exercise the upgrade/rollback lifecycle, then remove it — leaving no
trace. Nothing here is committed as cluster state; it's purely to learn.

- **Chart used:** [`podinfo`](https://github.com/stefanprodan/podinfo) — a tiny
  Go web app, arm64-friendly, and the canonical GitOps demo (you'll meet it
  again with ArgoCD).
- **Namespace:** everything goes in a `helm-demo` namespace so cleanup is one
  command.

> **Mental model.** Helm is the *package manager for Kubernetes*. A **chart** is
> a bundle of templated Kubernetes manifests + default **values**. `helm install`
> merges values → renders the templates to plain YAML → applies it to the
> cluster → records a versioned **release**. Helm (v3 and v4) is client-side
> only: the CLI runs on your Mac and talks to the API with your kubeconfig;
> nothing extra runs in the cluster. This lab uses Helm v4.

---

## Part 0 — Prerequisites

- A working cluster (the k3s phase) and the kubeconfig fetched to your Mac.
- **Point every command at the homelab cluster.** This kubeconfig is separate
  from your default `~/.kube/config`, so export it for this shell session:

```sh
export KUBECONFIG=~/.kube/homelab.config
kubectl get nodes            # sanity check: homelab should be Ready
```

Helm reads the same `KUBECONFIG` env var and current context, so once this is
exported, both `kubectl` and `helm` talk to the right cluster.

### Install Helm (control node only)

```sh
brew install helm
# Alternative: curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version                 # confirm it runs
```

---

## Part 1 — Find and inspect a chart (nothing touches the cluster yet)

A **repository** is a hosted index of charts. Add podinfo's and refresh:

```sh
helm repo add podinfo https://stefanprodan.github.io/podinfo
helm repo update
helm search repo podinfo     # lists the chart + its version
```

Look at the chart before installing anything — a good habit:

```sh
helm show chart  podinfo/podinfo    # metadata (Chart.yaml): name, version, appVersion
helm show values podinfo/podinfo    # the DEFAULT values you can override
```

> Everything above is read-only and local. `helm show values` is the menu of
> knobs a chart exposes — `replicaCount`, `ui.message`, `ingress.enabled`, etc.

---

## Part 2 — Render without installing (`helm template`)

This is the single most useful learning command. It runs steps 1–2 of an install
(merge values, render templates) and **stops before touching the cluster** —
it just prints the final Kubernetes YAML:

```sh
helm template demo podinfo/podinfo --namespace helm-demo | less
```

Scroll through it: you'll see a `ServiceAccount`, a `Service`, and a
`Deployment`, all fully rendered — no `{{ }}` left. This is *exactly* what
`helm install` would apply. Try overriding a value and watch the output change:

```sh
helm template demo podinfo/podinfo --set replicaCount=3 | grep -A2 'replicas:'
```

---

## Part 3 — Install for real (the throwaway)

Now apply it. `--create-namespace` makes the `helm-demo` namespace on the fly:

```sh
helm install demo podinfo/podinfo \
  --namespace helm-demo --create-namespace

helm list --namespace helm-demo           # your release, revision 1, deployed
kubectl get all --namespace helm-demo      # the objects Helm created
```

You should see a `deployment.apps/demo-podinfo`, a `replicaset`, a running
`pod`, and a `service/demo-podinfo` (named `<release>-<chart>`).

### Where Helm keeps its records

The thing that makes Helm more than "kubectl apply" is the **release record** —
a Secret in the namespace describing exactly what it installed:

```sh
kubectl get secret --namespace helm-demo -l owner=helm
# NAME: sh.helm.release.v1.demo.v1   TYPE: helm.sh/release.v1
```

That's how `helm history`, `helm upgrade`, `helm rollback`, and `helm uninstall`
know what they manage. Confirm the history:

```sh
helm history demo --namespace helm-demo    # revision 1, status deployed
```

---

## Part 4 — See it actually serve

`podinfo` listens on port 9898. There's no ingress yet, so forward the Service
port to your Mac (this command blocks — open a second terminal, or background it):

```sh
kubectl --namespace helm-demo port-forward svc/demo-podinfo 9898:9898
# in another terminal:
curl -s localhost:9898 | head       # JSON greeting from podinfo
# or open http://localhost:9898 in a browser for its UI
```

Stop the port-forward with Ctrl-C when done.

---

## Part 5 — The lifecycle: upgrade and rollback

This is why releases are versioned. Change a value and upgrade — it becomes
**revision 2**, not a fresh install:

```sh
helm upgrade demo podinfo/podinfo \
  --namespace helm-demo --set replicaCount=2

helm history demo --namespace helm-demo     # now shows revisions 1 and 2
kubectl get pods --namespace helm-demo       # two podinfo pods now
```

Changed your mind? Roll back to revision 1 (which itself records as a *new*
revision 3 — Helm never rewrites history):

```sh
helm rollback demo 1 --namespace helm-demo
helm history demo --namespace helm-demo
kubectl get pods --namespace helm-demo       # back to one pod
```

---

## Part 6 — Clean up (leave no trace)

```sh
helm uninstall demo --namespace helm-demo    # removes the release + its objects
kubectl delete namespace helm-demo           # remove the (now empty) namespace
helm list --namespace helm-demo              # empty — gone
```

---

## What this means for our GitOps setup

You just ran the full Helm lifecycle **by hand** to understand it. In the real
lab we **won't** `helm install` manually — that would be a second source of
truth competing with Git (the same boundary rule we kept for Ansible vs the
cluster). Instead:

- The **committed artifacts** — a chart reference and a `values.yaml` (soon a
  `helmfile.yaml`) — are the source of truth.
- **ArgoCD** runs the render-and-apply from Git for us.
- `helm template` and `helm install --dry-run` stay in the toolbox as
  **learning / validation** aids that never touch the cluster.

Next: **Helmfile**, which declares a *set* of Helm releases (repos + charts +
values) in one file — the "codify it" layer on top of what you just learned.
