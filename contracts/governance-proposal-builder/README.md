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
```

## fillOptionsGatewayProposal

### Workflow

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

3. The script writes two files next to the input:
   - `gateway-proposal-filled.json` — the validated proposal mirroring the
     input shape, with `arguments.options` filled in. Useful as a
     human-readable record of what was generated.
   - `aragonProposal.json` — the same call rendered as a single Aragon
     transaction (`[{ to, value, data }]`) where `data` is the ABI-encoded
     `sendRemoteProposal(...)` calldata. This is the file to upload via the
     Aragon DAO front-end when creating the proposal that calls
     `sendRemoteProposal` on the `GovernanceOAppSender` contract.

To validate a non-default temp proposal file:

```
npm run fill-options-gateway-proposal:mainnet -- --tempProposal my-temp.json
```

The leading `--` is required so npm forwards the flag to the script instead
of consuming it itself.

### What the script checks

Before computing options, the script enforces that the input matches the
canonical structure of `gateway-proposal-temp.json`:

- Top-level keys are exactly `to`, `method`, `arguments` (no extras, none
  missing).
- `arguments` keys are exactly `targets`, `values`, `functionSignatures`,
  `datas`, `operations`, `options`.
- `targets`, `values`, `functionSignatures`, `datas`, `operations` are arrays
  of strings of identical length (matches the on-chain length checks in
  `GovernanceOAppSender.sendRemoteProposal`).
- `options` is a string equal to `"0x"` (empty placeholder — the whole point
  of the script is to fill it).
- `method` is exactly `"sendRemoteProposal"`.
- `to` matches the canonical `GovernanceOAppSender` for the chosen network:
  - mainnet: `0x1c5D750D18917064915901048cdFb2dB815e0910`
  - testnet: `0x909692c2f4979ca3fa11B5859d499308A1ec4932`

### How `options` is computed

The script uses `@layerzerolabs/lz-v2-utilities` to build a LayerZero
option containing a single executor `lzReceive` action. To do this it forks the Gateway chain and impersonates the `SafeProxy` account to estimate the gas needed, and adds some constant and proportional buffers.

### Output

The script writes two files next to the input:

```
./gateway-proposal-filled.json
./aragonProposal.json
```

It **refuses to overwrite** either file if it already exists, and exits
with a non-zero status before writing anything. Delete the file(s) first if
you want to regenerate.

### RECOMMENDED MANUAL STEP: Decoding individual `datas` entries

Independently from this script, when doing a cross-chain proposal, it is highly recommended to always sanity-check what each `arguments.datas[i]` actually calls (using the matching
`arguments.functionSignatures[i]`) — note that datas are encoded **without**
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