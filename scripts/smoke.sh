#!/usr/bin/env bash
# Smoke test: call every public endpoint through the local gateway, like a browser would.
# Prints PASS/FAIL per check and exits non-zero if any check fails.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

kps_guard

passed=0
failed=0
body="$(mktemp)"
trap 'rm -f "$body"' EXIT

# check <name> <path> <expected-status> [regex the body must match] [description]
check() {
  local name="$1" path="$2" want="$3" pattern="${4:-}" what="${5:-}" code attempt
  for attempt in 1 2 3; do
    code="$(gw_curl "$name" "$path" -o "$body" -w '%{http_code}' 2>/dev/null || true)"
    code="${code:-000}"
    if [[ "$code" == "$want" ]] && { [[ -z "$pattern" ]] || grep -Eq "$pattern" "$body"; }; then
      printf '  PASS  %-36s %s %s\n' "${name}.localtest.me${path}" "$code" "$what"
      passed=$((passed + 1))
      return 0
    fi
    [[ "$attempt" -lt 3 ]] && sleep 2
  done
  printf '  FAIL  %-36s got %s, want %s %s\n' "${name}.localtest.me${path}" "$code" "$want" "$what"
  failed=$((failed + 1))
}

log "Smoke test through the gateway ($(url_for app) and friends)"
check app          /         200 '"service" *: *"sample-api"'  '(JSON field service)'
check app          /healthz  200
check app          /readyz   200
check app          /metrics  200 'http_requests_total'         '(contains http_requests_total)'
check grafana      /api/health 200
check prometheus   /-/ready  200
check alertmanager /-/ready  200
check argocd       /healthz  200

echo
echo "smoke: $passed passed, $failed failed"
if ((failed > 0)); then
  echo "Hints: make status; KUBECONFIG=$KUBECONFIG kubectl --context kind-kps get httproutes -A" >&2
  exit 1
fi
