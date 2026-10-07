# Workload Identity Federation for GitHub Actions.
#
# GitHub gives each workflow run a short-lived OIDC token. Google exchanges it for a
# short-lived access token of a service account. No JSON key is created, stored in
# GitHub secrets, or needs rotation.
#
#   GitHub Actions run --OIDC token--> pool "github" / provider "github-actions"
#        --> impersonates gh-ci-push (push images) or gh-tf-plan (read-only plan)
#
# Who may impersonate what is decided by GitHub's "sub" claim, which names the repository
# and what triggered the job:
#   repo:OWNER/REPO:ref:refs/heads/main     a job on the main branch (no GitHub Environment)
#   repo:OWNER/REPO:environment:NAME        a job that runs in a GitHub Environment
#   repo:OWNER/REPO:pull_request            a pull request job

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = local.wif_pool_id
  display_name              = "GitHub Actions"
  description               = "Federated identities for GitHub Actions workflows of ${var.github_repository}."

  depends_on = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = local.wif_provider_id
  display_name                       = "GitHub Actions OIDC"
  description                        = "Trusts OIDC tokens issued by GitHub Actions."

  # Copy claims from GitHub's token into attributes that IAM bindings can match on.
  attribute_mapping = {
    "google.subject"                = "assertion.sub"
    "attribute.repository"          = "assertion.repository"
    "attribute.repository_id"       = "assertion.repository_id"
    "attribute.repository_owner"    = "assertion.repository_owner"
    "attribute.repository_owner_id" = "assertion.repository_owner_id"
    "attribute.ref"                 = "assertion.ref"
  }

  # Only tokens from this one repository are accepted. Any other GitHub repository
  # (including forks) is rejected before an IAM binding is even checked. The numeric IDs
  # never change, so a deleted and re-created owner or repository with the same name
  # cannot match.
  attribute_condition = join(" && ", [
    "assertion.repository == \"${var.github_repository}\"",
    "assertion.repository_id == \"${var.github_repository_id}\"",
    "assertion.repository_owner_id == \"${var.github_owner_id}\"",
  ])

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

locals {
  github_pool = google_iam_workload_identity_pool.github.name

  # Only jobs that run on the main branch (after review and merge). Pull requests,
  # other branches and manual runs from other branches cannot push images.
  ci_push_principal = "principal://iam.googleapis.com/${local.github_pool}/subject/repo:${var.github_repository}:ref:refs/heads/main"

  # Only jobs that run in the GitHub Environment var.tf_plan_environment. Give that
  # environment required reviewers, so a pull request cannot run code with this identity
  # before someone has looked at it.
  tf_plan_principal = "principal://iam.googleapis.com/${local.github_pool}/subject/repo:${var.github_repository}:environment:${var.tf_plan_environment}"
}

# --- CI image push -----------------------------------------------------------

resource "google_service_account" "ci_push" {
  account_id   = "gh-ci-push"
  display_name = "GitHub Actions: push images"
  description  = "Used by CI in ${var.github_repository} to push images to Artifact Registry. No keys."

  depends_on = [google_project_service.apis]
}

resource "google_service_account_iam_member" "ci_push_wif" {
  service_account_id = google_service_account.ci_push.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.ci_push_principal
}

# Write access to this one repository only.
resource "google_artifact_registry_repository_iam_member" "ci_push_writer" {
  project    = google_artifact_registry_repository.apps.project
  location   = google_artifact_registry_repository.apps.location
  repository = google_artifact_registry_repository.apps.name
  role       = "roles/artifactregistry.writer"
  member     = google_service_account.ci_push.member
}

# --- Terraform plan on pull requests -----------------------------------------

resource "google_service_account" "tf_plan" {
  account_id   = "gh-tf-plan"
  display_name = "GitHub Actions: terraform plan"
  description  = "Read-only identity for terraform plan in ${var.github_repository} pull requests. No keys."

  depends_on = [google_project_service.apis]
}

resource "google_service_account_iam_member" "tf_plan_wif" {
  service_account_id = google_service_account.tf_plan.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.tf_plan_principal
}

# Read-only: plan can read resources and their IAM policies, but cannot change anything.
# roles/viewer is a broad basic role, chosen on purpose: plan has to read every resource
# type in this module, and a hand-picked list of viewer roles breaks each time a resource
# type is added. The identity is still read-only and limited to the reviewed environment.
resource "google_project_iam_member" "tf_plan_readonly" {
  for_each = toset([
    "roles/viewer",
    "roles/iam.securityReviewer",
  ])

  project = var.project_id
  role    = each.value
  member  = google_service_account.tf_plan.member
}

# Read the Terraform state. Plan runs with -lock=false, so no write access is needed.
resource "google_storage_bucket_iam_member" "tf_plan_state_reader" {
  count = var.tf_state_bucket == "" ? 0 : 1

  bucket = var.tf_state_bucket
  role   = "roles/storage.objectViewer"
  member = google_service_account.tf_plan.member
}
