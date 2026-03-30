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

1. **Global Invariants**: Checked via `invariant_*` functions in the invariant test contract after every sequence step. These check system-wide accounting rules. (**ProtocolStaking.invariants.t**)

2. **Transition Invariants**: Checked via the `assertTransitionInvariants` modifier directly inside the Handler contract. These compare State A (before an action) to State B (after an action) to ensure monotonicity (values only going up/down as expected). (**ProtocolStakingHandler**)

3. **Equivalence Invariants**: Verify that two different execution paths to the same logical outcome produce identical on-chain state. Checked inline in the handler using `vm.snapshotState()` to fork execution, run both paths, and compare results. (**ProtocolStakingHandler**)

### Handler

[`handlers/ProtocolStakingHandler.sol`](handlers/ProtocolStakingHandler.sol)

- Wraps ProtocolStaking actions: `stake`, `unstake`, `claimRewards`, `release`, `warp`, `setRewardRate`, `addEligibleAccount`, `removeEligibleAccount`, `setUnstakeCooldownPeriod`, `unstakeThenWarp`, `setRewardsRecipient`
- Bounds inputs (e.g. `amount ≤ balance`)
- Tracks ghost state: `ghost_totalStaked`, `ghost_accumulatedRewardCapacity`, `ghost_eligibleAccounts`, `ghost_claimed`, etc.
- Exposes equivalence scenarios: `stakeEquivalenceScenario`, `unstakeEquivalenceScenario`

### Invariant Test Contract

[`ProtocolStaking.invariants.t.sol`](ProtocolStaking.invariants.t.sol) (`ProtocolStakingInvariantsTest`)

- Defines invariants via `invariant_*` functions
- Uses `targetContract` and `targetSender` to direct the fuzzer's actions
- Invariants are checked after every handler call in the fuzz sequence

### Tolerance bound proofs (unit tests)

[`ProtocolStaking.tests.t.sol`](ProtocolStaking.tests.t.sol) (`ProtocolStakingTests`)

- Isolated scenarios (`test_*`) that justify ghost terms and tolerances used by the handler and invariants

## Invariants

### 1. Global Invariants

Checked via `invariant_*` functions in the main test contract after every handler call.

#### Total supply bounded by reward rate

`invariant_TotalSupplyBoundedByRewardRate`: `totalSupply` must stay within the handler’s model of **accumulated reward capactiy** plus a small tolerance for rounding on weight-decreasing exits.

```
totalSupply ≤ ghost_initialTotalSupply
            + ghost_accumulatedRewardCapacity
            + ghost_truncationOps
```

- **`ghost_initialTotalSupply`** — `totalSupply` snapshot when the handler is constructed (before fuzzing).
- **`ghost_accumulatedRewardCapacity`** — running upper bound Σ(δTᵢ × rateᵢ): on each `warp`, if `totalStakedWeight > 0`, the handler adds `ghost_currentRate * duration` (rate is kept in sync with `setRewardRate`). This matches “rewards the contract is allowed to emit” while time advances.
- **`ghost_truncationOps`** — count of weight-decrease operations (eligible `unstake`, `removeEligibleAccount` with balance). Each can let at most **one** extra wei be minted above the allowance.

See the **Total Supply Bound** block in the contract level NatSpec on [`ProtocolStakingHandler.sol`](handlers/ProtocolStakingHandler.sol).

#### Total staked weight

`invariant_TotalStakedWeightEqualsEligibleWeights`: the contract’s aggregate eligible weight must match the sum of per-account weights implied by current balances.

The test compares:

```
protocolStaking.totalStakedWeight() == handler.computeExpectedTotalWeight()
```

`computeExpectedTotalWeight` walks the handler’s **`actors`** list, keeps only `isEligibleAccount(account)`, and sums `weight(balanceOf(account))`.

#### Reward conservation

`invariant_RewardConservation`: per-account reward views must match the global pool within tolerance.

```
actorTotal     = Σ _paid(account) + Σ earned(account)
protocolTotal  = _totalVirtualPaid + historicalReward
```

**Tolerance** — `N + D`:

- `N` = `GHOST_MAX_ELIGIBLE_ACCOUNTS`: actor count fixed at handler construction; bounds truncation dust from per-account `earned()` floors.
- `D` = `ghost_dilutionOps`: handler count of weight-increase events; each contributes at most 1 wei of phantom to the actor side.

```
| actorTotal − protocolTotal | ≤ N + D
```

For why `N` and `D` arise, see the **Reward Conservation** section in the contract-level NatSpec on [`ProtocolStakingHandler.sol`](handlers/ProtocolStakingHandler.sol).

#### Pending withdrawals solvency

`invariant_PendingWithdrawalsSolvency`: the **staking token** balance held by `ProtocolStaking` must cover every wei still locked in the unstake cooldown (sum of `awaitingRelease`).

```
IERC20(token).balanceOf(address(protocolStaking))
  ≥ Σ protocolStaking.awaitingRelease(account)
```

`Σ` adds `awaitingRelease(account)` for every address in the handler’s `actors` array.

#### Staked funds solvency

`invariant_StakedFundsSolvency`: for each actor, cumulative **staking token** deposited through the handler must equal what is inside the contract's accounting bucket (staked tokens + exit queue + already released tokens).

```
ghost_totalStaked[account]
  == protocolStaking.balanceOf(account)       // account staked balance
   + protocolStaking.awaitingRelease(account) // unstaked balance, cooldown not finished
   + ghost_totalReleased[account]             // exited to wallet after cooldown (handler ghost)
```

