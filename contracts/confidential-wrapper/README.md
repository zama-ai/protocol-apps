# Confidential Wrapper

Wraps standard ERC20 tokens into confidential ERC7984 tokens using FHE. Deployed as UUPS upgradeable proxies.

## Setup

1. Copy `.env.example` to `.env` and fill in the required values (see below).
2. Run `npm install` to install dependencies.
3. Run `npm run compile` to compile the contracts.

## Environment Variables

### Blockchain configuration

| Variable | Description |
| --- | --- |
| `MNEMONIC` or `PRIVATE_KEY` | Authentication for the deployer account |
| `MAINNET_RPC_URL` | RPC URL for mainnet |
| `SEPOLIA_RPC_URL` | RPC URL for Sepolia testnet |
| `ETHERSCAN_API_KEY` | Etherscan API key (required for contract verification) |

### Task inputs (batch deployment)

| Variable | Description |
| --- | --- |
| `NUM_CONFIDENTIAL_WRAPPERS` | Number of confidential wrappers to deploy |
| `CONFIDENTIAL_WRAPPER_NAME_{i}` | Name of the wrapper at index `i` (e.g. `"Confidential USDT"`) |
| `CONFIDENTIAL_WRAPPER_SYMBOL_{i}` | Symbol of the wrapper at index `i` (e.g. `"cUSDT"`) |
| `CONFIDENTIAL_WRAPPER_CONTRACT_URI_{i}` | Contract URI metadata for the wrapper at index `i` |
| `CONFIDENTIAL_WRAPPER_UNDERLYING_ADDRESS_{i}` | Address of the underlying ERC20 token for the wrapper at index `i` |
| `CONFIDENTIAL_WRAPPER_OWNER_ADDRESS_{i}` | Owner address for the wrapper at index `i` |

## Hardhat Tasks

### `task:deployConfidentialWrapper`

Deploy a single confidential wrapper contract.

**Parameters:**

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `--name` | `string` | Yes | The name of the confidential wrapper (e.g. `"Confidential USDT"`) |
| `--symbol` | `string` | Yes | The symbol of the confidential wrapper (e.g. `"cUSDT"`) |
| `--contract-uri` | `string` | Yes | The contract URI containing JSON metadata for the wrapper |
| `--underlying` | `string` | Yes | The address of the underlying ERC20 token to wrap |
| `--owner` | `string` | Yes | The address that will own the deployed wrapper contract |

**Example:**

```bash
npx hardhat task:deployConfidentialWrapper \
  --name "Confidential USDT" \
  --symbol "cUSDT" \
  --contract-uri 'data:application/json;utf8,{"name":"Confidential USDT","symbol":"cUSDT","description":"Confidential wrapper of USDT"}' \
  --underlying 0x1234567890123456789012345678901234567890 \
  --owner 0x9876543210987654321098765432109876543210 \
  --network testnet
```

### `task:deployAllConfidentialWrappers`

Deploy all confidential wrapper contracts defined in the `.env` file. Reads `NUM_CONFIDENTIAL_WRAPPERS` and iterates over each wrapper's environment variables (`CONFIDENTIAL_WRAPPER_NAME_{i}`, `CONFIDENTIAL_WRAPPER_SYMBOL_{i}`, etc.).

**Parameters:** None (configuration is read from environment variables).

**Example:**

```bash
npx hardhat task:deployAllConfidentialWrappers --network testnet
```

### `task:verifyConfidentialWrapper`

Verify a single confidential wrapper contract (both proxy and implementation) on Etherscan.

**Parameters:**

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `--proxy-address` | `string` | Yes | The address of the deployed confidential wrapper proxy contract |

**Example:**

```bash
npx hardhat task:verifyConfidentialWrapper \
  --proxy-address 0x1234567890123456789012345678901234567890 \
  --network testnet
```

### `task:verifyAllConfidentialWrappers`

Verify all deployed confidential wrapper contracts on Etherscan. Reads wrapper names from environment variables and fetches proxy addresses from the deployment artifacts.

**Parameters:** None (configuration is read from environment variables and deployment artifacts).

**Example:**

```bash
npx hardhat task:verifyAllConfidentialWrappers --network testnet
```

## Scripts

### `test-upgrade`

Simulates an upgrade on a forked network. Captures all on-chain state before the upgrade, deploys a new implementation, executes `upgradeToAndCall`, and verifies that all storage (public getters, raw ERC7201 slots, `_unwrapRequests` mapping entries) is preserved. Also checks that new function signatures are present and security invariants hold (re-initialization blocked, non-owner upgrade blocked).

Uses a dedicated hardhat config (`hardhat.config.fork.ts`) that omits `@fhevm/hardhat-plugin` to avoid genesis storage overrides that conflict with forking.

**Required environment variables:**

| Variable | Description |
| --- | --- |
| `CONFIDENTIAL_WRAPPER_UPGRADE_TEST_RPC_URL` | RPC URL for the network to fork |
| `CONFIDENTIAL_WRAPPER_UPGRADE_TEST_ADDRESS` | Address of the deployed wrapper proxy to test against |
| `CONFIDENTIAL_WRAPPER_UPGRADE_TEST_DEPLOY_BLOCK` | Block number at which the wrapper was deployed (for event scanning) |

**Example:**

```bash
npx hardhat --config hardhat.config.fork.ts run scripts/test-upgrade.ts
```

## Deployment Steps

### Deploy wrapper(s)

1. Set up the `.env` file with the required environment variables (see above).
2. Deploy using one of:
   - **Batch**: `npx hardhat task:deployAllConfidentialWrappers --network <network>`
   - **Single**: `npx hardhat task:deployConfidentialWrapper ... --network <network>`
3. Verify the contracts:
   - **First deployment**:
     - **Batch**: `npx hardhat task:verifyAllConfidentialWrappers --network <network>`
     - **Single**: `npx hardhat task:verifyConfidentialWrapper ... --network <network>`
   - **Subsequent upgrades**: on Etherscan:
     - open the wrapper proxy address
     - go to "Contract" > "Code" > "More Options" > "Is this a proxy?" > "Verify" > "Save"
     - go back to the wrapper page and refresh
4. Register the wrapper in the registry (see the [registry documentation](../../docs/registry-contract.md)).
