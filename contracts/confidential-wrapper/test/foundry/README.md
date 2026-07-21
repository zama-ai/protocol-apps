# Foundry Mainnet-Fork Tests: Confidential Wrappers

Foundry tests that exercise the **live** Confidential Wrappers deployed on Ethereum mainnet.
`BaseForkTest` enumerates every valid wrapper from the on-chain
`ConfidentialTokenWrappersRegistry`, and the suite checks:

- direct wrap, confidential transfer, unwrap, finalize, and ERC-1363 receiver flows;
- per-wrapper deny-list behavior (owner gating, block/unblock, blocked-wrap guard);
- configured underlying-token deny-list selectors against the deployed underlying token code;
- underlying-token deny-list gating against real mainnet state, including known
  blacklisted mainnet addresses.

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

## Layout

| Path | Purpose |
| ---- | ------- |
| `test/BaseForkTest.t.sol` | `FhevmTest` harness: enumerate registry wrappers, repoint FHE config at the local host, shared token/KMS helpers |
| `test/WrapperFlows.t.sol` | Per-wrapper wrap, confidential transfer, unwrap/finalize, ERC-1363 receiver path |
| `test/DenyList.t.sol` | Local block/unblock, owner gating, blocked wrap guard |
| `test/UnderlyingDenyList.t.sol` | Underlying deny-list selectors vs. token code and known blacklisted mainnet addresses |
| `script/utils/resolve-fork.sh` | Resolves the fork target: RPC URL from the environment or `.env`, block from `FORK_BLOCK` or `config/fork.json` |
| `config/fork.json` | Pinned mainnet fork block |
| `config/blacklist-interfaces.json` | Per-token deny-list getter selectors |
| `config/blacklist-seeds.json` | Per-token known-denied test-vector addresses |

## Troubleshooting

- `ETHEREUM_MAINNET_FORK_RPC_URL is not set`: export the archive RPC or set it in
  `contracts/confidential-wrapper/.env` (see `.env.example`).
- `missing underlying token code`: the archive node did not return code for that address at the
  forked block; check the RPC and the pinned `FORK_BLOCK`.
- `seeded address not denied by real token state`: a `config/blacklist-seeds.json` address is no
  longer denied at the forked block; refresh the seed.

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
