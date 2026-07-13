# Staking deployment runbook

> Deploys the Zama Protocol staking system (see [`staking.md`](../staking.md)) to any EVM
> network: two `ProtocolStaking` roots (KMS + Coprocessor), `N` `OperatorStaking` pools
> (each with an auto-deployed `OperatorRewarder`), registers pool eligibility, wires the
> staking token's minting permission, and hands ownership to the DAO.
>
> All commands run from `contracts/staking/` and take `--network <NETWORK>`.

## Placeholders

| Placeholder | Meaning |
| --- | --- |
| `<NETWORK>` | The Hardhat network name (e.g. `mainnet`, `testnet`, `hoodi`) |
| `<RPC_URL>` / `<CHAIN_ID>` | RPC endpoint and chain id for `<NETWORK>` |
| `PROTOCOL_DEPLOYER_ADDRESS` | Wallet that deploys and initially owns the contracts |
| `DAO_ADDRESS` | Protocol DAO governance — final owner / `MANAGER_ROLE` holder |
| `SETUP_MULTISIG` | Multisig that executes calls on behalf of the DAO (accept transfer, grant minter) |
| `ZAMA_TOKEN_ADDRESS` | The staking/reward ERC-20 (real ZAMA token, or a testnet mock) |
| `N_COPRO` / `N_KMS` | Number of Coprocessor / KMS operator pools |

---

## Requirements

| Input | Where to get it |
| --- | --- |
| `PRIVATE_KEY` for `PROTOCOL_DEPLOYER_ADDRESS` | DFNS / internal secrets |
| RPC URL for `<NETWORK>` | Infura / Alchemy / internal node / public endpoint |
| `ETHERSCAN_API_KEY` | Etherscan dashboard (only for optional source verification) |
| `ZAMA_TOKEN_ADDRESS` | Existing ZAMA token address, or deploy a mock (Phase 1) |
| `DAO_ADDRESS`, `SETUP_MULTISIG` | [Addresses directory](../addresses/README.md) for the target chain |
| Native gas token | Fund `PROTOCOL_DEPLOYER_ADDRESS` before starting |

---

## What gets deployed

| Contract | Kind | Count | Notes |
| --- | --- | --- | --- |
| `ProtocolStaking` | UUPS proxy + impl | 2 | KMS + Coprocessor roots |
| `OperatorStaking` | UUPS proxy + impl | `N_COPRO + N_KMS` | One pool per operator per role |
| `OperatorRewarder` | Immutable | one per pool | Deployed + started inside `OperatorStaking.initialize` (`contracts/OperatorStaking.sol:150`) |
| `ERC20Mock` | Token | 0 or 1 | Testnet only — the mock staking/reward token (Phase 1) |

Operator share-token naming (rule from [`staking.md`](../staking.md)): symbol
`stZAMA-<name>-<role>`, name `<name> Staked ZAMA (<role>)`, where `<role>` is `KMS` or
`Coprocessor`.

---

## Network setup

Add `<NETWORK>` to `hardhat.config.ts` under `networks` (and, for source verification, an
`etherscan.customChains` entry). The existing `hoodi` entry is a worked example:

```ts
// networks
hoodi: {
  url: process.env.HOODI_RPC_URL || '',
  accounts,
  chainId: 560048,
},
// etherscan.customChains
{ network: 'hoodi', chainId: 560048, urls: { apiURL: 'https://api.etherscan.io/v2/api', browserURL: 'https://hoodi.etherscan.io' } },
```

---

## Phase 0 — Configure `.env`

Copy `.env.example` to `.env` and fill it in for `<NETWORK>`:

```dotenv
PRIVATE_KEY=<key for PROTOCOL_DEPLOYER_ADDRESS>
ETHERSCAN_API_KEY=<optional, for verification>
<NETWORK>_RPC_URL=<RPC_URL>

# Staking / reward token — real ZAMA token, or the mock deployed in Phase 1
ZAMA_TOKEN_ADDRESS=<ZAMA_TOKEN_ADDRESS>
# Final owner / manager
DAO_ADDRESS=<DAO_ADDRESS>

# ── ProtocolStaking (both roots) ──
# Cooldown: 604800 (7 days) on mainnet, 180 (3 min) on testnet
PROTOCOL_STAKING_COPRO_TOKEN_NAME="Staked ZAMA (Coprocessor)"
PROTOCOL_STAKING_COPRO_TOKEN_SYMBOL=stZAMA-Coprocessor
PROTOCOL_STAKING_COPRO_VERSION=1
PROTOCOL_STAKING_COPRO_COOLDOWN_PERIOD=<7d mainnet | 180 testnet>
PROTOCOL_STAKING_COPRO_REWARD_RATE=<tokens per second, 18 decimals>
PROTOCOL_STAKING_KMS_TOKEN_NAME="Staked ZAMA (KMS)"
PROTOCOL_STAKING_KMS_TOKEN_SYMBOL=stZAMA-KMS
PROTOCOL_STAKING_KMS_VERSION=1
PROTOCOL_STAKING_KMS_COOLDOWN_PERIOD=<7d mainnet | 180 testnet>
PROTOCOL_STAKING_KMS_REWARD_RATE=<tokens per second, 18 decimals>

# ── OperatorStaking — one indexed block per operator (0 .. N-1) ──
NUM_OPERATOR_STAKING_COPRO=<N_COPRO>
NUM_OPERATOR_STAKING_KMS=<N_KMS>
# For each Coprocessor operator i in 0..N_COPRO-1:
OPERATOR_STAKING_COPRO_TOKEN_NAME_i="<name> Staked ZAMA (Coprocessor)"
OPERATOR_STAKING_COPRO_TOKEN_SYMBOL_i="stZAMA-<name>-Coprocessor"
OPERATOR_REWARDER_COPRO_BENEFICIARY_i="<operator beneficiary>"
OPERATOR_REWARDER_COPRO_MAX_FEE_i=2000   # 20% max (basis points)
OPERATOR_REWARDER_COPRO_FEE_i=<initial fee bps>
# For each KMS operator j in 0..N_KMS-1: same block with KMS/ names/symbols
```

