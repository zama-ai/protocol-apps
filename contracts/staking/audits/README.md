# Staking — Audit & verification status

Tracks the security verification status for each released version of the `staking` contracts.

- Package source: [`contracts/staking`](../)
- Deployed addresses: [Ethereum mainnet](../../../docs/addresses/mainnet/ethereum.md), [Sepolia testnet](../../../docs/addresses/testnet/sepolia.md)
- Top-level index: [`SECURITY.md`](../../../SECURITY.md)

## Git tag convention

Releases are tagged from the repo root as `staking-vX.Y.Z`. These contracts are mixed upgradable and immutable, so each tag is the source snapshot for a proxy upgrade or a specific immutable on-chain deployment.

## Verification status

Legend: ✅ completed · 🟡 in progress · — not applicable · TBD to be filled in.

| Tag              | Commit | Pre-deploy audit | Post-deploy audit | Fuzzing and invariants  | Deploy status  |
| ---------------- | ------ | ---------------- | ----------------- | ----------------------- | -------------- |
| `staking-v0.1.0` | [`b9869f6`](https://github.com/zama-ai/protocol-apps/commit/b9869f6016f88821550e98c414c725464da30cb9)  | ✅               | -                 | -                       | Skipped |
| `staking-v1.0.0` | [`b631f17`](https://github.com/zama-ai/protocol-apps/commit/b631f175722f81f80ee05f94e5508261e552b341)  | ✅              | ✅               | 🟡                      | Active (*)  |
| `staking-v1.0.1-luganodes` | [`5c5e705`](https://github.com/zama-ai/protocol-apps/commit/5c5e705fb79827cd459f014a931c22efd698654c)  | ✅              | ✅               | 🟡                      | Active (**)  |

Legend:
- (*) The tag is the currently deployed source for all operators EXCEPT `Luganodes`.
- (**) The tag is the currently deployed source for the `Luganodes` operator ONLY.