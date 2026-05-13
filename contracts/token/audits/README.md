# Token — Audit & verification status

Tracks the security verification status of the token contracts (`ZamaERC20`, `ZamaOFTAdapter`, `ZamaOFT`) per chain. Each chain deployment has its own audit scope, so the matrix is grouped by chain.

- Package source: [`contracts/token`](../)
- Deployed addresses: [Ethereum mainnet](../../../docs/addresses/mainnet/ethereum.md), [Gateway mainnet](../../../docs/addresses/mainnet/gateway.md), [BSC](../../../docs/addresses/mainnet/bsc.md), [HyperEVM](../../../docs/addresses/mainnet/hyper_evm.md), [Sepolia testnet](../../../docs/addresses/testnet/sepolia.md), [Gateway testnet](../../../docs/addresses/testnet/gateway.md)
- Solana OFT: tracked separately in [`solanaOFT` audits](../../solanaOFT/audits/README.md)
- Top-level index: [`SECURITY.md`](../../../SECURITY.md)

## Git tag convention

Releases are tagged from the repo root as `token-vX.Y.Z`. These contracts are immutable, so each tag is the source snapshot for a specific on-chain deployment. A single tag covers all EVM chain deployments of that version.

## Verification status

Legend: ✅ completed · 🟡 in progress · — not applicable · TBD to be filled in.

| Tag            | Commit | Pre-deploy audit |
| -------------- | ------ | ---------------- |
| `token-v1.0.0` | [`157e6c4`](https://github.com/zama-ai/protocol-apps/commit/157e6c4aaa2283f48aeecc7b900146bc3f62bbe1)  | ✅              |

| Chain            | Tag            | Post-deploy audit | Deploy status    |
| ---------------- | -------------- | ----------------- | ---------------- |
| Ethereum         | `token-v1.0.0` | ✅                | ✅                |
| Gateway          | `token-v1.0.0` | ✅                | ✅                |
| BSC              | `token-v1.0.0` | ✅                | ✅                |
| HyperEVM         | `token-v1.0.0` | ✅                | ✅                |