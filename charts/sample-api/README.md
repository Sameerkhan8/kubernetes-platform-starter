# sample-api Helm chart

This chart deploys `sample-api`, a small FastAPI service, with the settings you would expect
in production: probes, a graceful shutdown, autoscaling, a disruption budget, network
policies, metrics, alerts and a dashboard.

Argo CD deploys it with release name `sample-api` into namespace `demo`
(`gitops/applications/sample-api-dev.yaml`). With that release name, every object is named
`sample-api` (the dashboard ConfigMap is `sample-api-dashboard`).

## What the chart creates

| Object | File | Notes |
|---|---|---|
| Deployment | `templates/deployment.yaml` | Rolling update with `maxSurge: 1`, `maxUnavailable: 0` and `minReadySeconds`. No `spec.replicas` when the HPA is on, so the HPA owns the replica count. |
| HorizontalPodAutoscaler | `templates/hpa.yaml` | `autoscaling/v2`, CPU only, with scale-up and scale-down `behavior`. |
| PodDisruptionBudget | `templates/pdb.yaml` | `minAvailable: 1`, `unhealthyPodEvictionPolicy: AlwaysAllow`. |
| Service | `templates/service.yaml` | ClusterIP, port 80 to the container port named `http` (8000). |
| HTTPRoute | `templates/httproute.yaml` | Gateway API route, attached to `traefik-gateway` locally. The request matches are a value: every path locally, only `/` in the prod profile. |
| Ingress | `templates/ingress.yaml` | Optional, off by default. For clusters that still use the Ingress API. |
| NetworkPolicy (x3) | `templates/networkpolicy.yaml` | Default-deny ingress and default-deny egress (DNS still allowed) for the namespace, then allow the gateway and Prometheus namespaces (or CIDRs) on the app port. |
| ServiceAccount | `templates/serviceaccount.yaml` | Token not mounted: the app never calls the Kubernetes API. |
| ServiceMonitor | `templates/servicemonitor.yaml` | Prometheus Operator scrape config. The job label is `sample-api`. |
| PrometheusRule | `templates/prometheusrule.yaml` | The 6 app alerts from `rules/sample-api.rules.yaml`. |
| ConfigMap (dashboard) | `templates/grafana-dashboard.yaml` | `dashboards/sample-api.json`, found by the Grafana sidecar through the label `grafana_dashboard: "1"`. |

The alert rules and the dashboard are plain files inside the chart. The app ships its own
alerts and dashboard, and promtool unit-tests the same rule file the chart deploys
(`monitoring/tests/sample-api.test.yaml`).

## Pod hardening

- Runs as uid/gid 10001, `runAsNonRoot: true`, seccomp `RuntimeDefault`.
- `readOnlyRootFilesystem: true`, all Linux capabilities dropped, no privilege escalation.
  `/tmp` is a small `emptyDir`.
- Meets the Pod Security `restricted` profile (the `demo` namespace enforces it).

## Graceful shutdown

When a pod is deleted, this happens in order:

1. `preStopSleepSeconds` (10s): the pod keeps serving while the gateway and the Service
   endpoints drop it.
2. SIGTERM: `/readyz` returns 503 and the app keeps serving for `app.shutdownDelaySeconds` (3s).
3. uvicorn stops accepting connections and waits up to `app.gracefulTimeoutSeconds` (10s) for
   in-flight requests.

The total (23s) must stay below `terminationGracePeriodSeconds` (30s). The chart refuses to
render if it does not. `make rollout-test` checks that a rolling restart drops no requests.
See `docs/decisions/0002-prestop-sleep-graceful-shutdown.md`.

## Main values

