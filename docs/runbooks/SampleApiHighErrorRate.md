# SampleApiHighErrorRate

| Severity | Source rule file | Fires when (plain words) |
|---|---|---|
| critical | `charts/sample-api/rules/sample-api.rules.yaml` | More than 5% of sample-api requests returned a 5xx status over the last 5 minutes, for 2 minutes in a row, while traffic is above 0.1 requests per second. |

## What it means

The app itself is answering with server errors (500-599). The ratio is computed per namespace
from the app's own `http_requests_total` counter.

The traffic guard (more than 0.1 requests per second) stops the alert from firing on
"1 error out of 2 requests" at night.

Errors made by the gateway (for example 503 when no pod is ready) never reach the app, so they
are not counted here. Look at [SampleApiDown](SampleApiDown.md) for that case, or at Traefik's
own metric `traefik_service_requests_total{code=~"5.."}`.

## Impact on users

At least 1 in 20 requests fails. Users see errors now. Act at once.

## How to check

```bash
export KUBECONFIG=$PWD/.kube/config  # repo-local kind cluster

# Which pods, and what do the logs say?
kubectl --context kind-kps -n demo get pods -l app.kubernetes.io/name=sample-api -o wide
kubectl --context kind-kps -n demo logs -l app.kubernetes.io/name=sample-api --tail=100 --prefix

# Did something change just before the errors started?
kubectl --context kind-kps -n argocd get application sample-api-dev \
  -o jsonpath='{.status.sync.revision}{"\n"}'
kubectl --context kind-kps -n demo rollout history deployment/sample-api

# Is someone running the error demo or a load test?
kubectl --context kind-kps -n demo get jobs
```

In Prometheus (http://prometheus.localtest.me), find which path returns the errors:

```promql
sum by (path, status) (rate(http_requests_total{job="sample-api", status=~"5.."}[5m]))
```

## How to fix

| Cause | Fix |
|---|---|
| A new version is broken | Revert the commit in Git; Argo CD deploys the previous version. Locally: `git revert <sha>` then `make gitops-local`. Do not use `kubectl rollout undo` (Argo CD self-heal undoes it). |
| A dependency is failing (database, other API) | Check that dependency. Return a clear error, add timeouts and retries with backoff, and fail fast instead of piling up requests. |
| Pods are overloaded | See [SampleApiHpaMaxedOut](SampleApiHpaMaxedOut.md) and [SampleApiHighLatencyP95](SampleApiHighLatencyP95.md). |
| The local demo | `make alert-demo` stops its own Job. If you stopped the script early: `kubectl --context kind-kps -n demo delete job kps-alert-demo` |

The alert resolves by itself about 5 minutes after the errors stop, when the 5-minute
rate window no longer contains them.

## How to trigger it locally

```bash
make alert-demo
```

It sends traffic to `/error?rate=0.5` (half of the requests return 500) through the gateway,
waits until the alert fires (usually about 3 minutes), prints the alert as Alertmanager received
it, and stops the traffic.

## Related

- Dashboard "Sample API - Golden Signals": panels "Error ratio (5xx)" and "Requests/s by status".
- [SampleApiDown](SampleApiDown.md), [SampleApiHighLatencyP95](SampleApiHighLatencyP95.md).
- [ADR 0004: GitOps with Argo CD](../decisions/0004-gitops-with-argo-cd.md) (why rollback goes through Git).
