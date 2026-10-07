# Offline unit tests for this module: terraform test
#
# The google provider is mocked, so these tests need no credentials, make no API calls
# and create nothing. They only run "plan" and check the planned values and the
# input validations.

mock_provider "google" {}

variables {
  project_id           = "my-gcp-project-id"
  github_repository_id = "123456789"
  github_owner_id      = "12345678"
}

run "zonal_cluster_defaults" {
  command = plan

  assert {
    condition     = google_container_cluster.this.location == "us-central1-a"
    error_message = "With regional = false the cluster must be created in var.zone."
  }

  assert {
    condition     = google_container_cluster.this.private_cluster_config[0].enable_private_nodes == true
    error_message = "Nodes must be private (no public IPs)."
  }

  assert {
    condition     = length(google_container_cluster.this.master_authorized_networks_config[0].cidr_blocks) == 0
    error_message = "With no authorized networks, no external CIDR may reach the API server."
  }

  assert {
    condition     = google_container_cluster.this.workload_identity_config[0].workload_pool == "my-gcp-project-id.svc.id.goog"
    error_message = "Workload Identity must use the project's workload pool."
  }

  assert {
    condition     = google_container_cluster.this.datapath_provider == "ADVANCED_DATAPATH"
    error_message = "Dataplane V2 is required so NetworkPolicy is enforced."
  }

  assert {
    condition     = google_container_node_pool.general.node_config[0].workload_metadata_config[0].mode == "GKE_METADATA"
    error_message = "Pods must use the GKE metadata server (Workload Identity)."
  }

  assert {
    condition     = google_container_node_pool.general.upgrade_settings[0].max_unavailable == 0
    error_message = "Node upgrades must not remove capacity before a new node is ready."
  }

  assert {
    condition     = length(google_storage_bucket_iam_member.tf_plan_state_reader) == 0
    error_message = "No state bucket binding may be created when tf_state_bucket is empty."
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.github.attribute_condition == "assertion.repository == \"Sameerkhan8/kubernetes-platform-starter\" && assertion.repository_id == \"123456789\" && assertion.repository_owner_id == \"12345678\""
    error_message = "The OIDC provider must only accept tokens from the configured repository (name and immutable IDs)."
  }

  assert {
    condition     = google_compute_subnetwork.nodes.log_config[0].flow_sampling == 0.1 && google_compute_subnetwork.nodes.log_config[0].metadata == "INCLUDE_ALL_METADATA"
    error_message = "VPC Flow Logs must be on by default, with a 10% sample."
  }

  assert {
    condition     = google_artifact_registry_repository.apps.docker_config[0].immutable_tags == true
    error_message = "Image tags must be immutable by default."
  }

  assert {
    condition     = google_artifact_registry_repository.apps.cleanup_policy_dry_run == true
    error_message = "Cleanup policies must start in dry-run mode."
  }

  assert {
    condition     = output.artifact_registry_url == "us-central1-docker.pkg.dev/my-gcp-project-id/apps"
    error_message = "Unexpected Artifact Registry URL."
  }

  assert {
    condition     = output.get_credentials_command == "gcloud container clusters get-credentials kps-gke --location us-central1-a --project my-gcp-project-id"
    error_message = "Unexpected get-credentials command."
  }
}

run "regional_cluster_with_state_bucket" {
  command = plan

  variables {
    regional        = true
    tf_state_bucket = "my-gcp-project-id-tfstate"
    master_authorized_networks = [
      {
        cidr_block   = "203.0.113.10/32"
        display_name = "office-vpn-example"
      },
    ]
  }

  assert {
    condition     = google_container_cluster.this.location == "us-central1"
    error_message = "With regional = true the cluster must be created in var.region."
  }

  assert {
    condition     = length(google_storage_bucket_iam_member.tf_plan_state_reader) == 1
    error_message = "The plan identity needs read access to the state bucket when one is set."
  }

  assert {
    condition     = length(google_container_cluster.this.master_authorized_networks_config[0].cidr_blocks) == 1
    error_message = "Each authorized network must become one cidr_blocks entry."
  }
}

run "rejects_zone_outside_region" {
  command = plan

  variables {
    zone = "europe-west4-a"
  }

  expect_failures = [var.zone]
}

run "rejects_min_nodes_above_max_nodes" {
  command = plan

  variables {
    min_nodes = 4
    max_nodes = 3
  }

  expect_failures = [var.max_nodes]
}

run "rejects_control_plane_range_that_is_not_a_28" {
  command = plan

  variables {
    master_ipv4_cidr = "172.16.0.0/24"
  }

  expect_failures = [var.master_ipv4_cidr]
}

run "rejects_unknown_release_channel" {
  command = plan

  variables {
    release_channel = "NIGHTLY"
  }

  expect_failures = [var.release_channel]
}

run "flow_logs_can_be_turned_off" {
  command = plan

  variables {
    subnet_flow_logs = false
  }

  assert {
    condition     = length(google_compute_subnetwork.nodes.log_config) == 0
    error_message = "subnet_flow_logs = false must remove the log_config block."
  }
}

run "rejects_non_numeric_repository_id" {
  command = plan

  variables {
    github_repository_id = "kubernetes-platform-starter"
  }

  expect_failures = [var.github_repository_id]
}
