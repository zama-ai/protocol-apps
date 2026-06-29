# Temporary fresh-wrapper deployment workaround

> ⚠️ **Temporary.** The current audited contract source cannot be deployed directly as V3 in a fresh deployment. Until this is fixed in V4, fresh deployments must use this workaround instead of [Option 1 in the main runbook](./deploy-wrapper-runbook.md#option-1--fresh-wrapper-contract-deployment).

This runbook combines a V1 fresh deployment with a single DAO proposal that both **upgrades the proxy to V3** and **registers the wrapper** in the registry.

---

## Overview

1. Deploy a fresh `ConfidentialWrapper` (V1) proxy from a pinned commit.
2. Verify the V1 proxy on Etherscan.
3. Confirm a V3 implementation is already deployed onchain.
4. Submit a single DAO proposal that bundles `upgradeToAndCall` (V1 → V3) and `registerConfidentialToken`.
5. Open a PR to update the addresses directory.

The DAO proposal at Step 4 replaces both Option 1 Step 4 (registry) and Option 2 Step 5 (upgrade) from the main runbook.

---

## Step 1 — Check out the pinned V1 commit

Fresh V1 deployments must use commit [`d59c6780`](https://github.com/zama-ai/protocol-apps/commit/d59c6780257031ebb75c7ecde8a1dbab4d09302b):

```bash
git fetch origin
git checkout d59c6780257031ebb75c7ecde8a1dbab4d09302b
```

Work from `contracts/confidential-wrapper` at this commit for Steps 2-3.

## Step 2 — Deploy the V1 proxy

From the `contracts/confidential-wrapper` directory at the pinned commit:

```bash
cp .env.example .env
npm install
npm run compile
```

Populate `.env`. V1 only takes the five constructor inputs (no blocked-users or denylist selector):

```dotenv
# Auth
MNEMONIC=                          # or PRIVATE_KEY=
MAINNET_RPC_URL=
ETHERSCAN_API_KEY=

NUM_CONFIDENTIAL_WRAPPERS=N

# Repeat for each i in 0..N-1
CONFIDENTIAL_WRAPPER_NAME_{i}=
CONFIDENTIAL_WRAPPER_SYMBOL_{i}=
CONFIDENTIAL_WRAPPER_CONTRACT_URI_{i}=
CONFIDENTIAL_WRAPPER_UNDERLYING_ADDRESS_{i}=
CONFIDENTIAL_WRAPPER_OWNER_ADDRESS_{i}=
```

**Batch (recommended when deploying multiple wrappers):**

```bash
npx hardhat task:deployAllConfidentialWrappers --network mainnet
```

**Single wrapper:**

```bash
npx hardhat task:deployConfidentialWrapper \
  --name "Confidential USDT" \
  --symbol "cUSDT" \
  --contract-uri 'data:application/json;utf8,{"name":"Confidential USDT","symbol":"cUSDT","description":"Confidential wrapper of USDT"}' \
  --underlying 0xdAC17F958D2ee523a2206206994597C13D831ec7 \
  --owner 0xB6D69D5F334d8B97B194617B53c6aB62f8681Ef3 \
  --network mainnet
```

Record the proxy address for every wrapper.

## Step 3 — Verify on Etherscan

This verifies both the proxy and the V1 implementation. See the note in the main runbook's [Step 3](./deploy-wrapper-runbook.md#step-3--verify-on-etherscan) about duplicate-verification notices when multiple wrappers share an implementation.

**Batch:**

```bash
npx hardhat task:verifyAllConfidentialWrappers --network mainnet
```

**Single:**

```bash
npx hardhat task:verifyConfidentialWrapper \
  --proxy-address <PROXY_ADDRESS> \
  --network mainnet
```

## Step 4 — Submit the combined DAO proposal

Prepare a single DAO proposal for each new wrapper proxy that calls:

1. **Upgrade** V1 → V3:

```solidity
proxy.upgradeToAndCall(v3ImplementationAddress, reinitializeV3Calldata);
```

2. **Register** the wrapper in the registry:

```solidity
registry.registerConfidentialToken(
    underlyingERC20Address,
    confidentialWrapperProxyAddress
);
```

`v3ImplementationAddress` should reuse an existing V3 implementation:

**Ethereum**: `0x5226fe30Fa7Bf20C1Cd33F125f77D0c42d3c23b5`

**Sepolia**: `0x390aA02fB7ebA565bfCFC43f67DB7E4D05c1D0Ee`

For encoding `reinitializeV3Calldata`, see [Getting calldata bytes](./deploy-wrapper-runbook.md#getting-calldata-bytes) in the main runbook.

See the [Creating Ethereum Proposals](/docs/governance/creating-proposals-ethereum.md) guide for help on creating a new proposal.

## Step 5 — Update the addresses directory

Same as [Option 1 Step 5](./deploy-wrapper-runbook.md#step-5--update-the-addresses-directory).