---

## Phase 1 — Staking token

**Real token (mainnet / production):** set `ZAMA_TOKEN_ADDRESS` in `.env` to the deployed
ZAMA token. Skip to Phase 2. Grant its minter role in Phase 6.

**Testnet mock (optional):** the staking contracts need a token whose `mint` they can
call. `ERC20Mock` exposes an unrestricted public `mint(address,uint256)` that doubles as a
delegator faucet, so no minter grant (Phase 6) is needed for the mock.

```bash
npx hardhat task:deployERC20MockAndMintDeployer --network <NETWORK>
```
- Copy the printed `ERC20Mock` address into `.env` as `ZAMA_TOKEN_ADDRESS`

> The mock's per-call cap `maxMintAmount` (base units) defaults to `1e6 * 10^18` and is
> **owner-settable** (deployer owns it): `setMaxMintAmount(baseUnits)` — pass
> `type(uint256).max` to make it unlimited, `0` to block minting; read it via
> `maxMintAmount()`.

---

## Phase 2 — Local dry run (before touching `<NETWORK>`)

```bash
npm run compile
npx hardhat test          # unit tests
npx hardhat test:tasks    # deploys mock → protocol → operator on in-memory net + task tests
```

---

## Phase 3 — Deploy the ProtocolStaking contracts

```bash
npx hardhat task:deployAllProtocolStakingContracts --network <NETWORK>
```

At deploy the `governor` and `MANAGER_ROLE` are both set to the deployer for
configuration; they move to the DAO in Phase 8.

---

## Phase 4 — Deploy the OperatorStaking contracts

```bash
npx hardhat task:deployAllOperatorStakingContracts --network <NETWORK>
```
- `N_COPRO` Coprocessor pools + `N_KMS` KMS pools deployed (each prints its `OperatorRewarder`)

---

## Phase 5 — Register operators as eligible

```bash
npx hardhat task:addAllOperatorsAsEligible --network <NETWORK>
```
Calls `addEligibleAccount(operatorStaking)` once per pool on that pool's own root: the
Coprocessor pools on the Coprocessor `ProtocolStaking`, the KMS pools on the KMS
`ProtocolStaking` — `N_COPRO + N_KMS` transactions total. Requires `MANAGER_ROLE` (still
held by the deployer at this point).

---

## Phase 6 — Grant the token's `MINTER_ROLE` to the ProtocolStaking contracts

**Real token only** (skip for the testnet mock — its `mint` is public). Because
`claimRewards` mints rewards, both ProtocolStaking roots must hold the ZAMA token's
`MINTER_ROLE`. There is no staking-repo task for this — it is a call on the token
contract, executed by `SETUP_MULTISIG` on behalf of `DAO_ADDRESS`. See the [Creating Proposals Runbook](../governance/creating-proposals-ethereum.md):

- `grantRole(role, account)` on `ZAMA_TOKEN_ADDRESS`, twice:
  - `role`: `0x9f2df0fed2c77648de5860a4cc508cd0818c85b8b8a1ab4ceeef8d981c8956a6`
    (`keccak256("MINTER_ROLE")`)
  - `account`: the Coprocessor ProtocolStaking, then the KMS ProtocolStaking

---

## Phase 7 — Configure operator fees

Initial `feeBasisPoints` / `maxFeeBasisPoints` are set at deploy time from the
`OPERATOR_REWARDER_*_FEE_*` / `_MAX_FEE_*` env vars. Afterwards each operator's
beneficiary can adjust their own pool via `OperatorRewarder.setFee(basisPoints)`
(beneficiary-only; capped at the max, ≤ 20% / `2000` bps).

---

## Phase 8 — Transfer ownership to the DAO

> For an ephemeral testnet where the deployer intentionally keeps `owner` / `MANAGER_ROLE`
> (e.g. to keep calling `addEligibleAccount`), **skip this phase**.

**Manager role** — grant to the DAO, then renounce the deployer's:
```bash
npx hardhat task:grantProtocolStakingManagerRolesToDAO --network <NETWORK>
npx hardhat task:renounceProtocolStakingManagerRolesFromDeployer --network <NETWORK>
```

**Governor role** (`DEFAULT_ADMIN_ROLE`, 2-step) — begin transfer, then the DAO accepts:
```bash
npx hardhat task:beginTransferProtocolStakingGovernorRolesToDAO --network <NETWORK>
```
- [ ] `SETUP_MULTISIG` calls `acceptDefaultAdminTransfer()` on both ProtocolStaking
      contracts on behalf of `DAO_ADDRESS`
- [ ] `owner()` on both roots returns `DAO_ADDRESS`

---

**Etherscan source verification:**
```bash
npx hardhat task:verifyERC20Mock --contract-address <MOCK_ADDR> --network <NETWORK>  # testnet mock only
npx hardhat task:verifyAllProtocolStakingContracts --network <NETWORK>
npx hardhat task:verifyAllOperatorStakingContracts --network <NETWORK>
npx hardhat task:verifyOperatorRewarder --network <NETWORK>
```

---

## Phase 10 — Record addresses

- Add the deployed addresses to `docs/addresses/<...>.md` for the target chain
      (token, both ProtocolStaking proxies, all OperatorStaking proxies, all
      OperatorRewarders).
- (For Contributors) Update the `protocol-registry-internal` SSOT.

---
