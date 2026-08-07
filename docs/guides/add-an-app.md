# Adding an app

How to put a new workload on the cluster and serve it at a public hostname —
end to end, GitOps all the way. The worked example is the lab's first app, the
static site at the apex **katomatik.com** (`manifests/katomatik-web/`), but the
shape is the same for any app. The *why* behind these choices is
[ADR-0008](../adr/0008-app-delivery-plain-manifests-and-apex-routing.md).

`manifests/kurtcebenl-web/` is the same pattern on a **second domain**
(`kurtcebe.nl`) — useful to diff against, and a fair warning that only the
Ingress host rules and the Terraform zone key actually differ
([ADR-0018](../adr/0018-second-domain-multi-zone-cloudflare.md)).

## The mental model

Two independent things have to line up for a request to reach your app:

```
                    Git (this repo)
                     │
   ┌─────────────────┼──────────────────────────┐
   │ 1. apps/<name>.yaml  → ArgoCD Application    │  what runs in the cluster
   │ 2. manifests/<name>/ → Deployment/Svc/Ingress│
   └─────────────────┼──────────────────────────┘
                     │
 Browser → Cloudflare (TLS) → Tunnel → cloudflared → Traefik :80 → Ingress → Service → Pod
                     │
   ┌─────────────────┴──────────────────────────┐
   │ 3. terraform/  → proxied CNAME per hostname  │  how the name reaches us
   └──────────────────────────────────────────────┘
```

- **In-cluster** (parts 1–2): ArgoCD's app-of-apps root scans `apps/`, so
  dropping an `Application` there deploys it; that Application points at plain
  manifests in `manifests/<name>/`.
- **Routing** (part 3): the tunnel is a single catch-all to Traefik. A new
  public hostname needs a proxied CNAME (Terraform) so DNS points at the tunnel;
  Traefik then matches the `Host` header to your `Ingress`. TLS is terminated at
  Cloudflare, so nothing in the cluster deals with certs.

The steps below build both halves.

## Prerequisites

