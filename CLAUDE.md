# CLAUDE.md — Homelab Project

## Project goal
Learning DevOps, Kubernetes, and GitOps by building a real home lab
server. The goal is understanding the tools, not just getting things
running.

## Hardware
- M1 MacBook (16 GB RAM, 165 GB allocated to Linux)
- Dual-boot: Fedora Asahi Remix (headless) + macOS
- Networking: KPN Box 12, WiFi (ethernet not available yet)
- Target static IP: 192.168.2.10 (to be set via DHCP reservation on
  KPN Box 12, or via NetworkManager on the server)

## Full stack
- OS: Fedora Asahi Remix (headless, server variant)
- Config management: Ansible (OS-level setup)
- IaC / external cloud: Terraform (Cloudflare zone, tunnel, DNS) — see ADR-0005
- Kubernetes: k3s (single node)
- Package deployment: Helm (chart format; rendered by ArgoCD, not run by hand)
- GitOps: ArgoCD only, via app-of-apps (watches Git, manages cluster state,
  self-manages after a one-time bootstrap). Helmfile dropped — see ADR-0003.
- Secrets: SOPS + age (encrypted in Git, decrypted by ArgoCD plugin)
- Ingress: Traefik (bundled with k3s)
- Tunnel: Cloudflare Tunnel (cloudflared as systemd service)
- Observability: Prometheus + Grafana
- Auth: Keycloak + PostgreSQL
- Apps: my own web applications

## Repo structure
homelab/
├── ansible/
│   ├── inventory/hosts.ini
│   ├── group_vars/all.yml
│   ├── roles/base/{tasks,handlers}/main.yml
│   └── site.yml
├── k3s/
├── helm/
├── terraform/        # Cloudflare zone/tunnel/DNS (ADR-0005; built in its phase)
├── argocd/           # ArgoCD bootstrap values + app-of-apps root
├── apps/             # ArgoCD Application manifests
├── docs/
│   └── adr/          # Architectural Decision Records (see below)
└── README.md

## Architectural Decision Records (ADRs)
- Significant architectural decisions are recorded as ADRs under
  `docs/adr/`, one decision per file, so the *reasoning* and trade-offs
  survive — not just the resulting config.
- Each ADR has: **Title** (sequential id + name), **Status** (Proposed /
  Accepted / Rejected / Superseded), **Context**, **Decision** (active
  voice), **Consequences**. Keep to 1–2 pages. Files are named
  `NNNN-short-title.md`; `docs/adr/README.md` is the index and template.
- When a decision changes, add a NEW ADR that supersedes the old one and
  flip the old one's status — don't rewrite history.
- After making a substantive architectural decision in a session, write it
  up as an ADR and add it to the index table in `docs/adr/README.md`.
- Recorded so far:
  - ADR-0001 — single-node k3s via a custom Ansible role (incl. keeping
    bundled Traefik/Ingress for now).
  - ADR-0002 — Cloudflare Tunnel as a host daemon pointed at Traefik ingress.
  - ADR-0003 — ArgoCD-only GitOps (app-of-apps); Helmfile dropped.
  - ADR-0004 — ArgoCD reads the private repo via a read-only SSH deploy key.
    (Superseded by ADR-0006.)
  - ADR-0005 — Terraform for the external/Cloudflare layer (zone/tunnel/DNS).
  - ADR-0006 — repo made public; ArgoCD reads it anonymously over HTTPS
    (supersedes ADR-0004).

## Secrets management — decided: SOPS + age
- Approach: encrypt secret *values* in YAML with an age keypair, commit
  the encrypted files to Git; ArgoCD decrypts at render time via a
  config-management plugin (KSOPS or argocd-vault-plugin).
- Why SOPS: industry-standard, transferable skill; not cluster-bound, so
  secrets stay portable across cluster rebuilds; readable Git diffs
  (keys stay plaintext, only values encrypted).
- Rejected: Sealed Secrets (cluster-bound key), External Secrets Operator
  (needs an external backend), HashiCorp Vault (too heavy for one node).
- Rules:
  - NEVER commit a plaintext secret. `.gitignore` blocks the danger files
    (age.key, *.age, unencrypted *secret*.yaml).
  - The age private key is the crown jewel: back it up, never commit it;
    later provided to ArgoCD as a one-time bootstrap secret.
  - Install SOPS+age tooling just before the first component that needs a
    secret (Cloudflare Tunnel token or Keycloak/Postgres) — not before.

