# ADR-0002: Expose services via a host-daemon Cloudflare Tunnel pointed at Traefik

## Status

Accepted — 2026-07-13. **Implementation deferred** to the Cloudflare Tunnel
phase (two phases after k3s); the topology is decided now so the k3s and
ingress work slots into it without rework.

## Context

The homelab has no usable inbound path from the internet: it sits behind a
residential KPN Box on WiFi, with no static public IP and no desire to open
inbound ports on the home router. **Cloudflare Tunnel** solves this — the
`cloudflared` daemon makes an *outbound* connection to Cloudflare's edge, and
public traffic flows back down that tunnel. No inbound ports, no public IP.

Cloudflare's **documented Kubernetes model** (their deployment guide) is:

- run `cloudflared` as an **in-cluster Deployment**, adjacent to the apps,
  with 2+ replicas for high availability (they warn against autoscaling, and
  note cloudflared does *not* load-balance across replicas — replicas are
  strictly for HA);
- have the tunnel forward **directly to Kubernetes Services**
  (`http://my-service`), **bypassing any ingress controller**;
- their example configures routing in the **Cloudflare dashboard**
  (remotely-managed tunnel), so hostname→service mapping lives at Cloudflare,
  not in Git.

That model optimizes for "expose one app quickly." It conflicts with this
project's goals: routing should be **declarative in Git** (GitOps), ingress
is an explicit **learning objective** (Traefik is a first-class stack
component, with an `Ingress → Gateway API` arc planned), the host firewall
should stay locked down, and we want to avoid a bootstrap circular dependency
where reaching the ArgoCD UI depends on ArgoCD having already deployed the
tunnel.

## Decision

**Run `cloudflared` as a host `systemd` service** (managed by Ansible, its
token stored via SOPS + age), **not** as an in-cluster workload.

**Point the tunnel at Traefik over loopback.** k3s's bundled ServiceLB binds
Traefik to host ports 80/443, so `cloudflared` targets `http://localhost:80`.
The tunnel config carries a **single catch-all rule** (`*.<domain> →
http://localhost:80`); `cloudflared` knows nothing except "send everything to
Traefik."

**Keep all per-app routing inside Kubernetes.** Host/path routing lives in
`Ingress` (later `HTTPRoute`) resources in Git, managed by ArgoCD. Adding or
changing an app's public route is a Git change to a Kubernetes manifest, never
a change to the tunnel.

This **deliberately deviates** from Cloudflare's direct-to-Service, in-cluster
recommendation.

## Consequences

**Positive**

- **Routing stays in Git.** The part that changes often (per-app routes) is
  declarative and ArgoCD-managed; the tunnel is set-once.
- **firewalld stays fully closed.** `cloudflared` reaches Traefik over
  loopback and Cloudflare over an outbound connection, so no inbound 80/443
  is ever opened — the host keeps only SSH and the API port exposed.
- **The tunnel is decoupled from cluster lifecycle.** It runs like any other
  host service (sshd, chrony); restarting k3s doesn't disturb it.
- **No bootstrap circular dependency.** Because the tunnel exists
  independently of cluster state, the ArgoCD UI is reachable through it the
  moment ArgoCD is running.
- **Simple for a single node** — one replica is sufficient; the in-cluster
  HA/replica machinery isn't needed.

**Negative / trade-offs**

- **Two infrastructure management planes.** The tunnel daemon and its
  credential live on the host (Ansible/SOPS), outside ArgoCD's control. The
  split is limited to the daemon itself — routing still lives in Git.
- **Off Cloudflare's documented happy path**, so their Kubernetes examples
  don't map one-to-one.
- **Implicit dependency on ServiceLB's hostPort binding.** The
  `localhost:80` target assumes Traefik is exposed that way; changing
  Traefik's Service type would require re-pointing the tunnel.
- The tunnel credential is a host-file secret rather than a Kubernetes
  Secret.

**Alternatives considered**

- *In-cluster Deployment → Service directly* (Cloudflare's recommendation) —
  rejected: routing leaves Git, no ingress learning, and it couples external
  access to the cluster's own bootstrap.
- *In-cluster Deployment → Traefik* — a viable, more orthodox-GitOps variant
  (everything under ArgoCD). Deferred as a possible **later migration
  exercise** once the lab is stable.
