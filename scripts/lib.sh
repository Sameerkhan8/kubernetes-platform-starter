# shellcheck shell=bash
# shellcheck disable=SC2034  # the KPS_* constants are used by the scripts that source this file
# Shared helpers for scripts/*.sh. Source it; do not run it.
#
# Safety model:
#   - KUBECONFIG always points at the repo-local .kube/config (set below, unconditionally).
#   - kubectl_kps and helm_kps are the only way the scripts call kubectl and helm.
#     They pin --context kind-kps / --kube-context kind-kps on every call.
#   - kps_guard aborts unless the current context is kind-kps and its API server is local.
# A bare "kubectl" or "helm" is allowed only in this file and in guard-context.sh
# ("make lint-sh" checks this).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
export KUBECONFIG="$REPO_ROOT/.kube/config"
# Helm reads these from the environment, and they override the API server and credentials
# even when --kube-context is passed. Clear them so helm only ever uses the kubeconfig above.
unset HELM_KUBEAPISERVER HELM_KUBETOKEN HELM_KUBECAFILE HELM_KUBEINSECURE_SKIP_TLS_VERIFY \
  HELM_KUBEASUSER HELM_KUBEASGROUPS HELM_KUBETLS_SERVER_NAME HELM_KUBECONTEXT

KPS_CLUSTER_NAME="kps"
KPS_CONTEXT="kind-kps"
KPS_GITHUB_REPO_URL="https://github.com/Sameerkhan8/kubernetes-platform-starter.git"
# In-cluster address of the Traefik gateway. Load Jobs send traffic here with a Host header,
# so they test the same path as a browser (gateway -> HTTPRoute -> pod).
KPS_GATEWAY_URL="http://traefik.traefik.svc.cluster.local"
KPS_APP_HOST="app.localtest.me"
KPS_APP_NS="demo"
KPS_APP_NAME="sample-api"

# Pinned versions (KEY=value lines, see versions.env).
set -a
# shellcheck source=../versions.env
. "$REPO_ROOT/versions.env"
set +a

: "${IMAGE:=sample-api:dev}"
: "${IMAGE_SOURCE:=local}"
: "${REPO_URL:=}"

# ---------------------------------------------------------------- output helpers