## k3s phase — decided approach
- Install k3s with Ansible, written as our OWN small `k3s` role (not the
  community k3s-ansible role) — same "understand it, then codify it" method
  used for the base role. A single-node install is simple enough that a
  community role would be overkill, and hand-rolling teaches more.
- Ansible's job STOPS at the cluster boundary. Ansible: install k3s, manage
  the systemd service, fetch the kubeconfig back to the Mac. Everything
  running *inside* Kubernetes (Traefik config, ArgoCD, Prometheus, Keycloak,
  apps) is Helm/Helmfile + ArgoCD — NOT Ansible. Don't `kubectl apply` from
  Ansible; that creates two competing sources of truth.
- GitOps discipline: keep everything declarative and committed so ArgoCD can
  adopt it later.
- Before writing the role, walk through what the k3s install actually does
  (install script, systemd unit, kubeconfig location, the flags that matter)
  so it isn't a black box.
- RESOLVED (see ADR-0001): keep k3s's bundled Traefik (Ingress model) for
  now. Planned later exercises — migrate to a Helm-managed Traefik, then
  from the Ingress API to the Gateway API — each with its own ADR when done.
- Cloudflare Tunnel topology is also settled ahead of time (see ADR-0002):
  host `cloudflared` daemon → Traefik ingress, routing kept in Git. This
  revises the "cloudflared as a systemd service" note above only in that we
  point it at Traefik rather than at Services directly.

## Current phase
- [x] Asahi install                ← COMPLETE (see notes below)
- [x] Ansible playbook             ← COMPLETE (base role: hardening, no-sleep,
                                      wifi-powersave-off, firewall, chrony,
                                      dnf5-automatic)
- [x] k3s                          ← COMPLETE (single-node v1.36.2+k3s1 via
                                      the k3s role; bundled Traefik kept)
- [x] Helm                         ← COMPLETE (v4; hands-on walkthrough in
                                      docs/helm-basics.md)
- [~] Helmfile                     ← DROPPED from critical path (ADR-0003);
                                      optional side-exercise only
- [x] ArgoCD bootstrap             ← COMPLETE (v3.4.5 via chart 10.1.3,
                                      app-of-apps, self-managed, automated sync;
                                      private repo via deploy key, ADR-0004)
- [x] Cloudflare Tunnel            ← COMPLETE (cloudflared host daemon → Traefik,
                                      ADR-0002; SOPS-encrypted credential;
                                      ArgoCD exposed at argocd.katomatik.com.
                                      Cloudflare-side codified next by Terraform)
- [x] Terraform (Cloudflare)       ← COMPLETE (zone/tunnel/DNS as IaC, ADR-0005;
                                      HCP remote state/exec; tunnel recreated +
                                      handed to Ansible; docs/terraform-cloudflare.md)
- [ ] Prometheus + Grafana         ← CURRENT
- [ ] Keycloak + Postgres
- [ ] Own apps

## Asahi install — completed, notes
- Fedora Asahi Remix installed, headless
- Regular user created with sudo (wheel group)
- SSH is running and accessible
- Connected via WiFi (nmcli)
- dnf update not yet run — do this first in Ansible or manually

## Ansible — pending tasks for base role
- Deploy SSH public key (first run uses --ask-pass, then key auth)
- Disable SSH root login and password auth (after key is deployed)
- Set hostname
- Prevent sleep/suspend (critical for headless server)
- Firewall basics (firewalld)
- Install base packages (git, curl, vim, etc.)
- DNF automatic updates
- Static IP / DHCP reservation (deferred — on WiFi for now)

## SSH access
- Current IP: check with `ip addr` on server (DHCP for now)
- User: (your username)
- Auth: password for first Ansible run, then SSH key
- First run command: ansible-playbook site.yml --ask-pass
- Subsequent runs:  ansible-playbook site.yml

## Working style
- One layer at a time — don't jump ahead to the next phase
- Explain why, not just what
- When writing config files or playbooks, explain each significant
  section before or after writing it
- Flag when something is a learning simplification vs production
  best practice
- Update the "Current phase" section above as phases complete
