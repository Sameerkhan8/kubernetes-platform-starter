# SampleApiHighLatencyP95

| Severity | Source rule file | Fires when (plain words) |
|---|---|---|
| warning | `charts/sample-api/rules/sample-api.rules.yaml` | For 5 minutes, the slowest 5% of requests took longer than 500ms (the `/work` endpoint is not counted). |

## What it means

p95 latency means: 95% of requests were faster than this number, 5% were slower.
It is computed from the `http_request_duration_seconds` histogram, per namespace.

`/work` is excluded on purpose. It burns CPU for as long as the caller asks, so its latency
says nothing about health.

## Impact on users

The app works, but it is slow for some users. Slow requests often turn into timeouts and errors
later, so check it before it gets worse.

## How to check

```bash
export KUBECONFIG=$PWD/.kube/config  # repo-local kind cluster

# Are the pods busy? Is the autoscaler at its limit?
kubectl --context kind-kps -n demo top pods -l app.kubernetes.io/name=sample-api
kubectl --context kind-kps -n demo get hpa sample-api

# Are the nodes busy?
kubectl --context kind-kps top nodes

# Is a load test running?
kubectl --context kind-kps -n demo get jobs
```

In Prometheus (http://prometheus.localtest.me):

```promql
# p95 per path
histogram_quantile(0.95, sum by (path, le) (rate(http_request_duration_seconds_bucket{job="sample-api"}[5m])))

# Is the CPU limit throttling the pods? (share of time slices that were throttled)
sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{namespace="demo", container="sample-api"}[5m]))
  / sum by (pod) (rate(container_cpu_cfs_periods_total{namespace="demo", container="sample-api"}[5m]))
```

## How to fix

| Cause | Fix |
|---|---|
| Not enough pods | If the HPA is at its maximum, see [SampleApiHpaMaxedOut](SampleApiHpaMaxedOut.md). Raise `autoscaling.maxReplicas` in Git if the traffic is real. |
| CPU throttling | The local profile has a 500m CPU limit on purpose. The production profile (`values-prod.yaml`) removes the CPU limit and keeps the request. See [ADR 0001](../decisions/0001-cpu-only-hpa.md). |
| Slow dependency | Check the dependency's own latency. Add timeouts so slow calls fail fast. |
| A new version is slower | Compare with the previous version, then revert the commit in Git if needed. |
| Noisy neighbours on the node | Check `kubectl --context kind-kps top nodes`. On kind, all nodes share the laptop CPU. |

## How to trigger it locally

This alert is covered by the promtool unit tests (`make lint-rules`). It is not part of the
scripted demos, because the load demo only calls `/work`, which this alert ignores on purpose.

An experiment you can try (not part of the tested demos, results depend on your laptop):
make the pods CPU-starved with heavy `/work` load, and send normal traffic to `/` at the same time.

```bash
# terminal 1: heavy CPU load for 10 minutes
make load LOAD_DURATION=600 LOAD_CONCURRENCY=32 WORK_MS=1000

# terminal 2: normal requests to / (these are the ones the alert measures)
while true; do curl -s -o /dev/null --resolve app.localtest.me:80:127.0.0.1 http://app.localtest.me/; sleep 0.2; done
```

## Related

- Dashboard "Sample API - Golden Signals": panels "p95 latency", "Latency p50 / p95 / p99", "CPU per pod vs request", "In-flight requests".
- [SampleApiHpaMaxedOut](SampleApiHpaMaxedOut.md), [SampleApiHighErrorRate](SampleApiHighErrorRate.md).
- [ADR 0001: CPU-only HPA](../decisions/0001-cpu-only-hpa.md).
