// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/* solhint-disable var-name-mixedcase */ // ghost_variables prefix
/* solhint-disable max-states-count*/

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Test} from "forge-std/Test.sol";
import {ZamaERC20} from "token/contracts/ZamaERC20.sol";
import {ProtocolStakingHarness} from "./../harness/ProtocolStakingHarness.sol";

/// @title ProtocolStakingHandler
/// @notice Invariant-test handler for ProtocolStaking. Wraps all state-changing actions
///         with bounded fuzz inputs and per-transition invariant checks.
///
/// @dev Floor division in _allocation (mulDiv) causes two independent rounding phenomena.
///      Both stem from the same `floor(Pool × share / total)` operation inside _updateRewards
///      and earned(), but they affect different invariants and pull in opposite directions.
///
///      --- Reward Conservation (invariant_RewardConservation) ---
///
///      Actor total  = Σ _paid(account) + Σ earned(account)
///      Protocol total (Pool) = _totalVirtualPaid + historicalReward
///      Invariant: |actor total − protocol total| ≤ N + D
///
///      Truncation dust — pulls actor total DOWN (test_MaxNormalTruncationDust):
///        earned() computes floor(Pool × w / W) independently per account. The sum of N
///        individual floors is at most N − 1 less than the pool, so the actor total falls
///        below the protocol total by up to N − 1 wei.
///
///      Phantom wei — pulls actor total UP (test_DilutionTrap, test_CompoundPhantomWei):
///        Each weight-increase op adds floor(Pool × Δw / W) to _totalVirtualPaid. The floor
///        means the increase is slightly less than the exact proportional share, so each
///        event adds < 1 wei of phantom: existing accounts' allocations sum to more than the
///        new pool, stranding wei in _paid (the reward debt) of anyone who already claimed.
///        D events pull the actor total up by at most D wei.
///
///      Budget: ghost_maxEligibleAccounts (N) + ghost_dilutionOps (D).
///
///      --- Total Supply Bound (invariant_TotalSupplyBoundedByRewardRate) ---
///
///      Each weight-decrease op (unstake by eligible account, removeEligibleAccount with
///      balance) subtracts floor(Pool × Δw / W) from _totalVirtualPaid. The floor means the
///      subtraction is slightly less than the exact proportional share, leaving _totalVirtualPaid
///      higher than it should be — inflating Pool by up to 1 wei. A subsequent claimer at
///      full weight can mint that extra wei, exceeding the authorized reward cap by 1.
///
///      Budget: ghost_truncationOps.

