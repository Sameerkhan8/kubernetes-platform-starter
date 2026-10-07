#!/usr/bin/env bash
# Create or delete the local kind cluster "kps".
#   scripts/cluster.sh up     create the cluster if it does not exist, then verify the kube context
#   scripts/cluster.sh down   delete the cluster and the kps-git container (images are kept)
#
# kind always gets --kubeconfig "$REPO_ROOT/.kube/config". Without it, kind would write
# into your default kubeconfig and switch its current-context.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "$KPS_CLUSTER_NAME"
}

render_config() {
  local out="$1"
  sed -E \
    -e "s|^( +image: )kindest/node:.*$|\1${KIND_NODE_IMAGE}|" \
    -e "s|^( +hostPort: )80( +# HOST_HTTP_PORT)$|\1${HOST_HTTP_PORT}\2|" \
    -e "s|^( +hostPort: )443( +# HOST_HTTPS_PORT)$|\1${HOST_HTTPS_PORT}\2|" \
    "$REPO_ROOT/kind/cluster.yaml" >"$out"
  grep -Eq "hostPort: ${HOST_HTTP_PORT} +# HOST_HTTP_PORT" "$out" || die "could not set HOST_HTTP_PORT in the kind config"
  grep -Eq "hostPort: ${HOST_HTTPS_PORT} +# HOST_HTTPS_PORT" "$out" || die "could not set HOST_HTTPS_PORT in the kind config"
}

up() {
  command -v kind >/dev/null 2>&1 || die "kind not found. Run 'make doctor'."
  [[ "$HOST_HTTP_PORT" =~ ^[0-9]+$ && "$HOST_HTTPS_PORT" =~ ^[0-9]+$ ]] \
    || die "HOST_HTTP_PORT and HOST_HTTPS_PORT must be numbers"
  local kind_v
  kind_v="$(kind version 2>/dev/null | awk '{print $2}')"
  [[ "$kind_v" == "$KIND_VERSION" ]] || warn "kind $kind_v found, this repo is tested with $KIND_VERSION"

  mkdir -p "$REPO_ROOT/.kube"
  if cluster_exists; then
    log "kind cluster '$KPS_CLUSTER_NAME' already exists, not creating it again"
    if [[ ! -s "$KUBECONFIG" ]]; then
      log "Writing its kubeconfig to $KUBECONFIG"
      kind export kubeconfig --name "$KPS_CLUSTER_NAME" --kubeconfig "$KUBECONFIG"
    fi
  else
    local cfg
    cfg="$(mktemp)"
    # shellcheck disable=SC2064  # expand now: the variable is local
    trap "rm -f '$cfg'" EXIT
    render_config "$cfg"
    log "Creating kind cluster '$KPS_CLUSTER_NAME' (1 control-plane + 2 workers, Kubernetes $KUBERNETES_VERSION)"
    info "gateway ports on this laptop: 127.0.0.1:${HOST_HTTP_PORT} (http), 127.0.0.1:${HOST_HTTPS_PORT} (https)"
    kind create cluster --name "$KPS_CLUSTER_NAME" --config "$cfg" --kubeconfig "$KUBECONFIG" --wait 120s
  fi
  chmod 600 "$KUBECONFIG"

  log "Checking the kube context (KUBECONFIG=$KUBECONFIG)"
  info "kubectl config current-context: $(kubectl_current_context)"
  kps_guard
  info "OK: context is $KPS_CONTEXT and its API server is local"
  kubectl_kps get nodes -L topology.kubernetes.io/zone
}

down() {
  if command -v kind >/dev/null 2>&1 && cluster_exists; then
    log "Deleting kind cluster '$KPS_CLUSTER_NAME'"
    mkdir -p "$REPO_ROOT/.kube"
    kind delete cluster --name "$KPS_CLUSTER_NAME" --kubeconfig "$KUBECONFIG"
  else
    log "kind cluster '$KPS_CLUSTER_NAME' does not exist"
  fi
  if docker container inspect kps-git >/dev/null 2>&1; then
    log "Removing the local git daemon container kps-git"
    docker rm -f kps-git >/dev/null
  fi
  info "Images (sample-api:*, kps-*) are kept. Remove them by hand if you want the disk space back."
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  *) die "usage: $0 up|down" ;;
esac
