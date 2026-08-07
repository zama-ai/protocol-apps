# Confidential Token Wrappers Registry — Audit & verification status

Tracks the security verification status for each released version of the `confidential-token-wrappers-registry` contracts.

- Package source: [`contracts/confidential-token-wrappers-registry`](../)
- Deployed addresses: [Ethereum mainnet](../../../docs/addresses/mainnet/ethereum.md), [Sepolia testnet](../../../docs/addresses/testnet/sepolia.md)
- Top-level index: [`SECURITY.md`](../../../SECURITY.md)

## Git tag convention

Releases are tagged from the repo root as `registry-vX.Y.Z`. These contracts are upgradable (UUPS), so a tag is a candidate source snapshot for a proxy upgrade.

## Verification status

Legend: ✅ completed · 🟡 in progress · — not applicable · TBD to be filled in.

| Tag               | Commit | Pre-deploy audit | Post-deploy audit | Deploy status   |
| ----------------- | ------ | ---------------- | ----------------- | --------------- |
| `registry-v1.0.0` | [`76dbe8f`](https://github.com/zama-ai/protocol-apps/commit/76dbe8f0bb8d254650b5e6644423c2dbc6fb6117)  | -              | -               | Active   |
| `registry-v1.0.1` | [`373c5f2`](https://github.com/zama-ai/protocol-apps/commit/373c5f29ee6e9b45a379470488a83cb20b324bdf)  | ✅              | TBD               | Upcoming |
