#!/usr/bin/env bash
# Run the pauser fork suite against one network. Usage (from test/foundry, as make invokes it):
#
#   NETWORK=<ethereum|sepolia|polygon|amoy> ./script/utils/fork-test.sh [extra forge args]
#
# RPC URL: the environment variable named by config/fork.json `<network>.rpcEnv` (CI secret), then the same
# variable from contracts/confidential-wrapper-pauser/.env for local dev. Exits 1 with guidance if neither is set.
#
# Block: FORK_BLOCK (ad-hoc override) first, then the committed `<network>.block` pin, then latest - 50.
#
# The network key is exported as FORK_NETWORK so test/PauserFork.t.sol picks the matching registry.
set -euo pipefail

NETWORK="${NETWORK:-ethereum}"
LATEST_BLOCK_OFFSET=50
CONFIG="config/fork.json"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to read ${CONFIG}." >&2
  exit 1
fi

if ! jq -e --arg n "${NETWORK}" 'has($n)' "${CONFIG}" >/dev/null; then
  echo "Unknown NETWORK \"${NETWORK}\"; keys in ${CONFIG}: $(jq -r 'del(._doc) | keys | join(", ")' "${CONFIG}")" >&2
  exit 1
fi

RPC_ENV="$(jq -r --arg n "${NETWORK}" '.[$n].rpcEnv' "${CONFIG}")"
URL="${!RPC_ENV:-}"

if [ -z "${URL}" ] && [ -f ../../.env ]; then
  URL="$(. ../../.env && printf '%s' "${!RPC_ENV:-}")"
fi

if [ -z "${URL}" ]; then
  echo "${RPC_ENV} is not set." >&2
  echo "Set it in the environment (CI secret) or in contracts/confidential-wrapper-pauser/.env (see .env.example)." >&2
  exit 1
fi

BLOCK="${FORK_BLOCK:-}"

if [ -z "${BLOCK}" ]; then
  # Emits the block, or nothing when it is null; any other value is a config error.
  BLOCK="$(jq -er --arg n "${NETWORK}" '
    .[$n].block as $b
    | if $b == null then ""
      elif ($b | type) == "number" and ($b | floor) == $b and $b > 0 then ($b | tostring)
      else "config/fork.json: \($n).block must be a positive integer or null, got \($b | tojson)\n" | halt_error(1)
      end
  ' "${CONFIG}")"
fi

if [ -z "${BLOCK}" ]; then
  if ! command -v cast >/dev/null 2>&1; then
    echo "cast is required to resolve latest - ${LATEST_BLOCK_OFFSET} (install Foundry, or set FORK_BLOCK)." >&2
    exit 1
  fi
  LATEST_BLOCK="$(cast block-number --rpc-url "${URL}")"
  BLOCK="$((LATEST_BLOCK - LATEST_BLOCK_OFFSET))"
fi

echo "Forking ${NETWORK} at block ${BLOCK}" >&2
FORK_NETWORK="${NETWORK}" exec forge test --fork-url "${URL}" --fork-block-number "${BLOCK}" -vvv "$@"
