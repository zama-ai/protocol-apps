# Foundry Tests: Confidential Wrappers

Suites:

- **`test/`** — mainnet-fork tests against the **live** deployed wrappers. Needs an archive RPC.
- **`test/msca/local/`** — treasury proof of concept. Local only: no RPC, no secret.
- **`test/msca/fork/`** — the same deployment sequence against the live cUSDC wrapper; runs with the
  fork tests. See [MSCA treasury suite](#msca-treasury-suite).

## Mainnet-fork suite

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
| Live fork run | `make fork-test` | Forks mainnet at the block pinned in `config/fork.json`. Reads the RPC (see below). Excludes `test/msca/local`. |
| Ad-hoc block | `FORK_BLOCK=<n> make fork-test` | Overrides the pinned block for one run. |
| MSCA treasury run | `make msca-test` | Local only — no RPC. Runs `test/msca/local` and nothing else. |
| Live cUSDC migration | `make fork-msca-test` | The `test/msca/fork` suite alone, on the same fork target as `fork-test`. |

A bare `forge test` runs both and so fails without a fork URL; use the targets above.

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
| `src/msca/`, `test/msca/` | The MSCA treasury suite, below |

## MSCA treasury suite

Moves the wrapper's underlying reserve into a Circle ERC-6900 account controlled by the Protocol DAO.

```bash
make setup      # also fetches Circle's accounts and the EntryPoint
make msca-test
```

`test/msca/local` never touches the network. `test/msca/fork` runs with the mainnet-fork suites.

| Path | Purpose |
| ---- | ------- |
| `src/msca/ConfidentialWrapperTreasury.sol` | Reserve-hook overrides, ERC-1363 path, views, migration |
| `src/msca/fixtures/` | Local 0.8.24 helpers (`ManifestHasher`, drain plugin); compiled by `profile.circle` |
| `src/msca/interfaces/` | Circle ERC-6900 surface, redeclared at `^0.8.27` |
| `test/msca/local/TreasuryFixture.t.sol` | Wrapper, fhEVM, EntryPoint, deployment sequence |
| `test/msca/local/{Msca,Sca}TreasuryBase.t.sol` | Treasury as MSCA / SCA |
| `test/msca/local/Treasury{Migration,Settlement,Governance}.t.sol` | Shared behaviour |
| `test/msca/local/{Msca,Sca}Treasury.t.sol` | Concrete suites and per-product differences |
| `test/msca/fork/TreasuryMigrationFork.t.sol` | Deployment sequence against live cUSDC (`make fork-test`) |

Shared suites run twice, once per Circle product.

### Live cUSDC migration

Binds to the live proxy at `0xe978F22157048E5DB8E5d07971376e86671672B2` and the live EntryPoint,
applies the same FHE injection as `test/BaseForkTest.t.sol`, then hands over the account, grants the
allowance, and upgrades with `reinitializeV4WithTreasury`.

- a pre-upgrade holder settles from the treasury; the whole live reserve moves in the upgrade
- a full wrap -> confidential transfer -> unwrap -> finalize cycle, entirely after the upgrade
- an operator-funded wrap unwraps by the holder alone
- an unwrap requested before the upgrade still settles after it
- the upgrade preserves handle permissions, and the treasury acquires none (see below)

`make fork-msca-test` runs this suite alone. `make fork-test` includes it. `make msca-test` excludes
it. The suites sit in `local/` and `fork/` because forge path globs are recursive.

### Initializer version

The migration is the wrapper's V4 reinitializer. Live proxies are on V3.

The inherited one-argument `reinitializeV4` is tombstoned: both consume version 4, and the bare one
would leave the wrapper at V4 with no treasury.

`ConfidentialWrapper.initialize` also lands on 4, so local suites rewind a fresh proxy to 3 with
`_rewindToV3`. The fork suite asserts the live version is below 4 instead.

### FHE permissions

The treasury needs no ACL grants, and the migration re-grants nothing. Every grant the wrapper makes
goes to one of three parties:

| Call site | Grantee |
| ---- | ------- |
| `ERC7984Upgradeable._update` — `FHE.allowThis` on balances, total supply, transferred amount | the wrapper proxy |
| `ERC7984Upgradeable._update` — `FHE.allow(ptr, from/to)` | the cToken holder |
| `wrap` / `confidentialTransfer*` — `FHE.allowTransient(…, msg.sender)` | the caller, for that transaction only |
| `_unwrap` — `FHE.makePubliclyDecryptable` | nobody: a public-decryption flag on the handle |
| `ConfidentialWrapper._addObserver` — `delegateUserDecryptionWithoutExpiration` | the observer |

The reserve holder is not one of them. All four reserve touchpoints — `_reserve`, `_reserveBalance`,
`_depositUnderlyingFrom`, `_payUnderlying` — are plain ERC-20, and the underlying has no handle
attached, so there is nothing to carry over when it moves.

The wrapper's own grants are keyed to the **proxy** address, which an implementation swap does not
change, so they survive the upgrade untouched.
`test_LiveCusdc_UpgradePreservesHandlePermissionsAndTheTreasuryGetsNone` asserts both directions: the
holder's and the wrapper's grants on a pre-upgrade handle are intact and still usable afterwards,
while the treasury has none and settles a payout anyway.

One consequence worth knowing: if cTokens are ever sent *to* the treasury address, `_update` grants
it a balance handle like any other holder, and recovering them means driving `unwrap` through the
account's `execute`. Out of scope here — the RFC scopes the treasury as a non-user of the wrapper —
and untested.

### Reserve hooks

`ConfidentialWrapperTreasury` overrides `_reserve`, `_depositUnderlyingFrom`, and `_payUnderlying`
instead of reimplementing `wrap`, `finalizeUnwrap`, and `inferredTotalSupply`. `onTransferReceived`
is copied: the ERC-1363 callback already delivered tokens here, and the remainder must reach the
treasury before minting.

### Compiler boundary

Circle pins `0.8.24` and the wrapper is `^0.8.27`. Default `solc_version` is `0.8.27` and skips
`src/msca/fixtures/`. `FOUNDRY_PROFILE=circle forge build` compiles Circle's package plus those
fixtures at 0.8.24 into `out-circle/` so the default 0.8.27 build does not wipe them. Makefile
targets that need Circle artifacts run that profile first. ERC-6900 v0.8 is skipped: it needs
`@erc6900/reference-implementation`, which is not a dependency here, and the suite only deploys v0.7.

### Scope

The treasury holds plain underlying and never touches a cToken, FHE handle, or the ACL. Live KMS
decryption and a real bundler are also out of scope.

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
