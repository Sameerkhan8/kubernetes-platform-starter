#!/usr/bin/env bash
# HPA demo: run an in-cluster load Job against /work (CPU burn) through the gateway,
# and print the autoscaler and pod count every 15 seconds while it runs.
#   LOAD_DURATION     seconds of load (default 180; use 420 to also fire SampleApiHpaMaxedOut)
#   LOAD_CONCURRENCY  parallel workers in the load Job (default 8)
#   WORK_MS           CPU milliseconds burned per request (default 100)
#   WAIT_SCALE_DOWN=1 keep watching after the load until the HPA is back at its minimum
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

kps_guard
require_app

LOAD_DURATION="${LOAD_DURATION:-180}"
LOAD_CONCURRENCY="${LOAD_CONCURRENCY:-8}"
WORK_MS="${WORK_MS:-100}"
JOB="kps-load"
for v in LOAD_DURATION LOAD_CONCURRENCY WORK_MS; do
  [[ "${!v}" =~ ^[1-9][0-9]*$ ]] || die "$v must be a positive whole number (got '${!v}')"
done

hpa_line() {
  local s pods cur="" desired="" cpu="" target="" max=""
  s="$(kubectl_kps -n "$KPS_APP_NS" get hpa "$KPS_APP_NAME" -o jsonpath='{.status.currentReplicas}|{.status.desiredReplicas}|{.status.currentMetrics[0].resource.current.averageUtilization}|{.spec.metrics[0].resource.target.averageUtilization}|{.spec.maxReplicas}' 2>/dev/null || true)"
  IFS='|' read -r cur desired cpu target max <<<"$s" || true
  pods="$(kubectl_kps -n "$KPS_APP_NS" get pods -l app.kubernetes.io/name=sample-api \
    --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  printf 'hpa replicas=%s desired=%s (max %s)  cpu=%s%% (target %s%%)  running pods=%s' \
    "${cur:-?}" "${desired:-?}" "${max:-?}" "${cpu:-?}" "${target:-?}" "$pods"
}

log "Starting load: ${LOAD_DURATION}s, concurrency ${LOAD_CONCURRENCY}, /work?ms=${WORK_MS} via ${KPS_GATEWAY_URL} (Host: ${KPS_APP_HOST})"
info "before: $(hpa_line)"
loadgen_job_start "$JOB" \
  --url "${KPS_GATEWAY_URL}/work?ms=${WORK_MS}" \
  --host "$KPS_APP_HOST" \
  --duration "$LOAD_DURATION" \
  --concurrency "$LOAD_CONCURRENCY"
job_wait_started "$JOB" 120 || die "load Job did not start"

start=$SECONDS
peak=0
deadline=$((start + LOAD_DURATION + 180))
while [[ "$(job_state "$JOB")" == "running" ]]; do
  if ((SECONDS > deadline)); then
    die "load Job still running after $((SECONDS - start))s. Check: KUBECONFIG=$KUBECONFIG kubectl --context kind-kps -n demo logs job/$JOB"
  fi
  sleep 15
  line="$(hpa_line)"
  cur="$(sed -nE 's/^hpa replicas=([0-9]+).*/\1/p' <<<"$line")"
  if [[ -n "$cur" ]] && ((cur > peak)); then peak=$cur; fi
  info "t=$((SECONDS - start))s  $line"
done

result="$(job_result "$JOB")"
echo
log "Load generator output"
job_logs "$JOB" | sed 's/^/    /'
echo
if [[ "$(job_state "$JOB")" != "succeeded" || -z "$result" ]]; then
  die "load Job failed. Check: KUBECONFIG=$KUBECONFIG kubectl --context kind-kps -n demo describe job/$JOB"
fi
log "Peak HPA replicas seen: $peak"

if [[ "${WAIT_SCALE_DOWN:-0}" == "1" ]]; then
  min="$(kubectl_kps -n "$KPS_APP_NS" get hpa "$KPS_APP_NAME" -o jsonpath='{.spec.minReplicas}')"
  log "Waiting for the HPA to scale back to $min (up to 8 minutes)"
  start=$SECONDS
  while ((SECONDS - start < 480)); do
    line="$(hpa_line)"
    info "t=$((SECONDS - start))s  $line"
    cur="$(sed -nE 's/^hpa replicas=([0-9]+).*/\1/p' <<<"$line")"
    [[ "$cur" == "$min" ]] && { log "Back at $min replicas after $((SECONDS - start))s"; exit 0; }
    sleep 15
  done
  warn "HPA did not reach $min replicas within 8 minutes"
  exit 1
fi

info "Scale-down is slower on purpose: the HPA waits 120s (stabilization window), then removes"
info "at most 50% of the pods per minute. Expect about 2-3 minutes back to the minimum. Watch it with:"
info "  KUBECONFIG=$KUBECONFIG kubectl --context kind-kps -n demo get hpa sample-api -w"
