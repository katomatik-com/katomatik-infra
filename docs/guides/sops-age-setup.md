# Setting up SOPS + age — install, keypair, and config

A hands-on setup guide for the homelab's secret-encryption tooling. You do this
**once** on the control node (your Mac). The goal: be able to commit secrets to
this Git repo — which is **public**, so encryption is essential — with their
**values encrypted**, decryptable only by the age private key you generate here.

Background/decision: `CLAUDE.md` (Secrets — SOPS + age) and the ADRs. Concept
recap: SOPS encrypts the *values* in a YAML/JSON file (keys stay readable) using
a random data key, which it wraps for each **age recipient** (public key). Only
the age **private key** can unwrap it.

> **Two consumers, two keys.** Decryption happens in two places: **Ansible on
> this Mac** (host secrets, e.g. the Cloudflare Tunnel credential — next phase)
> and **ArgoCD in-cluster** (Kubernetes Secrets — later, via a SOPS plugin).
> ArgoCD gets its **own dedicated cluster key**, not the one you generate here;
> Kubernetes Secrets are encrypted to *both*, so the Mac stays a break-glass
> decryptor ([ADR-0012](../adr/0012-argocd-sops-decryption-ksops.md)). The
> **server itself never holds a key**: Ansible decrypts here and ships plaintext
> over SSH. This guide sets up the Mac side — the master key.

---

## Part 1 — Install the tools

```sh
brew install sops age
sops --version      # confirm
age --version       # confirm
```

- **age** — the encryption tool/format (the keypair lives here).
- **sops** — the file editor that uses age to encrypt values in structured files.

---

## Part 2 — Generate the age keypair

```sh
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
```

`age-keygen` prints your **public key** (`age1...`) to the screen and writes the
file, which looks like:

```
# created: 2026-07-14T...
# public key: age1qz...             <- recipient; safe to share/commit
AGE-SECRET-KEY-1QF...               <- the crown jewel; NEVER commit
```

Re-derive the public key any time from the private key:

```sh
age-keygen -y ~/.config/sops/age/keys.txt      # prints age1...
```

> The key lives at `~/.config/sops/age/keys.txt`, **outside this repo** — so
> it's not in git at all. (`.gitignore` also blocks `keys.txt`/`age.key` as a
> belt-and-suspenders measure in case one is ever copied in.)

---

## Part 3 — Back up the private key (do this now)

**If you lose `AGE-SECRET-KEY-...`, every secret you ever encrypt is
unrecoverable. If it leaks, every secret is compromised.** Treat it like a root
password:

- Copy the **whole** `keys.txt` (or at least the `AGE-SECRET-KEY-...` line) into
  your password manager, or an encrypted offline backup.
- Do **not** email it, paste it into chat, or commit it.

Don't continue until it's backed up.

---

## Part 4 — Tell SOPS where the key is

SOPS's default key location differs per OS (on macOS it's *not* `~/.config`), so
set it explicitly for cross-platform sanity. Add to `~/.zshrc`:

```sh
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
```

Then reload: `source ~/.zshrc` (or open a new terminal). SOPS uses this file to
**decrypt**; it finds the recipient to **encrypt** to from `.sops.yaml` (next).

---

## Part 5 — Configure `.sops.yaml`

This repo-root file maps file patterns → the age recipient to encrypt to, so you
never pass keys on the command line. Create it with your public key filled in
automatically:

```sh
cat > .sops.yaml <<EOF
# Which files SOPS encrypts, and to which age recipient(s).
# The value below is a PUBLIC key — safe to commit.
creation_rules:
  - path_regex: .*\.sops\.ya?ml$
    age: $(age-keygen -y ~/.config/sops/age/keys.txt)
EOF

cat .sops.yaml      # sanity check: age1... is present
```

Convention (matches `.gitignore`): **encrypted files are named `*.sops.yaml`**
and are committable; anything named `*secret*.yaml` is treated as plaintext and
blocked from commits.

> **Later refinement (not now):** for Kubernetes `Secret` manifests we'll add a
> rule with `encrypted_regex: ^(data|stringData)$` so only the secret data is
> encrypted and `apiVersion`/`kind`/`metadata` stay readable for ArgoCD. For the
> Cloudflare Tunnel (an Ansible host secret in our own format), encrypting all
> values is fine.

---

## Part 6 — Verify it works (round-trip)

Create an encrypted file with the SOPS editor — it opens `$EDITOR`, and encrypts
on save, so the plaintext never lands on disk:

```sh
sops test.sops.yaml
#   In the editor, replace the example content with:
#       hello: world
#       token: super-secret-123
#   then save & quit.
```

Inspect and round-trip:

```sh
cat test.sops.yaml        # values are ENC[AES256_GCM,...]; keys (hello, token)
                          # stay plaintext; a `sops:` metadata block is appended

sops -d test.sops.yaml    # prints the original plaintext (decrypt works)
```

Confirm the git safety net treats the names correctly:

```sh
git check-ignore test.sops.yaml && echo "BLOCKED (unexpected!)" || echo "committable (correct)"
# and a plaintext-named file IS blocked:
touch my-secret.yaml && git check-ignore my-secret.yaml && echo "blocked (correct)"; rm my-secret.yaml
```

Clean up the test:

```sh
rm test.sops.yaml
```

---

## Part 7 — Day-to-day workflow (for reference)

- **Create/edit a secret:** `sops path/to/thing.sops.yaml` — decrypts into your
  editor, re-encrypts on save. Never write plaintext to a `*.sops.yaml` name by
  hand.
- **View/decrypt to stdout:** `sops -d path/to/thing.sops.yaml`
- **Rotate recipients** (after changing `.sops.yaml`): `sops updatekeys
  path/to/thing.sops.yaml`
- **Commit** the `*.sops.yaml` file — the ciphertext is safe in Git.

| File name | Contents | Git |
|---|---|---|
| `~/.config/sops/age/keys.txt` | age private key | outside repo; never commit |
| `.sops.yaml` | public key + rules | **commit** (public key is safe) |
| `*.sops.yaml` | encrypted values | **commit** |
| `*secret*.yaml`, `*.dec.yaml` | plaintext | blocked by `.gitignore` |

---

## What's next

With SOPS + age working and `.sops.yaml` committed, the **Cloudflare Tunnel**
phase will:
1. create the tunnel and get its **credential** (our first real secret),
2. store it as a `*.sops.yaml` file, and
3. have **Ansible decrypt it on this Mac** and deploy it to the `cloudflared`
   host service.

Later, **ArgoCD** decrypts Kubernetes Secrets at render time using a **second,
dedicated cluster key** (added as a one-time in-cluster bootstrap Secret) — not
the master key generated here, which never leaves this Mac. Files under
`manifests/` are encrypted to both recipients, so the master remains a
break-glass decryptor; see `.sops.yaml` and
[argocd-secret-decryption.md](argocd-secret-decryption.md).
