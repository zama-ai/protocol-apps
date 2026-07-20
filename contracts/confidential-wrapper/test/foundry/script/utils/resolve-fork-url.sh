#!/usr/bin/env bash
# Resolve the archive fork RPC URL and print it to stdout.
#
# Prefers the process environment (CI injects ETHEREUM_MAINNET_FORK_RPC_URL
# from a GitHub secret), then falls back to contracts/confidential-wrapper/.env for local
# dev. Exits 1 with guidance if neither provides it. Run from the foundry package root
# (test/foundry), where make invokes it, so ../../.env resolves to the package .env.
set -euo pipefail

URL="${ETHEREUM_MAINNET_FORK_RPC_URL:-}"

if [ -z "${URL}" ] && [ -f ../../.env ]; then
  URL="$(. ../../.env && printf '%s' "${ETHEREUM_MAINNET_FORK_RPC_URL:-}")"
fi

if [ -z "${URL}" ]; then
  echo "ETHEREUM_MAINNET_FORK_RPC_URL is not set." >&2
  echo "Set it in the environment (CI secret) or in contracts/confidential-wrapper/.env (see .env.example)." >&2
  exit 1
fi

printf '%s' "${URL}"
