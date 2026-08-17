.PHONY: setup circle-artifacts fork-test msca-test fork-msca-test build clean

# local: no RPC. fork: archive node, included in fork-test.
# Separate directories because forge path globs are recursive.
MSCA_LOCAL_TESTS := test/msca/local/*
MSCA_FORK_TESTS := test/msca/fork/*

# Lazy so resolve-fork.sh only runs for fork targets.
FORK_URL = $$(./script/utils/resolve-fork.sh)

# Installs the soldeer dependencies pinned in soldeer.toml (incl. forge-fhevm).
setup:
	forge soldeer install --config-location soldeer

# Builds Circle's package at 0.8.24. Lint is off: we don't own that tree.
circle-artifacts:
	FOUNDRY_LINT_LINT_ON_BUILD=false FOUNDRY_PROFILE=circle forge build

build: circle-artifacts
	forge build

# Network-bound test run against a live mainnet fork. Reads
# ETHEREUM_MAINNET_FORK_RPC_URL from the environment (CI secret) or
# contracts/confidential-wrapper/.env (see .env.example). The fork block comes from
# config/fork.json so runs are reproducible; FORK_BLOCK overrides it ad hoc.
fork-test: circle-artifacts
	@URL="$(FORK_URL)" || exit 1; \
	forge test --fork-url "$${URL}" --no-match-path '$(MSCA_LOCAL_TESTS)' -vvv

# Local treasury suites: fhEVM host, Circle account, mock underlying.
msca-test: circle-artifacts
	forge test --match-path '$(MSCA_LOCAL_TESTS)'

# Live cUSDC migration on the same fork as fork-test.
fork-msca-test: circle-artifacts
	@URL="$(FORK_URL)" || exit 1; \
	forge test --fork-url "$${URL}" --match-path '$(MSCA_FORK_TESTS)' -vvv

clean:
	forge clean
	FOUNDRY_PROFILE=circle forge clean
