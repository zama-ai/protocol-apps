# Config Checker

Utilities for checking FHEVM protocol contract configurations.

## Prerequisites

- Node.js (v18+)
- npm

## Installation

```bash
npm install
```

## Configuration

Create a `.env` file based on `.env.example`:

```bash
cp .env.example .env
```

## Available scripts

Currently, most useful scripts are:

```
[*] get-current-pausers
[*] get-token-roles
[*] get-oft-owners
[*] get-multisig-info
```
### getCurrentPausers

#### Usage

```bash
npm run get-current-pausers
```

Returns the current set of active pausers for PauserSet contracts on Ethereum and Gateway chains by analyzing on-chain events.

The script will:
1. Query both Ethereum and Gateway chains (if configured)
2. Find the deployment block for each PauserSet contract
3. Fetch all `AddPauser`, `RemovePauser`, and `SwapPauser` events
4. Compute the current set of active pausers
5. Display a summary comparing pausers across chains

#### Example Output

```
[Ethereum]
  Finding deployment block for 0xbBfE1680b4a63ED05f7F80CE330BED7C992A586C...
  Deployment block: 23832655
  Current block: 23900000
  Fetching pauser events...
    AddPauser: 100% - found 2 events
    RemovePauser: 100% - found 0 events
    SwapPauser: 100% - found 0 events

[Gateway]
  Finding deployment block for 0x571ecb596fCc5c840DA35CbeCA175580db50ac1b...
  Deployment block: 1000000
  Current block: 1050000
  Fetching pauser events...
    AddPauser: 100% - found 2 events
    RemovePauser: 100% - found 0 events
    SwapPauser: 100% - found 0 events

==================================================
SUMMARY
==================================================

Ethereum pausers:
  1. 0x1234...abcd
  2. 0x5678...efgh
  Total: 2 pauser(s)

Gateway pausers:
  1. 0x1234...abcd
  2. 0x5678...efgh
  Total: 2 pauser(s)

--------------------------------------------------
Pausers are IDENTICAL on both chains.
```

If pausers differ between chains, the script will show which addresses exist only on one chain.

### getTokenRoles

#### Usage

```bash
npm run get-token-roles
```

The script will:
1. Use `RPC_ETHEREUM` and `ZAMA_TOKEN_ERC20_ETHEREUM` from your `.env` file.
2. Find the deployment block for the ZamaERC20 token contract on Ethereum.
3. Fetch all `RoleGranted` and `RoleRevoked` events from deployment to the latest block.
4. Compute the current holders of `DEFAULT_ADMIN_ROLE`, `MINTER_ROLE`, and `MINTING_PAUSER_ROLE`.
5. Display a summary of role holders with the event counts per role.

Example Output:

```
[Ethereum]
  Finding deployment block for 0x...
  Deployment block: 23790400
  Current block: 24578326
  Fetching role events...
    RoleGranted: 100% - found 4 events..
    RoleRevoked: 100% - found 0 events..

==================================================
CURRENT ROLE HOLDERS
==================================================

DEFAULT_ADMIN_ROLE:
  1. 0x... 
  Events: 1 granted, 0 revoked
  Total: 1 address(es)

MINTER_ROLE:
  1. 0x...
  2. 0x...
  Events: 2 granted, 0 revoked
  Total: 2 address(es)

MINTING_PAUSER_ROLE:
  1. 0x...
  Events: 1 granted, 0 revoked
  Total: 1 address(es)

--------------------------------------------------
Total RoleGranted events: 4
Total RoleRevoked events: 0
```

### getOftOwners

Reports the current **owner** and **delegate** for all OFT/OFTAdapter contracts across EVM chains and Solana. This is the recommended command to run for a full overview.

```bash
npm run get-oft-owners
```

To run only EVM or Solana individually:

```bash
npm run get-oft-owners-evm
npm run get-oft-owners-solana
```

#### EVM

