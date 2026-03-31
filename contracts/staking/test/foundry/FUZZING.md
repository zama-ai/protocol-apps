# Staking Invariant Fuzz Testing

Invariant and stateful fuzz testing for `ProtocolStaking` and `OperatorStaking` using Foundry.

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
---

## Test Structure

Tests use a **handler pattern**: a handler contract wraps the target contract, bounds fuzz inputs, and maintains ghost state. After each handler call in a fuzz sequence, Foundry evaluates all `invariant_*` functions.

Invariant checks fall into three categories:

| Category | Where | Purpose |
|---|---|---|
| **Global invariants** | `invariant_*` in test contract | System-wide accounting rules checked after every step |
| **Transition invariants** | `assertTransitionInvariants` modifier in handler | State A → State B checks (monotonicity, exact deltas) |
| **Equivalence scenarios** | Handler functions using `vm.snapshotState()` | Two paths to same state must produce identical results |

> Transition invariants live in the handler because Foundry reverts EVM state after `invariant_*` calls, which would destroy any pre/post comparison.

---

## ProtocolStaking

### Files

- Handler: [`handlers/ProtocolStakingHandler.sol`](/contracts/staking/test/foundry/handlers/ProtocolStakingHandler.sol)
- Test: [`ProtocolStakingInvariantTest.t.sol`](/contracts/staking/test/foundry/ProtocolStakingInvariantTest.t.sol)

### Covered actions

`stake`, `unstake`, `claimRewards`, `release`, `warp`, `setRewardRate`, `addEligibleAccount`, `removeEligibleAccount`, `setUnstakeCooldownPeriod`, `unstakeThenWarp`

### Global invariants

- **Total supply bounded by reward rate**
  ```
  totalSupply ≤ initialTotalSupply + Σ(δT_i × rewardRate_i)
  ```

- **Total staked weight**
  ```
  totalStakedWeight() == Σ weight(balanceOf(account))
  ```

- **Reward debt conservation**
  ```
  Σ _paid[account] + Σ earned(account) == _totalVirtualPaid + historicalRewards()
  ```

- **Pending withdrawals solvency**
  ```
  balanceOf(protocolStaking) ≥ Σ awaitingRelease(account)
  ```

- **Staked funds solvency**
  ```
  totalStaked == balanceOf(account) + awaitingRelease(account) + released
  ```

### Transition invariants

- `claimed + earned` is non-decreasing per account across any action (with 1-wei tolerance for division rounding)
- `awaitingRelease(account)` is non-decreasing until `release()` is explicitly called
- `_unstakeRequests` checkpoints have non-decreasing timestamps and cumulative amounts
- `earned(account) == 0` immediately after `claimRewards(account)`

### Equivalence scenarios

- **Stake equivalence**: `stake(a + b)` gives the same shares, weight, and earned as `stake(a)` then `stake(b)`
- **Unstake equivalence**: partial unstake to target gives the same shares, weight, and earned as full unstake then restake to target

---

## OperatorStaking

OperatorStaking is an ERC4626 vault that stakes into ProtocolStaking.

### Files

- Handler: [`handlers/OperatorStakingHandler.sol`](/contracts/staking/test/foundry/handlers/OperatorStakingHandler.sol)
- Test: [`OperatorStakingInvariantTest.t.sol`](/contracts/staking/test/foundry/OperatorStakingInvariantTest.t.sol)
- Harness: [`harness/OperatorStakingHarness.sol`](/contracts/staking/test/foundry/harness/OperatorStakingHarness.sol)

### Covered actions

`deposit`, `depositWithPermit`, `requestRedeem`, `redeem`, `redeemMax`, `stakeExcess`, `donate`, `claimRewards`

---

## Tolerance Budget System

Two integer rounding effects can cause `previewRedeem` or `earned` to promise slightly more than the vault or rewarder can pay, causing `redeem` or `claimRewards` to revert with `ERC20InsufficientBalance`. The handler tracks a bounded budget for each effect and asserts the expected revert rather than failing the test when a shortfall falls within that budget.

### Staking-side: donation-triggered truncation leak

When a user deposits `d` assets, shares are minted using floor division:

```
sharesMinted = floor(d * totalShares / totalAssets)
```

Because Solidity rounds down, the depositor pays for a fractional share they never receive. That fractional share's asset value stays in the vault as unowned value, inflating `previewRedeem` for all outstanding shares, including those in the redemption queue. This creates an obligation the vault cannot cover from liquid assets.

