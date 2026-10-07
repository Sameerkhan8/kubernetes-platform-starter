# Terraform state lives in a Google Cloud Storage bucket.
#
# This is a "partial" backend configuration: the bucket name and prefix are passed
# at init time, so no project-specific value is stored in git.
#
#   terraform init \
#     -backend-config="bucket=<your-state-bucket>" \
#     -backend-config="prefix=gcp-gke"
#
# For offline checks (CI validate job, make lint-tf) no bucket is needed:
#
#   terraform init -backend=false
#
# The GCS backend locks the state during apply, so two people cannot apply at once.
terraform {
  backend "gcs" {}
}
