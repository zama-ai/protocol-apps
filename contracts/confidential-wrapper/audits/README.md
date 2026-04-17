# Confidential Wrapper — Audit & verification status

Tracks the security verification status for each released version of the `confidential-wrapper` contracts.

- Package source: [`contracts/confidential-wrapper`](../)
- Deployed addresses: [Ethereum mainnet](../../../docs/addresses/mainnet/ethereum.md), [Sepolia testnet](../../../docs/addresses/testnet/sepolia.md)
- Top-level index: [`SECURITY.md`](../../../SECURITY.md)

## Git tag convention

Releases are tagged from the repo root as `wrapper-vX.Y.Z`. These contracts are upgradable (UUPS), so a tag is a candidate source snapshot for a proxy upgrade.

## Verification status

Legend: ✅ completed · 🟡 in progress · — not applicable · TBD to be filled in.

| Tag              | Commit | Pre-deploy audit | Post-deploy audit | Deploy status   |
| ---------------- | ------ | ---------------- | ----------------- | --------------- |
| `wrapper-v1.0.0` | [`ac9f9ca`](https://github.com/zama-ai/protocol-apps/commit/ac9f9ca247328ad89dd3084854f71585fdd0c39c)  | -              | -               | Active   |
| `wrapper-v2.0.0` | [`b06eb26`](https://github.com/zama-ai/protocol-apps/commit/b06eb263d64c788a27b6bc1baf46b7547f7ec594)  | ✅              | TBD               | Upcoming |
