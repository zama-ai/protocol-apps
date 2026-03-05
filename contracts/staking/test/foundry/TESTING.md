# ProtocolStaking Testing

Invariant and fuzz testing for the ProtocolStaking contract using Foundry.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`)
- Node.js (v20+)
- pnpm or npm

## Installation

From the repository root:

```bash
cd contracts/staking
pnpm install
```

## Test Structure

Tests use a **handler pattern**: a handler contract wraps ProtocolStaking, bounds fuzzed inputs, and tracks ghost state. Invariants run after each handler call in a fuzz sequence.

### Handler

[`test/foundry/handlers/ProtocolStakingHandler.sol`](test/foundry/handlers/ProtocolStakingHandler.sol)

- Wraps ProtocolStaking actions: `stake`, `unstake`, `claimRewards`, `release`, `warp`, `setRewardRate`, `addEligibleAccount`, `removeEligibleAccount`, `setUnstakeCooldownPeriod`, `unstakeThenWarp`
- Bounds inputs (e.g. `amount ≤ balance`, `actorIndex ∈ [0, actors.length)`)
- Tracks ghost state: `ghost_totalStaked`, `ghost_accumulatedRewardCapacity`, `ghost_eligibleAccounts`, `ghost_claimed`, etc.
- Exposes equivalence scenarios: `stakeEquivalenceScenario`, `unstakeEquivalenceScenario`

### Invariant Test Contract

[`test/foundry/ProtocolStakingInvariantTest.t.sol`](test/foundry/ProtocolStakingInvariantTest.t.sol)

- Defines invariants via `invariant_*` functions
- Uses `targetContract` and `targetSelector` to limit which handler methods are fuzzed
- Invariants are checked after every handler call in the fuzz sequence

## Invariants

### Total supply bounded by reward rate: `invariant_TotalSupplyBoundedByRewardRate`

```
totalSupply ≤ initialTotalSupply + Σ(δT_i × rewardRate_i)
```

### Total staked weight: `invariant_TotalStakedWeightEqualsEligibleWeights`

```
totalStakedWeight() == Σ weight(balanceOf(account)) over eligible accounts
```

### Reward debt conservation: `invariant_RewardDebtConservation`

```
Σ _paid[account] + Σ earned(account) == _totalVirtualPaid + historicalRewards()
earned(account) == 0 after claimRewards(account)
```

### Claimed + claimable never decreases: `invariant_ClaimedPlusClaimableNeverDecreases`

```
claimed + earned is non-decreasing per account
```

### Awaiting release never decreases: `invariant_AwaitingReleaseNeverDecreases`

```
awaitingRelease(account) is non-decreasing until release() is called
```

### Unstake queue monotonicity: `invariant_UnstakeQueueMonotonicity`

```
_unstakeRequests checkpoints: non-decreasing timestamps and cumulative amounts
_released[account] ≤ _unstakeRequests[account].latest() → awaitingRelease() never reverts
```

### Pending withdrawals solvency: `invariant_PendingWithdrawalsSolvency`

```
balanceOf(protocolStaking) ≥ Σ awaitingRelease(account)
```

### Staked funds solvency: `invariant_StakedFundsSolvency`

```
totalStaked == balanceOf(account) + awaitingRelease(account) + released
```

### Stake equivalence: `invariant_StakeEquivalence`

```
stake(a1 + a2) ≈ stake(a1) + stake(a2)  (shares, weight, earned within tolerance)
```

### Unstake equivalence: `invariant_UnstakeEquivalence`

```
partial unstake to target ≈ unstake all + stake(target)  (shares, weight, earned within tolerance)
```

## Running Tests

### 0. Install dependencies

From the repository root:

```bash
cd contracts/staking
pnpm install
```

### 1. Run all invariant tests

From `contracts/staking`:

```bash
pnpm test:fuzz
```

Or directly with forge:

```bash
forge test
```

### 2. Run with verbose output

```bash
pnpm test:fuzz:verbose
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

[`foundry.toml`](foundry.toml):

- `test = 'test/foundry'`
- `[invariant] runs = 256`, `depth = 100`

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