#### Derivation of the per-deposit bound

The exact number of shares before rounding is `d * totalShares / totalAssets`. After rounding down, the fractional remainder is:

```
remainder = (d * totalShares / totalAssets) - sharesMinted
```

This remainder is always >= 0 and strictly less than 1 whole share (it is the part that got truncated). To find how much asset value this leftover represents, multiply it by the asset-per-share exchange rate:

```
leaked assets = remainder * (totalAssets / totalShares)
```

Since `0 ≤ remainder < 1` (share units), with exchange rate `totalAssets / totalShares`:

```
leaked assets = remainder * (totalAssets / totalShares) < totalAssets / totalShares
```

`totalAssets / totalShares` is the upper bound in this model (approached as remainder → 1). Typical leaks are smaller (e.g. remainder ≈ 0.3 implies leaked ≈ 0.3 × rate, still **strictly less** than `totalAssets / totalShares`).

To get a whole-number upper bound we round up (ceiling division):

```
upper bound = ceil(totalAssets / totalShares)
```

#### Implementation of `ceil(totalAssets / totalShares)`

```solidity
uint256 S = totalSupply + totalSharesInRedemption + 100;  // effective total shares
uint256 A = totalAssets + 1;                               // +1 avoids division by zero
uint256 currentCeilAS = (A + S - 1) / S;
```

The expression `(A + S - 1) / S` is the standard integer ceiling division identity: 

```
for any positive integers `a` and `b`: 

ceil(a / b) = floor((a + b - 1) / b)
```

The handler captures this value **before each deposit** (when the pre-deposit exchange rate is known) and accumulates it into **`ghost_globalRedemptionBudget`** and **`ghost_actorDepositBudget`** according to the trigger rules in **Ghost state counters** below.

See: `test_IlliquidityBug_TruncationLeak` for a detailed example.

### Rewarder-side: phantom reward from repeated rounding

When an actor makes N sequential deposits and `transferHook` fires on each, each call independently rounds down its reward allocation and accumulates the result into `_rewardsPaid[actor]`. Later, `earned()` computes a single combined allocation and rounds down once.

Rounding down several small values individually can discard more total precision than rounding the combined value once. The sum of the individually rounded values can therefore be strictly less than the single rounded combined value. Concretely:

```
0. Setup / notation
   - Other staker: 500 shares, held for the whole trace.
   - rewardsPerToken: cumulative rewards distributed per share since deployment.
   - _rewardsPaid[actor]: running total of reward debt for an actor

1. Before deposit 1
   - totalSupply: 500
   - rewardsPerToken: 3

2. Actor deposits 200 shares
   - totalSupply: 500 -> 700
   - transferHook credits floor(rewardsPerToken * newShares / totalSupply)
   - Update 1 = floor(3 * 200 / 700) = floor(0.857) = 0
   - _rewardsPaid[actor]: 0

3. Rewards accrue
   - rewardsPerToken: 3 -> 7

4. Actor deposits 300 shares
   - totalSupply: 700 -> 1000
   - transferHook credits floor(rewardsPerToken * newShares / totalSupply)
   - Update 2 = floor(7 * 300 / 1000) = floor(2.1) = 2
   - _rewardsPaid[actor]: 0 + 2 = 2

5. Rewards accrue
   - rewardsPerToken: 7 -> 10

6. Actor calls earned()
   - actorShares: 500; totalSupply: 1000; rewardsPerToken: 10
   - earned() = floor(rewardsPerToken * actorShares / totalSupply) - _rewardsPaid[actor]
   - earned = floor(10 * 500 / 1000) - (0 + 2) = 5 - 2 = 3

7. Actor calls claimRewards()
   - available = rewarder.balanceOf(rewarder) + protocolStaking.earned(operatorStaking) = 2
   - needed = earned() = 3
   - ERC20InsufficientBalance(rewarder, balance=2, needed=3)
```

Deposit 1 rounded 0.857 down to 0, and that discarded fraction is never re-credited. When `earned()` later computes the combined allocation, the actor appears to be owed 1 wei more than ProtocolStaking ever emitted. The handler acccounts for this shortfall with `ghost_rewarderDepositCount` (see **Ghost state counters**).

