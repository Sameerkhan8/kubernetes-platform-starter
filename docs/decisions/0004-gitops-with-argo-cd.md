# 0004: Deploy with GitOps (Argo CD)

- **Status:** Accepted
- **Date:** 2026-10-07

## Context

The common "push" setup lets CI run `kubectl apply` or `helm upgrade` against the
cluster. That has three problems:

- CI holds cluster-admin credentials. Anyone who can change a workflow can change
  the cluster.
- Manual changes in the cluster (drift) go unnoticed until something breaks.
- "What is running right now?" has no single answer. You have to piece it
  together from CI logs.

## Decision

Git is the source of truth. Argo CD runs inside the cluster and **pulls** from Git.

- The Application `sample-api-dev` tracks branch `main`, path `charts/sample-api`,
  with `values-dev.yaml`. Its sync policy is automated with `prune`
  (delete what was removed from Git) and `selfHeal` (undo manual changes).
- CI builds, tests and scans the image, pushes it under an immutable tag
  (`sha-<7 chars>`), scans that exact pushed digest again, and only then **commits**
  the tag to `values-dev.yaml`. CI never talks to the cluster.
- A release is a git tag (`v0.1.0`). CI gives the image that `main` already built for
  that commit the extra tag `0.1.0` (build once, promote the same image; it builds one
  only if `main` never did). Production promotion is a
  pull request that changes the tag in `values-prod.yaml`. It is reviewed like any
  code change, and `git revert` is the rollback.
  (`values-prod.yaml` is an example profile. No prod cluster is part of this repo.)
- The HPA owns the replica count. The chart leaves `spec.replicas` out of the
  Deployment when autoscaling is on. Otherwise Argo CD would reset the replica
  count to the Git value on every sync and fight the HPA.
- Offline mode: `make gitops-local` runs a small git daemon container (`kps-git`)
  on the kind network and points the same Application at it. GitOps works on a
  laptop before the repo is ever pushed. `make gitops REPO_URL=...` switches to GitHub.

## Consequences

- The cluster needs no inbound access from CI. CI needs no cluster credentials.
- Every deploy is a commit: who, what, when, and how to undo it.
- Drift is visible in the Argo CD UI, and `selfHeal` fixes it. The
  `ArgoCdAppOutOfSync` alert fires if an app stays out of sync.
- CI needs `contents: write` to commit the tag. Bot commits appear in history.
  If `main` gets required reviews, the bump must become a pull request.
- Argo CD polls Git (every 60s locally; the default is 3 minutes). A webhook would
  make it faster.
- Argo CD is one more system to run and secure. Locally `exec` is disabled and
  the admin password is only printed by `make creds`.

## Alternatives considered

- **Push deploys from CI** (`helm upgrade` in a workflow). Rejected for the reasons above.
- **Flux CD.** Equally good. Argo CD was chosen for its UI, which makes the
  demo easy to follow.
- **Argo CD Image Updater.** Writes new image tags back to Git by itself. One less
  CI step, but one more component. The explicit CI commit is easier to explain.
