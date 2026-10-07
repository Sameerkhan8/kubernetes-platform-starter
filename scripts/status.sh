#!/usr/bin/env bash
# Show the state of the local platform: nodes, pods, autoscaling, routes and the Argo CD app.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

kps_guard

log "Nodes (zone labels are used by topologySpreadConstraints)"
kubectl_kps get nodes -o wide -L topology.kubernetes.io/zone

for ns in demo traefik monitoring argocd; do
  echo
  log "Pods in namespace $ns"
  kubectl_kps -n "$ns" get pods -o wide 2>/dev/null || true
done

echo
log "Autoscaler and disruption budget (demo)"
kubectl_kps -n demo get hpa,pdb 2>/dev/null || true

echo
log "Gateway and routes"
kubectl_kps get gateways.gateway.networking.k8s.io -A 2>/dev/null || info "(Gateway API not installed)"
kubectl_kps get httproutes.gateway.networking.k8s.io -A 2>/dev/null || true

echo
log "Argo CD applications"
kubectl_kps -n argocd get applications.argoproj.io \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision,REPO:.spec.source.repoURL' \
  2>/dev/null || info "(Argo CD not installed)"