See: `test_PhantomRewardBug_RewarderInsolvency` for a detailed example.

### Ghost state counters

| Budget counter | Accumulates | Trigger condition | Phenomenon |
|---|---|---|---|
| `ghost_globalRedemptionBudget` | `ceil(totalAssets / totalShares)` per deposit | deposit while `totalSharesInRedemption > 0` | Staking-side liquidity shortfall |
| `ghost_actorDepositBudget[actor]` | `ceil(totalAssets / totalShares)` per deposit | every deposit | Per-actor recoverable value loss |
| `ghost_rewarderDepositCount` | `1` per deposit | deposit while `totalSupply > 0` | Rewarder-side phantom reward |

The trigger conditions differ because:
- **Staking-side**: the truncation leak only creates a liquidity shortfall when in-flight redemptions exist to absorb the inflated `previewRedeem`.
- **Per-actor**: any deposit can cause the depositor to receive fewer shares than the value they contributed, regardless of redemption state.
- **Rewarder-side**: `transferHook` fires on any deposit where `totalSupply > 0`. The phantom arises from sequential floor divisions in `_allocation`, not from exchange rate inflation.

### Staking-side expected revert logic

When `redeem()` encounters a shortfall within `ghost_globalRedemptionBudget`, `_assertRedeemRevertsForDust` executes the call wrapped in `vm.expectRevert(ERC20InsufficientBalance)`. This actively proves the bug's signature without breaking the fuzzer's execution state. If the shortfall exceeds the budget, it falls through and surfaces as a real failure.

### Rewarder-side expected revert logic

Using the same pattern, when `earned(actor) > rewarderBalance + protocolStaking.earned(operatorStaking)` and the shortfall is within `ghost_rewarderDepositCount`, `_assertClaimRewardsRevertsForDust` explicitly asserts the expected `ERC20InsufficientBalance` revert.

---

## Global Invariants

### `invariant_redeemAtExactCooldown`

Every pending redemption can be claimed at exactly its cooldown timestamp. Each iteration is isolated via snapshot/revertTo, so each gets the full unspent tolerance budget independently.

When a truncation-leak shortfall exists within the tolerance budget, the invariant asserts the shortfall is bounded rather than executing the redeem.

The invariant explicitly asserts the expected `ERC20InsufficientBalance` revert occurs via the handler. If no shortfall exists, it executes the redeem and strictly verifies the exact ERC20 transfer matches the assets returned.

### `invariant_totalRecoverableValue`

No actor ever loses funds without slashing:

```
redeemed + previewRedeem(allShares) + acceptableLoss ≥ deposited
```

`acceptableLoss = ghost_actorRedeemCount + ghost_actorDepositBudget`: the cumulative `ceil(totalAssets / totalShares)` captured before each deposit (at the pre-deposit exchange rate) plus 1 wei per redeem for floor-rounding in `_convertToAssets`.

### `invariant_canAlwaysRequestRedeem`

Any account with a non-zero balance can always call `requestRedeem(balance)` without reverting, and the share balance decreases by exactly the requested amount.

### `invariant_redemptionQueueCompleteness`

```
Σ (pendingRedeemRequest(actor) + claimableRedeemRequest(actor)) == totalSharesInRedemption()
```

### `invariant_unstakeQueueMonotonicity`

Each controller's `_redeemRequests` checkpoint trace has non-decreasing timestamps and non-decreasing cumulative share amounts.

### `invariant_sharesConversionRoundTrip`

Two consecutive preview conversions can only lose value, never create it. Each direction has its own tolerance:

**shares → assets → shares** (`previewDeposit(previewRedeem(x)) <= x`):
```
step 1: assets = floor(x * totalAssets / totalShares)          -- rounds down, losing < 1 share of asset value
step 2: result = floor(assets * totalShares / totalAssets)
loss   = x - result <= ceil(totalShares / totalAssets)
tolerance = (S + A - 1) / A
```

**assets → shares → assets** (`previewRedeem(previewDeposit(x)) <= x`):
```
step 1: shares = floor(x * totalShares / totalAssets)          -- rounds down, losing < 1 share worth of assets
step 2: result = floor(shares * totalAssets / totalShares)
loss   = x - result <= ceil(totalAssets / totalShares)
tolerance = (A + S - 1) / S
```

Where `S = totalSupply + totalSharesInRedemption + 100` and `A = totalAssets + 1`. At a 1:1 exchange rate both tolerances equal 1; they widen only when the rate diverges.

