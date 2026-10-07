#!/usr/bin/env bash
# Alerting demo: inject 5xx errors through the gateway until SampleApiHighErrorRate fires,
# then show the alert as Alertmanager received it (labels, annotations, runbook link).
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

kps_guard
require_app

JOB="kps-alert-demo"
ALERT="SampleApiHighErrorRate"
TIMEOUT=480

cleanup() {
  kubectl_kps -n "$KPS_APP_NS" delete job "$JOB" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap 'cleanup; exit 130' INT TERM

# prom_query <promql> -> raw JSON from the Prometheus HTTP API (through the gateway)
prom_query() {
  gw_curl prometheus /api/v1/query -G --data-urlencode "query=$1" 2>/dev/null || true
}

log "Injecting errors: /error?rate=0.5 (half of the requests return 500), 2 workers x 5 req/s"
loadgen_job_start "$JOB" \
  --url "${KPS_GATEWAY_URL}/error?rate=0.5" \
  --host "$KPS_APP_HOST" \
  --duration 420 \
  --concurrency 2 \
  --rate 5
job_wait_started "$JOB" 120 || { cleanup; die "error-injection Job did not start"; }

log "Watching Prometheus until $ALERT is firing (rule: >5% 5xx over 5m, for 2m; usually about 3 minutes)"
start=$SECONDS
state="inactive"
while :; do
  ratio_json="$(prom_query 'sum(rate(http_requests_total{job="sample-api",status=~"5.."}[5m])) / sum(rate(http_requests_total{job="sample-api"}[5m]))')"
  ratio="$(sed -nE 's/.*"value":\[[0-9.]+,"([^"]+)"\].*/\1/p' <<<"$ratio_json")"
  alert_json="$(prom_query "ALERTS{alertname=\"$ALERT\"}")"
  state="inactive"
  grep -q '"alertstate":"pending"' <<<"$alert_json" && state="pending"
  grep -q '"alertstate":"firing"' <<<"$alert_json" && state="firing"
  if [[ -n "$ratio" && "$ratio" != "NaN" ]]; then
    ratio="$(awk -v r="$ratio" 'BEGIN { printf "%.1f%%", r * 100 }')"
  else
    ratio="n/a"
  fi
  info "t=$((SECONDS - start))s  5xx ratio (5m)=$ratio  alert=$state"
  [[ "$state" == "firing" ]] && break
  if ((SECONDS - start >= TIMEOUT)); then
    cleanup
    die "$ALERT did not fire within ${TIMEOUT}s. Check $(url_for prometheus)/alerts and $(url_for prometheus)/targets"
  fi
  sleep 15
done

log "$ALERT is firing after $((SECONDS - start))s. As received by Alertmanager:"
am_json=""
for _ in 1 2 3 4 5 6; do
  am_json="$(gw_curl alertmanager "/api/v2/alerts?filter=alertname%3D%22${ALERT}%22" 2>/dev/null || true)"
  grep -q "\"alertname\":\"$ALERT\"" <<<"$am_json" && break
  sleep 5
done
if command -v jq >/dev/null 2>&1; then
  jq '.[] | {status: .status.state, startsAt, labels, annotations}' <<<"$am_json" | sed 's/^/    /'
else
  json_pretty <<<"$am_json" | sed 's/^/    /'
fi

cleanup
echo
log "Stopped the error injection (Job $JOB deleted)."
info "Alertmanager:  $(url_for alertmanager)/#/alerts"
info "Prometheus:    $(url_for prometheus)/alerts"
info "Grafana:       $(url_for grafana) -> dashboard 'Sample API - Golden Signals' (Error ratio panel)"
info "The alert resolves by itself about 5 minutes from now, when the 5-minute rate window is clean again."
info "Locally, Alertmanager sends notifications nowhere (null receiver). Real setups route to Slack, Teams or PagerDuty."