log()  { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- gateway ports on this laptop

# kind_host_port <container-port> -> the 127.0.0.1 host port the running kind cluster maps it to
# (empty if the cluster does not exist). Read-only "docker port"; no cluster API call.
kind_host_port() {
  command -v docker >/dev/null 2>&1 || return 0
  # "|| true": no cluster is a normal case, and set -e/pipefail must not end the caller.
  docker port "${KPS_CLUSTER_NAME}-control-plane" "$1/tcp" 2>/dev/null \
    | sed -nE 's/^127\.0\.0\.1:([0-9]+)$/\1/p' | head -n 1 || true
}

# port_in_use <port>: true if something on this laptop listens on that TCP port.
# Returns false when neither ss nor lsof is installed (the check is then skipped).
port_in_use() {
  if command -v ss >/dev/null 2>&1; then
    [[ -n "$(ss -ltnH "sport = :$1" 2>/dev/null || true)" ]]
  elif command -v lsof >/dev/null 2>&1; then
    [[ -n "$(lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null || true)" ]]
  else
    return 1
  fi
}

# An explicit HOST_HTTP_PORT / HOST_HTTPS_PORT wins. If it is not set and the cluster exists,
# use the ports the cluster was created with, so "HOST_HTTP_PORT=8080 make up" followed by a
# plain "make smoke" still works. Otherwise use 80 / 443.
kps_set_port() {
  local var="$1" container_port="$2" default="$3" detected
  detected="$(kind_host_port "$container_port")"
  if [[ -z "${!var:-}" ]]; then
    printf -v "$var" '%s' "${detected:-$default}"
  elif [[ -n "$detected" && "$detected" != "${!var}" ]]; then
    warn "$var=${!var}, but cluster '$KPS_CLUSTER_NAME' maps port $container_port to $detected. Using $detected."
    printf -v "$var" '%s' "$detected"
  fi
}
KPS_HTTPS_PORT_FALLBACK=0
if [[ -z "${HOST_HTTPS_PORT:-}" && -z "$(kind_host_port 443)" ]] && port_in_use 443; then
  # Nothing serves HTTPS yet (there is no TLS listener), so a busy 443 (a local proxy or VPN
  # tool) must not block "make up". Map the unused HTTPS port to 8443 instead.
  HOST_HTTPS_PORT=8443
  KPS_HTTPS_PORT_FALLBACK=1
fi
kps_set_port HOST_HTTP_PORT 80 80
kps_set_port HOST_HTTPS_PORT 443 443
export HOST_HTTP_PORT HOST_HTTPS_PORT IMAGE IMAGE_SOURCE REPO_URL

# ---------------------------------------------------------------- cluster access

# Abort unless kubectl points at the local kind cluster. Same checks as guard-context.sh
# (it runs that script, so there is only one implementation to review).
kps_guard() {
  "$REPO_ROOT/scripts/guard-context.sh"
}

kubectl_kps() { command kubectl --context "$KPS_CONTEXT" "$@"; }
helm_kps()    { command helm --kube-context "$KPS_CONTEXT" "$@"; }

# Read-only helpers that never talk to a cluster.
kubectl_current_context() { command kubectl config current-context 2>/dev/null || true; }
kubectl_client_version()  { command kubectl version --client 2>/dev/null | sed -n 's/^Client Version: //p'; }
helm_client_version()     { command helm version --template '{{.Version}}' 2>/dev/null || true; }

# ---------------------------------------------------------------- URLs and the local gateway

# url_for <name> -> http://<name>.localtest.me[:port]
url_for() {
  if [[ "$HOST_HTTP_PORT" == "80" ]]; then
    printf 'http://%s.localtest.me\n' "$1"
  else
    printf 'http://%s.localtest.me:%s\n' "$1" "$HOST_HTTP_PORT"
  fi
}

# gw_curl <name> <path> [curl args...]
# curl through the local gateway. --resolve pins <name>.localtest.me to 127.0.0.1,
# so the scripts never depend on public DNS.
gw_curl() {
  local name="$1" path="$2"
  shift 2
  curl --silent --show-error --max-time 10 \
    --resolve "${name}.localtest.me:${HOST_HTTP_PORT}:127.0.0.1" \
    "$@" "$(url_for "$name")${path}"
}

# Random 24-character alphanumeric password. Never echoed by the scripts.
gen_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-24
  else
    head -c 48 /dev/urandom | base64 | tr -d '/+=\n' | cut -c1-24
  fi
}

# ---------------------------------------------------------------- sample-api helpers

require_app() {
  kubectl_kps -n "$KPS_APP_NS" get deployment "$KPS_APP_NAME" >/dev/null 2>&1 \
    || die "Deployment $KPS_APP_NS/$KPS_APP_NAME not found. Run 'make app' (or 'make up') first."
}

# The load generator ships inside the sample-api image (python -m sample_api.loadgen).
# Use exactly the image and pull policy the running Deployment uses, so the Job works in
# both local mode (sample-api:dev, pullPolicy Never) and GHCR mode.
app_image() {
  local img
  img="$(kubectl_kps -n "$KPS_APP_NS" get deployment "$KPS_APP_NAME" \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="sample-api")].image}' 2>/dev/null || true)"
  printf '%s\n' "${img:-$IMAGE}"
}

app_pull_policy() {
  local policy
  policy="$(kubectl_kps -n "$KPS_APP_NS" get deployment "$KPS_APP_NAME" \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="sample-api")].imagePullPolicy}' 2>/dev/null || true)"
  if [[ -z "$policy" ]]; then
    if [[ "$IMAGE_SOURCE" == "local" ]]; then policy="Never"; else policy="IfNotPresent"; fi
  fi
  printf '%s\n' "$policy"
}

