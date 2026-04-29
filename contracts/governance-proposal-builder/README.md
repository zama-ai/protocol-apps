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