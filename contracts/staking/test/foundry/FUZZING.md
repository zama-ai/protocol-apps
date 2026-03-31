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

## Protocol Staking

Uses a **handler pattern**: a handler contract wraps ProtocolStaking, bounds fuzzed inputs, and tracks ghost state. Invariants run after each handler call in a fuzz sequence.

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

### Tolerance bound justification

[`ProtocolStaking.tests.t.sol`](ProtocolStaking.tests.t.sol) (`ProtocolStakingTests`)

- Isolated scenarios (`test_*`) that justify ghost terms and tolerances used by the handler and invariants

## Protocol Staking Invariants

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

---
## OperatorStaking

OperatorStaking is an ERC7540-inspired staking vault that delegates assets into ProtocolStaking on behalf of depositors.

### Files

- Handler: [`handlers/OperatorStakingHandler.sol`](handlers/OperatorStakingHandler.sol)
- Test: [`OperatorStaking.invariants.t.sol`](OperatorStaking.invariants.t.sol)
- Harness: [`harness/OperatorStakingHarness.sol`](harness/OperatorStakingHarness.sol)

### Covered actions

`deposit`, `depositWithPermit`, `requestRedeem`, `redeem`, `redeemMax`, `stakeExcess`, `donate`, `claimRewards`, `setFee`, `warp`

### Rounding Tolerances

Two floor-division effects can cause `previewRedeem` or `earned` to promise slightly more than the vault or rewarder can pay, reverting `redeem` or `claimRewards` with `ERC20InsufficientBalance`. The handler tracks a bounded budget for each effect and asserts the expected revert when a shortfall falls within budget.

#### Staking-side: deposit truncation leak

When a deposit of `d` assets is converted to shares via floor division, the truncated fractional share is never minted, but its asset value stays in the vault as unowned value. This inflates `previewRedeem` for all outstanding shares, including those in the redemption queue, creating an obligation the vault cannot cover from liquid assets.

```
sharesMinted = floor(d * S / A)
```

`S = totalSupply + totalSharesInRedemption + 10^offset`, `A = totalAssets + 1`.

##### Per-deposit bound: `ceil(A/S)`

The fractional remainder is in `[0, 1)` shares. Multiplied by the exchange rate `A/S`, the leaked assets are strictly less than `A/S`. The integer upper bound is `ceil(A/S)`:

```solidity
uint256 S = totalSupply + totalSharesInRedemption + 100;
uint256 A = totalAssets + 1;
uint256 currentCeilAS = (A + S - 1) / S;  // standard ceil: ceil(a/b) = floor((a + b - 1) / b)
```

##### Why `ceil(A/S) = 1` in normal operation

The decimals offset of 2 creates 100 virtual shares, anchoring the share supply at ~100× the asset balance (`A/S ≈ 1/100`). No normal flow breaks this:

- **Deposits** mint shares proportionally via `_convertToShares`.
- **Redemption requests** move shares between `totalSupply` and `totalSharesInRedemption` without touching assets.
- **Redeems** reduce assets and shares proportionally.
- **Rewards** route to `OperatorRewarder`, not to the vault's token balance.

The only way to push `ceil(A/S)` above 1 is a direct token transfer (donation), which inflates `totalAssets` while shares stay fixed. Because shares outnumber assets ~100:1, the donation must exceed ~99× current TVL before the ceiling rounds up to 2.

With `ceil = 1` the per-deposit error is at most **1 wei**, so budgets grow slowly. Calling `stakeExcess` resets `ghost_globalRedemptionBudget` to 0 by restoring the exact-buffer condition.

See: `test_StakingSideDepositBudget_RemainderLeak` and `test_GlobalRedemptionBudget_DonationTruncation` in [OperatorStaking.tests.t.sol](OperatorStaking.tests.t.sol).

#### Rewarder-side: phantom reward from repeated rounding

When an actor makes N sequential deposits, each `transferHook` call independently rounds down its `_allocation` result into `_rewardsPaid[actor]`. Later, `earned()` computes a single combined allocation and rounds down once. Rounding down several small values individually can discard more precision than rounding the combined value once, so `earned()` can report up to 1 phantom wei per deposit that the rewarder cannot cover.

See: `test_RewarderSideDepositBudget_PhantomInsolvency` in [`OperatorStaking.tests.t.sol`](OperatorStaking.tests.t.sol).

