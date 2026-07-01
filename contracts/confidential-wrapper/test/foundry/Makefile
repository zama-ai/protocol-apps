STATE_FILE := deployments/mainnet-fork/anvil-state.json
RPC := http://localhost:8545
ANVIL_PID := .anvil.pid
ANVIL_LOG := /tmp/foundry-tests-anvil.log
REGISTRY := eb5015ff021db115ace010f23f55c2591059bba0

.PHONY: bake bake-blacklists test test-live anvil teardown-anvil build clean validate-state wait-anvil

# Manual, network-bound step. Reads CONFIDENTIAL_WRAPPER_UPGRADE_TEST_RPC_URL
# from contracts/confidential-wrapper/.env (see .env.example). Commits the fixture.
# Never run in CI (see ADR-010 / README).
bake:
	node script/bake.mjs

# Network-bound incremental blacklist-only refresh over the committed fixture.
bake-blacklists:
	node script/bake-blacklist.mjs

build:
	forge build

validate-state:
	@test -s $(STATE_FILE) || (echo "Missing $(STATE_FILE). Run make bake first."; exit 1)
	@head -c 2 $(STATE_FILE) | grep -q '0x' || \
		(echo "$(STATE_FILE) must be a raw anvil_dumpState hex string."; exit 1)

# Boots blank Anvil, loads the committed fixture through anvil_loadState, and serves it.
anvil: validate-state
	@rm -f $(ANVIL_PID) $(ANVIL_LOG)
	@anvil --chain-id 31337 --port 8545 > $(ANVIL_LOG) 2>&1 & echo $$! > $(ANVIL_PID)
	@$(MAKE) wait-anvil
	@./script/utils/load-state.sh $(RPC) $(STATE_FILE)
	@echo "Anvil ready on $(RPC). Press Ctrl-C to stop."
	@tail -f $(ANVIL_LOG); \
	status=$$?; \
	kill `cat $(ANVIL_PID)` 2>/dev/null || true; rm -f $(ANVIL_PID); \
	exit $$status

teardown-anvil:
	@./script/teardown-anvil.sh --port 8545

# Network-bound test run against a live mainnet fork. Reads
# CONFIDENTIAL_WRAPPER_UPGRADE_TEST_RPC_URL from contracts/confidential-wrapper/.env
# (see .env.example). Optionally set FORK_BLOCK.
test-live:
	@ENV_FILE=../../.env; \
	if [ -f "$$ENV_FILE" ]; then \
		FORK_URL="$$(. "$$ENV_FILE" && printf '%s' "$${CONFIDENTIAL_WRAPPER_UPGRADE_TEST_RPC_URL:-}")"; \
	else \
		FORK_URL=""; \
	fi; \
	if [ -z "$${FORK_URL}" ]; then \
		echo "CONFIDENTIAL_WRAPPER_UPGRADE_TEST_RPC_URL is not set."; \
		echo "Add it to contracts/confidential-wrapper/.env (see .env.example)."; \
		exit 1; \
	fi; \
	if [ -n "$${FORK_BLOCK:-}" ]; then FORK_URL="$${FORK_URL}@$${FORK_BLOCK}"; fi; \
	forge test --fork-url "$${FORK_URL}" -vvv

# Self-contained test run: start fixture-loaded Anvil in the background, wait
# for it to accept connections, run the suite against it, then tear it down.
test: validate-state
	@rm -f $(ANVIL_PID) $(ANVIL_LOG)
	@anvil --chain-id 31337 --port 8545 > $(ANVIL_LOG) 2>&1 & echo $$! > $(ANVIL_PID)
	@$(MAKE) wait-anvil
	@./script/utils/load-state.sh $(RPC) $(STATE_FILE)
	@node script/utils/list-wrappers.mjs $(RPC)
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