| Key | Default | Description |
|---|---|---|
| `environment` | `dev` | Returned by `GET /` (env `APP_ENV`). |
| `image.repository` | `ghcr.io/sameerkhan8/sample-api` | Image repository. |
| `image.tag` | `""` | Empty means the chart `appVersion`. CI sets an immutable `sha-xxxxxxx` tag in `values-dev.yaml`. |
| `image.pullPolicy` | `IfNotPresent` | `Never` in `values-local.yaml` (image loaded with `kind load`). |
| `app.port` | `8000` | Container port. |
| `app.logLevel` | `info` | `critical`, `error`, `warning`, `info` or `debug`. |
| `app.shutdownDelaySeconds` | `3` | Serve time after SIGTERM, with readiness failing. |
| `app.gracefulTimeoutSeconds` | `10` | Max wait for in-flight requests on shutdown. |
| `app.workMaxMs` | `2000` | Upper limit for `GET /work?ms=N`. |
| `app.demoEndpoints` | `true` | Serve the demo-only `/work`, `/error`, the API docs, and pod/node names in `GET /`. `false` in `values-prod.yaml`: `/work` lets anyone burn CPU and `/error` fails on purpose, so they never belong on a public route. |
| `replicaCount` | `2` | Used only when `autoscaling.enabled=false`. |
| `autoscaling.enabled` | `true` | Create the HPA. |
| `autoscaling.minReplicas` / `maxReplicas` | `2` / `6` | Replica range. |
| `autoscaling.targetCPUUtilizationPercentage` | `60` | Average CPU target, as a percentage of the CPU request. |
| `autoscaling.behavior` | see `values.yaml` | Scale up by up to 2 pods every 15s; scale down by at most 50% per minute after a 120s window. |
| `resources` | requests `50m`/`64Mi`, limits `500m`/`128Mi` | The CPU limit keeps the laptop demo in check. `values-prod.yaml` removes it. |
| `strategy.maxSurge` / `maxUnavailable` | `1` / `0` | Never drop below the desired count during a rollout. |
| `minReadySeconds` | `5` | A new pod must stay Ready this long before it counts. |
| `terminationGracePeriodSeconds` | `30` | Must exceed preStop + shutdown delay + graceful timeout. |
| `preStopSleepSeconds` | `10` | Native `preStop.sleep` (Kubernetes 1.30+). `0` disables it. |
| `probes.startup` / `liveness` / `readiness` | `/healthz`, `/healthz`, `/readyz` | Path, period, timeout and failure threshold for each probe. |
| `topologySpread.enabled` | `true` | Spread pods across zones and nodes (best effort, `ScheduleAnyway`). |
| `pdb.enabled` / `pdb.minAvailable` | `true` / `1` | Keep `minAvailable` below the minimum replica count, or node drains block. |
| `service.port` | `80` | Service port. |
| `httpRoute.enabled` | `true` | Create the HTTPRoute. |
| `httpRoute.hostnames` | `[app.localtest.me]` | Hostnames for the route. |
| `httpRoute.parentRefs` | `traefik-gateway` / `traefik` / `web` | Gateway and listener to attach to. |
| `httpRoute.matches` | `PathPrefix /` | Gateway API request matches sent to the app. The prod profile routes only `Exact /`, so `/metrics` and the probes are never public. |
| `ingress.enabled` | `false` | Create an Ingress instead of (or as well as) the HTTPRoute. |
| `networkPolicy.enabled` | `true` | Create the NetworkPolicies. |
| `networkPolicy.defaultDenyIngress` | `true` | Namespace-wide default deny. Turn it off in shared namespaces. |
| `networkPolicy.allowFromNamespaces` | `[traefik, monitoring]` | Namespaces allowed to reach the app port. |
| `networkPolicy.allowFromCIDRs` | `[]` | CIDRs allowed to reach the app port. For cloud load balancers that call pod IPs directly (GKE's managed Gateway runs no pods in the cluster). |
| `networkPolicy.defaultDenyEgress` | `true` | Namespace-wide default deny for egress; DNS to kube-dns stays open. The app calls nothing else. Turn it off in shared namespaces. |
| `serviceMonitor.enabled` | `true` | Needs the Prometheus Operator CRDs. |
| `serviceMonitor.labels` | `{}` | Add `release: <name>` if your Prometheus selects ServiceMonitors by label. |
| `prometheusRule.enabled` | `true` | Needs the Prometheus Operator CRDs. |
| `grafanaDashboard.enabled` | `true` | Dashboard ConfigMap for the Grafana sidecar. |

Every key has a comment in `values.yaml`. `values.schema.json` checks types and rejects
unknown keys, so a typo such as `autoscalling` fails at render time instead of being ignored.

## How the values files layer

| File | Used by | What it changes |
|---|---|---|
| `values.yaml` | always | Defaults. |
| `values-dev.yaml` | Argo CD app `sample-api-dev` | `environment: dev` and the image tag that CI bumps after each merge to `main`. |
| `values-local.yaml` | `make gitops-local` (on top of dev) | Local image `sample-api:dev`, `pullPolicy: Never`. |
| `values-prod.yaml` | example only, never applied here | 3-10 replicas, bigger requests, no CPU limit, `minAvailable: 2`, demo endpoints off, only `/` routed on a public HTTPS gateway, Google load balancer ranges allowed in, and a release tag (`0.1.0`) promoted by pull request. |

Later files win. Example render for the local demo:

```bash
helm template sample-api charts/sample-api --namespace demo \
  -f charts/sample-api/values-dev.yaml -f charts/sample-api/values-local.yaml
```

## Checks

```bash
helm lint charts/sample-api --strict -f charts/sample-api/values-prod.yaml
make lint-helm lint-k8s lint-rules   # lint, kubeconform, promtool
```

The chart has no `helm test` hook: a test pod would be blocked by the chart's own
default-deny NetworkPolicies. `make smoke` tests the app through the gateway instead, and
`make policy-test` proves the NetworkPolicies and Pod Security with throwaway pods.

The default-deny egress policy covers every pod in the namespace. The load-test Jobs that
`make load`, `make rollout-test` and `make alert-demo` start bring their own small policy
(`kps-loadgen-egress`) that lets them reach the gateway and nothing else.
