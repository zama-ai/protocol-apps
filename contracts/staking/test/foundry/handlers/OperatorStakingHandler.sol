// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/* solhint-disable var-name-mixedcase */ // ghost_variables prefix
/* solhint-disable max-states-count */

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Test} from "forge-std/Test.sol";
import {ZamaERC20} from "token/contracts/ZamaERC20.sol";
import {OperatorRewarder} from "./../../../contracts/OperatorRewarder.sol";
import {OperatorStakingHarness} from "./../harness/OperatorStakingHarness.sol";
import {ProtocolStakingHarness} from "./../harness/ProtocolStakingHarness.sol";

/// @title OperatorStakingHandler
/// @notice Invariant-test handler for OperatorStaking. Wraps all state-changing actions
///         with bounded fuzz inputs and per-transition invariant checks.
///
/// @dev Two known floor-division phenomena each allow the system to diverge by at most
///      ceil(totalAssets / totalShares) wei per triggering deposit. Shortfalls within
///      budget are asserted to produce the expected ERC20InsufficientBalance revert
///      rather than failing the test.
///
///      Staking-side (test_IlliquidityBug_TruncationLeak):
///         Shares and assets are related by an exchange rate: each share is worth
///         (totalAssets / totalShares) in assets. When a deposit converts assets into
///         shares, the result is rounded down to a whole number because Solidity has no
///         fractions. The fractional share that gets truncated (always less than 1 whole
///         share) is not minted to the depositor, but the corresponding assets still
///         enter the vault. Even though this leftover is less than 1 share, it maps to a
///         real, nonzero amount of assets: up to (totalAssets / totalShares) - 1 wei.
///         Those unowned assets raise the exchange rate, which inflates previewRedeem for
///         every outstanding share — including shares sitting in the redemption queue.
///         The per-deposit obligation increase is strictly less than
///         (totalAssets / totalShares), so ceil(totalAssets / totalShares) is a sound
///         upper bound per deposit while redemptions are queued.

