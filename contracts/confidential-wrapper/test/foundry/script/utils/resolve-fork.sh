#!/usr/bin/env bash
# Resolve the fork target for a network and print it to stdout as forge's --fork-url argument,
# i.e. "<rpc-url>" or "<rpc-url>@<block>". Progress goes to stderr so stdout stays parseable.
#
# Network: the NETWORK environment variable (exported by the Makefile, default "ethereum"). It
# selects an entry in config/fork.json, which carries that network's `rpcUrlEnv` and `block`.
#
# Block: the FORK_BLOCK environment variable (ad-hoc override) first, then the committed
# config/fork.json pin, and finally latest - 50 when the pin is null.
#
# Run from the foundry package root (test/foundry), where make invokes it, so ../../.env and
# ./config/fork.json resolve.
set -euo pipefail

NETWORK="${NETWORK:-ethereum}"
FORK_CONFIG=config/fork.json
LATEST_BLOCK_OFFSET=50

# The whole entry for this network, so the file is parsed once and an unknown NETWORK fails here
# rather than as a confusing empty value further down.
NET="$(jq -er --arg n "${NETWORK}" '
  .[$n] // ("\(input_filename): unknown network \($n); known: \([keys[] | select(startswith("_") | not)] | join(", "))\n" | halt_error(1))
' "${FORK_CONFIG}")"

URL_ENV="$(printf '%s' "${NET}" | jq -er '.rpcUrlEnv')"
URL="${!URL_ENV:-}"

if [ -z "${URL}" ] && [ -f ../../.env ]; then
  URL="$(. ../../.env && printf '%s' "${!URL_ENV:-}")"
fi

if [ -z "${URL}" ]; then
  echo "${URL_ENV} is not set (required to fork ${NETWORK})." >&2
  echo "Set it in the environment (CI secret) or in contracts/confidential-wrapper/.env (see .env.example)." >&2
  exit 1
fi

BLOCK="${FORK_BLOCK:-}"

if [ -z "${BLOCK}" ]; then
  # Emits the block, or nothing when it is null; any other value is a config error.
  BLOCK="$(printf '%s' "${NET}" | jq -er --arg n "${NETWORK}" '
    .block as $b
    | if $b == null then ""
      elif ($b | type) == "number" and ($b | floor) == $b and $b > 0 then ($b | tostring)
      else "config/fork.json: \($n).block must be a positive integer or null, got \($b | tojson)\n" | halt_error(1)
      end
  ')"
fi

if [ -z "${BLOCK}" ]; then
  if ! command -v cast >/dev/null 2>&1; then
    echo "cast is required to resolve latest - ${LATEST_BLOCK_OFFSET} (install Foundry, or set FORK_BLOCK to bypass)." >&2
    exit 1
  fi

  LATEST_BLOCK="$(cast block-number --rpc-url "${URL}")"
  BLOCK="$((LATEST_BLOCK - LATEST_BLOCK_OFFSET))"
fi

echo "Forking ${NETWORK} at block ${BLOCK}" >&2
printf '%s@%s' "${URL}" "${BLOCK}"
