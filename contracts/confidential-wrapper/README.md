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
| `MNEMONIC` or `PRIVATE_KEY` | Local signer for the deployer account |
| `ETHEREUM_RPC_URL` | RPC URL for the `ethereum` network (mainnet) |
| `POLYGON_RPC_URL` | RPC URL for the `polygon` network (Polygon mainnet) |
| `SEPOLIA_RPC_URL` | RPC URL for the `sepolia` network (Sepolia testnet) |
| `AMOY_RPC_URL` | RPC URL for the `amoy` network (Polygon Amoy testnet) |
| `ETHERSCAN_API_KEY` | Etherscan API key (required for Etherscan verification; Blockscout/Sourcify need none) |

### Task inputs (batch deployment)

| Variable | Description |
| --- | --- |
| `NUM_CONFIDENTIAL_WRAPPERS` | Number of confidential wrappers to deploy |
| `CONFIDENTIAL_WRAPPER_NAME_{i}` | Name of the wrapper at index `i` (e.g. `"Confidential USDT"`) |
| `CONFIDENTIAL_WRAPPER_SYMBOL_{i}` | Symbol of the wrapper at index `i` (e.g. `"cUSDT"`) |
| `CONFIDENTIAL_WRAPPER_CONTRACT_URI_{i}` | Contract URI metadata for the wrapper at index `i` |
| `CONFIDENTIAL_WRAPPER_UNDERLYING_ADDRESS_{i}` | Address of the underlying ERC20 token for the wrapper at index `i` |
| `CONFIDENTIAL_WRAPPER_OWNER_ADDRESS_{i}` | Owner address for the wrapper at index `i` |
| `CONFIDENTIAL_WRAPPER_INITIAL_OBSERVERS_{i}` | JSON array of observer addresses to seed during initialization; use `[]` for none |
| `CONFIDENTIAL_WRAPPER_PAUSER_ADDRESS_{i}` | Address allowed to call `pause()`, set during initialization; the zero address disables pausing |

Every variable above is required in the batch path — a missing or misspelled one aborts the run
rather than deploying a wrapper with no observers or no pauser. Opt out explicitly with `[]` and the
zero address.

### Task inputs (upgrade implementation)

| Variable | Description |
| --- | --- |
| `CONFIDENTIAL_WRAPPER_UPGRADE_NAME` | Optional wrapper identifier included in the artifact (e.g. `cUSDT`). Used by `task:deployConfidentialWrapperImpl` when `--name` is omitted. Omit for a shared implementation |
| `CONFIDENTIAL_WRAPPER_UPGRADE_VERSION_TAG` | Version tag appended to the saved implementation artifact (e.g. `v4`). Used by `task:deployConfidentialWrapperImpl` when `--version-tag` is omitted |

> **Underlying deny-list configuration:** the selector alone carries enablement.
> Consumers of `getUnderlyingDenyListSelector` determine enablement with `selector != 0`. A deny-list
> getter whose selector is genuinely `0x00000000` can exist in theory but is indistinguishable from
> "disabled" here, so the wrapper does not support one.

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
| `--underlying-deny-list-selector` | `string` | Yes | Function selector used to query the underlying token denylist; `0x00000000` disables the check |
| `--initial-observers` | `json` | No | JSON array of observer addresses to seed during `initialize` |
| `--pauser` | `string` | No | Address allowed to call `pause()`, set during `initialize`; defaults to the zero address, which disables pausing |

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
  --initial-observers '[]' \
  --pauser 0x2222222222222222222222222222222222222222 \
  --network sepolia
```

### `task:deployAllConfidentialWrappers`

Deploy all confidential wrapper contracts defined in the `.env` file. Reads `NUM_CONFIDENTIAL_WRAPPERS` and iterates over each wrapper's environment variables (`CONFIDENTIAL_WRAPPER_NAME_{i}`, `CONFIDENTIAL_WRAPPER_SYMBOL_{i}`, etc.).

Each wrapper must also provide the V3/V4 initializer configuration:

| Variable | Description |
| --- | --- |
| `CONFIDENTIAL_WRAPPER_BLOCKED_USERS_{i}` | JSON array of addresses to seed into the wrapper denylist |
| `CONFIDENTIAL_WRAPPER_UNDERLYING_DENY_LIST_SELECTOR_{i}` | Function selector used to query the underlying token denylist; `0x00000000` disables the check |
| `CONFIDENTIAL_WRAPPER_INITIAL_OBSERVERS_{i}` | JSON array of observer addresses to seed during initialization; use `[]` for none |
| `CONFIDENTIAL_WRAPPER_PAUSER_ADDRESS_{i}` | Address allowed to call `pause()`; the zero address disables pausing |

**Parameters:** None (configuration is read from environment variables).

**Example:**

```bash
npx hardhat task:deployAllConfidentialWrappers --network <network>
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
  --network <network>
```

### `task:verifyAllConfidentialWrappers`

Verify all deployed confidential wrapper contracts on Etherscan. Reads wrapper names from environment variables and fetches proxy addresses from the deployment artifacts.

**Parameters:** None (configuration is read from environment variables and deployment artifacts).

**Example:**

```bash
npx hardhat task:verifyAllConfidentialWrappers --network <network>
```

### `task:deployConfidentialWrapperImpl`

Deploy a new `ConfidentialWrapper` implementation contract without upgrading any proxy. The proxy upgrade is handled separately by the DAO.

The artifact is `ConfidentialWrapper_<versionTag>_Impl`, or `ConfidentialWrapper_<name>_<versionTag>_Impl` when a name is provided.

**Parameters:**

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `--name` | `string` | No | Wrapper identifier in the artifact (e.g. `"cUSDT"`). |
| `--version-tag` | `string` | No | Version tag appended to the saved artifact name (e.g. `"v4"`). Defaults to `CONFIDENTIAL_WRAPPER_UPGRADE_VERSION_TAG` |

**Example:**

```bash
npx hardhat task:deployConfidentialWrapperImpl --name cUSDT --version-tag v4 --network <network>
```

Shared implementation (no per-wrapper name):

```bash
npx hardhat task:deployConfidentialWrapperImpl --version-tag v4 --network <network>
```

Or, with `CONFIDENTIAL_WRAPPER_UPGRADE_VERSION_TAG` (and optionally `CONFIDENTIAL_WRAPPER_UPGRADE_NAME`) set in `.env`:

```bash
npx hardhat task:deployConfidentialWrapperImpl --network <network>
```

### `task:verifyConfidentialWrapperImpl`

Verify a `ConfidentialWrapper` implementation contract on Etherscan.

**Parameters:**

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `--impl-address` | `string` | Yes | The address of the implementation contract to verify |

**Example:**

```bash
npx hardhat task:verifyConfidentialWrapperImpl \
  --impl-address 0x1234567890123456789012345678901234567890 \
  --network <network>
```

## Scripts

### Foundry mainnet-fork tests

The mainnet-fork tests live in `test/foundry`. They run against a live mainnet fork, so they
need archive RPC access via `ETHEREUM_MAINNET_FORK_RPC_URL` (this package's `.env`,
see `.env.example`, or the environment):

```bash
cd test/foundry
make setup
make build
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