///         Budget:
///         --------------------------------
///         ghost_globalRedemptionBudget: running sum of ceil(totalAssets / totalShares)
///         for each deposit made while redemptions are queued.
///         --------------------------------
///         ghost_actorDepositBudget: Per-actor budget, running sum of ceil(totalAssets / totalShares)
///         for all deposits by that actor.
///         --------------------------------
///
///      Rewarder-side (test_PhantomRewardBug_RewarderInsolvency):
///         Sequential deposits each floor-divide independently in transferHook._allocation. Rounding down
///         multiple times individually can lose more total precision than rounding once on
///         the combined value, so earned() can return 1 phantom wei that the rewarder
///         cannot cover.
///
///         Budget:
///         --------------------------------
///         ghost_rewarderDepositCount: number of deposits while totalSupply > 0.
///         --------------------------------
contract OperatorStakingHandler is Test {
    // -------------------------------------------------------------------
    //  State
    // -------------------------------------------------------------------

    OperatorStakingHarness public operatorStaking;
    ZamaERC20 public assetToken;
    ProtocolStakingHarness public protocolStaking;
    OperatorRewarder public rewarder;

    struct PendingRedeem {
        address controller;
        uint48 releaseTime;
    }

    uint256 public constant MAX_PERIOD_DURATION = 365 days * 3;
    uint256 public constant REWARD_ROUNDING_TOLERANCE = 1;

    address[] public actors;
    mapping(address => uint256) public actorPrivateKeys;

    // -------------------------------------------------------------------
    //  Ghost accounting — per-actor
    // -------------------------------------------------------------------

    /// @dev Cumulative assets deposited by each actor.
    mapping(address => uint256) public ghost_deposited;

    /// @dev Cumulative assets received from redeems by each actor.
    mapping(address => uint256) public ghost_redeemed;

    /// @dev Cumulative rewards claimed by each actor.
    mapping(address => uint256) public ghost_claimedRewards;

    /// @dev Number of redeems per actor (1 wei rounding tolerance each).
    mapping(address => uint256) public ghost_actorRedeemCount;

    // -------------------------------------------------------------------
    //  Ghost accounting — tolerance budgets
    // -------------------------------------------------------------------

    /// @dev Staking-side budget: accumulates ceil(totalAssets / totalShares) for deposits
    ///      made while totalSharesInRedemption > 0. Bounds the total possible truncation leak.
    uint256 public ghost_globalRedemptionBudget;

    /// @dev Per-actor budget: accumulates ceil(totalAssets / totalShares) for deposits made
    ///      by each actor.
    mapping(address => uint256) public ghost_actorDepositBudget;

    /// @dev Rewarder-side budget: counts deposits made while totalSupply > 0.
    uint256 public ghost_rewarderDepositCount;

    // -------------------------------------------------------------------
    //  Ghost state — transition checks
    // -------------------------------------------------------------------

    mapping(address => uint256) private _preTotalRewards;
    bool public ghost_stakeExcessCalled;
    bool public ghost_redeemCalled;
    uint256 public ghost_lastRedeemExpected;
    uint256 public ghost_lastRedeemAssets;
    uint256 public ghost_lastRedeemEffectiveShares;
    uint256 public ghost_lastRedeemPreTotalInRedemption;
    uint256 public ghost_lastRedeemPreSharesReleased;
    address public ghost_lastRedeemActor;
    address public ghost_lastPermitActor;
    PendingRedeem[] public ghost_pendingRedeems;

    // -------------------------------------------------------------------
    //  Constructor
    // -------------------------------------------------------------------

    constructor(
        OperatorStakingHarness _operatorStaking,
        ZamaERC20 _assetToken,
        ProtocolStakingHarness _protocolStaking,
        address[] memory _actors,
        uint256[] memory _actorPrivateKeys
    ) {
        require(_actors.length > 0, "need at least one actor");
        operatorStaking = _operatorStaking;
        assetToken = _assetToken;
        protocolStaking = _protocolStaking;
        rewarder = OperatorRewarder(_operatorStaking.rewarder());
        actors = _actors;
        for (uint256 i = 0; i < _actors.length; i++) {
            actorPrivateKeys[_actors[i]] = _actorPrivateKeys[i];
        }
    }

    // -------------------------------------------------------------------
    //  Transition invariant modifier
    // -------------------------------------------------------------------

    /// @dev Wraps every handler action with pre/post invariant checks.
    modifier assertTransitionInvariants() {
        _snapshotActorTotalRewards();
        _;
        _assertActorTotalRewardsMonotonicity();
        _assertStakeExcessExactBufferInvariant();
        _assertRedeemTransitionInvariants();
        _repairAllowanceAfterPermit();
    }

    // -------------------------------------------------------------------
    //  Transition invariant checks
    // -------------------------------------------------------------------

    function _snapshotActorTotalRewards() internal {
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            _preTotalRewards[actor] = ghost_claimedRewards[actor] + rewarder.earned(actor);
        }
    }

    /// @dev Total rewards (claimed + unclaimed) must never decrease for any actor.
    function _assertActorTotalRewardsMonotonicity() internal view {
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            uint256 postTotal = ghost_claimedRewards[actor] + rewarder.earned(actor);
            uint256 preTotal = _preTotalRewards[actor];

            // Subtract tolerance safely to avoid underflow.
            uint256 adjustedPre = preTotal > REWARD_ROUNDING_TOLERANCE ? preTotal - REWARD_ROUNDING_TOLERANCE : 0;

            assertGe(postTotal, adjustedPre, "Transition: total rewards decreased");
        }
    }

    /// @dev After stakeExcess, liquid balance must equal previewRedeem(totalSharesInRedemption).
    function _assertStakeExcessExactBufferInvariant() internal {
        if (!ghost_stakeExcessCalled) return;
        assertEq(
            assetToken.balanceOf(address(operatorStaking)),
            operatorStaking.previewRedeem(operatorStaking.totalSharesInRedemption()),
            "Transition: stakeExcess did not leave exact redemption buffer"
        );
        ghost_stakeExcessCalled = false;
    }

    /// @dev After redeem:
    ///   1. Actual ERC20 transfer must equal the pre-call previewRedeem snapshot.
    ///   2. totalSharesInRedemption must have decreased by exactly effectiveShares.
    ///   3. _sharesReleased[controller] must have increased by exactly effectiveShares.
    ///
    ///   Note: checks 2 and 3 are gated on assets > 0. OperatorStaking.redeem only updates
    ///   the accounting block inside `if (assets > 0)`, so if previewRedeem(effectiveShares)
    ///   rounds down to 0 (e.g. redeeming a tiny number of shares), neither field changes.
    function _assertRedeemTransitionInvariants() internal {
        if (!ghost_redeemCalled) return;
        assertEq(ghost_lastRedeemAssets, ghost_lastRedeemExpected, "Transition: redeem transfer != previewRedeem");
        if (ghost_lastRedeemExpected > 0) {
            assertEq(
                ghost_lastRedeemPreTotalInRedemption - operatorStaking.totalSharesInRedemption(),
                ghost_lastRedeemEffectiveShares,
                "Transition: totalSharesInRedemption delta != effectiveShares"
            );
            assertEq(
                operatorStaking._harness_getSharesReleased(ghost_lastRedeemActor) - ghost_lastRedeemPreSharesReleased,
                ghost_lastRedeemEffectiveShares,
                "Transition: _sharesReleased delta != effectiveShares"
            );
        }
        ghost_redeemCalled = false;
    }

    // -------------------------------------------------------------------
    //  Public view helpers
    // -------------------------------------------------------------------

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 index) external view returns (address) {
        if (index >= actors.length) return address(0);
        return actors[index];
    }

    function getPendingRedeemsCount() external view returns (uint256) {
        return ghost_pendingRedeems.length;
    }

    function getPendingRedeem(uint256 index) external view returns (address controller, uint48 releaseTime) {
        PendingRedeem memory pending = ghost_pendingRedeems[index];
        return (pending.controller, pending.releaseTime);
    }

    /// @dev Returns (previewRedeem(shares), liquid + pendingRelease) for shortfall comparison.
    function getExpectedAssets(uint256 shares) public view returns (uint256 expectedAssets, uint256 availableAssets) {
        expectedAssets = operatorStaking.previewRedeem(shares);
        uint256 pendingRelease = protocolStaking._harness_amountToRelease(address(operatorStaking));
        availableAssets = assetToken.balanceOf(address(operatorStaking)) + pendingRelease;
    }

    function assertRedeemRevertsForDust(
        address actor,
        uint256 shares,
        uint256 expectedAssets,
        uint256 availableAssets
    ) public returns (bool) {
        return _assertRedeemRevertsForDust(actor, shares, expectedAssets, availableAssets);
    }

    // -------------------------------------------------------------------
    //  Internal helpers
    // -------------------------------------------------------------------

    /// @dev Permit overrides the max-approval set in setUp; restore it.
    function _repairAllowanceAfterPermit() internal {
        if (ghost_lastPermitActor != address(0)) {
            vm.prank(ghost_lastPermitActor);
            assetToken.approve(address(operatorStaking), type(uint256).max);
            ghost_lastPermitActor = address(0);
        }
    }

    /// @dev O(1) swap-and-pop removal from ghost_pendingRedeems.
    function _removePendingRedeem(uint256 index) internal {
        uint256 lastIndex = ghost_pendingRedeems.length - 1;
        if (index != lastIndex) {
            ghost_pendingRedeems[index] = ghost_pendingRedeems[lastIndex];
        }
        ghost_pendingRedeems.pop();
    }

    /// @dev Check whether a redeem would hit a truncation-leak shortfall within budget.
    ///      Returns true if the shortfall was within budget and the expected revert was asserted.
    function _assertRedeemRevertsForDust(
        address actor,
        uint256 shares,
        uint256 expectedAssets,
        uint256 availableAssets
    ) internal returns (bool) {
        if (expectedAssets <= availableAssets) return false;

        uint256 shortfall = expectedAssets - availableAssets;

        if (shortfall <= ghost_globalRedemptionBudget) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    bytes4(0xe450d38c), // ERC20InsufficientBalance(address,uint256,uint256)
                    address(operatorStaking),
                    availableAssets,
                    expectedAssets
                )
            );
            vm.prank(actor);
            operatorStaking.redeem(shares, actor, actor);
            return true;
        }
        return false;
    }

    /// @dev Check whether a claimRewards would hit a phantom-reward shortfall within budget.
    ///
    ///      Root cause: when an actor makes multiple sequential deposits, each transferHook
    ///      call independently rounds down its reward allocation and adds it to
    ///      _rewardsPaid[actor]. Later, earned() computes a single combined allocation and
    ///      rounds down once. Rounding down several small values individually can discard
    ///      more total precision than rounding the combined value once, so earned() can
    ///      report 1 phantom wei more than the sum credited via _rewardsPaid.
    ///
    ///      When a shortfall exists within the tolerance budget, the claim is
    ///      asserted to revert with ERC20InsufficientBalance and the budget is debited.
    ///      Returns true if the claim was handled (reverted as expected).
    function _assertClaimRewardsRevertsForDust(address actor, uint256 earnedAmount) internal returns (bool) {
        uint256 rewarderBalance = assetToken.balanceOf(address(rewarder));
        uint256 pendingFromProtocol = protocolStaking.earned(address(operatorStaking));

        // The rewarder will pull pending rewards from the protocol before transferring,
        // so its actual liquid balance at the time of the safeTransfer is the sum of both.
        uint256 totalAvailable = rewarderBalance + pendingFromProtocol;

        if (earnedAmount <= totalAvailable) return false;

        uint256 shortfall = earnedAmount - totalAvailable;

        if (shortfall <= ghost_rewarderDepositCount) {
            // The rewarder is insolvent by `shortfall` wei due to the phantom reward bug.
            // Assert the claim reverts with the expected ERC20InsufficientBalance error.
            vm.expectRevert(
                abi.encodeWithSelector(
                    bytes4(0xe450d38c), // ERC20InsufficientBalance(address,uint256,uint256)
                    address(rewarder),
                    totalAvailable,
                    earnedAmount
                )
            );
            vm.prank(actor);
            rewarder.claimRewards(actor);

            return true;
        }

        // Shortfall exceeds budget — fall through and let the revert surface.
        return false;
    }

    /// @dev Redeem shares. If a truncation-leak shortfall is within budget, asserts the
    ///      redeem reverts with ERC20InsufficientBalance instead of executing it.
    function _executeRedeem(address actor, uint256 shares) internal returns (uint256 assetsOut) {
        uint256 effectiveShares = shares == type(uint256).max ? operatorStaking.maxRedeem(actor) : shares;
        if (effectiveShares == 0) return 0;

        (uint256 expectedAssets, uint256 availableAssets) = getExpectedAssets(effectiveShares);
        if (_assertRedeemRevertsForDust(actor, shares, expectedAssets, availableAssets)) return 0;

        uint256 balanceBefore = assetToken.balanceOf(actor);
        ghost_lastRedeemPreTotalInRedemption = operatorStaking.totalSharesInRedemption();
        ghost_lastRedeemPreSharesReleased = operatorStaking._harness_getSharesReleased(actor);
        ghost_lastRedeemEffectiveShares = effectiveShares;
        ghost_lastRedeemActor = actor;

        vm.prank(actor);
        assetsOut = operatorStaking.redeem(shares, actor, actor);

        uint256 actualTransfer = assetToken.balanceOf(actor) - balanceBefore;
        ghost_redeemed[actor] += actualTransfer;
        ghost_lastRedeemAssets = actualTransfer;
        ghost_lastRedeemExpected = expectedAssets;
        ghost_redeemCalled = true;
        ghost_actorRedeemCount[actor]++;

        // Clean up ghost entries if actor has fully exited the redemption queue.
        bool hasPending = operatorStaking.pendingRedeemRequest(actor) > 0;
        bool hasClaimable = operatorStaking.claimableRedeemRequest(actor) > 0;
        if (!hasPending && !hasClaimable) {
            for (uint256 i = ghost_pendingRedeems.length; i > 0; i--) {
                if (ghost_pendingRedeems[i - 1].controller == actor) {
                    _removePendingRedeem(i - 1);
                }
            }
        }
    }

    function _getSignature(
        address actor,
        uint256 assets,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        uint256 privateKey = actorPrivateKeys[actor];
        bytes32 structHash = keccak256(
            abi.encode(
                0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9,
                actor,
                address(operatorStaking),
                assets,
                assetToken.nonces(actor),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", assetToken.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(privateKey, digest);
    }

    // -------------------------------------------------------------------
    //  Handler actions
    // -------------------------------------------------------------------

    function warp(uint256 duration) public assertTransitionInvariants {
        duration = bound(duration, 1, MAX_PERIOD_DURATION);
        vm.warp(block.timestamp + duration);
    }

    function deposit(uint256 assets) external assertTransitionInvariants {
        address actor = msg.sender;
        uint256 balance = assetToken.balanceOf(actor);
        if (balance == 0) return;

        assets = bound(assets, 1, balance);

        bool hasPendingRedemptions = operatorStaking.totalSharesInRedemption() > 0;
        bool transferHookFires = operatorStaking.totalSupply() > 0;

        // Capture ceil(totalAssets / totalShares) before the deposit changes totalAssets.
        uint256 S = operatorStaking.totalSupply() + operatorStaking.totalSharesInRedemption() + 100;
        uint256 A = operatorStaking.totalAssets() + 1;
        uint256 currentCeilAS = (A + S - 1) / S;

        vm.prank(actor);
        operatorStaking.deposit(assets, actor);

        ghost_deposited[actor] += assets;
        ghost_actorDepositBudget[actor] += currentCeilAS;
        if (hasPendingRedemptions) ghost_globalRedemptionBudget += currentCeilAS;
        if (transferHookFires) ghost_rewarderDepositCount++;
    }

    function depositWithPermit(uint256 assets) external assertTransitionInvariants {
        address actor = msg.sender;
        uint256 balance = assetToken.balanceOf(actor);
        if (balance == 0) return;

        assets = bound(assets, 1, balance);

        bool hasPendingRedemptions = operatorStaking.totalSharesInRedemption() > 0;
        bool transferHookFires = operatorStaking.totalSupply() > 0;

        // Capture ceil(totalAssets / totalShares) BEFORE the deposit changes totalAssets.
        uint256 S = operatorStaking.totalSupply() + operatorStaking.totalSharesInRedemption() + 100;
        uint256 A = operatorStaking.totalAssets() + 1;
        uint256 currentCeilAS = (A + S - 1) / S;

        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) = _getSignature(actor, assets, deadline);

        vm.prank(actor);
        operatorStaking.depositWithPermit(assets, actor, deadline, v, r, s);

        ghost_deposited[actor] += assets;
        ghost_lastPermitActor = actor;
        ghost_actorDepositBudget[actor] += currentCeilAS;
        if (hasPendingRedemptions) ghost_globalRedemptionBudget += currentCeilAS;
        if (transferHookFires) ghost_rewarderDepositCount++;
    }

    /// @dev Requesting redemption of 1 share returns 0 assets due to rounding, but the share
    ///      is still burned. Repeated tiny redeems can exhaust tolerance for invariant_totalRecoverableValue.
    function requestRedeem(uint256 shares) external assertTransitionInvariants {
        address actor = msg.sender;
        uint256 balance = operatorStaking.balanceOf(actor);
        if (balance == 0) return;

        uint256 allowed = Math.min(balance, type(uint208).max);
        uint256 boundedShares = bound(shares, 1, allowed);

        vm.prank(actor);
        uint48 releaseTime = operatorStaking.requestRedeem(SafeCast.toUint208(boundedShares), actor, actor);

        ghost_pendingRedeems.push(PendingRedeem({controller: actor, releaseTime: releaseTime}));
    }

    function redeem(uint256 shares) external assertTransitionInvariants {
        address actor = msg.sender;
        uint256 maxShares = operatorStaking.maxRedeem(actor);
        if (maxShares == 0) return;

        uint256 boundedShares = bound(shares, 1, maxShares);
        _executeRedeem(actor, boundedShares);
    }

    function redeemMax() external assertTransitionInvariants {
        address actor = msg.sender;
        _executeRedeem(actor, type(uint256).max);
    }

    function stakeExcess() external assertTransitionInvariants {
        uint256 awaitingRelease = protocolStaking._harness_amountToRelease(address(operatorStaking));
        uint256 liquidBalance = assetToken.balanceOf(address(operatorStaking)) + awaitingRelease;
        uint256 obligation = operatorStaking.previewRedeem(operatorStaking.totalSharesInRedemption());
        if (liquidBalance <= obligation) return;

        operatorStaking.stakeExcess();
        ghost_stakeExcessCalled = true;
    }

    /// @dev Donations inflate totalAssets without minting shares, raising the exchange rate.
    ///      When redemptions are in-flight, any subsequent deposit at the elevated rate incurs
    ///      floor-rounding truncation, leaking up to ceil(totalAssets / totalShares) wei per
    ///      deposit into the pool.
    function donate(uint256 amount) external assertTransitionInvariants {
        address actor = msg.sender;
        uint256 balance = assetToken.balanceOf(actor);
        if (balance == 0) return;

        amount = bound(amount, 1, balance);

        vm.prank(actor);
        assetToken.transfer(address(operatorStaking), amount);
    }

    /// @dev Claims rewards from the OperatorRewarder. If a phantom-reward shortfall is
    ///      within budget, asserts the claim reverts with ERC20InsufficientBalance
    ///      instead of executing it.
    function claimRewards() external assertTransitionInvariants {
        address actor = msg.sender;
        uint256 earnedAmount = rewarder.earned(actor);
        if (earnedAmount == 0) return;

        // If the phantom bug is triggered, assert the revert and exit cleanly
        if (_assertClaimRewardsRevertsForDust(actor, earnedAmount)) return;

        vm.prank(actor);
        rewarder.claimRewards(actor);
        ghost_claimedRewards[actor] += earnedAmount;
    }

    // -------------------------------------------------------------------
    //  Equivalence scenarios
    // -------------------------------------------------------------------

    /// @notice deposit(a) + deposit(b) must yield shares within a proven bound of deposit(a+b).
    ///
    ///   After deposit(a), the truncated fractional share shifts the exchange rate by a
    ///   small amount proportional to 1 / (totalAssets + a). When deposit(b) executes at
    ///   this slightly shifted rate, it can produce fewer shares than if both amounts were
    ///   deposited together. Combined with up to 1 unit of rounding from each floor
    ///   operation, the maximum share difference is:
    ///
    ///     abs(sharesA - sharesB) <= floor(amount2 / (totalAssets + amount1)) + 2
    ///
    ///   earned() can differ by at most 2 due to floor division in transferHook._allocation.
    function depositEquivalenceScenario(uint256 amount1, uint256 amount2) external {
        address actor = msg.sender;
        uint256 balance = assetToken.balanceOf(actor);
        if (balance < 2) return;

        amount1 = bound(amount1, 1, balance - 1);
        amount2 = bound(amount2, 1, balance - amount1);

        // Capture pre-deposit state for tolerance computation.
        uint256 A = operatorStaking.totalAssets() + 1;
        uint256 sharesTolerance = amount2 / (A + amount1) + 2;

        uint256 snapshot = vm.snapshotState();

        // Path A: two deposits via the handler (maintains all ghost state and transition checks).
        vm.prank(actor);
        this.deposit(amount1);
        vm.prank(actor);
        this.deposit(amount2);
        uint256 sharesPathA = operatorStaking.balanceOf(actor);
        uint256 earnedPathA = rewarder.earned(actor);

        vm.revertToState(snapshot);

        // Path B: single deposit of sum (surviving path — ghost state updated by handler).
        vm.prank(actor);
        this.deposit(amount1 + amount2);
        uint256 sharesPathB = operatorStaking.balanceOf(actor);
        uint256 earnedPathB = rewarder.earned(actor);

        assertApproxEqAbs(
            sharesPathA,
            sharesPathB,
            sharesTolerance,
            "depositEquivalence: share difference exceeds proven bound"
        );
        assertApproxEqAbs(earnedPathA, earnedPathB, 2, "depositEquivalence: earned differs by > 2");
    }

    /// @notice requestRedeem(a) + requestRedeem(b) must yield the same pending shares
    ///         as requestRedeem(a+b). Both requests happen at the same timestamp so the
    ///         contract must accumulate them into the same checkpoint window.
    function requestRedeemEquivalenceScenario(uint256 amount1, uint256 amount2) external {
        address actor = msg.sender;
        uint256 balance = operatorStaking.balanceOf(actor);
        if (balance < 2) return;

        amount1 = bound(amount1, 1, balance - 1);
        amount2 = bound(amount2, 1, balance - amount1);

        uint256 snapshot = vm.snapshotState();

        // Path A: two requestRedeems.
        vm.prank(actor);
        this.requestRedeem(amount1);
        vm.prank(actor);
        this.requestRedeem(amount2);
        uint256 pendingPathA = operatorStaking.pendingRedeemRequest(actor);

        vm.revertToState(snapshot);

        // Path B: single requestRedeem of sum (surviving path — ghost state updated by handler).
        vm.prank(actor);
        this.requestRedeem(amount1 + amount2);
        uint256 pendingPathB = operatorStaking.pendingRedeemRequest(actor);

        assertEq(pendingPathA, pendingPathB, "requestRedeemEquivalence: pending shares differ");
    }
}
