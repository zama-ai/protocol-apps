# Native confidential token

This document gives high-level **guidelines** for designing a *native confidential token*: a token contract that directly implements the [ERC-7984](https://eips.ethereum.org/EIPS/eip-7984) confidential token standard, managing its own encrypted supply rather than wrapping an existing ERC-20.

It is intentionally scoped to design considerations only. The code snippets below are illustrative sketches meant to make the guidelines concrete — they are not production-ready, and this document does not cover deployment or tooling.

## Terminology

* **Native confidential token**: A token contract that directly implements the ERC-7984 confidential token standard.
* **ERC-7984**: A confidential fungible token standard where balances and transfer amounts are encrypted.
* **Owner**: The privileged account that administers the token (for example, mint authority or upgrade authority).
* **Operator**: An address authorized to transfer confidential tokens on behalf of a holder for a limited period of time.
* **ACL**: The Access Control List (ACL) contract used by the FHEVM to manage who is allowed to use a ciphertext. More information in the [ACL guide](https://docs.zama.org/protocol/solidity-guides/smart-contract/acl).
* **Input proof**: A proof that an encrypted input is valid. More information in the [Zama SDK documentation](https://docs.zama.org/protocol/sdk/guides/encrypt-decrypt).

## Guidelines

### Precision and supply bounds

ERC-7984 stores confidential amounts as `euint64`. This means the confidential supply is bounded by `type(uint64).max`, and the token's decimals must be chosen with that bound in mind. Pick a decimals value (for example, `6`) that leaves enough headroom for the intended maximum supply.

### Token shape

A native confidential token composes the ERC-7984 base with the FHEVM config and your chosen access-control model. The skeleton below shows the shape — an owner-gated `mint`, a holder-driven `burn`, and encrypted amounts passed in as external ciphertexts with an input proof:

```solidity
// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {FHE, externalEuint64, euint64} from "@fhevm/solidity/lib/FHE.sol";

contract NativeConfidentialToken is ERC7984, ZamaEthereumConfig, Ownable2Step {
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
}
```

### Choosing a minting strategy

Decide up front how the initial supply is issued. Common options:

* **Zero initial supply, then mint later** — simplest option; confidential issuance is controlled by the owner after the token exists. Best when you want the simplest setup and owner-controlled issuance over time. No genesis logic is needed: rely on the owner-gated `mint` shown above.
* **Public initial allocations** — recipients and amounts are set at genesis in cleartext. Best when the initial distribution does not need to be confidential. Amounts are encrypted on the way in with `FHE.asEuint64`:

  ```solidity
  for (uint256 i = 0; i < initialHolders.length; i++) {
      _mint(initialHolders[i], FHE.asEuint64(initialAmounts[i]));
  }
  ```

* **Confidential genesis allocations** — initial recipients and/or amounts are encrypted from the start. Best when confidentiality must hold from day one, but it requires extra choreography (encrypted inputs and proofs supplied at initialization rather than as plain `uint64` values).

### Confidential transfers

Balances and transfer amounts are encrypted, so transfers move ciphertexts rather than cleartext values. As with ERC-7984 in general, a transfer takes the amount either as an external ciphertext plus an input proof, or as an `euint64` handle the caller already has ACL permission for.

A holder transfers their own tokens directly:

```solidity
// With an input proof (fresh external ciphertext)...
token.confidentialTransfer(to, encryptedAmount, inputProof);
// ...or with an already-permitted handle.
token.confidentialTransfer(to, encryptedAmountHandle);
```

An approved [operator](#operator-approvals) transfers on a holder's behalf with `confidentialTransferFrom`. To move tokens into a contract that needs to react to the transfer, prefer the callback variant so delivery and notification happen in one transaction, without a standing operator allowance:

```solidity
// Operator-driven transfer.
token.confidentialTransferFrom(from, to, encryptedAmount, inputProof);
// Transfer into a receiver contract, notifying it in the same transaction.
token.confidentialTransferAndCall(to, encryptedAmount, inputProof, callbackData);
```

### ACL permissions

Encrypted balances and amounts are ciphertexts governed by the ACL. When designing flows, make sure the caller and the contract have the necessary ACL permissions for any ciphertext that will be reused, and that encrypted inputs are generated for the correct token contract address. Missing permissions are the most common source of failures when working with confidential values.

```solidity
// Bring an external ciphertext in-contract, then grant the reuse permissions it needs.
euint64 amount = FHE.fromExternal(encryptedAmount, inputProof);
FHE.allowThis(amount);        // allow this contract to reuse the ciphertext
FHE.allow(amount, msg.sender); // allow the caller to decrypt it
```

### Operator approvals

Operators can move confidential tokens on behalf of a holder for a limited time. To limit exposure:

* Keep operator approvals short-lived.
* Prefer dedicated operational accounts rather than broad, shared wallets.
* Revoke or replace approvals when workflows change.

```solidity
// Authorize an operator until a timestamp, then transfer on the holder's behalf.
token.setOperator(operator, validUntilTimestamp);
bool authorized = token.isOperator(holder, operator);
token.confidentialTransferFrom(from, to, encryptedAmount, inputProof);
```

### Access control and administration

Guard privileged actions (minting, and any administrative logic) behind clear ownership. Keep the set of privileged actions small and explicit, and document who holds each authority.

### Upgradeability

First decide whether the token needs to be upgradeable at all. An immutable token gives holders the strongest guarantee that its rules cannot change (the ZAMA ERC20, for instance, is deliberately **not** upgradeable), while an upgradeable token trades some of that guarantee for the ability to fix bugs or evolve behavior.

If you do make it upgradeable, follow the same pattern as the confidential wrapper: **UUPS (Universal Upgradeable Proxy Standard)** with 2-step ownership transfer, where only the owner can authorize an upgrade. Swap each base for its `Upgradeable` counterpart — [`ERC7984Upgradeable`](https://github.com/zama-ai/protocol-apps/blob/main/contracts/confidential-wrapper/contracts/token/ERC7984Upgradeable.sol) and [`ZamaEthereumConfigUpgradeable`](https://github.com/zama-ai/protocol-apps/blob/main/contracts/confidential-wrapper/contracts/fhevm/ZamaEthereumConfigUpgradeable.sol) — disable initializers in the constructor, and initialize through an `initialize` function rather than the constructor.

The FHEVM config base is not optional: it points the contract at the coprocessor for the target chain (`FHE.setCoprocessor(...)`), and without it encrypted operations have no backend to run against. In an upgradeable contract it must be initialized like any other base (`__ZamaEthereumConfig_init()`) rather than set in the constructor:

```solidity
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

    function initialize(string memory name_, string memory symbol_, address owner_) public initializer {
        __ERC7984_init(name_, symbol_, "");
        __ZamaEthereumConfig_init();
        __Ownable_init(owner_);
        __Ownable2Step_init();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
```

Whoever holds ownership controls upgrades, so treat the upgrade authority as the token's most sensitive privilege — prefer a governance or multisig owner over an EOA.

## Further reading

* [ERC-7984](https://eips.ethereum.org/EIPS/eip-7984)
* [`ERC7984Upgradeable.sol`](https://github.com/zama-ai/protocol-apps/blob/main/contracts/confidential-wrapper/contracts/token/ERC7984Upgradeable.sol) — upgradeable ERC-7984 base used by the confidential wrapper
* [`ZamaEthereumConfigUpgradeable.sol`](https://github.com/zama-ai/protocol-apps/blob/main/contracts/confidential-wrapper/contracts/fhevm/ZamaEthereumConfigUpgradeable.sol) — wires the contract to the FHEVM coprocessor
* [Zama ACL guide](https://docs.zama.org/protocol/solidity-guides/smart-contract/acl)
* [Zama SDK — encrypt & decrypt](https://docs.zama.org/protocol/sdk/guides/encrypt-decrypt)
* [OpenZeppelin — Access Control](https://docs.openzeppelin.com/contracts/5.x/access-control)
* [OpenZeppelin — Writing upgradeable contracts](https://docs.openzeppelin.com/upgrades-plugins/writing-upgradeable)
