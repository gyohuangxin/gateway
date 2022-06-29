# Golang variables
GOOS ?= $(shell go env GOOS)
GOARCH ?= $(shell go env GOARCH)

# nescessary

# Docker variables
# REGISTRY is the image registry to use for build and push image targets.
REGISTRY ?= docker.io/envoyproxy
# IMAGE is the image URL for build and push image targets.
IMAGE ?= ${REGISTRY}/gateway-dev
# REV is the short git sha of latest commit.
REV=$(shell git rev-parse --short HEAD)
# Tag is the tag to use for build and push image targets.
TAG ?= $(REV)
# ENVTEST_K8S_VERSION refers to the version of kubebuilder assets to be downloaded by envtest binary.
ENVTEST_K8S_VERSION = 1.23

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# Setting SHELL to bash allows bash commands to be executed by recipes.
# This is a requirement for 'setup-envtest.sh' in the test target.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help
	@echo Envoy Gateway is an open source project for managing Envoy Proxy as a standalone or Kubernetes-based application gateway
	@echo
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Build

.DEFAULT_GOAL = build

include build-aux/tools.mk

.PHONY: build build-linux-amd64 build-linux-arm64 build-all
build: bin/${GOOS}/${GOARCH}/envoy-gateway ## Build the envoy-gateway binary
build-linux-amd64: bin/linux/amd64/envoy-gateway
build-linux-arm64: bin/linux/arm64/envoy-gateway
build-all: build-linux-amd64 build-linux-arm64
bin/%/envoy-gateway: FORCE
	CGO_ENABLED=0 GOOS=$(word 1,$(subst /, ,$*)) GOARCH=$(word 2,$(subst /, ,$*)) go build -o $@ github.com/envoyproxy/gateway/cmd/envoy-gateway

.PHONY: test
test:
	go test ./...

.PHONY: docker-build
docker-build: build-all ## Build the envoy-gateway docker image.
	DOCKER_BUILDKIT=1 docker build -t $(IMAGE):$(TAG) -f Dockerfile bin

.PHONY: docker-push
docker-push: ## Push the docker image for envoy-gateway.
	docker push $(IMAGE):$(TAG)

.PHONY: lint
lint: ## Run lint checks

.PHONY: lint-deps
lint-deps: ## Everything necessary to lint (useful to separate out in the logs)

GOLANGCI_LINT_FLAGS ?= $(if $(GITHUB_ACTION),--out-format=github-actions)
.PHONY: lint-golint
lint: lint-golint
lint-deps: $(tools/golangci-lint)
lint-golint: $(tools/golangci-lint)
	@echo Running Go linter ...
	$(tools/golangci-lint) run $(GOLANGCI_LINT_FLAGS) --build-tags=e2e --config=tools/golangci-lint/.golangci.yml

.PHONY: lint-yamllint
lint: lint-yamllint
lint-deps: $(tools/yamllint)
lint-yamllint: $(tools/yamllint)
	@echo Running YAML linter ...
	## TODO(lianghao208): add other directories later
	$(tools/yamllint) --config-file=tools/yamllint/.yamllint changelogs/

CODESPELL_FLAGS ?= $(if $(GITHUB_ACTION),--disable-colors)
.PHONY: lint-codespell
lint: lint-codespell
lint-deps: $(tools/codespell)
lint-codespell: CODESPELL_SKIP := $(shell cat tools/codespell/.codespell.skip | tr \\n ',')
lint-codespell: $(tools/codespell)
# This ::add-matcher/::remove-matcher business is based on
# https://github.com/codespell-project/actions-codespell/blob/2292753ad350451611cafcbabc3abe387491339a/entrypoint.sh
# We do this here instead of just using
# codespell-project/codespell-problem-matcher@v1 so that the matcher
# doesn't apply to the other linters that `make lint` also runs.
#
# This recipe is written a little awkwardly with everything running in
# one shell, this is because we want the ::remove-matcher lines to get
# printed whether or not it finds complaints.
	@PS4=; set -e; { \
	  if test -n "$$GITHUB_ACTION"; then \
	    printf '::add-matcher::$(CURDIR)/tools/codespell/matcher.json\n'; \
	    trap "printf '::remove-matcher owner=codespell-matcher-default::\n::remove-matcher owner=codespell-matcher-specified::\n'" EXIT; \
	  fi; \
	  (set -x; $(tools/codespell) $(CODESPELL_FLAGS) --skip $(CODESPELL_SKIP) --ignore-words tools/codespell/.codespell.ignorewords --check-filenames --check-hidden -q2); \
	}

##@ Development

.PHONY: manifests
manifests: $(tools/controller-gen) ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	$(tools/controller-gen) rbac:roleName=envoy-gateway-role crd webhook paths="./..." output:crd:artifacts:config=pkg/provider/kubernetes/config/crd/bases

.PHONY: generate
generate: $(tools/controller-gen) ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	$(tools/controller-gen) object paths="./..."

.PHONY: kube-test
kube-test: manifests generate lint $(tools/setup-envtest) ## Run Kubernetes provider tests.
	KUBEBUILDER_ASSETS="$(shell $(tools/setup-envtest) use $(ENVTEST_K8S_VERSION) -p path)" go test ./... -coverprofile cover.out

##@ Deployment

ifndef ignore-not-found
  ignore-not-found = false
endif

.PHONY: kube-install
kube-install: manifests $(tools/kustomize) ## Install CRDs into the Kubernetes cluster specified in ~/.kube/config.
	$(tools/kustomize) build pkg/provider/kubernetes/config/crd | kubectl apply -f -

.PHONY: kube-uninstall
kube-uninstall: manifests $(tools/kustomize) ## Uninstall CRDs from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	$(tools/kustomize) build pkg/provider/kubernetes/config/crd | kubectl delete --ignore-not-found=$(ignore-not-found) -f -

.PHONY: FORCE
