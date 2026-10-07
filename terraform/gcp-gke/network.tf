# A dedicated VPC for the cluster.
# Nodes have private IPs only. They reach the internet (image pulls, external APIs)
# through Cloud NAT, and Google APIs through Private Google Access.

resource "google_compute_network" "vpc" {
  name                    = var.network_name
  description             = "VPC for the ${var.cluster_name} GKE cluster."
  auto_create_subnetworks = false # custom mode: we choose every subnet and range ourselves
  routing_mode            = "REGIONAL"

  depends_on = [google_project_service.apis]
}

resource "google_compute_subnetwork" "nodes" {
  name          = "${local.name_prefix}-subnet"
  description   = "Nodes of ${var.cluster_name}. Secondary ranges hold pod and service IPs (VPC-native cluster)."
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = var.subnet_cidr

  # Lets private nodes call Google APIs (Artifact Registry, Cloud Logging, ...) without a public IP.
  private_ip_google_access = true

  # Pod IPs. One /24 per node by default (110 pods per node).
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  # ClusterIP Service IPs.
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }

  # VPC Flow Logs: who talked to whom, for network investigations. Billed by log volume,
  # so only a sample of the flows is kept (var.flow_logs_sampling, 10% by default).
  dynamic "log_config" {
    for_each = var.subnet_flow_logs ? [1] : []
    content {
      aggregation_interval = "INTERVAL_5_SEC"
      flow_sampling        = var.flow_logs_sampling
      metadata             = "INCLUDE_ALL_METADATA"
    }
  }
}

# Cloud Router + Cloud NAT: outbound internet for private nodes, no inbound path.
resource "google_compute_router" "nat" {
  name    = "${local.name_prefix}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name   = "${local.name_prefix}-nat"
  router = google_compute_router.nat.name
  region = var.region

  # Google picks and manages the external NAT IPs. Use MANUAL_ONLY with reserved IPs
  # if a partner needs to allow-list a fixed egress IP.
  nat_ip_allocate_option = "AUTO_ONLY"

  # NAT only this cluster's subnet (all ranges: nodes and pods).
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  subnetwork {
    name                    = google_compute_subnetwork.nodes.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  # Log only failed translations (for example port exhaustion). Full logging is noisy and costs money.
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# Private GKE gotcha: GKE's automatic firewall rules let the control plane reach nodes
# only on ports 443 and 10250. Admission webhooks that listen on other ports time out
# and block deploys (for example "failed calling webhook ... context deadline exceeded").
# Common webhook ports: 8443 (many operators), 9443 (controller-runtime default), 15017 (Istio).
resource "google_compute_firewall" "control_plane_to_webhooks" {
  name        = "${local.name_prefix}-allow-webhooks-from-control-plane"
  description = "Allow the GKE control plane to call admission webhooks running on the nodes."
  network     = google_compute_network.vpc.id
  direction   = "INGRESS"
  priority    = 1000

  source_ranges = [var.master_ipv4_cidr]
  target_tags   = [local.node_tag]

  allow {
    protocol = "tcp"
    ports    = ["8443", "9443", "15017"]
  }
}
