.PHONY: setup build fork-test clean

# Installs the soldeer dependencies pinned in foundry.toml (forge-std, OpenZeppelin).
setup:
	forge soldeer install

build:
	forge build

# Network-bound test run against a live fork of NETWORK (ethereum by default; sepolia, polygon, amoy).
# The RPC URL comes from the env var named in config/fork.json (CI secret) or from
# contracts/confidential-wrapper-pauser/.env; the fork block from FORK_BLOCK, the config pin, or latest - 50.
NETWORK ?= ethereum
fork-test:
	NETWORK=$(NETWORK) ./script/utils/fork-test.sh

clean:
	forge clean
