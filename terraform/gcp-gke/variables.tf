# --- Project and location -----------------------------------------------------

variable "project_id" {
  description = "Google Cloud project ID to deploy into (for example my-gcp-project-id)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be 6-30 characters: lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "region" {
  description = "Region for the subnet, Cloud NAT, Artifact Registry and (when regional = true) the cluster."
  type        = string
  default     = "us-central1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "region must look like us-central1 or europe-west4."
  }
}

variable "zone" {
  description = "Zone for a zonal cluster (used when regional = false). Must be inside region."
  type        = string
  default     = "us-central1-a"

  validation {
    condition     = startswith(var.zone, "${var.region}-")
    error_message = "zone must be a zone of the selected region, for example us-central1-a for us-central1."
  }
}

variable "subnet_flow_logs" {
  description = "Turn on VPC Flow Logs for the node subnet (a record of network connections, for investigations). Billed by log volume."
  type        = bool
  default     = true
}

variable "flow_logs_sampling" {
  description = "Share of flows that VPC Flow Logs records, from 0 (nothing) to 1 (everything). A low value keeps the logging cost down."
  type        = number
  default     = 0.1

  validation {
    condition     = var.flow_logs_sampling > 0 && var.flow_logs_sampling <= 1
    error_message = "flow_logs_sampling must be greater than 0 and at most 1."
  }
}

variable "regional" {
  description = "true = regional cluster (control plane and nodes in 3 zones). false = zonal cluster (cheaper, one zone)."
  type        = bool
  default     = false
}

# --- Names --------------------------------------------------------------------

variable "cluster_name" {
  description = "Name of the GKE cluster. Also used as the prefix for subnet, router, NAT and firewall names."
  type        = string
  default     = "kps-gke"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,18}[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be 2-20 characters: lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "network_name" {
  description = "Name of the VPC network."
  type        = string
  default     = "kps-vpc"

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$", var.network_name))
    error_message = "network_name must be a valid Compute Engine name (lowercase letters, digits, hyphens; max 63)."
  }
}

# --- IP ranges ----------------------------------------------------------------

variable "subnet_cidr" {
  description = "Primary range of the subnet (node IPs)."
  type        = string
  default     = "10.10.0.0/20"

  validation {
    condition     = can(cidrhost(var.subnet_cidr, 0))
    error_message = "subnet_cidr must be a valid IPv4 CIDR."
  }
}

variable "pods_cidr" {
  description = "Secondary range for pod IPs. Each node takes a /24 from it by default."
  type        = string
  default     = "10.20.0.0/14"

  validation {
    condition     = can(cidrhost(var.pods_cidr, 0))
    error_message = "pods_cidr must be a valid IPv4 CIDR."
  }
}

variable "services_cidr" {
  description = "Secondary range for Kubernetes Service (ClusterIP) IPs."
  type        = string
  default     = "10.24.0.0/20"

  validation {
    condition     = can(cidrhost(var.services_cidr, 0))
    error_message = "services_cidr must be a valid IPv4 CIDR."
  }
}

variable "master_ipv4_cidr" {
  description = "Private /28 range for the GKE control plane. Must not overlap any other range in the VPC."
  type        = string
  default     = "172.16.0.0/28"

  validation {
    condition     = can(cidrhost(var.master_ipv4_cidr, 0)) && endswith(var.master_ipv4_cidr, "/28")
    error_message = "master_ipv4_cidr must be a valid IPv4 /28 range, for example 172.16.0.0/28."
  }
}

variable "master_authorized_networks" {
  description = "Networks allowed to reach the public Kubernetes API endpoint. Empty list = no external access."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []

  validation {
    condition     = alltrue([for n in var.master_authorized_networks : can(cidrhost(n.cidr_block, 0))])
    error_message = "Every master_authorized_networks entry needs a valid IPv4 cidr_block, for example 203.0.113.10/32."
  }
}

# --- Cluster and nodes --------------------------------------------------------

variable "release_channel" {
  description = "GKE release channel: RAPID, REGULAR or STABLE. GKE upgrades the cluster automatically on this channel."
  type        = string
  default     = "REGULAR"

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE"], var.release_channel)
    error_message = "release_channel must be RAPID, REGULAR or STABLE."
  }
}

