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

OperatorStaking is an ERC4626 vault that stakes into ProtocolStaking. Its testing is more involved than ProtocolStaking because:

- It has an internal redemption queue (`requestRedeem` → cooldown → `redeem`) backed by ProtocolStaking unstakes
- Direct token transfers inflate `totalAssets` without minting shares, causing ERC4626 floor-rounding in `_convertToShares` to leak value into in-flight redemptions (staking-side illiquidity bug)
- The `OperatorRewarder` adds a second reward accounting system where sequential deposits expose a sum-of-floors < floor-of-sum phantom (rewarder-side phantom bug)
- Two contracts (vault + rewarder) can be independently affected by the same deposit event

### Files

- Handler: [`handlers/OperatorStakingHandler.sol`](/contracts/staking/test/foundry/handlers/OperatorStakingHandler.sol)
- Test: [`OperatorStakingInvariantTest.t.sol`](/contracts/staking/test/foundry/OperatorStakingInvariantTest.t.sol)
- Harness: [`harness/OperatorStakingHarness.sol`](/contracts/staking/test/foundry/harness/OperatorStakingHarness.sol)

### Covered actions

`deposit`, `depositWithPermit`, `requestRedeem`, `redeem`, `redeemMax`, `stakeExcess`, `donate`, `claimRewards`

---

## Tolerance Budget System

Two distinct floor-division phenomena each allow the system to diverge by at most 1 wei per triggering event. Rather than patching state, the handler asserts that the expected `ERC20InsufficientBalance` revert occurs.

### Staking-side: donation-triggered truncation leak

Direct token transfers inflate `totalAssets` without minting shares, raising the per-share exchange rate. Any subsequent deposit at the elevated rate incurs ERC4626 floor-rounding truncation: `_convertToShares` floors down, leaking the remainder into the shared pool. That leaked value raises `previewRedeem` for all outstanding shares — including shares already in the redemption queue — beyond what the vault holds as liquid assets.

The `donate()` handler caps donations so that `totalAssets / totalShares ≤ 1` (using virtual offsets), which bounds the per-deposit leak to exactly 0 or 1 wei. Proof: if `D ≤ N` (where D = totalAssets+1, N = totalShares+100), then for any single deposit minting N' shares, `pendingShares × (D'/N' − D/N) < 1`.

See: `test_IlliquidityBug_TruncationLeak`.

### Rewarder-side: sum-of-floors < floor-of-sum phantom

When an actor makes N sequential deposits and `transferHook` fires on each, each call independently computes `floor(R × s_i / T_i)` and accumulates the result into `_rewardsPaid[actor]`. Later, `earned()` computes a single `floor(R' × totalShares / totalSupply)` — the floor of the combined allocation.

By the sum-of-floors property, the sum of N individual floors can be strictly less than the floor of their combined value. Concretely, with totalSupply=500, R=7, and deposits of 200 then 300 shares:

```
V1 = floor(7 × 200 / 500)    = floor(2.8)   = 2
V2 = floor(9 × 300 / 700)    = floor(3.857) = 3   [R' = 7+2 = 9]
earned = floor(12 × 500 / 1000) − (2+3) = 6 − 5 = 1  ← phantom
```

The rewarder has 0 tokens after the preceding claim and protocolStaking has 0 pending, so `claimRewards` reverts with `ERC20InsufficientBalance(rewarder, 0, 1)`.

See: `test_PhantomRewardBug_RewarderInsolvency`.

### Ghost state counters

Each phenomenon has its own budget counter (upper bound) and spent tracker:

| Budget counter | Trigger condition | Spent tracker | Phenomenon |
|---|---|---|---|
| `ghost_inflatedDepositCount` | deposit while `totalSharesInRedemption > 0` | `ghost_globalSponsoredDust` | Staking-side illiquidity |
| `ghost_rewarderDepositCount` | deposit while `totalSupply > 0` | `ghost_rewarderSponsoredDust` | Rewarder-side phantom |

The trigger conditions differ because:
- **Staking-side**: the leak only matters when in-flight redemptions exist to absorb the inflated `previewRedeem`.
- **Rewarder-side**: `transferHook` fires on any deposit where `totalSupply > 0`, regardless of redemptions. The phantom comes from sequential floor divisions in `_allocation`, not from exchange rate inflation.

### Staking-side expected revert logic

