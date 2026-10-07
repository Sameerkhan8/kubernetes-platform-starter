terraform {
  # 1.9 is the first release that lets a variable validation read other variables
  # (used for min_nodes <= max_nodes and zone-in-region checks).
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.6"
    }
  }
}
