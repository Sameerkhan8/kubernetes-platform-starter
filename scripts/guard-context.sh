#!/usr/bin/env bash
# Refuse to continue unless kubectl points at the local kind cluster "kps".
#
# Why this exists: the default kubeconfig on a work laptop often points at a real
# cluster. Every cluster command in this repo uses the repo-local .kube/config and
# runs this check first, so a typo can never reach anything but the local kind cluster.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="$REPO_ROOT/.kube/config"
EXPECTED_CONTEXT="kind-kps"
EXPECTED_CLUSTER="kps"

# Helm reads these from the environment and lets them override the API server and
# credentials, even when --kube-context is passed. Refuse to run while any of them is set.
helm_env="$(env | sed -nE 's/^(HELM_KUBE[A-Z_]*)=.*/\1/p' | tr '\n' ' ')"
if [[ -n "$helm_env" ]]; then
  echo "ABORT: these Helm variables would redirect helm to another cluster: ${helm_env% }. Unset them first." >&2
  exit 1
fi

if [[ ! -f "$KUBECONFIG" ]]; then
  echo "ABORT: $KUBECONFIG does not exist. Run 'make cluster' first." >&2
  exit 1
fi
current="$(kubectl config current-context 2>/dev/null || true)"
if [[ "$current" != "$EXPECTED_CONTEXT" ]]; then
  echo "ABORT: kube context is '${current:-<none>}', expected '$EXPECTED_CONTEXT' (KUBECONFIG=$KUBECONFIG)." >&2
  exit 1
fi
server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
case "$server" in
  https://127.0.0.1:*|https://localhost:*|https://\[::1\]:*) ;;
  *) echo "ABORT: context '$current' points at '$server', which is not a local kind API server." >&2; exit 1 ;;
esac
# A local address is not enough (it could be an SSH tunnel to another cluster): the port must
# be the one Docker publishes for the API server of the kind node container "kps-control-plane".
api_port="$(docker port "${EXPECTED_CLUSTER}-control-plane" 6443/tcp 2>/dev/null | sed -nE 's/^127\.0\.0\.1:([0-9]+)$/\1/p' | head -n 1 || true)"
if [[ -z "$api_port" ]]; then
  echo "ABORT: the kind node container '${EXPECTED_CLUSTER}-control-plane' is not running. Run 'make cluster' first." >&2
  exit 1
fi
if [[ "${server##*:}" != "$api_port" ]]; then
  echo "ABORT: context '$current' points at '$server', but kind cluster '$EXPECTED_CLUSTER' listens on 127.0.0.1:$api_port." >&2
  exit 1
fi
