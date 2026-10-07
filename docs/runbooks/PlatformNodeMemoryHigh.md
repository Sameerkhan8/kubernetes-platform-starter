# PlatformNodeMemoryHigh

| Severity | Source rule file | Fires when (plain words) |
|---|---|---|
| warning | `monitoring/rules/platform.rules.yaml` | A node has used more than 90% of its memory for 10 minutes. |

## What it means

node-exporter reports how much memory is still available on each node. When less than 10% is
left, the kernel may start killing processes (OOM killer) and the kubelet may evict pods.

On kind, every node sees the memory of the whole laptop. So on kind this alert means:
**your laptop** is almost out of memory, not one Kubernetes node.

## Impact on users

Nothing yet. Next come evicted pods, OOM-killed containers and a slow node.

## How to check

```bash
export KUBECONFIG=$PWD/.kube/config  # repo-local kind cluster

kubectl --context kind-kps top nodes
kubectl --context kind-kps top pods -A --sort-by=memory | head -15

# On kind: how much does each node container use?
docker stats --no-stream kps-control-plane kps-worker kps-worker2

# On the laptop itself
free -h
```

In Prometheus (http://prometheus.localtest.me):

```promql
1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes
```

## How to fix

| Cause | Fix |
|---|---|
| Laptop is busy with other apps (kind) | Close other apps, or stop the stack with `make down` when you are not using it. |
| One pod uses far more memory than usual | Check it with `top pods`; a memory leak needs a code fix. Every container in this repo has a memory limit, so a leak hits its own limit (OOMKilled) before it fills the node. |
| The cluster is simply too full (cloud) | Add nodes or use bigger machine types; check that memory requests match real use (VPA recommendations help here). |

## How to trigger it locally

Covered by the promtool unit tests only (`make lint-rules`). Filling the laptop's memory on
purpose is not a safe demo.

## Related

- Grafana default dashboard "Node Exporter / Nodes" (memory panels).
- [PlatformPodCrashLooping](PlatformPodCrashLooping.md), [PlatformNodeNotReady](PlatformNodeNotReady.md).
- This alert replaces the kube-prometheus-stack default `NodeMemoryHighUtilization` (switched off in `platform/kube-prometheus-stack/values.yaml`).
