# SampleApiDown

| Severity | Source rule file | Fires when (plain words) |
|---|---|---|
| critical | `charts/sample-api/rules/sample-api.rules.yaml` | For 2 minutes, Prometheus has not scraped a single healthy sample-api pod. |

## What it means

Prometheus finds sample-api pods through the `sample-api` ServiceMonitor and scrapes
`/metrics` on each pod. This alert fires when no scrape succeeds (`up == 1`) for 2 minutes.

There are two very different causes:

- **The app is down.** No pod is running, or every pod crashes or hangs.
- **Only monitoring is broken.** The pods are fine, but Prometheus cannot reach them
  (NetworkPolicy, ServiceMonitor, labels). Users are fine, but you are blind.

During `make up` it can show as **pending** for a short time, between the moment Prometheus
loads the rules and the moment Argo CD has deployed the app. In a measured run it cleared
after about 30 seconds, well before the 2-minute `for:` time, so it did not fire.

## Impact on users

If the app is down: every request through the gateway fails (Traefik returns 503 when a route
has no ready endpoints). This is a full outage.
If only scraping is broken: no user impact, but no other app alert can fire.

## How to check

```bash
export KUBECONFIG=$PWD/.kube/config  # repo-local kind cluster

# 1. Is the app running and ready?
kubectl --context kind-kps -n demo get deploy,pods -l app.kubernetes.io/name=sample-api -o wide
kubectl --context kind-kps -n demo get endpointslices -l kubernetes.io/service-name=sample-api

# 2. Can a user reach it through the gateway?
curl -s -o /dev/null -w '%{http_code}\n' --resolve app.localtest.me:80:127.0.0.1 http://app.localtest.me/healthz

# 3. Why are pods not running? (events, last state, logs)
kubectl --context kind-kps -n demo describe pods -l app.kubernetes.io/name=sample-api | tail -40
kubectl --context kind-kps -n demo logs -l app.kubernetes.io/name=sample-api --tail=50 --prefix

# 4. Is the deployment managed and in sync?
kubectl --context kind-kps -n argocd get application sample-api-dev

# 5. If the app works, check the monitoring side
kubectl --context kind-kps -n demo get servicemonitor sample-api
kubectl --context kind-kps -n demo get networkpolicy
```

Open http://prometheus.localtest.me/targets and search for `sample-api`.
The error next to each target tells you if it is a timeout, a refused connection or a 404.

## How to fix

| Cause | What you see | Fix |
|---|---|---|
| Bad deploy (app crashes on start) | `CrashLoopBackOff`, errors in `logs --previous` | Revert the commit in Git. Argo CD syncs the old version. Locally: `git revert <sha>` then `make gitops-local`. |
| Image not available | `ErrImageNeverPull` or `ImagePullBackOff` | Locally: `make image` (builds `sample-api:dev` and loads it into kind). In GHCR mode: check the tag in `values-dev.yaml` exists and the package is public. |
| Deployment scaled to 0 or deleted | 0 pods | `kubectl --context kind-kps -n demo scale deployment sample-api --replicas=2`. If it was deleted, Argo CD self-heal recreates it. |
| Scrape blocked | pods Ready, target error "context deadline exceeded" | The NetworkPolicy must allow namespace `monitoring` on port `http` (chart value `networkPolicy.allowFromNamespaces`). |
| No target at all | target missing from the targets page | ServiceMonitor missing, or its selector does not match the Service labels. Check `serviceMonitor.enabled` in the chart values. |

Do not fix a bad deploy with `kubectl rollout undo`. Argo CD self-heal puts the Git version back.
The fix must go into Git.

## How to trigger it locally

```bash
export KUBECONFIG=$PWD/.kube/config
kubectl --context kind-kps -n demo scale deployment sample-api --replicas=0
# wait about 3 minutes, then look at http://alertmanager.localtest.me
kubectl --context kind-kps -n demo scale deployment sample-api --replicas=2
```

Argo CD does not undo this, because the chart leaves `replicas` to the HPA, and an HPA does not
act on a Deployment that is scaled to 0.

Tested on the kind cluster on 2026-10-07: the alert went pending 45 seconds after the scale-down
and fired after 2 minutes 46 seconds. After scaling back to 2 it cleared within about
25 seconds. Argo CD showed the app as `Degraded` for a minute while the HPA had no metrics yet.

## Related

- Dashboard "Sample API - Golden Signals": panels "Available pods" and "Requests/s".
- [SampleApiPodRestarting](SampleApiPodRestarting.md), [SampleApiReplicasUnavailable](SampleApiReplicasUnavailable.md), [ArgoCdAppOutOfSync](ArgoCdAppOutOfSync.md).
- [ADR 0004: GitOps with Argo CD](../decisions/0004-gitops-with-argo-cd.md).
