# ConfidentialWrapperPauser

Roster and circuit breaker for the confidential wrappers of one chain, as specified in P-RFC-006 "Confidential
Wrapper Pausing". One deployment per chain; governance points every wrapper's `setPauser` at it; any single roster
member can then pause one wrapper or all of them. Unpausing is not offered here: it stays `onlyOwner` on each
wrapper, so pausing is fast (one signer) and restoring is a governance action.

## Design

| Concern        | Implementation                                                                                                                                                                                  |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Owner          | The chain's governance (Protocol DAO on Ethereum and Sepolia, the local Safe on Polygon and Amoy), under OpenZeppelin `Ownable2Step`: ownership moves only through `transferOwnership` followed by the new owner's `acceptOwnership`; `renounceOwnership` is disabled (`RenounceOwnershipDisabled`), as on the wrappers. |
| Roster         | An OpenZeppelin `EnumerableSet` of addresses, edited by the owner with `addPauser` / `removePauser` (no-ops, without event, on an existing / missing member; the zero address is rejected with `ZeroAddressPauser`, by the constructor too), read with `isPauser` and `pausers()`. Changes emit `PauserAdded` / `PauserRemoved`; off-roster callers of `pause` get `SenderNotPauser`. |
| Pause one      | `pause(address)` — `SenderNotPauser` off-roster; `WrapperPaused(wrapper, account)` names the roster member who paused; `WrapperAlreadyPaused` event (no revert) when the wrapper already reports `paused()`; otherwise `PauseFailed(wrapper, errorData)` with the wrapper's own revert data (`SenderNotPauser(pauser)` when governance has not armed it with this contract yet, or the revert of a `paused()` that cannot be read). |
| Pause many     | `pause(address[])` — best effort, as the RFC specifies: every wrapper entry gets exactly one of `WrapperPaused`, `WrapperAlreadyPaused` or `WrapperPauseFailed(wrapper, account, errorData)`, each naming the calling roster member, and a wrapper that rejects the call, or whose `paused()` reverts, never stops the rest. |
| Targets        | Trusted. There is no allowlist and no low-level probing: a target is called as a `ConfidentialWrapper` (`paused()`, then `pause()`), so an address that answers `paused()` with nothing to decode (an EOA, a silent fallback) aborts the call, and one whose fallback fails (WETH-style `deposit()`) is reported as a failed wrapper after burning the gas it was handed. Picking valid targets is the roster member's responsibility; the runbook says how. Revoked registry entries are still wrappers (revocation only flips the registry flag) and are paused like the others. |
| Unpause        | Not here. `unpause()` is `onlyOwner` on every wrapper.                                                                                                                                          |
| Upgradeability | None (rule from `docs/governance.md`: pauser contracts are not upgradeable). Recovery is a redeploy plus a re-batched `setPauser` proposal.                                                     |

The ABI is the one specified in P-RFC-006, plus the `WrapperAlreadyPaused` event, an indexed `account` (the calling roster member) on the three pause outcome events and the `ZeroAddressPauser` error, on top of the standard `Ownable2Step` surface. The wrapper side is reached through `IPausableWrapper` (`pause()`, `paused()`); a unit test checks those selectors, and the mock's whole surface, against the `ConfidentialWrapper` entry of `contracts/selectors.txt`, and the fork suite exercises the live wrappers.

## Prerequisites

```bash
cp .env.example .env
```

Fill `PRIVATE_KEY` (or `MNEMONIC`), the RPC URL of the target network and `ETHERSCAN_API_KEY`. For a deployment, also
set `PAUSER_OWNER_ADDRESS` (the chain's governance, checked against `config/networks.json`) and
`PAUSER_INITIAL_PAUSERS` (JSON array, the agreed day-one roster; the zero address and duplicates are refused).

## Testing

```bash
make test          # hardhat unit tests against the mocks
npm run coverage   # solidity-coverage + thresholds in .istanbul.yml
npm run lint       # solhint + prettier
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

The deploy is permissionless. It refuses an owner that is not the network's governance in `config/networks.json`
unless `PAUSER_ALLOW_OWNER_MISMATCH=true`.

## Arming the wrappers (migration step 2) and asserting the result

```bash
# One setPauser(pauser) action per registered wrapper of the chain (revoked included), ready for the Aragon app / Safe builder
npx hardhat task:setPauserProposal --pauser <pauser-address> --network <network> --out out/<network>-setPauser.json

# After the proposal executed: every wrapper reports pauser() == <pauser-address>, roster and owner as expected
npx hardhat task:checkPausers --pauser <pauser-address> --expected-pausers 0xA,0xB --network <network>
```

Both tasks first check `--pauser` itself: it must hold a `ConfidentialWrapperPauser` owned by the chain's governance.
`task:setPauserProposal` refuses the zero address, an EOA, a wrong contract or a pauser owned by someone else, since
the resulting proposal would disarm or misarm every wrapper; `task:checkPausers` reports the same as failures.
`task:checkPausers` also checks every wrapper's `owner()` against governance (a wrapper transferred away could not be
unpaused or re-armed by it) and exits non-zero on any mismatch, so it doubles as the scheduled drift check across
chains. Both tasks enumerate the chain's `ConfidentialTokenWrappersRegistry` from `config/networks.json`; they accept
`--registry` and `--governance` to override it and `--include` for wrappers that are not (yet) registered. Revoked
registry entries are still wrappers (revocation only flips the registry flag, the wrapper keeps running and holding
funds), so both tasks arm and check them like the others and mark them `(revoked)` in their output and payload.

See `docs/deployment/deploy-wrapper-pauser-runbook.md` for the full per-chain procedure.
