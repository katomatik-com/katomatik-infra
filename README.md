# Homelab

Learning DevOps / Kubernetes / GitOps by building a real home lab server.
See [CLAUDE.md](./CLAUDE.md) for the full plan, stack, and decisions.

## Current phase: Ansible base role

OS-level setup + hardening of the Fedora Asahi server from your Mac.

> New to the setup? Start with the step-by-step
> [Ansible bootstrap guide](./docs/ansible-bootstrap.md) — it takes two fresh
> machines to "Ansible can manage my server" (users, SSH keys, first run).

### One-time setup on the control node (your Mac)

```sh
# 1. Install Ansible + the collection the base role uses
brew install ansible                       # or: pipx install ansible
ansible-galaxy collection install -r ansible/requirements.yml

# 2. Generate an SSH key for the homelab (if you don't have one)
ssh-keygen -t ed25519 -C "homelab"         # -> ~/.ssh/id_ed25519[.pub]
```

### Fill in the placeholders

- `ansible/inventory/hosts.ini` — set `ansible_user`, and the server IP if
  it isn't `192.168.2.10` yet (check with `ip addr` on the server).
- `ansible/group_vars/all.yml` — set `ssh_user`, confirm `ssh_public_key_file`.

### Run it

```sh
cd ansible

# FIRST run: no SSH key on the server yet, so authenticate with a password.
# -k = --ask-pass (SSH password), -K = --ask-become-pass (sudo password).
# IMPORTANT: leave ssh_password_authentication = "yes" in group_vars for
# this first run, so you don't lock yourself out mid-play.
ansible-playbook site.yml -k -K

# CONFIRM key login works:
ssh <ssh_user>@<server-ip>

# THEN harden: set ssh_password_authentication: "no" in group_vars and
# re-run. Now key auth is the only way in.
ansible-playbook site.yml -K
```

### Verify afterwards

```sh
ssh homelab@<ip> 'systemctl is-enabled dnf-automatic.timer; \
  systemctl is-active firewalld; \
  systemctl status sleep.target | head -3'   # should show: masked
```

## Secrets

This repo uses **SOPS + age** (see CLAUDE.md). Never commit plaintext
secrets — `.gitignore` blocks them. SOPS tooling gets set up later, just
before the first component that needs a secret.
