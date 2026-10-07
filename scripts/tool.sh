#!/usr/bin/env bash
# Run a lint tool: the local binary if it is on PATH, otherwise its pinned Docker image.
# This keeps Docker the only hard requirement for "make lint".
#   scripts/tool.sh <kubeconform|promtool|shellcheck|terraform|tflint> [args...]
# Paths must be inside the repo; the repo is mounted at /work in the container.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tool="${1:-}"
[[ -n "$tool" ]] || die "usage: $0 <tool> [args...]"
shift

if command -v "$tool" >/dev/null 2>&1; then
  exec "$tool" "$@"
fi

entrypoint=()
env_args=()
case "$tool" in
  kubeconform) image="ghcr.io/yannh/kubeconform:${KUBECONFORM_VERSION}" ;;
  promtool)
    image="quay.io/prometheus/prometheus:${PROMETHEUS_VERSION}"
    entrypoint=(--entrypoint /bin/promtool) ;;
  shellcheck) image="docker.io/koalaman/shellcheck:${SHELLCHECK_VERSION}" ;;
  terraform)
    image="docker.io/hashicorp/terraform:${TERRAFORM_VERSION}"
    env_args=(-e HOME=/tmp -e TF_IN_AUTOMATION=1) ;;
  tflint)
    image="ghcr.io/terraform-linters/tflint:${TFLINT_VERSION}"
    # Keep downloaded tflint plugins between runs, in the gitignored .bin/ folder.
    env_args=(-e HOME=/tmp -e TFLINT_PLUGIN_DIR=/work/.bin/tflint-plugins)
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then env_args+=(-e GITHUB_TOKEN); fi
    mkdir -p "$REPO_ROOT/.bin/tflint-plugins" ;;
  *) die "$tool is not installed and has no Docker fallback" ;;
esac

# Keep relative paths working: run in the same sub-directory of the repo as the caller.
workdir="/work"
if [[ "$PWD" == "$REPO_ROOT" || "$PWD" == "$REPO_ROOT"/* ]]; then
  workdir="/work${PWD#"$REPO_ROOT"}"
fi

echo "($tool not installed locally; using $image)" >&2
exec docker run --rm -i \
  -v "$REPO_ROOT:/work" -w "$workdir" \
  --user "$(id -u):$(id -g)" \
  ${env_args[@]+"${env_args[@]}"} \
  ${entrypoint[@]+"${entrypoint[@]}"} \
  "$image" "$@"
