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

### Task inputs (batch deploy upgrade implementations)

| Variable | Description |
| --- | --- |
| `NUM_CONFIDENTIAL_WRAPPERS` | Same meaning as batch deployment: how many wrappers are listed in `.env` |
| `CONFIDENTIAL_WRAPPER_NAME_{i}` | Name of the wrapper at index `i` |
| `CONFIDENTIAL_WRAPPER_UPGRADE_VERSION_LABEL` | Version label appended to the saved implementation artifact (e.g. `v2`), shared for all wrappers in the batch upgrade/verify tasks |

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
| `--blocked-users` | `json` | Yes | JSON array of addresses to seed into the wrapper denylist during `initialize` |
| `--underlying-deny-list-selector` | `string` | Yes | Function selector used to query the underlying token denylist |
| `--has-underlying-deny-list-selector` | `boolean` | Yes | Whether the underlying token denylist selector should be enabled |

**Example:**

```bash
npx hardhat task:deployConfidentialWrapper \
  --name "Confidential USDT" \
  --symbol "cUSDT" \
  --contract-uri 'data:application/json;utf8,{"name":"Confidential USDT","symbol":"cUSDT","description":"Confidential wrapper of USDT"}' \
  --underlying 0x1234567890123456789012345678901234567890 \
  --owner 0x9876543210987654321098765432109876543210 \
  --blocked-users '[]' \
  --underlying-deny-list-selector 0x00000000 \
  --has-underlying-deny-list-selector false \
  --network testnet
```

### `task:deployAllConfidentialWrappers`

Deploy all confidential wrapper contracts defined in the `.env` file. Reads `NUM_CONFIDENTIAL_WRAPPERS` and iterates over each wrapper's environment variables (`CONFIDENTIAL_WRAPPER_NAME_{i}`, `CONFIDENTIAL_WRAPPER_SYMBOL_{i}`, etc.).

Each wrapper must also provide the V3 initializer configuration:

| Variable | Description |
| --- | --- |
| `CONFIDENTIAL_WRAPPER_BLOCKED_USERS_{i}` | JSON array of addresses to seed into the wrapper denylist |
| `CONFIDENTIAL_WRAPPER_UNDERLYING_DENY_LIST_SELECTOR_{i}` | Function selector used to query the underlying token denylist |
| `CONFIDENTIAL_WRAPPER_HAS_UNDERLYING_DENY_LIST_SELECTOR_{i}` | Whether the underlying token denylist selector should be enabled |

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

### `task:deployWrapperImplementation`

Deploy a new `ConfidentialWrapper` implementation contract without upgrading any proxy. The proxy upgrade is handled separately by the DAO.

**Parameters:**

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `--name` | `string` | Yes | The name of the wrapper this implementation is for |
| `--label` | `string` | Yes | A version label appended to the artifact name (e.g. `"v2"`) |

**Example:**

```bash
npx hardhat task:deployWrapperImplementation --name "Confidential USDT" --label "v2" --network testnet
```

### `task:deployAllWrapperImplementations`

Requires that `CONFIDENTIAL_WRAPPER_UPGRADE_VERSION_LABEL` is set in the `.env` file.

Deploy upgrade implementations for all wrappers defined in the `.env` file. Reads `NUM_CONFIDENTIAL_WRAPPERS`, `CONFIDENTIAL_WRAPPER_NAME_{i}`, and `CONFIDENTIAL_WRAPPER_UPGRADE_VERSION_LABEL`.

**Parameters:** None (configuration is read from environment variables).

**Example:**

```bash
npx hardhat task:deployAllWrapperImplementations --network testnet
```

### `task:verifyWrapperImplementation`

Verify a single `ConfidentialWrapper` implementation contract on Etherscan.

**Parameters:**

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `--address` | `string` | Yes | The address of the implementation contract to verify |

**Example:**

```bash
npx hardhat task:verifyWrapperImplementation --address 0x1234567890123456789012345678901234567890 --network testnet
```

### `task:verifyAllWrapperImplementations`

Verify upgrade implementation contracts for all wrappers on Etherscan. Looks up deployment artifacts using `CONFIDENTIAL_WRAPPER_NAME_{i}` and `CONFIDENTIAL_WRAPPER_UPGRADE_VERSION_LABEL`.

**Parameters:** None (configuration is read from environment variables and deployment artifacts).

**Example:**

```bash
npx hardhat task:verifyAllWrapperImplementations --network testnet
```

## Scripts

### Foundry mainnet-fork tests

The mainnet-fork tests live in `test/foundry`. They run against a live mainnet fork, so they
need archive RPC access via `ETHEREUM_MAINNET_FORK_RPC_URL` (this package's `.env`,
see `.env.example`, or the environment):

```bash
cd test/foundry
npm run setup
make fork-test
```

See [`test/foundry/README.md`](test/foundry/README.md) for details.

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
4. Register the wrapper in the registry (see the [registry documentation](../../docs/wrapper-registry.md)).
