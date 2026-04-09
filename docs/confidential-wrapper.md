# Confidential wrapper

This document gives an overview of the **Confidential Wrapper,** a smart contract that wraps standard ERC-20 tokens into confidential ERC-7984 tokens. Built on Zama's FHEVM, it enables privacy-preserving token transfers where balances and transfer amounts remain encrypted.

## Terminology

* **Confidential Token**: The ERC-7984 confidential token wrapper.
* **Underlying Token**: The standard ERC-20 token wrapped by the confidential wrapper.
* **Wrapping**: Converting ERC-20 tokens into confidential tokens.
* **Unwrapping**: Converting confidential tokens back into ERC-20 tokens.
* **Rate**: The conversion ratio between underlying token units and confidential token units (due to decimal differences).
* **Operator**: An address authorized to transfer confidential tokens on behalf of another address.
* **Owner**: The owner of the wrapper contract. In the FHEVM protocol, this is initially set to a DAO [governance](governance.md) contract handled by Zama. Ownership will then be transferred to the underlying token's owner.
* **Registry**: The registry contract that maps ERC-20 tokens to their corresponding confidential wrappers. More information [here](wrapper-registry.md).
* **ACL**: The Access Control List (ACL) contract that manages the permissions for encrypted amounts. More information in the [FHEVM library documentation](https://docs.zama.org/protocol/protocol/overview/library#access-control).
* **Input proof**: A proof that the encrypted amount is valid. More information in the [`relayer-sdk` documentation](https://docs.zama.org/protocol/relayer-sdk-guides/fhevm-relayer/input).
* **Public decryption**: A request to publicly decrypt an encrypted amount. More information in the [`relayer-sdk` documentation](https://docs.zama.org/protocol/relayer-sdk-guides/fhevm-relayer/decryption/public-decryption).

## Contract information

| Resource | Link |
| --- | --- |
| Deployed addresses | [Addresses directory](addresses/README.md) |
| Source code | [ConfidentialWrapper.sol](https://github.com/zama-ai/protocol-apps/blob/main/contracts/confidential-wrapper/contracts/ConfidentialWrapper.sol) |

## Quick Start

{% hint style="warning" %}
### **Decimal conversion**

The wrapper enforces a maximum number of decimals for the confidential token. When wrapping, amounts are rounded down and excess tokens are refunded. Currently, this maximum is set to **6 decimals** only. See [Maximum number of decimals](confidential-wrapper.md#maximum-number-of-decimals) for more information.
{% endhint %}

{% hint style="warning" %}
### **Unsupported tokens**

**Shielded Zama protocol staking shares do not earn rewards**

Operator staking shares issued by the Zama [staking protocol](staking.md) are vault-style shares that represent a proportional claim on the underlying staked assets. Staking rewards are accrued to the active holder of the shares. Wrapping these shares transfers their custody to the confidential wrapper contract, which becomes the address of record and the effective recipient of all future rewards. Consequently, holders of shielded shares do not earn staking rewards as long as their underlying shares remain shielded.

Non-standard tokens are not supported. This includes fee-on-transfer, deflationary, and rebasing tokens. See [Non-standard token types](#non-standard-token-types) for a full breakdown.
{% endhint %}

### Get the confidential wrapper address of an ERC-20 token

Zama provides a registry contract that maps ERC-20 tokens to their corresponding verified confidential wrappers. Make sure to check the registry contract to ensure the confidential wrapper is valid before wrapping. More information [here](wrapper-registry.md).

### Wrap ERC-20 → Confidential token

**Important:** Prior to wrapping, the confidential wrapper contract must be approved by the `msg.sender` on the underlying token.

```solidity
wrapper.wrap(to, amount);
```

The wrapper will mint the corresponding confidential token to the `to` address and refund the excess tokens to the `msg.sender` (due to decimal conversion). Considerations:

* `amount` must be a value using the same decimal precision as the underlying token.
* `to` must not be the zero address.

{% hint style="info" %}
### **Low amount handling**

If the amount is less than the rate, the wrapping will succeed but the recipient will receive 0 confidential tokens and the excess tokens will be refunded to the `msg.sender`.
{% endhint %}

### Unwrap confidential token → ERC-20

Unwrapping is a **two-step asynchronous process**: an `unwrap` must be first made and then finalized with `finalizeUnwrap`. The `unwrap` function can be called with or without an input proof.

#### 1) Unwrap request

{% hint style="warning" %}
### **Unsupported `from`**

Accounts with a zero balance that have never held tokens cannot be the `from` address in unwrap requests.
{% endhint %}

**With input proof**

{% hint style="info" %}
### **Input proof**

To unwrap any amount of confidential tokens, the `from` address must first create an encrypted input to generate an `encryptedAmount` (`externalEuint64`) along its `inputProof`. The amount to be encrypted must use the same decimal precision as the confidential wrapper. More information in the [`relayer-sdk` documentation](https://docs.zama.org/protocol/relayer-sdk-guides/fhevm-relayer/input).
{% endhint %}

```solidity
wrapper.unwrap(from, to, encryptedAmount, inputProof);
```

Alternatively, an unwrap request can be made without an input proof if the encrypted amount (`euint64`) is known to `from`. For example, this can be the confidential balance of `from`.

This requests an unwrap request of `encryptedAmount` confidential tokens from `from`. Considerations:

* `msg.sender` must be `from` or an approved operator for `from`.
* `from` must not be the zero address.
* `encryptedAmount` will be burned in the request.
* **NO** transfer of underlying tokens is made in this request.

It emits an `UnwrapRequested` event:

```solidity
event UnwrapRequested(address indexed receiver, bytes32 indexed unwrapRequestId, euint64 amount);
```

**Without input proof**

Alternatively, an unwrap request can be made without an input proof if the encrypted amount (`euint64`) is known to `from`. For example, this can be the confidential balance of `from`.

```solidity
wrapper.unwrap(from, to, encryptedAmount);
```

On top of the above unwrap request considerations:

* `msg.sender` must be approved by ACL for the given `encryptedAmount` ⚠️ (see [ACL documentation](https://docs.zama.org/protocol/protocol/overview/library#access-control)).

#### 2) Finalize unwrap

{% hint style="info" %}
### **Public decryption**

The encrypted burned amount `burntAmount` emitted by the `UnwrapRequested` event must be publicly decrypted to get the `cleartextAmount` along its `decryptionProof`. More information in the [`relayer-sdk` documentation](https://docs.zama.org/protocol/relayer-sdk-guides/fhevm-relayer/decryption/public-decryption).
{% endhint %}

```solidity
wrapper.finalizeUnwrap(burntAmount, cleartextAmount, decryptionProof);
```

This finalizes the unwrap request by sending the corresponding amount of underlying tokens to the `to` defined in the `unwrap` request.

It emits an `UnwrapFinalized` event:

```solidity
event UnwrapFinalized(
    address indexed receiver,
    bytes32 indexed unwrapRequestId,
    euint64 encryptedAmount,
    uint64 cleartextAmount
);
```

### Transfer confidential tokens

{% hint style="info" %}
### **Transfer with input proof**

Similarly to the unwrap process, transfers can be made with or without an input proof and the encrypted amount must be approved by the ACL for the `msg.sender`.
{% endhint %}

{% hint style="warning" %}
### **Unsupported `from`**

Accounts with a zero balance that have never held tokens cannot be the `from` address in confidential transfers.
{% endhint %}

#### Direct transfer

```solidity
wrapper.confidentialTransfer(to, encryptedAmount, inputProof);

wrapper.confidentialTransfer(to, encryptedAmount);
```

#### Operator-based transfer

```solidity
wrapper.confidentialTransferFrom(from, to, encryptedAmount, inputProof);

wrapper.confidentialTransferFrom(from, to, encryptedAmount);
```

Considerations:

* `msg.sender` must be `from` or an approved operator for `from`.

#### Transfer with callback

The callback can be used along an ERC-7984 receiver contract.

```solidity
wrapper.confidentialTransferAndCall(to, encryptedAmount, inputProof, callbackData);

wrapper.confidentialTransferAndCall(to, encryptedAmount, callbackData);
```

#### Operator-based transfer with callback

The callback can be used along an ERC-7984 receiver contract.

```solidity
wrapper.confidentialTransferFromAndCall(from, to, encryptedAmount, inputProof, callbackData);

wrapper.confidentialTransferFromAndCall(from, to, encryptedAmount, callbackData);
```

Considerations:

* `msg.sender` must be `from` or an approved operator for `from`.

### Check the conversion rate and decimals

```solidity
uint256 conversionRate = wrapper.rate();
uint8 wrapperDecimals = wrapper.decimals();
```

**Examples:**

| Underlying Decimals | Wrapper Decimals | Rate  | Effect                       |
| ------------------- | ---------------- | ----- | ---------------------------- |
| 18                  | 6                | 10^12 | 1 wrapped = 10^12 underlying |
| 6                   | 6                | 1     | 1:1 mapping                  |
| 2                   | 2                | 1     | 1:1 mapping                  |

### Check supplies

#### Non-confidential total supply

The wrapper exposes a non-confidential view of the total supply, computed from the underlying ERC20 balance held by the wrapper contract. This value may be higher than `confidentialTotalSupply()` if tokens are sent directly to the wrapper outside of the wrapping process.

{% hint style="info" %}
### **Total Value Shielded (TVS)**

This view function is useful for getting a good approximation of the wrapper's Total Value Shielded (TVS).
{% endhint %}

```solidity
uint256 nonConfidentialSupply = wrapper.inferredTotalSupply();
```

#### Encrypted (confidential) total supply

The actual supply tracked by the confidential token contract, represented as an encrypted value. To determine the cleartext value, you need to request decryption and appropriate ACL authorization.

```solidity
euint64 encryptedSupply = wrapper.confidentialTotalSupply();
```

#### Maximum total supply

The maximum number of wrapped tokens supported by the encrypted datatype (uint64 limit). If this maximum is exceeded, wrapping new tokens will revert.

```solidity
uint256 maxSupply = wrapper.maxTotalSupply();
```

## Integration patterns

### Operator system

Delegate transfer capabilities with time-based expiration:

```solidity
// Grant operator permission until a specific timestamp
wrapper.setOperator(operatorAddress, validUntilTimestamp);

// Check if an address is an authorized operator
bool isAuthorized = wrapper.isOperator(holder, spender);
```

### Query ongoing unwrap request details

```solidity
// Get the encrypted amount associated with an ongoing unwrap request
euint64 encryptedAmount = wrapper.unwrapAmount(unwrapRequestId);

// Get the receiver address of an ongoing unwrap request 
// Returns address(0) if the ID is not associated with an ongoing request
address receiver = wrapper.unwrapRequester(unwrapRequestId);
```

### Amount disclosure

Optionally reveal encrypted amounts publicly:

```solidity
// Request disclosure (initiates async decryption)
wrapper.requestDiscloseEncryptedAmount(encryptedAmount);

// Complete disclosure with proof
wrapper.discloseEncryptedAmount(encryptedAmount, cleartextAmount, decryptionProof);
```

### Check ACL permissions

Before using encrypted amounts in transactions, callers must be authorized:

```solidity
require(FHE.isAllowed(encryptedAmount, msg.sender), "Unauthorized");
```

Transfer functions with `euint64` (not `externalEuint64`) require the caller to already have ACL permission for that ciphertext. More information in the [FHEVM library documentation](https://docs.zama.org/protocol/protocol/overview/library#access-control).

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     ConfidentialWrapper                         │
│  (UUPS Upgradeable, Ownable2Step)                              │
├─────────────────────────────────────────────────────────────────┤
│                 ERC7984ERC20WrapperUpgradeable                  │
│  (Wrapping/Unwrapping Logic, ERC1363 Receiver)                 │
├─────────────────────────────────────────────────────────────────┤
│                    ERC7984Upgradeable                           │
│  (Confidential Token Standard - Encrypted Balances/Transfers)  │
├─────────────────────────────────────────────────────────────────┤
│               ZamaEthereumConfigUpgradeable                     │
│  (FHE Coprocessor Configuration)                               │
└─────────────────────────────────────────────────────────────────┘
```

## Events

| Event                                                                          | Description                                     |
| ------------------------------------------------------------------------------ | ----------------------------------------------- |
| `ConfidentialTransfer(from, to, encryptedAmount)`                              | Emitted on every transfer (including mint/burn) |
| `OperatorSet(holder, operator, until)`                                         | Emitted when operator permissions change        |
| `UnwrapRequested(receiver, unwrapRequestId, encryptedAmount)`                  | Emitted when unwrap is initiated                |
| `UnwrapFinalized(receiver, unwrapRequestId, encryptedAmount, cleartextAmount)` | Emitted when unwrap completes                   |
| `AmountDiscloseRequested(encryptedAmount, requester)`                          | Emitted when disclosure is requested            |
| `AmountDisclosed(encryptedAmount, cleartextAmount)`                            | Emitted when amount is publicly disclosed       |

## Errors

| Error                                                   | Cause                                      |
| ------------------------------------------------------- | ------------------------------------------ |
| `ERC7984InvalidReceiver(receiver)`                      | Transfer to zero address                   |
| `ERC7984InvalidSender(sender)`                          | Transfer from zero address                 |
| `ERC7984UnauthorizedSpender(holder, spender)`           | Caller not authorized as operator          |
| `ERC7984ZeroBalance(holder)`                            | Sender has never held tokens               |
| `ERC7984UnauthorizedUseOfEncryptedAmount(amount, user)` | Caller lacks ACL permission for ciphertext |
| `ERC7984UnauthorizedCaller(caller)`                     | Invalid caller for operation               |
| `InvalidUnwrapRequest(amount)`                          | Finalizing non-existent unwrap request     |
| `ERC7984TotalSupplyOverflow()`                          | Minting would exceed uint64 max            |

## Important Considerations

### Ciphertext uniqueness assumption

The unwrap mechanism stores requests in a mapping keyed by ciphertext and the current implementation assumes these ciphertexts are unique. This holds in this very specific case but be aware of this architectural decision as it is **NOT** true in the general case.

### Maximum number of decimals

The maximum number of decimals `_maxDecimals()` for the confidential token is currently set to **6 decimals** only. This is due to FHE limitations as confidential balances must be represented by the euint64 encrypted datatype.

It is possible that future implementations of the wrapper set a higher `_maxDecimals()` value to better suit the needs of the underlying token. For example, cWBTC might require 8 decimals since using only 6 would make the smallest unit impractically expensive.

At deployment, the confidential wrapper sets its number of decimals as:

* the number of decimals of the underlying token if it is less than `_maxDecimals()`
* `_maxDecimals()` otherwise

**Example with `_maxDecimals()` set to 6**

| Underlying Decimals | Wrapper Decimals | Example    |
| ------------------- | ---------------- | ---------- |
| 18                  | 6                | ZAMA/cZAMA |
| 6                   | 6                | USDT/cUSDT |
| 2                   | 2                | GUSD/cGUSD |

Once a confidential wrapper contract is deployed, this number cannot be updated. It can be viewed with the following view function:

```solidity
wrapper.decimals();
```

### Maximum total supply

The maximum total supply for the confidential token is currently set to `type(uint64).max` (`2^64 - 1`) due to FHE limitations.

### Non-standard token types

The wrapper assumes the full transfer amount is received when minting. Tokens that deviate from this assumption, or whose supply changes independently of wrap/unwrap operations, are not supported and may result in undercollateralization or loss of yield.

| Type | Behavior | Example | Wrapper impact |
| --- | --- | --- | --- |
| **Fee-on-transfer** | A fee is deducted from the transferred amount | SafeMoon, PAXG | The wrapper mints more shares than the underlying balance it receives, leading to undercollateralization |
| **Deflationary** | Token supply decreases over time via burns on transfer or scheduled reductions | BOMB | Equivalent to fee-on-transfer; the same undercollateralization risk applies |
| **Inflationary** | New tokens are minted over time to addresses other than existing holders | Governance tokens with scheduled emissions | **Supported**: The wrapper is not directly impacted, but holders of the confidential token are subject to the same dilution as holders of the underlying token |
| **Rebasing (up)** | Holder balances increase automatically over time to distribute yield | aUSDC, stETH | Yield accrues to the wrapper contract rather than to individual holders; wrapped positions do not earn rewards |
| **Rebasing (down)** | Holder balances decrease automatically, for example due to slashing | stETH (slashing) | The wrapper holds fewer underlying tokens than shares outstanding, resulting in undercollateralization |
| **Pausable** | A privileged account can suspend all token transfers | USDC, USDT | Wrap and unwrap operations revert for the duration of the pause |
| **Blocklist/allowlist** | A privileged account can restrict transfers to or from specific addresses | USDC, USDT | The wrapper contract address may be blocked, preventing all wrap and unwrap operations |
| **Upgradeable** | The token implementation can be replaced after deployment | USDC (proxy) | A logic upgrade may alter token behavior in ways that are incompatible with the wrapper |
| **Multiple entry points** | Two contract addresses share the same underlying balance | Old Synthetix SNX/ProxyERC20 | The same underlying balance can be wrapped twice, inflating the confidential supply |
| **Flash-mintable** | Tokens can be minted without collateral within a single transaction | DAI (flash mint) | Transient supply spikes may interfere with `inferredTotalSupply()` based checks |
| **ERC-777 hooks** | Transfers invoke callbacks on the sender and receiver | imBTC | Callbacks introduce reentrancy vectors during wrap and unwrap operations |
| **Non-standard decimals** | The token uses fewer than 18 decimals | USDC (6), WBTC (8), GUSD (2) | **Supported**: The wrapper normalizes precision automatically via `rate()` -- See the section on [decimal conversion](#check-the-conversion-rate-and-decimals) | 

## Interface Support (ERC-165)

```solidity
wrapper.supportsInterface(type(IERC7984).interfaceId);
wrapper.supportsInterface(type(IERC7984ERC20Wrapper).interfaceId);
wrapper.supportsInterface(type(IERC165).interfaceId);
```

## Upgradeability

The contract uses **UUPS (Universal Upgradeable Proxy Standard)** with 2-step ownership transfer. Only the owner can upgrade the contract. Initially, the owner is set to a DAO [governance](governance.md) contract handled by Zama. Ownership will then be transferred to the underlying token's owner.
