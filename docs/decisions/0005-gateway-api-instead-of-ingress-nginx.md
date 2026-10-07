# 0005: Gateway API (Traefik locally) instead of ingress-nginx

- **Status:** Accepted
- **Date:** 2026-10-07

## Context

Many clusters use ingress-nginx and the `Ingress` API. In 2026 that is a problem:

- The `kubernetes/ingress-nginx` GitHub repository is archived (checked on
  2026-10-07). Its last releases were chart 4.15.1 and controller v1.15.1, on
  2026-03-19. An edge proxy without security fixes should not go into a new platform.
- The `Ingress` API is frozen. Features such as header matching, traffic
  splitting and timeouts depend on controller-specific annotations, so the
  config is not portable.

The Kubernetes Gateway API is the upstream successor. It splits routing into
three resources, owned by different roles:

| Resource | Owner | Defines |
|---|---|---|
| `GatewayClass` | Infrastructure provider | Which controller implements gateways |
| `Gateway` | Platform team | Listeners: ports, protocols, TLS, and which namespaces may attach routes |
| `HTTPRoute` | App team | Hostnames, paths and backends for one app |

## Decision

- Use the Gateway API (`gateway.networking.k8s.io/v1`, standard channel CRDs v1.6.1).
- Locally, Traefik v3.7 implements it. Traefik is light, runs as one pod, supports
  Gateway API and `Ingress`, and works with a simple `hostPort` on kind.
- The Traefik chart creates GatewayClass `traefik` and Gateway `traefik-gateway`
  (listener `web`). The sample-api chart ships an `HTTPRoute` that attaches to it.
- The chart keeps an optional `Ingress` template (off by default) for clusters
  that still use `Ingress`.
- On GKE, the Terraform module enables the managed Gateway API
  (`gateway_api_config { channel = "CHANNEL_STANDARD" }`). The same `HTTPRoute`
  works there with a different parentRef (see `values-prod.yaml`).

## Consequences

- Routing config is portable between controllers, without annotations.
- App teams can change their own routes without touching the shared Gateway.
- Shows a migration path off ingress-nginx, which many teams need now.
- Local shortcuts, documented: the listener allows routes from all namespaces
  (production would use a namespace selector), and there is no HTTPS listener
  (production: cert-manager and an HTTPS listener).
- Gateway API CRDs must be installed before the controller. `make up` does this.

## Alternatives considered

- **Keep ingress-nginx.** Rejected: archived and unmaintained.
- **Keep `Ingress` with another controller** (Traefik, HAProxy, a cloud load
  balancer controller). Works, and the chart still supports it, but it keeps
  the annotation lock-in.
- **Envoy Gateway.** A strong Gateway API implementation. Heavier for a laptop:
  a control plane plus separate Envoy proxy pods.
- **NGINX Gateway Fabric.** The NGINX-based Gateway API implementation. A good
  fit for teams that want to stay on NGINX.
