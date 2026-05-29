# Native confidential token

This guide explains how to deploy a basic **native confidential token**, meaning an `ERC-7984` token that manages its own confidential supply directly instead of wrapping an existing ERC-20. Unlike a [confidential wrapper](confidential-wrapper.md), the issuer defines the token contract, the minting policy, the upgrade policy, and the administrative model.

The goal of this document is to provide a clear path to follow from the reference materials in this repository to a deployed upgradeable native confidential token.

## Terminology

* **Native confidential token**: A token contract that directly implements the `ERC-7984` confidential token standard.
* **ERC-7984**: A confidential fungible token standard where balances and transfer amounts are encrypted.
* **Owner**: The privileged account that administers the token in the reference example in this guide.
* **Operator**: An address authorized to transfer confidential tokens on behalf of a holder for a limited period of time.
* **ACL**: The Access Control List contract used by fhEVM to manage who is allowed to use a ciphertext. More information in the [ACL guide](https://docs.zama.org/protocol/solidity-guides/smart-contract/acl).
* **Input proof**: A proof that an encrypted input is valid. More information in the [Zama SDK documentation](https://docs.zama.org/protocol/sdk/guides/encrypt-decrypt).
* **Public decryption**: A process that makes an encrypted amount publicly decryptable and then reveals its cleartext value with a proof.
* **Proxy**: The onchain contract address users interact with.
* **Implementation**: The logic contract used by the proxy.

## Contract information

| Resource | Link |
| --- | --- |
| Upgradeable ERC-7984 | [ERC7984Upgradeable.sol](https://github.com/zama-ai/protocol-apps/blob/9ccc8e9037cbc13fe162b0c622e42e644498ea62/contracts/confidential-token/contracts/token/ERC7984Upgradeable.sol) |
| FHE config helper | [ZamaEthereumConfigUpgradeable.sol](https://github.com/zama-ai/protocol-apps/blob/9ccc8e9037cbc13fe162b0c622e42e644498ea62/contracts/confidential-token/contracts/fhevm/ZamaEthereumConfigUpgradeable.sol) |
| OpenZeppelin access control docs | [Access Control](https://docs.openzeppelin.com/contracts/5.x/access-control) |
| OpenZeppelin upgradeability docs | [Writing Upgradeable Contracts](https://docs.openzeppelin.com/upgrades-plugins/writing-upgradeable) |
| OpenZeppelin utility contracts | [Utilities](https://docs.openzeppelin.com/contracts/api/utils) |
| Hardhat getting started | [Getting started](https://hardhat.org/docs/getting-started) |
| Hardhat configuration docs | [Configuration](https://hardhat.org/docs/reference/configuration) |

## Quick Start

### Step 1: Start from the reference deployment example

The recommended starting point is the reference deployment example in this repository:

```bash
cd scripts/native-confidential-token
cp .env.example .env
npm install
```

This project already contains:

* a minimal `NativeConfidentialToken.sol` example
* a deploy script
* a minimal Hardhat config
* a `.env.example`
* a local package dependency on the reusable base contracts in `contracts/confidential-token/`

If you later move this reference example into a separate repository, preserve the same package relationship or vendor the reusable base contracts directly.

### Step 2: Configure `.env`

Fill the `.env` file used by the reference example:

| Key | Expected value |
| --- | --- |
| `MNEMONIC` | Optional wallet seed phrase for the deployer account. Use this or `PRIVATE_KEY`. |
| `PRIVATE_KEY` | Optional private key for the deployer account. Use this or `MNEMONIC`. |
| `SEPOLIA_RPC_URL` | RPC endpoint URL for Sepolia deployments. |
| `MAINNET_RPC_URL` | RPC endpoint URL for Ethereum mainnet deployments. |
| `ETHERSCAN_API_KEY` | API key used for contract verification in Etherscan-compatible explorers. |
| `OWNER_ADDRESS` | Address that will own the deployed proxy and control owner-only actions such as minting and upgrades. |
| `TOKEN_NAME` | Human-readable token name. |
| `TOKEN_SYMBOL` | Short token ticker symbol. |
| `TOKEN_CONTRACT_URI` | Token metadata URI, such as a `data:` URI or an HTTPS-hosted JSON document. |

Set either `MNEMONIC` or `PRIVATE_KEY` for deployment signing. The reference example already loads these values through `dotenv`. For the current Hardhat initialization flow and config options, refer to the official [Hardhat getting started](https://hardhat.org/docs/getting-started) and [Hardhat configuration](https://hardhat.org/docs/reference/configuration) guides.

### Step 3: Use the reference deployment example

The deployable reference flow lives in [`scripts/native-confidential-token`](https://github.com/zama-ai/protocol-apps/tree/9ccc8e9037cbc13fe162b0c622e42e644498ea62/scripts/native-confidential-token).

The reference project uses `contracts/confidential-token` as a local package dependency. After `npm install`, the example resolves the reusable base contracts through the `confidential-token-base/...` Solidity imports.

{% hint style="warning" %}
The concrete `NativeConfidentialToken.sol` contract in the reference deployment project is a **reference example only**. It is not a supported implementation and should be treated as a starting point for integrators rather than a drop-in production contract.
{% endhint %}

### Step 4: Implement the token contract

This guide uses `Ownable2StepUpgradeable` as the administrative model in the main example to keep the baseline simple.

If your deployment needs multiple privileged actors, role separation, or emergency controls, OpenZeppelin documents those options separately:

* `Ownable` and `Ownable2Step` in the [OpenZeppelin access control docs](https://docs.openzeppelin.com/contracts/5.x/access-control)
* `AccessControlUpgradeable` in the same [access control docs](https://docs.openzeppelin.com/contracts/5.x/access-control)
* `PausableUpgradeable` and other optional building blocks in [OpenZeppelin utilities](https://docs.openzeppelin.com/contracts/api/utils)

The reference example contract imports the reusable base contracts through the local package dependency:

```solidity
// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {FHE, externalEuint64, euint64} from "@fhevm/solidity/lib/FHE.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ZamaEthereumConfigUpgradeable} from "confidential-token-base/contracts/fhevm/ZamaEthereumConfigUpgradeable.sol";
import {ERC7984Upgradeable} from "confidential-token-base/contracts/token/ERC7984Upgradeable.sol";

contract NativeConfidentialToken is
    ERC7984Upgradeable,
    ZamaEthereumConfigUpgradeable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable
{
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name_,
        string memory symbol_,
        string memory contractURI_,
        address owner_
    ) public initializer {
        __ERC7984_init(name_, symbol_, contractURI_);
        __ZamaEthereumConfig_init();
        __Ownable_init(owner_);
        __Ownable2Step_init();
    }

    function mint(
        address to,
        externalEuint64 encryptedAmount,
        bytes calldata inputProof
    ) external onlyOwner returns (euint64) {
        return _mint(to, FHE.fromExternal(encryptedAmount, inputProof));
    }

    function burn(
        externalEuint64 encryptedAmount,
        bytes calldata inputProof
    ) external returns (euint64) {
        return _burn(msg.sender, FHE.fromExternal(encryptedAmount, inputProof));
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
```

The constructor calls `_disableInitializers()` so the implementation contract cannot be initialized directly. Without that guard, an attacker could initialize the implementation address itself and take control of the logic contract.

This example uses:

* `Ownable2StepUpgradeable` for administration
* `UUPSUpgradeable` for proxy upgrades
* owner-authorized minting
* self-service burning

{% hint style="warning" %}
### **Base ERC-7984 constraints**

The upgradeable `ERC7984` base used here returns `6` decimals and stores confidential amounts as `euint64`. In practice, this means the token precision is fixed to 6 decimals and the confidential supply is bounded by `type(uint64).max`.
{% endhint %}

{% hint style="info" %}
OpenZeppelin recommends initializer-based setup for upgradeable contracts and recommends disabling initializers in the implementation constructor so the implementation cannot be taken over directly. See [Writing Upgradeable Contracts](https://docs.openzeppelin.com/upgrades-plugins/writing-upgradeable).
{% endhint %}

### Step 5: Decide your mint strategy

Before deploying, decide how the token supply should enter circulation.

Common options include:

* **Zero initial supply, then mint after deployment**
  Best when you want the simplest proxy deployment flow and confidential issuance controlled by the owner after deployment.
* **Public initial allocations in `initialize`**
  Best when initial recipients and amounts do not need to be confidential at deployment time. The `initialAmounts_` values are passed in plaintext deployment calldata and remain permanently visible in transaction history.
* **Custom confidential initialization flow**
  Best when you need confidential genesis allocations at deployment time, but this requires extra deployment choreography. Zama encrypted inputs are generated for a specific contract address and user address. See the [encrypted inputs guide](https://docs.zama.org/protocol/solidity-guides/smart-contract/inputs) and the [encrypt/decrypt guide](https://docs.zama.org/protocol/sdk/guides/encrypt-decrypt). 

Example public pre-mint initializer extension:

```solidity
function initialize(
    string memory name_,
    string memory symbol_,
    string memory contractURI_,
    address owner_,
    address[] memory initialHolders_,
    uint64[] memory initialAmounts_
) public initializer {
    __ERC7984_init(name_, symbol_, contractURI_);
    __ZamaEthereumConfig_init();
    __Ownable_init(owner_);
    __Ownable2Step_init();

    require(initialHolders_.length == initialAmounts_.length, "length mismatch");

    for (uint256 i = 0; i < initialHolders_.length; i++) {
        _mint(initialHolders_[i], FHE.asEuint64(initialAmounts_[i]));
    }
}
```

### Step 6: Create the deployment script

Create `scripts/deploy-native-token.ts`, or reuse the example from [`scripts/native-confidential-token/scripts/deploy-native-token.ts`](https://github.com/zama-ai/protocol-apps/blob/9ccc8e9037cbc13fe162b0c622e42e644498ea62/scripts/native-confidential-token/scripts/deploy-native-token.ts):

```ts
import "dotenv/config";
import { ethers, upgrades } from "hardhat";

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is required`);
  }
  return value;
}

async function main() {
  const factory = await ethers.getContractFactory("NativeConfidentialToken");

  const proxy = await upgrades.deployProxy(
    factory,
    [
      requiredEnv("TOKEN_NAME"),
      requiredEnv("TOKEN_SYMBOL"),
      requiredEnv("TOKEN_CONTRACT_URI"),
      requiredEnv("OWNER_ADDRESS"),
    ],
    {
      initializer: "initialize",
      kind: "uups",
    }
  );

  await proxy.waitForDeployment();

  const proxyAddress = await proxy.getAddress();
  const implementationAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);

  console.log({
    proxyAddress,
    implementationAddress,
  });
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
```

To compile and deploy from `scripts/native-confidential-token/`:

```bash
npm run compile
npm run deploy:testnet
```

### Step 7: Verify the implementation and proxy

Verify the implementation contract:

```bash
npx hardhat verify --network testnet <IMPLEMENTATION_ADDRESS>
```

Then register the proxy as a proxy contract in your block explorer:

The menu flow below is specific to **Etherscan-style explorers**. Other explorers, such as Blockscout-style interfaces, expose similar proxy detection or proxy verification flows under different menus.

1. Open the proxy address in the explorer.
2. Go to `Contract` -> `Code`.
3. Open `More Options` -> `Is this a proxy?`
4. Click `Verify` and then `Save`.

Users and integrators should interact with the **proxy address**, not the implementation address.

### Step 8: Validate the deployment

Optionally, once deployed, do a small end-to-end validation:

1. Confirm the proxy reports the expected token metadata.
2. Confirm the owner is set correctly.
3. Mint a small confidential amount to a test holder.
4. Read the holder's encrypted balance from `confidentialBalanceOf`.
5. Read the encrypted total supply from `confidentialTotalSupply`.
6. Perform one small confidential transfer between two test accounts.
7. Confirm the recipient can access the resulting ciphertext through the normal fhEVM flow.

For the offchain encryption and decryption workflow used in these checks, use the [Zama SDK encrypt/decrypt guide](https://docs.zama.org/protocol/sdk/guides/encrypt-decrypt).

## Operator system

The `ERC7984` operator model allows a holder to delegate transfer capability to another account for a limited period of time.

Grant an operator:

```solidity
token.setOperator(operator, validUntilTimestamp);
```

Check if an operator is active:

```solidity
bool isAuthorized = token.isOperator(holder, operator);
```

An active operator can then call:

```solidity
token.confidentialTransferFrom(from, to, encryptedAmount, inputProof);
```

or, if they already have ACL access to the ciphertext:

```solidity
token.confidentialTransferFrom(from, to, encryptedAmountHandle);
```

Best practices:

* keep operator approvals short-lived
* prefer dedicated operational accounts rather than broad shared wallets
* revoke or replace approvals when workflows change
* test the operator flow explicitly before using it in production workflows

## Working with encrypted balances

After deployment, most operational workflows involve three related actions:

* encrypting an input amount offchain
* sending that encrypted amount to the token contract with its proof
* decrypting balances or disclosed values when authorized

The authoritative guide for this flow is the [Zama SDK encrypt/decrypt documentation](https://docs.zama.org/protocol/sdk/guides/encrypt-decrypt).

In practice:

* generate encrypted inputs for the **token proxy address**
* make sure the caller and contract have the necessary ACL permissions for any ciphertext that will be reused
* use `requestDiscloseEncryptedAmount` and `discloseEncryptedAmount` only when you intentionally want a public cleartext value
* refer to the [ACL guide](https://docs.zama.org/protocol/solidity-guides/smart-contract/acl) when deciding whether access should be permanent, transient, or public

## Administrative extensions

The reference example in this guide keeps administration intentionally simple, but it is not the only valid model.

Common variations include:

* `AccessControlUpgradeable` when separate minter, upgrader, compliance, or operations roles are needed
* `PausableUpgradeable` when an emergency stop mechanism is required
* other OpenZeppelin utility contracts when your deployment has additional operational or security requirements

For these patterns, rely on the official OpenZeppelin references:

* [Access Control](https://docs.openzeppelin.com/contracts/5.x/access-control)
* [Utilities](https://docs.openzeppelin.com/contracts/api/utils)

## Migrating beyond the reference project

The primary flow in this guide assumes you start from [`scripts/native-confidential-token`](https://github.com/zama-ai/protocol-apps/tree/9ccc8e9037cbc13fe162b0c622e42e644498ea62/scripts/native-confidential-token) and deploy from that reference project.

If you later want to move this flow into another repository, the reusable abstract/helper contracts live in [`contracts/confidential-token`](https://github.com/zama-ai/protocol-apps/tree/9ccc8e9037cbc13fe162b0c622e42e644498ea62/contracts/confidential-token).

To reuse only the base layer, vendor the following source files:

* [`ERC7984Upgradeable.sol`](https://github.com/zama-ai/protocol-apps/blob/9ccc8e9037cbc13fe162b0c622e42e644498ea62/contracts/confidential-token/contracts/token/ERC7984Upgradeable.sol)
* [`ZamaEthereumConfigUpgradeable.sol`](https://github.com/zama-ai/protocol-apps/blob/9ccc8e9037cbc13fe162b0c622e42e644498ea62/contracts/confidential-token/contracts/fhevm/ZamaEthereumConfigUpgradeable.sol)

Copying only these two Solidity files is **not** enough. They also import upstream dependencies from npm, so your project must install:

```bash
npm install @fhevm/solidity @openzeppelin/confidential-contracts @openzeppelin/contracts @openzeppelin/contracts-upgradeable
```

These files are the reusable base layer for a native confidential token in this repository. In the reference example project, their upstream imports are already satisfied by the package dependencies in `scripts/native-confidential-token/package.json`.

## Related registry guidance

Registering native confidential tokens will be supported in the near future.
