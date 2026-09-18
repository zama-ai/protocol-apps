# Deploy the confidential wrapper pauser (runbook)

This runbook arms the confidential wrappers of one chain with a `ConfidentialWrapperPauser`, following
P-RFC-006 "Confidential Wrapper Pausing". Repeat it per chain, in this order: Sepolia, Ethereum, Polygon Amoy,
Polygon. Rehearse a pause and an unpause on Sepolia before arming Ethereum.

Related: [Pausing](../pausing.md) · [Deploy wrapper runbook](deploy-wrapper-runbook.md) ·
[`contracts/confidential-wrapper-pauser`](../../contracts/confidential-wrapper-pauser/README.md)

## Roles

| Actor                                                    | Reached how                                                                               | Time to act   |
| -------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ------------- |
| Roster member (`pausers()`)                              | one signer calls `pause(address[])`                                                       | minutes       |
| Governance (owner of the pauser, owner of every wrapper) | proposal + vote, then `unpause()` per wrapper, `addPauser` / `removePauser` on the roster | hours to days |

Pausing is reversible and moves no funds, so the roster is sized for availability. Unpausing is a governance
action on each wrapper, never on the pauser contract.

## Inputs per chain

| Chain    | Governance (pauser owner and wrapper owner)                  | Registry (enumerated by the tasks)           |
| -------- | ------------------------------------------------------------ | -------------------------------------------- |
| Ethereum | Protocol DAO `0xB6D69D5F334d8B97B194617B53c6aB62f8681Ef3`    | `0xeb5015fF021DB115aCe010f23F55C2591059bBA0` |
| Sepolia  | Protocol DAO `0x08e8a84c3c8c7cba165B1adcf67Ae4639eF84f52`    | `0x2f0750Bbb0A246059d80e94c454586a7F27a128e` |
| Polygon  | Governance Safe `0xeF0645fE2f53aE04d750d5C578BbDAd6cE5Afe55` | `0xc8908569868758dAF814B5a8b96bBc44D1653d54` |
| Amoy     | Amoy Safe `0xF0b1FE5DecfFe400fb141BBEAF9B181bCF76E3Cb`       | `0xF486c3D4F4562760A43883e72E8D6f6Cf2EFdA94` |

These values are committed in `contracts/confidential-wrapper-pauser/config/networks.json`; the deploy script
refuses another owner unless explicitly overridden. The pauser contract itself has no registry dependency: the
registry is what the proposal and assertion tasks enumerate to find every wrapper of the chain.

The day-one roster is decided per environment (mainnet: the Fireblocks signer accounts; testnet: the testnet DAO
members). The addresses live in the internal wallet registry and are passed as `PAUSER_INITIAL_PAUSERS`.

## Step 0 — Rehearse on a fork

```bash
cd contracts/confidential-wrapper-pauser/test/foundry
make setup
make fork-test NETWORK=<sepolia|ethereum|polygon|amoy>
```

The suite deploys the pauser, has governance call `setPauser` on every registered wrapper, pauses everything from
one roster member and unpauses from governance, against the live state of the chain.

## Step 1 — Deploy (permissionless)

```bash
cd contracts/confidential-wrapper-pauser
cp .env.example .env   # fill PRIVATE_KEY/MNEMONIC, <NETWORK>_RPC_URL, ETHERSCAN_API_KEY, PAUSER_OWNER_ADDRESS
                       # (governance above), PAUSER_INITIAL_PAUSERS (JSON array)
npx hardhat deploy --network <network>
npx hardhat task:verifyConfidentialWrapperPauser --address <pauser> --network <network>
```

Checklist:

- [ ] `owner()` returns the chain's governance and `pendingOwner()` is the zero address
- [ ] `pausers()` returns exactly the agreed roster
- [ ] source verified on Etherscan (Blockscout / Sourcify best-effort)
- [ ] address recorded in `protocol-registry` (type "wrapper pauser", with its owner) and in `docs/addresses/`
- [ ] `docs/pausing.md` lists the new pauser for the chain

## Step 2 — Governance arms the wrappers

Generate the actions from the registry at proposal time; never hard-code the wrapper list.

```bash
npx hardhat task:setPauserProposal --pauser <pauser> --network <network> --out out/<network>-setPauser.json
```

