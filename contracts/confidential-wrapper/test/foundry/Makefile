.PHONY: setup fork-test fork-test-batcher build clean

# The chain to fork: a config/fork.json key, which also names its config/<network>/ directory.
# Exported so fork-test.sh and the tests (vm.envOr("NETWORK", ...)) read the same value.
NETWORK ?= ethereum
export NETWORK

# Installs the soldeer dependencies pinned in soldeer.toml (incl. forge-fhevm).
setup:
	forge soldeer install --config-location soldeer

build:
	forge build

# Network-bound test run against a live fork of $(NETWORK). fork-test.sh makes that network's RPC
# variable visible to Foundry (from the environment in CI, or contracts/confidential-wrapper/.env
# locally — see .env.example) and resolves the fork block from config/fork.json, which is unpinned
# by default so runs cover latest - 50; FORK_BLOCK pins a run ad hoc. Call the script directly to
# forward extra forge arguments, e.g. `./script/utils/fork-test.sh --match-test test_Foo`.
fork-test:
	@./script/utils/fork-test.sh

# Same fork, but the deployed-batcher suite under the `batcher` profile.
fork-test-batcher:
	@FOUNDRY_PROFILE=batcher ./script/utils/fork-test.sh

clean:
	forge clean
