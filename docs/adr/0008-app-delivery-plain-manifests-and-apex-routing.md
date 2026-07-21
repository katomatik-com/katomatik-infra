# ADR-0008: App delivery — plain manifests per app, apex + www routing

## Status

Accepted — 2026-07-21.

## Context

The lab's first real workload — the static site at the apex `katomatik.com` —
needs a home in the repo. The app-of-apps pattern is already in place
([ADR-0003](0003-argocd-only-gitops-helmfile-dropped.md)): the root `Application`
scans `apps/` and turns each `Application` manifest there into a running
component. But so far the only child is ArgoCD itself, which pulls a *remote*
Helm chart. There is no convention yet for **our own** workloads:

- **Where do a workload's manifests live**, and how is packaged?
  Options: plain Kubernetes YAML, a small in-repo Helm chart, or Kustomize.
- **How does a public hostname get wired**, including the apex — which is a
  special DNS case — and the `www` canonical redirect?

Routing constraints are already fixed by earlier decisions: the Cloudflare
Tunnel is a single catch-all to Traefik, and per-hostname routing is done by
Kubernetes `Ingress` behind Traefik
([ADR-0002](0002-cloudflare-tunnel-host-daemon-to-traefik.md)); the
Cloudflare/Terraform layer is kept deliberately thin
([ADR-0005](0005-terraform-for-cloudflare-external-layer.md)). This ADR fills in
the app-shaped gap between "ArgoCD exists" and "an app is serving traffic".

## Decision

**Each app is one ArgoCD `Application` in `apps/<name>.yaml` whose source is a
directory of plain Kubernetes manifests at `manifests/<name>/`.** Concretely:

- **Plain manifests, not a chart.** A static site is a `Deployment` + `Service`
  + `Ingress` with no values to parameterise. Plain YAML gives the most readable
  diffs and no templating indirection — the right altitude for the learning goal
  and for one app. Helm stays reserved for third-party charts (ArgoCD, later
  Prometheus/Keycloak) where we consume someone else's template.
- **One namespace per app**, set once via the `Application`'s
  `destination.namespace` + `CreateNamespace=true`. The manifests carry no
  `namespace:` field, so they stay portable and the name lives in one place.
- **`apps/` vs `manifests/`.** The child `Application` lives in `apps/` (so the
  root's directory scan picks it up); the workload YAML lives in `manifests/`
  (which the root does **not** scan, so app resources are never mistaken for
  `Application`s).
- **Image tags are immutable and committed.** Pin the exact tag (here a git
  commit hash, `dfe8989`) in the manifest — never a floating `:latest`.
  Deploying a new build is "bump the tag, push"; ArgoCD does the rest.
- **Public hostname wiring:** a proxied CNAME per host in Terraform — subdomains
  via the `hostnames` list, the **apex** via a dedicated `cloudflare_dns_record`
  using Cloudflare's **CNAME flattening** (DNS forbids a real apex CNAME). In
  the cluster, one `Ingress` per host, matched on the `Host` header behind
  Traefik.
- **Canonical host in-cluster.** Serve the apex; redirect `www` → apex with a
  Traefik `RedirectRegex` **Middleware** attached to a `www` `Ingress`, rather
  than a Cloudflare edge redirect — keeping routing behind Traefik per ADR-0002
  and the external layer thin.

## Consequences

**Positive**

- A consistent, minimal per-app footprint: `apps/<name>.yaml` +
  `manifests/<name>/`. Adding an app is a copy-and-edit, documented in
  `docs/guides/add-an-app.md`.
- Readable diffs and no values indirection; the manifests *are* the desired
  state.
- Teaches the core Kubernetes objects (`Deployment`/`Service`/`Ingress`) and a
  Traefik CRD (`Middleware`) directly, not hidden behind a chart.
- The Cloudflare/Terraform layer stays thin — it only ever grows a CNAME.

**Negative / trade-offs**

- **No templating or DRY across apps.** Two near-identical apps mean duplicated
  YAML. Acceptable at one app; revisit Helm or Kustomize when a second similar
  app actually appears.
- **Manual image bumps.** Tags are edited by hand and pushed; no image
  automation. A future Argo CD Image Updater could watch the registry — out of
  scope now.
- **Redirect at the origin**, not the edge: a `www` request makes the full trip
  to Traefik before the 301. Negligible for a canonical redirect, and it keeps
  routing in one place.

**Alternatives considered**

- *In-repo Helm chart per app* — rejected: premature machinery (a chart, values,
  a `_helpers.tpl`) for a single static site with nothing to parameterise.
- *Kustomize base/overlays* — rejected: a third templating tool to learn with no
  variation to model yet. Reconsider if per-environment overlays ever appear.
- *Cloudflare Redirect Rule for `www`* — rejected: thickens the deliberately-thin
  external layer and moves routing out of the cluster, against ADR-0002.
