# Fees Burner — Audit & verification status

Tracks the security verification status for each released version of the `feesBurner` contracts (`ProtocolFeesBurner`, `FeesSenderToBurner`).

- Package source: [`contracts/feesBurner`](../)
- Deployed addresses: [Ethereum mainnet](../../../docs/addresses/mainnet/ethereum.md), [Gateway mainnet](../../../docs/addresses/mainnet/gateway.md), [Sepolia testnet](../../../docs/addresses/testnet/sepolia.md), [Gateway testnet](../../../docs/addresses/testnet/gateway.md)
- Top-level index: [`SECURITY.md`](../../../SECURITY.md)

## Git tag convention

Releases are tagged from the repo root as `fees-vX.Y.Z`. Contracts are immutable, so each tag is the source snapshot for a specific on-chain deployment.

## Verification status

Legend: ✅ completed · 🟡 in progress · — not applicable · TBD to be filled in.

| Tag           | Commit | Pre-deploy audit | Post-deploy audit | Deploy status |
| ------------- | ------ | ---------------- | ----------------- | ------------- |
| `fees-v1.0.0` | [`b8cbe46`](https://github.com/zama-ai/protocol-apps/commit/b8cbe46dadac9a69deec2a9fe0fa5ea1478a7c0a)  | ✅              | -               | Active |
