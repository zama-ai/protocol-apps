STATE_FILE := deployments/mainnet-fork/anvil-state.json
READ_CACHE := deployments/mainnet-fork/read-cache.json
MANIFEST := deployments/mainnet-fork/manifest.json
FOUNDRY_RPC_CACHE := $(HOME)/.foundry/cache/rpc
ANVIL_PORT := 8545
RPC := http://localhost:8545
ANVIL_PID := .anvil.pid
ANVIL_LOG := /tmp/foundry-tests-anvil.log
REGISTRY := eb5015ff021db115ace010f23f55c2591059bba0

.PHONY: bake fork-test fork-test-live regression anvil teardown-anvil build clean validate-state check-anvil-free wait-anvil

# Manual, network-bound step. Warms forge's fork read cache by running the suite against a
# live mainnet fork, commits that cache to deployments/mainnet-fork/read-cache.json, then
# converts it into the offline anvil-state.json fixture. Reads
# CONFIDENTIAL_WRAPPER_UPGRADE_TEST_RPC_URL from the environment or
# contracts/confidential-wrapper/.env (see .env.example). Optionally pin FORK_BLOCK. Commit
# read-cache.json, anvil-state.json, and manifest.json together. Never run in CI (see README).
bake:
	@FORK_URL="$$(./script/utils/resolve-fork-url.sh)" || exit 1; \
	BLOCK="$${FORK_BLOCK:-}"; \
	if [ -z "$$BLOCK" ]; then BLOCK="$$(cast block-number --rpc-url "$$FORK_URL")"; fi; \
	echo "Warming forge read cache against the live fork @ block $$BLOCK ..."; \
	forge test --fork-url "$$FORK_URL@$$BLOCK" -vvv || exit $$?; \
	CACHE="$$(find "$(FOUNDRY_RPC_CACHE)" -type f -path "*/$$BLOCK" 2>/dev/null | head -n1)"; \
	if [ -z "$$CACHE" ]; then \
		CACHE="$$(find "$(FOUNDRY_RPC_CACHE)" -type f -path "*/$$BLOCK/storage.json" 2>/dev/null | head -n1)"; \
	fi; \
	if [ -z "$$CACHE" ]; then \
		echo "Could not find forge read cache for block $$BLOCK under $(FOUNDRY_RPC_CACHE)."; \
		exit 1; \
	fi; \
	echo "Copying read cache $$CACHE -> $(READ_CACHE)"; \
	mkdir -p "$$(dirname "$(READ_CACHE)")"; \
	cp "$$CACHE" "$(READ_CACHE)"; \
	node script/convert-cache.js

build:
	forge build

validate-state:
	@test -s $(STATE_FILE) || (echo "Missing $(STATE_FILE). Run make bake first."; exit 1)
	@head -c 2 $(STATE_FILE) | grep -q '0x' || \
		(echo "$(STATE_FILE) must be a raw anvil_dumpState hex string."; exit 1)

check-anvil-free:
	@if command -v lsof >/dev/null 2>&1; then \
		listener="$$(lsof -tiTCP:$(ANVIL_PORT) -sTCP:LISTEN 2>/dev/null || true)"; \
		if [ -n "$$listener" ]; then \
			echo "TCP port $(ANVIL_PORT) is already in use by pid(s): $$listener"; \
			echo "Run 'make teardown-anvil' or stop the existing listener before make fork-test."; \
			exit 1; \
		fi; \
	elif curl -fsS -H 'content-type: application/json' \
		--data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
		$(RPC) > /dev/null 2>&1; then \
		echo "Ethereum RPC is already listening on $(RPC)."; \
		echo "Run 'make teardown-anvil' or stop the existing listener before make fork-test."; \
		exit 1; \
	fi

# Boots blank Anvil, loads the committed fixture through anvil_loadState, and serves it.
anvil: validate-state
	@rm -f $(ANVIL_PID) $(ANVIL_LOG)
	@anvil --chain-id 31337 --port $(ANVIL_PORT) > $(ANVIL_LOG) 2>&1 & echo $$! > $(ANVIL_PID)
	@$(MAKE) wait-anvil
	@./script/utils/load-state.sh $(RPC) $(STATE_FILE)
	@echo "Anvil ready on $(RPC). Press Ctrl-C to stop."
	@tail -f $(ANVIL_LOG); \
	status=$$?; \
	kill `cat $(ANVIL_PID)` 2>/dev/null || true; rm -f $(ANVIL_PID); \
	exit $$status

