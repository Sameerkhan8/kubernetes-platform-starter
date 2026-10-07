# SampleApiPodRestarting

| Severity | Source rule file | Fires when (plain words) |
|---|---|---|
| warning | `charts/sample-api/rules/sample-api.rules.yaml` | A sample-api container restarted more than 2 times in the last 15 minutes. |

## What it means

Kubernetes keeps restarting the `sample-api` container in one pod. Common reasons:

- the process crashes (an exception at start-up, a bad config value)
- it is killed for using more memory than its limit (`OOMKilled`)
- the liveness probe (`/healthz`) fails 3 times in a row, so the kubelet restarts it

## Impact on users

Usually small at first: the other pods keep serving, and the readiness probe takes a broken pod
out of the Service. But each restart drops in-flight requests on that pod, and if every pod has
the same problem, it becomes an outage ([SampleApiDown](SampleApiDown.md)).

## How to check

```bash
export KUBECONFIG=$PWD/.kube/config  # repo-local kind cluster

# RESTARTS column, and which node the pod is on
kubectl --context kind-kps -n demo get pods -l app.kubernetes.io/name=sample-api -o wide

# Why did it stop last time? Look at "Last State": Reason (OOMKilled, Error, Completed) and Exit Code
kubectl --context kind-kps -n demo describe pod <pod-name>

# Logs of the previous (crashed) container
kubectl --context kind-kps -n demo logs <pod-name> -c sample-api --previous

# Probe failures and other events
kubectl --context kind-kps -n demo get events --sort-by=.lastTimestamp | tail -20
```

## How to fix

| Cause | What you see | Fix |
|---|---|---|
| Out of memory | `Reason: OOMKilled`, exit code 137 | Raise `resources.limits.memory` in the chart values (Git), or find the leak. The "Memory working set per pod" panel shows the trend. |
| Liveness probe fails | events `Liveness probe failed` | `/healthz` must be cheap and must not depend on other services. If the pod is only slow under load, raise `probes.liveness.timeoutSeconds` or `failureThreshold`, and scale out. |
| Crash at start-up | exit code 1, a traceback in `--previous` logs | Usually a bad config value or a bad build. Revert the commit in Git; Argo CD deploys the previous version. |
| Process exits on purpose | `Reason: Completed`, exit code 0 | Something sends SIGTERM to the process (or it stops by itself). Check who, and why. |

## How to trigger it locally

Not part of the scripted demos. To try it, send SIGTERM to the app process 3 times. The app
shuts down cleanly and Kubernetes restarts the container each time:

```bash
export KUBECONFIG=$PWD/.kube/config
POD=$(kubectl --context kind-kps -n demo get pods -l app.kubernetes.io/name=sample-api -o jsonpath='{.items[0].metadata.name}')
for i in 1 2 3; do
  kubectl --context kind-kps -n demo exec "$POD" -c sample-api -- python -c "import os, signal; os.kill(1, signal.SIGTERM)"
  sleep 60   # wait for the restart (Kubernetes adds a growing back-off delay)
done
```

The alert fires about 1 minute after the third restart and clears 15 minutes after the last one
(or soon after you delete the pod: the new pod starts with 0 restarts).

Tested on the kind cluster on 2026-10-07: SIGTERM at 0, 60 and 120 seconds; the alert went
pending at about 130 seconds and fired at about 190 seconds. The quick restarts also put the
container into a short CrashLoopBackOff, so [PlatformPodCrashLooping](PlatformPodCrashLooping.md)
fired for the same pod for about a minute as well. That is expected: both alerts describe the
same restarts from two angles.

## Related

- Dashboard "Sample API - Golden Signals": panels "Container restarts (1h)" and "Memory working set per pod".
- [PlatformPodCrashLooping](PlatformPodCrashLooping.md) (the same problem when it turns into CrashLoopBackOff).
- [SampleApiDown](SampleApiDown.md).
