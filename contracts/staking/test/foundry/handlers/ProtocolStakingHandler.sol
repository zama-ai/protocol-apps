// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/* solhint-disable var-name-mixedcase */ // ghost_variables prefix

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Test} from "forge-std/Test.sol";
import {ZamaERC20} from "token/contracts/ZamaERC20.sol";
import {ProtocolStakingHarness} from "./../harness/ProtocolStakingHarness.sol";

/// @title ProtocolStakingHandler
/// @notice Invariant-test handler for ProtocolStaking. Wraps all state-changing actions
///         with bounded fuzz inputs and per-transition invariant checks.
///
/// @dev Two opposing floor-division phenomena compete in the reward debt accounting system.
///      Their interaction bounds the total divergence to at most N wei (not 2N), where N
///      is the maximum number of simultaneously eligible accounts.
///
///      Truncation dust (test_MaxNormalTruncationDust): each call to earned() floor-divides
///      `rewardPool × weight / totalWeight` independently per account. The sum of N floors
///      is strictly less than the pool total, pulling the reward debt LHS DOWN by at most
///      N − 1 wei across all accounts.
///
///      Phantom wei / compound dilution trap (test_DilutionTrap, test_CompoundPhantomWei):
///      after an account claims rewards, each subsequent dilution event (a new eligible
///      staker entering) can drop the account's allocation by 1 more wei via the same
///      mulDiv truncation. The shortfall of one entrant's virtualAmount is < 1 wei and
///      distributes proportionally across all phantom accounts, so the TOTAL phantom
///      across all accounts increases by at most 1 per dilution event — not 1 per account
///      per dilution. This pulls the reward debt LHS UP by at most N + D wei in total.
///
///      Because truncation dust and phantom pull in opposite directions they partially
///      cancel. The combined bound is N + D wei, tracked as two independent terms.
///      Budget: ghost_maxEligibleAccounts + ghost_dilutionOps.
///
///      A designated outgroup (bottom 20% of actors) is never made eligible. This keeps
///      ghost_maxEligibleAccounts a strict static bound regardless of fuzz sequencing.
contract ProtocolStakingHandler is Test {
    ProtocolStakingHarness public protocolStaking;
    ZamaERC20 public zama;

    address public manager;
    address[] public actors;
    mapping(address => bool) public isOutgroup;

    // @dev Maximum duration to warp the block timestamp by.
    uint256 public constant MAX_PERIOD_DURATION = 365 days * 3;
    // @dev Maximum unstake cooldown period. Must be <= 365 days for required checks.
    uint256 public constant MAX_UNSTAKE_COOLDOWN_PERIOD = 365 days;
    // @dev Maximum reward rate.
    uint256 public constant MAX_REWARD_RATE = 1e24;

    // The 2-step path (Path B) incurs up to 2 wei of compounding truncation drift
    // compared to a 1-step action (Path A) due to intermediate virtual pool updates.
    // See: test_MaxNormalTruncationDust in ProtocolStakingInvariantTest.t.sol for more details.
    uint256 internal constant EQUIVALENCE_EARNED_TOLERANCE = 2;

    // A single protocol action can update the virtual pool using truncated math.
    // The continuous loss is strictly < 1 wei, meaning a user's floored `earned()`
    // balance can drop by a maximum of exactly 1 wei across a single state transition.
    uint256 internal constant TRANSITION_EARNED_TOLERANCE = 1;

    uint256 public ghost_maxEligibleAccounts;

    uint256 public ghost_accumulatedRewardCapacity;
    uint256 public ghost_currentRate;
    uint256 public ghost_initialTotalSupply;

    mapping(address => uint256) public ghost_claimed;
    mapping(address => uint256) public ghost_totalStaked;
    mapping(address => uint256) public ghost_totalReleased;

    // Counts weight-decrease operations (unstake on eligible accounts, removeEligibleAccount with
    // staked balance) that trigger mulDiv truncation in _updateRewards, inflating _totalVirtualPaid
    // by at most 1 wei each. Used as the tolerance for invariant_TotalSupplyBoundedByRewardRate.
    uint256 public ghost_truncationOps;

    // Counts weight-increase operations (stake by eligible accounts, addEligibleAccount for accounts
    // with existing balance) that are the dilution events responsible for compounding phantom wei.
    // Each such event can drop a phantom account's allocation by 1 more wei, increasing the phantom
    // beyond the initial 1-wei-per-account bound. Added as a separate term in computeRewardDebtTolerance.
    // See: test_CompoundPhantomWei.
    uint256 public ghost_dilutionOps;

    // Flag to exempt an account from the awaitingRelease monotonicity check
    address public ghost_releasedAccount;

    constructor(ProtocolStakingHarness _protocolStaking, ZamaERC20 _zama, address _manager, address[] memory _actors) {
        require(_actors.length > 0, "need at least one actor");
        protocolStaking = _protocolStaking;
        zama = _zama;
        manager = _manager;
        actors = _actors;
        ghost_currentRate = _protocolStaking.rewardRate();
        ghost_initialTotalSupply = _zama.totalSupply();

        uint256 outgroupCount = _actors.length / 5;
        uint256 outgroupStartIndex = _actors.length - outgroupCount;
        for (uint256 i = outgroupStartIndex; i < _actors.length; i++) {
            isOutgroup[_actors[i]] = true;
        }
        ghost_maxEligibleAccounts = outgroupStartIndex;
    }

    // **************** Transition Invariant Modifiers ****************

    /// @dev Master modifier to check all transition invariants (State A -> State B)
    modifier assertTransitionInvariants() {
        uint256 actorsLen = actors.length;

        // Allocate memory for pre-states
        uint256[] memory preClaimedEarned = new uint256[](actorsLen);
        uint256[] memory preAwaitingRelease = new uint256[](actorsLen);
        uint48[] memory preKeys = new uint48[](actorsLen);
        uint208[] memory preValues = new uint208[](actorsLen);
        bool[] memory hadCheckpoint = new bool[](actorsLen);

        // Capture pre-states: Awaiting Release, Claimed + Earned, and Unstake Queue.
        for (uint256 i = 0; i < actorsLen; i++) {
            address account = actors[i];
            preAwaitingRelease[i] = protocolStaking.awaitingRelease(account);
            preClaimedEarned[i] = ghost_claimed[account] + protocolStaking.earned(account);

            uint256 count = _getUnstakeRequestCheckpointCount(account);
            if (count > 0) {
                (preKeys[i], preValues[i]) = _getUnstakeRequestCheckpointAt(account, count - 1);
                hadCheckpoint[i] = true;
            }
        }

        _; // Execute the handler action

        // Assert post-states for all transition invariants.
        for (uint256 i = 0; i < actorsLen; i++) {
            address account = actors[i];
            _assertClaimedPlusEarnedTransition(account, preClaimedEarned[i]);
            _assertAwaitingReleaseTransition(account, preAwaitingRelease[i]);
            _assertUnstakeQueueMonotonicityTransition(account, hadCheckpoint[i], preKeys[i], preValues[i]);
        }

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

    function _assertUnstakeQueueMonotonicityTransition(
        address account,
        bool hadCheckpoint,
        uint48 preKey,
        uint208 preValue
    ) internal view {
        uint256 count = _getUnstakeRequestCheckpointCount(account);
        if (count == 0) return;

        (uint48 postKey, uint208 postValue) = _getUnstakeRequestCheckpointAt(account, count - 1);

        if (hadCheckpoint) {
            assertGe(postKey, preKey, "unstake request keys must be non-decreasing");
            if (postKey == preKey) {
                assertGe(postValue, preValue, "unstake request values must be non-decreasing for same key");
            }
        }
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
        // Reset the released account flag for the next fuzz step.
        ghost_releasedAccount = address(0);
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

    function computeRewardDebtLHS() external view returns (int256) {
        int256 sumPaid;
        uint256 sumEarned;
        for (uint256 i = 0; i < actors.length; i++) {
            address account = actors[i];
            sumPaid += _readPaid(account);
            sumEarned += protocolStaking.earned(account);
        }
        return sumPaid + SafeCast.toInt256(sumEarned);
    }

    function computeRewardDebtRHS() external view returns (int256) {
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

    /**
     * @notice Calculates the maximum acceptable wei deviation for the reward debt invariant.
     * @dev The total tolerance is the sum of two independent bounds:
     *
     * Term 1 — ghost_maxEligibleAccounts (N):
     *   Two opposing rounding forces partially cancel, giving a net bound of N wei.
     *   - Truncation Dust: integer division in earned() causes each of the N active accounts
     *     to lose up to 1 wei of fractional reward, pulling LHS DOWN by at most (N - 1) wei.
     *   - Phantom Wei (initial): after a claim, a single dilution event can strand 1 wei in
     *     _paid above the account's new allocation, pulling LHS UP by at most 1 wei per account.
     *   Because these forces oppose each other the combined bound is N, not 2N.
     *   See: test_DilutionTrap and test_MaxNormalTruncationDust.
     *
     * Term 2 — ghost_dilutionOps (D):
     *   Each weight-increase operation (stake by an eligible account, or addEligibleAccount for
     *   an account with existing balance) is a dilution event that adjusts the virtual pool via
     *   a truncated mulDiv. While an account is already in the phantom zone (earned == 0), each
     *   such event can drop its allocation by 1 more wei, compounding its phantom beyond the
     *   initial 1-wei-per-account assumption. The phantom for a single account grows by at most
     *   1 per dilution event, so D events add at most D additional wei to the LHS upward pressure.
     *   See: test_CompoundPhantomWei.
     *
     * @return The maximum allowable rounding error in wei: N + D.
     */
    function computeRewardDebtTolerance() external view returns (uint256) {
        return ghost_maxEligibleAccounts + ghost_dilutionOps;
    }

    // **************** ProtocolStaking actions ****************

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

        // Outgroup accounts are not ever eligible to earn rewards
        if (isOutgroup[account]) return;

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
        assertEq(protocolStaking.earned(account), 0, "earned(account) must be 0 after claimRewards");
        ghost_claimed[account] += amount;
    }

    function release() external assertTransitionInvariants {
        address account = msg.sender;
        uint256 awaitingBefore = protocolStaking.awaitingRelease(account);
        protocolStaking.release(account);
        uint256 awaitingAfter = protocolStaking.awaitingRelease(account);
        ghost_totalReleased[account] += (awaitingBefore - awaitingAfter);
        ghost_releasedAccount = account;
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
        // TODO: Weight is not expected to be strictly equal, might want to try to break the equivalence invariant
        // have not found a counter example for now
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
