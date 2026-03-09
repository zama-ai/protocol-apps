# ProtocolStaking Testing

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

We separate our invariant rules into two distinct categories to handle EVM state constraints:

1. **Global Invariants**: Checked via invariant_* functions in the test contract after every sequence step. These check system-wide accounting rules.

2. **Transition Invariants**: Checked via the `assertTransitionInvariants` modifier directly inside the Handler contract. These compare State A (before an action) to State B (after an action) to ensure monotonicity (values only going up/down as expected).

### Handler

[`handlers/ProtocolStakingHandler.sol`](handlers/ProtocolStakingHandler.sol)

- Wraps ProtocolStaking actions: `stake`, `unstake`, `claimRewards`, `release`, `warp`, `setRewardRate`, `addEligibleAccount`, `removeEligibleAccount`, `setUnstakeCooldownPeriod`, `unstakeThenWarp`
- Bounds inputs (e.g. `amount ≤ balance`, `actorIndex ∈ [0, actors.length)`)
- Tracks ghost state: `ghost_totalStaked`, `ghost_accumulatedRewardCapacity`, `ghost_eligibleAccounts`, `ghost_claimed`, etc.
- Exposes equivalence scenarios: `stakeEquivalenceScenario`, `unstakeEquivalenceScenario`

### Invariant Test Contract

[`ProtocolStakingInvariantTest.t.sol`](ProtocolStakingInvariantTest.t.sol)

- Defines invariants via `invariant_*` functions
- Uses `targetContract` and `targetSelector` to limit which handler methods are fuzzed
- Invariants are checked after every handler call in the fuzz sequence

## Invariants

We separate our testing rules into three distinct categories:

### 1. Global Invariants

Checked via `invariant_*` functions in the main test contract after every handler call.

- Total supply bounded by reward rate:
```
totalSupply ≤ initialTotalSupply + Σ(δT_i × rewardRate_i)
```

- Total staked weight:
```
totalStakedWeight() == Σ weight(balanceOf(account))
```

- Reward debt conservation:
```
Σ _paid[account] + Σ earned(account) == _totalVirtualPaid + historicalRewards().
```

- Pending withdrawals solvency:
```
balanceOf(protocolStaking) ≥ Σ awaitingRelease(account)
```

- Staked funds solvency:
```
totalStaked == balanceOf(account) + awaitingRelease(account) + released
```

### 2. Transition Invariants

Because Foundry reverts the EVM state after evaluating `invariant_*` functions, transition checks (State A vs. State B) are executed natively inside the Handler using the `assertTransitionInvariants` modifier.

- Claimed + claimable never decreases:
```
claimed + earned is strictly non-decreasing per account across any action (incorporating a tolerance for division rounding).
```

- Awaiting release never decreases:
```
awaitingRelease(account) is non-decreasing until release() is explicitly called by that account.
```

- Unstake queue monotonicity:
```
_unstakeRequests checkpoints strictly enforce non-decreasing timestamps and cumulative amounts.
```

- Earned is zero after claim:
```
earned(account) is always zero after a claim
```

### 3. Equivalence Scenarios

These ensure that complex or batched actions result in the exact same mathematical state as singular actions. They utilize vm.snapshotState() and are checked inline inside the Handler.

- Stake equivalence:
```
stake(a1 + a2) results in the exact same shares, weight, and (approx) earned rewards as stake(a1) followed by stake(a2).
```

- Unstake equivalence:
```
A partial unstake to a target amount results in the exact same shares, weight, and (approx) earned rewards as a full unstake followed by a new stake of the target amount.
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
