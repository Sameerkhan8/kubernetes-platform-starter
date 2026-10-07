#!/usr/bin/env bash
# Check local prerequisites for "make up".
# Read-only: it never talks to a Kubernetes cluster and never reads your default kubeconfig.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fails=0
warns=0
ok()   { printf '  [ok]   %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; fails=$((fails + 1)); }
note() { printf '  [warn] %s\n' "$*"; warns=$((warns + 1)); }

# ver_ge A B: true if version A >= version B (leading "v" ignored)
ver_ge() {
  local a="${1#v}" b="${2#v}"
  [[ "$(printf '%s\n%s\n' "$b" "$a" | sort -V | head -n 1)" == "$b" ]]
}

have() { command -v "$1" >/dev/null 2>&1; }

log "Required tools"

if have docker; then
  if docker info >/dev/null 2>&1; then
    ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?') (daemon reachable)"
  else
    bad "docker is installed but the daemon is not reachable (is Docker running? can your user use it?)"
  fi
else
  bad "docker not found: https://docs.docker.com/engine/install/"
fi

if have kind; then
  kind_v="$(kind version 2>/dev/null | awk '{print $2}')"
  if [[ "$kind_v" == "$KIND_VERSION" ]]; then
    ok "kind $kind_v"
  else
    note "kind $kind_v found, this repo is tested with $KIND_VERSION (https://kind.sigs.k8s.io/docs/user/quick-start/#installation)"
  fi
else
  bad "kind not found: https://kind.sigs.k8s.io/docs/user/quick-start/#installation (want $KIND_VERSION)"
fi

if have kubectl; then
  kubectl_v="$(kubectl_client_version)"
  ok "kubectl ${kubectl_v:-?}"
  k_minor="$(printf '%s' "${kubectl_v#v}" | cut -d. -f2)"
  c_minor="$(printf '%s' "$KUBERNETES_VERSION" | cut -d. -f2)"
  if [[ -n "$k_minor" && "$k_minor" =~ ^[0-9]+$ ]] && (( k_minor < c_minor - 1 || k_minor > c_minor + 1 )); then
    note "kubectl ${kubectl_v} is more than one minor version away from the cluster (${KUBERNETES_VERSION})"
  fi
else
  bad "kubectl not found: https://kubernetes.io/docs/tasks/tools/"
fi

if have helm; then
  helm_v="$(helm_client_version)"
  if ver_ge "${helm_v:-0}" "3.18.0"; then
    ok "helm ${helm_v} (3.18+ and 4.x both work)"
  else
    bad "helm ${helm_v:-?} is too old, need 3.18 or newer: https://helm.sh/docs/intro/install/"
  fi
else
  bad "helm not found: https://helm.sh/docs/intro/install/"
fi

for t in git curl make; do
  if have "$t"; then ok "$t"; else bad "$t not found"; fi
done

log "Optional tools (lint targets fall back to pinned Docker images when missing)"
for t in promtool kubeconform shellcheck terraform tflint jq openssl; do
  if have "$t"; then ok "$t"; else info "[--]   $t not installed (optional)"; fi
done

log "Host ports (HOST_HTTP_PORT=$HOST_HTTP_PORT, HOST_HTTPS_PORT=$HOST_HTTPS_PORT)"
if have docker && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${KPS_CLUSTER_NAME}-control-plane"; then
  ok "cluster '$KPS_CLUSTER_NAME' is running and already owns its ports"
elif ! have ss && ! have lsof; then
  note "cannot check ports $HOST_HTTP_PORT and $HOST_HTTPS_PORT (no ss or lsof)"
else
  if port_in_use "$HOST_HTTP_PORT"; then
    bad "port $HOST_HTTP_PORT is already in use. Free it or run: HOST_HTTP_PORT=8080 make up"
  else
    ok "port $HOST_HTTP_PORT is free"
  fi
  if ((KPS_HTTPS_PORT_FALLBACK == 1)); then
    note "port 443 is in use, so 'make up' will map the (unused) HTTPS port to $HOST_HTTPS_PORT instead"
  fi
  if port_in_use "$HOST_HTTPS_PORT"; then
    bad "port $HOST_HTTPS_PORT is already in use. Pick a free one: HOST_HTTPS_PORT=9443 make up"
  else
    ok "port $HOST_HTTPS_PORT is free"
  fi
fi

log "Kernel and resources"
if [[ -r /proc/sys/fs/inotify/max_user_instances ]]; then
  inst="$(cat /proc/sys/fs/inotify/max_user_instances)"
  watches="$(cat /proc/sys/fs/inotify/max_user_watches)"
  if (( inst >= 512 && watches >= 524288 )); then
    ok "inotify limits (instances=$inst, watches=$watches)"
  else
    note "inotify limits are low (instances=$inst, watches=$watches). Multi-node kind clusters can fail with 'too many open files'."
    info "       Fix until next reboot: sudo sysctl -w fs.inotify.max_user_instances=512 fs.inotify.max_user_watches=524288"
  fi
fi

if have docker && docker info >/dev/null 2>&1; then
  mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
  cpus="$(docker info --format '{{.NCPU}}' 2>/dev/null || echo '?')"
  mem_gib=$(( mem_bytes / 1024 / 1024 / 1024 ))
  if (( mem_gib >= 8 )); then
    ok "Docker can use ${mem_gib} GiB RAM and ${cpus} CPUs"
  else
    note "Docker can use only ${mem_gib} GiB RAM (${cpus} CPUs). The full stack wants about 6 GiB free."
  fi
fi
if [[ -r /proc/meminfo ]]; then
  avail_gib=$(( $(awk '/^MemAvailable:/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
  if (( avail_gib >= 6 )); then
    ok "${avail_gib} GiB RAM available right now"
  else
    note "only ${avail_gib} GiB RAM available right now; close some apps before 'make up'"
  fi
fi

log "Local state"
if have kind && kind get clusters 2>/dev/null | grep -qx "$KPS_CLUSTER_NAME"; then
  info "kind cluster '$KPS_CLUSTER_NAME' exists"
else
  info "kind cluster '$KPS_CLUSTER_NAME' does not exist yet ('make up' creates it)"
fi
info "kubeconfig used by this repo: $KUBECONFIG (your default kubeconfig is never used)"

echo
if (( fails > 0 )); then
  echo "doctor: $fails problem(s), $warns warning(s). Fix the [FAIL] lines first."
  exit 1
fi
echo "doctor: all required checks passed ($warns warning(s))."
