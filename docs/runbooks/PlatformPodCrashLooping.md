# PlatformPodCrashLooping

| Severity | Source rule file | Fires when (plain words) |
|---|---|---|
| warning | `monitoring/rules/platform.rules.yaml` | For 5 minutes, a container in any namespace has been in CrashLoopBackOff. |

## What it means

The container starts, crashes, and Kubernetes waits longer and longer before it tries again
(CrashLoopBackOff). The rule looks at the last 5 minutes, because the "waiting" state comes and
goes between restart attempts.

The alert names the namespace, pod and container in its labels.

## Impact on users

It depends on the component:

| Namespace | What breaks |
|---|---|
| `demo` | sample-api capacity (see [SampleApiPodRestarting](SampleApiPodRestarting.md)) |
| `traefik` | the gateway: every URL stops working |
| `monitoring` | metrics, dashboards or alerts (you may not get other alerts) |
| `argocd` | deployments from Git stop; running apps keep running |
| `kube-system` | DNS (CoreDNS), networking (kindnet) or metrics-server (the HPA stops scaling) |
| any other namespace | that team's workload; the alert covers every namespace, so nothing crash-loops unnoticed |

## How to check

```bash
export KUBECONFIG=$PWD/.kube/config  # repo-local kind cluster

kubectl --context kind-kps get pods -A | grep -E 'CrashLoopBackOff|Error|OOMKilled'

# Last State (Reason, Exit Code) and Events at the bottom
kubectl --context kind-kps -n <namespace> describe pod <pod-name>

# Logs of the crashed container
kubectl --context kind-kps -n <namespace> logs <pod-name> -c <container> --previous
```

For a Helm-installed component, see what changed recently:

```bash
helm --kube-context kind-kps -n <namespace> history <release>   # traefik, kube-prometheus-stack, argocd, metrics-server
```

## How to fix

| Cause | What you see | Fix |
|---|---|---|
| Out of memory | `Reason: OOMKilled`, exit code 137 | Raise the memory limit in `platform/<component>/values.yaml` and re-run its make target (for example `make monitoring`). |
| Bad configuration after an upgrade | errors in `--previous` logs right after a change | Fix the values file and re-run the make target, or roll back: `helm --kube-context kind-kps -n <namespace> rollback <release>`. |
| A dependency is missing | logs mention a missing CRD, Secret or Service | Install components in the `make up` order (CRDs first, then monitoring, then the gateway). |
| sample-api in `demo` | see [SampleApiPodRestarting](SampleApiPodRestarting.md) | Fix through Git; Argo CD deploys it. |

## How to trigger it locally

Not part of the scripted demos. To try it, start a pod in `demo` that exits with an error at once.
The `demo` namespace enforces Pod Security "restricted", so the pod needs a strict security context:

```bash
export KUBECONFIG=$PWD/.kube/config
kubectl --context kind-kps -n demo run crashloop-demo --image=sample-api:dev --restart=Always \
  --overrides='{"apiVersion":"v1","spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"crashloop-demo","image":"sample-api:dev","imagePullPolicy":"Never","command":["python","-c","raise SystemExit(1)"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
# the alert fires after about 10 minutes (see below)
kubectl --context kind-kps -n demo delete pod crashloop-demo
```

Tested on the kind cluster (Kubernetes 1.36) on 2026-10-07: the alert went pending about
5 minutes after the pod started crashing and fired about 10 minutes after. It is slower than
the rule's 5-minute `for:` because the `CrashLoopBackOff` waiting state only shows up in
kube-state-metrics (scraped every 30 seconds) once the back-off delay between restarts gets
long. Before that, `kubectl get pod` shows the container as `Error` between restarts.

## Related

- Grafana default dashboard "Kubernetes / Compute Resources / Namespace (Pods)".
- [SampleApiPodRestarting](SampleApiPodRestarting.md), [PlatformNodeMemoryHigh](PlatformNodeMemoryHigh.md).
- This alert replaces the kube-prometheus-stack default `KubePodCrashLooping` (switched off in `platform/kube-prometheus-stack/values.yaml`).
