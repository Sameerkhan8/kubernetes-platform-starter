#!/usr/bin/env bash
# Print the Grafana and Argo CD admin passwords to the terminal only (never to a file).
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

kps_guard

# secret_value <namespace> <secret> <key>
secret_value() {
  kubectl_kps -n "$1" get secret "$2" \
    -o go-template="{{ index .data \"$3\" | base64decode }}" 2>/dev/null || true
}

grafana_pw="$(secret_value monitoring grafana-admin admin-password)"
argocd_pw="$(secret_value argocd argocd-initial-admin-secret password)"

echo
printf '  %-8s %-34s user: admin   password: %s\n' "Grafana" "$(url_for grafana)" "${grafana_pw:-<Secret monitoring/grafana-admin not found>}"
printf '  %-8s %-34s user: admin   password: %s\n' "Argo CD" "$(url_for argocd)" "${argocd_pw:-<Secret argocd/argocd-initial-admin-secret not found (deleted after a password change?)>}"
echo
echo "  These are local, randomly generated passwords. Do not paste them anywhere."
echo
