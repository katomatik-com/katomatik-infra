#!/usr/bin/env bash
# Run Terraform against the in-cluster Keycloak admin API.
#
# Wraps the three things that must be true for a run to work (ADR-0015) so they
# can't be half-done:
#   1. a `kubectl port-forward` to the admin API — which is NOT exposed publicly
#   2. KEYCLOAK_USER / KEYCLOAK_PASSWORD, read straight from the cluster Secret
#      so no credential is ever typed, echoed, or written to disk here
#   3. the tunnel torn down again afterwards, even if Terraform fails
#
# Usage:  ./tf.sh plan
#         ./tf.sh apply
#         ./tf.sh output
#
# Still supplied by you, deliberately: TF_VAR_admin_initial_password. If it isn't
# set, Terraform prompts for it — a value that ends up in state should be a
# conscious act, not something a wrapper script decides.

set -euo pipefail

NAMESPACE="keycloak"
SERVICE="svc/keycloak-service"
LOCAL_PORT="${KC_LOCAL_PORT:-8080}"
PROBE="http://localhost:${LOCAL_PORT}/realms/master/.well-known/openid-configuration"

# Always operate on this workspace, whatever directory you invoked from — the
# nesting under terraform/ makes a stray `cd` genuinely easy.
cd "$(dirname "$0")"

for tool in kubectl terraform curl; do
  command -v "$tool" >/dev/null || { echo "error: $tool not found in PATH" >&2; exit 1; }
done

port_forward_pid=""
cleanup() {
  # Only tear down a tunnel THIS script opened; an editor/terminal you left
  # running elsewhere is none of our business.
  if [[ -n "$port_forward_pid" ]]; then
    echo "==> closing port-forward"
    kill "$port_forward_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Reuse an existing tunnel if one is already up. The probe checks for Keycloak's
# discovery document specifically, not merely "something is listening on 8080",
# so an unrelated local service can't be mistaken for the admin API.
if curl -sf --max-time 2 "$PROBE" 2>/dev/null | grep -q '"issuer"'; then
  echo "==> reusing tunnel already open on :${LOCAL_PORT}"
else
  echo "==> opening port-forward ${NAMESPACE}/${SERVICE} -> localhost:${LOCAL_PORT}"
  kubectl -n "$NAMESPACE" port-forward "$SERVICE" "${LOCAL_PORT}:8080" >/dev/null 2>&1 &
  port_forward_pid=$!

  # Wait for readiness instead of sleeping a hopeful fixed amount — and notice
  # if kubectl died (wrong context, port already bound, pod not running).
  for _ in $(seq 1 30); do
    if curl -sf --max-time 2 "$PROBE" >/dev/null 2>&1; then break; fi
    kill -0 "$port_forward_pid" 2>/dev/null || {
      echo "error: port-forward exited — is :${LOCAL_PORT} already in use, or keycloak-0 not running?" >&2
      exit 1
    }
    sleep 0.5
  done
  curl -sf --max-time 2 "$PROBE" >/dev/null 2>&1 || {
    echo "error: tunnel opened but the admin API never answered on :${LOCAL_PORT}" >&2
    exit 1
  }
  echo "==> tunnel ready"
fi

# The bootstrap admin account. Exported into Terraform's environment only — the
# keycloak provider reads these two variable names natively (see versions.tf).
KEYCLOAK_USER="$(kubectl -n "$NAMESPACE" get secret keycloak-initial-admin \
  -o jsonpath='{.data.username}' | base64 -d)"
KEYCLOAK_PASSWORD="$(kubectl -n "$NAMESPACE" get secret keycloak-initial-admin \
  -o jsonpath='{.data.password}' | base64 -d)"
export KEYCLOAK_USER KEYCLOAK_PASSWORD

echo "==> terraform $*"
# NOT `exec` — that would replace this shell and the EXIT trap would never fire,
# orphaning the port-forward. Run it as a child so cleanup always happens.
terraform "$@"
