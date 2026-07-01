# Committed Mainnet-Fork Fixture

The baked Anvil fixture consumed by the test suite:

- `anvil-state.json`: raw `anvil_dumpState` hex, loaded via `anvil_loadState`.
- `manifest.json`: bake metadata (`forkBlock`, `blacklistScannedBlock`, `chainId`, registry address, pairs).
- `blacklist-cache.json`: per-token blacklist sidecar (encoding, base slot, last scanned block, set).

These are produced by `make bake` through `script/bake.mjs` and committed together; they are not
generated in CI. After a fresh bake, run `make test` from the foundry package before committing.
See the [package README](../../README.md) for baking, teardown, the fixture model, and usage.