### `invariant_liquidityBufferSufficiency`

```
balanceOf(operatorStaking) + awaitingRelease(operatorStaking) + tolerance ≥ previewRedeem(totalSharesInRedemption())
```

`tolerance = ghost_globalRedemptionBudget` — the cumulative `ceil(totalAssets / totalShares)` captured before each deposit made while `totalSharesInRedemption > 0`.

---

## Transition Invariants

### Reward monotonicity

`ghost_claimedRewards[actor] + rewarder.earned(actor)` is non-decreasing across every action, with a 1-wei tolerance for division rounding in `_allocation`.

### stakeExcess exact buffer

After `stakeExcess()`:

```
IERC20(asset).balanceOf(operatorStaking) == previewRedeem(totalSharesInRedemption())
```

### Redeem exact transfer + shares accounting

After `redeem(shares)`:

1. Actual ERC20 transfer equals the pre-call `previewRedeem(effectiveShares)` snapshot
2. `totalSharesInRedemption` decreased by `effectiveShares`
3. `_sharesReleased[controller]` increased by `effectiveShares`

Checks 2 and 3 are gated on `assets > 0`. `OperatorStaking.redeem` only runs the accounting block inside `if (assets > 0)` — if `previewRedeem(effectiveShares)` rounds to zero (very small share count), the call succeeds but neither field changes.

---

## Equivalence Scenarios

### `depositEquivalenceScenario`

`deposit(a) + deposit(b)` vs `deposit(a + b)` using snapshot/revertTo.

**Shares**: not asserted equal. After `deposit(a)`, the truncated fractional share stays in the vault, shifting the exchange rate slightly. `deposit(b)` at the new rate yields fewer shares. The fractional part is always less than 1 share, so the rate shift is always less than `1 / totalShares`. The proven bound on the share difference is:

```
abs(sharesA - sharesB) <= floor(amount2 / (totalAssets + amount1)) + 2
```

This is computed dynamically from pre-deposit state (`A = totalAssets + 1`) and used as the assertion tolerance.

**Earned**: asserted within 2 wei. Two floor calls in `transferHook._allocation` (path A) vs one (path B) introduces at most 2 wei divergence.

### `requestRedeemEquivalenceScenario`

`requestRedeem(a) + requestRedeem(b)` vs `requestRedeem(a + b)` using snapshot/revertTo.

Both requests happen at the same timestamp, so the contract accumulates them into the same checkpoint window. `pendingRedeemRequest` is asserted exactly equal between paths — no tolerance needed.

---

## Known Limitations

### `ghost_claimedRewards` drift

Because phantom rewards are caught via expected reverts, the underlying phantom debt remains on the rewarder's books. This permanently blocks the affected actor from successfully executing `claimRewards()` until their shares burn via `requestRedeem` (which adjust `_rewardsPaid` in the transferHook). During this period, `ghost_claimedRewards[actor]` under-counts actual accrued rewards.

Once a truncation shortfall exists in the vault, direct token donations cannot close it. The dominant redeemer's floating shares absorb any injected value proportionally — `previewRedeem` rises in lockstep with the bailout. To close a 1-wei gap requires donating approximately `totalAssets / 100` (TVL-proportional, not shortfall-proportional).

---

## Running Tests

```bash
# All tests
forge test

# OperatorStaking invariants only
forge test --match-contract OperatorStakingInvariantTest

# ProtocolStaking invariants only
forge test --match-contract ProtocolStakingInvariantTest

# Single invariant
forge test --match-contract OperatorStakingInvariantTest --match-test invariant_liquidityBufferSufficiency

# Verbose output
forge test -vvv

# After modifying handler or invariants, clear the failure cache first
forge clean && forge test
```

### Configuration

Fuzz parameters are in [`foundry.toml`](/contracts/staking/foundry.toml):

```toml
[invariant]
fail_on_revert = true
```

`fail_on_revert = true` ensures unexpected reverts in handler actions are treated as failures rather than discards. `runs` and `depth` use Foundry defaults.

---

## Coverage

```bash
# Summary
forge coverage

# LCOV report
forge coverage --report lcov

# HTML report (requires lcov: brew install lcov / apt install lcov)
forge coverage --report lcov && genhtml lcov.info -o coverage
open coverage/index.html
```
