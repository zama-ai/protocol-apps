#!/usr/bin/env bash
set -euo pipefail

RPC="${1:-http://localhost:8545}"
STATE_FILE="${2:-deployments/mainnet-fork/anvil-state.json}"

if [[ ! -s "${STATE_FILE}" ]]; then
  echo "Missing Anvil state file: ${STATE_FILE}" >&2
  exit 1
fi

STATE="$(tr -d '\n' < "${STATE_FILE}")"
if [[ "${STATE}" != 0x* ]]; then
  echo "${STATE_FILE} is not a raw anvil_dumpState hex string" >&2
  exit 1
fi

RESPONSE="$(
  curl -fsS \
    -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"anvil_loadState\",\"params\":[\"${STATE}\"],\"id\":1}" \
    "${RPC}"
)"

if [[ "${RESPONSE}" != *'"result":true'* ]]; then
  echo "anvil_loadState failed: ${RESPONSE}" >&2
  exit 1
fi
