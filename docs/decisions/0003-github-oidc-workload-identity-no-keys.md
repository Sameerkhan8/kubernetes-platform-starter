# 0003: GitHub OIDC and Workload Identity Federation instead of JSON keys

- **Status:** Accepted
- **Date:** 2026-10-07

## Context

CI needs cloud access for two jobs:

- push container images to a registry, and
- run `terraform plan` against the GKE module.

The old way is a service account JSON key saved as a GitHub secret. That key:

- never expires unless someone rotates it,
- works from anywhere, not only from this repository's CI,
- can leak through logs, forks, laptops or a compromised third-party action,
- is easy to forget about after the person who created it leaves.

## Decision

No long-lived keys anywhere.

- **GHCR (used by this repo today):** CI logs in with the built-in
  `GITHUB_TOKEN`. It is scoped to this repository and expires when the job ends.
  No personal access token is used.
- **Google Cloud (the `terraform/gcp-gke` module):** GitHub Actions requests a
  short-lived OIDC token. GCP Workload Identity Federation trades it for a
  short-lived Google access token (one hour by default).
  - Pool `github`, provider `github-actions`, issuer
    `https://token.actions.githubusercontent.com`.
  - `attribute_condition` allows only this repository, checked by name and by
    the numeric repository and owner IDs (`assertion.repository_id`,
    `assertion.repository_owner_id`). Without a condition, any GitHub repository
    could try to use the pool. The IDs never change, so a deleted and re-created
    repository or account with the same name cannot match.
  - Two service accounts, each with only what its job needs, and each usable only
    from one kind of job (matched on GitHub's `sub` claim):
    - `gh-ci-push`: `roles/artifactregistry.writer` on one repository. Only jobs on
      the `main` branch (`repo:OWNER/REPO:ref:refs/heads/main`), so a pull request
      or another branch cannot push images.
    - `gh-tf-plan`: `roles/viewer` and `roles/iam.securityReviewer` on the project,
      plus read access to the state bucket. It cannot change anything. Only jobs in
      the GitHub Environment `tf-plan` (`repo:OWNER/REPO:environment:tf-plan`), and
      that environment has required reviewers, so pull request code never runs with
      this identity before someone has read it. `roles/viewer` is a broad basic
      role, chosen on purpose: plan must read every resource type in the module.
  - A workflow job must ask for `permissions: id-token: write` to get a token.
    Only the `plan` job in `terraform.yml` does that today. Its summary shows only
    resource counts and addresses, never the full plan, because run logs of a public
    repository are public.

## Consequences

- Nothing to rotate and nothing to leak. Tokens expire on their own.
- Access is tied to the repository (name and immutable IDs) and to the trigger:
  only `main` can push images, and only the reviewed `tf-plan` environment can plan.
- Pull requests from forks cannot get these tokens. The `plan` job also checks
  that the pull request comes from this repository.
- If GitHub's default `sub` claim format is customised for the repository, the
  two bindings in `workload-identity.tf` must be updated to match.
- Setup is a little more work the first time. The module creates the pool,
  provider and service accounts, and its README lists the GitHub variables to set.
- The module is validated (`fmt`, `validate`, `tflint`) but was not applied as
  part of this project. The `plan` job skips itself until the variables exist.

## Alternatives considered

- **JSON key in a GitHub secret.** Rejected for the reasons above.
- **Direct Workload Identity Federation** (grant roles to the GitHub identity
  itself, with no service account). One hop fewer. Not every Google Cloud
  service supports it yet, and service accounts are easier to audit.
- **Self-hosted runners with a node service account.** Then every job on that
  runner gets the same access, and we must run and patch the runners ourselves.