Checks each configured EVM chain and reports the current **owner** and **LayerZero delegate** for each ZamaOFTAdapter (Ethereum) or ZamaOFT (Gateway, BSC, HyperEVM). Uses on-chain view calls only (`owner()`, `endpoint()`, `delegates(oapp)`).

For each configured chain it will:
1. Read the OFT/OFTAdapter contract to get `owner()` and `endpoint()`.
2. Read the endpoint's `delegates(contractAddress)` to get the current delegate.
3. Print adapter/OFT address, endpoint address, owner, and delegate.

**Environment variables (per chain):**

| Chain            | RPC env       | Contract address env      |
|------------------|---------------|----------------------------|
| Ethereum Adapter | `RPC_ETHEREUM` | `ZAMA_OFT_ADAPTER_ETHEREUM` |
| Gateway OFT      | `RPC_GATEWAY`  | `ZAMA_OFT_GATEWAY`          |
| BSC OFT          | `RPC_BSC`      | `ZAMA_OFT_BSC`              |
| HyperEVM OFT     | `RPC_HYPEREVM` | `ZAMA_OFT_HYPEREVM`         |

Chains missing RPC or contract address are skipped. Example output:

```
=== EVM OFT ===

[Ethereum OFT Adapter]
  Adapter/OFT address : 0x...
  Owner               : 0x...
  Delegate            : 0x...

[Gateway OFT]
  Adapter/OFT address : 0x...
  Owner               : 0x...
  Delegate            : 0x...

...

Owner and Delegate should be IDENTICAL on EVM chains,
and it should be the Zama DAO or a Safe multisig wallet owned by Zama FB_i operators
```

#### Solana

Reads Solana on-chain accounts to report the OFT **admin (owner)**, LayerZero **delegate**, **upgrade authority**. Verifies that admin, delegate, and upgrade authority are all equal.

The script will:
1. Fetch the **Mint** account to get the mint authority (which is the OFTStore address).
2. Fetch the **OFTStore** account to get admin (owner) and endpoint program.
3. Derive the **OAppRegistry** PDA from the endpoint program and fetch the delegate.
4. Derive the **ProgramData** PDA from the OFT program and the BPF Loader to fetch the upgrade authority.
5. Verify that admin, delegate, and upgrade authority are all the same address.
6. Print a summary with results.

**Environment variables:**

| Variable           | Description                     | Example                                          |
|--------------------|---------------------------------|--------------------------------------------------|
| `SOLANA_RPC_URL`   | Solana RPC endpoint             | `https://api.mainnet-beta.solana.com`            |
| `SOLANA_OFT_MINT` | OFT Mint address            | `4Zp52aF4hZi9fzH19xpbWKYKQvgLyCN67KFbrQDqeTKh` |

Example output:

```
=== Solana OFT ===

  OFT Mint            : 4Zp52aF4hZi9fzH19xpbWKYKQvgLyCN67KFbrQDqeTKh
  Admin (Owner)       : G9jXsKZ2XXfNEks2dmouKiJJFBWcn8SQHmMkcy3TUVf5
  OApp Delegate       : G9jXsKZ2XXfNEks2dmouKiJJFBWcn8SQHmMkcy3TUVf5
  Upgrade Authority   : G9jXsKZ2XXfNEks2dmouKiJJFBWcn8SQHmMkcy3TUVf5

Admin, Upgrade Authority, and Delegate should be IDENTICAL on Solana,
and it should be a Squads multisig wallet owned by Zama FB_i operators
```

### getMultisigInfo

Reports owners and thresholds for all deployed multisig wallets (EVM Safes, Aragon DAO plugins, Solana Squads).

#### Usage

```bash
npm run get-multisig-info
```

