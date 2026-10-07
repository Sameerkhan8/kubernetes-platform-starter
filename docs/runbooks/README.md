# Runbooks

Every custom alert in this repo has a `runbook_url` annotation that points to one of these pages.
When an alert fires, the on-call person opens the link and follows the steps.

Each runbook has the same sections:

1. **What it means**: the condition in plain words.
2. **Impact on users**: how bad it is, so you can decide how fast to act.
3. **How to check**: copy-paste commands to find the cause.
4. **How to fix**: common causes and what to do about each one.
5. **How to trigger it locally**: so you can practice on the kind cluster.
6. **Related**: dashboard panels, other alerts and design decisions.

## Alerts

| Alert | Severity | Rule file | Fires when | Triggered on the kind cluster (2026-10-07) |
|---|---|---|---|---|
| [SampleApiDown](SampleApiDown.md) | critical | `charts/sample-api/rules/sample-api.rules.yaml` | Prometheus cannot scrape any healthy sample-api pod for 2 minutes | Yes, runbook steps: fired after 2 min 46 s |
| [SampleApiHighErrorRate](SampleApiHighErrorRate.md) | critical | `charts/sample-api/rules/sample-api.rules.yaml` | More than 5% of requests return 5xx (over 5 minutes) for 2 minutes | Yes, `make alert-demo`: fired after about 3 min |
| [SampleApiHighLatencyP95](SampleApiHighLatencyP95.md) | warning | `charts/sample-api/rules/sample-api.rules.yaml` | p95 latency is above 500ms for 5 minutes (`/work` excluded) | TBD_LAT |
| [SampleApiPodRestarting](SampleApiPodRestarting.md) | warning | `charts/sample-api/rules/sample-api.rules.yaml` | A sample-api container restarted more than 2 times in 15 minutes | Yes, runbook steps: fired about 1 min after the third restart |
| [SampleApiHpaMaxedOut](SampleApiHpaMaxedOut.md) | warning | `charts/sample-api/rules/sample-api.rules.yaml` | The autoscaler has been at its maximum replicas for 5 minutes | Yes, `make load LOAD_DURATION=420`: fired 5 min after the HPA reached 6 pods |
| [SampleApiReplicasUnavailable](SampleApiReplicasUnavailable.md) | warning | `charts/sample-api/rules/sample-api.rules.yaml` | Fewer pods are available than desired for 10 minutes | Yes, runbook steps: fired about 11 min after the pod was deleted; the upstream `KubeDeploymentReplicasMismatch` for the same Deployment showed as `suppressed` in Alertmanager |
| [PlatformPodCrashLooping](PlatformPodCrashLooping.md) | warning | `monitoring/rules/platform.rules.yaml` | A container in any namespace is in CrashLoopBackOff for 5 minutes | Yes, runbook steps: fired after about 10 min |
| [PlatformNodeNotReady](PlatformNodeNotReady.md) | critical | `monitoring/rules/platform.rules.yaml` | A node is not Ready for 5 minutes | Yes, runbook steps: fired after 6 min 22 s (see the runbook for the inotify note) |
| [PlatformNodeMemoryHigh](PlatformNodeMemoryHigh.md) | warning | `monitoring/rules/platform.rules.yaml` | Node memory use is above 90% for 10 minutes | No: promtool unit tests only (filling the laptop memory is not a safe demo) |
| [ArgoCdAppOutOfSync](ArgoCdAppOutOfSync.md) | warning | `monitoring/rules/platform.rules.yaml` | An Argo CD application is not Synced for 15 minutes | Yes, runbook steps: fired after 15 min 33 s |

The app alerts ship inside the Helm chart (the team that builds the service owns its alerts).
The platform alerts are applied by `make monitoring`.
Every alert has unit tests in `monitoring/tests/` (`make lint-rules` runs them with promtool).

Some kube-prometheus-stack default alerts cover the same problems. Two rules decide what
happens to them (`platform/kube-prometheus-stack/values.yaml`):

- **Switched off**, because a custom alert covers the same thing for every namespace or node:
  `KubePodCrashLooping` (-> PlatformPodCrashLooping), `KubeNodeNotReady` (-> PlatformNodeNotReady)
  and `NodeMemoryHighUtilization` (-> PlatformNodeMemoryHigh).
- **Kept, but hidden for sample-api** by Alertmanager inhibit rules: `KubeHpaMaxedOut` and
  `KubeDeploymentReplicasMismatch`. The SampleApi* alerts only watch sample-api, so every other
  Deployment and HPA still needs the upstream alerts. While SampleApiHpaMaxedOut or
  SampleApiReplicasUnavailable fires, Alertmanager suppresses the upstream alert for the same
  object, so one problem notifies once. (Checked on the cluster: in the
  SampleApiReplicasUnavailable drill, `KubeDeploymentReplicasMismatch` for sample-api showed as
  `suppressed`; with test alerts, `KubeHpaMaxedOut` for sample-api was `suppressed` and the
  same alert for another HPA stayed `active`.)

All other default alerts stay on. They link to the upstream runbooks at
https://runbooks.prometheus-operator.dev/.

## Before you run any command

All commands use the repo-local kubeconfig and name the context on every call:

```bash
export KUBECONFIG=$PWD/.kube/config  # repo-local kind cluster; run from the repo root
kubectl --context kind-kps get nodes
```

If your default kubeconfig points at a real cluster, a copy-pasted command still cannot reach it:
the `kind-kps` context only exists in the repo-local file.

## About severities

- **critical**: users are affected now, or will be very soon. Act at once.
- **warning**: something is wrong or close to a limit. Look at it during working hours.

Locally, Alertmanager sends notifications nowhere (null receiver). A real setup routes critical
alerts to a pager (PagerDuty, Opsgenie) and warnings to a chat channel (Slack, Microsoft Teams).
The `Watchdog` alert always fires on purpose: it proves the alert pipeline works end to end.
