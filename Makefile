# MCP Servers — Local Sandboxed Management
# Usage:
#   make add url=https://github.com/user/repo
#   make build server=repo
#   make build-all
#   make data server=repo
#   make run server=repo [network=none|bridge|proxy]
#   make list
#   make config server=repo [network=none]
#   make update server=repo
#   make remove server=repo
#   make proxy-build
#   make proxy-start
#   make proxy-stop

-include .env

SERVERS_DIR := servers
DATA_DIR := $(CURDIR)/data
ENV_DIR := $(CURDIR)/.server-config
SERVER ?= $(server)
URL ?= $(url)
NETWORK ?= $(or $(network),none)
IMAGE_PREFIX ?= $(or $(image_prefix),mcp-)
MCP_NAME_PREFIX ?= $(mcp_name_prefix)
PROXY_IMAGE := mcp-squid-proxy
PROXY_NET := mcp-proxy-net
PROXY_CONTAINER := mcp-squid-proxy
PROXY_BASE_PORT := 3128

# Extract repo name from URL (last path segment, minus .git)
repo_name = $(basename $(notdir $(URL)))

# ──────────────────────────────────────────────
# add: Add a new MCP server as a git submodule
# ──────────────────────────────────────────────
.PHONY: add
add:
ifndef URL
	$(error URL/url is required. Usage: make add url=https://github.com/user/repo)
endif
	@if [ -d "$(SERVERS_DIR)/$(repo_name)" ]; then \
		echo "Error: $(SERVERS_DIR)/$(repo_name) already exists"; \
		exit 1; \
	fi
	@if [ ! -f ".gitmodules" ] && git ls-files --error-unmatch .gitmodules >/dev/null 2>&1; then \
		echo "Fixing stale .gitmodules index entry..."; \
		git rm --cached -f .gitmodules >/dev/null 2>&1 || true; \
	fi
	@if [ ! -e "$(SERVERS_DIR)/$(repo_name)" ] && git ls-files --error-unmatch "$(SERVERS_DIR)/$(repo_name)" >/dev/null 2>&1; then \
		echo "Fixing stale submodule index entry for $(repo_name)..."; \
		git rm --cached -f "$(SERVERS_DIR)/$(repo_name)" >/dev/null 2>&1 || true; \
	fi
	@if [ ! -e "$(SERVERS_DIR)/$(repo_name)" ] && [ -d ".git/modules/$(SERVERS_DIR)/$(repo_name)" ]; then \
		echo "Fixing stale local git dir for $(repo_name)..."; \
		rm -rf ".git/modules/$(SERVERS_DIR)/$(repo_name)"; \
	fi
	@mkdir -p $(SERVERS_DIR)
	git submodule add $(URL) $(SERVERS_DIR)/$(repo_name)
	@HASH=$$(git -C $(SERVERS_DIR)/$(repo_name) rev-parse HEAD); \
		echo "Added submodule $(repo_name) at $$HASH"; \
		echo "Running build + config for $(repo_name)..."; \
		$(MAKE) --no-print-directory build server=$(repo_name); \
		$(MAKE) --no-print-directory config server=$(repo_name)
ifeq ($(NETWORK),proxy)
	@mkdir -p "$(ENV_DIR)/$(repo_name)"
	@ALLOWLIST="$(ENV_DIR)/$(repo_name)/.allowlist"; \
	if [ ! -f "$$ALLOWLIST" ]; then \
		printf '# Domain allowlist for $(repo_name)\n# One domain per line. Lines starting with # are ignored.\n# Use .example.com to match example.com and all subdomains.\n' > "$$ALLOWLIST"; \
		echo "Created $$ALLOWLIST — add domains to allow network access."; \
	fi
	@PORT_FILE="$(ENV_DIR)/$(repo_name)/.proxy-port"; \
	if [ ! -f "$$PORT_FILE" ]; then \
		NEXT_PORT=$(PROXY_BASE_PORT); \
		for f in $(ENV_DIR)/*/.proxy-port; do \
			[ -f "$$f" ] || continue; \
			EXISTING=$$(cat "$$f"); \
			if [ "$$EXISTING" -ge "$$NEXT_PORT" ]; then \
				NEXT_PORT=$$((EXISTING + 1)); \
			fi; \
		done; \
		echo "$$NEXT_PORT" > "$$PORT_FILE"; \
		echo "Assigned proxy port $$NEXT_PORT to $(repo_name)"; \
	fi
	@ENV_FILE="$(ENV_DIR)/$(repo_name)/.env"; \
	PORT=$$(cat "$(ENV_DIR)/$(repo_name)/.proxy-port"); \
	if ! grep -q 'HTTP_PROXY' "$$ENV_FILE" 2>/dev/null; then \
		printf "\n# Proxy settings (network=proxy)\nHTTP_PROXY=http://$(PROXY_CONTAINER):$$PORT\nHTTPS_PROXY=http://$(PROXY_CONTAINER):$$PORT\nhttp_proxy=http://$(PROXY_CONTAINER):$$PORT\nhttps_proxy=http://$(PROXY_CONTAINER):$$PORT\n" >> "$$ENV_FILE"; \
		echo "Added proxy env vars (port $$PORT) to $$ENV_FILE"; \
	fi
endif

# ──────────────────────────────────────────────
# build: Build Docker image for a server
# ──────────────────────────────────────────────
.PHONY: build
build:
ifndef SERVER
	$(error SERVER/server is required. Usage: make build server=<repo>)
endif
	@if [ ! -d "$(SERVERS_DIR)/$(SERVER)" ]; then \
		echo "Error: $(SERVERS_DIR)/$(SERVER) does not exist. Run make add first."; \
		exit 1; \
	fi
	@# Detect Dockerfile: own Dockerfile > Python indicators > Node indicators > error
	@if [ -f "$(SERVERS_DIR)/$(SERVER)/Dockerfile" ]; then \
		echo "Building $(SERVER) with its own Dockerfile..."; \
		docker build -t $(IMAGE_PREFIX)$(SERVER) $(SERVERS_DIR)/$(SERVER); \
	elif [ -f "$(SERVERS_DIR)/$(SERVER)/pyproject.toml" ] || \
	     [ -f "$(SERVERS_DIR)/$(SERVER)/requirements.txt" ] || \
	     [ -f "$(SERVERS_DIR)/$(SERVER)/setup.py" ]; then \
		echo "Building $(SERVER) with shared Dockerfile.python..."; \
		docker build -t $(IMAGE_PREFIX)$(SERVER) -f dockerfiles/Dockerfile.python $(SERVERS_DIR)/$(SERVER); \
	elif [ -f "$(SERVERS_DIR)/$(SERVER)/package.json" ]; then \
		echo "Building $(SERVER) with shared Dockerfile.node..."; \
		docker build -t $(IMAGE_PREFIX)$(SERVER) -f dockerfiles/Dockerfile.node $(SERVERS_DIR)/$(SERVER); \
	else \
		echo "Error: cannot detect server type for $(SERVER)."; \
		echo "Expected one of: Dockerfile, pyproject.toml, requirements.txt, setup.py, package.json"; \
		echo "Add a Dockerfile to the server repo or use a supported project type."; \
		exit 1; \
	fi
	@echo "Built image: $(IMAGE_PREFIX)$(SERVER)"

# ──────────────────────────────────────────────
# build-all: Build all servers
# ──────────────────────────────────────────────
.PHONY: build-all
build-all:
	@for dir in $(SERVERS_DIR)/*/; do \
		server=$$(basename "$$dir"); \
		echo "=== Building $$server ==="; \
		$(MAKE) build SERVER=$$server; \
	done

# ──────────────────────────────────────────────
# run: Run a server in Docker (interactive, for testing)
# ──────────────────────────────────────────────
.PHONY: run
run:
ifndef SERVER
	$(error SERVER/server is required. Usage: make run server=<repo>)
endif
	@$(MAKE) --no-print-directory data SERVER=$(SERVER) >/dev/null
ifeq ($(NETWORK),proxy)
	@$(MAKE) --no-print-directory proxy-start
endif
	@echo "Running $(SERVER) with network=$(NETWORK)..."
	@ENV_FILE="$(ENV_DIR)/$(SERVER)/.env"; \
	ENV_ARGS=""; \
	if [ -f "$$ENV_FILE" ]; then \
		ENV_ARGS="--env-file $$ENV_FILE"; \
		echo "Loading env overrides from $$ENV_FILE"; \
	fi; \
	NETWORK_ARGS="--network $(NETWORK)"; \
	if [ "$(NETWORK)" = "proxy" ]; then \
		NETWORK_ARGS="--network $(PROXY_NET)"; \
	fi; \
	echo "Mounting $(DATA_DIR)/$(SERVER) -> /data"; \
	docker run -i --rm $$NETWORK_ARGS \
		-v $(DATA_DIR)/$(SERVER):/data \
		-e DATA_DIR=/data \
		$$ENV_ARGS \
		$(IMAGE_PREFIX)$(SERVER)

# ──────────────────────────────────────────────
# data: Create persistent storage for a server
# ──────────────────────────────────────────────
.PHONY: data
data:
ifndef SERVER
	$(error SERVER/server is required. Usage: make data server=<repo>)
endif
	@if [ ! -d "$(SERVERS_DIR)/$(SERVER)" ]; then \
		echo "Error: $(SERVERS_DIR)/$(SERVER) does not exist. Run make add first."; \
		exit 1; \
	fi
	@mkdir -p $(DATA_DIR)/$(SERVER) "$(ENV_DIR)/$(SERVER)"
	@echo "Created $(DATA_DIR)/$(SERVER)"
	@ENV_FILE="$(ENV_DIR)/$(SERVER)/.env"; \
	if [ ! -f "$$ENV_FILE" ]; then \
		printf '# Per-server environment overrides for $(SERVER)\n# DATA_DIR is already set to /data by Makefile.\n# Add server-specific persistence variables below.\n# Example for todo-list-mcp:\n# TODO_DB_FOLDER=/data\n' > "$$ENV_FILE"; \
		echo "Created $$ENV_FILE"; \
	else \
		echo "Using existing $$ENV_FILE"; \
	fi
	@echo "Data will be mounted at /data inside the container."
	@echo "Use $(ENV_DIR)/$(SERVER)/.env for server-specific path variables."

# ──────────────────────────────────────────────
# list: Show all submodules and pinned commits
# ──────────────────────────────────────────────
.PHONY: list
list:
	@if [ ! -f ".gitmodules" ]; then \
		echo "No submodules added yet. Run: make add URL=..."; \
		exit 0; \
	fi
	@printf "%-30s %-42s %s\n" "SERVER" "COMMIT" "URL"
	@printf "%-30s %-42s %s\n" "------" "------" "---"
	@git config -f .gitmodules --get-regexp '^submodule\..*\.path$$' | while read -r key path; do \
		name=$$(basename "$$path"); \
		url=$$(git config -f .gitmodules --get "$${key%.path}.url"); \
		hash=$$(git -C "$$path" rev-parse HEAD 2>/dev/null || echo "N/A"); \
		printf "%-30s %-42s %s\n" "$$name" "$$hash" "$$url"; \
	done

# ──────────────────────────────────────────────
# config: Print VS Code MCP config JSON for a server
# ──────────────────────────────────────────────
.PHONY: config
config:
ifndef SERVER
	$(error SERVER/server is required. Usage: make config server=<repo>)
endif
	@$(MAKE) --no-print-directory data SERVER=$(SERVER) >/dev/null
	@ACTUAL_NET="$(NETWORK)"; \
	if [ "$(NETWORK)" = "proxy" ]; then \
		ACTUAL_NET="$(PROXY_NET)"; \
		echo ''; \
		echo 'NOTE: Proxy mode requires the proxy to be running before the server starts.'; \
		echo 'Run: make proxy-build && make proxy-start'; \
	fi; \
	echo ''; \
	echo 'Add this to .vscode/mcp.json under "servers":'; \
	echo ''; \
	echo '  "$(MCP_NAME_PREFIX)$(SERVER)": {'; \
	echo '    "command": "docker",'; \
	echo '    "args": ['; \
	echo '      "run", "-i", "--rm",'; \
	echo "      \"--network\", \"$$ACTUAL_NET\","; \
	echo '      "-v", "$(DATA_DIR)/$(SERVER):/data",'; \
	echo '      "-e", "DATA_DIR=/data",'; \
	echo '      "--env-file", "$(ENV_DIR)/$(SERVER)/.env",'; \
	echo '      "$(IMAGE_PREFIX)$(SERVER)"'; \
	echo '    ]'; \
	echo '  }'
	@echo ''

# ──────────────────────────────────────────────
# update: Pull latest for a submodule and show diff
# ──────────────────────────────────────────────
.PHONY: update
update:
ifndef SERVER
	$(error SERVER/server is required. Usage: make update server=<repo>)
endif
	@SUB_PATH="$(SERVERS_DIR)/$(SERVER)"; \
	if [ ! -d "$$SUB_PATH" ]; then \
		echo "Error: $$SUB_PATH does not exist. Run make add first."; \
		exit 1; \
	fi; \
	OLD_HASH=$$(git -C "$$SUB_PATH" rev-parse HEAD); \
	URL=$$(git config -f .gitmodules --get "submodule.$$SUB_PATH.url"); \
	if [ -z "$$URL" ]; then \
		echo "Error: $$SUB_PATH is not configured as a submodule."; \
		exit 1; \
	fi; \
	echo "Current pin: $$OLD_HASH"; \
	echo "Fetching latest from $$URL..."; \
	git -C "$$SUB_PATH" fetch --quiet origin; \
	DEFAULT_BRANCH=$$(git -C "$$SUB_PATH" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||'); \
	if [ -z "$$DEFAULT_BRANCH" ]; then \
		DEFAULT_BRANCH=$$(git -C "$$SUB_PATH" remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p'); \
	fi; \
	if [ -z "$$DEFAULT_BRANCH" ]; then \
		echo "Error: cannot detect default branch for $$SUB_PATH. Try: git -C $$SUB_PATH remote set-head origin --auto"; \
		exit 1; \
	fi; \
	NEW_HASH=$$(git -C "$$SUB_PATH" rev-parse "origin/$$DEFAULT_BRANCH"); \
	if [ "$$OLD_HASH" = "$$NEW_HASH" ]; then \
		echo "Already up to date."; \
		exit 0; \
	fi; \
	echo "New commit: $$NEW_HASH"; \
	echo ""; \
	echo "=== Changes since $$OLD_HASH ==="; \
	git -C "$$SUB_PATH" log --oneline "$$OLD_HASH..$$NEW_HASH" || true; \
	echo ""; \
	printf "Update $(SERVER) to $$NEW_HASH? [y/N] "; \
	read confirm; \
	if [ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ]; then \
		git -C "$$SUB_PATH" checkout "$$NEW_HASH"; \
		echo "Updated $(SERVER) to $$NEW_HASH. Run: make build server=$(SERVER)"; \
	else \
		echo "Aborted."; \
	fi

# ──────────────────────────────────────────────
# proxy-build: Build the Squid proxy image
# ──────────────────────────────────────────────
.PHONY: proxy-build
proxy-build:
	@echo "Building Squid proxy image..."
	docker build -t $(PROXY_IMAGE) -f dockerfiles/Dockerfile.squid dockerfiles
	@echo "Built image: $(PROXY_IMAGE)"

# ──────────────────────────────────────────────
# proxy-start: Start the shared proxy with per-port allowlists
# ──────────────────────────────────────────────
.PHONY: proxy-start
proxy-start:
	@# Generate squid.conf from all registered .proxy-port + .allowlist pairs
	@CONF="$(ENV_DIR)/squid.generated.conf"; \
	VOLUME_ARGS=""; \
	FOUND=0; \
	printf '# Auto-generated Squid config — do not edit\n' > "$$CONF"; \
	printf 'acl SSL_ports port 443\n' >> "$$CONF"; \
	printf 'acl Safe_ports port 80\n' >> "$$CONF"; \
	printf 'acl Safe_ports port 443\n' >> "$$CONF"; \
	printf 'http_access deny !Safe_ports\n' >> "$$CONF"; \
	printf 'http_access deny CONNECT !SSL_ports\n\n' >> "$$CONF"; \
	for portfile in $(ENV_DIR)/*/.proxy-port; do \
		[ -f "$$portfile" ] || continue; \
		SNAME=$$(basename "$$(dirname "$$portfile")"); \
		PORT=$$(cat "$$portfile"); \
		ALLOWFILE="$(ENV_DIR)/$$SNAME/.allowlist"; \
		if [ ! -f "$$ALLOWFILE" ]; then \
			echo "Warning: $$ALLOWFILE not found, skipping $$SNAME"; \
			continue; \
		fi; \
		FOUND=1; \
		printf '# --- %s (port %s) ---\n' "$$SNAME" "$$PORT" >> "$$CONF"; \
		printf 'http_port %s\n' "$$PORT" >> "$$CONF"; \
		printf 'acl port_%s localport %s\n' "$$SNAME" "$$PORT" >> "$$CONF"; \
		printf 'acl allow_%s dstdomain "/etc/squid/allowlist_%s.txt"\n' "$$SNAME" "$$SNAME" >> "$$CONF"; \
		printf 'http_access allow port_%s allow_%s\n\n' "$$SNAME" "$$SNAME" >> "$$CONF"; \
		VOLUME_ARGS="$$VOLUME_ARGS -v $$ALLOWFILE:/etc/squid/allowlist_$$SNAME.txt:ro"; \
	done; \
	printf 'http_access deny all\n\n' >> "$$CONF"; \
	printf 'pid_filename /tmp/squid.pid\n' >> "$$CONF"; \
	printf '# Logging\naccess_log stdio:/dev/stdout\ncache_log stdio:/dev/stderr\ncache deny all\n' >> "$$CONF"; \
	if [ "$$FOUND" = "0" ]; then \
			echo "Error: no .proxy-port files found in $(ENV_DIR)/*/.proxy-port. Add a server with network=proxy first."; \
		rm -f "$$CONF"; \
		exit 1; \
	fi; \
	docker network inspect $(PROXY_NET) >/dev/null 2>&1 || \
		(echo "Creating network $(PROXY_NET)..." && docker network create $(PROXY_NET)); \
	if docker ps -q -f name=$(PROXY_CONTAINER) | grep -q .; then \
		echo "Restarting proxy with updated config..."; \
		docker stop $(PROXY_CONTAINER) >/dev/null; \
	fi; \
	echo "Starting Squid proxy..."; \
	eval docker run -d --rm --name $(PROXY_CONTAINER) \
		--network $(PROXY_NET) \
		-v "$$CONF:/etc/squid/squid.conf:ro" \
		$$VOLUME_ARGS \
		$(PROXY_IMAGE) >/dev/null; \
	echo "Proxy running on network $(PROXY_NET)"

# ──────────────────────────────────────────────
# proxy-stop: Stop the shared proxy and remove its network
# ──────────────────────────────────────────────
.PHONY: proxy-stop
proxy-stop:
	@if docker ps -q -f name=$(PROXY_CONTAINER) | grep -q .; then \
		echo "Stopping proxy..."; \
		docker stop $(PROXY_CONTAINER) >/dev/null; \
	else \
		echo "Proxy is not running."; \
	fi
	@docker network rm $(PROXY_NET) 2>/dev/null && echo "Removed network $(PROXY_NET)" || true
	@rm -f $(ENV_DIR)/squid.generated.conf

# ──────────────────────────────────────────────
# clean: Remove a server
# ──────────────────────────────────────────────
.PHONY: clean remove
clean: remove

remove:
ifndef SERVER
	$(error SERVER/server is required. Usage: make remove server=<repo>)
endif
	@echo "Removing server $(SERVER)..."
	@if [ -f .gitmodules ] && git config -f .gitmodules --get "submodule.$(SERVERS_DIR)/$(SERVER).path" >/dev/null 2>&1; then \
		git submodule deinit -f -- $(SERVERS_DIR)/$(SERVER) 2>/dev/null || true; \
		git rm -f $(SERVERS_DIR)/$(SERVER) 2>/dev/null || rm -rf $(SERVERS_DIR)/$(SERVER); \
	else \
		rm -rf $(SERVERS_DIR)/$(SERVER); \
	fi
	@rm -rf .git/modules/$(SERVERS_DIR)/$(SERVER)
	@if [ -f .gitmodules ] && [ ! -s .gitmodules ]; then rm -f .gitmodules; fi
	@if [ ! -e "$(SERVERS_DIR)/$(SERVER)" ] && git ls-files --error-unmatch "$(SERVERS_DIR)/$(SERVER)" >/dev/null 2>&1; then \
		git rm --cached -f "$(SERVERS_DIR)/$(SERVER)" >/dev/null 2>&1 || true; \
	fi
	@if [ ! -f ".gitmodules" ] && git ls-files --error-unmatch .gitmodules >/dev/null 2>&1; then \
		git rm --cached -f .gitmodules >/dev/null 2>&1 || true; \
	fi
	@rm -rf "$(ENV_DIR)/$(SERVER)"
	@rm -rf $(DATA_DIR)/$(SERVER)
	@docker rmi $(IMAGE_PREFIX)$(SERVER) 2>/dev/null || true
	@echo "Removed $(SERVER) and cleaned submodule/env/data/docker artifacts"
