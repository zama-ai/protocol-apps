# Quickstart: Proposal Reviewer

This page gets you from zero to a verified governance proposal. For full details, see [Reviewing Proposals](reviewing-proposals.md).

## Prerequisites

- Access to the Aragon [mainnet DAO](https://app.aragon.org/dao/ethereum-mainnet/zama.dao.eth/dashboard) or [testnet DAO](https://app.aragon.org/dao/ethereum-sepolia/0x08e8a84c3c8c7cba165B1adcf67Ae4639eF84f52/dashboard)
- Access to the [protocol-registry](https://github.com/zama-ai/protocol-registry) repo (source of truth for addresses)
- For CLI verification: Node.js v18+, npm, and an Ethereum RPC URL

## Review via Aragon frontend

1. Open the proposal in the Aragon DAO dashboard.
2. For each action, verify:
   - **Contract address**: matches the expected address in the protocol-registry repo.
   - **Function name**: matches the intended operation.
   - **Arguments**: all values are correct (including role hashes, encoded data).
3. For ERC1967 proxies:
   - Mark the contract as a proxy on the block explorer.
   - Use "Read as Proxy" to find the implementation address.
   - Inspect the implementation source code.
4. For magic constants (e.g. role hashes):
   - Recompute using `keccak256("ROLE_NAME")`.
   - Compare against the value in the proposal.
5. For cross-chain proposals (`sendRemoteProposal`):
   - Also verify using the CLI tools below.

## Verify via CLI Inspector

### One-time setup

```bash
git clone https://github.com/zama-ai/protocol-apps.git
cd protocol-apps/scripts/governance-proposal-builder
npm install
cp .env.example .env
# Edit .env: set RPC_ETHEREUM and optionally ETHERSCAN_API_KEY
```

### Run the inspector

1. Get the two required inputs:
   - **Plugin address** (`0xPLUGIN`): from the [protocol-registry repo](https://github.com/zama-ai/protocol-registry) (not the DAO address).
   - **Proposal ID**: from the Aragon frontend: click "Published: \<DATE\>" to go to Etherscan, then find the `proposalId` in the **Logs** tab.
2. Run:
   ```bash
   npm run aragon-proposal-inspector -- --plugin 0xPLUGIN --id PROPOSAL_ID
   ```
3. Compare the CLI output against what the Aragon frontend shows:
   - `to` addresses must match.
   - `function` names and argument values must match.

### Final check before signing

- In your wallet (e.g. MetaMask), open **advanced details**.
- Verify the `proposalId` value matches the expected one.
- **⚠️ Verify the full `proposalId` on your hardware wallet screen**: this is critical.

## Verify a Cross-Chain Gateway Proposal

1. In `gateway-proposal-temp.json`, replace `targets[i]`, `functionSignatures[i]`, and `datas[i]` with values from the Aragon frontend. Keep `options` as `"0x"`.
2. Run:
   ```bash
   npm run fill-options-gateway-proposal:mainnet   # or :testnet
   ```
3. Compare the `options` value in `gateway-proposal-filled.json` with the Aragon frontend:
   - **Match**: gas estimation is correct.
   - **Mismatch**: decode both and compare gas limits:
     ```bash
     npm run decode-options-gateway-proposal -- --options <OPTIONS_HEX>
     ```
     Gas limits should differ by at most a few percentage points.
4. Sanity-check each `datas[i]`:
   ```bash
   cast abi-decode 'f()(address,uint256)' "$DATA"
   ```

## What's Next

- For full verification examples, see [Reviewing Proposals](reviewing-proposals.md#examples)
- For CLI command details, see [CLI Reference](cli-reference.md)
