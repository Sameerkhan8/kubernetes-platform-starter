# ArgoCdAppOutOfSync

| Severity | Source rule file | Fires when (plain words) |
|---|---|---|
| warning | `monitoring/rules/platform.rules.yaml` | For 15 minutes, an Argo CD application has not matched what is in Git. |

## What it means

Argo CD compares the cluster with Git. "OutOfSync" means they differ. With automated sync and
self-heal (this repo's default), Argo CD fixes that within a minute or two. If it is still out of
sync after 15 minutes, something is blocking the sync.

## Impact on users

None directly: the running version keeps running. But new commits (fixes, rollbacks) are not
reaching the cluster, and the cluster may not be what Git says it is.

## How to check

```bash
export KUBECONFIG=$PWD/.kube/config  # repo-local kind cluster

kubectl --context kind-kps -n argocd get applications

# Conditions and the last sync result
kubectl --context kind-kps -n argocd describe application sample-api-dev
kubectl --context kind-kps -n argocd get application sample-api-dev \
  -o jsonpath='{.status.operationState.phase}{": "}{.status.operationState.message}{"\n"}'

# Which resources differ?
kubectl --context kind-kps -n argocd get application sample-api-dev \
  -o jsonpath='{range .status.resources[?(@.status=="OutOfSync")]}{.kind}/{.name}{"\n"}{end}'

# Can Argo CD read the repo?
kubectl --context kind-kps -n argocd logs deploy/argocd-repo-server --tail=50

# Local mode only: is the git daemon running?
docker ps --filter name=kps-git
```

The Argo CD UI (http://argocd.localtest.me) shows the same information, with a diff view.

## How to fix

| Cause | What you see | Fix |
|---|---|---|
| Sync fails | `operationState.phase: Failed` with a message | Usually an invalid manifest, a Pod Security rejection, or a change to an immutable field (for example a Deployment selector). Fix it in Git. |
| Repo cannot be read | `ComparisonError`, repo-server errors | GitHub mode: is the repo public and the URL right? Local mode: run `make gitops-local` (it restarts the `kps-git` container and republishes the mirror). |
| Automated sync was turned off | no sync attempts | Turn it back on in Git (`syncPolicy.automated`) and re-apply the application (`make app`). |
| Something outside Git keeps changing a field | flips between Synced and OutOfSync | Find the other writer (a controller, a script, a person). Remove it, or tell Argo CD to ignore that field (`ignoreDifferences`) with a comment saying why. |

Note: `spec.replicas` is not in the chart when autoscaling is on, so the HPA never causes drift.

## How to trigger it locally

Not part of the scripted demos. To try it, turn off automated sync, then change a field that
Git controls:

```bash
export KUBECONFIG=$PWD/.kube/config
kubectl --context kind-kps -n argocd patch application sample-api-dev --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl --context kind-kps -n demo patch deployment sample-api --type merge \
  -p '{"spec":{"minReadySeconds":7}}'
# the app shows OutOfSync at once; the alert fires after 15 minutes
make app   # re-applies the application with automated sync; self-heal restores the Git value
```

Tested on the kind cluster on 2026-10-07: the alert went pending about 30 seconds after the
change and fired after 15 minutes 33 seconds. `make app` then turned automated sync back on,
and self-heal put `minReadySeconds` back to the Git value.

## Related

- Argo CD UI: http://argocd.localtest.me (application `sample-api-dev`).
- [SampleApiDown](SampleApiDown.md), [SampleApiReplicasUnavailable](SampleApiReplicasUnavailable.md).
- [ADR 0004: GitOps with Argo CD](../decisions/0004-gitops-with-argo-cd.md).