contract ProtocolStakingHandler is Test {
    // *** Protocol contracts ***

    ProtocolStakingHarness public protocolStaking;
    ZamaERC20 public zama;

    // *** Actor set ***

    address public manager;
    address[] public actors;

    // *** Fuzz bounds ***

    uint256 public constant MAX_PERIOD_DURATION = 365 days * 3;
    uint256 public constant MAX_UNSTAKE_COOLDOWN_PERIOD = 365 days;
    uint256 public constant MAX_REWARD_RATE = 1e24;

    // *** Tolerance constants ***
    //
    // TRANSITION_EARNED_TOLERANCE (1): a single pool update floors earned() by at most 1 wei.
    // EQUIVALENCE_EARNED_TOLERANCE (2): Path B has one extra pool update vs Path A, adding ≤1 more floor.

    uint256 internal constant TRANSITION_EARNED_TOLERANCE = 1;
    uint256 internal constant EQUIVALENCE_EARNED_TOLERANCE = 2;

    // *** Ghost state — reward accounting ***

    uint256 public ghost_initialTotalSupply;
    uint256 public ghost_accumulatedRewardCapacity; // Σ(δT_i × rewardRate_i), updated on every warp
    uint256 public ghost_currentRate;

    mapping(address => uint256) public ghost_claimed;
    mapping(address => uint256) public ghost_totalStaked;
    mapping(address => uint256) public ghost_totalReleased;

    // *** Ghost state — tolerance counters ***
    //
    // ghost_truncationOps: weight-decrease ops (unstake on eligible accounts,
    //   removeEligibleAccount with balance). The floored subtraction from _totalVirtualPaid
    //   leaves Pool inflated by ≤1 wei each, enabling up to 1 extra token mint per op.
    //   Tolerance for invariant_TotalSupplyBoundedByRewardRate.
    //
    // ghost_dilutionOps: weight-increase ops (stake by eligible accounts,
    //   addEligibleAccount with balance). The floored addition to _totalVirtualPaid is
    //   slightly less than the exact share, creating ≤1 phantom wei per event that strands
    //   in _paid (the reward debt) of prior claimants, pulling the actor total UP.
    //   Tolerance term D in computeRewardConservationTolerance.
    //
    // ghost_maxEligibleAccounts: static upper bound on simultaneously eligible accounts (N).
    //   Tolerance term N in computeRewardConservationTolerance. Fixed at construction.

    uint256 public ghost_truncationOps;
    uint256 public ghost_dilutionOps;
    uint256 public immutable GHOST_MAX_ELIGIBLE_ACCOUNTS;

    // *** Ghost state — transition flags ***
    //
    // Cleared at the end of every assertTransitionInvariants execution.

    address public ghost_releasedAccount; // exempts this account from awaitingRelease monotonicity
    address public ghost_lastClaimedActor; // triggers earned() == 0 check for this account

    constructor(ProtocolStakingHarness _protocolStaking, ZamaERC20 _zama, address _manager, address[] memory _actors) {
        require(_actors.length > 0, "need at least one actor");
        protocolStaking = _protocolStaking;
        zama = _zama;
        manager = _manager;
        actors = _actors;
        ghost_currentRate = _protocolStaking.rewardRate();
        ghost_initialTotalSupply = _zama.totalSupply();
        GHOST_MAX_ELIGIBLE_ACCOUNTS = _actors.length;
    }

    // **************** Transition Invariant Modifiers ****************

    /// @dev Master modifier to check all transition invariants (State A -> State B)
    modifier assertTransitionInvariants() {
        uint256 actorsLen = actors.length;

        // Allocate memory for pre-states
        uint256[] memory preClaimedEarned = new uint256[](actorsLen);
        uint256[] memory preAwaitingRelease = new uint256[](actorsLen);

        // Capture pre-states: Awaiting Release and Claimed + Earned.
        for (uint256 i = 0; i < actorsLen; i++) {
            address account = actors[i];
            preAwaitingRelease[i] = protocolStaking.awaitingRelease(account);
            preClaimedEarned[i] = ghost_claimed[account] + protocolStaking.earned(account);
        }

        _; // Execute the handler action

        // Assert post-states for all transition invariants.
        for (uint256 i = 0; i < actorsLen; i++) {
            address account = actors[i];
            _assertClaimedPlusEarnedTransition(account, preClaimedEarned[i]);
            _assertAwaitingReleaseTransition(account, preAwaitingRelease[i]);
        }
        _assertEarnedZeroAfterClaim();

        _resetTransitionFlags();
    }

    // **************** Transition invariant assertions ****************

    function _assertClaimedPlusEarnedTransition(address account, uint256 preClaimedEarned) internal view {
        uint256 postClaimedEarned = ghost_claimed[account] + protocolStaking.earned(account);
        // Tolerance accounts for truncation in the earned() calculation.
        assertGe(
            postClaimedEarned + TRANSITION_EARNED_TOLERANCE,
            preClaimedEarned,
            "claimed+claimable must not decrease"
        );
    }

    function _assertAwaitingReleaseTransition(address account, uint256 preAwaitingRelease) internal view {
        // Skip the monotonicity check if this specific account was just released.
        if (account == ghost_releasedAccount) return;

        // inherent check that awaiting release does not revert
        // _released[account] is always inferior or equal to the latest unstake request in _unstakeRequest[account].latest()
        uint256 postAwaitingRelease = protocolStaking.awaitingRelease(account);
        assertGe(postAwaitingRelease, preAwaitingRelease, "awaitingRelease must not decrease except after release");
    }

    function _assertEarnedZeroAfterClaim() internal view {
        if (ghost_lastClaimedActor == address(0)) return;
        assertEq(protocolStaking.earned(ghost_lastClaimedActor), 0, "earned must be 0 immediately after claimRewards");
    }

    // **************** Helper functions ****************

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 index) external view returns (address) {
        if (index >= actors.length) return address(0);
        return actors[index];
    }

    function _resetTransitionFlags() internal {
        ghost_releasedAccount = address(0);
        ghost_lastClaimedActor = address(0);
    }

    // **************** Storage reading functions ****************

    /// @dev Reads the paid amount for an account through the ProtocolStakingHarness
    function _readPaid(address account) internal view returns (int256) {
        return protocolStaking._harness_getPaid(account);
    }

    /// @dev Reads the total virtual paid amount through the ProtocolStakingHarness
    function _readTotalVirtualPaid() internal view returns (int256) {
        return protocolStaking._harness_getTotalVirtualPaid();
    }

    /// @dev Reads the historical reward through the ProtocolStakingHarness
    function _readHistoricalReward() internal view returns (uint256) {
        return protocolStaking._harness_getHistoricalReward();
    }

    /// @dev Reads the length of _unstakeRequests[account]._checkpoints for an actor through the ProtocolStakingHarness
    function _getUnstakeRequestCheckpointCount(address account) internal view returns (uint256) {
        return protocolStaking._harness_getUnstakeRequestCheckpointCount(account);
    }

    /// @dev Reads the checkpoint at index for _unstakeRequests[account] through the ProtocolStakingHarness
    function _getUnstakeRequestCheckpointAt(
        address account,
        uint256 index
    ) internal view returns (uint48 key, uint208 value) {
        return protocolStaking._harness_getUnstakeRequestCheckpointAt(account, index);
    }

    // **************** Invariant functions ****************

    /// @notice Per-account view of rewards: Σ _paid(account) + Σ earned(account).
    function computeActorRewardTotal() external view returns (int256) {
        int256 sumPaid;
        uint256 sumEarned;
        for (uint256 i = 0; i < actors.length; i++) {
            address account = actors[i];
            sumPaid += _readPaid(account);
            sumEarned += protocolStaking.earned(account);
        }
        return sumPaid + SafeCast.toInt256(sumEarned);
    }

    /// @notice Global pool view of rewards: _totalVirtualPaid + historicalReward.
    function computeProtocolRewardTotal() external view returns (int256) {
        int256 totalVirtualPaid = _readTotalVirtualPaid();
        uint256 histReward = _readHistoricalReward();
        return totalVirtualPaid + SafeCast.toInt256(histReward);
    }

    function computeExpectedTotalWeight() external view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            address account = actors[i];
            if (protocolStaking.isEligibleAccount(account)) {
                total += protocolStaking.weight(protocolStaking.balanceOf(account));
            }
        }
    }

    /// @notice Maximum acceptable wei deviation: |actorTotal − protocolTotal| ≤ N + D.
    /// @dev N (truncation dust) pulls actor total DOWN by up to N − 1 wei (see test_MaxNormalTruncationDust).
    ///      D (phantom wei) pulls actor total UP by up to D wei (see test_DilutionTrap, test_CompoundPhantomWei).
    ///      Worst-case tolerance bounded conservatively by N + D.
    function computeRewardConservationTolerance() external view returns (uint256) {
        return GHOST_MAX_ELIGIBLE_ACCOUNTS + ghost_dilutionOps;
    }

    // **************** ProtocolStaking actions ****************
    //
    // Actor identity via targetSender:
    //   The test contract registers each entry in `actors` with Foundry's `targetSender()`.
    //   On every fuzz call Foundry picks one of those addresses as `msg.sender`, so inside
    //   every handler function `msg.sender` is always a known actor from the `actors` array.
    //   Handler actions that the actor performs directly (stake, unstake, claimRewards,
    //   release) read `address actor = msg.sender` and prank as that address.
    //   Actions that require manager privileges (setRewardRate, addEligibleAccount,
    //   removeEligibleAccount, setUnstakeCooldownPeriod) still use `msg.sender` to select
    //   which account is affected, but prank as `manager` to satisfy the access-control check.

    /// @dev Move the block timestamp forward by a given duration.
    function warp(uint256 duration) public assertTransitionInvariants {
        duration = bound(duration, 1, MAX_PERIOD_DURATION);

        // If there are no staked tokens, the accumulated reward capacity is not updated
        if (protocolStaking.totalStakedWeight() > 0) {
            ghost_accumulatedRewardCapacity += ghost_currentRate * duration;
        }
        vm.warp(block.timestamp + duration);
    }

    function setRewardRate(uint256 rate) external assertTransitionInvariants {
        rate = bound(rate, 0, MAX_REWARD_RATE);
        vm.prank(manager);
        protocolStaking.setRewardRate(rate);
        ghost_currentRate = rate;
    }

    function addEligibleAccount() public assertTransitionInvariants {
        address account = msg.sender;

        if (!protocolStaking.isEligibleAccount(account) && protocolStaking.balanceOf(account) > 0) {
            ghost_dilutionOps++;
        }
        vm.prank(manager);
        protocolStaking.addEligibleAccount(account);
    }

    function removeEligibleAccount() external assertTransitionInvariants {
        address account = msg.sender;
        if (protocolStaking.isEligibleAccount(account) && protocolStaking.balanceOf(account) > 0) {
            ghost_truncationOps++;
        }
        vm.prank(manager);
        protocolStaking.removeEligibleAccount(account);
    }

    function setUnstakeCooldownPeriod(uint256 cooldownPeriod) external assertTransitionInvariants {
        cooldownPeriod = bound(cooldownPeriod, 1, MAX_UNSTAKE_COOLDOWN_PERIOD - 1);
        vm.prank(manager);
        protocolStaking.setUnstakeCooldownPeriod(SafeCast.toUint48(cooldownPeriod));
    }

    function stake(uint256 amount) public assertTransitionInvariants {
        address actor = msg.sender;
        uint256 balance = zama.balanceOf(actor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        if (protocolStaking.isEligibleAccount(actor)) {
            ghost_dilutionOps++;
        }
        vm.prank(actor);
        protocolStaking.stake(amount);
        ghost_totalStaked[actor] += amount;
    }

    function unstake(uint256 amount) public assertTransitionInvariants {
        address actor = msg.sender;
        uint256 stakedBalance = protocolStaking.balanceOf(actor);
        if (stakedBalance == 0) return;
        amount = bound(amount, 1, stakedBalance);
        if (protocolStaking.isEligibleAccount(actor)) {
            ghost_truncationOps++;
        }
        vm.prank(actor);
        protocolStaking.unstake(amount);
    }

    function claimRewards() external assertTransitionInvariants {
        address account = msg.sender;
        uint256 amount = protocolStaking.earned(account);
        protocolStaking.claimRewards(account);
        ghost_claimed[account] += amount;
        ghost_lastClaimedActor = account;
    }

    function release() external assertTransitionInvariants {
        address account = msg.sender;
        uint256 awaitingBefore = protocolStaking.awaitingRelease(account);
        protocolStaking.release(account);
        uint256 awaitingAfter = protocolStaking.awaitingRelease(account);
        ghost_totalReleased[account] += (awaitingBefore - awaitingAfter);
        ghost_releasedAccount = account;
    }

    /// @dev Routes msg.sender's future reward mints to any address.
    ///      address(0) resets to mint-to-self. Only the mint target changes, not the accounting.
    function setRewardsRecipient(address recipient, uint256 index, bool isActor) external assertTransitionInvariants {
        if (isActor) {
            // overrides recipient by one of the actors
            index = bound(index, 0, actors.length - 1);
            recipient = actors[index];
        }
        vm.prank(msg.sender);
        protocolStaking.setRewardsRecipient(recipient);
    }

    /// @notice Unstake then warp past cooldown to allow for valid release() calls.
    function unstakeThenWarp() external assertTransitionInvariants {
        address account = msg.sender;
        uint256 stakedBalance = protocolStaking.balanceOf(account);
        if (stakedBalance == 0) return;

        unstake(stakedBalance);

        uint256 cooldown = protocolStaking.unstakeCooldownPeriod();
        warp(cooldown + 1);
    }

    // **************** Equivalence scenario handlers ****************
    //
    // Purpose:
    //   These functions verify that two different execution paths to the same logical outcome
    //   produce identical on-chain state. They are registered as fuzzable handler actions so
    //   Foundry exercises them organically within invariant sequences, subjecting the comparison
    //   to arbitrary prior history rather than a clean initial state.
    //
    // Mechanism:
    //   Each scenario uses vm.snapshotState() to fork EVM state, runs Path A, captures results,
    //   reverts to the snapshot via vm.revertToState(), then runs Path B on the live state.
    //   Path B's final state persists and becomes part of the ongoing fuzz sequence, meaning
    //   subsequent handler calls build on a real execution path.

    // Compare stake(amount1+amount2) once vs stake(amount1) then stake(amount2).
    function stakeEquivalenceScenario(uint256 amount1, uint256 amount2, uint256 duration) external {
        address account = msg.sender;

        addEligibleAccount();

        uint256 balance = zama.balanceOf(account);
        if (balance < 2) return;
        amount1 = bound(amount1, 1, balance - 1);
        amount2 = bound(amount2, 1, balance - amount1);
        uint256 totalAmount = amount1 + amount2;

        duration = bound(duration, 1, MAX_PERIOD_DURATION);

        uint256 snapshot = vm.snapshotState();

        // Path A: single stake
        stake(totalAmount);
        uint256 sharesSingle = protocolStaking.balanceOf(account);
        uint256 weightSingle = protocolStaking.weight(protocolStaking.balanceOf(account));

        // Warp past the duration to allow for valid earned() calls.
        warp(duration);
        uint256 earnedSingle = protocolStaking.earned(account);

        vm.revertToState(snapshot);

        // Path B: double stake
        stake(amount1);
        stake(amount2);
        uint256 sharesDouble = protocolStaking.balanceOf(account);
        uint256 weightDouble = protocolStaking.weight(protocolStaking.balanceOf(account));

        warp(duration);
        uint256 earnedDouble = protocolStaking.earned(account);

        assertEq(sharesDouble, sharesSingle, "stake equivalence: shares");
        // Since weight = floor(sqrt(balance)), equal inputs should guarantee equal outputs.
        assertEq(weightDouble, weightSingle, "stake equivalence: weight");
        assertApproxEqAbs(earnedDouble, earnedSingle, EQUIVALENCE_EARNED_TOLERANCE, "stake equivalence: earned");
    }

    // Compare partial unstake (to targetStake) vs unstake all then stake(targetStake).
    function unstakeEquivalenceScenario(uint256 initialStake, uint256 targetStake, uint256 duration) external {
        address account = msg.sender;

        addEligibleAccount();

        uint256 balance = zama.balanceOf(account);
        // Need at least 2 to stake, and leave at least 1 for path B restake (unstaked tokens are queued until release)
        if (balance < 3) return;
        initialStake = bound(initialStake, 2, balance - 1);
        // targetStake must be <= balance - initialStake so path B can restake
        targetStake = bound(targetStake, 1, Math.min(initialStake - 1, balance - initialStake));
        uint256 unstakeAmount = initialStake - targetStake;
        duration = bound(duration, 1, MAX_PERIOD_DURATION);

        uint256 snapshot = vm.snapshotState();

        stake(initialStake);
        warp(duration);

        // Path A: partial unstake
        unstake(unstakeAmount);
        uint256 sharesPartial = protocolStaking.balanceOf(account);
        uint256 weightPartial = protocolStaking.weight(protocolStaking.balanceOf(account));

        warp(duration);
        uint256 earnedPartial = protocolStaking.earned(account);

        vm.revertToState(snapshot);

        // Path B: unstake all then restake target
        stake(initialStake);
        warp(duration);

        unstake(initialStake);
        stake(targetStake);
        uint256 sharesRestaked = protocolStaking.balanceOf(account);
        uint256 weightRestaked = protocolStaking.weight(protocolStaking.balanceOf(account));

        warp(duration);
        uint256 earnedRestaked = protocolStaking.earned(account);

        assertEq(sharesRestaked, sharesPartial, "unstake equivalence: shares");
        assertEq(weightRestaked, weightPartial, "unstake equivalence: weight");
        assertApproxEqAbs(earnedRestaked, earnedPartial, EQUIVALENCE_EARNED_TOLERANCE, "unstake equivalence: earned");
    }
}
