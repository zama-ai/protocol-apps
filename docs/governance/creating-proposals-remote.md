# Creating Cross-Chain (Remote) Proposals

The Protocol DAO on Ethereum can execute governance actions on EVM destination
chains (Zama Gateway, Polygon Amoy, …). This works through:
- `GovernanceOAppSender` contract on Ethereum (**one per destination**)
- `GovernanceOAppReceiver` contract on the destination chain
- Connected via LayerZero

On the destination chain, `GovernanceOAppReceiver` calls functions through the
destination multisig (Safe). More information is available in the
[Governance](../governance.md) documentation, and the list of supported
destinations (ids, addresses, RPC vars) is in
[Destinations](destinations.md).

**Related guides:**
- [Creating Ethereum proposals](creating-proposals-ethereum.md): how to create and submit Ethereum proposals
- [Reviewing proposals](reviewing-proposals.md): how to verify proposals before approving
- [CLI reference](cli-reference.md): detailed CLI tool documentation

---

## Step 0: Create a community forum post

Before creating the on-chain proposal, publish a post in the [governance community forum](https://community.zama.org/c/protocol/governance/) to present and add context on the proposal so DAO members can review it. Use the [forum post template](forum-post-template.md). Keep the post's URL — you'll link it in the proposal's **Resources** when filling in the proposal details (Step 5).

## One-time setup.

```bash
git clone https://github.com/zama-ai/protocol-apps.git
cd protocol-apps/scripts/governance-proposal-builder
npm install
cp .env.example .env
# Edit .env: set the RPC for your destination (see destinations.md), e.g. RPC_GATEWAY_MAINNET.
```

> **Important:** It is recommended to use your own RPC URLs for the script.

## Step 1: Describe the destination calls

Copy the minimal template and fill in **only** the three equal-length arrays —
one entry per call:

```bash
cp remote-proposal-temp.example.json remote-proposal-temp.json
```

Edit `remote-proposal-temp.json`:
- `targets[i]`: contract address **on the destination chain**
- `functionSignatures[i]`: human-readable signature, e.g. `addOwnerWithThreshold(address,uint256)` (**required** — never leave empty, so every call is auditable; the script builds the 4-byte selector from it)
- `datas[i]`: ABI-encoded arguments **without** the 4-byte selector

That's all you provide. For the destination you pick in Step 2, the script
fills the rest: `to` (its `GovernanceOAppSender`), `method`, `values` (all
`0`), `operations` (all `0`) and `options`.

```json
{
  "targets": ["0x5f0F86BcEad6976711C9B131bCa5D30E767fe2bE"],
  "functionSignatures": ["addOwnerWithThreshold(address,uint256)"],
  "datas": ["0x00000000000000000000000012345678901234567890123456789012345678900000000000000000000000000000000000000000000000000000000000000002"]
}
```

## Step 2: Run the fill script

Pass the destination id (`npm run list-destinations` lists them; see [Destinations](destinations.md)):

```bash
npm run fill-options-remote-proposal -- --destination gateway-mainnet
# or gateway-testnet, gateway-devnet, polygon-amoy-testnet, …
```

The script **decodes each `datas[i]` against its `functionSignatures[i]` and
prints the resulting call** as a built-in sanity check — it **aborts** if a
`datas`/signature pair doesn't match. Read that output and confirm every call
is exactly what you intend. It then runs `eth_estimateGas` against the
destination chain with its multisig as the (unsigned) `from` to estimate the
LayerZero execution gas, and writes:

**Output files:**
- `aragonProposal.json`: upload this to the Aragon frontend
- `remote-proposal-filled.json`: human-readable record (the full proposal with `options` populated)

> **Important:** The script won't overwrite existing output files. Delete `remote-proposal-filled.json` and `aragonProposal.json` before regenerating new ones.

> **Gas calibration (non-Gateway chains):** the fixed overhead/buffer the script adds on top of the per-call estimate was calibrated for the Ethereum → Gateway path. It has **not** been verified for other destinations (e.g. Polygon Amoy). For a non-Gateway destination, treat the first proposal as a calibration run: if delivery gets stuck, recover it via [manual execution](manual-execution-remote.md) and adjust the constants in `fillOptionsRemoteProposal.js`.

> **Optional cross-check:** you can independently decode any `datas[i]` with Foundry — `cast abi-decode 'f()(address,uint256)' <DATA>` — where the types after `f()` must match `functionSignatures[i]`.

## Step 3: Upload and submit the proposal

1. In the Aragon frontend, click the **Upload** button:

![Upload button](images/aragon-upload-button.png)

2. Select `aragonProposal.json`. The UI should decode the `sendRemoteProposal` call:

![Decoded proposal](images/aragon-decoded-proposal.png)

3. As in [Creating Ethereum Proposals](creating-proposals-ethereum.md#step-3-simulate-and-submit): **simulate** the proposal, then submit.


## Step 4: Upload the json files to the community forum

Upload the `aragonProposal.json` and `remote-proposal-filled.json` files to the community forum post created in Step 0.
