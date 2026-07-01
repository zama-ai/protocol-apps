# Foundry Mainnet-Fork Tests: Confidential Wrappers

Foundry tests that exercise the **live** Confidential Wrappers deployed on Ethereum mainnet.
`BaseForkTest` enumerates every valid wrapper from the on-chain
`ConfidentialTokenWrappersRegistry`, and the suite checks:

- direct wrap, confidential transfer, unwrap, finalize, and ERC-1363 receiver flows;
- per-wrapper deny-list behavior (owner gating, block/unblock, blocked-wrap guard);
- configured underlying-token deny-list selectors against the deployed underlying token code;
- underlying-token deny-list gating against baked blacklist state, including known
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
| Offline run (default / CI) | `make test` | Loads the committed fixture into a blank Anvil node, runs `forge test`, then tears Anvil down. No RPC needed. |
| Live debug against archive | `[FORK_BLOCK=<n>] make test-live` | Forks mainnet directly. Reads the RPC from `.env` (see below). |
| Stop local Anvil | `make teardown-anvil` | Stops this package's `.anvil.pid` process and any Anvil listener on port `8545`. |

Test cases are isolated: each `test_*` starts from its own `setUp()` state; mutations do not
leak across tests or files.

## Baking the fixture

The fixture consists of **three committed files** under `deployments/mainnet-fork/`:
`anvil-state.json` (raw `anvil_dumpState` hex), `manifest.json`, and `blacklist-cache.json`.
Both bake commands read the archive RPC from `CONFIDENTIAL_WRAPPER_UPGRADE_TEST_RPC_URL` in
`contracts/confidential-wrapper/.env` (see `.env.example`); they exit early if it is unset.
`FORK_BLOCK` is optional. For `make bake`, it pins the fork block; without it Anvil forks the
current head. For `make bake-blacklists`, it pins the archive block to scan through; without it the
script scans through the archive head. A successful run rewrites all three files; commit them
together.

| Task | Command | When |
| ---- | ------- | ---- |
| Rebake fixture | `[FORK_BLOCK=<n>] make bake` | Contract upgrade, new wrapper, storage coverage change, or clean re-pin |
| Refresh blacklist only | `[FORK_BLOCK=<n>] make bake-blacklists` | Blacklist drift, contracts unchanged |

`make bake` auto-selects its strategy: **delta** when the fixture, `blacklist-cache.json`, and
`manifest.blacklistScannedBlock` are all present; otherwise **full**. Either way it starts a
fresh fork overlay, re-materializes the full contract base, re-pins `forkBlock`, and writes the
complete current blacklist set into the new fixture. Delta mode only shortens the blacklist log
scan by starting after each token's cached `lastScannedBlock`. To force a full historical
blacklist scan, delete `blacklist-cache.json` (or the fixture).

`make bake-blacklists` moves only blacklist data forward over the already-committed fixture; it
leaves `forkBlock` untouched and records `blacklistScannedBlock=<n>` in the manifest.
Use it only with a block at or after the sidecar's current `lastScannedBlock`; use `make bake`
for historical re-pins.

Re-run `make test` after any bake.

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

## Blacklist interface config

USDC, USDT, and XAUT carry on-chain blacklists. Each declares its interface **explicitly** in
`config/blacklist-interfaces.json`, the single source of truth read by the JS bake
(`script/bake.mjs`), the blacklist-only refresh path (`script/bake-blacklist.mjs`), and the fork
tests (`test/BaseForkTest.t.sol`). Tokens are keyed by address. Adding a blacklist-bearing token
is a one-entry config edit.

| Field | Meaning |
| ----- | ------- |
| `getter` | Bool-returning view selector, e.g. USDC `isBlacklisted(address)`, USDT `isBlackListed(address)`, XAUT `isBlocked(address)`. |
| `deployBlock` | First block with deployed token code. Full historical blacklist scans start here; if omitted, the bake falls back to binary-searching `eth_getCode`. |
| `baseSlot` | Optional mapping base slot. The bake validates `keccak256(probe, baseSlot)` against the getter trace; omit it when the base is discoverable in slots `0..255`. |
| `addEvent` / `removeEvent` | Add/remove log signatures scanned to reconstruct membership. |
| `addrIndexed` | `true` if the affected address rides in an event topic; `false` if in event data (USDT). |
| `encoding` | `word` (slot holds a whole-word `1`/`0`, e.g. USDT/XAUT) or `highBit` (flag in **bit 255** of a slot shared with the balance, e.g. USDC; written read-modify-write so the balance bits survive). |

Slot layout is config-validated against the declared getter trace. If `baseSlot` is omitted, the
bake tries simple mapping bases `0..255`; if `baseSlot` is present, the bake checks that
`keccak256(probe, baseSlot)` is one of the getter-touched storage slots.

## Layout

