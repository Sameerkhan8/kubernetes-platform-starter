# Private Docker registry next to the cluster (same region: faster pulls, no cross-region egress).

resource "google_artifact_registry_repository" "apps" {
  repository_id = var.artifact_registry_repo
  location      = var.region
  format        = "DOCKER"
  description   = "Container images for ${var.cluster_name}. Managed by Terraform."

  # Immutable tags: once sha-abc1234 or 1.4.0 is pushed, it can never point at a different image.
  # What runs in the cluster is then always what was tested and scanned.
  docker_config {
    immutable_tags = var.immutable_tags
  }

  # Start in dry-run: Artifact Registry only logs what it WOULD delete.
  # Read those logs and compare them with what is deployed before you set this to false.
  cleanup_policy_dry_run = var.cleanup_dry_run

  # Delete images that have no tag and are older than 30 days.
  cleanup_policies {
    id     = "delete-untagged-older-than-30d"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "2592000s" # 30 days
    }
  }

  # KEEP wins over DELETE: the 20 newest versions are never deleted, tagged or not.
  cleanup_policies {
    id     = "keep-20-most-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 20
    }
  }

  depends_on = [google_project_service.apis]
}
