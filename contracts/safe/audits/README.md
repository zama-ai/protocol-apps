# Safe (Admin Module) — Audit & verification status

Tracks the security verification status for each released version of the `safe` contracts (`AdminModule`).

- Package source: [`contracts/safe`](../)
- Deployed addresses: [Gateway mainnet](../../../docs/addresses/mainnet/gateway.md), [Gateway testnet](../../../docs/addresses/testnet/gateway.md)
- Top-level index: [`SECURITY.md`](../../../SECURITY.md)

## Git tag convention

Releases are tagged from the repo root as `safe-vX.Y.Z`. These contracts are immutable, so each tag is the source snapshot for a specific on-chain deployment.

## Verification status

Legend: ✅ completed · 🟡 in progress · — not applicable · TBD to be filled in.

| Tag           | Commit | Pre-deploy audit | Post-deploy audit | Deploy status |
| ------------- | ------ | ---------------- | ----------------- | ------------- |
| `safe-v1.0.0` | [`c414e53`](https://github.com/zama-ai/protocol-apps/commit/c414e538367d97f15dcfecce411873d1411f6269)  | ✅              | ✅               | Active |
