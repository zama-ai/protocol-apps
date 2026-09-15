# ConfidentialWrapperPauser

Roster and circuit breaker for the confidential wrappers of one chain, as specified in P-RFC-006 "Confidential
Wrapper Pausing". One deployment per chain; governance points every wrapper's `setPauser` at it; any single roster
member can then pause one wrapper or all of them. Only addresses the chain's `ConfidentialTokenWrappersRegistry`
lists as valid wrappers are ever called, so a typo or a non-wrapper in a batch is reported, never executed.
Unpausing is not offered here: it stays `onlyOwner` on each wrapper, so pausing is fast (one signer) and restoring is
a governance action.

## Design

| Concern        | Implementation                                                                                                                                                                                  |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Admin          | The chain's governance (Protocol DAO on Ethereum and Sepolia, the local Safe on Polygon and Amoy) holds `DEFAULT_ADMIN_ROLE` under OpenZeppelin `AccessControlDefaultAdminRules`: single holder, moved only through `beginDefaultAdminTransfer` / `acceptDefaultAdminTransfer` after the configured delay, never granted or revoked directly; `owner()` (ERC-5313) returns it. |
| Roster         | `PAUSER_ROLE` of OpenZeppelin `AccessControlEnumerable`, administered by the default admin. The RFC ABI is kept as thin wrappers: `addPauser` / `removePauser` call `grantRole` / `revokeRole` (no-ops on an existing / missing member), `isPauser` calls `hasRole`, `pausers()` calls `getRoleMembers`. Roster changes emit `PauserAdded` / `PauserRemoved` next to `RoleGranted` / `RoleRevoked`, whichever path made them (including a member's own `renounceRole`); off-roster callers of `pause` get `SenderNotPauser`. Access checks are internal functions, not modifiers. |
| Registry gate  | The chain's `ConfidentialTokenWrappersRegistry` is fixed at deployment (`registry()`, immutable; the constructor refuses an address without code with `InvalidRegistry`). Every target is checked with `isConfidentialTokenValid` first: an address the registry does not list as a valid wrapper (never registered, or revoked) is reported with an ABI-encoded `WrapperNotRegistered(wrapper)` and never called, so a stray non-wrapper cannot burn the batch's gas. Everything the registry lists is a `ConfidentialWrapper` with the V4 pause API, so `paused()` and `pause()` are ordinary calls. |
| Pause one      | `pause(address)` — `SenderNotPauser` off-roster; `WrapperAlreadyPaused` event (no revert) when the wrapper already reports `paused()`; otherwise `PauseFailed(wrapper, errorData)` with the wrapper's own revert data (`SenderNotPauser(pauser)` when governance has not armed it with this contract yet) or `WrapperNotRegistered`. |
| Pause many     | `pause(address[])` — best effort, as the RFC specifies: every entry gets exactly one of `WrapperPaused`, `WrapperAlreadyPaused` or `WrapperPauseFailed(wrapper, errorData)`, and a failing entry never stops the rest. |
| Unpause        | Not here. `unpause()` is `onlyOwner` on every wrapper.                                                                                                                                          |
| Upgradeability | None (rule from `docs/governance.md`: pauser contracts are not upgradeable). Recovery is a redeploy plus a re-batched `setPauser` proposal.                                                     |

The ABI is the one specified in P-RFC-006, on top of the standard `AccessControl`, `AccessControlEnumerable` and `AccessControlDefaultAdminRules` surfaces. The wrapper side is reached through `IPausableWrapper` (`pause()`, `paused()`) and the registry through `IConfidentialTokenWrappersRegistry` (`isConfidentialTokenValid`); a unit test checks those selectors, and the mocks' whole surface, against the `ConfidentialWrapper` and `ConfidentialTokenWrappersRegistry` entries of `contracts/selectors.txt`, and the fork suite exercises the live wrappers and registry.

## Prerequisites

```bash
cp .env.example .env
```

Fill `PRIVATE_KEY` (or `MNEMONIC`), the RPC URL of the target network and `ETHERSCAN_API_KEY`. For a deployment, also
set `PAUSER_ADMIN_ADDRESS` (the default admin: the chain's governance, checked against `config/networks.json`),
`PAUSER_DEFAULT_ADMIN_DELAY` (seconds a scheduled admin transfer waits before it can be accepted) and
`PAUSER_INITIAL_PAUSERS` (JSON array, the agreed day-one roster; the zero address and duplicates are refused). The
registry the pauser gates on comes from `config/networks.json`; `PAUSER_REGISTRY_ADDRESS` overrides it for forks and
local runs.

## Testing

```bash
make test          # hardhat unit tests against the mocks
npm run coverage   # solidity-coverage + thresholds in .istanbul.yml
npm run lint       # solhint + prettier
```

### Fuzz and invariant tests

`test/foundry/test/unit` holds local Foundry property tests over the same mocks, no fork and no RPC: fuzzed
roster sequences, batches over random mixes of armed / unarmed / already-paused / reverting / unregistered
(code-less, WETH-style, revoked) targets, constructor inputs and delay changes (`PauserFuzz.t.sol`), a stateful
`StdInvariant` handler suite (`PauserInvariant.t.sol`, `PauserHandler.sol`) and regression tests for the gas drain
WETH-style targets caused before the registry gate (`PauserGasDrain.t.sol`). They run under the `unit` profile of
`test/foundry/foundry.toml`:

```bash
cd test/foundry
make setup                              # once: soldeer dependencies (forge-std, OpenZeppelin)
make unit-test                          # fuzz + invariants; MATCH=<pattern> narrows to one test
```

### Live fork rehearsal

`test/foundry` rehearses the whole migration against the live wrappers of a chain (deploy, `setPauser` on every
registered wrapper as governance, batch pause by one roster member, unpause by governance) without any FHE dependency.

```bash
cd test/foundry
make setup                              # forge soldeer install
make fork-test NETWORK=sepolia          # also: ethereum, polygon, amoy
```

The RPC URL is read from the env var named in `config/fork.json` (for example `SEPOLIA_RPC_URL`), first from the
environment and then from `../../.env`. `FORK_BLOCK=<n>` pins the fork block.

## Deployment (P-RFC-006 migration step 1)

```bash
npx hardhat deploy --network <ethereum|sepolia|polygon|amoy>
npx hardhat task:verifyConfidentialWrapperPauser --address <deployed-address> --network <network>
```

The deploy is permissionless. It gates the pauser on the network's registry from `config/networks.json` (checked to
have code) and refuses an admin that is not the network's governance in the same file unless
`PAUSER_ALLOW_ADMIN_MISMATCH=true`.

## Arming the wrappers (migration step 2) and asserting the result

```bash
# One setPauser(pauser) action per valid wrapper in the chain's registry, ready for the Aragon app / Safe builder
npx hardhat task:setPauserProposal --pauser <pauser-address> --network <network> --out out/<network>-setPauser.json

# After the proposal executed: every wrapper reports pauser() == <pauser-address>, roster and admin as expected
npx hardhat task:checkPausers --pauser <pauser-address> --expected-pausers 0xA,0xB --network <network>
```

`task:checkPausers` exits non-zero on any mismatch, so it doubles as the scheduled roster-drift check across chains.
Both tasks accept `--registry` to override the registry and `--include` for wrappers that are not (yet) registered.

See `docs/deployment/deploy-wrapper-pauser-runbook.md` for the full per-chain procedure.