The task refuses to build anything unless `<pauser>` holds a `ConfidentialWrapperPauser` owned by the chain's
governance (zero address, EOA, wrong contract, wrong owner), and warns on a pending ownership transfer or an empty
roster. The payload holds one `setPauser(<pauser>)` action per valid wrapper (`to`, `value`, `data`). Enter them:

- **Ethereum / Sepolia:** as actions of one Aragon proposal, see
  [Creating Ethereum proposals](../governance/creating-proposals-ethereum.md).
- **Polygon / Amoy:** as a remote proposal from the Ethereum / Sepolia DAO
  ([Creating remote proposals](../governance/creating-proposals-remote.md)) or, as a fallback, as a Safe
  transaction batch signed by the local multisig.

Reviewers verify: every `to` is a wrapper listed in the registry, every `data` equals
`cast calldata "setPauser(address)" <pauser>`, and the pauser's `pausers()` is the approved roster.

## Step 3 — Assert

```bash
npx hardhat task:checkPausers --pauser <pauser> --expected-pausers <0xA,0xB,...> --network <network>
```

Exit code 0 means every registered wrapper reports `pauser() == <pauser>` and `owner() == governance`, the pauser's
owner is governance and the roster matches. Run the same command on a schedule across chains as the drift check: a
wrapper whose owner drifted could not be unpaused, re-armed or upgraded by governance.

## Step 4 — Rehearse on Sepolia (before Ethereum)

1. A roster member calls `pause(address[])` with every Sepolia wrapper; check `paused()` and the `Paused` events.
2. Governance passes an `unpause()` proposal for every wrapper; record the elapsed restoration time in the RFC.
3. `task:checkPausers` is green again.

## Incident use

- **Pause:** any roster member calls `pause(address)` or `pause(address[])` on the chain's pauser. `WrapperPaused`
  confirms each wrapper; `WrapperAlreadyPaused` means it was already halted (not a failure, the single form does not
  revert on it); `WrapperPauseFailed` (batch) or `PauseFailed` (single) means that wrapper is still running and needs
  attention. The three events carry `account`, the roster member whose call it was, so on-call knows who acted
  without fetching the transaction. Its `errorData` is the wrapper's own revert (`SenderNotPauser`: not armed with this pauser; anything
  else: its `paused()` or `pause()` reverted, look at the wrapper). The batch never stops on a wrapper that rejects
  the call or cannot be read.
- **Pick the targets from the registry.** Build the batch from `task:checkPausers` output or the registry's
  `getTokenConfidentialTokenPairs()`, never from a token list: the pauser calls every entry as a wrapper. An address
  with no `paused()` (an underlying token pasted instead of its wrapper) is reported as failed with empty
  `errorData`; one that answers `paused()` with nothing (a typo, an EOA, a contract with a silent fallback) aborts
  the whole call; and a contract with a permissive fallback (WETH-style `deposit()`) can burn most of the
  transaction's gas before it is reported as failed. Re-send a batch without the offending entry; nothing else is
  affected.
- **What a pause does not stop:** an unwrap burnt before the pause cannot settle (`finalizeUnwrap` reverts
  `EnforcedPause`) until governance unpauses; underlying tokens already inside the wrapper stay there.
- **Unpause:** governance proposal with `unpause()` on each affected wrapper.
- **Roster change:** governance proposal with `addPauser(account)` / `removePauser(account)` on the pauser. Both are
  no-ops on an existing / missing member, so a batch listing an account twice still executes.
- **Owner change:** `transferOwnership(newOwner)` by governance, then `acceptOwnership()` by the new owner
  (`Ownable2Step`); until accepted, governance stays the owner and can nominate someone else, or the zero address
  to cancel. `renounceOwnership` is disabled: an ownerless pauser would have a roster nobody can rotate.

## Monitoring

Alert on, per chain: `Paused` / `Unpaused` on any wrapper (P0), `PauserUpdated` with a value other than the chain's
pauser, `PauserAdded` / `PauserRemoved` on the pauser that do not match an approved roster change,
`OwnershipTransferStarted` / `OwnershipTransferred` on the pauser, and `WrapperPauseFailed` (page: a wrapper an
operator tried to stop is still running; `account` says which roster member).