variable "machine_type" {
  description = "Compute Engine machine type for the nodes."
  type        = string
  default     = "e2-standard-4"
}

variable "disk_size_gb" {
  description = "Boot disk size per node, in GB."
  type        = number
  default     = 50

  validation {
    condition     = var.disk_size_gb >= 10
    error_message = "disk_size_gb must be at least 10 (the GKE minimum)."
  }
}

variable "min_nodes" {
  description = "Minimum number of nodes in the pool, counted across all zones."
  type        = number
  default     = 1

  validation {
    condition     = var.min_nodes >= 0 && floor(var.min_nodes) == var.min_nodes
    error_message = "min_nodes must be a whole number >= 0."
  }
}

variable "max_nodes" {
  description = "Maximum number of nodes in the pool, counted across all zones."
  type        = number
  default     = 3

  validation {
    condition     = var.max_nodes >= 1 && floor(var.max_nodes) == var.max_nodes && var.max_nodes >= var.min_nodes
    error_message = "max_nodes must be a whole number >= 1 and >= min_nodes."
  }
}

variable "spot" {
  description = "Use Spot VMs for the node pool. Much cheaper, but Google can stop them at any time. Good for dev, not for prod."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Block terraform destroy of the cluster. Set to false and apply before you delete it."
  type        = bool
  default     = true
}

# --- Artifact Registry --------------------------------------------------------

variable "artifact_registry_repo" {
  description = "ID of the Docker repository in Artifact Registry."
  type        = string
  default     = "apps"

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$", var.artifact_registry_repo))
    error_message = "artifact_registry_repo must be lowercase letters, digits and hyphens, starting with a letter (max 63)."
  }
}

variable "immutable_tags" {
  description = "Make image tags immutable, so a tag can never be moved to a different image."
  type        = bool
  default     = true
}

variable "cleanup_dry_run" {
  description = "Run the cleanup policies in dry-run mode (log only, delete nothing). Check the logs before you set this to false."
  type        = bool
  default     = true
}

# --- GitHub Actions (Workload Identity Federation) ----------------------------

variable "github_repository" {
  description = "GitHub repository (owner/name) whose Actions workflows may use the CI service accounts."
  type        = string
  default     = "Sameerkhan8/kubernetes-platform-starter"

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "github_repository must look like owner/name."
  }
}

variable "github_repository_id" {
  description = "Numeric ID of the GitHub repository (gh api repos/OWNER/REPO --jq .id). Unlike the name, it never changes and is never reused."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "github_repository_id must be the numeric repository ID, for example 123456789."
  }
}

variable "github_owner_id" {
  description = "Numeric ID of the GitHub user or organization that owns the repository (gh api users/OWNER --jq .id)."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_owner_id))
    error_message = "github_owner_id must be the numeric owner ID, for example 12345678."
  }
}

variable "tf_plan_environment" {
  description = "GitHub Environment the terraform.yml plan job runs in. Only jobs in this environment may use the plan identity. Give it required reviewers."
  type        = string
  default     = "tf-plan"

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.tf_plan_environment))
    error_message = "tf_plan_environment must be a simple environment name (letters, digits, '.', '_' and '-')."
  }
}

variable "tf_state_bucket" {
  description = "Name of the GCS bucket that holds the Terraform state. When set, the plan service account gets read access to it. Empty = skip."
  type        = string
  default     = ""

  validation {
    condition     = var.tf_state_bucket == "" || can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.tf_state_bucket))
    error_message = "tf_state_bucket must be empty or a valid bucket name (no gs:// prefix)."
  }
}

# --- Labels -------------------------------------------------------------------

variable "labels" {
  description = "Labels added to every resource that supports them. A 'cluster' label is added automatically."
  type        = map(string)
  default = {
    project    = "kubernetes-platform-starter"
    managed-by = "terraform"
  }

  validation {
    condition = alltrue([
      for k, v in var.labels :
      can(regex("^[a-z][a-z0-9_-]{0,62}$", k)) && can(regex("^[a-z0-9_-]{0,63}$", v))
    ])
    error_message = "Label keys must start with a lowercase letter; keys and values may use lowercase letters, digits, '_' and '-' (max 63)."
  }
}