The script will:
1. Query each configured **Gnosis Safe** (Gateway, BSC, HyperEVM) for `getOwners()` and `getThreshold()`, then cross-check that owners and threshold are identical across all chains.
2. On the **Gateway Safe**, list every enabled module via `getModulesPaginated(SENTINEL, 100)` and verify that the only enabled module is the configured `AdminModule`. The `AdminModule` is also queried for its `ADMIN_ACCOUNT()` and `SAFE_PROXY()`; the latter must match `ZAMA_SAFE_GATEWAY`.
3. Detect active **Aragon DAO plugins** by scanning `Granted`/`Revoked` events for `EXECUTE_PERMISSION` on the DAO, filtering out uninstalled plugins. A sanity check calls `hasPermission()` on-chain to verify the event-derived state.
4. Query the **Solana Squads** multisig account for members and threshold.

**Environment variables:**

| Variable | Description |
|---|---|
| `RPC_GATEWAY` | Gateway RPC endpoint |
| `RPC_BSC` | BSC RPC endpoint |
| `RPC_HYPEREVM` | HyperEVM RPC endpoint |
| `RPC_ETHEREUM` | Ethereum RPC endpoint (for Aragon) |
| `ZAMA_SAFE_GATEWAY` | Safe address on Gateway |
| `ZAMA_SAFE_ADMIN_MODULE_GATEWAY` | AdminModule address enabled on the Gateway Safe |
| `ZAMA_SAFE_BSC` | Safe address on BSC |
| `ZAMA_SAFE_HYPEREVM` | Safe address on HyperEVM |
| `ZAMA_ARAGON_DAO` | Aragon DAO address on Ethereum |
| `SOLANA_RPC_URL` | Solana RPC endpoint |
| `SOLANA_SQUADS_MULTISIG_ACCOUNT` | Squads multisig account PDA** |

> **⚠️ `SOLANA_SQUADS_MULTISIG_ACCOUNT` is NOT the Squads vault ID.**
>
> The address listed as "Squads Multisig" in `docs/addresses/mainnet/solana.md`
> (`G9jXsKZ2...TUVf5`, shown on `app.squads.so` and used everywhere as "the
> multisig") is the vault account: the PDA that holds funds and signs transactions.
>
> `SOLANA_SQUADS_MULTISIG_ACCOUNT` is a different PDA: the Squads **multisig**
> **account** that stores the members list and signing threshold.
>
> Find it on `solscan.io` under the vault's **Multisig** tab, or on
> `app.squads.so` under `Settings`.

#### Example Output

```
=== Safe Multisig Wallets ===

[Gateway]
  Safe address : 0x5f0F...2bE
  Threshold    : 3 of 5
  Owners:
    1. 0x9b82...9B71
    2. 0xf299...fBBE
    3. 0x6dd4...5874
    4. 0x8edF...8CB8
    5. 0x7053...02b3

[BSC]
  ...

[HyperEVM]
  ...

All Safe wallets have IDENTICAL owners and threshold (3 of 5)

=== Gateway Safe AdminModule ===

[Gateway AdminModule]
  Module address : 0x57f866b5E7Fb82Fb812Ed3D3C79cdB35E9e91518
  Admin account  : 0x...
  Safe proxy     : 0x5f0F86BcEad6976711C9B131bCa5D30E767fe2bE

[Gateway Safe enabled modules]
  Safe address  : 0x5f0F86BcEad6976711C9B131bCa5D30E767fe2bE
  Total enabled : 1
    1. 0x57f866b5E7Fb82Fb812Ed3D3C79cdB35E9e91518

Only the AdminModule is enabled on the Gateway Safe, and its SAFE_PROXY matches.

=== Aragon DAO Plugins ===
  DAO: 0xB6D6...Ef3
  ...

Detected 2 active plugin address(es):
    https://etherscan.io/address/0x...
    https://etherscan.io/address/0x...

=== Solana Squads Multisig ===

[Solana Squads]
  Multisig account : HB3bo...CkxC
  Threshold        : 4 of 6
  Members:
    1. ...
    2. ...
    ...
```
