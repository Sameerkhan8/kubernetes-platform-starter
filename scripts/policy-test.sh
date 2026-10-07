#!/usr/bin/env bash
# Check the security policies on the running cluster, with throwaway pods:
#   1. NetworkPolicy, ingress: a pod in namespace "default" cannot reach sample-api.
#   2. NetworkPolicy, egress:  a pod in "demo" can resolve DNS but cannot open other connections.
#   3. NetworkPolicy, allow:   a load-generator pod in "demo" reaches the app through the gateway.
#   4. Pod Security:           the "demo" namespace rejects a privileged pod (server-side dry run).
# Prints PASS/FAIL per check and exits non-zero if any check fails.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

kps_guard
require_app

IMAGE_REF="$(app_image)"
PULL="$(app_pull_policy)"
PROBE_TIMEOUT=5
passed=0
failed=0

result() {
  local ok="$1" what="$2" detail="$3"
  if [[ "$ok" == 1 ]]; then
    printf '  PASS  %-58s %s\n' "$what" "$detail"
    passed=$((passed + 1))
  else
    printf '  FAIL  %-58s %s\n' "$what" "$detail"
    failed=$((failed + 1))
  fi
}

# probe <namespace> <pod-name> <app-label> <url> [host-header]
# Runs a short-lived pod (Pod Security "restricted" compatible) that tries one HTTP request
# and prints DNS=ok|fail and then CONNECTED <status> or BLOCKED <reason>.
probe() {
  local ns="$1" name="$2" label="$3" url="$4" host="${5:-}" phase="" i
  kubectl_kps -n "$ns" delete pod "$name" --ignore-not-found --wait=true >/dev/null
  kubectl_kps apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    app.kubernetes.io/name: ${label}
    app.kubernetes.io/part-of: kubernetes-platform-starter
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  enableServiceLinks: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      image: ${IMAGE_REF}
      imagePullPolicy: ${PULL}
      env:
        - name: URL
          value: "${url}"
        - name: HOST_HEADER
          value: "${host}"
        - name: TIMEOUT
          value: "${PROBE_TIMEOUT}"
      command:
        - python
        - -c
        - |
          import os, socket, urllib.error, urllib.parse, urllib.request
          url, host, timeout = os.environ["URL"], os.environ["HOST_HEADER"], float(os.environ["TIMEOUT"])
          try:
              socket.getaddrinfo(urllib.parse.urlsplit(url).hostname, 80)
              print("DNS=ok")
          except OSError:
              print("DNS=fail")
          request = urllib.request.Request(url, headers={"Host": host} if host else {})
          try:
              with urllib.request.urlopen(request, timeout=timeout) as response:
                  print("CONNECTED", response.status)
          except urllib.error.HTTPError as exc:
              print("CONNECTED", exc.code)
          except urllib.error.URLError as exc:
              print("BLOCKED", exc.reason)
          except Exception as exc:
              print("BLOCKED", type(exc).__name__, exc)
      resources:
        requests:
          cpu: 10m
          memory: 32Mi
        limits:
          cpu: 200m
          memory: 64Mi
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
EOF
  for ((i = 0; i < 60; i++)); do
    phase="$(kubectl_kps -n "$ns" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
    sleep 1
  done
  kubectl_kps -n "$ns" logs "$name" 2>/dev/null || echo "NO-OUTPUT phase=${phase:-unknown}"
  kubectl_kps -n "$ns" delete pod "$name" --ignore-not-found --wait=false >/dev/null
}

app_svc="http://${KPS_APP_NAME}.${KPS_APP_NS}.svc.cluster.local/healthz"

log "NetworkPolicy and Pod Security checks (throwaway pods, image $IMAGE_REF)"

# A NetworkPolicy drops the packets, so a blocked call times out. "Connection refused"
# would mean something else (for example no ready pods), so it does not count as a pass.
out="$(probe default kps-policy-test-ingress kps-policy-test "$app_svc")"
if grep -q '^BLOCKED timed out' <<<"$out"; then ok=1; else ok=0; fi
result "$ok" "ingress: pod in 'default' -> sample-api is blocked" "$(grep -E '^(CONNECTED|BLOCKED|NO-OUTPUT)' <<<"$out" | head -n 1)"

out="$(probe "$KPS_APP_NS" kps-policy-test-egress kps-policy-test "$KPS_GATEWAY_URL/healthz" "$KPS_APP_HOST")"
if grep -q '^DNS=ok' <<<"$out" && grep -q '^BLOCKED timed out' <<<"$out"; then ok=1; else ok=0; fi
result "$ok" "egress: pod in '$KPS_APP_NS' resolves DNS, other traffic blocked" "$(tr '\n' ' ' <<<"$out")"

loadgen_egress_policy
out="$(probe "$KPS_APP_NS" kps-policy-test-allow kps-loadgen "$KPS_GATEWAY_URL/healthz" "$KPS_APP_HOST")"
if grep -q '^CONNECTED 200' <<<"$out"; then ok=1; else ok=0; fi
result "$ok" "allow: load-generator pod -> gateway -> sample-api works" "$(grep -E '^(CONNECTED|BLOCKED|NO-OUTPUT)' <<<"$out" | head -n 1)"

psa_out="$(kubectl_kps -n "$KPS_APP_NS" apply --dry-run=server -f - 2>&1 <<EOF || true
apiVersion: v1
kind: Pod
metadata:
  name: kps-policy-test-privileged
spec:
  containers:
    - name: c
      image: ${IMAGE_REF}
      securityContext:
        privileged: true
EOF
)"
if grep -q 'violates PodSecurity "restricted' <<<"$psa_out"; then ok=1; else ok=0; fi
result "$ok" "Pod Security: '$KPS_APP_NS' rejects a privileged pod" "$(grep -o 'violates PodSecurity "[^"]*"' <<<"$psa_out" | head -n 1)"

echo
echo "policy-test: $passed passed, $failed failed"
((failed == 0))