# ---------------------------------------------------------------- load generator Jobs

yaml_quote() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# The chart denies all egress in the app namespace except DNS. Load Jobs (label
# app.kubernetes.io/name=kps-loadgen) may also call the gateway, and nothing else.
# Traefik's "web" entrypoint listens on container port 8000.
loadgen_egress_policy() {
  kubectl_kps apply -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: kps-loadgen-egress
  namespace: ${KPS_APP_NS}
  labels:
    app.kubernetes.io/name: kps-loadgen
    app.kubernetes.io/part-of: kubernetes-platform-starter
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: kps-loadgen
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: traefik
      ports:
        - port: 8000
          protocol: TCP
EOF
}

# loadgen_job_start <job-name> <loadgen args...>
# (Re)creates a Job in the demo namespace that runs "python -m sample_api.loadgen <args>".
# The pod passes Pod Security "restricted" (same securityContext as the chart).
loadgen_job_start() {
  local name="$1"
  shift
  local image pull cmd="" arg
  image="$(app_image)"
  pull="$(app_pull_policy)"
  for arg in python -m sample_api.loadgen "$@"; do
    cmd+="$(yaml_quote "$arg"), "
  done
  cmd="[${cmd%, }]"

  kubectl_kps -n "$KPS_APP_NS" delete job "$name" --ignore-not-found --wait=true >/dev/null
  loadgen_egress_policy
  kubectl_kps apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${name}
  namespace: ${KPS_APP_NS}
  labels:
    app.kubernetes.io/name: kps-loadgen
    app.kubernetes.io/part-of: kubernetes-platform-starter
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: kps-loadgen
        app.kubernetes.io/part-of: kubernetes-platform-starter
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      enableServiceLinks: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: loadgen
          image: ${image}
          imagePullPolicy: ${pull}
          command: ${cmd}
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir:
            sizeLimit: 16Mi
EOF
  info "Job $KPS_APP_NS/$name started (image $image)"
}

# job_state <job-name> -> running | succeeded | failed
job_state() {
  local s
  s="$(kubectl_kps -n "$KPS_APP_NS" get job "$1" -o jsonpath='{.status.succeeded}/{.status.failed}' 2>/dev/null || true)"
  case "$s" in
    [1-9]*/*) echo succeeded ;;
    */[1-9]*) echo failed ;;
    *) echo running ;;
  esac
}

# job_wait_started <job-name> <timeout-seconds>: wait until the Job's pod is Running (or done).
job_wait_started() {
  local name="$1" timeout="$2" phase deadline
  deadline=$((SECONDS + timeout))
  while ((SECONDS < deadline)); do
    phase="$(kubectl_kps -n "$KPS_APP_NS" get pods -l "batch.kubernetes.io/job-name=$name" \
      -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
    case "$phase" in
      Running|Succeeded|Failed) return 0 ;;
    esac
    sleep 2
  done
  warn "Job $name did not start within ${timeout}s."
  kubectl_kps -n "$KPS_APP_NS" get pods -l "batch.kubernetes.io/job-name=$name" -o wide || true
  return 1
}

job_logs() {
  kubectl_kps -n "$KPS_APP_NS" logs "job/$1" --tail=-1 2>/dev/null || true
}

# job_result <job-name> -> the JSON after "RESULT " in the loadgen output (empty if missing)
job_result() {
  job_logs "$1" | sed -n 's/^RESULT //p' | tail -n 1
}

# json_number <key> <json> -> top-level numeric field (enough for the flat RESULT line)
json_number() {
  printf '%s\n' "$2" | sed -nE "s/.*\"$1\": *([0-9.]+).*/\1/p"
}

# Pretty-print JSON from stdin with whatever is installed.
json_pretty() {
  if command -v jq >/dev/null 2>&1; then
    jq .
  elif command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool
  else
    cat
    echo
  fi
}
