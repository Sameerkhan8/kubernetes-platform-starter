#!/usr/bin/env bash
# Print the local URLs. Does not talk to the cluster and never prints passwords.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cat <<EOF

Local URLs (Traefik + Gateway API, reachable from this laptop only):

  App            $(url_for app)
  Grafana        $(url_for grafana)        user: admin   (dashboard "Sample API - Golden Signals")
  Prometheus     $(url_for prometheus)
  Alertmanager   $(url_for alertmanager)
  Argo CD        $(url_for argocd)         user: admin

Passwords: run 'make creds'. They live only in in-cluster Secrets and are never written to a file.
*.localtest.me is public DNS that points to 127.0.0.1. If your network blocks that,
see "Troubleshooting" in README.md (one /etc/hosts line fixes it).

EOF