- An image in a registry the cluster can pull. Public
  [GHCR](https://ghcr.io) needs no pull secret — make sure the package is set to
  **public** (Package settings → Change visibility). A private registry means an
  `imagePullSecret` (a SOPS-encrypted secret — out of scope here; prefer public
  for now).
- The image **tag pinned to an immutable reference** (a git commit hash or a
  digest), never `:latest`. GitOps means "what's deployed" is a line in Git.
- The image **must include a `linux/arm64` layer.** The node is an M1 / Asahi
  box (arm64), so an `amd64`-only image fails to pull with
  `no match for platform in manifest` — and containerd will **not** emulate it.
  Build multi-arch:

  ```sh
  docker buildx build --platform linux/amd64,linux/arm64 \
    -t ghcr.io/<org>/<image>:<sha> --push .
  ```

  Check what a tag actually ships with
  `docker manifest inspect <image>:<tag>` — you want a `linux/arm64` entry (an
  `unknown/unknown` line is just buildx's provenance attestation, ignore it).

## 1. Workload manifests — `manifests/<name>/`

Create a directory named for the app and drop in plain Kubernetes YAML. For
`katomatik-web` that's four files; the interesting bits:

**`deployment.yaml`** — the pods. Pin the exact image tag, name the container
port, and give it modest requests/limits. Health probes on a static site just
GET `/`:

```yaml
image: ghcr.io/katomatik-com/katomatik-web:f23db80   # commit hash, not :latest
ports:
  - name: http            # named — the Service targets this name, not the number
    containerPort: 8080
```

Leave `namespace:` **off** every manifest — the Application (step 2) sets it, so
these files stay portable.

**`service.yaml`** — a stable name/IP for the pods. Note the port hop: the
Service listens on `80` and forwards to the pod's named `http` port (`8080`):

```yaml
ports:
  - name: http
    port: 80
    targetPort: http      # the container's named port
```

**`ingress.yaml`** — the public entrypoint, matched on the `Host` header. No TLS
block (Cloudflare already terminated it):

```yaml
spec:
  ingressClassName: traefik
  rules:
    - host: katomatik.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: katomatik-web
                port:
                  number: 80    # the Service port
```

> **Apex vs subdomain in the Ingress:** the `host:` is just the hostname you want
> to serve — `katomatik.com`, `blog.katomatik.com`, whatever. The apex is only
> special at the DNS layer (step 3), not here.

## 2. The ArgoCD Application — `apps/<name>.yaml`

This is the object the app-of-apps root turns into a running app. It points at
the manifests dir from step 1 and picks the namespace:

```yaml
spec:
  source:
    repoURL: https://github.com/katomatik-com/katomatik-infra.git
    targetRevision: main
    path: manifests/katomatik-web
  destination:
    server: https://kubernetes.default.svc
    namespace: katomatik-web        # one namespace per app
  syncPolicy:
    automated: { selfHeal: true, prune: true }
    syncOptions:
      - CreateNamespace=true         # makes the namespace on first sync
```

It goes in `apps/` (scanned by the root), never in `manifests/`. See the full
file at [`apps/katomatik-web.yaml`](../../apps/katomatik-web.yaml).

## 3. DNS — a proxied CNAME (Terraform)

The hostname has to resolve to the tunnel. That's a proxied CNAME to
`<tunnel-id>.cfargotunnel.com`, managed in `terraform/`:

The lab serves more than one domain, so records live in a `zones` map keyed by
apex (ADR-0018) — first decide which domain the hostname belongs to.

- **A subdomain** — add its label to that zone's `hostnames` list in
  `terraform/terraform.tfvars`. The `cloudflare_dns_record.subdomain` `for_each`
  creates one record per (zone, label) pair:

  ```hcl
  zones = {
    "katomatik.com" = { hostnames = ["argocd", "www", "auth", "authdemo"] }
    "kurtcebe.nl"   = { hostnames = ["www"] }
  }
  ```

- **The apex** — DNS forbids a real CNAME at a zone apex, so it can't ride the
  subdomain `for_each`. `cloudflare_dns_record.apex` in
  `terraform/cloudflare.tf` handles it with Cloudflare's **CNAME flattening**,
  one record per zone, created automatically. Never list an apex under
  `hostnames`.

- **A whole new domain** — add a top-level key. The zone, its apex record and
  its subdomains all follow, and the **existing tunnel is reused** (a
  `cfargotunnel.com` CNAME resolves for any zone in the same Cloudflare
  account). The only extra step is delegating that domain's nameservers at its
  registrar — see [Terraform — Cloudflare](terraform-cloudflare.md), which also
  covers how to verify a delegation without fooling yourself.

> **Adding a key is free; renaming or removing one is not.** The apex key and
> the subdomain labels build the Terraform resource addresses, so changing an
> existing one plans a destroy + create of live DNS. A rename needs a `moved`
> block (`terraform/moved.tf` has worked examples).

Apply from the `terraform/` dir (runs in HCP):

```sh
cd terraform && terraform plan && terraform apply
```

## 4. Canonical redirect (optional) — `www` → apex

If you want `www` to redirect to the apex instead of serving a duplicate site,
add a Traefik `Middleware` + a `www` `Ingress` (see
[`manifests/katomatik-web/www-redirect.yaml`](../../manifests/katomatik-web/www-redirect.yaml)).
The Middleware rewrites the URL and 301s; the `www` Ingress attaches it via an
annotation:

```yaml
annotations:
  traefik.ingress.kubernetes.io/router.middlewares: katomatik-web-www-to-apex@kubernetescrd
```

The annotation value is `<namespace>-<middleware-name>@kubernetescrd`. `www`
still needs its own CNAME (step 3) so the request can reach Traefik to be
redirected.

## 5. Deploy = commit + push

There is no `kubectl apply`. Once the files are committed and pushed:

- ArgoCD's root notices the new `Application` in `apps/` and syncs it —
  namespace, Deployment, Service, Ingress all appear.
- Terraform's CNAME (once applied) makes the hostname resolve to the tunnel.

## 6. Verify

```sh
export KUBECONFIG=~/.kube/homelab.config

# The app synced and is Healthy?
kubectl -n argocd get applications
kubectl -n katomatik-web get deploy,svc,ingress,pods

# DNS resolves (proxied → you'll see Cloudflare IPs, that's expected):
dig +short katomatik.com

# End to end:
curl -I https://katomatik.com
curl -I https://www.katomatik.com     # expect: 301 → https://katomatik.com
```

## Troubleshooting

- **App stuck `Missing`/`OutOfSync`** — the root only picks up files in `apps/`.
  Confirm the `Application` is there (not in `manifests/`) and pushed.
- **Pods `ImagePullBackOff`** — the GHCR package is still private, or the tag
  doesn't exist. Flip the package to public, or fix the tag.
- **`ErrImagePull: no match for platform in manifest`** — the image has no
  `linux/arm64` layer (see prerequisites). Rebuild multi-arch; emulation is not
  an option on this node.
- **`404 page not found` from Traefik** — the `Host` in the Ingress doesn't
  match the hostname you requested, or the CNAME isn't applied yet.
- **`www` doesn't redirect** — the middleware annotation namespace prefix must
  match `destination.namespace`, and `www` needs its own CNAME.

## Shipping a new build

Tags are immutable, so a new build = a new tag. That single line in
`manifests/<name>/deployment.yaml` is the whole record of what's live, and
**Renovate raises the bump as a PR** — merge it and ArgoCD rolls it out
([ADR-0019](../adr/0019-renovate-self-hosted-dependency-updates.md)). Editing
the tag by hand still works and is the fallback.

For that to happen, the app's CI must publish an **orderable** tag:

```yaml
# in the app repo's docker/metadata-action step
tags: |
  type=raw,value={{date 'YYYYMMDD'}}.{{date 'HHmmss'}}-{{sha}}
```

A bare git SHA cannot be compared — Renovate can't tell `f23db80` from
`be6ef2d`, so it proposes nothing and looks broken rather than erroring. The
timestamp gives ordering, the trailing SHA keeps the commit readable, and
seconds matter because two builds in one day would otherwise tie.

A new app also needs its image added to the `matchPackageNames` list in
[`renovate.json5`](../../renovate.json5), or Renovate will extract it but
compare it with default versioning and never propose an upgrade.

## Checklist

- [ ] Image pushed, tag pinned (not `:latest`), package public
- [ ] App CI publishes an orderable `<date>.<time>-<sha>` tag, and the image is
      listed in `renovate.json5` so bumps are automated
- [ ] `manifests/<name>/` — Deployment, Service, Ingress (no `namespace:`)
- [ ] `apps/<name>.yaml` — Application → that path, `destination.namespace` set
- [ ] `terraform/terraform.tfvars` — hostname added under the right zone in
      `zones` (each zone's apex record is automatic; a *new* domain also needs
      registrar delegation)
- [ ] (optional) `www` redirect middleware
- [ ] `terraform apply`, then commit + push
- [ ] Verified: `kubectl get`, `dig`, `curl -I`
