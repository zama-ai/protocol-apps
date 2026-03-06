# Confidential Token Wrappers Registry

On-chain registry that maps ERC20 tokens to their confidential wrapper contracts. Deployed as a UUPS upgradeable proxy.

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

### Task inputs

| Variable | Description |
| --- | --- |
| `INITIAL_OWNER` | Address of the initial owner of the registry contract |

## Hardhat Tasks

### Registry deployment

#### `task:deployConfidentialTokenWrappersRegistry`

Deploy the `ConfidentialTokenWrappersRegistry` contract as a UUPS proxy. The initial owner is read from the `INITIAL_OWNER` environment variable.

**Parameters:** None (configuration is read from environment variables).

**Example:**

```bash
npx hardhat task:deployConfidentialTokenWrappersRegistry --network testnet
```

#### `task:verifyConfidentialTokenWrappersRegistry`

Verify the registry contract (both proxy and implementation) on Etherscan.

**Parameters:**

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `--proxy-address` | `string` | No | The address of the registry proxy contract. If not provided, the address is fetched from deployment artifacts. |

**Example:**

```bash
npx hardhat task:verifyConfidentialTokenWrappersRegistry \
  --proxy-address 0x1234567890123456789012345678901234567890 \
  --network testnet
```

### Mock tokens (testnet only)

#### `task:deployERC20Mock`

Deploy a mock ERC20 token contract. Useful for testing on testnets.

**Parameters:**

| Parameter | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `--name` | `string` | Yes | - | The name of the mock ERC20 token (e.g. `"Mock Token"`) |
| `--symbol` | `string` | Yes | - | The symbol of the mock ERC20 token (e.g. `"MTK"`) |
| `--decimals` | `int` | No | `18` | The number of decimals for the mock token |

**Example:**

```bash
npx hardhat task:deployERC20Mock \
  --name "Mock Token" \
  --symbol "MTK" \
  --decimals 18 \
  --network testnet
```

#### `task:deployUSDTMock`

Deploy a mock USDT token contract with the realistic "approve to zero first" quirk. Useful for testing USDT-specific behavior on testnets.

**Parameters:** None.

**Example:**

```bash
npx hardhat task:deployUSDTMock --network testnet
```

#### `task:verifyMockERC20`

Verify a deployed mock ERC20 contract on Etherscan.

**Parameters:**

| Parameter | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `--contract-address` | `string` | Yes | - | The address of the deployed mock ERC20 contract |
| `--name` | `string` | Yes | - | The name used when deploying the mock token |
| `--symbol` | `string` | Yes | - | The symbol used when deploying the mock token |
| `--decimals` | `int` | No | `18` | The decimals used when deploying the mock token |

**Example:**

```bash
npx hardhat task:verifyMockERC20 \
  --contract-address 0x1234567890123456789012345678901234567890 \
  --name "Mock Token" \
  --symbol "MTK" \
  --decimals 18 \
  --network testnet
```

#### `task:verifyUSDTMock`

Verify a deployed USDTMock contract on Etherscan.

**Parameters:**

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `--contract-address` | `string` | Yes | The address of the deployed USDTMock contract |

**Example:**

```bash
npx hardhat task:verifyUSDTMock \
  --contract-address 0x1234567890123456789012345678901234567890 \
  --network testnet
```

## Deployment Steps

### Deploy the registry

1. Set up the `.env` file with the required environment variables (see above).
2. Deploy: `npx hardhat task:deployConfidentialTokenWrappersRegistry --network <network>`
3. Verify the contract:
   - **First deployment**: run `task:verifyConfidentialTokenWrappersRegistry`.
   - **Subsequent upgrades**: on Etherscan:
     - open the registry proxy address
     - go to "Contract" > "Code" > "More Options" > "Is this a proxy?" > "Verify" > "Save"
     - go back to the registry page and refresh

### Deploy mock ERC20 tokens (testnet only)

1. Deploy the mock token:
   - **Standard ERC20**: `npx hardhat task:deployERC20Mock ... --network testnet`
   - **USDT (with approve quirk)**: `npx hardhat task:deployUSDTMock --network testnet`
2. Verify the contract:
   - **Standard ERC20**: `npx hardhat task:verifyMockERC20 ... --network testnet`
   - **USDT**: `npx hardhat task:verifyUSDTMock ... --network testnet`
3. Deploy a confidential wrapper for this token (see the [confidential-wrapper README](../confidential-wrapper/README.md)).
