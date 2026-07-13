# ADR-0001: Provision single-node k3s via a custom Ansible role

## Status

Accepted — 2026-07-13.

## Context

The homelab needs a Kubernetes cluster to host the rest of the stack
(ArgoCD, Prometheus/Grafana, Keycloak, own apps). The hardware is a single
M1 MacBook (16 GB RAM, ~165 GB allocated) running Fedora Asahi Remix,
headless, on WiFi — one node, ARM64, resource-constrained. The overriding
project goal is *understanding* the tools, not just getting them running.

Several choices had to be settled to start this phase:

- **Which distribution.** Full upstream Kubernetes (kubeadm) is heavy and
  multi-process; k3s is a single ~70 MB binary that bundles the control
  plane, kubelet, containerd, CNI, DNS, an ingress controller, a bare-metal
  load balancer, and a storage provisioner, with first-class ARM64 builds.
  For a single learning node, k3s fits.
- **How to install it.** Options were the community `k3s-ansible` role, our
  own small role, or manual `curl | sh`. A community role hides the moving
  parts behind someone else's abstraction; manual install isn't
  reproducible. The base OS role was hand-written on the same
  "understand it, then codify it" principle.
- **Where Ansible's responsibility ends.** Ansible manages the host;
  Kubernetes manages what runs inside the cluster. Blurring that line
  (e.g. `kubectl apply` from a playbook) creates two competing sources of
  truth and undermines the later GitOps model.
- **What to do with k3s's bundled batteries** — Traefik (ingress),
  ServiceLB, local-path storage, CoreDNS, metrics-server — keep the
  defaults or replace them now.

## Decision

**Install single-node k3s with our own small `k3s` Ansible role**, not the
community role. The role:

- downloads and installs a **pinned** k3s version (no floating `latest`);
- configures k3s declaratively via `/etc/rancher/k3s/config.yaml` (a
  templated file) rather than shell env strings;
- passes `--tls-san <server-ip/hostname>` so the API certificate is valid
  for remote `kubectl`, and `--write-kubeconfig-mode 0644` so the kubeconfig
  is fetchable without root;
- manages the `k3s.service` systemd unit;
- opens the firewalld rules that cluster networking needs (API `6443/tcp`,
  and the flannel pod/service CIDRs `10.42.0.0/16` and `10.43.0.0/16`);
- fetches the kubeconfig (`/etc/rancher/k3s/k3s.yaml`) back to the Mac and
  rewrites its `server:` field to the node's address.

**Ansible's responsibility stops at the cluster boundary.** Ansible installs
k3s, manages its service, configures host networking/firewall, and retrieves
the kubeconfig. Everything *inside* Kubernetes — Traefik config, ArgoCD,
Prometheus, Keycloak, apps — is Helm/Helmfile + ArgoCD. No `kubectl apply`
from Ansible.

**Keep k3s's bundled components for now**, including **Traefik as the ingress
controller** on the standard `Ingress` API model, exposed on host ports
80/443 by the bundled ServiceLB. The single node uses the **embedded SQLite**
datastore (etcd is only for HA).

## Consequences

**Positive**

- Every piece of the install is understood and version-controlled;
  reproducible and a transferable skill.
- No premature complexity: a working cluster *and* a working ingress on day
  one, so the whole chain (up through ArgoCD and the tunnel) can be
  validated end to end.
- One clear source of truth per layer — host state in Ansible, cluster state
  in Git/ArgoCD.

**Negative / trade-offs**

- A hand-rolled role is more to write and maintain than adopting the
  community role.
- SQLite is not highly available and is a single-file backup concern
  (`/var/lib/rancher/k3s/server/db/`).
- Bundled Traefik is configured *by k3s* and speaks the older `Ingress` API;
  we trade control for a fast start.
- firewalld must be explicitly taught the cluster CIDRs, or pod-to-pod and
  pod-to-DNS traffic silently breaks — a classic k3s + firewalld trap.
- `--write-kubeconfig-mode 0644` is a mild secret exposure on a shared host.
  Acceptable as a **learning simplification** on a solo box; noted, not
  production practice.

**Planned future direction (each will get its own ADR when we do it)**

- Replace bundled Traefik with a **Helm-managed Traefik** deployed the
  GitOps way.
- Migrate ingress from the `Ingress` API to the **Gateway API**.

These are deliberate later exercises with a working reference to compare
against — explicitly *not* part of this initial bring-up.
