# Staking — Audit & verification status

Tracks the security verification status for each released version of the `staking` contracts.

- Package source: [`contracts/staking`](../)
- Deployed addresses: [Ethereum mainnet](../../../docs/addresses/mainnet/ethereum.md), [Sepolia testnet](../../../docs/addresses/testnet/sepolia.md)
- Top-level index: [`SECURITY.md`](../../../SECURITY.md)

## Git tag convention

Releases are tagged from the repo root as `staking-vX.Y.Z`. These contracts are mixed upgradable and immutable, so each tag is the source snapshot for a proxy upgrade or a specific immutable on-chain deployment.

## Verification status

Legend: ✅ completed (link to report) · 🟡 in progress · — not applicable · TBD to be filled in.

| Tag              | Commit | Pre-deploy audit | Post-deploy audit | Fuzzing and invariants | Status |
| ---------------- | ------ | ---------------- | ----------------- | ----------------------- | ------ |
| `staking-v1.0.0` | `TBD`  | TBD              | TBD               | TBD                     | Active |
