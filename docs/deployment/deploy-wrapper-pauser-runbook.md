# Deploy the confidential wrapper pauser (runbook)

This runbook arms the confidential wrappers of one chain with a `ConfidentialWrapperPauser`, following
P-RFC-006 "Confidential Wrapper Pausing". Repeat it per chain, in this order: Sepolia, Ethereum, Polygon Amoy,
Polygon. Rehearse a pause and an unpause on Sepolia before arming Ethereum.

Related: [Pausing](../pausing.md) · [Deploy wrapper runbook](deploy-wrapper-runbook.md) ·
[`contracts/confidential-wrapper-pauser`](../../contracts/confidential-wrapper-pauser/README.md)

## Roles

| Actor                                                            | Reached how                                                                               | Time to act   |
| ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ------------- |
| Roster member (`pausers()`)                                      | one signer calls `pause(address[])`                                                       | minutes       |
| Governance (default admin of the pauser, owner of every wrapper) | proposal + vote, then `unpause()` per wrapper, `addPauser` / `removePauser` on the roster | hours to days |

Pausing is reversible and moves no funds, so the roster is sized for availability. Unpausing is a governance
action on each wrapper, never on the pauser contract.

## Inputs per chain

| Chain    | Governance (pauser admin and wrapper owner)                  | Registry                                     |
| -------- | ------------------------------------------------------------ | -------------------------------------------- |
| Ethereum | Protocol DAO `0xB6D69D5F334d8B97B194617B53c6aB62f8681Ef3`    | `0xeb5015fF021DB115aCe010f23F55C2591059bBA0` |
| Sepolia  | Protocol DAO `0x08e8a84c3c8c7cba165B1adcf67Ae4639eF84f52`    | `0x2f0750Bbb0A246059d80e94c454586a7F27a128e` |
| Polygon  | Governance Safe `0xeF0645fE2f53aE04d750d5C578BbDAd6cE5Afe55` | `0xc8908569868758dAF814B5a8b96bBc44D1653d54` |
| Amoy     | Amoy Safe `0xF0b1FE5DecfFe400fb141BBEAF9B181bCF76E3Cb`       | `0xF486c3D4F4562760A43883e72E8D6f6Cf2EFdA94` |

These values are committed in `contracts/confidential-wrapper-pauser/config/networks.json`; the deploy script
refuses another admin unless explicitly overridden. The registry is fixed at deployment (`registry()`, immutable):
only the wrappers it lists as valid can be paused, any other address is reported as `WrapperNotRegistered` without
being called. The deploy also fixes the default admin transfer delay
(`PAUSER_DEFAULT_ADMIN_DELAY`, seconds): a scheduled admin transfer can only be accepted once it has elapsed, and the
admin can raise it later with `changeDefaultAdminDelay`.

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
cp .env.example .env   # fill PRIVATE_KEY/MNEMONIC, <NETWORK>_RPC_URL, ETHERSCAN_API_KEY, PAUSER_ADMIN_ADDRESS
                       # (governance above), PAUSER_DEFAULT_ADMIN_DELAY (seconds), PAUSER_INITIAL_PAUSERS (JSON array)
npx hardhat deploy --network <network>
npx hardhat task:verifyConfidentialWrapperPauser --address <pauser> --network <network>
```

Checklist:

- [ ] `defaultAdmin()` (also `owner()`) returns the chain's governance, `pendingDefaultAdmin()` is unset and
      `defaultAdminDelay()` is the agreed delay
- [ ] `pausers()` returns exactly the agreed roster
- [ ] `registry()` returns the chain's `ConfidentialTokenWrappersRegistry` from the table above
- [ ] source verified on Etherscan (Blockscout / Sourcify best-effort)
- [ ] address recorded in `protocol-registry` (type "wrapper pauser", with its admin) and in `docs/addresses/`
- [ ] `docs/pausing.md` lists the new pauser for the chain

## Step 2 — Governance arms the wrappers

Generate the actions from the registry at proposal time; never hard-code the wrapper list.

```bash
npx hardhat task:setPauserProposal --pauser <pauser> --network <network> --out out/<network>-setPauser.json
```

The payload holds one `setPauser(<pauser>)` action per valid wrapper (`to`, `value`, `data`). Enter them:

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

Exit code 0 means every registered wrapper reports `pauser() == <pauser>`, the default admin is governance and the
roster matches. Run the same command on a schedule across chains as the roster-drift check.

## Step 4 — Rehearse on Sepolia (before Ethereum)

1. A roster member calls `pause(address[])` with every Sepolia wrapper; check `paused()` and the `Paused` events.
2. Governance passes an `unpause()` proposal for every wrapper; record the elapsed restoration time in the RFC.
3. `task:checkPausers` is green again.

## Incident use

- **Pause:** any roster member calls `pause(address)` or `pause(address[])` on the chain's pauser. `WrapperPaused`
  confirms each wrapper; `WrapperAlreadyPaused` means it was already halted (not a failure, the single form does not
  revert on it); `WrapperPauseFailed` (batch) or `PauseFailed` (single) means that wrapper is still running and needs
  attention. Its `errorData` is the wrapper's own revert (`SenderNotPauser`: not armed with this pauser) or
  `WrapperNotRegistered` (the address is not a valid wrapper in the chain's registry: a typo, an underlying token
  pasted instead of its wrapper, or a revoked wrapper; such an address is never called). The batch never stops on a
  failing entry.
- **What a pause does not stop:** an unwrap burnt before the pause cannot settle (`finalizeUnwrap` reverts
  `EnforcedPause`) until governance unpauses; underlying tokens already inside the wrapper stay there.
- **Unpause:** governance proposal with `unpause()` on each affected wrapper.
- **Roster change:** governance proposal with `addPauser(account)` / `removePauser(account)` on the pauser (thin
  wrappers over `grantRole` / `revokeRole(PAUSER_ROLE, account)`; a member can also step down with `renounceRole`).
- **Admin change:** `beginDefaultAdminTransfer(newAdmin)` by governance, then, once `defaultAdminDelay()` has
  elapsed, `acceptDefaultAdminTransfer()` by the new admin (`AccessControlDefaultAdminRules`); `cancelDefaultAdminTransfer()`
  aborts a pending one. `DEFAULT_ADMIN_ROLE` cannot be granted or revoked directly, and renouncing it needs a matured
  transfer to the zero address, after which the roster is frozen for good.

## Monitoring

Alert on, per chain: `Paused` / `Unpaused` on any wrapper (P0), `PauserUpdated` with a value other than the chain's
pauser, `PauserAdded` / `PauserRemoved` (and the matching `RoleGranted` / `RoleRevoked`) on the pauser that do not match an
approved roster change, `DefaultAdminTransferScheduled` / `DefaultAdminDelayChangeScheduled`, and
`WrapperPauseFailed` (page: a wrapper an operator tried to stop is still running).
