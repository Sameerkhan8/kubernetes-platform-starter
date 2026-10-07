# SampleApiReplicasUnavailable

| Severity | Source rule file | Fires when (plain words) |
|---|---|---|
| warning | `charts/sample-api/rules/sample-api.rules.yaml` | For 10 minutes, the sample-api Deployment has had fewer available pods than it wants. |

## What it means

The Deployment wants N pods (set by the HPA), but fewer than N are available (running, ready,
and ready for at least `minReadySeconds`). A short dip during a rolling update is normal;
10 minutes is not.

Common reasons:

- new pods cannot be scheduled (`Pending`: not enough CPU or memory on the nodes, a node is down)
- new pods cannot pull their image
- new pods start but never become ready (the `/readyz` probe fails)

## Impact on users

Less capacity than planned. Users are fine while the remaining pods can carry the traffic.
If it drops to zero, see [SampleApiDown](SampleApiDown.md).

## How to check

```bash
export KUBECONFIG=$PWD/.kube/config  # repo-local kind cluster

kubectl --context kind-kps -n demo get deployment sample-api
kubectl --context kind-kps -n demo get pods -l app.kubernetes.io/name=sample-api -o wide

# Why is a pod Pending or not Ready? Look at the Events at the bottom.
kubectl --context kind-kps -n demo describe pod <pod-name>

# Is a rollout stuck? (old and new ReplicaSets)
kubectl --context kind-kps -n demo rollout status deployment/sample-api --timeout=10s
kubectl --context kind-kps -n demo get replicasets -l app.kubernetes.io/name=sample-api

# Node health and free capacity
kubectl --context kind-kps get nodes
kubectl --context kind-kps describe nodes | grep -A 8 "Allocated resources"
```

## How to fix

| Cause | What you see | Fix |
|---|---|---|
| No room on the nodes | `Pending`, event `Insufficient cpu` or `Insufficient memory` | Add nodes (GKE node pool autoscaling), or lower the requests if they are too high. |
| A node is down or cordoned | `Pending`, node `NotReady` or `SchedulingDisabled` | See [PlatformNodeNotReady](PlatformNodeNotReady.md). `kubectl --context kind-kps uncordon <node>` if it was cordoned by mistake. |
| Image cannot be pulled | `ErrImagePull`, `ImagePullBackOff`, `ErrImageNeverPull` | Locally: `make image`. Otherwise fix the image tag in Git. |
| Readiness probe fails | `Running` but `0/1` ready, event `Readiness probe failed` | Read the pod logs. Fix the cause in Git and let Argo CD deploy it. |

Always fix through Git. `kubectl edit` or `kubectl rollout undo` changes are undone by Argo CD
self-heal within seconds.

## How to trigger it locally

Not part of the scripted demos. To try it, stop new pods from being scheduled and delete one pod:

```bash
export KUBECONFIG=$PWD/.kube/config
kubectl --context kind-kps cordon kps-worker kps-worker2
kubectl --context kind-kps -n demo get pods -l app.kubernetes.io/name=sample-api   # pick one that is Running
kubectl --context kind-kps -n demo delete pod <pod-name>
# the replacement pod stays Pending; the alert fires after about 10 minutes
kubectl --context kind-kps uncordon kps-worker kps-worker2
```

Tested on the kind cluster on 2026-10-07: the alert went pending within 30 seconds of the
delete and fired about 11 minutes after it. Five minutes later the upstream
`KubeDeploymentReplicasMismatch` fired in Prometheus for the same Deployment, and Alertmanager
showed it as `suppressed` (the inhibit rule), so only one notification would go out.

## Related

- Dashboard "Sample API - Golden Signals": panels "Available pods" and "HPA replicas".
- [SampleApiDown](SampleApiDown.md), [PlatformNodeNotReady](PlatformNodeNotReady.md), [SampleApiHpaMaxedOut](SampleApiHpaMaxedOut.md).
- [ADR 0002: preStop sleep and graceful shutdown](../decisions/0002-prestop-sleep-graceful-shutdown.md) (how rolling updates stay safe).
- The upstream kube-prometheus-stack alert `KubeDeploymentReplicasMismatch` watches every
  Deployment and fires after 15 minutes. For sample-api, Alertmanager hides it while this
  alert fires (an inhibit rule in `platform/kube-prometheus-stack/values.yaml`).
