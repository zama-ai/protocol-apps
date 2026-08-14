# Foundry Mainnet-Fork Tests: Confidential Wrappers

Foundry tests that exercise the **live** Confidential Wrappers deployed on Ethereum mainnet.
`BaseForkTest` enumerates every valid wrapper from the on-chain
`ConfidentialTokenWrappersRegistry`, and the suite checks:

- direct wrap, confidential transfer, unwrap, finalize, and ERC-1363 receiver flows;
- per-wrapper deny-list behavior (owner gating, block/unblock, blocked-wrap guard);
- configured underlying-token deny-list selectors against the deployed underlying token code;
- underlying-token deny-list gating against real mainnet state, including known
  blacklisted mainnet addresses.

A second suite under `test/batcher` drives the **deployed** Confidential DeFi Gateway batchers
against the same candidate implementation, so a wrapper upgrade that breaks the batchers fails
here. See [Deployed-batcher suite](#deployed-batcher-suite).

Tests run against a **live mainnet fork**: `forge test --fork-url <archive RPC>` reads the code
and storage the tests touch directly from the archive node.

## Setup

Run commands from this package directory:

```bash
cd contracts/confidential-wrapper/test/foundry
make setup     # forge soldeer install (incl. forge-fhevm, pinned in soldeer.toml)
make build     # forge build
```

## Running tests

| Task | Command | Notes |
| ---- | ------- | ----- |
| Live fork run | `make fork-test` | Forks mainnet at the block pinned in `config/fork.json`. Reads the RPC (see below). |
| Deployed-batcher run | `make fork-test-batcher` | Same fork, `test/batcher` under the `batcher` profile. |
| Ad-hoc block | `FORK_BLOCK=<n> make fork-test` | Overrides the pinned block for one run. |

Test cases are isolated: each `test_*` starts from its own `setUp()` state; mutations do not
leak across tests or files.

`make fork-test` resolves `ETHEREUM_MAINNET_FORK_RPC_URL` via
`script/utils/resolve-fork.sh`: the process environment first (CI injects it from a GitHub
secret), then `contracts/confidential-wrapper/.env` for local dev (see `.env.example`). CI runs
`make fork-test` against the archive node on pushes to `main`, manual dispatch, and PRs from
branches in this repo; fork PRs skip the whole job, since GitHub withholds the secret from them.

## Fork block

The fork block lives in `config/fork.json` and is resolved by
`script/utils/resolve-fork.sh`, so CI and local runs fork the same state. This matters
because the suite asserts against real mainnet state — a `config/blacklist-seeds.json` address
removed from a token's blacklist would break an unpinned run.

Precedence: `FORK_BLOCK` (ad-hoc override) → `config/fork.json` → chain tip when
`ethereumMainnet.block` is `null`. Bump the pin (and refresh the deny-list seeds if the run then
fails) when the suite should cover newer state.

## Deny-list config

USDC, USDT, XAUT, and TGBP carry on-chain deny lists. Two small committed files drive the
deny-list tests:

- `config/blacklist-interfaces.json` — the bool-returning `getter` selector per token
  (USDC `isBlacklisted(address)`, USDT `isBlackListed(address)`, XAUT `isBlocked(address)`,
  TGBP `isBanned(address)`). Read by `test/BaseForkTest.t.sol`.
- `config/blacklist-seeds.json` — a handful of known-denied addresses per token, used as test
  vectors. The suite reads each seed's deny-list slot from the live fork and asserts the token
  reports it denied. These are real addresses denied at the forked block. Adding a token is a
  one-entry edit to each file.

## Deployed-batcher suite

`test/batcher` runs the deployed Confidential DeFi batchers against the candidate wrapper
implementation. The batchers are read from mainnet, not deployed by the tests, so the suite checks
the exact non-upgradeable bytecode a wrapper upgrade must support.

Run it with:

```
make fork-test-batcher 
```

It uses the `batcher` Foundry profile, which enables
`isolate = true` and keeps the regular `make fork-test` target scoped to the wrapper suite.

Addresses live in `config/batchers.json`.

The harness mutates fork storage to repoint the deployed batchers at the local fhEVM host and clear
mainnet ciphertext handles that cannot be decoded locally. If a storage-layout guard fails, rederive
the deployed layout before changing any `vm.store` slot.

## Layout

| Path | Purpose |
| ---- | ------- |
| `test/BaseForkTest.t.sol` | `FhevmTest` harness: enumerate registry wrappers, repoint FHE config at the local host, shared token/KMS helpers |
| `test/WrapperFlows.t.sol` | Per-wrapper wrap, confidential transfer, unwrap/finalize, ERC-1363 receiver path |
| `test/DenyList.t.sol` | Local block/unblock, owner gating, blocked wrap guard |
| `test/UnderlyingDenyList.t.sol` | Underlying deny-list selectors vs. token code and known blacklisted mainnet addresses |
| `test/Upgrade.t.sol` | Upgrades every live proxy onto the HEAD impl and asserts storage/enablement invariants |
| `test/batcher/IVaultBatcher.sol` | Slice of the deployed batchers' ABI these tests drive |
| `test/batcher/BatcherForkBase.t.sol` | Harness for the deployed batchers |
| `test/batcher/BatcherFlows.t.sol` | Wiring guard, deposit/redeem round trip, operator join and quit, empty-batch dispatch |
| `test/batcher/BatcherDenyList.t.sol` | Deny-list and pause behavior seen through a batcher |
| `script/utils/resolve-fork.sh` | Resolves the fork target: RPC URL from the environment or `.env`, block from `FORK_BLOCK` or `config/fork.json` |
| `script/utils/check-batcher-manifest.sh` | Fails when `config/batchers.json` drifts from the upstream deployment manifest |
| `config/fork.json` | Pinned mainnet fork block |
| `config/blacklist-interfaces.json` | Per-token deny-list getter selectors |
| `config/blacklist-seeds.json` | Per-token known-denied test-vector addresses |
| `config/batchers.json` | Deployed batcher, wrapper and vault addresses |

## Troubleshooting

- `ETHEREUM_MAINNET_FORK_RPC_URL is not set`: export the archive RPC or set it in
  `contracts/confidential-wrapper/.env` (see `.env.example`).
- `missing underlying token code`: the archive node did not return code for that address at the
  forked block; check the RPC and the pinned `FORK_BLOCK`.
- `seeded address not denied by real token state`: a `config/blacklist-seeds.json` address is no
  longer denied at the forked block; refresh the seed.
- `MISMATCH <key>` from `check-batcher-manifest.sh`: the batchers were redeployed upstream; copy the
  new addresses into `config/batchers.json` and re-run `make fork-test-batcher`.
- `batcher: unexpected ACL` / `unexpected batcher layout`: the deployed batcher no longer matches
  what the harness assumes (FHE config or `BatcherConfidential` storage slots). Re-derive it (see
  below) rather than relaxing the guard — it is the only thing keeping the `vm.store` writes honest.

### Re-deriving the batcher storage layout

`BATCHES_SLOT` in `test/batcher/BatcherForkBase.t.sol` is the one hand-derived constant in the
suite. Read it off the **deployed** contract, which resolves the verified source from Etherscan and
prints the layout with live values:

```bash
cast storage 0x324EA89FD3784036673BfE6Ffee2334A088F40Cc \
  --rpc-url "${MAINNET_RPC_URL}" \
  --etherscan-api-key "${ETHERSCAN_API_KEY}" \
  --block 25582172
```

Prefer this over reading the layout out of upstream source, which can
drift from the mainnet deployment.

## How it works

### FHE on a live fork

The deployed wrappers point their FHE config at the real Zama mainnet coprocessor (compute
happens off-chain), so a bare fork can't produce usable ciphertext/decryptions. Zama's
[`forge-fhevm`](https://github.com/zama-ai/forge-fhevm) closes the gap:

- The inherited `FhevmTest.setUp()` deploys the local fhEVM host stack (at canonical addresses)
  and records executor logs into an in-memory plaintext DB.
- `BaseForkTest.setUp()` then repoints each wrapper's three FHE config slots at those local host
  addresses and **zeroes the cached total-supply handle** (a mainnet handle has no entry in the
  local plaintext DB, so the first local mint/burn rebuilds it against the local executor).
- `finalizeUnwrap` verifies a scalar `abi.encode(uint64)` payload, so tests use
  `buildDecryptionProof(handle, abi.encode(cleartext))` rather than the generic
  `publicDecrypt(handles)` proof (which signs `abi.encode(uint256[])`).

### Coverage guards

The in-test coverage guards (`assertGt(configured, 0)`, `assertGt(exercised, 0)`,
`assertGt(wrappers.length, 0)`, and the `missing token code` assertions) ensure the fork run
isn't silently under-covering: if a wrapper, token, or code path the tests expect is absent
from the forked state, the guard fails rather than passing vacuously.
