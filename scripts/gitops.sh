#!/usr/bin/env bash
# Deploy sample-api with Argo CD (GitOps).
#
#   scripts/gitops.sh local    (make gitops-local) Argo CD pulls from a git daemon container
#                              "kps-git" on the kind Docker network. Works before the repo is
#                              pushed anywhere, and offline.
#   scripts/gitops.sh remote   (make gitops REPO_URL=...) Argo CD pulls from REPO_URL,
#                              e.g. https://github.com/Sameerkhan8/kubernetes-platform-starter.git
#
# Local mode publishes this repo into a bare mirror in .gitops/ (gitignored):
#   - commit mode (default when this directory is a git repo with commits):
#       pushes HEAD to the mirror's main branch. Uncommitted changes are NOT deployed.
#   - snapshot mode (no commits yet, or GITOPS_SNAPSHOT=1):
#       writes the working tree into the mirror as a throwaway commit. The project's own
#       git history is never touched.
#
# Image source: IMAGE_SOURCE=local (default) adds values-local.yaml (image sample-api:dev,
# loaded with "make image"). IMAGE_SOURCE=ghcr uses the image in values-dev.yaml from GHCR
# (the GHCR package must be public, or you need an imagePullSecret).
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

kps_guard

MODE="${1:-}"
APP_NAME="sample-api-dev"
GITD_IMAGE="kps-gitd:local"
GITD_CONTAINER="kps-git"
MIRROR_NAME="kubernetes-platform-starter.git"
MIRROR="$REPO_ROOT/.gitops/$MIRROR_NAME"
WAIT_SECONDS="${GITOPS_WAIT_SECONDS:-300}"

repo_git() { git -c safe.directory="$REPO_ROOT" -C "$REPO_ROOT" "$@"; }

# ---------------------------------------------------------------- local mode helpers

publish_mirror() {
  mkdir -p "$REPO_ROOT/.gitops"
  if [[ ! -d "$MIRROR" ]]; then
    log "Creating the bare mirror $MIRROR"
    git init --bare --quiet --initial-branch=main "$MIRROR"
  fi
  # Local state that must never be published, even if .gitignore is missing or changed.
  mkdir -p "$MIRROR/info"
  printf '%s\n' '# Written by scripts/gitops.sh: local state that is never published.' \
    '/.kube/' '/.gitops/' '/.bin/' '.terraform/' '*.tfstate' '*.tfstate.*' '.env' '*.pem' '*.key' \
    >"$MIRROR/info/exclude"

  local top=""
  top="$(repo_git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ "${GITOPS_SNAPSHOT:-0}" != "1" && "$top" == "$REPO_ROOT" ]] && repo_git rev-parse --verify --quiet HEAD >/dev/null; then
    log "Publishing HEAD ($(repo_git rev-parse --short HEAD)) to the local mirror (commit mode)"
    if [[ -n "$(repo_git status --porcelain)" ]]; then
      warn "uncommitted changes are NOT deployed; commit them or use GITOPS_SNAPSHOT=1"
    fi
    repo_git push --force --quiet "$MIRROR" HEAD:refs/heads/main
  else
    log "Publishing the working tree to the local mirror (snapshot mode)"
    local idx tree parent="" commit
    idx="$(mktemp -u)"
    # $MIRROR/info/exclude (above) and the repo's .gitignore decide what is left out.
    GIT_DIR="$MIRROR" GIT_WORK_TREE="$REPO_ROOT" GIT_INDEX_FILE="$idx" \
      git -C "$REPO_ROOT" add -A -- .
    tree="$(GIT_DIR="$MIRROR" GIT_INDEX_FILE="$idx" git write-tree)"
    rm -f "$idx"
    parent="$(git --git-dir="$MIRROR" rev-parse --verify --quiet refs/heads/main || true)"
    if [[ -n "$parent" && "$(git --git-dir="$MIRROR" rev-parse "$parent^{tree}")" == "$tree" ]]; then
      info "no changes since the last snapshot ($(git --git-dir="$MIRROR" rev-parse --short "$parent"))"
    else
      commit="$(
        GIT_AUTHOR_NAME=kps-local-snapshot GIT_AUTHOR_EMAIL=kps-local@localhost \
        GIT_COMMITTER_NAME=kps-local-snapshot GIT_COMMITTER_EMAIL=kps-local@localhost \
        git --git-dir="$MIRROR" commit-tree "$tree" ${parent:+-p "$parent"} \
          -m "local snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      )"
      git --git-dir="$MIRROR" update-ref refs/heads/main "$commit"
      info "snapshot commit $(git --git-dir="$MIRROR" rev-parse --short "$commit") (lives only in .gitops/)"
    fi
  fi
  # The daemon runs as nobody (65534) and mounts .gitops read-only: make it world-readable.
  chmod -R a+rX "$REPO_ROOT/.gitops"
}

