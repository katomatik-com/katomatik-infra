#!/usr/bin/env bash
# Collect what is ACTUALLY running, so documentation can be checked against it
# rather than against itself (ADR-0017; driven by /docs-drift-audit).
#
# Design rules, in order of importance:
#
#   1. NO SECRETS ARE COLLECTED. Every command here is chosen to return shape,
#      not values: `terraform output` redacts sensitive outputs itself, secrets
#      are listed by NAME and KEY only (never `-o yaml`/`jsonpath`, which emit
#      base64 — encoding, not encryption). A guard at the end aborts loudly if a
#      secret-looking string reaches the output anyway.
#   2. OUTPUT LANDS OUTSIDE THE REPO by default ($TMPDIR). This repo is public;
#      a collection of live infrastructure state is not something to risk
#      `git add .`-ing. Override with -o only if you know why.
#   3. A FAILED SOURCE IS RECORDED, NOT FATAL. Each collector can fail on its
#      own — the cluster is LAN-only, HCP needs credentials, the Keycloak
#      workspace needs a port-forward. summary.txt says which sources answered,
#      so anything they would have covered is honestly UNVERIFIABLE instead of
#      silently "confirmed".
#
# Progress goes to STDERR; STDOUT carries ONLY the output directory, so
#   DIR=$(scripts/ground-truth.sh)
# captures a path and not a progress log. (Same convention as terraform/keycloak/tf.sh.)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR=""
# Every public hostname the lab serves, across BOTH domains (ADR-0018). A
# hostname missing here is not "assumed fine" — the audit has nothing to check
# it against, so its claims come out UNVERIFIABLE. Add a line when you add a
# hostname to terraform.tfvars `zones`.
PUBLIC_HOSTS=(
  "https://argocd.katomatik.com"
  "https://auth.katomatik.com"
  "https://authdemo.katomatik.com"
  "https://katomatik.com"
  "https://www.katomatik.com"
  "https://kurtcebe.nl"
  "https://www.kurtcebe.nl"
)

while getopts ":o:h" opt; do
  case "$opt" in
    o) OUT_DIR="$OPTARG" ;;
    h) sed -n '2,30p' "$0" >&2; exit 0 ;;
    *) echo "usage: $0 [-o output-dir]" >&2; exit 2 ;;
  esac
done

# mktemp -d, not a fixed path: two runs never clobber each other, and the OS
# cleans up eventually. Deliberately NOT inside the repo — see rule 2.
[[ -n "$OUT_DIR" ]] || OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/katomatik-ground-truth.XXXXXX")"
mkdir -p "$OUT_DIR"

SUMMARY="$OUT_DIR/summary.txt"
: > "$SUMMARY"

note() { echo "$*" >&2; }

# Run one collector. Records OK/FAILED in summary.txt either way, and keeps
# going — a missing source must be visible, not fatal.
collect() {
  local name="$1" file="$2"; shift 2
  note "==> $name"
  if "$@" > "$OUT_DIR/$file" 2> "$OUT_DIR/$file.err"; then
    printf 'OK        %-28s -> %s\n' "$name" "$file" >> "$SUMMARY"
    rm -f "$OUT_DIR/$file.err"
  else
    printf 'FAILED    %-28s (see %s.err) — claims from this source are UNVERIFIABLE\n' \
      "$name" "$file" >> "$SUMMARY"
    note "    FAILED — continuing"
  fi
}

# --- Cluster ------------------------------------------------------------------
# The API is homelab.lan:6443, i.e. LAN-only. Off the LAN every one of these
# fails, which is the correct and visible outcome.
KUBECTL=(kubectl --request-timeout=15s)

collect "cluster: version"        cluster-version.txt      "${KUBECTL[@]}" version
collect "cluster: nodes"          cluster-nodes.txt        "${KUBECTL[@]}" get nodes -o wide
collect "cluster: namespaces"     cluster-namespaces.txt   "${KUBECTL[@]}" get ns
# Images and replica counts: the source of truth for every "we run version X" claim.
collect "cluster: deployments"    cluster-deployments.txt  "${KUBECTL[@]}" get deploy,statefulset,ds -A \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,READY:.status.readyReplicas,IMAGES:.spec.template.spec.containers[*].image'
# Hosts and paths — what is actually routed, and therefore what is NOT.
collect "cluster: ingresses"      cluster-ingresses.txt    "${KUBECTL[@]}" get ingress -A \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,HOSTS:.spec.rules[*].host,PATHS:.spec.rules[*].http.paths[*].path,SVC:.spec.rules[*].http.paths[*].backend.service.name'
collect "cluster: services"       cluster-services.txt     "${KUBECTL[@]}" get svc -A
collect "cluster: pods"           cluster-pods.txt         "${KUBECTL[@]}" get pods -A -o wide
# NAME and TYPE only. Never the data — see rule 1.
collect "cluster: secret names"   cluster-secret-names.txt "${KUBECTL[@]}" get secrets -A \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,TYPE:.type'
collect "argocd: applications"    argocd-applications.txt  "${KUBECTL[@]}" -n argocd get applications \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REPO:.spec.source.repoURL,PATH:.spec.source.path'
# argocd-cm holds oidc.config and the RBAC policy. No credentials live here
# (those are in argocd-secret, which is deliberately not collected).
collect "argocd: configmaps"      argocd-configmaps.yaml   "${KUBECTL[@]}" -n argocd get cm argocd-cm argocd-rbac-cm -o yaml
collect "keycloak: CR"            keycloak-cr.yaml         "${KUBECTL[@]}" -n keycloak get keycloak -o yaml

