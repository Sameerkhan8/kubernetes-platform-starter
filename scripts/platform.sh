#!/usr/bin/env bash
# Install the platform components into the local kind cluster.
#   scripts/platform.sh gateway-api-crds   Gateway API CRDs (standard channel)
#   scripts/platform.sh metrics-server     metrics-server (CPU/memory metrics for the HPA)
#   scripts/platform.sh monitoring         kube-prometheus-stack + Grafana admin Secret + platform alerts
#   scripts/platform.sh gateway            Traefik (Gateway API controller)
#   scripts/platform.sh argocd             Argo CD
#
# Charts are installed straight from their repo URL with a pinned version (versions.env).
# There is no "helm repo add", so your global Helm config is not changed.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

kps_guard

# helm_install <release> <chart> <repo-url> <version> <namespace> <values-file> [extra helm args...]
helm_install() {
  local release="$1" chart="$2" repo="$3" version="$4" ns="$5" values="$6"
  shift 6
  log "Installing $chart $version (release '$release', namespace '$ns')"
  # --hide-notes: the upstream chart notes print kubectl commands without --context (and
  # Secret names this repo does not use). "make urls" and "make creds" show access instead.
  helm_kps upgrade --install "$release" "$chart" \
    --repo "$repo" --version "$version" \
    --namespace "$ns" --create-namespace \
    -f "$REPO_ROOT/$values" \
    --hide-notes \
    --wait --timeout 10m "$@"
}

ensure_namespace() {
  kubectl_kps create namespace "$1" --dry-run=client -o yaml | kubectl_kps apply -f - >/dev/null
}

gateway_api_crds() {
  local url="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
  log "Installing Gateway API CRDs ${GATEWAY_API_VERSION} (standard channel)"
  kubectl_kps apply --server-side -f "$url"
  kubectl_kps wait --for=condition=Established --timeout=120s \
    crd/gatewayclasses.gateway.networking.k8s.io \
    crd/gateways.gateway.networking.k8s.io \
    crd/httproutes.gateway.networking.k8s.io
}

metrics_server() {
  helm_install metrics-server metrics-server https://kubernetes-sigs.github.io/metrics-server/ \
    "$METRICS_SERVER_CHART_VERSION" kube-system platform/metrics-server/values.yaml
  log "Waiting for the metrics API (used by the HPA)"
  kubectl_kps wait --for=condition=Available --timeout=180s apiservice/v1beta1.metrics.k8s.io
}

# Create the Grafana admin Secret once, with a random password. "kubectl create" (not apply)
# so the password is not copied into a last-applied-configuration annotation.
ensure_grafana_secret() {
  if kubectl_kps -n monitoring get secret grafana-admin >/dev/null 2>&1; then
    info "Secret monitoring/grafana-admin already exists, keeping it"
    return
  fi
  local password
  password="$(gen_password)"
  [[ ${#password} -ge 20 ]] || die "could not generate a Grafana password"
  kubectl_kps create -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin
  namespace: monitoring
  labels:
    app.kubernetes.io/part-of: kubernetes-platform-starter
type: Opaque
stringData:
  admin-user: admin
  admin-password: "${password}"
EOF
  info "Created Secret monitoring/grafana-admin with a random password (run 'make creds' to see it)"
}

# monitoring/rules/platform.rules.yaml is a plain Prometheus rule file (so promtool can test it).
# Wrap it into a PrometheusRule object at apply time.
apply_platform_rules() {
  log "Applying the platform alert rules (monitoring/rules/platform.rules.yaml)"
  {
    printf 'apiVersion: monitoring.coreos.com/v1\nkind: PrometheusRule\nmetadata:\n  name: kps-platform-alerts\n  namespace: monitoring\n  labels:\n    app.kubernetes.io/part-of: kubernetes-platform-starter\nspec:\n'
    sed 's/^/  /' "$REPO_ROOT/monitoring/rules/platform.rules.yaml"
  } | kubectl_kps apply -f -
}

monitoring() {
  ensure_namespace monitoring
  ensure_grafana_secret
  local extra=()
  if [[ "$HOST_HTTP_PORT" != "80" ]]; then
    extra+=(--set "prometheus.prometheusSpec.externalUrl=$(url_for prometheus)")
    extra+=(--set "alertmanager.alertmanagerSpec.externalUrl=$(url_for alertmanager)")
    extra+=(--set "grafana.grafana\.ini.server.root_url=$(url_for grafana)")
  fi
  helm_install kube-prometheus-stack kube-prometheus-stack https://prometheus-community.github.io/helm-charts \
    "$KUBE_PROMETHEUS_STACK_CHART_VERSION" monitoring platform/kube-prometheus-stack/values.yaml \
    ${extra[@]+"${extra[@]}"}
  apply_platform_rules
}

gateway() {
  helm_install traefik traefik https://traefik.github.io/charts \
    "$TRAEFIK_CHART_VERSION" traefik platform/traefik/values.yaml
  log "Waiting for Gateway traefik/traefik-gateway to be Programmed"
  if ! kubectl_kps -n traefik wait --for=condition=Programmed --timeout=180s gateway/traefik-gateway; then
    kubectl_kps -n traefik get gateway traefik-gateway \
      -o jsonpath='{range .status.conditions[*]}  {.type}={.status} ({.reason}): {.message}{"\n"}{end}' || true
    die "Gateway traefik-gateway is not Programmed. Check: KUBECONFIG=$KUBECONFIG kubectl --context kind-kps -n traefik logs deploy/traefik"
  fi
}

argocd() {
  local extra=()
  if [[ "$HOST_HTTP_PORT" != "80" ]]; then
    extra+=(--set "configs.cm.url=$(url_for argocd)")
  fi
  helm_install argocd argo-cd https://argoproj.github.io/argo-helm \
    "$ARGOCD_CHART_VERSION" argocd platform/argocd/values.yaml \
    ${extra[@]+"${extra[@]}"}
}

case "${1:-}" in
  gateway-api-crds) gateway_api_crds ;;
  metrics-server) metrics_server ;;
  monitoring) monitoring ;;
  gateway) gateway ;;
  argocd) argocd ;;
  *) die "usage: $0 gateway-api-crds|metrics-server|monitoring|gateway|argocd" ;;
esac
