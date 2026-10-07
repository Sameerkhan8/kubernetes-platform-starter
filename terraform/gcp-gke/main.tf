# Shared values and the Google APIs this module needs.
# The other resources are split by topic: network.tf, gke.tf, iam.tf,
# artifact-registry.tf and workload-identity.tf.

locals {
  # Prefix for the subnet, router, NAT and firewall rule names.
  name_prefix = var.cluster_name

  # A zonal cluster is cheaper (and its management fee is covered by the GKE free tier).
  # A regional cluster runs the control plane in three zones and survives a zone outage.
  location = var.regional ? var.region : var.zone

  # Network tag set on every node. The webhook firewall rule in network.tf targets it.
  node_tag = "${var.cluster_name}-node"

  # Labels for every resource that supports them (see default_labels in providers.tf).
  labels = merge(var.labels, { cluster = var.cluster_name })

  # IDs of the Workload Identity Federation pool and provider (workload-identity.tf).
  # A deleted pool or provider keeps its ID reserved for 30 days. If you destroy and
  # re-create within that time, change these IDs or undelete the old pool first.
  wif_pool_id     = "github"
  wif_provider_id = "github-actions"

  # Google APIs used by this module.
  apis = toset([
    "artifactregistry.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
  ])
}

resource "google_project_service" "apis" {
  for_each = local.apis

  project = var.project_id
  service = each.value

  # Never switch an API off on destroy. Other workloads in the project may still use it.
  disable_on_destroy = false
}
