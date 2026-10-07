# GKE Standard cluster with private nodes, plus one autoscaling node pool.

resource "google_container_cluster" "this" {
  name        = var.cluster_name
  description = "GKE cluster for kubernetes-platform-starter. Managed by Terraform."
  location    = local.location

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.nodes.id

  # GKE always creates a default node pool. We delete it right away and manage our own
  # pool below, so node pool changes never force the whole cluster to be replaced.
  remove_default_node_pool = true
  initial_node_count       = 1

  # Only used by that short-lived default pool. Without this block it would run, for a
  # few minutes, as the Compute Engine default service account (which often has Editor).
  node_config {
    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  # VPC-native networking: pods and services get IPs from the subnet's secondary ranges.
  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Private nodes: no public IPs on the VMs. The control plane keeps a public endpoint,
  # but only the CIDRs in master_authorized_networks can reach it (see below).
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_ipv4_cidr
  }

  # Always enabled. With an empty list, no outside network can reach the public API endpoint.
  # Add your office or VPN egress IP (as /32) in terraform.tfvars to use kubectl.
  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.master_authorized_networks
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  # GKE picks the version and upgrades the control plane and nodes on this channel.
  release_channel {
    channel = var.release_channel
  }

  # Workload Identity: pods use a Kubernetes service account that maps to a Google
  # service account. No JSON key files inside the cluster.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Dataplane V2 (eBPF/Cilium). It also enforces Kubernetes NetworkPolicy, so the chart's
  # default-deny policies are enforced here too. One difference from kind: GKE's managed
  # Gateway runs no pods in the cluster, so the app must allow Google's load balancer
  # ranges by CIDR instead of a gateway namespace (see charts/sample-api/values-prod.yaml).
  datapath_provider = "ADVANCED_DATAPATH"

  # GKE's managed Gateway API controller, the same API the local kind setup uses.
  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  # Secure Boot and integrity monitoring for node VMs.
  enable_shielded_nodes = true

  # Automatic upgrades happen only on weekends, 02:00-10:00 UTC (8 hours on Saturday and Sunday).
  # GKE needs at least 48 hours of maintenance time in any 32-day period; this gives at least 64.
  # The dates only set the time of day and the start; the window repeats every week.
  maintenance_policy {
    recurring_window {
      start_time = "2026-01-03T02:00:00Z"
      end_time   = "2026-01-03T10:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
    }
  }

  # Adds cluster and namespace labels to the billing export, so cost can be split per team.
  cost_management_config {
    enabled = true
  }

  # Protects the cluster from an accidental terraform destroy. Set to false first to delete it.
  deletion_protection = var.deletion_protection

  lifecycle {
    # node_config above only applies to the deleted default pool; ignore later drift in it.
    ignore_changes = [node_config]
  }

  depends_on = [
    google_project_service.apis,
    google_project_iam_member.gke_nodes_default,
  ]
}

resource "google_container_node_pool" "general" {
  name     = "general"
  cluster  = google_container_cluster.this.id
  location = google_container_cluster.this.location

  # Nodes per zone at creation time. After that the cluster autoscaler decides.
  initial_node_count = 1

  autoscaling {
    # "total" limits count nodes across all zones of the pool (zonal or regional).
    total_min_node_count = var.min_nodes
    total_max_node_count = var.max_nodes
    location_policy      = "BALANCED"
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # Upgrade one extra node at a time and never take a node away before its replacement
  # is ready. Together with the app's PodDisruptionBudget this keeps capacity during upgrades.
  upgrade_settings {
    strategy        = "SURGE"
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type = var.machine_type
    disk_size_gb = var.disk_size_gb
    disk_type    = "pd-balanced"
    image_type   = "COS_CONTAINERD" # Container-Optimized OS: small, read-only root, auto-updated

    # Spot VMs are much cheaper but Google can reclaim them at any time. Fine for dev and demos.
    spot = var.spot

    # Least-privilege node identity (iam.tf). Access is controlled by IAM roles, so the
    # broad cloud-platform scope is the recommended setting with a custom service account.
    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    # Pods see the GKE metadata server, not the node's. Required for Workload Identity, and it
    # stops pods from reading the node's own credentials.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }

    # Kubernetes node labels (for nodeSelector / affinity).
    labels = {
      pool = "general"
    }

    # Google Cloud labels on the VMs (billing, inventory).
    resource_labels = local.labels

    # Network tag used by the webhook firewall rule in network.tf.
    tags = [local.node_tag]
  }
}