When `redeem()` encounters a dust-sized shortfall within the tolerance budget, `_assertRedeemRevertsForDust` executes the call wrapped in `vm.expectRevert(ERC20InsufficientBalance)`. This actively proves the bug's signature without breaking the fuzzer's execution state, and debits `ghost_globalSponsoredDust`. If the shortfall exceeds the remaining budget, it falls through and surfaces as a real, unhandled bug.

### Rewarder-side expected revert logic

Using the same pattern, when `earned(actor) > rewarderBalance + protocolStaking.earned(operatorStaking)` and the shortfall is within budget, `_assertClaimRewardsRevertsForDust` explicitly asserts the expected `ERC20InsufficientBalance` revert and debits `ghost_rewarderSponsoredDust`.

---

## Global Invariants

### `invariant_redeemAtExactCooldown`

Every pending redemption can be claimed at exactly its cooldown timestamp. Each iteration is isolated via snapshot/revertTo, so each gets the full unspent tolerance budget independently.

When a truncation-leak shortfall exists within the tolerance budget, the invariant asserts the shortfall is bounded rather than executing the redeem. Dealing tokens to the vault to fix the shortfall is self-defeating for dominant redeemers: the dealt wei inflates `totalAssets`, which `previewRedeem` absorbs proportionally to `effectiveShares / totalShares`. When `actor_shares / S ≈ 1`, the obligation rises in lockstep with the injection.

The invariant explicitly asserts the expected `ERC20InsufficientBalance` revert occurs via the handler. If no shortfall exists, it executes the redeem and strictly verifies the exact ERC20 transfer matches the assets returned.

### `invariant_totalRecoverableValue`

No actor ever loses funds without slashing:

```
redeemed + previewRedeem(allShares) + acceptableLoss ≥ deposited
```

`acceptableLoss = ghost_actorRedeemCount + ghost_actorDepositCount` — 1 wei per floor-rounding event across deposits and redeems.

### `invariant_canAlwaysRequestRedeem`

Any account with a non-zero balance can always call `requestRedeem(balance)` without reverting, and the share balance decreases by exactly the requested amount.

### `invariant_redemptionQueueCompleteness`

```
Σ (pendingRedeemRequest(actor) + claimableRedeemRequest(actor)) == totalSharesInRedemption()
```

### `invariant_unstakeQueueMonotonicity`

Each controller's `_redeemRequests` checkpoint trace has non-decreasing timestamps and non-decreasing cumulative share amounts.

### `invariant_sharesConversionRoundTrip`

Two consecutive preview conversions can only lose value, never create it:

```
previewDeposit(previewRedeem(x)) ≤ x
previewRedeem(previewDeposit(x)) ≤ x
```

The round-trip loss is bounded by `ceil(S/A)` where `S = totalSupply + totalSharesInRedemption + 100` and `A = totalAssets + 1`.

**Why `ceil(S/A)` and not 1:**

```
previewRedeem(x)    = floor(x × A/S) = x × A/S − ε,   ε ∈ [0, 1)
previewDeposit(y)   = floor(y × S/A)
round-trip loss     = floor(ε × S/A) + 1   when frac(ε × S/A) > 0
```

With ε approaching 1 and a fractional S/A (e.g. 99.5), the loss reaches `floor(S/A) + 1 = ceil(S/A) = 100`. For integer S/A the ceiling equals the floor, so the loss stays within `S/A`. The tolerance is `(S + A − 1) / A` in integer arithmetic.

At a healthy 1:1 exchange rate this tolerance is 1. It widens only when the rate diverges due to large donations or reward accumulation.

### `invariant_liquidityBufferSufficiency`

```
balanceOf(operatorStaking) + awaitingRelease(operatorStaking) + tolerance ≥ previewRedeem(totalSharesInRedemption())
```

`tolerance = ghost_inflatedDepositCount − ghost_globalSponsoredDust` — the unspent rounding budget.

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

**Shares**: not asserted equal. After `deposit(a)`, the exchange rate shifts by `ε/(A + a)` where `ε ∈ [0, 1)` is the fractional part of `a × S/A`. The second deposit uses this new rate, yielding `floor(b × ε / (A + a))` fewer shares. The proven bound is:

```
|sharesB − sharesA| ≤ floor(amount2 / (A + amount1)) + 2
```

This is computed dynamically from pre-deposit state and used as the assertion tolerance.

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
runs  = 256
depth = 100
fail_on_revert = true
```

`fail_on_revert = true` ensures unexpected reverts in handler actions are treated as failures rather than discards.

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
