provider "google" {
  project = var.project_id
  region  = var.region

  # Added to every resource that supports labels (cluster, Artifact Registry, ...).
  # Labels show up in the billing export, so costs can be grouped per project and cluster.
  default_labels = local.labels
}
