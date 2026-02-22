.PHONY: help cluster cluster-delete \
       configure setup-rpi \
       tilt-up tilt-down \
       status logs backup setup-backup-cron \
       tesla-token import-teslafi

NAMESPACE := teslamate
CLUSTER_NAME := teslamate
TESLA_AUTH_VERSION := v0.11.0
TESLA_AUTH_BIN := ./bin/tesla_auth

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } \
		/^[a-zA-Z_-]+:.*?## / { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo ""

##@ Getting Started

cluster: ## Create a local k3d cluster
	@if k3d cluster list 2>/dev/null | grep -q $(CLUSTER_NAME); then \
		echo "Cluster '$(CLUSTER_NAME)' already exists."; \
		echo "  To delete and recreate: make cluster-delete && make cluster"; \
	else \
		k3d cluster create $(CLUSTER_NAME); \
		echo "Cluster '$(CLUSTER_NAME)' created."; \
	fi
	@kubectl config use-context k3d-$(CLUSTER_NAME)
	@echo "kubectl context set to k3d-$(CLUSTER_NAME)"

configure: ## Configure environment (interactive: domain, tunnel, secrets)
	./scripts/configure.sh

tilt-up: check-config check-secrets ## Start Tilt (deploys full stack with live UI)
	tilt up

tesla-token: ## Generate Tesla API tokens (opens browser login)
	@if [ ! -f $(TESLA_AUTH_BIN) ]; then \
		mkdir -p bin; \
		ARCH=$$(uname -m); OS=$$(uname -s); \
		case "$$OS-$$ARCH" in \
			Darwin-arm64)  ASSET="tesla_auth-aarch64-apple-darwin" ;; \
			Darwin-x86_64) ASSET="tesla_auth-x86_64-apple-darwin" ;; \
			Linux-x86_64)  ASSET="tesla_auth-x86_64-unknown-linux-gnu" ;; \
			*) echo "Error: Unsupported platform $$OS-$$ARCH"; exit 1 ;; \
		esac; \
		echo "Downloading tesla_auth $(TESLA_AUTH_VERSION) ($$ASSET.tar.xz)..."; \
		curl -sL "https://github.com/adriankumpf/tesla_auth/releases/download/$(TESLA_AUTH_VERSION)/$$ASSET.tar.xz" \
			| tar -xJ -C bin/ --strip-components=1 "$$ASSET/tesla_auth"; \
		chmod +x $(TESLA_AUTH_BIN); \
		echo "Installed tesla_auth to $(TESLA_AUTH_BIN)"; \
	fi
	@echo "Opening Tesla login — sign in to generate your API tokens."
	@echo ""
	@$(TESLA_AUTH_BIN)

import-teslafi: ## Import TeslaFi CSV data (CSV_DIR=path, default ./import)
	./scripts/import-teslafi.sh $(CSV_DIR)

setup-rpi: ## Set up Raspberry Pi (run on RPi only)
	./scripts/setup-rpi.sh

##@ Operations

status: ## Show status of all pods
	@kubectl get pods -n $(NAMESPACE) -o wide

logs: ## Tail TeslaMate logs (use APP=grafana for other pods)
	kubectl logs -n $(NAMESPACE) -l app=$(or $(APP),teslamate) -f --tail=100

backup: ## Backup PostgreSQL (BACKUP_DIR=path, default /var/backups/teslamate)
	./scripts/backup-postgres.sh $(or $(BACKUP_DIR),/var/backups/teslamate)

setup-backup-cron: ## Install daily 3am backup cron job
	@SCRIPT_PATH="$$(cd "$$(dirname "$(MAKEFILE_LIST)")" && pwd)/scripts/backup-postgres.sh"; \
	BDIR="$(or $(BACKUP_DIR),/var/backups/teslamate)"; \
	CRON_ENTRY="0 3 * * * $$SCRIPT_PATH $$BDIR"; \
	if crontab -l 2>/dev/null | grep -qF "$$SCRIPT_PATH"; then \
		echo "Backup cron job already exists:"; \
		crontab -l | grep "$$SCRIPT_PATH"; \
	else \
		(crontab -l 2>/dev/null; echo "$$CRON_ENTRY") | crontab -; \
		echo "Installed daily backup cron job (3am):"; \
		echo "  $$CRON_ENTRY"; \
	fi

##@ Teardown

cluster-delete: ## Delete the local k3d cluster
	k3d cluster delete $(CLUSTER_NAME)

tilt-down: ## Stop Tilt and clean up
	tilt down

# --- Internal targets (not shown in help) ---

REQUIRED_SECRETS := teslamate-db-secret teslamate-secret oauth2-proxy-secret oauth2-proxy-emails cloudflared-secret

check-config:
	@if [ ! -f .env ]; then \
		echo "Error: .env not found. Run 'make configure' first."; \
		exit 1; \
	fi
	@if [ ! -d k8s/overlays/local ]; then \
		echo "Error: k8s/overlays/local/ not found. Run 'make configure' first."; \
		exit 1; \
	fi

check-secrets:
	@MISSING=""; \
	for secret in $(REQUIRED_SECRETS); do \
		if ! kubectl get secret $$secret -n $(NAMESPACE) &>/dev/null; then \
			MISSING="$$MISSING  - $$secret\n"; \
		fi; \
	done; \
	if [ -n "$$MISSING" ]; then \
		echo "Error: Required Kubernetes secrets are missing:"; \
		echo ""; \
		printf "$$MISSING"; \
		echo ""; \
		echo "Run 'make configure' first to create them."; \
		exit 1; \
	fi
