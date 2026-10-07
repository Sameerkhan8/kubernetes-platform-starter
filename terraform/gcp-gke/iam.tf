# Identity for the GKE nodes.
# GKE's default is the Compute Engine default service account, which often has the Editor
# role on the whole project. This dedicated account gets only what a node needs.

resource "google_service_account" "gke_nodes" {
  account_id   = "gke-nodes"
  display_name = "GKE nodes (${var.cluster_name})"
  description  = "Least-privilege identity for the ${var.cluster_name} node VMs. Managed by Terraform."

  depends_on = [google_project_service.apis]
}

# Google's predefined role with the minimum permissions a GKE node needs,
# mainly writing logs and metrics. Nothing else.
resource "google_project_iam_member" "gke_nodes_default" {
  project = var.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = google_service_account.gke_nodes.member
}

# Nodes may pull images from this project's Artifact Registry repository only,
# not from every repository in the project.
resource "google_artifact_registry_repository_iam_member" "gke_nodes_reader" {
  project    = google_artifact_registry_repository.apps.project
  location   = google_artifact_registry_repository.apps.location
  repository = google_artifact_registry_repository.apps.name
  role       = "roles/artifactregistry.reader"
  member     = google_service_account.gke_nodes.member
}
