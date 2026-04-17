# Token — Audit & verification status

Tracks the security verification status of the token contracts (`ZamaERC20`, `ZamaOFTAdapter`, `ZamaOFT`) per chain. Each chain deployment has its own audit scope, so the matrix is grouped by chain.

- Package source: [`contracts/token`](../)
- Deployed addresses: [Ethereum mainnet](../../../docs/addresses/mainnet/ethereum.md), [Gateway mainnet](../../../docs/addresses/mainnet/gateway.md), [BSC](../../../docs/addresses/mainnet/bsc.md), [HyperEVM](../../../docs/addresses/mainnet/hyper_evm.md), [Sepolia testnet](../../../docs/addresses/testnet/sepolia.md), [Gateway testnet](../../../docs/addresses/testnet/gateway.md)
- Solana OFT: tracked separately in [`solanaOFT` audits](../../solanaOFT/audits/README.md)
- Top-level index: [`SECURITY.md`](../../../SECURITY.md)

## Git tag convention

Releases are tagged from the repo root as `token-vX.Y.Z`. These contracts are immutable, so each tag is the source snapshot for a specific on-chain deployment. A single tag covers all EVM chain deployments of that version.

## Verification status

Legend: ✅ completed (link to report) · 🟡 in progress · — not applicable · TBD to be filled in.

### Ethereum — `ZamaERC20` + `ZamaOFTAdapter`

| Tag            | Commit | Pre-deploy audit | Post-deploy audit |
| -------------- | ------ | ---------------- | ----------------- |
| `token-v1.0.0` | `TBD`  | TBD              | TBD               |

### BSC — `ZamaOFT`

| Tag            | Commit | Pre-deploy audit | Post-deploy audit |
| -------------- | ------ | ---------------- | ----------------- |
| `token-v1.0.0` | `TBD`  | TBD              | TBD               |

### HyperEVM — `ZamaOFT` + `HyperLiquidComposer`

| Tag            | Commit | Pre-deploy audit | Post-deploy audit |
| -------------- | ------ | ---------------- | ----------------- |
| `token-v1.0.0` | `TBD`  | TBD              | TBD               |

### Gateway — `ZamaOFT`

| Tag            | Commit | Pre-deploy audit | Post-deploy audit |
| -------------- | ------ | ---------------- | ----------------- |
| `token-v1.0.0` | `TBD`  | TBD              | TBD               |
