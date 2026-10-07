# tflint configuration. Run from this directory:
#   tflint --init && tflint
config {
  format = "compact"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "google" {
  enabled = true
  version = "0.40.0"
  source  = "github.com/terraform-linters/tflint-ruleset-google"
}
