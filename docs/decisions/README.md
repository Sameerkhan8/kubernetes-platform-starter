# Architecture decision records

An architecture decision record (ADR) is a short note about one design choice:
what the problem was, what we chose, what it costs, and what else we looked at.
They explain *why* the code looks the way it does.

| # | Decision | Status | Date |
|---|---|---|---|
| [0001](0001-cpu-only-hpa.md) | Scale on CPU only, not on memory | Accepted | 2026-10-07 |
| [0002](0002-prestop-sleep-graceful-shutdown.md) | preStop sleep and graceful shutdown for zero-downtime rollouts | Accepted | 2026-10-07 |
| [0003](0003-github-oidc-workload-identity-no-keys.md) | GitHub OIDC and Workload Identity Federation instead of JSON keys | Accepted | 2026-10-07 |
| [0004](0004-gitops-with-argo-cd.md) | Deploy with GitOps (Argo CD) | Accepted | 2026-10-07 |
| [0005](0005-gateway-api-instead-of-ingress-nginx.md) | Gateway API (Traefik locally) instead of ingress-nginx | Accepted | 2026-10-07 |

## Format

Each record has the same sections:

- **Status**: Proposed, Accepted, or Superseded by a later record.
- **Context**: the problem and the facts that matter.
- **Decision**: what we do.
- **Consequences**: what gets better, and what it costs.
- **Alternatives considered**: other options and why we did not pick them.

To change a decision, add a new record that supersedes the old one.
Do not rewrite history in the old record.
