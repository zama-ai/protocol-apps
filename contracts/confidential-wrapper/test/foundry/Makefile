.PHONY: fork-test build clean

build:
	forge build

# Network-bound test run against a live mainnet fork. Reads
# CONFIDENTIAL_WRAPPER_UPGRADE_TEST_RPC_URL from the environment (CI secret) or
# contracts/confidential-wrapper/.env (see .env.example). Optionally set FORK_BLOCK.
fork-test:
	@FORK_URL="$$(./script/utils/resolve-fork-url.sh)" || exit 1; \
	if [ -n "$${FORK_BLOCK:-}" ]; then FORK_URL="$${FORK_URL}@$${FORK_BLOCK}"; fi; \
	forge test --fork-url "$${FORK_URL}" -vvv

clean:
	forge clean
