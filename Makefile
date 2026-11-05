# Local RMF Automation — lifecycle wrapper around ./scripts.
#
# Every target shells out to the script that already does the work, because the
# ordering between them is load-bearing (see `make up` and the README). Nothing
# here reimplements a step.
#
#   make help      list targets
#   make up        bring the whole lab up, from nothing or after a reboot
#   make verify    13-step end-to-end check
#
# All targets source env.sh themselves, so no `source` is needed first. env.sh
# redirects AWS_CONFIG_FILE / AWS_SHARED_CREDENTIALS_FILE / KUBECONFIG at
# repo-local files, so your real ~/.aws and ~/.kube are never read or written.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

REPO_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
S        := $(REPO_DIR)/scripts
KC       := kubectl --context
# Passed through to terraform: `make infra AUTO=1` skips the approval prompt.
APPROVE  := $(if $(AUTO),-auto-approve,)

.PHONY: help up down destroy purge verify preflight infra workloads kubeconfig \
        hosts unhosts iam eviction keycloak-client db-shell db keycloak-shell \
        keycloak-config pods logs floci-logs urls token tfsec fmt validate \
        stig-library stigs clean-scratch

## ----------------------------------------------------------------- lifecycle

help: ## List available targets
	@echo "Local RMF Automation"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  Add AUTO=1 to infra/workloads/up to skip terraform approval prompts."

up: ## Bring the whole lab up (idempotent; safe after a reboot)
	@$(S)/00-up.sh

down: ## Stop the containers, keep all state
	@$(S)/99-down.sh

destroy: ## terraform destroy, then stop (k8s objects and MySQL data are lost)
	@$(S)/99-down.sh --destroy

purge: ## destroy + delete Floci state, k3s volumes, certs and kubeconfig
	@$(S)/99-down.sh --purge

verify: ## End-to-end check, 13 steps; non-zero exit if anything failed
	@$(S)/08-verify.sh

preflight: ## Check that the required tools are installed
	@missing=0; \
	for t in docker terraform kubectl jq curl python3; do \
	  if command -v $$t >/dev/null 2>&1; then \
	    printf '  \033[32mok\033[0m    %-10s %s\n' "$$t" "$$(command -v $$t)"; \
	  else \
	    printf '  \033[31mMISSING\033[0m %-10s\n' "$$t"; missing=1; \
	  fi; \
	done; \
	for t in k9s tfsec; do \
	  command -v $$t >/dev/null 2>&1 \
	    && printf '  \033[32mok\033[0m    %-10s %s (optional)\n' "$$t" "$$(command -v $$t)" \
	    || printf '  \033[33m-\033[0m     %-10s not installed (optional)\n' "$$t"; \
	done; \
	docker info >/dev/null 2>&1 \
	  && printf '  \033[32mok\033[0m    %-10s daemon reachable\n' "docker ps" \
	  || { printf '  \033[31mMISSING\033[0m %-10s daemon not reachable\n' "docker ps"; missing=1; }; \
	exit $$missing

## ------------------------------------------------------------ built in steps

iam: ## Mint the emulated IAM user whose key signs EKS auth tokens
	@$(S)/01-bootstrap-iam.sh

infra: ## Stage 1 — VPC, IAM, EKS, ACM, ALBs, Route53
	@$(S)/02-apply-infra.sh $(APPROVE)

kubeconfig: ## Rewrite ./kubeconfig for both clusters
	@$(S)/03-kubeconfig.sh

workloads: ## Stage 2 — Keycloak, MySQL, STIG Manager API, CoreDNS overrides
	@$(S)/04-apply-workloads.sh $(APPROVE)

hosts: ## Add stigman.mil / keycloak.mil to /etc/hosts (needs sudo)
	@$(S)/05-hosts.sh

unhosts: ## Remove this lab's /etc/hosts entries
	@$(S)/05-hosts.sh --remove

eviction: ## Relax kubelet's disk-eviction threshold (recreates the k3s containers)
	@$(S)/06-patch-eviction.sh

keycloak-client: ## Narrow the Keycloak client's redirect URIs to the lab hostname
	@$(S)/07-keycloak-client.sh

## -------------------------------------------------------------------- poking

urls: ## Print the lab URLs and credentials
	@source $(REPO_DIR)/env.sh >/dev/null; \
	cd $(REPO_DIR)/terraform/01-infra && terraform output urls 2>/dev/null || true; \
	echo "  STIG Manager  admin / password"; \
	echo "  Keycloak      admin / Pa55w0rd"

pods: ## Show pods in both clusters
	@source $(REPO_DIR)/env.sh >/dev/null; \
	for c in keycloak stigman; do echo "--- $$c ---"; $(KC) $$c get pods -A -o wide; done

