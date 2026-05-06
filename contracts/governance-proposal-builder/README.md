# Governance Proposal Builder

Helpers to build, validate, and fill DAO Governance proposals.

## Prerequisites

- Node.js v18+
- npm

## Installation

```
npm install
```

## Configuration

Create a `.env` file based on `.env.example`:
```
cp .env.example .env
```

## Available scripts

Currently availabe scripts are:
```
[*] fill-options-gateway-proposal
[*] decode-options-gateway-proposal
[*] aragon-proposal-inspector
```

### fillOptionsGatewayProposal

#### Workflow

1. Edit `gateway-proposal-temp.json` (see one of the
   `gateway-proposal-temp.<network>-example.json` files as a starting point) to
   describe the proposal you want to send. Leave `arguments.options` set to
   `"0x"` — that field is what this script fills in.
2. Run the fill script for the target network:

   ```bash
   npm run fill-options-gateway-proposal:mainnet
   # or
   npm run fill-options-gateway-proposal:testnet
   ```

3. The script writes two files in current directory:
   - `gateway-proposal-filled.json` — the validated proposal mirroring the
     input shape, with `arguments.options` filled in. Useful as a
     human-readable record of what was generated.
   - `aragonProposal.json` — the same call rendered as a single Aragon
     transaction (`[{ to, value, data }]`) where `data` is the ABI-encoded
     `sendRemoteProposal(...)` calldata. **This is the file to upload via the
     Aragon DAO front-end** when creating the proposal that calls
     `sendRemoteProposal` on the `GovernanceOAppSender` contract.

#### What the script checks

Before computing options, the script enforces that the input matches the
canonical structure of `gateway-proposal-temp.json`:

- Top-level keys are exactly `to`, `method`, `arguments`.
- `arguments` keys are exactly `targets`, `values`, `functionSignatures`,
  `datas`, `operations`, `options`.
- `targets`, `values`, `functionSignatures`, `datas`, `operations` are arrays
  of strings of identical length.
- `options` is a string equal to `"0x"` : empty placeholder — **the whole point
  of the script is to fill it**.
- `method` is exactly `"sendRemoteProposal"`.
- `to` matches the canonical `GovernanceOAppSender` for the chosen network:
  - mainnet: `0x1c5D750D18917064915901048cdFb2dB815e0910`
  - testnet: `0x909692c2f4979ca3fa11B5859d499308A1ec4932`
- currently it only allows `values` and `operations` to be arrays of `"0"`s.
- each `targets[i]` has non-empty bytecode on the Gateway chain.

#### How `options` is computed

The script uses `@layerzerolabs/lz-v2-utilities` to build a LayerZero
option containing a single executor `lzReceive` action. To do this it forks the Gateway chain and impersonates the `SafeProxy` account to estimate the gas needed, and adds some constant and proportional buffers.

#### Output

The script writes two files next to the input:

```
./gateway-proposal-filled.json
./aragonProposal.json
```

It **refuses to overwrite** either file if it already exists, and exits
with a non-zero status before writing anything. Delete the file(s) first if
you want to regenerate.

#### RECOMMENDED MANUAL STEP: Decoding individual `datas` entries

Independently from this script, when doing a cross-chain proposal, it is highly recommended to always sanity-check what each `arguments.datas[i]` actually calls (using the matching
`arguments.functionSignatures[i]`) — note that usually datas are encoded **without**
the 4-byte selector, so use `cast abi-decode` and treat the bytes as the
"return-value" tuple, for example:

```bash
DATA=0x00000000000000000000000012345678901234567890123456789012345678900000000000000000000000000000000000000000000000000000000000000002

cast abi-decode 'f()(address,uint256)' "$DATA"
# 0x1234567890123456789012345678901234567890
# 2
```

The `f()` is just a placeholder; only the parameter-types tuple matters. Pass
the same types as the matching `functionSignatures[i]`.

### decodeOptionsGatewayProposal

Reverse of the `computeLZOptions` step inside `fillOptionsGatewayProposal`:
takes a LayerZero options hex string
and prints the decoded `gasLimit` and `nativeValue`. Useful to sanity-check
what's in `arguments.options` of a Gateway proposal and to use before voting on a pending DAO Gateway proposal.

#### Usage

```bash
npm run decode-options-gateway-proposal -- --options 0x000301001101000000000000000000000000000493e0
```

The leading `--` is required so npm forwards the flag to the script instead
of consuming it itself. `--options` is the only flag and is required.

#### Output

Prints (to stdout) the raw hex and the decoded fields:

```
Options hex:   0x000301001101000000000000000000000000000493e0
gasLimit:      300000
nativeValue:   0
```

### aragonProposalInspector

Independent, RPC-only viewer for a pending proposal on an Aragon
**Multisig** plugin. Useful as a sanity check before voting in case the
Aragon front-end has been compromised: this script bypasses
all Aragon-hosted infrastructure.

#### Trust path

For the proposal content itself: only the chosen RPC endpoint and ethers js library. No Aragon subgraph or
hosted API is consulted. Point `RPC_ETHEREUM` at an endpoint
you trust — ideally your own node.

For the optional abi-decoding of calldata and contract names: also Etherscan. 
The abi-decoding is still done and checked locally, we use Etherscan only for fetching 
the ABIs and contrat names, so we don't actually trust Etherscan for the security of decoded data.

#### Usage

```bash
# Reads RPC from .env (RPC_ETHEREUM)
npm run aragon-proposal-inspector -- --plugin 0xPLUGIN --id 5

# Or override the RPC inline (e.g. to point at Sepolia, your own node, ...)
npm run aragon-proposal-inspector -- --plugin 0xPLUGIN --id 5 --rpc https://your.rpc

# Machine-readable output
npm run aragon-proposal-inspector -- --plugin 0xPLUGIN --id 5 --json
```

The leading `--` is required so npm forwards flags to the script. Required
flags are `--plugin` (the Multisig plugin address — **not** the DAO address;
in Aragon OSx, proposals live on the plugin) and `--id` (decimal or
0x-hex non-negative integer).

#### Optional: Etherscan enrichment

If `ETHERSCAN_API_KEY` is set in `.env`, every action's `to` address is
additionally looked up via the Etherscan v2 API
(single key across all supported chains). For
each address, the inspector prints:

- the contract `name` and verification status,
- if the contract is flagged as a proxy and `Implementation` is set, the
  implementation's name + verification status,
- the abi-decoded `function:` line + each argument, decoded against the
  contract's own ABI when verified, falling back to the implementation ABI
  for verified proxies.

#### What it prints

For the human-readable mode:

- Plugin address, chain id, latest block.
- Proposal id, `executed` flag, `approvals / minApprovals`, and
  `canExecute`.
- `snapshotBlock`, `startDate`, `endDate`, and a derived
  `Window status` (not yet open / open / closed).
- `allowFailureMap` (raw hex).
- For each action: `to`, optional `name` (when Etherscan is enabled),
  `value` (wei), the full raw `data`, and an optional `function:` block
  with the decoded signature and arguments (when Etherscan is enabled and
  the calldata could be decoded).