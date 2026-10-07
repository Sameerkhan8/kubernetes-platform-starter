#!/usr/bin/env bash
# Static checks. None of them talk to a cluster.
#   scripts/lint.sh helm    helm lint --strict (default values + each environment file)
#   scripts/lint.sh k8s     kubeconform on the rendered chart and the Argo CD manifests
#   scripts/lint.sh rules   promtool check + unit tests for all alert rules
#   scripts/lint.sh tf      terraform fmt/validate/test + tflint (no backend, no cloud access)
#   scripts/lint.sh sh      shellcheck + "no bare kubectl/helm outside lib.sh"
#   scripts/lint.sh all     everything above
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd "$REPO_ROOT"
TOOL="$REPO_ROOT/scripts/tool.sh"
CHART="charts/sample-api"
ENV_FILES=(values-dev.yaml values-prod.yaml values-local.yaml)

lint_helm() {
  command -v helm >/dev/null 2>&1 || die "helm not found"
  log "helm lint --strict $CHART (default values)"
  helm_kps lint "$CHART" --strict
  local f
  for f in "${ENV_FILES[@]}"; do
    log "helm lint --strict $CHART -f $f"
    helm_kps lint "$CHART" --strict -f "$CHART/$f"
  done
}

lint_k8s() {
  command -v helm >/dev/null 2>&1 || die "helm not found"
  local args=(
    -strict -summary
    -kubernetes-version "$KUBERNETES_VERSION"
    -schema-location default
    -schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/${CRDS_CATALOG_REF}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
  )
  local f values
  for f in "" "${ENV_FILES[@]}"; do
    values=()
    [[ -n "$f" ]] && values=(-f "$CHART/$f")
    log "kubeconform: helm template $CHART ${f:-(default values)}"
    helm_kps template sample-api "$CHART" --namespace demo --kube-version "$KUBERNETES_VERSION" \
      ${values[@]+"${values[@]}"} | "$TOOL" kubeconform "${args[@]}"
  done
  log "kubeconform: gitops/ manifests"
  "$TOOL" kubeconform "${args[@]}" gitops/projects/*.yaml gitops/applications/*.yaml

  log "kind/cluster.yaml uses KIND_NODE_IMAGE from versions.env"
  local n_total n_match
  n_total="$(grep -cE '^ +image: ' kind/cluster.yaml)"
  n_match="$(grep -cF "image: ${KIND_NODE_IMAGE}" kind/cluster.yaml)"
  [[ "$n_total" -gt 0 && "$n_total" == "$n_match" ]] \
    || die "kind/cluster.yaml node images do not all match KIND_NODE_IMAGE=$KIND_NODE_IMAGE"
  info "OK ($n_match nodes)"
}

lint_rules() {
  log "promtool check rules"
  "$TOOL" promtool check rules charts/sample-api/rules/sample-api.rules.yaml monitoring/rules/platform.rules.yaml
  log "promtool test rules (alert unit tests)"
  "$TOOL" promtool test rules monitoring/tests/*.test.yaml
  log "every alert has a runbook in docs/runbooks/"
  local alert missing=0
  while read -r alert; do
    if [[ ! -f "docs/runbooks/${alert}.md" ]]; then
      warn "missing runbook: docs/runbooks/${alert}.md"
      missing=1
    fi
  done < <(sed -nE 's/^ *- alert: *([A-Za-z0-9_]+).*/\1/p' charts/sample-api/rules/sample-api.rules.yaml monitoring/rules/platform.rules.yaml)
  ((missing == 0)) || die "some alerts have no runbook"
  info "OK"
}

lint_tf() {
  local dir="terraform/gcp-gke"
  log "terraform fmt -check -recursive terraform/"
  "$TOOL" terraform fmt -check -recursive terraform/
  log "terraform init -backend=false + validate ($dir)"
  "$TOOL" terraform -chdir="$dir" init -backend=false -input=false >/dev/null
  "$TOOL" terraform -chdir="$dir" validate -no-color
  log "terraform test ($dir, mocked provider: no credentials, nothing is created)"
  "$TOOL" terraform -chdir="$dir" test -no-color
  log "tflint ($dir)"
  "$TOOL" tflint --chdir="$dir" --init >/dev/null
  "$TOOL" tflint --chdir="$dir"
}

lint_sh() {
  log "shellcheck scripts/*.sh"
  "$TOOL" shellcheck scripts/*.sh
  log "scripts call kubectl/helm only through kubectl_kps/helm_kps (lib.sh)"
  # lib.sh and guard-context.sh are the only files allowed to call them directly.
  local files=() f
  for f in scripts/*.sh; do
    case "$f" in scripts/lib.sh|scripts/guard-context.sh) ;; *) files+=("$f") ;; esac
  done
  awk -f scripts/no-bare-cli.awk "${files[@]}" \
    || die "use kubectl_kps / helm_kps from scripts/lib.sh instead of bare kubectl / helm"
  info "OK"
}

case "${1:-all}" in
  helm) lint_helm ;;
  k8s) lint_k8s ;;
  rules) lint_rules ;;
  tf) lint_tf ;;
  sh) lint_sh ;;
  all) lint_helm; lint_k8s; lint_rules; lint_tf; lint_sh ;;
  *) die "usage: $0 helm|k8s|rules|tf|sh|all" ;;
esac
