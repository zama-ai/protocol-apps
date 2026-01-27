# Confidential transfers with multisig accounts

This guide explains how to perform confidential token operations using a multisig wallet (e.g., Gnosis Safe). It covers two main use cases:

1. **Reading the balance** of a multisig account
2. **Executing a confidential transfer** from a multisig account

## Prerequisites

- A deployed multisig wallet (e.g., Gnosis Safe)
- Access to the `fhevm-cli` tooling
- At least one EOA (Externally Owned Account) owner of the multisig account

### Key addresses

| Component | Address | Description |
|-----------|---------|-------------|
| Owner address `i` | `<OWNER_ADDRESS_i>` | The EOA address of the multisig's owner `i` |
| Multisig Wallet | `<MULTISIG_ADDRESS>` | Your Gnosis Safe or similar multisig |
| Confidential Wrapper | `<WRAPPER_ADDRESS>` | The cWrapper contract holding balances |

---

## Reading the balance of a multisig account

To read the encrypted balance of a multisig wallet, the multisig owners must first grant ACL permissions from the multisig account to their EOAs.

### Step 1: Get the balance handle

Retrieve the encrypted balance handle `<BALANCE_HANDLE>` of the multisig from the confidential wrapper contract using `confidentialBalanceOf(<MULTISIG_ADDRESS>)` function.

### Step 2: Grant ACL permissions to owners

The proposer creates a proposal containing `ACL.allow(<BALANCE_HANDLE>, <OWNER_ADDRESS_i>)` calls for each owner `i`.

### Step 3: Approve and execute the proposal

The required number of owners approve and execute the proposal through the multisig.

### Step 4: Decrypt the balance

Once permissions are granted, any owner can decrypt the balance using the `fhevm-cli`:

```bash
npx hardhat task:userDecrypt \
  --handle <BALANCE_HANDLE> \
  --contract-address <WRAPPER_ADDRESS> \
  --encrypted-type euint64 \
  --network mainnet
```

---

## Executing a confidential transfer from a multisig

Confidential transfers from a multisig require a helper contract to properly handle encrypted inputs and ACL permissions.

### Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│  1. Deploy MultiSigHelper                                               │
│  2. Encrypt transfer amount                                             │
│  3. Call allowForMultiSig() on helper                                   │
│  4. Allow handle to helper via ACL                                      │
│  5. Create confidentialTransfer proposal (without inputProof)           │
│  6. Owners decrypt handle to verify amount                              │
│  7. Approve and execute transfer                                        │
└─────────────────────────────────────────────────────────────────────────┘
```

### Step 1: Deploy the MultiSigHelper contract

The proposer deploys a `MultiSigHelper` contract, passing the multisig address in the constructor:

```bash
npx hardhat task:deployMultiSigHelper \
  --multisig <MULTISIG_ADDRESS> \
  --network mainnet
```

### Step 2: Verify the helper contract

Verify the deployed contract of address `<HELPER_ADDRESS>` on etherscan:

```bash
npx hardhat task:verifyMultiSigHelper \
  --address <HELPER_ADDRESS> \
  --multisig <MULTISIG_ADDRESS> \
  --network mainnet
```

### Step 3: Encrypt the transfer amount

The proposer (can be any of the `<OWNER_ADDRESS_i>`) encrypts the amount `<AMOUNT>` to transfer. The encryption is tied to:
- **User address**: The proposer's EOA (must be a multisig owner)
- **Contract address**: The `MultiSigHelper` contract

```bash
npx hardhat task:encryptInput \
  --input-value <AMOUNT> \
  --user-address <OWNER_ADDRESS_i> \
  --contract-address <HELPER_ADDRESS> \
  --encrypted-type euint64 \
  --network mainnet
```

{% hint style="warning" %}
**Input amount decimal precision** 

The input amount must be a value using the decimal precision as the confidential wrapper. For example, if the confidential wrapper has 6 decimals, the `--input-value` must be a value using 6 decimals.
{% endhint %}

This outputs:
- `handle`: The encrypted amount input handle `<ENCRYPTED_HANDLE>`, which will need to be verified
- `proof`: The input proof `<INPUT_PROOF>`, which will be used to verify the handle

### Step 4: Allow the handle for the multisig and owners

Call `allowForMultiSig()` on the helper contract. This function:
- Verifies the encrypted input handle
- Grants ACL permissions to the multisig and all its owners

```bash
npx hardhat task:allowForMultiSig \
  --helper <HELPER_ADDRESS> \
  --handle <ENCRYPTED_HANDLE> \
  --proof <INPUT_PROOF> \
  --network mainnet
```

### Step 5: Allow the handle to the helper contract via ACL

The proposer must also allow the handle to the confidential wrapper contract through the ACL:

```bash
npx hardhat task:allowHandle \
  --handle <ENCRYPTED_HANDLE> \
  --account <WRAPPER_ADDRESS> \
  --network mainnet
```

### Step 6: Create the confidential transfer proposal

The proposer creates a `confidentialTransfer(<TO_ADDRESS>, <ENCRYPTED_HANDLE>)` proposal in the multisig.

{% hint style="info" %}
**Important:** Since the `MultiSigHelper` has already validated the handle, either:
- use the transfer function **without** `inputProof` parameter,  
- use the transfer function **with** `inputProof` parameter set to `0x`
{% endhint %}

### Step 7: Verify the transfer amount

Any multisig owner can decrypt the handle to verify the transfer amount from the proposal before approving it:

```bash
npx hardhat task:userDecrypt \
  --handle <ENCRYPTED_HANDLE> \
  --contract-address <WRAPPER_ADDRESS> \
  --encrypted-type euint64 \
  --network mainnet
```

### Step 8: Approve and execute the transfer

The required number of owners approve the proposal, and any owner can then execute the transfer.

---

## Reference

### MultiSigHelper contract

The `MultiSigHelper` contract serves as an intermediary to:
1. Validate encrypted inputs (via `FHE.fromExternal()`)
2. Grant ACL permissions to the multisig and all its owners in a single transaction

```solidity
function allowForMultiSig(externalEuint64 inputHandle, bytes memory inputProof) external {
    euint64 handle = FHE.fromExternal(inputHandle, inputProof);
    FHE.allow(handle, address(multiSig));
    address[] memory owners = getMultiSigOwners();
    for (uint256 i; i < owners.length; i++) {
        FHE.allow(handle, owners[i]);
    }
}
```

### Related documentation

- [Confidential Wrapper](confidential-wrapper.md) - Full documentation on the confidential token wrapper
- [ACL Documentation](https://docs.zama.org/protocol/protocol/overview/library#access-control) - Access Control List for encrypted handles
- [Relayer SDK - Input](https://docs.zama.org/protocol/relayer-sdk-guides/fhevm-relayer/input) - Creating encrypted inputs
- [Relayer SDK - Decryption](https://docs.zama.org/protocol/relayer-sdk-guides/fhevm-relayer/decryption/public-decryption) - Public decryption process