- **`ghost_totalStaked`** — incremented on each `stake` in [`ProtocolStakingHandler`](handlers/ProtocolStakingHandler.sol).
- **`ghost_totalReleased`** — incremented on `release` (tokens leaving the cooldown queue).

#### Unstake queue monotonicity

`invariant_UnstakeQueueMonotonicity`: for each actor, the `_unstakeRequests[account]` checkpoint trace has only **increasing** timestamps (`key`) and **increasing cumulative** queued shares (`value`). The stored `value` is a running total in the exit queue, not a per-unstake increment; identical `key` with a larger `value` is in-place growth at the same time.

```
key[j] ≥ key[j−1]
value[j] ≥ value[j−1]     // j indexes consecutive checkpoints
```

Read from on-chain storage via [`ProtocolStakingHarness`](harness/ProtocolStakingHarness.sol): `_harness_getUnstakeRequestCheckpointCount`, `_harness_getUnstakeRequestCheckpointAt`.

### 2. Transition invariants

Foundry rolls back state after each `invariant_*` call, so **per-step** (State A → State B) rules live on the [`assertTransitionInvariants`](handlers/ProtocolStakingHandler.sol) modifier in **ProtocolStakingHandler**: it snapshots `ghost_claimed + earned` and `awaitingRelease` for every `actors[]` entry **before** the handler action, runs the action, then asserts below.

#### Claimed + claimable never decreases

**`_assertClaimedPlusEarnedTransition`**: an actor’s total **already claimed + still claimable** tokens must not drop across a single handler step (beyond fixed rounding tolerance).

```
pre  = ghost_claimed[account] + protocolStaking.earned(account)   // before the action
post = ghost_claimed[account] + protocolStaking.earned(account)   // after the action

post ≥ pre
```

#### Awaiting release never decreases

**`_assertAwaitingReleaseTransition`**: `awaitingRelease(account)` must not decrease unless that account just executed **`release()`** (then the check is skipped via `ghost_releasedAccount`).

```
postAwaitingRelease ≥ preAwaitingRelease
```

On-chain, `awaitingRelease(account) = _unstakeRequests[account].latest() − _released[account]`. A successful read implies `_released[account] ≤ latest()`, otherwise, the subtraction reverts.

#### Earned is zero immediately after claim

**`_assertEarnedZeroAfterClaim`**: if the last action was **`claimRewards`**, the claimant must have **`earned(account) == 0`** right after.

```
protocolStaking.earned(ghost_lastClaimedActor) == 0
```

`claimRewards()` sets `ghost_lastClaimedActor`. After all transition checks, **`_resetTransitionFlags`** zeroes `ghost_lastClaimedActor` and `ghost_releasedAccount`. If no claim was performed, `ghost_lastClaimedActor` is `address(0)` and `_assertEarnedZeroAfterClaim` returns without asserting.

### 3. Equivalence scenarios

**`stakeEquivalenceScenario`** and **`unstakeEquivalenceScenario`** in [`ProtocolStakingHandler`](handlers/ProtocolStakingHandler.sol) are regular fuzz targets. Each uses **`vm.snapshotState()`** -> runs **path A** -> **`vm.revertToState(snapshot)`** -> runs **path B** (path B stays as the live continuation), then compares **`post_A`** vs **`post_B`**.

**Balances and weight** must match exactly. **Earned rewards** may differ only within **`EQUIVALENCE_EARNED_TOLERANCE`** (**2** wei): path B typically performs more intermediate reward/pool updates, so a tolerance is allocated for `muldiv` truncation.

#### Stake equivalence — `stakeEquivalenceScenario`

**Intent:** stake(a + b) ≡ stake(a) + stake(b)

```
Path A:  stake(amount1 + amount2) -> warp(duration) -> read state -> revert state
Path B:  stake(amount1) + stake(amount2) -> warp(duration) -> read state
```

Let **`post_A`** / **`post_B`** be the state after path **A** / path **B**:

```
balance = protocolStaking.balanceOf(account)

post_A(balance) == post_B(balance)
post_A(protocolStaking.weight(balance)) == post_B(protocolStaking.weight(balance))
post_A(protocolStaking.earned(account)) == post_B(protocolStaking.earned(account)) (within tolerance)
```

#### Unstake equivalence — `unstakeEquivalenceScenario`

**Intent:** unstake(initialStake − targetStake) ≡ unstake(initialStake) -> stake(targetStake)

```
Path A:  stake(initialStake) -> warp -> unstake(initialStake − targetStake) -> warp -> read state -> revert state
Path B:  stake(initialStake) -> warp -> unstake(initialStake) -> stake(targetStake) -> warp -> read state
```

Let **`post_A`** / **`post_B`** be the state after path **A** / path **B**:

```
balance = protocolStaking.balanceOf(account)

post_A(balance) == post_B(balance)
post_A(protocolStaking.weight(balance)) == post_B(protocolStaking.weight(balance))
post_A(protocolStaking.earned(account)) == post_B(protocolStaking.earned(account)) (within tolerance)
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
forge test --match-contract ProtocolStakingInvariantsTest --match-test invariant_TotalSupplyBoundedByRewardRate
```

Replace `invariant_TotalSupplyBoundedByRewardRate` with any invariant name (e.g. `invariant_RewardConservation`).

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