teardown-anvil:
	@./script/teardown-anvil.sh --port $(ANVIL_PORT)

# Network-bound test run against a live mainnet fork. Reads
# CONFIDENTIAL_WRAPPER_UPGRADE_TEST_RPC_URL from the environment (CI secret) or
# contracts/confidential-wrapper/.env (see .env.example). Optionally set FORK_BLOCK.
fork-test-live:
	@FORK_URL="$$(./script/utils/resolve-fork-url.sh)" || exit 1; \
	if [ -n "$${FORK_BLOCK:-}" ]; then FORK_URL="$${FORK_URL}@$${FORK_BLOCK}"; fi; \
	forge test --fork-url "$${FORK_URL}" -vvv

# Self-contained test run: start fixture-loaded Anvil in the background, wait
# for it to accept connections, run the suite against it, then tear it down.
fork-test: validate-state check-anvil-free
	@rm -f $(ANVIL_PID) $(ANVIL_LOG)
	@anvil --chain-id 31337 --port $(ANVIL_PORT) > $(ANVIL_LOG) 2>&1 & echo $$! > $(ANVIL_PID)
	@$(MAKE) wait-anvil
	@./script/utils/load-state.sh $(RPC) $(STATE_FILE)
	@node script/utils/list-wrappers.js $(RPC)
	@code="$$(cast code 0x$(REGISTRY) --rpc-url $(RPC))"; \
	if [ "$$code" = "0x" ]; then \
		echo "Loaded state has no registry code at 0x$(REGISTRY). Re-run make bake."; \
		kill `cat $(ANVIL_PID)` 2>/dev/null || true; rm -f $(ANVIL_PID); \
		exit 1; \
	fi
	@forge test --fork-url $(RPC) -vvv; \
	status=$$?; \
	kill `cat $(ANVIL_PID)` 2>/dev/null; rm -f $(ANVIL_PID); \
	exit $$status

# Regression: run the whole suite against the live fork (pinned to manifest.forkBlock) and
# against the committed offline fixture, then assert identical per-test results and that both
# passed. Proves the converted state reproduces live behavior with nothing silently skipped.
# Network-bound; reads the archive RPC like fork-test-live.
regression: validate-state check-anvil-free
	@FORK_URL="$$(./script/utils/resolve-fork-url.sh)" || exit 1; \
	BLOCK="$$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync("$(MANIFEST)")).forkBlock))')"; \
	LIVE="$${TMPDIR:-/tmp}/cwrapper-live-run.json"; \
	OFFLINE="$${TMPDIR:-/tmp}/cwrapper-offline-run.json"; \
	echo "Live run against fork @ block $$BLOCK ..."; \
	forge test --fork-url "$$FORK_URL@$$BLOCK" --json > "$$LIVE" || true; \
	rm -f $(ANVIL_PID) $(ANVIL_LOG); \
	anvil --chain-id 31337 --port $(ANVIL_PORT) > $(ANVIL_LOG) 2>&1 & echo $$! > $(ANVIL_PID); \
	$(MAKE) wait-anvil; \
	./script/utils/load-state.sh $(RPC) $(STATE_FILE); \
	echo "Offline run against the committed fixture ..."; \
	forge test --fork-url $(RPC) --json > "$$OFFLINE" || true; \
	kill `cat $(ANVIL_PID)` 2>/dev/null || true; rm -f $(ANVIL_PID); \
	node script/utils/assert-parity.js "$$LIVE" "$$OFFLINE"

wait-anvil:
	@echo "Waiting for Anvil..."
	@ready=0; \
	for i in $$(seq 1 30); do \
		if curl -fsS -H 'content-type: application/json' \
			--data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
			$(RPC) > /dev/null 2>&1; then ready=1; break; fi; \
		if ! kill -0 `cat $(ANVIL_PID)` 2>/dev/null; then break; fi; \
		sleep 0.5; \
	done; \
	if [ "$$ready" -ne 1 ]; then \
		echo "Anvil failed to start. Log:"; \
		cat $(ANVIL_LOG); \
		kill `cat $(ANVIL_PID)` 2>/dev/null || true; rm -f $(ANVIL_PID); \
		exit 1; \
	fi

clean:
	forge clean
	rm -f $(ANVIL_PID)
