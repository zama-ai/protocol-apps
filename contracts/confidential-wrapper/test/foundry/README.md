# Foundry Mainnet-Fork Tests: Confidential Wrappers

Foundry tests that exercise the **live** Confidential Wrappers deployed on Ethereum mainnet.
`BaseForkTest` enumerates every valid wrapper from the on-chain
`ConfidentialTokenWrappersRegistry`, and the suite checks:

- direct wrap, confidential transfer, unwrap, finalize, and ERC-1363 receiver flows;
- per-wrapper deny-list behavior (owner gating, block/unblock, blocked-wrap guard);
- configured underlying-token deny-list selectors against the deployed underlying token code;
- underlying-token deny-list gating against real mainnet state, including known
  blacklisted mainnet addresses.

Tests run **offline by default**: they load a committed Anvil state fixture rather than
contacting mainnet. See [How it works](#how-it-works) for the mechanics behind that.

## Setup

Run commands from this package directory:

```bash
cd contracts/confidential-wrapper/test/foundry
npm run setup     # installs soldeer deps (incl. forge-fhevm, pinned in soldeer.toml)
npm run build     # forge build
```

`make bake` uses the parent package's Node dependencies (`ethers`) in addition to Foundry. If
the parent package has not been installed yet, run `npm install` from
`contracts/confidential-wrapper` first.

## Running tests

| Task | Command | Notes |
| ---- | ------- | ----- |
| Offline run (default / local) | `make fork-test` | Loads the committed fixture into a blank Anvil node, runs `forge test`, then tears Anvil down. No RPC needed. |
| Live debug against archive | `[FORK_BLOCK=<n>] make fork-test-live` | Forks mainnet directly. Reads the RPC (see below). |
| Live-vs-offline parity | `make regression` | Runs the suite live (pinned to `manifest.forkBlock`) and offline, asserts identical per-test results. Network-bound. |
| Stop local Anvil | `make teardown-anvil` | Stops this package's `.anvil.pid` process and any Anvil listener on port `8545`. |

Test cases are isolated: each `test_*` starts from its own `setUp()` state; mutations do not
leak across tests or files.

The network-bound targets (`fork-test-live`, `regression`, `bake`) resolve
`CONFIDENTIAL_WRAPPER_UPGRADE_TEST_RPC_URL` via `script/utils/resolve-fork-url.sh`: the process
environment first (CI injects it from a GitHub secret), then `contracts/confidential-wrapper/.env`
for local dev (see `.env.example`). CI runs `make fork-test-live` against the archive node on pushes
to `main`, manual dispatch, and PRs from branches in this repo; fork PRs skip the whole job, since
GitHub withholds the secret from them. Offline `make fork-test` remains the local default.

## Baking the fixture

The fixture consists of **three committed files** under `deployments/mainnet-fork/`:
`read-cache.json` (forge's captured fork read cache — the source), `anvil-state.json` (raw
`anvil_dumpState` hex, derived from the read cache), and `manifest.json`.

`make bake` reads the archive RPC from `CONFIDENTIAL_WRAPPER_UPGRADE_TEST_RPC_URL` (environment or
`contracts/confidential-wrapper/.env`, see `.env.example`) and does three things:

1. **Warm** — runs the whole suite against a live mainnet fork pinned to a block
   (`FORK_BLOCK` if set, otherwise the current archive head). forge lazily reads exactly the
   code and storage the tests touch and flushes it to `~/.foundry/cache/rpc/mainnet/<block>`.
2. **Capture** — copies that cache file to `deployments/mainnet-fork/read-cache.json`.
3. **Convert** — `script/convert-cache.js` replays the read cache into a blank Anvil overlay
   (which `anvil_dumpState` *can* serialize) and writes `anvil-state.json` + `manifest.json`.

Because the fixture is captured by the tests themselves, it is complete by construction: it
contains exactly what the suite reads, and nothing else. There is no per-contract storage-layout
knowledge in the tooling. A successful run rewrites all three files; commit them together, then
run `make fork-test` and `make regression`.

| Task | Command | When |
| ---- | ------- | ---- |
| Rebake fixture | `[FORK_BLOCK=<n>] make bake` | Contract upgrade, new wrapper, new/changed test coverage, blacklist drift, or a clean re-pin |

To add coverage for new state (a new wrapper, token, or code path), add the test, then rebake:
the warm-up run will read the new state and the converter will bake it automatically.

## Deny-list config

USDC, USDT, XAUT, and TGBP carry on-chain deny lists. Two small committed files drive the
deny-list tests:

- `config/blacklist-interfaces.json` — the bool-returning `getter` selector per token
  (USDC `isBlacklisted(address)`, USDT `isBlackListed(address)`, XAUT `isBlocked(address)`,
  TGBP `isBanned(address)`). Read by `test/BaseForkTest.t.sol`.
- `config/blacklist-seeds.json` — a handful of known-denied addresses per token, used as test
  vectors. The warm-up run reads each seed's deny-list slot, so the converter captures the
  exact word mainnet holds; offline, `getter(seed)` returns the same result. These are real
  addresses denied at the committed fork block. Adding a token is a one-entry edit to each file.

No blacklist membership is enumerated or scanned: the deny-list storage the tests need is
whatever the warm-up run reads, captured like all other state.

## Anvil teardown

Most targets clean up their own Anvil process, but interrupted runs can leave port `8545`
occupied. Use the teardown helper before rebaking or starting a fixture node:

```bash
make teardown-anvil
```

The helper first stops the PID recorded in `.anvil.pid`, then checks TCP port `8545`. It only
stops a port listener when the command line looks like Anvil. For unusual cases, inspect first:

```bash
lsof -nP -iTCP:8545 -sTCP:LISTEN
```

Then use the explicit script form if needed:

```bash
./script/teardown-anvil.sh --port 8545
```

`--force` exists for non-standard process names, but use it only after confirming the listener
is disposable.

## Layout

| Path | Purpose |
| ---- | ------- |
| `test/BaseForkTest.t.sol` | `FhevmTest` harness: enumerate registry wrappers, repoint FHE config at the local host, shared token/KMS helpers |
| `test/WrapperFlows.t.sol` | Per-wrapper wrap, confidential transfer, unwrap/finalize, ERC-1363 receiver path |
| `test/DenyList.t.sol` | Local block/unblock, owner gating, blocked wrap guard |
| `test/UnderlyingDenyList.t.sol` | Underlying deny-list selectors vs. token code and known blacklisted mainnet addresses |
| `script/convert-cache.js` | Converts the committed read cache into `anvil-state.json` + `manifest.json`; used by `make bake` |
| `script/lib/anvil.js` | Shared Anvil process + JSON-RPC helpers |
| `script/utils/list-wrappers.js` | One-time test banner listing the wrappers under test from the loaded fixture registry |
| `script/utils/load-state.sh` | Small Anvil fixture loader used by `make anvil`, `make fork-test`, and `make regression` |
| `script/utils/assert-parity.js` | Compares two `forge test --json` runs; used by `make regression` |
| `script/teardown-anvil.sh` | Safe cleanup helper for `.anvil.pid` and Anvil listeners on port `8545` |
| `config/blacklist-interfaces.json` | Per-token deny-list getter selectors |
| `config/blacklist-seeds.json` | Per-token known-denied test-vector addresses |
| `deployments/mainnet-fork/` | Committed `read-cache.json` + `anvil-state.json` + `manifest.json` |

## Troubleshooting

- `could not instantiate forked environment with provider localhost`: Anvil is not running
  or failed to bind port `8545`. Use `make fork-test` rather than invoking `forge test` directly.
- `Loaded state has no registry code`: the fixture is missing or stale; run `make bake`.
- `missing underlying token code` / `not baked`: the warm-up run did not read that state.
  Ensure a test exercises the path, then rebake.
- `baked address not denied by real token state`: a `config/blacklist-seeds.json` address is
  no longer denied at the fork block; refresh the seed and rebake.

## How it works

### FHE offline

The deployed wrappers point their FHE config at the real Zama mainnet coprocessor (compute
happens off-chain), so a bare fork can't produce usable ciphertext/decryptions. Zama's
[`forge-fhevm`](https://github.com/zama-ai/forge-fhevm) closes the gap:

- The inherited `FhevmTest.setUp()` deploys the local fhEVM host stack (at canonical addresses)
  and records executor logs into an in-memory plaintext DB.
- `BaseForkTest.setUp()` then repoints each wrapper's three FHE config slots at those local host
  addresses and **zeroes the cached total-supply handle** (a mainnet handle has no entry in the
  local plaintext DB, so the first local mint/burn rebuilds it against the local executor). This
  runs identically during the live warm-up and the offline run, so the committed state stays pure
  captured mainnet and both modes see the same wrapper config.
- `finalizeUnwrap` verifies a scalar `abi.encode(uint64)` payload, so tests use
  `buildDecryptionProof(handle, abi.encode(cleartext))` rather than the generic
  `publicDecrypt(handles)` proof (which signs `abi.encode(uint256[])`).

### The committed fixture

`anvil_dumpState` serializes **only Anvil's local overlay**, never forge's lazy fork-cache
reads. So instead of hand-materializing state, `make bake` warms forge's fork read cache by
running the suite live, then `script/convert-cache.js` replays that cache into a blank Anvil
(via `anvil_setCode` / `anvil_setBalance` / `anvil_setNonce` / `anvil_setStorageAt`) and dumps
the overlay. The read cache holds raw storage words, so the converter needs no per-contract
layout knowledge — USDC's packed balance+blacklist word, proxy implementation pointers, the
registry pair array, and every deny-list slot the tests read are all captured verbatim.

If a loaded fixture reads a value as zero that should come from mainnet, it means the warm-up run
never read that slot: add or adjust the test that should exercise it, then rebake.

### Regression parity

`make regression` runs the whole suite against the live fork (pinned to `manifest.forkBlock`) and
against the committed offline fixture, then `script/utils/assert-parity.js` asserts the two runs
produced identical per-test results and that both fully passed. The in-test coverage guards
(`assertGt(configured, 0)`, `assertGt(exercised, 0)`, `assertGt(wrappers.length, 0)`, and the
`missing token code` / `not baked` assertions) ensure the fixture isn't silently under-covering.
