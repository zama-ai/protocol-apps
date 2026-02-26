# Config Checker

Utilities for checking FHEVM protocol contract configurations.

Returns the current set of active pausers for PauserSet contracts on Ethereum and Gateway chains by analyzing on-chain events.

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
```
### getCurrentPausers

#### Usage

```bash
npm run get-current-pausers
```

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
DEFAULT_ADMIN_ROLE:
  1. 0x... (0 ETH)
  Events: 1 granted, 0 revoked
  Total: 1 address(es)

MINTER_ROLE:
  1. 0x... (0 ETH)
  2. 0x... (0 ETH)
  Events: 2 granted, 0 revoked
  Total: 2 address(es)

MINTING_PAUSER_ROLE:
  1. 0x... (0 ETH)
  Events: 1 granted, 0 revoked
  Total: 1 address(es)

--------------------------------------------------
Total RoleGranted events: 4
Total RoleRevoked events: 0
```

### getOftOwners

#### Usage

```bash
npm run get-oft-owners
```

The script checks multiple chains (as configured in `.env`) and reports the current **owner** and **LayerZero delegate** for each ZamaOFTAdapter (Ethereum) or ZamaOFT (Gateway, BSC, HyperEVM). It uses on-chain view calls only (`owner()`, `endpoint()`, `delegates(oapp)`).

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
[Ethereum Adapter]
  Adapter/OFT address : 0x...
  Endpoint address    : 0x...
  Owner              : 0x...
  Delegate           : 0x...

[Gateway OFT]
  ...
```


