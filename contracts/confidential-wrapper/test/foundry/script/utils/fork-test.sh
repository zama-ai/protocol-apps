#!/usr/bin/env bash
# Run `forge test` against a live fork of a network, forwarding any extra arguments.
#
# Network: the NETWORK environment variable (exported by the Makefile, default "ethereum"). It
# selects an entry in config/fork.json, which carries that network's `block`, and names the
# `[rpc_endpoints]` alias in foundry.toml that forge and cast resolve to its RPC URL.
#
# Block: the FORK_BLOCK environment variable (ad-hoc override) first, then the committed
# config/fork.json pin, and finally latest - 50 when the pin is null.
#
# Run from the foundry package root (test/foundry), where make invokes it, so ../../.env,
# ./config/fork.json and ./foundry.toml resolve.
set -euo pipefail

NETWORK="${NETWORK:-ethereum}"
FORK_CONFIG=config/fork.json
ENV_FILE=../../.env
LATEST_BLOCK_OFFSET=50

# Foundry interpolates the ${...} in foundry.toml's [rpc_endpoints] from the process environment.
# CI sets those variables directly; locally they live in the package .env two directories above the
# Foundry root, which Foundry's own dotenv loading never reads. Take just the fork RPC entries from
# it — the rest of that file is deploy config bash cannot source — and never override a variable
# that is already set, so CI always wins.
if [ -f "${ENV_FILE}" ]; then
  while IFS='=' read -r key value; do
    [ -n "${!key:-}" ] || export "${key}=${value}"
  done < <(grep -E '^[A-Z0-9_]+_FORK_RPC_URL=' "${ENV_FILE}" | tr -d "\"'")
fi

# The whole entry for this network, so the file is parsed once and an unknown NETWORK fails here
# rather than as a confusing empty value further down.
NET="$(jq -er --arg n "${NETWORK}" '
  .[$n] // ("\(input_filename): unknown network \($n); known: \([keys[] | select(startswith("_") | not)] | join(", "))\n" | halt_error(1))
' "${FORK_CONFIG}")"

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
  LATEST_BLOCK="$(cast block-number --rpc-url "${NETWORK}")"
  BLOCK="$((LATEST_BLOCK - LATEST_BLOCK_OFFSET))"
fi

echo "Forking ${NETWORK} at block ${BLOCK}" >&2
exec forge test --fork-url "${NETWORK}" --fork-block-number "${BLOCK}" -vvv "$@"