#### Ghost state counters

| Counter | Per-event increment | Trigger | Phenomenon |
|---|---|---|---|
| `ghost_globalRedemptionBudget` | `ceil(A/S)` | deposit while `totalSharesInRedemption > 0` | Staking-side liquidity shortfall |
| `ghost_actorDepositBudget[actor]` | `ceil(A/S)` | every deposit | Per-actor recoverable value loss |
| `ghost_rewarderDepositCount` | `1` | deposit while `totalSupply > 0` | Rewarder-side phantom reward |

Trigger conditions differ because:
- **Global redemption**: the leak only creates a liquidity shortfall when in-flight redemptions absorb the inflated `previewRedeem`.
- **Per-actor**: any deposit can cause the depositor to receive fewer shares than the value contributed.
- **Rewarder**: `transferHook` fires on any deposit where `totalSupply > 0`. The phantom arises from sequential floor divisions in `_allocation`, not exchange rate inflation.

#### Expected revert logic

When a shortfall falls within budget, the handler wraps the call in `vm.expectRevert(ERC20InsufficientBalance)`, proving the bug signature without breaking execution. If the shortfall exceeds budget, it falls through as a real failure.

- **Staking-side** (`_assertRedeemRevertsWithinBudget`): triggers when `previewRedeem(shares) > availableAssets` and shortfall ≤ `ghost_globalRedemptionBudget`.
- **Rewarder-side** (`_assertClaimRevertsWithinBudget`): triggers when `earned(actor) > rewarderBalance + protocolStaking.earned(operatorStaking)` and shortfall ≤ `ghost_rewarderDepositCount`.

## Operator Staking Invariants

### 1. Global Invariants

Checked via `invariant_*` functions in [`OperatorStaking.invariants.t.sol`](OperatorStaking.invariants.t.sol) after every handler call.

#### Redeem at exact cooldown

`invariant_redeemAtExactCooldown`: every pending redemption is claimable at its exact cooldown timestamp. Each queue entry is isolated via `vm.snapshotState` / `vm.revertToState`.

- **Shortfall within budget**: asserts `ERC20InsufficientBalance` via [`assertRedeemRevertsWithinBudget`](handlers/OperatorStakingHandler.sol).
- **No shortfall**: executes `redeem`, asserts tokens transferred == `assetsReturned`.

#### Total recoverable value

`invariant_totalRecoverableValue`: no actor loses deposited principal without slashing.

```
ghost_redeemed + previewRedeem(totalSharesActor) + acceptableLoss ≥ ghost_deposited
```

- **`totalSharesActor`** = `balanceOf(actor) + pendingRedeemRequest(actor) + claimableRedeemRequest(actor)`
- **`acceptableLoss`** = `ghost_actorRedeemCount(actor) + ghost_actorDepositBudget(actor)`

