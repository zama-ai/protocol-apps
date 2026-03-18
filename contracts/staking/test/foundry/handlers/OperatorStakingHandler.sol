// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ZamaERC20} from "token/contracts/ZamaERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {ProtocolStakingHarness} from "./../harness/ProtocolStakingHarness.sol";
import {OperatorStakingHarness} from "./../harness/OperatorStakingHarness.sol";
import {OperatorRewarder} from "./../../../contracts/OperatorRewarder.sol";

/// @title OperatorStakingHandler
/// @notice Invariant-test handler for OperatorStaking. Wraps all state-changing actions
///         with bounded fuzz inputs and per-transition invariant checks.
///
/// @dev Tolerance budget system
///
///   Direct token donations inflate totalAssets without minting shares. Any subsequent
///   deposit at the elevated exchange rate incurs ERC4626 floor-rounding truncation,
///   leaking up to 1 wei of asset value per deposit into the shared pool. That leaked
///   value inflates previewRedeem for in-flight redemptions beyond liquid coverage.
///   See: test_IlliquidityBug_TruncationLeak.
///
///   The donate() handler caps donations so that totalAssets/totalShares diverges by
///   at most 1 wei per deposit, bounding the leak to exactly 0 or 1 wei per deposit.
///   ghost_inflatedDepositCount tracks the number of deposits made while redemptions
///   existed — the upper bound on total leaked wei.
///
///   Two independent budgets draw from this count:
///     - ghost_globalSponsoredDust:   staking-side shortfalls patched via deal()
///     - ghost_rewarderSponsoredDust: rewarder-side phantom claims skipped
///
///   They are independent because a single truncation event can cause a phantom in
///   both systems simultaneously.
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

    /// @dev Number of deposits per actor (1 wei rounding tolerance each).
    mapping(address => uint256) public ghost_actorDepositCount;

    /// @dev Number of redeems per actor (1 wei rounding tolerance each).
    mapping(address => uint256) public ghost_actorRedeemCount;

    // -------------------------------------------------------------------
    //  Ghost accounting — global tolerance budget
    // -------------------------------------------------------------------

    /// @dev Deposits made while totalSharesInRedemption > 0. Upper bound on total leaked wei.
    uint256 public ghost_inflatedDepositCount;

    /// @dev Staking-side dust injected via deal() to cover illiquidity shortfalls.
    uint256 public ghost_globalSponsoredDust;

    /// @dev Rewarder-side phantom claims skipped (independent budget from staking-side).
    uint256 public ghost_rewarderSponsoredDust;

    // -------------------------------------------------------------------
    //  Ghost state — transition checks
    // -------------------------------------------------------------------

    mapping(address => uint256) private _preTotalRewards;
    bool public ghost_stakeExcessCalled;
    bool public ghost_redeemCalled;
    uint256 public ghost_lastRedeemExpected;
    uint256 public ghost_lastRedeemAssets;
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
        _assertRedeemExactBufferInvariant();
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
            uint256 adjustedPre = preTotal > REWARD_ROUNDING_TOLERANCE
                ? preTotal - REWARD_ROUNDING_TOLERANCE
                : 0;

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

    /// @dev Actual ERC20 transfer must match the pre-call previewRedeem snapshot.
    function _assertRedeemExactBufferInvariant() internal {
        if (!ghost_redeemCalled) return;
        assertEq(
            ghost_lastRedeemAssets,
            ghost_lastRedeemExpected,
            "Transition: redeem transfer != previewRedeem"
        );
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

    /// @dev If expectedAssets > availableAssets and the shortfall fits within the tolerance
    ///      budget, deal() the missing wei to the vault and debit the budget. If the shortfall
    ///      exceeds tolerance, do nothing — let the redeem revert to surface real bugs.
    ///
    ///      This deal is NOT self-defeating: DECIMALS_OFFSET=100 virtual shares guarantee
    ///      floor(shortfall * effectiveShares / totalShares) = 0 for any single-actor shortfall,
    ///      so the injected wei does not inflate previewRedeem for the actor being redeemed.
    function _sponsorAcceptedRoundingDust(uint256 expectedAssets, uint256 availableAssets) internal {
        if (expectedAssets <= availableAssets) return;

        uint256 shortfall = expectedAssets - availableAssets;
        uint256 remainingBudget = ghost_inflatedDepositCount - ghost_globalSponsoredDust;

        if (shortfall <= remainingBudget) {
            uint256 currentBalance = assetToken.balanceOf(address(operatorStaking));
            deal(address(assetToken), address(operatorStaking), currentBalance + shortfall);
            ghost_globalSponsoredDust += shortfall;
        }
    }

    /// @dev Redeem shares, sponsor rounding dust if needed, update ghost state.
    function _executeRedeem(address actor, uint256 shares) internal returns (uint256 assetsOut) {
        uint256 effectiveShares = shares == type(uint256).max ? operatorStaking.maxRedeem(actor) : shares;
        if (effectiveShares == 0) return 0;

        (uint256 expectedAssets, uint256 availableAssets) = getExpectedAssets(effectiveShares);
        _sponsorAcceptedRoundingDust(expectedAssets, availableAssets);

        // Refresh after sponsoring: the deal may have shifted the exchange rate by a negligible
        // amount, but we need the post-deal previewRedeem for the transition assertion.
        (expectedAssets,) = getExpectedAssets(effectiveShares);

        uint256 balanceBefore = assetToken.balanceOf(actor);

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

        // Track deposits during active redemptions for the tolerance budget.
        // donate() caps D <= N, so each deposit shifts previewRedeem by at most 1 wei.
        bool hasPendingRedemptions = operatorStaking.totalSharesInRedemption() > 0;

        vm.prank(actor);
        operatorStaking.deposit(assets, actor);

        ghost_deposited[actor] += assets;
        ghost_actorDepositCount[actor]++;
        if (hasPendingRedemptions) ghost_inflatedDepositCount++;
    }

    function depositWithPermit(uint256 assets) external assertTransitionInvariants {
        address actor = msg.sender;
        uint256 balance = assetToken.balanceOf(actor);
        if (balance == 0) return;

        assets = bound(assets, 1, balance);

        bool hasPendingRedemptions = operatorStaking.totalSharesInRedemption() > 0;
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) = _getSignature(actor, assets, deadline);

        vm.prank(actor);
        operatorStaking.depositWithPermit(assets, actor, deadline, v, r, s);

        ghost_deposited[actor] += assets;
        ghost_actorDepositCount[actor]++;
        ghost_lastPermitActor = actor;
        if (hasPendingRedemptions) ghost_inflatedDepositCount++;
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
    ///      Any subsequent deposit at the elevated rate incurs floor-rounding truncation,
    ///      leaking up to 1 wei per deposit into in-flight redemptions.
    ///      See: test_IlliquidityBug_TruncationLeak.
    ///
    ///      The cap ensures totalAssets <= totalShares (with virtual offsets), which bounds
    ///      the per-deposit leak to exactly 0 or 1 wei. Proof: if D/N <= 1, then
    ///      pendingShares * (D'/N' - D/N) < 1 for any single deposit of N' shares.
    function donate(uint256 amount) external assertTransitionInvariants {
        address actor = msg.sender;
        uint256 balance = assetToken.balanceOf(actor);
        if (balance == 0) return;

        // Virtual offsets: +100 shares (DECIMALS_OFFSET), +1 asset (ERC4626 standard).
        uint256 S = operatorStaking.totalSupply() + operatorStaking.totalSharesInRedemption() + 100;
        uint256 A = operatorStaking.totalAssets() + 1;

        // Cap: keep totalAssets/totalShares <= 1.
        uint256 maxDonation = S > A ? S - A : 0;
        if (maxDonation == 0) return;

        uint256 allowed = Math.min(balance, maxDonation);
        amount = bound(amount, 1, allowed);

        vm.prank(actor);
        assetToken.transfer(address(operatorStaking), amount);
    }

    /// @dev Claims rewards from the OperatorRewarder.
    ///
    ///      Known issue: the rewarder can be 1 wei short due to a phantom residual in
    ///      _totalVirtualRewardsPaid. Donate inflates share price -> deposit truncates
    ///      shares -> transferHook calls _allocation with floor division -> phantom wei
    ///      lodges in _totalVirtualRewardsPaid -> historicalReward() overstates by 1 ->
    ///      earned() promises 1 more token than the rewarder holds.
    ///
    ///      Dealing tokens to the rewarder is self-defeating: the dealt amount raises
    ///      _totalAssetsPlusPaidRewards -> historicalReward -> earned by the same amount.
    ///      The rewarder's _allocation divides by totalSupply (no virtual offset), so for
    ///      majority holders the shortfall never closes.
    ///
    ///      Fix: skip the claim when the shortfall fits within the rewarder tolerance budget.
    ///
    ///      Known limitation: rewarder.claimRewards() is all-or-nothing. A persistent 1-wei
    ///      phantom blocks ALL future claims for the affected actor until their shares burn
    ///      via requestRedeem (which resets _rewardsPaid in the transferHook). This means
    ///      ghost_claimedRewards under-counts for affected actors.
    function claimRewards() external assertTransitionInvariants {
        address actor = msg.sender;
        uint256 earnedAmount = rewarder.earned(actor);
        if (earnedAmount == 0) return;

        uint256 rewarderBalance = assetToken.balanceOf(address(rewarder));
        uint256 pendingFromProtocol = protocolStaking.earned(address(operatorStaking));
        uint256 totalAvailable = rewarderBalance + pendingFromProtocol;

        if (earnedAmount > totalAvailable) {
            uint256 shortfall = earnedAmount - totalAvailable;
            uint256 remainingBudget = ghost_inflatedDepositCount - ghost_rewarderSponsoredDust;

            if (shortfall <= remainingBudget) {
                ghost_rewarderSponsoredDust += shortfall;
                return;
            }
            // Shortfall exceeds budget — fall through and let the revert surface.
        }

        vm.prank(actor);
        rewarder.claimRewards(actor);
        ghost_claimedRewards[actor] += earnedAmount;
    }
}
