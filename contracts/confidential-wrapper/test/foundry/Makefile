.PHONY: setup fork-test fork-test-batcher build clean

# The chain to fork: a config/fork.json key, which also names its config/<network>/ directory.
# Exported so resolve-fork.sh and the tests (vm.envOr("NETWORK", ...)) read the same value.
NETWORK ?= ethereum
export NETWORK

# Installs the soldeer dependencies pinned in soldeer.toml (incl. forge-fhevm).
setup:
	forge soldeer install --config-location soldeer

build:
	forge build

# Network-bound test run against a live fork of $(NETWORK). resolve-fork.sh reads that
# network's RPC variable from the environment (CI secret) or contracts/confidential-wrapper/.env
# (see .env.example), and its fork block from config/fork.json, which is unpinned by default so
# runs cover latest - 50; FORK_BLOCK pins a run ad hoc.
fork-test:
	@FORK_URL="$$(./script/utils/resolve-fork.sh)" || exit 1; \
	forge test --fork-url "$${FORK_URL}" -vvv

# Same fork, but the deployed-batcher suite under the `batcher` profile.
fork-test-batcher:
	@FORK_URL="$$(./script/utils/resolve-fork.sh)" || exit 1; \
	FOUNDRY_PROFILE=batcher forge test --fork-url "$${FORK_URL}" -vvv

clean:
	forge clean
