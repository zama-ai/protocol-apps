# CLI Reference: Governance Tools

All tools live in the `scripts/governance-proposal-builder` directory of the [protocol-apps](https://github.com/zama-ai/protocol-apps) repo.

---

## Installation

```bash
git clone https://github.com/zama-ai/protocol-apps.git
cd protocol-apps/scripts/governance-proposal-builder
npm install
cp .env.example .env
```

Edit `.env` with the required values:

| Variable | Required | Description |
|---|---|---|
| `RPC_ETHEREUM` | Yes | Ethereum RPC URL (mainnet or Sepolia). Use your own node when possible. |
| `RPC_GATEWAY_MAINNET` | No | Gateway mainnet RPC. Default: `https://rpc.mainnet.zama.org` |
| `RPC_GATEWAY_TESTNET` | No | Gateway testnet RPC. Default: `https://rpc-zama-testnet-0.t.conduit.xyz` |
| `ETHERSCAN_API_KEY` | Yes (verification step) | Etherscan API key. Enables ABI fetching for human-readable logs in the inspector. |

---

## `aragon-proposal-inspector`

Independently verifies an Aragon Multisig proposal using only an RPC endpoint. Bypasses all Aragon-hosted infrastructure (subgraph, API, frontend).

**Used by:** [Reviewers](quickstart-reviewer.md) (independent proposal verification)

### Usage

```bash
npm run aragon-proposal-inspector -- --plugin <PLUGIN_ADDRESS> --id <PROPOSAL_ID>
```

Optional flags:
- `--rpc <URL>`: override `RPC_ETHEREUM` from `.env`
- `--json`: output raw JSON instead of formatted logs

### Expected inputs

| Input | Description | Where to find it |
|---|---|---|
| `--plugin` | Multisig Plugin contract address (**not** the DAO address) | [protocol-registry repo](https://github.com/zama-ai/protocol-registry/blob/main/data/mainnet/contracts.yaml) |
| `--id` | Proposal ID (`uint256`) | Aragon frontend → click "Published: \<DATE\>" → Etherscan Logs tab → `proposalId` field |

### Expected output

Formatted log showing for each action:
- `to`: target contract address (with name if Etherscan API key is set)
- `function`: decoded function name and arguments
- `value`: ETH value

### Trust model

- **Trusted:** RPC endpoint, ethers.js library
- **Untrusted:** Aragon subgraph, Aragon API, Aragon frontend, Etherscan (used only for ABI fetching)
- If the ABI from Etherscan is wrong, decoding fails (the script panics) rather than silently producing incorrect output.

### Common errors

| Error | Cause | Fix |
|---|---|---|
| Cannot fetch proposal | Wrong plugin address or proposal ID | Verify `--plugin` is the Multisig Plugin (not the DAO address). Verify `--id` from Etherscan Logs. |
| ABI fetch failed | Etherscan API key missing or invalid | Set `ETHERSCAN_API_KEY` in `.env`, or the script falls back to raw calldata display. |
| RPC connection error | `RPC_ETHEREUM` not set or unreachable | Set a valid RPC URL in `.env` or pass `--rpc`. |
| Decoding error | Contract ABI mismatch | Check that the contract is verified on Etherscan. The script may still show raw calldata. |

---

## Utility: `cast abi-decode`

Not part of this repo, but frequently used alongside these tools for manual verification. Part of [Foundry](https://book.getfoundry.sh/).

### Usage

```bash
# Decode ABI-encoded data (without selector)
cast abi-decode 'f()(address,uint256)' "0x00000000..."

# Encode a function call (to verify bytes inputs)
cast calldata 'reinitializeV2()'
```

### Installation

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

## `fill-options-gateway-proposal`

Computes LayerZero gas options for a cross-chain Gateway proposal and produces an Aragon-uploadable JSON file.

**Used by:** [Creators](quickstart-creator.md) (building proposals), [Reviewers](quickstart-reviewer.md) (verifying proposals)

### Usage

```bash
npm run fill-options-gateway-proposal:mainnet
npm run fill-options-gateway-proposal:testnet
```

### Expected input

A `gateway-proposal-temp.json` file in the current directory. Start from a template:

```bash
# Mainnet
cp gateway-proposal-temp.mainnet-example.json gateway-proposal-temp.json

# Testnet
cp gateway-proposal-temp.testnet-example.json gateway-proposal-temp.json
```

Edit these fields in the JSON:
- `arguments.targets[i]`: Gateway contract address
- `arguments.functionSignatures[i]`: e.g. `addOwnerWithThreshold(address,uint256)`
- `arguments.datas[i]`: ABI-encoded arguments without the 4-byte selector

Do **not** modify: `to`, `method`, `arguments.values`, `arguments.operations`, `arguments.options`.

### Expected output

Two files:

| File | Purpose |
|---|---|
| `aragonProposal.json` | Upload to the Aragon DAO frontend. Contains the ABI-encoded `sendRemoteProposal(...)` calldata as a single Aragon transaction. |
| `gateway-proposal-filled.json` | Human-readable record. Same shape as input, with `arguments.options` populated. |

### Common errors

| Error | Cause | Fix |
|---|---|---|
| Output file already exists | Script refuses to overwrite | Delete `aragonProposal.json` and `gateway-proposal-filled.json`, then retry. |
| Target has no bytecode | `targets[i]` address has no contract on Gateway | Verify the address is correct and on the right network. |
| Invalid `to` address | `to` does not match canonical `GovernanceOAppSender` | Do not modify the `to` field — keep the value from the template. |
| Missing `.env` values | `RPC_ETHEREUM` or Gateway RPC not set | Set the required values in `.env`. |

---

## `decode-options-gateway-proposal`

Decodes a LayerZero `options` hex string into human-readable `gasLimit` and `nativeValue`.

**Used by:** [Reviewers](quickstart-reviewer.md) (comparing gas options)

### Usage

```bash
npm run decode-options-gateway-proposal -- --options <OPTIONS_HEX>
```

> The leading `--` after the script name is required so npm forwards the flag to the script.

### Expected input

- `--options`: the hex string from `arguments.options` in a proposal or from the Aragon frontend.

### Expected output

```
Options hex:   0x000301001101000000000000000000000000000493e0
gasLimit:      300000
nativeValue:   0
```

### Common errors

| Error | Cause | Fix |
|---|---|---|
| Missing `--options` flag | Flag not provided or `--` separator missing | Use `-- --options <HEX>` (note the double `--`). |
| Invalid hex string | Malformed options value | Verify the hex string is copied correctly from the proposal. |

---