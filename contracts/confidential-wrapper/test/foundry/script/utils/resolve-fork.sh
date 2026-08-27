#!/usr/bin/env bash
# Resolve the mainnet fork target and print it to stdout as forge's --fork-url argument,
# i.e. "<rpc-url>" or "<rpc-url>@<block>". Progress goes to stderr so stdout stays parseable.
#
# RPC URL: the process environment (CI injects ETHEREUM_MAINNET_FORK_RPC_URL from a GitHub
# secret) first, then contracts/confidential-wrapper/.env for local dev. Exits 1 with guidance
# if neither provides it.
#
# Block: the FORK_BLOCK environment variable (ad-hoc override) first, then the committed
# config/fork.json pin (read with jq), and finally latest - 50 when the pin is null.
#
# Run from the foundry package root (test/foundry), where make invokes it, so ../../.env and
# ./config/fork.json resolve.
set -euo pipefail

URL="${ETHEREUM_MAINNET_FORK_RPC_URL:-}"
LATEST_BLOCK_OFFSET=50

if [ -z "${URL}" ] && [ -f ../../.env ]; then
  URL="$(. ../../.env && printf '%s' "${ETHEREUM_MAINNET_FORK_RPC_URL:-}")"
fi

if [ -z "${URL}" ]; then
  echo "ETHEREUM_MAINNET_FORK_RPC_URL is not set." >&2
  echo "Set it in the environment (CI secret) or in contracts/confidential-wrapper/.env (see .env.example)." >&2
  exit 1
fi

BLOCK="${FORK_BLOCK:-}"

if [ -z "${BLOCK}" ] && [ -f config/fork.json ]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required to read config/fork.json (install it, or set FORK_BLOCK to bypass)." >&2
    exit 1
  fi
  # Emits the block, or nothing when it is null; any other value is a config error.
  BLOCK="$(jq -er '
    .ethereumMainnet.block as $b
    | if $b == null then ""
      elif ($b | type) == "number" and ($b | floor) == $b and $b > 0 then ($b | tostring)
      else "config/fork.json: ethereumMainnet.block must be a positive integer or null, got \($b | tojson)\n" | halt_error(1)
      end
  ' config/fork.json)"
fi

if [ -z "${BLOCK}" ]; then
  if ! command -v cast >/dev/null 2>&1; then
    echo "cast is required to resolve latest - ${LATEST_BLOCK_OFFSET} (install Foundry, or set FORK_BLOCK to bypass)." >&2
    exit 1
  fi

  LATEST_BLOCK="$(cast block-number --rpc-url "${URL}")"
  BLOCK="$((LATEST_BLOCK - LATEST_BLOCK_OFFSET))"
fi

echo "Forking Ethereum mainnet at block ${BLOCK}" >&2
printf '%s@%s' "${URL}" "${BLOCK}"