See [Ghost state counters](#ghost-state-counters) for budget details.

#### Can always request redeem

`invariant_canAlwaysRequestRedeem`: any actor with non-zero shares can `requestRedeem` and their balance decreases by exactly the requested amount.

```
amount = min(balanceOf(actor), type(uint208).max)
requestRedeem(amount, actor, actor)
balanceOf(actor)_before − balanceOf(actor)_after == amount
```

#### Redemption queue completeness

`invariant_redemptionQueueCompleteness`: per-actor pending + claimable shares sum to global queued shares.

```
Σ (pendingRedeemRequest(actor) + claimableRedeemRequest(actor)) == totalSharesInRedemption()
```

#### Unstake (redeem) queue monotonicity

`invariant_unstakeQueueMonotonicity`: for each controller, `_redeemRequests` checkpoint keys and cumulative share values are non-decreasing.

```
key[j] ≥ key[j−1]
value[j] ≥ value[j−1]     // consecutive checkpoints j
```

Read via [`OperatorStakingHarness`](harness/OperatorStakingHarness.sol): `_harness_getRedeemRequestCheckpointCount`, `_harness_getRedeemRequestCheckpointAt`.

#### Liquidity buffer sufficiency

`invariant_liquidityBufferSufficiency`: liquid balance plus balance awaiting release covers all in-flight redemptions, within tolerance budget.

```
IERC20(asset).balanceOf(operatorStaking)
  + protocolStaking.awaitingRelease(operatorStaking)
  + ghost_globalRedemptionBudget
  ≥ previewRedeem(totalSharesInRedemption())
```

#### Shares conversion round trip

`invariant_sharesConversionRoundTrip`: two composed preview conversions never gain value. Per-direction loss is bounded by the ceiling of the inverse exchange rate.

**Shares → assets → shares** (`previewDeposit(previewRedeem(x))`):

```
sharesBack ≤ x
|x − sharesBack| ≤ ceil(S/A)    // (S + A − 1) / A
```

**Assets → shares → assets** (`previewRedeem(previewDeposit(x))`), for `x > 0`:

```
assetsBack ≤ x
|x − assetsBack| ≤ ceil(A/S)    // (A + S − 1) / S
```

### 2. Transition Invariants

#### Claimed + earned never decreases

**`_assertActorTotalRewardsMonotonicity`**: `ghost_claimedRewards[actor] + rewarder.earned(actor)` must not decrease across any step, within `REWARD_ROUNDING_TOLERANCE` (1 wei) for `_allocation` flooring.

```
post ≥ pre − REWARD_ROUNDING_TOLERANCE
```

#### stakeExcess exact buffer

**`_assertStakeExcessExactBufferInvariant`**: after `stakeExcess`, liquid asset balance equals exact redemption obligation.

```
IERC20(asset).balanceOf(operatorStaking) == previewRedeem(totalSharesInRedemption())
```

#### Redeem transfer and accounting

**`_assertRedeemTransitionInvariants`**: after `redeem(shares)`:

```
effectiveShares = (shares == type(uint256).max) ? maxRedeem(actor) : shares
expectedAssets = previewRedeem(effectiveShares)    // captured before redeem()

balance_actor_after − balance_actor_before == expectedAssets
totalSharesInRedemption_before − totalSharesInRedemption_after == effectiveShares
_sharesReleased(controller)_after − _sharesReleased(controller)_before == effectiveShares
```

### 3. Equivalence Scenarios

#### `depositEquivalenceScenario`

**Intent:** `deposit(a + b)` ≡ `deposit(a) + deposit(b)`.

```
Path A:  deposit(a) -> deposit(b) -> read state -> revert
Path B:  deposit(a + b) -> read state
```

**Shares** are not asserted equal. On Path A, the truncation from `deposit(a)` shifts the exchange rate by a small amount proportional to `1 / (totalAssets + a)`. When `deposit(b)` executes at this shifted rate, it produces fewer shares than if both amounts were deposited together. Combined with up to 1 unit of rounding from each floor operation, the maximum share difference is:

```
|shares_A − shares_B| ≤ b / (totalAssets + 1 + a) + 2
```

**Earned**: Asserts that each path's `earned()` result differs by less than **2 wei** (two `transferHook` floors on path A vs one on path B).

#### `requestRedeemEquivalenceScenario`

**Intent:** `requestRedeem(a + b)` ≡ `requestRedeem(a) + requestRedeem(b)`.

```
Path A:  requestRedeem(a) -> requestRedeem(b) -> read state -> revert
Path B:  requestRedeem(a + b) -> read state
```

Same-timestamp `pendingRedeemRequest` must match exactly.

---

## Known Limitations

`ghost_claimedRewards` drift:

Phantom rewards are caught via expected reverts, but the underlying phantom debt remains on the rewarder's books. This blocks the affected actor from successfully calling `claimRewards()` until their shares burn via `requestRedeem` (which adjusts `_rewardsPaid` in `transferHook`). During this period, `ghost_claimedRewards[actor]` under-counts actual accrued rewards.

Once a truncation shortfall exists, direct token donations cannot always close it. A dominant redeemer's floating shares absorb injected value proportionally, meaning `previewRedeem` rises in lockstep with the bailout. Closing a 1-wei gap requires donating approximately `totalAssets / 100` (TVL-proportional, not shortfall-proportional).

---

## Running Tests

### Install dependencies

From the repository root:

```bash
cd contracts/staking
npm install
forge install foundry-rs/forge-std --no-git
```

### Run the tests

```bash
# All tests
npm test:fuzz
# or
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

# HTML report — install the lcov package if necessary
# macOS: brew install lcov 
# Ubuntu/Debian: apt install lcov
forge coverage --report lcov
genhtml lcov.info -o coverage
open coverage/index.html
```
