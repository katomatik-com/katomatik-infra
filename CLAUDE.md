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
- Kubernetes: k3s (single node)
- Package deployment: Helm + Helmfile
- GitOps: ArgoCD (watches Git repo, manages cluster state)
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
└── README.md

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

## Current phase
- [x] Asahi install                ← COMPLETE (see notes below)
- [x] Ansible playbook             ← COMPLETE (base role: hardening, no-sleep,
                                      firewall, chrony, dnf5-automatic)
- [ ] k3s + Helm + Helmfile        ← CURRENT
- [ ] ArgoCD bootstrap
- [ ] Cloudflare Tunnel
- [ ] Prometheus + Grafana
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
