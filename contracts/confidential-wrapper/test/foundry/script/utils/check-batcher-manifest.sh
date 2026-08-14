#!/usr/bin/env bash
# Check that config/batchers.json still matches the live deployment manifest in
# zama-ai/confidential-defi. The batcher fork suite drives the deployed bytecode at those
# addresses, so a redeploy there silently turns this suite into a test of dead contracts.
#
# Reads the upstream manifest through `gh api`, which works for a private repo when GH_TOKEN
# (or a `gh auth login` session) grants access. Without credentials the check skips rather than
# fails, so a missing token never breaks the fork-test job.
#
# Run from the foundry package root (test/foundry), where make and CI invoke it.
set -euo pipefail

UPSTREAM_REPO="zama-ai/confidential-defi"
UPSTREAM_PATH="contracts/deployments/mainnet.json"
LOCAL_MANIFEST="config/batchers.json"
KEYS=(depositBatcher redeemBatcher cUsdc cShare morphoVault)

for cmd in gh jq; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "SKIP: ${cmd} is not installed, cannot verify ${LOCAL_MANIFEST}." >&2
    exit 0
  fi
done

if ! UPSTREAM="$(gh api "repos/${UPSTREAM_REPO}/contents/${UPSTREAM_PATH}" \
  --jq '.content' 2>/dev/null | base64 -d)"; then
  echo "SKIP: could not read ${UPSTREAM_REPO}/${UPSTREAM_PATH} (no token or no access)." >&2
  exit 0
fi

STATUS=0
for key in "${KEYS[@]}"; do
  # Addresses are compared case-insensitively: the manifests carry different checksum casings.
  want="$(printf '%s' "${UPSTREAM}" | jq -er --arg k "${key}" '.[$k]' | tr 'A-Z' 'a-z')"
  got="$(jq -er --arg k "${key}" '.[$k]' "${LOCAL_MANIFEST}" | tr 'A-Z' 'a-z')"
  if [ "${want}" != "${got}" ]; then
    echo "MISMATCH ${key}: ${LOCAL_MANIFEST} has ${got}, ${UPSTREAM_REPO} has ${want}" >&2
    STATUS=1
  fi
done

if [ "${STATUS}" -ne 0 ]; then
  echo "Update ${LOCAL_MANIFEST} from ${UPSTREAM_REPO}/${UPSTREAM_PATH} and re-run the batcher fork tests." >&2
  exit 1
fi

echo "${LOCAL_MANIFEST} matches ${UPSTREAM_REPO}/${UPSTREAM_PATH}."
