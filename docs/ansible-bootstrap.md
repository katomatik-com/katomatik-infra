# Bootstrapping a host for Ansible — step by step

This guide takes you from **two fresh machines** to **"Ansible on my laptop can
manage my server."** It covers the *manual* groundwork that has to happen
before Ansible can take over.

- **Control node** = the machine you run Ansible *from* (your Mac).
- **Managed host** = the machine Ansible *configures* (the homelab server,
  a fresh Fedora Asahi install).

> **The chicken-and-egg problem.** Ansible manages a host over SSH, running
> Python on the far end. So before Ansible can do anything, the host must
> already have: a user you can log in as, a running SSH server, and Python.
> Those few things are done by hand *once* — everything after is automated.

The examples use **Fedora** (this project's OS) with **Debian/Ubuntu**
equivalents in call-outs, so the guide is reusable.

---

## Part A — Control node (your Mac)

### A1. Install Ansible

Ansible only needs to exist on the control node — **not** on the server.

```sh
brew install ansible
# Alternative, version-pinned & isolated:  pipx install ansible
```

Verify:

```sh
ansible --version
```

### A2. Install the collections this project uses

Some modules this project uses aren't bundled with Ansible core — they live
in the `ansible.posix` collection (`authorized_key`, `firewalld`) and
`community.general` (`timezone`). They're declared in `ansible/requirements.yml`:

```sh
ansible-galaxy collection install -r ansible/requirements.yml
```

### A3. Create an SSH key pair

This key proves *who you are* to the server without a password. `ed25519` is
the modern, recommended key type.

```sh
ssh-keygen -t ed25519 -C "homelab" -f ~/.ssh/id_ed25519
```

- Press Enter twice for **no passphrase** (simplest; lets Ansible log in
  unattended), or set one for extra safety and load it into `ssh-agent`.
- Produces two files:
  - `~/.ssh/id_ed25519` — **private key**, never leaves this machine, never
    committed to Git.
  - `~/.ssh/id_ed25519.pub` — **public key**, safe to share; this is what
    gets installed on the server.

> **Production note.** Best practice is a *separate* key per purpose (one for
> GitHub, one for servers) so revoking one doesn't affect the others. For a
> single-user homelab, one key is a fine simplification.

---

## Part B — Managed host (fresh Linux install)

Do these steps **at the physical console** (or your cloud provider's web
console) the first time — you may not have SSH access yet.

### B1. Log in and become root

On a fresh install you'll have either a root password or a first user. Get a
root shell:

```sh
su -            # if you have the root password
# or:  sudo -i  (if your first user already has sudo)
```

### B2. Update the system

```sh
dnf upgrade --refresh -y
# Debian/Ubuntu:  apt update && apt upgrade -y
```

### B3. Create a non-root user with sudo

You never want Ansible (or yourself) logging in as root over SSH. Create a
regular user and grant it admin rights via the `wheel` group (Fedora) /
`sudo` group (Debian).

```sh
# Fedora
useradd -m -G wheel katomatik        # -m makes a home dir, -G wheel grants sudo
passwd katomatik                     # set a password (used only for the FIRST
                                # Ansible run, until the key is deployed)
```

```sh
# Debian/Ubuntu
adduser katomatik                    # interactive; sets password too
usermod -aG sudo katomatik
```

> **Why a password at all if we'll use keys?** Ansible's very first run has to
> get *in* somehow to install your public key. That first connection uses the
> password (`--ask-pass`); afterwards you disable password login entirely.

Confirm sudo works:

```sh
su - katomatik
sudo whoami        # should print: root
exit
```

### B4. Ensure the SSH server is installed and running

Ansible connects over SSH, so the host needs the SSH *daemon* (server),
not just the client.

```sh
# Fedora
dnf install -y openssh-server
systemctl enable --now sshd

# Debian/Ubuntu
apt install -y openssh-server
systemctl enable --now ssh
```

`enable --now` both starts it immediately and makes it start on every boot.
Check it's listening:

```sh
systemctl status sshd     # (ssh on Debian) — look for "active (running)"
```

### B5. Ensure Python 3 is present

Ansible executes its modules using Python on the managed host. Most modern
Linux installs already have it:

```sh
python3 --version
# If missing:
#   Fedora:  dnf install -y python3
#   Debian:  apt install -y python3
```

This matches `ansible_python_interpreter=/usr/bin/python3` in the project's
inventory.

### B6. Find the host's IP address

You'll point Ansible at this address.

```sh
ip addr        # look under your active interface (e.g. wlan0/eth0) for
               # an inet line like 192.168.2.34/24
```

> **DHCP caveat.** Until you set a static IP or a DHCP reservation, this
> address can change on reboot. For now, just note it and update the
> inventory when it changes. (This project targets a reservation at
> `192.168.2.10` later.)

### B7. (Firewall) allow SSH — usually already open

Fedora's firewall permits SSH by default, but to be sure:

```sh
firewall-cmd --add-service=ssh --permanent && firewall-cmd --reload
```

(The Ansible `base` role re-asserts this, so this is just to guarantee you're
not locked out before the first run.)

---

## Part C — Connect the two

### C1. Manual smoke test

From the **Mac**, prove basic SSH works before involving Ansible:

```sh
ssh katomatik@<server-ip>
```

Type `yes` to trust the host key on first connect, then the password from
step B3. If you get a shell, log back out (`exit`).

### C2. Point the inventory at the host

Edit `ansible/inventory/hosts.ini` and `ansible/group_vars/all.yml` and fill
in the `CHANGEME` values:

- `ansible_host` = the IP from B6
- `ansible_user` / `ssh_user` = `katomatik` (or whatever you created)
- `ssh_public_key_file` = `~/.ssh/id_ed25519.pub`

Test Ansible can reach the host (the `ping` module checks SSH **and** Python):

```sh
cd ansible
ansible all -m ping -k -K
#   -k / --ask-pass         → SSH login password
#   -K / --ask-become-pass  → sudo password
# Success looks like:  server | SUCCESS => { ... "ping": "pong" }
```

### C3. First playbook run — with a password

The key isn't on the server yet, so authenticate with the password.
**Leave `ssh_password_authentication: "yes"` in `group_vars/all.yml` for this
run** so you can't lock yourself out mid-play.

```sh
ansible-playbook site.yml -k -K
```

Among other things, this installs your **public key** onto the server.

### C4. Confirm key login, then lock the door

Verify you can now log in with **no password prompt** (key auth):

```sh
ssh katomatik@<server-ip>        # should NOT ask for a password
```

Only once that works, harden SSH:

1. Set `ssh_password_authentication: "no"` in `group_vars/all.yml`.
2. Re-run (no `-k` needed now — the key works; still `-K` for sudo):

```sh
ansible-playbook site.yml -K
```
From here on, password logins are refused and the only way in is your key.
Day-to-day you just run:

```sh
ansible-playbook site.yml
```
> this does not work yet, we didn't configure paswordless sudo

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `Permission denied (publickey,password)` on first run | You dropped `-k`, or password auth is already off. Use `-k`, and verify the user/password. |
| `ssh: connect to host ... port 22: No route to host` | Wrong IP (DHCP changed it — re-check `ip addr`), host down, or firewall. |
| Ansible ping fails with a Python error | Python 3 missing on the host (step B5) or wrong `ansible_python_interpreter`. |
| Host key warning after a reinstall | The server's key changed; remove the stale line: `ssh-keygen -R <server-ip>`. |
| Locked out after disabling password auth | Log in at the physical console, re-enable `PasswordAuthentication yes` in `/etc/ssh/sshd_config`, `systemctl restart sshd`, fix the key, try again. |

## Where this leaves you

The host is now a managed node: key-only SSH, a sudo user, firewall up, and
the `base` role keeping it that way. Re-running the playbook is safe and
**idempotent** — it only changes what's drifted. Next project phase: k3s.
