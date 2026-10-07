#!/usr/bin/env bash
# Build the sample-api image locally and load it into the kind cluster (no registry needed).
# If the app is already deployed, restart it so the pods pick up the new image.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

kps_guard

if [[ "$IMAGE" != "sample-api:dev" ]]; then
  warn "IMAGE=$IMAGE. charts/sample-api/values-local.yaml deploys sample-api:dev, so the app will not use this tag."
fi

commit="local"
if top="$(git -c safe.directory="$REPO_ROOT" -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null)" \
  && [[ "$top" == "$REPO_ROOT" ]] \
  && sha="$(git -c safe.directory="$REPO_ROOT" -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null)"; then
  commit="$sha"
fi

log "Building $IMAGE from app/ (APP_VERSION=0.1.0-dev, GIT_COMMIT=$commit)"
docker build -t "$IMAGE" \
  --build-arg APP_VERSION=0.1.0-dev \
  --build-arg GIT_COMMIT="$commit" \
  "$REPO_ROOT/app"

log "Loading $IMAGE into kind cluster '$KPS_CLUSTER_NAME'"
kind load docker-image "$IMAGE" --name "$KPS_CLUSTER_NAME"

if kubectl_kps -n "$KPS_APP_NS" get deployment "$KPS_APP_NAME" >/dev/null 2>&1; then
  log "Restarting deployment/$KPS_APP_NAME so the pods use the new image"
  kubectl_kps -n "$KPS_APP_NS" rollout restart "deployment/$KPS_APP_NAME"
  kubectl_kps -n "$KPS_APP_NS" rollout status "deployment/$KPS_APP_NAME" --timeout=180s
else
  info "sample-api is not deployed yet; 'make app' will use this image."
fi
