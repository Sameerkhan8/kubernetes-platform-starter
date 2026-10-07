SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help
.NOTPARALLEL:

include versions.env

CLUSTER_NAME := kps
KUBE_CONTEXT := kind-kps
# Force the repo-local kubeconfig. ':=' in a Makefile overrides any KUBECONFIG from the environment,
# and 'override' also beats "make KUBECONFIG=..." on the command line. (The scripts set it again.)
override export KUBECONFIG := $(CURDIR)/.kube/config
# Helm lets these override the API server and credentials even with --kube-context.
# Never pass them to a recipe (scripts/lib.sh also unsets them, and the guard refuses them).
unexport HELM_KUBEAPISERVER HELM_KUBETOKEN HELM_KUBECAFILE HELM_KUBEINSECURE_SKIP_TLS_VERIFY \
  HELM_KUBEASUSER HELM_KUBEASGROUPS HELM_KUBETLS_SERVER_NAME HELM_KUBECONTEXT
# For ad-hoc recipes. The scripts use kubectl_kps / helm_kps from scripts/lib.sh, which pin the same context.
KUBECTL := kubectl --context $(KUBE_CONTEXT)
HELM    := helm --kube-context $(KUBE_CONTEXT)

# Gateway ports on 127.0.0.1. Empty = 80/443 for a new cluster, or the ports an existing
# cluster was created with (scripts/lib.sh reads them with "docker port").
# Example when 80/443 are busy: HOST_HTTP_PORT=8080 HOST_HTTPS_PORT=8443 make up
HOST_HTTP_PORT  ?=
HOST_HTTPS_PORT ?=
# Empty = local git daemon (make gitops-local). Set it to deploy from GitHub (make gitops).
REPO_URL        ?=
# local = sample-api:dev built here and loaded into kind; ghcr = image from values-dev.yaml.
IMAGE_SOURCE    ?= local
# Must stay sample-api:dev unless you also change charts/sample-api/values-local.yaml.
IMAGE           ?= sample-api:dev
LOAD_DURATION   ?= 180
LOAD_CONCURRENCY ?= 8
WORK_MS         ?= 100
export HOST_HTTP_PORT HOST_HTTPS_PORT REPO_URL IMAGE_SOURCE IMAGE LOAD_DURATION LOAD_CONCURRENCY WORK_MS

##@ Safety

.PHONY: guard
guard: ## Abort unless kubectl points at the local kind cluster
	@scripts/guard-context.sh

##@ Getting started

.PHONY: help
help: ## List the targets
	@awk 'BEGIN {FS = ":.*## "} \
	  /^##@/ {printf "\n%s\n", substr($$0, 5); next} \
	  /^[a-zA-Z0-9_-]+:.*## / {printf "  %-18s %s\n", $$1, $$2}' $(firstword $(MAKEFILE_LIST))
	@echo
	@echo "Every cluster target uses $(KUBECONFIG) and context $(KUBE_CONTEXT) only."

.PHONY: doctor
doctor: ## Check prerequisites, free ports, RAM and inotify limits (no cluster access)
	@scripts/doctor.sh

.PHONY: up
up: cluster gateway-api-crds metrics-server monitoring gateway argocd image app urls ## Create the cluster and install everything

.PHONY: urls
urls: ## Print the local URLs (no cluster access)
	@scripts/urls.sh

.PHONY: creds
creds: guard ## Print the Grafana and Argo CD admin passwords (terminal only)
	@scripts/creds.sh

.PHONY: status
status: guard ## Show nodes, pods, HPA, PDB, routes and the Argo CD app
	@scripts/status.sh

##@ Cluster and platform (run in this order by "make up")

.PHONY: cluster
cluster: ## Create the kind cluster "kps" if missing, then verify the kube context
	@scripts/cluster.sh up

.PHONY: gateway-api-crds
gateway-api-crds: guard ## Install the Gateway API CRDs (standard channel)
	@scripts/platform.sh gateway-api-crds

.PHONY: metrics-server
metrics-server: guard ## Install metrics-server (CPU metrics for the HPA)
	@scripts/platform.sh metrics-server

.PHONY: monitoring
monitoring: guard ## Install kube-prometheus-stack, the Grafana admin Secret and the platform alerts
	@scripts/platform.sh monitoring

.PHONY: gateway
gateway: guard ## Install Traefik as the Gateway API controller
	@scripts/platform.sh gateway

.PHONY: argocd
argocd: guard ## Install Argo CD
	@scripts/platform.sh argocd

.PHONY: image
image: guard ## Build sample-api:dev and load it into kind (restarts the app if deployed)
	@scripts/image.sh

.PHONY: app
app: guard ## Deploy sample-api with Argo CD (local git daemon, or GitHub if REPO_URL is set)
	@scripts/gitops.sh $(if $(strip $(REPO_URL)),remote,local)

.PHONY: gitops-local
gitops-local: guard ## GitOps from a local git daemon (works before the repo is pushed)
	@scripts/gitops.sh local

.PHONY: gitops
gitops: guard ## GitOps from REPO_URL, e.g. make gitops REPO_URL=https://github.com/Sameerkhan8/kubernetes-platform-starter.git
	@scripts/gitops.sh remote

##@ Demos

.PHONY: smoke
smoke: guard ## Call every URL through the gateway and print PASS/FAIL
	@scripts/smoke.sh

.PHONY: load
load: guard ## Load /work through the gateway and watch the HPA scale (LOAD_DURATION, LOAD_CONCURRENCY, WORK_MS)
	@scripts/load.sh

.PHONY: rollout-test
rollout-test: guard ## Rolling restart under steady traffic; PASS means 0 failed requests
	@scripts/rollout-test.sh

.PHONY: alert-demo
alert-demo: guard ## Inject 5xx errors until SampleApiHighErrorRate fires, then show the alert
	@scripts/alert-demo.sh

.PHONY: policy-test
policy-test: guard ## Prove the NetworkPolicies (ingress, egress) and Pod Security "restricted" with throwaway pods
	@scripts/policy-test.sh

##@ Quality (no cluster needed)

.PHONY: test
test: ## Run ruff + pytest inside the Dockerfile "test" stage
	docker build --target test --progress=plain -t kps-sample-api-test:local app/

.PHONY: lint
lint: lint-helm lint-k8s lint-rules lint-tf lint-sh ## Run every static check

.PHONY: lint-helm
lint-helm: ## helm lint --strict with default, dev, prod and local values
	@scripts/lint.sh helm

.PHONY: lint-k8s
lint-k8s: ## kubeconform on the rendered chart and the Argo CD manifests
	@scripts/lint.sh k8s

.PHONY: lint-rules
lint-rules: ## promtool check + alert unit tests; every alert has a runbook
	@scripts/lint.sh rules

.PHONY: lint-tf
lint-tf: ## terraform fmt/validate (no backend) + terraform test (mocked) + tflint
	@scripts/lint.sh tf

.PHONY: lint-sh
lint-sh: ## shellcheck + no bare kubectl/helm in scripts
	@scripts/lint.sh sh

##@ Cleanup

.PHONY: down
down: ## Delete the kind cluster and the kps-git container (images are kept)
	@scripts/cluster.sh down

.PHONY: clean
clean: down ## down, then remove the local state in .gitops/ and .kube/
	rm -rf .gitops .kube
