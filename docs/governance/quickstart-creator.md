# Quickstart: Proposal Creator

This page gets you from zero to a submitted governance proposal. For full details, see [Creating Ethereum Proposals](creating-proposals-ethereum.md) or [Creating Gateway Proposals](creating-proposals-gateway.md).

## Prerequisites

- Wallet connected to the Aragon [mainnet DAO](https://app.aragon.org/dao/ethereum-mainnet/zama.dao.eth/dashboard) or [testnet DAO](https://app.aragon.org/dao/ethereum-sepolia/0x08e8a84c3c8c7cba165B1adcf67Ae4639eF84f52/dashboard)
- For cross-chain proposals: Node.js v18+, npm, and an Ethereum RPC URL

## Create an Ethereum Proposal

For full details, see [Creating Ethereum Proposals](creating-proposals-ethereum.md).

1. Open the Aragon DAO dashboard and click **Proposals** > **+ Proposal**.
2. Pick the proposal type:
   - **Operators**: requires 9/17 operator approvals.
3. Fill in **Title**, **Summary**, **Body** and **Resources**.
4. Add actions:
   - Enter the target contract address and wait for green checks.
   - Select the function to call.
   - Fill in arguments. **Do not use quotes** around function signature strings.
5. Click **+ Action** to add more actions if needed.
6. Click **Next**, then **Simulate** to verify the actions won't revert.
7. Submit the proposal, notify reviewers: first code owners, then DAO members.

## Create a Cross-Chain Gateway Proposal

For full details, see [Creating Gateway Proposals](creating-proposals-gateway.md).

### One-time setup

```bash
git clone https://github.com/zama-ai/protocol-apps.git
cd protocol-apps/scripts/governance-proposal-builder
npm install
cp .env.example .env
# Edit .env: set RPC_ETHEREUM to your RPC URL
```

### Build and submit

1. Copy the right template:
   ```bash
   # Mainnet
   cp gateway-proposal-temp.mainnet-example.json gateway-proposal-temp.json
   # Testnet
   cp gateway-proposal-temp.testnet-example.json gateway-proposal-temp.json
   ```
2. Edit `gateway-proposal-temp.json` — fill in only:
   - `arguments.targets[i]`: contract address on Gateway
   - `arguments.functionSignatures[i]`: e.g. `addOwnerWithThreshold(address,uint256)`
   - `arguments.datas[i]`: ABI-encoded arguments (without 4-byte selector)
3. Sanity-check each `datas[i]`:
   - types after `f()` must match types from `functionSignatures[i]`.
   ```bash
   cast abi-decode 'f()(address,uint256)' "$DATA"
   ```
4. Run the fill script:
   ```bash
   npm run fill-options-gateway-proposal:mainnet   # or :testnet
   ```
   - Output: `aragonProposal.json` (upload to Aragon) + `gateway-proposal-filled.json` (record)
5. In the Aragon frontend, click the **Upload** button and select `aragonProposal.json`.
6. Verify the UI decodes the `sendRemoteProposal` call correctly.
7. **Simulate**, then submit.

## What's Next

- Track cross-chain proposals on [LayerZeroScan](https://layerzeroscan.com/)
- If a proposal was executed on Ethereum but delivery to Gateway failed, see [Manual execution](manual-execution-gateway.md)
- Ask a reviewer to verify your proposal — see [Quickstart: Reviewer](quickstart-reviewer.md)
