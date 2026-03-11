# Confidential transfers with multisig accounts

This guide explains how to perform confidential token operations using a multisig wallet (e.g., Gnosis Safe). It covers two main use cases:

1. **Reading the balance** of a multisig account
2. **Executing a confidential transfer** from a multisig account

## Prerequisites

- A deployed multisig wallet (e.g., Gnosis Safe): for simplicity, we assume all owners are EOAs (Externally Owned Accounts)
- Access to the `fhevm-cli` tooling
- At least one EOA owner of the multisig account

### Key addresses

| Component | Address | Description |
|-----------|---------|-------------|
| Owner address `i` | `<OWNER_ADDRESS_i>` | The EOA address of the multisig's owner `i` |
| Multisig Wallet | `<MULTISIG_ADDRESS>` | Your Gnosis Safe or similar multisig |
| Confidential Token | `<CONFIDENTIAL_TOKEN_ADDRESS>` | The confidential token (e.g a confidential wrapper) contract holding balances |

---

## Reading the balance of a multisig account

To read the encrypted balance of a multisig wallet, the multisig owners must first grant ACL permissions from the multisig account to their EOAs.

### Step 1: Get the balance handle

Retrieve the encrypted balance handle `<BALANCE_HANDLE>` of the multisig from the confidential token contract using `confidentialBalanceOf(<MULTISIG_ADDRESS>)` function.

### Step 2: Grant ACL permissions to owners

The proposer creates a proposal containing `ACL.allow(<BALANCE_HANDLE>, <OWNER_ADDRESS_i>)` calls for each owner `i`.

### Step 3: Approve and execute the proposal

The required number of owners approve and execute the proposal through the multisig.

### Step 4: Decrypt the balance

Once permissions are granted, any owner can decrypt the balance using the `fhevm-cli`:

```bash
npx hardhat task:userDecrypt \
  --handle <BALANCE_HANDLE> \
  --contract-address <CONFIDENTIAL_TOKEN_ADDRESS> \
  --encrypted-type euint64 \
  --network mainnet
```

---

## Executing a confidential transfer from a multisig

Currently there are two ways to do a confidential transfer. Better and more practical methods will become available in the future, once fhEVM will support new features (such as delegation, simple ACL and EIP-1271, etc).

1/ **Confidential transfer with helper contract**: multi-step method leveraging the [`FHEVMMultiSigHelper.sol`](../contracts/fhevm-cli/contracts/FHEVMMultiSigHelper.sol) contract to properly handle newly encrypted inputs and ACL permissions. This requires several transactions but is more flexible than the second method, and could be used to send only part of the multisig confidential balance.

