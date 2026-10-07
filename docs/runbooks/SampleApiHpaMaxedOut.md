# SampleApiHpaMaxedOut

| Severity | Source rule file | Fires when (plain words) |
|---|---|---|
| warning | `charts/sample-api/rules/sample-api.rules.yaml` | The sample-api autoscaler has been running at its maximum number of pods for 5 minutes. |

## What it means

The HorizontalPodAutoscaler (HPA) adds pods when average CPU use is above the target
(60% of the CPU request by default). It is now at `maxReplicas` and cannot add more.
If the load keeps growing, the existing pods have to absorb it.

The alert stays quiet when `minReplicas` equals `maxReplicas`: then the replica count is
pinned on purpose and "at the maximum" is normal.

## Impact on users

None yet, maybe. But there is no spare capacity: more traffic will make the app slow
([SampleApiHighLatencyP95](SampleApiHighLatencyP95.md)) and then return errors.

## How to check

```bash
export KUBECONFIG=$PWD/.kube/config  # repo-local kind cluster

# Current vs maximum replicas, and the CPU target
kubectl --context kind-kps -n demo get hpa sample-api
kubectl --context kind-kps -n demo describe hpa sample-api   # look at Conditions and Events

# How busy are the pods and the nodes?
kubectl --context kind-kps -n demo top pods -l app.kubernetes.io/name=sample-api
kubectl --context kind-kps top nodes

# Is a load test running?
kubectl --context kind-kps -n demo get jobs

# Are new pods stuck in Pending (no room on the nodes)?
kubectl --context kind-kps -n demo get pods -l app.kubernetes.io/name=sample-api -o wide
```

## How to fix

| Cause | Fix |
|---|---|
| Real, lasting traffic growth | Raise `autoscaling.maxReplicas` in Git. Make sure the nodes can hold the extra pods: on GKE the node pool autoscaler adds nodes (`min_nodes`/`max_nodes` in `terraform/gcp-gke`). |
| A new version uses more CPU per request | Compare CPU per request before and after the deploy; revert in Git if it is a regression. |
| Unusual or abusive traffic | Find the source in the gateway logs; add rate limiting at the gateway. |
| The local load demo | It ends by itself. To stop it early: `kubectl --context kind-kps -n demo delete job kps-load` |

After the load drops, the HPA waits 120 seconds (stabilization window) and then removes at most
half of the pods per minute. This slow scale-down is on purpose: it avoids flapping.

## How to trigger it locally

```bash
make load LOAD_DURATION=420
```

The HPA reaches its maximum of 6 pods within a few minutes. The alert fires after 5 minutes at
the maximum, so the load must run for about 7 minutes in total.

## Related

- Dashboard "Sample API - Golden Signals": panels "HPA replicas" and "CPU per pod vs request".
- [SampleApiHighLatencyP95](SampleApiHighLatencyP95.md), [SampleApiReplicasUnavailable](SampleApiReplicasUnavailable.md).
- [ADR 0001: CPU-only HPA](../decisions/0001-cpu-only-hpa.md).
- The upstream kube-prometheus-stack alert `KubeHpaMaxedOut` watches every HPA and fires
  after 15 minutes. For sample-api, Alertmanager hides it while this alert fires (an inhibit
  rule in `platform/kube-prometheus-stack/values.yaml`), so the problem notifies once.