# --- Terraform ----------------------------------------------------------------
# Outputs, not state. `terraform output` redacts anything marked sensitive;
# `state list` is an inventory of resource addresses with no values at all.
collect "terraform: root outputs"    tf-root-outputs.txt     terraform -chdir="$REPO_ROOT/terraform" output
collect "terraform: root resources"  tf-root-resources.txt   terraform -chdir="$REPO_ROOT/terraform" state list

# The Keycloak workspace keeps LOCAL state and reaches the admin API over a
# port-forward, so tf.sh has to drive it. Off-machine this fails — correctly.
collect "terraform: keycloak outputs"   tf-keycloak-outputs.txt   "$REPO_ROOT/terraform/keycloak/tf.sh" output
collect "terraform: keycloak resources" tf-keycloak-resources.txt "$REPO_ROOT/terraform/keycloak/tf.sh" state list

# --- Public behaviour ---------------------------------------------------------
# The only source reachable from anywhere, and the one that checks claims the
# repo cannot: what a visitor actually gets.
note "==> public endpoints"
{
  echo "# status codes as seen from the public internet ($(date -u '+%Y-%m-%d %H:%M UTC'))"
  for base in "${PUBLIC_HOSTS[@]}"; do
    printf '%-40s %s\n' "$base/" "$(curl -s -o /dev/null -m 15 -w '%{http_code}' "$base/" || echo ERR)"
  done
  # Specific claims the guides make, worth checking by name rather than by host.
  # The www hosts above only record a status code; the docs claim a redirect to a
  # SPECIFIC target, so capture the Location too or "301" would look like proof.
  printf '%-40s %s\n' "katomatik: www -> apex target" \
    "$(curl -s -o /dev/null -m 15 -w '%{redirect_url}' https://www.katomatik.com/ || echo ERR)"
  printf '%-40s %s\n' "kurtcebe: www -> apex target" \
    "$(curl -s -o /dev/null -m 15 -w '%{redirect_url}' https://www.kurtcebe.nl/ || echo ERR)"
  printf '%-40s %s\n' "auth: /admin must NOT be routed" \
    "$(curl -s -o /dev/null -m 15 -w '%{http_code}' https://auth.katomatik.com/admin || echo ERR)"
  printf '%-40s %s\n' "auth: OIDC discovery" \
    "$(curl -s -o /dev/null -m 15 -w '%{http_code}' https://auth.katomatik.com/realms/katomatik/.well-known/openid-configuration || echo ERR)"
  printf '%-40s %s\n' "authdemo: /public/ping (anon)" \
    "$(curl -s -o /dev/null -m 15 -w '%{http_code}' https://authdemo.katomatik.com/public/ping || echo ERR)"
  printf '%-40s %s\n' "authdemo: /me (anon -> 302)" \
    "$(curl -s -o /dev/null -m 15 -w '%{http_code}' https://authdemo.katomatik.com/me || echo ERR)"
  printf '%-40s %s\n' "authdemo: /admin/hello (anon)" \
    "$(curl -s -o /dev/null -m 15 -w '%{http_code}' https://authdemo.katomatik.com/admin/hello || echo ERR)"
} > "$OUT_DIR/public-endpoints.txt" 2>/dev/null
printf 'OK        %-28s -> %s\n' "public: endpoints" "public-endpoints.txt" >> "$SUMMARY"

collect "public: issuer" public-issuer.json curl -s -m 15 \
  https://auth.katomatik.com/realms/katomatik/.well-known/openid-configuration

# --- Repo state ---------------------------------------------------------------
collect "git: recent history"  git-log.txt     git -C "$REPO_ROOT" log --oneline -40
collect "git: status"          git-status.txt  git -C "$REPO_ROOT" status --short

# --- Secret guard -------------------------------------------------------------
# Backstop for rule 1. If a credential ever reaches the output — a collector
# changed, a provider started echoing more — fail loudly rather than hand the
# audit a directory full of secrets.
note "==> checking output for leaked secrets"
if grep -rlE 'BEGIN [A-Z ]*PRIVATE KEY|AGE-SECRET-KEY-|eyJhbGciOi|password["'"'"':= ]+[^ <"]{8}' \
     "$OUT_DIR" 2>/dev/null | grep -q .; then
  echo "REFUSING: secret-looking content found in $OUT_DIR" >&2
  grep -rlE 'BEGIN [A-Z ]*PRIVATE KEY|AGE-SECRET-KEY-|eyJhbGciOi|password["'"'"':= ]+[^ <"]{8}' \
    "$OUT_DIR" 2>/dev/null | sed 's/^/  /' >&2
  echo "Inspect and delete it by hand: rm -rf $OUT_DIR" >&2
  exit 1
fi

note ""
note "--- summary ---"
cat "$SUMMARY" >&2
note ""
note "Sources that FAILED above cover claims that must be reported UNVERIFIABLE."

echo "$OUT_DIR"