2/ **Leaky transfer of whole balance**: this is a quick and dirty workaround, where the owners would transfer the current confidential balance handle of the multisig in a single transaction. This method would leak the fact that the multisig is sending its whole balance to the receiver. It could even be done blindly to save time and gas (not recommended), if the owners skip the steps from [previous section](#reading-the-balance-of-a-multisig-account).

### Method 1: Confidential transfer with helper contract (recommended)

#### Overview

```
┌──────────────────────────────────────────────────────────────────────────┐
│  1. Encrypt transfer amount                                              │
│  2. Call allowForSafeMultiSig()/allowForCustomMultiSigOwners() on helper │
│  3. Allow handle to confidential token via ACL                           │
│  4. Create confidentialTransfer proposal (without inputProof)            │
│  5. Owners decrypt handle to verify amount                               │
│  6. Approve and execute transfer                                         │
└──────────────────────────────────────────────────────────────────────────┘
```

#### Step 1: Encrypt the transfer amount

The proposer (can be any of the `<OWNER_ADDRESS_i>`) encrypts the amount `<AMOUNT>` to transfer. The encryption is tied to:
- **User address**: The proposer's EOA (must be a multisig owner)
- **Contract address**: The `FHEVMMultiSigHelper` contract, which has already been deployed: at address [`0x26C5BBC241577b9a5D5A51AA961CC68103939836`](https://etherscan.io/address/0x26C5BBC241577b9a5D5A51AA961CC68103939836) on **Ethereum mainnet** and at address [`0x3048Fb62cBeD3335e7B4E26461EB2fB63c5F320E`](https://sepolia.etherscan.io/address/0x3048Fb62cBeD3335e7B4E26461EB2fB63c5F320E) on **Ethereum Sepolia testnet**.

```bash
npx hardhat task:encryptInput \
  --input-value <AMOUNT> \
  --user-address <OWNER_ADDRESS_i> \
  --contract-address <FHEVM_MULTISIG_HELPER_ADDRESS> \
  --encrypted-type euint64 \
  --network mainnet
```

**Note:** Make sure that the `<AMOUNT>` value is less or equal tha the current balance of the multisig (otherwise the confidential transfer transaction would succeed but the sent amount will be `0`), and for `<FHEVM_MULTISIG_HELPER_ADDRESS>` value you should use `0x26C5BBC241577b9a5D5A51AA961CC68103939836` on Ethereum mainnet, or `0x3048Fb62cBeD3335e7B4E26461EB2fB63c5F320E` on Ethereum Sepolia testnet.

{% hint style="warning" %}
**Input amount decimal precision** 

The input amount must be a value using the decimal precision as the confidential token. For example, if the confidential token has 6 decimals, the `--input-value` must be a value using 6 decimals.
{% endhint %}

This outputs:
- `handle`: The encrypted amount input handle `<ENCRYPTED_HANDLE>`, which will need to be verified
- `proof`: The input proof `<INPUT_PROOF>`, which will be used to verify the handle

#### Step 2: Allow the handle for the multisig and owners

##### Step 2.1: If your multisig is a **Safe account**:

Call `allowForSafeMultiSig()` on the helper contract. This function:
- Verifies the encrypted input handle
- Automatically fetches all owners of the Safe multisig
- Grants ACL permissions to the multisig and all its owners

This is done via this command:

```bash
npx hardhat task:allowForSafeMultiSig \
  --safe <MULTISIG_ADDRESS> \
  --handle <ENCRYPTED_HANDLE> \
  --proof <INPUT_PROOF> \
  --network mainnet
```

Here `<MULTISIG_ADDRESS>` should be the address of the Safe account, while `<ENCRYPTED_HANDLE>` and `<INPUT_PROOF>` should be the values outputted in [Step 1](#step-1-encrypt-the-transfer-amount).

##### Step 2.2 (Alternative to Step 2.1): If your multisig is *NOT* a **Safe account**:

In this specific case, for e.g when using an Aragon multisig plugin, there is no on-chain method to fetch the owners of the multisig contract. Owners should be inputted manually when calling the `allowForCustomMultiSigOwners()` function of the helper contract. This function:

- Verifies the encrypted input handle
- Grants ACL permissions to the multisig and all its owners - here we trust the proposer inputted the correct owners, this could be checked by anyone by reading the corresponding transaction calldata in a block explorer

This is done via this command:

```bash
npx hardhat task:allowForCustomMultiSigOwners \
  --multisig <MULTISIG_ADDRESS> \
  --owners <OWNER_ADDRESS_0>,<OWNER_ADDRESS_1>,...,<OWNER_ADDRESS_N> \
  --handle <ENCRYPTED_HANDLE> \
  --proof <INPUT_PROOF> \
  --network mainnet
```

Here `<MULTISIG_ADDRESS>` should be the address of the multisig account, the `<OWNER_ADDRESS_i>` are the addresses of the owners of the multisig, while `<ENCRYPTED_HANDLE>` and `<INPUT_PROOF>` should be the values outputted in [Step 1](#step-1-encrypt-the-transfer-amount).

#### Step 3: Allow the handle to the confidential token contract via ACL

The proposer must also allow the handle to the confidential token (or wrapper) contract through the ACL:

```bash
npx hardhat task:allowHandle \
  --handle <ENCRYPTED_HANDLE> \
  --account <CONFIDENTIAL_TOKEN_ADDRESS> \
  --network mainnet
```

#### Step 4: Create the confidential transfer proposal

The proposer creates a `confidentialTransfer(<TO_ADDRESS>, <ENCRYPTED_HANDLE>)` proposal in the multisig.

{% hint style="info" %}
**Important:** Since the `FHEVMMultiSigHelper` has already validated the handle, either:
- use the transfer function **without** `inputProof` parameter,  
- use the transfer function **with** `inputProof` parameter set to `0x`
{% endhint %}

#### Step 5: Verify the transfer amount

Any multisig owner can decrypt the handle to verify the transfer amount from the proposal before approving it:

```bash
npx hardhat task:userDecrypt \
  --handle <ENCRYPTED_HANDLE> \
  --contract-address <CONFIDENTIAL_TOKEN_ADDRESS> \
  --encrypted-type euint64 \
  --network mainnet
```

#### Step 6: Approve and execute the transfer

The required number of owners approve the proposal, and any owner can then execute the transfer.

### Method 2: Leaky transfer of whole balance (fast but not recommended)

This method is straightforward: 

#### Step 1: Retrieve the encrypted balance of the multisig

Retrieve the encrypted balance handle `<BALANCE_HANDLE>` of the multisig from the confidential token contract using `confidentialBalanceOf(<MULTISIG_ADDRESS>)` function.

#### Step 2: Retrieve the encrypted balance of the multisig

The proposer creates a `confidentialTransfer(<TO_ADDRESS>, <BALANCE_HANDLE>)` proposal in the multisig.

#### Step 3: Approve and execute the proposal

The required number of owners approve and execute the proposal through the multisig.

---

#### Related documentation

- [Confidential Wrapper](confidential-wrapper.md) - Full documentation on the confidential token wrapper
- [ACL Documentation](https://docs.zama.org/protocol/protocol/overview/library#access-control) - Access Control List for encrypted handles
- [Relayer SDK - Input](https://docs.zama.org/protocol/relayer-sdk-guides/fhevm-relayer/input) - Creating encrypted inputs
- [Relayer SDK - Decryption](https://docs.zama.org/protocol/relayer-sdk-guides/fhevm-relayer/decryption/public-decryption) - Public decryption process
