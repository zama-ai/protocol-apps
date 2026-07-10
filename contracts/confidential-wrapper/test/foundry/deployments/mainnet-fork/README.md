# Committed Mainnet-Fork Fixture

The offline fork fixture consumed by the test suite:

- `read-cache.json`: forge's fork read cache, captured by warming the suite against a live
  mainnet fork (`make bake`). The human-auditable source of the fixture — it holds exactly the
  account code and storage the tests touch.
- `anvil-state.json`: raw `anvil_dumpState` hex, converted from `read-cache.json` by
  `script/convert-cache.js` and loaded via `anvil_loadState`.
- `manifest.json`: bake metadata (`forkBlock`, `readCacheBlock`, `chainId`, registry address).

`make bake` regenerates all three; commit them together. They are not generated in CI. After a
bake, run `make fork-test` (offline) and `make regression` (live-vs-offline parity) before committing.
See the [package README](../../README.md) for the full pipeline.
