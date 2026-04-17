# Solana OFT — Audit & verification status

Tracks the security verification status for each released version of the `solanaOFT` program (Solana-side of the ZAMA OFT).

- Package source: [`contracts/solanaOFT`](../)
- Deployed addresses: [Solana mainnet](../../../docs/addresses/mainnet/solana.md)
- Top-level index: [`SECURITY.md`](../../../SECURITY.md)

## Git tag convention

Releases are tagged from the repo root as `solanaOFT-vX.Y.Z`. The program is immutable, so each tag is the source snapshot for a specific on-chain deployment.

## Verification status

Legend: ✅ completed · 🟡 in progress · — not applicable · TBD to be filled in.

| Tag                | Commit | Pre-deploy audit | Post-deploy audit | Deploy status |
| ------------------ | ------ | ---------------- | ----------------- | ------------- |
| `solanaOFT-v1.0.0` | [`f771d55`](https://github.com/zama-ai/protocol-apps/commit/f771d550eac70616832fc1b4370d2bb753a3a850)  | ✅              | ✅               | Active |
