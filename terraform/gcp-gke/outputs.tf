output "cluster_name" {
  description = "Name of the GKE cluster."
  value       = google_container_cluster.this.name
}

output "cluster_location" {
  description = "Zone (zonal cluster) or region (regional cluster) of the GKE cluster."
  value       = google_container_cluster.this.location
}

output "cluster_endpoint" {
  description = "Public IP of the Kubernetes API server. Reachable only from master_authorized_networks."
  value       = google_container_cluster.this.endpoint
  sensitive   = true
}

output "get_credentials_command" {
  description = "Command that adds this cluster to your kubeconfig. Tip: set KUBECONFIG to a separate file first."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.this.name} --location ${google_container_cluster.this.location} --project ${var.project_id}"
}

output "network_name" {
  description = "Name of the VPC network."
  value       = google_compute_network.vpc.name
}

output "subnet_name" {
  description = "Name of the node subnet."
  value       = google_compute_subnetwork.nodes.name
}

output "artifact_registry_url" {
  description = "Docker registry prefix for image names, for example <this>/sample-api:sha-abc1234."
  value       = "${google_artifact_registry_repository.apps.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.apps.repository_id}"
}

output "node_service_account_email" {
  description = "Service account used by the GKE nodes."
  value       = google_service_account.gke_nodes.email
}

output "ci_push_service_account_email" {
  description = "Service account that GitHub Actions impersonates to push images to Artifact Registry."
  value       = google_service_account.ci_push.email
}

output "tf_plan_service_account_email" {
  description = "Read-only service account for terraform plan in GitHub Actions. Put it in the GitHub variable GCP_TF_PLAN_SERVICE_ACCOUNT."
  value       = google_service_account.tf_plan.email
}

output "workload_identity_provider" {
  description = "Full resource name of the GitHub OIDC provider. Put it in the GitHub variable GCP_WORKLOAD_IDENTITY_PROVIDER."
  value       = google_iam_workload_identity_pool_provider.github.name
}
