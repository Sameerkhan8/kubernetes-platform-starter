#!/usr/bin/env bash
# Zero-downtime check: send steady traffic through the gateway while the Deployment does a
# rolling restart, then count failed requests. PASS means 0 failed requests.
#
# What makes this pass (see docs/decisions/0002-prestop-sleep-graceful-shutdown.md):
# maxUnavailable 0 + readiness probe, preStop sleep while the gateway drops the old pod,
# /readyz flipping to 503 on SIGTERM, and uvicorn's graceful drain of in-flight requests.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

kps_guard
require_app

JOB="kps-rollout-test"
DURATION=90

log "Starting steady traffic: ${DURATION}s, 4 workers x 10 req/s on / via ${KPS_GATEWAY_URL} (Host: ${KPS_APP_HOST})"
loadgen_job_start "$JOB" \
  --url "${KPS_GATEWAY_URL}/" \
  --host "$KPS_APP_HOST" \
  --duration "$DURATION" \
  --concurrency 4 \
  --rate 10 \
  --fail-on-error
job_wait_started "$JOB" 120 || die "traffic Job did not start"

info "letting traffic run for 10s before the rollout"
sleep 10

log "Rolling restart of deployment/$KPS_APP_NAME (maxSurge 1, maxUnavailable 0)"
kubectl_kps -n "$KPS_APP_NS" get pods -l app.kubernetes.io/name=sample-api -o wide
rollout_ok=1
kubectl_kps -n "$KPS_APP_NS" rollout restart "deployment/$KPS_APP_NAME"
if ! kubectl_kps -n "$KPS_APP_NS" rollout status "deployment/$KPS_APP_NAME" --timeout=180s; then
  rollout_ok=0
  warn "rollout did not finish within 180s"
fi
kubectl_kps -n "$KPS_APP_NS" get pods -l app.kubernetes.io/name=sample-api -o wide

log "Waiting for the traffic Job to finish"
deadline=$((SECONDS + DURATION + 120))
while [[ "$(job_state "$JOB")" == "running" ]]; do
  ((SECONDS < deadline)) || die "traffic Job still running. Check: KUBECONFIG=$KUBECONFIG kubectl --context kind-kps -n demo logs job/$JOB"
  sleep 5
done

echo
log "Load generator output"
job_logs "$JOB" | sed 's/^/    /'

result="$(job_result "$JOB")"
[[ -n "$result" ]] || die "no RESULT line in the Job output. Check: KUBECONFIG=$KUBECONFIG kubectl --context kind-kps -n demo describe job/$JOB"
total="$(json_number total "$result")"
failed="$(json_number failed "$result")"

echo
echo "RESULT total=${total:-?} failed=${failed:-?}"
if [[ "$rollout_ok" == "1" && "${total:-0}" -gt 0 && "${failed:-1}" == "0" ]]; then
  echo "PASS: no request failed during the rolling update"
else
  echo "FAIL: requests failed during the rolling update (or the rollout did not finish)"
  exit 1
fi
