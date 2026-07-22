.PHONY: setup fork-test build clean

# Installs the soldeer dependencies pinned in soldeer.toml (incl. forge-fhevm).
setup:
	forge soldeer install --config-location soldeer

build:
	forge build

# Network-bound test run against a live mainnet fork. Reads
# ETHEREUM_MAINNET_FORK_RPC_URL from the environment (CI secret) or
# contracts/confidential-wrapper/.env (see .env.example). The fork block comes from
# config/fork.json so runs are reproducible; FORK_BLOCK overrides it ad hoc.
fork-test:
	@FORK_URL="$$(./script/utils/resolve-fork.sh)" || exit 1; \
	forge test --fork-url "$${FORK_URL}" -vvv

clean:
	forge clean