| Path | Purpose |
| ---- | ------- |
| `test/BaseForkTest.t.sol` | `FhevmTest` harness: enumerate baked registry wrappers and shared token/KMS helpers |
| `test/WrapperFlows.t.sol` | Per-wrapper wrap, confidential transfer, unwrap/finalize, ERC-1363 receiver path |
| `test/DenyList.t.sol` | Local block/unblock, owner gating, blocked wrap guard |
| `test/UnderlyingDenyList.t.sol` | Underlying deny-list selectors vs. baked token code and known blacklisted mainnet addresses |
| `script/bake.mjs` | Fixture discovery + materialization generator (full base + blacklist pass); used by `make bake` |
| `script/bake.test.mjs` | Unit tests for pure JS bake helpers (ABI decoding, mapping slots, blacklist folding) |
| `script/utils/list-wrappers.mjs` | One-time test banner that reads the loaded fixture registry and prints wrappers under test |
| `script/utils/load-state.sh` | Small Anvil fixture loader used by `make anvil` and `make test` after blank Anvil starts |
| `script/teardown-anvil.sh` | Safe cleanup helper for `.anvil.pid` and Anvil listeners on port `8545` |
| `script/bake-blacklist.mjs` | Standalone incremental blacklist-only refresh over the committed fixture; used by `make bake-blacklists` |
| `config/blacklist-interfaces.json` | Address-keyed blacklist interface config (getter/events/encoding); shared by the bake engine and the fork tests |
| `deployments/mainnet-fork/` | Committed `anvil-state.json` + `manifest.json` + `blacklist-cache.json` |

## Troubleshooting

- `could not instantiate forked environment with provider localhost`: Anvil is not running
  or failed to bind port `8545`. Use `make test` rather than invoking `forge test` directly.
- `Loaded state has no registry code`: the fixture is missing or stale; run `make bake`.
- `delegatecall 0x000...000` from an underlying token: its proxy implementation code was not
  materialized. Add a documented token-specific implementation slot only after a trace proves
  it is required.
- `baked address not denied by real token state`: `blacklist-cache.json` is out of sync with
  `anvil-state.json`. Re-run `make bake` or `make bake-blacklists` and commit both.

## How it works

### FHE offline

The deployed wrappers point their FHE config at the real Zama mainnet coprocessor (compute
happens off-chain), so a bare fork can't produce usable ciphertext/decryptions. Zama's
[`forge-fhevm`](https://github.com/zama-ai/forge-fhevm) closes the gap:

- `script/bake.mjs` points each baked wrapper's three FHE config slots at the local
  `forge-fhevm` host addresses and **zeroes the cached total-supply handle**. A mainnet handle has
  no entry in the local plaintext DB, so the first local mint/burn must rebuild it against the
  local executor.
- The inherited `FhevmTest.setUp()` initializes the local fhEVM host stack and plaintext DB that
  those baked wrapper slots target.
- `finalizeUnwrap` verifies a scalar `abi.encode(uint64)` payload, so tests use
  `buildDecryptionProof(handle, abi.encode(cleartext))` rather than the generic
  `publicDecrypt(handles)` proof (which signs `abi.encode(uint256[])`).

### The committed fixture

`anvil_dumpState` serializes **only the local overlay**, never lazy fork-cache reads. So an
account or slot survives `anvil_loadState` only if `script/bake.mjs` wrote it explicitly with
`anvil_setCode` / `anvil_setBalance` / `anvil_setStorageAt`. `bake.mjs` therefore materializes:

- registry proxy + implementation code, owner/initializer slots, the pair array, and
  token/wrapper lookup mappings;
- each registered wrapper's proxy + implementation code, owner/initializer slots, test-used
  metadata/storage, FHE config slots, and a zeroed cached total-supply handle;
- each underlying token's code, known proxy implementation code, and storage touched by
  configured static metadata/supply/ERC-165 calls;
- USDC's legacy ZeppelinOS implementation pointer at
  `keccak256("org.zeppelinos.proxy.implementation")` (mainnet USDC is not an EIP-1967 proxy);
- the blacklist membership of every blacklist-bearing underlying, so a loaded fixture
  reports the same denied/not-denied result the token would on mainnet.

The bake keeps source reads and overlay writes deliberately separate: source code/storage comes
from the configured archive RPC pinned to the fork block, access-list tracing runs against the
local fork before overlay writes, and persistence is written only through Anvil's `anvil_*`
methods.

If a loaded fixture reads a value as zero that should come from mainnet, add the specific
code/slot materialization to `bake.mjs` and rebake.

### Blacklist sidecar + incremental refresh

Blacklist membership mappings are sparse and live only in the lazy fork cache, so they must be
written explicitly like everything else. Because full histories are large, the sidecar is
**incremental and block-pinned** via `blacklist-cache.json`, which records per token the
`encoding`, resolved `baseSlot`, `lastScannedBlock`, and current blacklisted set.

`make bake` always builds a fresh overlay. In delta mode it reuses the sidecar set, scans only
add/remove events after `lastScannedBlock`, then writes the full resulting member set into the
fresh fixture. `make bake-blacklists` is different: it loads the already-committed fixture,
scans only new events, applies only the membership diff, and re-dumps.
