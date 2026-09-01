# Foundry Fork Tests: Confidential Wrappers

Foundry tests that exercise the **live** Confidential Wrappers deployed on a supported chain.
`BaseForkTest` enumerates every valid wrapper from the on-chain
`ConfidentialTokenWrappersRegistry`, and the suite checks:

- direct wrap, confidential transfer, unwrap, finalize, and ERC-1363 receiver flows;
- per-wrapper deny-list behavior (owner gating, block/unblock, blocked-wrap guard);
- configured underlying-token deny-list selectors against the deployed underlying token code;
- underlying-token deny-list gating against real chain state, including known
  blacklisted addresses.

A second suite under `test/batcher` drives the **deployed** Confidential DeFi Gateway batchers
against the same candidate implementation, so a wrapper upgrade that breaks the batchers fails
here. See [Deployed-batcher suite](#deployed-batcher-suite).

Tests run against a **live fork**: `forge test --fork-url <archive RPC>` reads the code
and storage the tests touch directly from the archive node. The chain is selected with
`NETWORK` (default `ethereum`); see [Networks](#networks).

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
| Live fork run | `make fork-test` | Forks the network at latest - 50 by default (see [Fork block](#fork-block)). Reads the RPC (see below). |
| Deployed-batcher run | `make fork-test-batcher` | Same fork, `test/batcher` under the `batcher` profile. |
| Another network | `make fork-test NETWORK=polygon` | Any key in `config/fork.json`. |
| Ad-hoc block | `FORK_BLOCK=<n> make fork-test` | Pins one run to a specific block. |

Test cases are isolated: each `test_*` starts from its own `setUp()` state; mutations do not
leak across tests or files.

Each network is an `[rpc_endpoints]` alias in `foundry.toml` pointing at its RPC variable, e.g.
`ETHEREUM_MAINNET_FORK_RPC_URL`, which `forge` and `cast` resolve from the environment. CI sets
those variables from GitHub secrets; locally `script/utils/fork-test.sh` loads them from
`contracts/confidential-wrapper/.env` (see `.env.example`).

## Networks

`NETWORK` (default `ethereum`) selects the chain. It names an entry in `config/fork.json`, the
`[rpc_endpoints]` alias in `foundry.toml` that resolves its RPC URL, and the `config/<network>/`
directory holding that chain's deny-list and batcher files.

To add a network:

1. Add its entry to `config/fork.json` and its alias to `foundry.toml`'s `[rpc_endpoints]`.
2. Add a `config/<network>/` directory for the deny-list tokens and batchers it has, if any.
3. Add it to the matrix in `.github/workflows/contracts-confidential-wrapper-foundry-tests.yml`,
   with its RPC variable in the job `env` and the matching repository secret.

## Fork block

The fork block is optional and resolved by `script/utils/fork-test.sh`.

Precedence: `FORK_BLOCK` (ad-hoc override) → `config/fork.json` → latest - 50 when the selected
network's `block` is `null`, which is the committed default. Set `<network>.block` to an integer, or
export `FORK_BLOCK`, to pin a run while reproducing a failure.

## Deny-list config

One committed file per network, `config/<network>/blacklist-interfaces.json`, drives the deny-list tests. 

Each token entry carries:

- `getter` — the bool-returning selector the wrapper staticcalls (USDC `isBlacklisted(address)`,
  USDT `isBlackListed(address)`, etc.).
- `setter` / `authority` — used to freshly deny an address by pranking the token's own admin.
- `blacklisted` — a handful of real already-denied addresses used as test vectors. The suite reads
  each one's deny-list slot from the live fork and asserts the token still reports it denied, so
  they must remain denied at the forked block.

## Deployed-batcher suite

`test/batcher` runs the deployed Confidential DeFi batchers against the candidate wrapper
implementation. The batchers are read from the chain, not deployed by the tests, so the suite checks
the exact non-upgradeable bytecode a wrapper upgrade must support.

Run it with:

```
make fork-test-batcher 
```

It uses the `batcher` Foundry profile, which enables
`isolate = true` and keeps the regular `make fork-test` target scoped to the wrapper suite.

Addresses live in `config/<network>/batchers.json`.

The harness mutates fork storage to repoint the deployed batchers at the local fhEVM host and clear
live ciphertext handles that cannot be decoded locally. If a storage-layout guard fails, rederive
the deployed layout before changing any `vm.store` slot.

## Layout

| Path | Purpose |
| ---- | ------- |
| `test/BaseForkTest.t.sol` | `FhevmTest` harness: enumerate registry wrappers, repoint FHE config at the local host, shared token/KMS helpers |
| `test/WrapperFlows.t.sol` | Per-wrapper wrap, confidential transfer, unwrap/finalize, ERC-1363 receiver path |
| `test/DenyList.t.sol` | Local block/unblock, owner gating, blocked wrap guard |
| `test/UnderlyingDenyList.t.sol` | Underlying deny-list selectors vs. token code and known blacklisted addresses |
| `test/Upgrade.t.sol` | Upgrades every live proxy onto the HEAD impl and asserts storage, enablement and initializer-version invariants |
| `test/batcher/IVaultBatcher.sol` | Slice of the deployed batchers' ABI these tests drive |
| `test/batcher/BatcherForkBase.t.sol` | Harness for the deployed batchers |
| `test/batcher/BatcherFlows.t.sol` | Wiring guard, deposit/redeem round trip, operator join and quit, empty-batch dispatch |
| `test/batcher/BatcherDenyList.t.sol` | Deny-list and pause behavior seen through a batcher |
| `script/utils/fork-test.sh` | Runs `forge test` against a fork of `NETWORK`: loads its RPC variable from `.env` when unset, resolves the block from `FORK_BLOCK` or `config/fork.json` |
| `script/utils/check-batcher-manifest.sh` | Fails when `config/<network>/batchers.json` drifts from the upstream deployment manifest |
| `config/fork.json` | Per-network registry address and optional fork block pin (`null` = chain tip) |
| `config/<network>/blacklist-interfaces.json` | Per-token deny-list selectors and known-denied test-vector addresses |
| `config/<network>/batchers.json` | Deployed batcher, wrapper and vault addresses |

## Troubleshooting

- `missing underlying token code`: the archive node did not return code for that address at the
  forked block; check the RPC and the pinned `FORK_BLOCK`.
- `seeded address not denied by real token state`: a `blacklisted` address in the deny-list config
  is no longer denied at the forked block; refresh the seed. Runs default to the chain tip, so this
  tracks live chain state.
- `MISMATCH <key>` from `check-batcher-manifest.sh`: the batchers were redeployed upstream; copy the
  new addresses into `config/<network>/batchers.json` and re-run `make fork-test-batcher`.
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

The deployed wrappers point their FHE config at the real Zama coprocessor for their chain (compute
happens off-chain), so a bare fork can't produce usable ciphertext/decryptions. Zama's
[`forge-fhevm`](https://github.com/zama-ai/forge-fhevm) closes the gap:

- The inherited `FhevmTest.setUp()` deploys the local fhEVM host stack (at canonical addresses)
  and records executor logs into an in-memory plaintext DB.
- `BaseForkTest.setUp()` then repoints each wrapper's three FHE config slots at those local host
  addresses and **zeroes the cached total-supply handle** (a live handle has no entry in the
  local plaintext DB, so the first local mint/burn rebuilds it against the local executor).
- `finalizeUnwrap` verifies a scalar `abi.encode(uint64)` payload, so tests use
  `buildDecryptionProof(handle, abi.encode(cleartext))` rather than the generic
  `publicDecrypt(handles)` proof (which signs `abi.encode(uint256[])`).

### Coverage guards

The in-test coverage guards (`assertGt(configured, 0)`, `assertGt(exercised, 0)`,
`assertGt(wrappers.length, 0)`, and the `missing token code` assertions) ensure the fork run
isn't silently under-covering: if a wrapper, token, or code path the tests expect is absent
from the forked state, the guard fails rather than passing vacuously.
