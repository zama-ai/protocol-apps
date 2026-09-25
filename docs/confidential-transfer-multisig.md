# Confidential transfers with multisig accounts

This guide explains how to perform confidential token operations using a multisig wallet (e.g., Gnosis Safe, Aragon Multisig plugin, etc). It covers two main use cases:

1. **Reading the balance** of a multisig account
2. **Executing a confidential transfer** from a multisig account

**Note:** Most of the following steps can be easily extended and reused with any smart account interacting with any fhevm-enabled contract (e.g unshielding in confidential wrapper, bidding in blind auction, etc).

## Prerequisites

- A deployed multisig wallet (e.g., Gnosis Safe): for simplicity, we assume all owners are EOAs (Externally Owned Accounts)
- At least one EOA owner of the multisig account
- The `relayer` CLI of [`@zama-fhe/relayer-sdk`](https://www.npmjs.com/package/@zama-fhe/relayer-sdk), to encrypt inputs and decrypt handles, and Foundry's [`cast`](https://getfoundry.sh/cast/overview), to send transactions (see [Tooling](#tooling))

### Key addresses

| Component | Address | Description |
|-----------|---------|-------------|
| Owner address `i` | `<OWNER_ADDRESS_i>` | The EOA address of the multisig's owner `i` |
| Multisig Wallet | `<MULTISIG_ADDRESS>` | Your Gnosis Safe or similar multisig |
| Confidential Token | `<CONFIDENTIAL_TOKEN_ADDRESS>` | The confidential token (e.g a [confidential wrapper](confidential-wrapper.md)) contract holding balances |

### Tooling

Install the `relayer` CLI in an empty directory (`dotenv` and `commander` are imports of the CLI that
the package does not install itself):

```bash
npm install @zama-fhe/relayer-sdk@0.4.4 dotenv commander
```

The CLI reads the network configuration from `.env.<network>` in the working directory. Create the
file for the network you use:

{% tabs %}
{% tab title="Ethereum mainnet (.env.mainnet)" %}
```bash
RPC_URL=<ETHEREUM_RPC_URL>
RELAYER_URL=https://relayer.mainnet.zama.org
ACL_CONTRACT_ADDRESS=0xcA2E8f1F656CD25C01F05d0b243Ab1ecd4a8ffb6
KMS_VERIFIER_CONTRACT_ADDRESS=0x77627828a55156b04Ac0DC0eb30467f1a552BB03
INPUT_VERIFIER_CONTRACT_ADDRESS=0xCe0FC2e05CFff1B719EFF7169f7D80Af770c8EA2
DECRYPTION_ADDRESS=0x0f6024a97684f7d90ddb0fAAD79cB15F2C888D24
INPUT_VERIFICATION_ADDRESS=0xcB1bB072f38bdAF0F328CdEf1Fc6eDa1DF029287
CHAIN_ID=1
CHAIN_ID_GATEWAY=261131
```
{% endtab %}
{% tab title="Ethereum Sepolia testnet (.env.testnet)" %}
```bash
RPC_URL=<SEPOLIA_RPC_URL>
RELAYER_URL=https://relayer.testnet.zama.org
ACL_CONTRACT_ADDRESS=0xf0Ffdc93b7E186bC2f8CB3dAA75D86d1930A433D
KMS_VERIFIER_CONTRACT_ADDRESS=0xbE0E383937d564D7FF0BC3b46c51f0bF8d5C311A
INPUT_VERIFIER_CONTRACT_ADDRESS=0xBBC1fFCdc7C316aAAd72E807D9b0272BE8F84DA0
DECRYPTION_ADDRESS=0x5D8BD78e2ea6bbE41f26dFe9fdaEAa349e077478
INPUT_VERIFICATION_ADDRESS=0x483b9dE06E4E4C7D35CCf5837A1668487406D955
CHAIN_ID=11155111
CHAIN_ID_GATEWAY=10901
```
{% endtab %}
{% endtabs %}

Secrets go in `.env`: `MNEMONIC` (the owner account that user-decrypts, first derived address) and,
on mainnet, `ZAMA_FHEVM_API_KEY` (the relayer rejects mainnet requests without it). The commands below
use `--network mainnet`; use `--network testnet` for Sepolia. Every `relayer` command takes
`--version 2`, the relayer's current route.

For `cast`, `<ETHEREUM_RPC_URL>` is the chain's RPC endpoint and `<OWNER_SIGNER>` whichever
[wallet option](https://getfoundry.sh/cast/reference/send) your owner key uses (e.g.
`--account <keystore-name>` or `--ledger`).

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

Once permissions are granted, any owner can decrypt the balance with the `relayer` CLI, signing the
request with the `MNEMONIC` of `.env`:

```bash
npx relayer user-decrypt --network mainnet --version 2 \
  --handle <BALANCE_HANDLE> \
  --contract-address <CONFIDENTIAL_TOKEN_ADDRESS> \
  --user-address <OWNER_ADDRESS_i>
```

---

## Executing a confidential transfer from a multisig

Currently there are two ways to do a confidential transfer. Better and more practical methods will become available in the future, once fhEVM will support new features (such as user delegated decryption, ACL simplifications, EIP-1271 support, etc).

1/ **Confidential transfer with helper contract**: multi-step method leveraging the [`FHEVMMultiSigHelper`](https://eth.blockscout.com/address/0xd430F46fE522a32b12ce92C719f437fFce35e127?tab=contract) contract to properly handle newly encrypted inputs and ACL permissions. This requires several transactions but is more flexible than the second method, and could be used to send only part of the multisig confidential balance.

2/ **Not recommended: Leaky transfer of whole balance**: this is a quick and dirty workaround, where the owners would transfer the current confidential balance handle of the multisig in a single transaction. This method would leak the fact that the multisig is sending its whole balance to the receiver. It could even be done blindly to save time and gas (not recommended), if the owners skip the steps from [previous section](#reading-the-balance-of-a-multisig-account).

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
- **Contract address**: The `FHEVMMultiSigHelper` contract, which has already been deployed: at address [`0xd430F46fE522a32b12ce92C719f437fFce35e127`](https://eth.blockscout.com/address/0xd430F46fE522a32b12ce92C719f437fFce35e127) on **Ethereum mainnet** and at address [`0xc51693587A5ec99FF131Ccd8aa6Fb424B17f5F61`](https://eth-sepolia.blockscout.com/address/0xc51693587A5ec99FF131Ccd8aa6Fb424B17f5F61) on **Ethereum Sepolia testnet**.

```bash
npx relayer input-proof --network mainnet --version 2 \
  --values <AMOUNT>:euint64 \
  --user-address <OWNER_ADDRESS_i> \
  --contract-address <FHEVM_MULTISIG_HELPER_ADDRESS> \
  --json
```
**Note:** Make sure that the `<AMOUNT>` value is less than or equal to the current balance of the multisig (otherwise the confidential transfer transaction would succeed but the sent amount will be `0`), and for `<FHEVM_MULTISIG_HELPER_ADDRESS>` value you should use: 
- Ethereum mainnet: [0xd430F46fE522a32b12ce92C719f437fFce35e127](https://eth.blockscout.com/address/0xd430F46fE522a32b12ce92C719f437fFce35e127)
- Ethereum Sepolia testnet: [0xc51693587A5ec99FF131Ccd8aa6Fb424B17f5F61](https://eth-sepolia.blockscout.com/address/0xc51693587A5ec99FF131Ccd8aa6Fb424B17f5F61)

{% hint style="warning" %}
**Input amount decimal precision** 

The input amount must be a value using the decimal precision as the confidential token. For example, if the confidential token has 6 decimals, `<AMOUNT>` must be a value using 6 decimals.
{% endhint %}

This outputs:
- `handles[0]`: The encrypted amount input handle `<ENCRYPTED_HANDLE>`, which will need to be verified
- `inputProof`: The input proof `<INPUT_PROOF>`, which will be used to verify the handle

#### Step 2: Allow the handle for the multisig and owners

##### Step 2.1: If your multisig is a **Safe account**:

Call `allowForSafeMultiSig()` on the helper contract. This function:
- Verifies the encrypted input handle
- Automatically fetches all owners of the Safe multisig
- Grants ACL permissions to the multisig and all its owners

This is done via this command:

The transaction must be sent by the `<OWNER_ADDRESS_i>` the input was encrypted for:

```bash
cast send <FHEVM_MULTISIG_HELPER_ADDRESS> \
  "allowForSafeMultiSig(address,bytes32[],bytes)" \
  <MULTISIG_ADDRESS> "[<ENCRYPTED_HANDLE>]" <INPUT_PROOF> \
  --rpc-url <ETHEREUM_RPC_URL> <OWNER_SIGNER>
```

Here `<MULTISIG_ADDRESS>` should be the address of the Safe account, while `<ENCRYPTED_HANDLE>` and `<INPUT_PROOF>` should be the values outputted in [Step 1](#step-1-encrypt-the-transfer-amount).

##### Step 2.2 (Alternative to Step 2.1): If your multisig is *NOT* a **Safe account**:

In this specific case, for e.g when using an Aragon multisig plugin, there is no on-chain method to fetch the owners of the multisig contract. Owners should be inputted manually when calling the `allowForCustomMultiSigOwners()` function of the helper contract. This function:

- Verifies the encrypted input handle
- Grants ACL permissions to the multisig and all its owners - here we trust the proposer inputted the correct owners, this could be checked by anyone by reading the corresponding transaction calldata in a block explorer

This is done via this command:

The transaction must be sent by the `<OWNER_ADDRESS_i>` the input was encrypted for:

```bash
cast send <FHEVM_MULTISIG_HELPER_ADDRESS> \
  "allowForCustomMultiSigOwners(address,address[],bytes32[],bytes)" \
  <MULTISIG_ADDRESS> "[<OWNER_ADDRESS_0>,<OWNER_ADDRESS_1>,...,<OWNER_ADDRESS_N>]" \
  "[<ENCRYPTED_HANDLE>]" <INPUT_PROOF> \
  --rpc-url <ETHEREUM_RPC_URL> <OWNER_SIGNER>
```

Here `<MULTISIG_ADDRESS>` should be the address of the multisig account, the `<OWNER_ADDRESS_i>` are the addresses of the owners of the multisig, while `<ENCRYPTED_HANDLE>` and `<INPUT_PROOF>` should be the values outputted in [Step 1](#step-1-encrypt-the-transfer-amount).

#### Step 3: Allow the handle to the confidential token contract via ACL

The proposer must also allow the handle to the confidential token (or wrapper) contract through the
ACL (`0xcA2E8f1F656CD25C01F05d0b243Ab1ecd4a8ffb6` on Ethereum mainnet,
`0xf0Ffdc93b7E186bC2f8CB3dAA75D86d1930A433D` on Sepolia):

```bash
cast send <ACL_ADDRESS> "allow(bytes32,address)" \
  <ENCRYPTED_HANDLE> <CONFIDENTIAL_TOKEN_ADDRESS> \
  --rpc-url <ETHEREUM_RPC_URL> <OWNER_SIGNER>
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
npx relayer user-decrypt --network mainnet --version 2 \
  --handle <ENCRYPTED_HANDLE> \
  --contract-address <CONFIDENTIAL_TOKEN_ADDRESS> \
  --user-address <OWNER_ADDRESS_i>
```

#### Step 6: Approve and execute the transfer

The required number of owners approve the proposal, and any owner can then execute the transfer.

### Method 2: Leaky transfer of whole balance (fast but not recommended)

This method is straightforward: 

#### Step 1: Retrieve the encrypted balance of the multisig

Retrieve the encrypted balance handle `<BALANCE_HANDLE>` of the multisig from the confidential token contract using `confidentialBalanceOf(<MULTISIG_ADDRESS>)` function.

#### Step 2: Create a transfer proposal

The proposer creates a `confidentialTransfer(<TO_ADDRESS>, <BALANCE_HANDLE>)` proposal in the multisig.

#### Step 3: Approve and execute the proposal

The required number of owners approve and execute the proposal through the multisig.

---

#### Related documentation

- [Confidential Wrapper](confidential-wrapper.md) - Full documentation on the confidential token wrapper
- [ACL Documentation](https://docs.zama.org/protocol/protocol/overview/library#access-control) - Access Control List for encrypted handles
- [Zama SDK](https://docs.zama.org/protocol/sdk/guides/encrypt-decrypt) - Encrypt & decrypt