ensure_git_daemon() {
  log "Building $GITD_IMAGE (git daemon)"
  docker build --quiet -t "$GITD_IMAGE" "$REPO_ROOT/gitops/local" >/dev/null
  local state
  state="$(docker container inspect -f '{{.State.Running}}' "$GITD_CONTAINER" 2>/dev/null || echo missing)"
  case "$state" in
    true) info "container $GITD_CONTAINER is running" ;;
    false)
      log "Starting the existing container $GITD_CONTAINER"
      if ! docker start "$GITD_CONTAINER" >/dev/null 2>&1; then
        warn "could not start the old $GITD_CONTAINER container; creating a new one"
        docker rm -f "$GITD_CONTAINER" >/dev/null
        run_git_daemon
      fi ;;
    *) run_git_daemon ;;
  esac
}

run_git_daemon() {
  log "Starting container $GITD_CONTAINER on the kind network (serves .gitops/ read-only)"
  docker run -d --name "$GITD_CONTAINER" --network kind --restart unless-stopped \
    -v "$REPO_ROOT/.gitops:/srv/git:ro" "$GITD_IMAGE" >/dev/null
}

# Ask the Argo CD repo-server itself whether it can read the URL (same network path as a sync).
argocd_can_read() {
  local url="$1" i
  for ((i = 0; i < 10; i++)); do
    if kubectl_kps -n argocd exec deploy/argocd-repo-server -c repo-server -- \
      git ls-remote "$url" refs/heads/main >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# ---------------------------------------------------------------- shared

apply_project() {
  local url="$1"
  log "Applying the Argo CD project 'kps'"
  if grep -qF -- "- $url" "$REPO_ROOT/gitops/projects/kps.yaml"; then
    kubectl_kps apply -f "$REPO_ROOT/gitops/projects/kps.yaml"
  else
    # The local git daemon, a fork or a mirror: allow exactly this URL in sourceRepos too.
    awk -v url="$url" '{ print } /^  sourceRepos:/ { print "    - " url }' \
      "$REPO_ROOT/gitops/projects/kps.yaml" | kubectl_kps apply -f -
  fi
}

apply_application() {
  local url="$1" add_local=0
  [[ "$IMAGE_SOURCE" == "local" ]] && add_local=1
  log "Applying Argo CD application '$APP_NAME' (repoURL=$url, IMAGE_SOURCE=$IMAGE_SOURCE)"
  awk -v url="$url" -v add_local="$add_local" '
    BEGIN { gsub(/&/, "\\\\&", url) }
    /^ *repoURL: / { sub(/repoURL: .*/, "repoURL: " url) }
    { print }
    add_local == 1 && /^ *- values-dev\.yaml$/ { line = $0; sub(/values-dev\.yaml/, "values-local.yaml", line); print line }
  ' "$REPO_ROOT/gitops/applications/sample-api-dev.yaml" | kubectl_kps apply -f -
}

# wait_synced_healthy [expected-revision]
# With a revision (local mode: the mirror's main commit), "done" also means Argo CD has
# synced exactly that commit, so an old Synced status is never mistaken for the new one.
wait_synced_healthy() {
  local want="${1:-}"
  kubectl_kps -n argocd annotate application "$APP_NAME" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  log "Waiting up to ${WAIT_SECONDS}s for '$APP_NAME' to be Synced and Healthy${want:+ at ${want:0:7}}"
  local start=$SECONDS status sync health rev refresh
  while :; do
    status="$(kubectl_kps -n argocd get application "$APP_NAME" \
      -o jsonpath='{.status.sync.status} {.status.health.status} {.status.sync.revision} {.metadata.annotations.argocd\.argoproj\.io/refresh}' 2>/dev/null || true)"
    read -r sync health rev refresh <<<"$status" || true
    info "t=$((SECONDS - start))s sync=${sync:-?} health=${health:-?} revision=${rev:0:7}"
    # Argo CD removes the refresh annotation once it has compared the app with Git again.
    if [[ -z "$refresh" && "$sync" == "Synced" && "$health" == "Healthy" && ( -z "$want" || "$rev" == "$want" ) ]]; then
      log "sample-api is deployed: $(url_for app)"
      kubectl_kps -n "$KPS_APP_NS" get deploy,hpa,pdb,httproute 2>/dev/null || true
      return 0
    fi
    if (( SECONDS - start >= WAIT_SECONDS )); then
      warn "Timed out after ${WAIT_SECONDS}s. Argo CD conditions:"
      kubectl_kps -n argocd get application "$APP_NAME" \
        -o jsonpath='{range .status.conditions[*]}  {.type}: {.message}{"\n"}{end}' 2>/dev/null || true
      echo "Look at (the kind-kps context only exists in the repo-local kubeconfig):" >&2
      echo "  export KUBECONFIG=$KUBECONFIG" >&2
      echo "  kubectl --context kind-kps -n argocd describe application $APP_NAME" >&2
      echo "  kubectl --context kind-kps -n $KPS_APP_NS get pods,events" >&2
      echo "  kubectl --context kind-kps -n argocd logs deploy/argocd-repo-server" >&2
      exit 1
    fi
    sleep 10
  done
}

# ---------------------------------------------------------------- modes

local_mode() {
  command -v git >/dev/null 2>&1 || die "git not found"
  publish_mirror
  ensure_git_daemon

  local url="git://$GITD_CONTAINER/$MIRROR_NAME" ip
  log "Checking that Argo CD can read $url"
  if ! argocd_can_read "$url"; then
    ip="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' "$GITD_CONTAINER" 2>/dev/null || true)"
    [[ -n "$ip" ]] || die "cannot find the IP of $GITD_CONTAINER on the kind network"
    warn "pods cannot resolve '$GITD_CONTAINER'; falling back to its IP $ip"
    url="git://$ip/$MIRROR_NAME"
    argocd_can_read "$url" || die "Argo CD cannot read $url. Check: docker logs $GITD_CONTAINER"
  fi
  info "OK"

  apply_project "$url"
  apply_application "$url"
  wait_synced_healthy "$(git --git-dir="$MIRROR" rev-parse refs/heads/main)"
}

remote_mode() {
  [[ -n "$REPO_URL" ]] \
    || die "REPO_URL is empty. Example: make gitops REPO_URL=$KPS_GITHUB_REPO_URL"
  log "Checking that $REPO_URL is reachable (read-only git ls-remote)"
  GIT_TERMINAL_PROMPT=0 git ls-remote "$REPO_URL" refs/heads/main >/dev/null 2>&1 \
    || warn "cannot read $REPO_URL from this laptop. Is it pushed and public?"
  log "Checking that Argo CD can read it"
  argocd_can_read "$REPO_URL" || die "Argo CD cannot read $REPO_URL (private repo? not pushed yet? use 'make gitops-local')"
  apply_project "$REPO_URL"
  apply_application "$REPO_URL"
  wait_synced_healthy
}

case "$MODE" in
  local) local_mode ;;
  remote) remote_mode ;;
  *) die "usage: $0 local|remote" ;;
esac
