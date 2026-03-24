# ProtocolStaking Invariant Fuzz Testing

Invariant and stateful fuzz testing for the `ProtocolStaking` contract using Foundry.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js (v20+)
- npm

## Installation & Setup

From the repository root, install the required Node dependencies (OpenZeppelin, etc.):

```bash
cd contracts/staking
npm install
forge install foundry-rs/forge-std --no-git
```

## Test Structure

Tests use a **handler pattern**: a handler contract wraps ProtocolStaking, bounds fuzzed inputs, and tracks ghost state. Invariants run after each handler call in a fuzz sequence.

We separate our invariant rules into three distinct categories to handle EVM state constraints:

1. **Global Invariants**: Checked via invariant_* functions in the test contract after every sequence step. These check system-wide accounting rules. (**ProtocolStakingInvariantTest.t**)

2. **Transition Invariants**: Checked via the `assertTransitionInvariants` modifier directly inside the Handler contract. These compare State A (before an action) to State B (after an action) to ensure monotonicity (values only going up/down as expected). (**ProtocolStakingHandler**)

3. **Equivalence Invariants**: Verify that two different execution paths to the same logical outcome produce identical on-chain state. Checked inline in the handler using `vm.snapshotState()` to fork execution, run both paths, and compare results. (**ProtocolStakingHandler**)

### Handler

[`handlers/ProtocolStakingHandler.sol`](handlers/ProtocolStakingHandler.sol)

- Wraps ProtocolStaking actions: `stake`, `unstake`, `claimRewards`, `release`, `warp`, `setRewardRate`, `addEligibleAccount`, `removeEligibleAccount`, `setUnstakeCooldownPeriod`, `unstakeThenWarp`
- Bounds inputs (e.g. `amount ≤ balance`, `actorIndex ∈ [0, actors.length)`)
- Tracks ghost state: `ghost_totalStaked`, `ghost_accumulatedRewardCapacity`, `ghost_eligibleAccounts`, `ghost_claimed`, etc.
- Exposes equivalence scenarios: `stakeEquivalenceScenario`, `unstakeEquivalenceScenario`

### Invariant Test Contract

[`ProtocolStakingInvariantTest.t.sol`](ProtocolStakingInvariantTest.t.sol)

- Defines invariants via `invariant_*` functions
- Uses `targetContract` and `targetSender` to direct the fuzzer's actions
- Invariants are checked after every handler call in the fuzz sequence

## Invariants

We separate our testing rules into three distinct categories:

### 1. Global Invariants

Checked via `invariant_*` functions in the main test contract after every handler call.

#### Total supply bounded by reward rate

Token issuance never exceeds the authorized emission:

```
zama.totalSupply()
  ≤ ghost_initialTotalSupply
  + ghost_accumulatedRewardCapacity   // Σ(δT_i × rewardRate_i), the sum of rewards allowed to be distributed for a given period, updated on every warp
  + ghost_truncationOps               // 1 wei tolerance per weight-decrease op (see Reward Debt System)
```

#### Total staked weight

The on-chain weight register matches the sum of eligible-account weights:

```
protocolStaking.totalStakedWeight()
  == Σ weight(protocolStaking.balanceOf(account))   // summed over all eligible accounts only
```
Ineligible accounts hold staked balance but contribute zero weight.

#### Reward debt conservation

The virtual accounting system stays balanced within rounding tolerance:

```
LHS = Σ _paid[account]              -- per-account already-credited amount
    + Σ earned(account)              -- per-account claimable rewards

RHS = _totalVirtualPaid()            -- global sum of all virtualPaid entries
    + historicalRewards()            -- cumulative rewards ever distributed

TOL = ghost_maxEligibleAccounts      -- static upper bound on simultaneously eligible accounts
    + ghost_dilutionOps              -- weight-increase ops that compound phantom wei by ≤1 per event

|LHS − RHS| ≤ TOL
```
Both sums range over all actors. All contract references are on `protocolStaking`. See the Reward Debt System section for the tolerance derivation.

#### Pending withdrawals solvency

The staking contract holds enough tokens to cover all queued withdrawals:

```
zama.balanceOf(address(protocolStaking))
  ≥ Σ protocolStaking.awaitingRelease(account)   // summed over all actors
```

#### Staked funds solvency

Every token an actor ever staked is accounted for, per account:

```
ghost_totalStaked[account]            // ghost: cumulative tokens staked by this account (handler)
  == protocolStaking.balanceOf(account)         // currently staked (shares → tokens)
   + protocolStaking.awaitingRelease(account)   // pending withdrawal, cooldown not yet elapsed
   + ghost_totalReleased[account]               // ghost: cumulative tokens already released (handler)
```
Checked independently for every actor.

#### Unstake queue monotonicity

The checkpoint trace for each account is internally consistent:

```
For all consecutive checkpoints (j-1, j) in _unstakeRequests[account]:
  key[j]   ≥ key[j-1]                          // timestamps are non-decreasing
  value[j] ≥ value[j-1]                         // cumulative shares are non-decreasing
```
`value` is a **cumulative** share total, not an incremental amount. When an unstake arrives at the same
block timestamp as the prior checkpoint it is updated in-place (same key, higher value). When it arrives
later a new checkpoint is appended (higher key). Both cases must preserve monotonicity across the full
history.

### 2. Transition Invariants

Because Foundry reverts the EVM state after evaluating `invariant_*` functions, transition checks (State A vs. State B) are executed natively inside the Handler using the `assertTransitionInvariants` modifier.

#### Claimed + claimable never decreases

For every account, across any handler action:

```
PRE  = ghost_claimed[account] + earned(account)    -- snapshot before the action
POST = ghost_claimed[account] + earned(account)    -- snapshot after the action

POST + 1 ≥ PRE
```
The 1 wei tolerance accounts for a single `earned()` floor truncation per pool update.

#### Awaiting release never decreases
```
protocolStaking.awaitingRelease(account) is non-decreasing until release() is explicitly called by that account.
```
`awaitingRelease(account)` is defined as `_unstakeRequests[account].latest() - _released[account]`. Calling
the function also implicitly enforces that `_released[account] ≤ latest unstake checkpoint` — if that
invariant were violated the subtraction would underflow and revert, which `fail_on_revert = true` would
surface as a test failure.


#### Earned is zero after claim
```
protocolStaking.earned(ghost_lastClaimedActor) == 0
```
`claimRewards` sets `ghost_lastClaimedActor` to the claiming account. The modifier checks this immediately
after the action and clears the flag. Guards on the zero address so non-claim steps are unaffected.

### 3. Equivalence Scenarios

These ensure that complex or batched actions result in the exact same mathematical state as singular actions. They utilize vm.snapshotState() and are checked inline inside the Handler.

#### Stake equivalence
```
stake(a + b) ≡ stake(a) + stake(b)
  shares: exactly equal   (1:1 mint, no share-conversion ratio)
  weight: exactly equal   (same balance ⟹ same weight)
  earned: equal ± 2 wei   (path B has one extra pool update, introducing at most 1 wei rounding error)
```

#### Unstake equivalence
```
unstake(initialStake - targetStake) ≡ unstake(initialStake) - stake(targetStake)
  shares: exactly equal
  weight: exactly equal
  earned: equal ± 2 wei // rounding tolerance 
```

## Running Tests

### 0. Install dependencies

From the repository root:

```bash
cd contracts/staking
npm install
forge install foundry-rs/forge-std --no-git
```

### 1. Run all invariant tests

From `contracts/staking`:

```bash
npm test:fuzz
```

Or directly with forge:

```bash
forge test
```

### 2. Run with verbose output

```bash
npm test:fuzz:verbose
```

Or:

```bash
forge test -vvv
```

### 3. Run a single invariant

```bash
forge test --match-contract ProtocolStakingInvariantTest --match-test invariant_UnstakeEquivalence
```

Replace `invariant_UnstakeEquivalence` with any invariant name (e.g. `invariant_RewardDebtConservation`, `invariant_StakeEquivalence`).

### Configuration

[`foundry.toml`](../../foundry.toml)

## Coverage

### 1. Generate coverage (Foundry)

From `contracts/staking`:

```bash
forge coverage
```

### 2. Generate LCOV report

```bash
forge coverage --report lcov
```

This writes `lcov.info` in the current directory.

### 3. Generate HTML coverage report

Install `genhtml` (from `lcov` package):

- **macOS:** `brew install lcov`
- **Ubuntu/Debian:** `apt install lcov`

Then:

```bash
forge coverage --report lcov
genhtml lcov.info -o coverage
```

### 4. View coverage report

Open the HTML report:

```bash
open coverage/index.html
```

The report is in `contracts/staking/coverage/index.html` when run from `contracts/staking`.
