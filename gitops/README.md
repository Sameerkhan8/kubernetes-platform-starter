# GitOps with Argo CD

Argo CD deploys `charts/sample-api` from Git into the `demo` namespace.
Nobody runs `helm install` for the app by hand. To change the app, you change Git.

| File | What it is |
|---|---|
| `projects/kps.yaml` | Argo CD project. Allows only this repo on GitHub, only the `demo` namespace, and only `Namespace` as a cluster-wide kind. In local mode the script adds the one local git daemon URL at apply time. |
| `applications/sample-api-dev.yaml` | Argo CD application. Helm chart `charts/sample-api` with `values-dev.yaml`, auto-sync with prune and self-heal. |
| `local/Dockerfile` | Image `kps-gitd:local`, a small read-only git daemon used by `make gitops-local`. |

## Two modes

### Local mode (default): `make gitops-local`

This works before the repo is pushed anywhere, and offline.

1. The script publishes the repo into a bare mirror in `.gitops/` (gitignored).
   - **Commit mode** (the repo has commits): it pushes `HEAD` to the mirror's `main`.
     Uncommitted changes are not deployed. The script warns you about them.
   - **Snapshot mode** (no commits yet, or `GITOPS_SNAPSHOT=1`): it writes the working tree
     into the mirror as a throwaway commit. Your own git history is never touched.
2. It runs the container `kps-git` (image `kps-gitd:local`) on the `kind` Docker network.
   The container serves `.gitops/` read-only over `git://`.
3. It checks that the Argo CD repo-server can read `git://kps-git/kubernetes-platform-starter.git`.
   If pods cannot resolve the name `kps-git`, it falls back to the container IP.
4. It applies the project (adding the exact git daemon URL to `sourceRepos`) and the
   application, with `repoURL` pointed at the git daemon.
   With `IMAGE_SOURCE=local` (default) it also adds `values-local.yaml`, so the app uses the
   image `sample-api:dev` that `make image` built and loaded into kind.
5. It waits until the application is `Synced` and `Healthy`.

To deploy a change locally: commit it, then run `make gitops-local` again
(or `GITOPS_SNAPSHOT=1 make gitops-local` to deploy uncommitted work).

### GitHub mode: `make gitops REPO_URL=...`

```bash
make gitops REPO_URL=https://github.com/Sameerkhan8/kubernetes-platform-starter.git
```

Same steps without the git daemon. Argo CD pulls from GitHub.

- `IMAGE_SOURCE=local` (default) still uses the locally built `sample-api:dev`.
- `IMAGE_SOURCE=ghcr` uses the tag in `values-dev.yaml`, which CI updates after every merge
  to `main`. The GHCR package must be public, or the cluster needs an imagePullSecret.

## The deploy loop in GitHub mode

1. A pull request is merged to `main`.
2. CI builds the image, pushes `ghcr.io/sameerkhan8/sample-api:sha-<7 chars>`, scans that
   exact pushed image with Trivy, and only then commits the tag into
   `charts/sample-api/values-dev.yaml`.
3. Argo CD sees the new commit and syncs the `demo` namespace.

CI never talks to the cluster. The cluster pulls from Git. Production would get its own
application that uses `values-prod.yaml` and is promoted by pull request.

The HorizontalPodAutoscaler owns the replica count. The chart leaves `spec.replicas` out of
the Deployment when autoscaling is on, so Argo CD and the HPA never fight over it.