logs: ## Tail the STIG Manager API log (JSON, piped through jq)
	@source $(REPO_DIR)/env.sh >/dev/null; \
	$(KC) stigman logs -f -n stigman -l app=stigman-api --tail=50 \
	  | (command -v jq >/dev/null && jq -R 'fromjson? // .' || cat)

floci-logs: ## Tail the emulator's own log
	@docker logs -f floci

token: ## Mint an OIDC access token for the API (prints the token)
	@source $(REPO_DIR)/env.sh >/dev/null; \
	scopes="openid stig-manager:stig stig-manager:stig:read stig-manager:collection"; \
	scopes="$$scopes stig-manager:user stig-manager:user:read stig-manager:op stig-manager:op:read"; \
	curl -s --cacert $(REPO_DIR)/certs/lab-ca.crt \
	  -d client_id=stig-manager -d username=admin -d password=password \
	  -d grant_type=password --data-urlencode "scope=$$scopes" \
	  https://keycloak.mil/realms/stigman/protocol/openid-connect/token \
	  | jq -r '.access_token'

db-shell: ## Interactive MySQL shell in the stigman cluster
	@source $(REPO_DIR)/env.sh >/dev/null; \
	pod=$$($(KC) stigman get pod -n stigman -l app=mysql -o jsonpath='{.items[0].metadata.name}'); \
	$(KC) stigman exec -it -n stigman "$$pod" -- mysql -h127.0.0.1 -ustigman -pstigman stigman

db: ## Run one SQL statement: make db Q="SELECT name FROM collection;"
	@test -n "$(Q)" || { echo 'usage: make db Q="SELECT name FROM collection;"' >&2; exit 2; }
	@source $(REPO_DIR)/env.sh >/dev/null; \
	pod=$$($(KC) stigman get pod -n stigman -l app=mysql -o jsonpath='{.items[0].metadata.name}'); \
	$(KC) stigman exec -n stigman "$$pod" -- \
	  mysql -h127.0.0.1 -ustigman -pstigman stigman -e "$(Q)"

keycloak-shell: ## Interactive shell in the Keycloak pod (kcadm.sh lives in /opt/keycloak/bin)
	@source $(REPO_DIR)/env.sh >/dev/null; \
	pod=$$($(KC) keycloak get pod -n keycloak -l app=keycloak -o jsonpath='{.items[0].metadata.name}'); \
	$(KC) keycloak exec -it -n keycloak "$$pod" -- bash

keycloak-config: ## Dump the stigman realm's clients, users and scopes
	@source $(REPO_DIR)/env.sh >/dev/null; \
	pod=$$($(KC) keycloak get pod -n keycloak -l app=keycloak -o jsonpath='{.items[0].metadata.name}'); \
	$(KC) keycloak exec -n keycloak "$$pod" -- sh -c '\
	  K=/opt/keycloak/bin/kcadm.sh; \
	  $$K config credentials --server http://localhost:8080 --realm master \
	    --user "$${KEYCLOAK_ADMIN:-admin}" --password "$${KEYCLOAK_ADMIN_PASSWORD:-Pa55w0rd}" >/dev/null; \
	  echo "=== clients ==="; \
	  $$K get clients -r stigman --fields clientId,enabled,publicClient,standardFlowEnabled; \
	  echo "=== users ==="; $$K get users -r stigman --fields username,enabled,email; \
	  echo "=== client scopes ==="; $$K get client-scopes -r stigman --fields name'

## -------------------------------------------------------------------- quality

fmt: ## terraform fmt, both stages
	@terraform -chdir=$(REPO_DIR)/terraform/01-infra fmt -recursive
	@terraform -chdir=$(REPO_DIR)/terraform/02-workloads fmt -recursive

validate: ## terraform validate + bash -n on every script
	@terraform -chdir=$(REPO_DIR)/terraform/01-infra init -backend=false -input=false >/dev/null
	@terraform -chdir=$(REPO_DIR)/terraform/01-infra validate
	@for f in $(S)/*.sh $(REPO_DIR)/env.sh; do bash -n "$$f" && echo "  ok $$(basename $$f)"; done

tfsec: ## Static analysis of the Terraform (findings are expected; this is a lab)
	@command -v tfsec >/dev/null || { echo "tfsec not installed — see the README" >&2; exit 1; }
	@tfsec $(REPO_DIR)/terraform/01-infra --no-colour || true
	@tfsec $(REPO_DIR)/terraform/02-workloads --no-colour || true

## ----------------------------------------------------------------- stig content

stig-library: ## Download the current DISA STIG compilation (~375 MB) into stigs/library
	@$(S)/10-fetch-stigs.sh

stigs: ## List the STIG content present locally
	@find $(REPO_DIR)/stigs -type f ! -name .gitkeep -printf '%10s  %p\n' | sort -k2 || true

clean-scratch: ## Remove downloaded STIG content (keeps the directories)
	@find $(REPO_DIR)/stigs -type f ! -name .gitkeep -delete
	@echo "stigs/ emptied"
