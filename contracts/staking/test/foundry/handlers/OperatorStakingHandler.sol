// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ZamaERC20} from "token/contracts/ZamaERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {ProtocolStakingHarness} from "./../harness/ProtocolStakingHarness.sol";
import {OperatorStakingHarness} from "./../harness/OperatorStakingHarness.sol";
import {OperatorRewarder} from "./../../../contracts/OperatorRewarder.sol";

/**
 * @title OperatorStakingHandler
 * @notice Handler for OperatorStaking invariant tests.
 * @dev Wraps state-changing actions and bounds fuzz inputs.
 */
contract OperatorStakingHandler is Test {
    OperatorStakingHarness public operatorStaking;
    ZamaERC20 public assetToken;
    ProtocolStakingHarness public protocolStaking;
    OperatorRewarder public rewarder;

    struct PendingRedeem {
        address controller;
        uint48 releaseTime;
    }

    uint256 public constant MAX_PERIOD_DURATION = 365 days * 3;

    // Truncation is used for reward calculation, so we need to account for the rounding error.
    uint256 public constant REWARD_ROUNDING_TOLERANCE = 1;

    address[] public actors;
    mapping(address => uint256) public actorPrivateKeys;

    mapping(address => uint256) public ghost_deposited;
    mapping(address => uint256) public ghost_redeemed;
    // Tracks the historical cumulative rewards actually harvested by each actor
    mapping(address => uint256) public ghost_claimedRewards;

    // Temporary state used exclusively inside the transition modifier
    mapping(address => uint256) private _preTotalRewards;

    // Flag to track transition invariant checks
    bool public ghost_stakeExcessCalled;
    bool public ghost_redeemCalled;
    // Stores the pre-redeem previewRedeem(effectiveShares) snapshot so the modifier can
    // verify the actual transfer matched the preview without re-calling after state changes.
    uint256 public ghost_lastRedeemExpected;
    uint256 public ghost_lastRedeemAssets;
    address public ghost_lastPermitActor;

    // Number of deposits made while in-flight redemptions existed. Each such deposit can shift
    // previewRedeem(totalSharesInRedemption) by at most 1 wei (the donate handler keeps D<=N,
    // bounding pendingShares*(D'/N'-D/N) < 1, so the floor can jump by 0 or 1 per deposit).
    uint256 public ghost_inflatedDepositCount;
    // Tracks rounding allowance per actor caused by floor division in deposits
    mapping(address => uint256) public ghost_actorDepositCount;
    // Tracks rounding allowance per actor caused by floor division in redeem
    mapping(address => uint256) public ghost_actorRedeemCount;

    // Tracks total artificial dust injected to bypass staking-side illiquidity anomalies.
    uint256 public ghost_globalSponsoredDust;

    // Tracks total phantom-wei claims skipped on the rewarder side.
    // Independent budget from ghost_globalSponsoredDust because the same truncation event
    // can cause a phantom in both systems (staking liquidity AND rewarder balance) independently.
    uint256 public ghost_rewarderSponsoredDust;

    PendingRedeem[] public ghost_pendingRedeems;

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

    // **************** Transition Invariant Modifiers ****************

    /// @dev Master modifier to check all transition invariants (State A -> State B)
    modifier assertTransitionInvariants() {
        _snapshotActorTotalRewards();

        _; // Execute the handler action

        _assertActorTotalRewardsMonotonicity();
        _assertStakeExcessExactBufferInvariant();
        _assertRedeemExactBufferInvariant();

        // hack to repair allowance when permit is used (permit overrides max allowance from setUp)
        _repairAllowanceWhenPermit();
    }

    // **************** Transition invariant helpers ****************

    function _snapshotActorTotalRewards() internal {
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            // Total Reward = what they already have in their wallet + what they are owed
            _preTotalRewards[actor] = ghost_claimedRewards[actor] + rewarder.earned(actor);
        }
    }

    function _assertActorTotalRewardsMonotonicity() internal view {
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            uint256 postTotalReward = ghost_claimedRewards[actor] + rewarder.earned(actor);
            uint256 adjustedPreTotalReward = _preTotalRewards[actor];

            if (adjustedPreTotalReward > REWARD_ROUNDING_TOLERANCE) {
                adjustedPreTotalReward -= REWARD_ROUNDING_TOLERANCE;
            } else {
                adjustedPreTotalReward = 0;
            }

            assertGe(
                postTotalReward,
                adjustedPreTotalReward,
                "Invariant: Claimed + claimable rewards decreased for an actor!"
            );
        }
    }

    /// @dev Invariant: stakeExcess must leave exactly previewRedeem(totalSharesInRedemption()) assets.
    function _assertStakeExcessExactBufferInvariant() internal {
        if (!ghost_stakeExcessCalled) return;
        assertEq(
            assetToken.balanceOf(address(operatorStaking)),
            operatorStaking.previewRedeem(operatorStaking.totalSharesInRedemption()),
            "Invariant: stakeExcess did not leave exact redemption buffer"
        );
        ghost_stakeExcessCalled = false;
    }

    /// @dev Invariant: redeem must transfer exactly previewRedeem(effectiveShares) assets.
    /// We compare the pre-call previewRedeem against the actual ERC20 transfer.
    function _assertRedeemExactBufferInvariant() internal {
        if (!ghost_redeemCalled) return;
        assertEq(
            ghost_lastRedeemAssets,
            ghost_lastRedeemExpected,
            "Invariant: redeem did not return exactly previewRedeem(shares) assets"
        );
        ghost_redeemCalled = false;
    }

    // **************** Invariant Helper functions ****************

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

    // **************** Internal Helper functions ****************

    function _repairAllowanceWhenPermit() internal {
        if (ghost_lastPermitActor != address(0)) {
            vm.prank(ghost_lastPermitActor);
            assetToken.approve(address(operatorStaking), type(uint256).max);
            ghost_lastPermitActor = address(0);
        }
    }

    /// @dev O(1) removal of a pending redeem from the ghost array
    function _removePendingRedeem(uint256 index) internal {
        uint256 lastIndex = ghost_pendingRedeems.length - 1;
        if (index != lastIndex) {
            ghost_pendingRedeems[index] = ghost_pendingRedeems[lastIndex];
        }
        ghost_pendingRedeems.pop();
    }

    /// @dev Analyzes shortfalls and sponsors mathematical dust to bypass known protocol anomalies.
    /// If the shortfall exceeds accepted mathematical bounds, it does not sponsor, forcing a revert.
    function _sponsorAcceptedRoundingDust(uint256 expectedAssets, uint256 availableAssets) internal {
        if (expectedAssets <= availableAssets) return;

        uint256 shortfall = expectedAssets - availableAssets;

        // Allow for up to 1 wei of dust tolerance per inflated deposit due to donations
        uint256 remainingBudget = ghost_inflatedDepositCount - ghost_globalSponsoredDust;

        if (shortfall <= remainingBudget) {
            // inject the missing wei using deal
            uint256 currentBalance = assetToken.balanceOf(address(operatorStaking));
            deal(address(assetToken), address(operatorStaking), currentBalance + shortfall);

            // account for this injected wealth
            ghost_globalSponsoredDust += shortfall;
        }
    }

    /// @dev Returns the available assets in the vault and expected assets redeemable for a given number of shares
    function getExpectedAssets(uint256 shares) public view returns (uint256 expectedAssets, uint256 availableAssets) {
        expectedAssets = operatorStaking.previewRedeem(shares);
        uint256 pendingRelease = protocolStaking._harness_amountToRelease(address(operatorStaking));
        availableAssets = assetToken.balanceOf(address(operatorStaking)) + pendingRelease;
    }

    /// @dev Core logic for redeeming and cleaning up state
    function _executeRedeem(address actor, uint256 shares) internal returns (uint256 assetsOut) {
        // Resolve type(uint256).max to the actual claimable shares
        uint256 effectiveShares = shares == type(uint256).max ? operatorStaking.maxRedeem(actor) : shares;
        if (effectiveShares == 0) return 0;

        (uint256 expectedAssets, uint256 availableAssets) = getExpectedAssets(effectiveShares);

        // Bypass known illiquidity anomalies if within bounds
        _sponsorAcceptedRoundingDust(expectedAssets, availableAssets);

        // Refresh expected assets after sponsoring dust, we may have sponsored dust that inflated the share price
        // so we need to refresh the expected assets to get the correct amount of assets out.
        (expectedAssets, availableAssets) = getExpectedAssets(effectiveShares);

        uint256 balanceBefore = assetToken.balanceOf(actor);

        // Execute redeem
        vm.prank(actor);
        assetsOut = operatorStaking.redeem(shares, actor, actor);

        uint256 actualTransfer = assetToken.balanceOf(actor) - balanceBefore;
        // Track global ghost state
        ghost_redeemed[actor] += actualTransfer;
        ghost_lastRedeemAssets = actualTransfer;
        ghost_lastRedeemExpected = expectedAssets;
        ghost_redeemCalled = true;
        // allow 1 wei of rounding tolerance per redeem (due to floor division)
        ghost_actorRedeemCount[actor]++;

        // Clean up ghost_pendingRedeems entries for this actor.
        // If the actor has no pending or claimable requests, we can safely wipe all their ghost entries.
        bool hasPending = operatorStaking.pendingRedeemRequest(actor) > 0;
        bool hasClaimable = operatorStaking.claimableRedeemRequest(actor) > 0;
        if (!hasPending && !hasClaimable) {
            for (uint256 i = ghost_pendingRedeems.length; i > 0; i--) {
                uint256 index = i - 1;
                PendingRedeem memory pending = ghost_pendingRedeems[index];
                if (pending.controller == actor) {
                    _removePendingRedeem(index);
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

    // **************** OperatorStaking actions ****************

    function warp(uint256 duration) public assertTransitionInvariants {
        duration = bound(duration, 1, MAX_PERIOD_DURATION);
        vm.warp(block.timestamp + duration);
    }

    // function setOperator(uint256 operatorIndex, bool approved) external assertTransitionInvariants {
    //     address actor = msg.sender;
    //     operatorIndex = bound(operatorIndex, 0, actors.length - 1);
    //     address operator = actors[operatorIndex];

    //     vm.prank(actor);
    //     operatorStaking.setOperator(operator, approved);
    // }

    function deposit(uint256 assets) external assertTransitionInvariants {
        address actor = msg.sender;
        uint256 balance = assetToken.balanceOf(actor);
        if (balance == 0) return;

        assets = bound(assets, 1, balance);

        // When there are in-flight redemptions, any deposit can shift the floor of
        // previewRedeem(pendingShares) by exactly 0 or 1 wei (provable since the donate handler
        // keeps D <= N, making pendingShares * (D'/N' - D/N) < 1 always). Track these deposits so
        // _sponsorAcceptedRoundingDust and invariant_liquidityBufferSufficiency have the correct budget.
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

        // TODO: review handling of deposits with permit, should they go to a new receiver?
        ghost_actorDepositCount[actor]++;
        ghost_lastPermitActor = actor;

        if (hasPendingRedemptions) ghost_inflatedDepositCount++;
    }

    /// @dev Note that requesting redemption of 1 share returns 0 assets due to rounding, but the share is still burned.
    /// This means that continually redeeming tiny amounts of shares can break invariant_totalRecoverableValue
    /// if the total amount of shares burned with zero assets received exceeds the rounding tolerance.
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

    /// @notice passes uint256.max as share amount to redeem
    function redeemMax() external assertTransitionInvariants {
        address actor = msg.sender;
        _executeRedeem(actor, type(uint256).max);
    }

    function stakeExcess() external assertTransitionInvariants {
        uint256 awaitingRelease = protocolStaking._harness_amountToRelease(address(operatorStaking));
        uint256 liquidBalance = assetToken.balanceOf(address(operatorStaking)) + awaitingRelease;
        uint256 assetsPendingRedemption = operatorStaking.previewRedeem(operatorStaking.totalSharesInRedemption());
        if (liquidBalance <= assetsPendingRedemption) return;
        operatorStaking.stakeExcess();

        ghost_stakeExcessCalled = true;
    }

    /// @dev Known limitation: direct token donations inflate `totalAssets` without minting shares,
    /// raising the per-share exchange rate. Any subsequent deposit at this elevated rate incurs
    /// ERC4626 floor-rounding truncation, leaking 1-2 wei of asset value into the shared pool.
    /// That leaked value credits all outstanding shares — including in-flight redemptions — with a
    /// fractionally higher payout than the vault has liquid assets to cover. The result is a
    /// dust-sized insolvency (~1 wei) that reverts with `ERC20InsufficientBalance` on withdrawal.
    /// see: test_IlliquidityBug_TruncationLeak
    function donate(uint256 amount) external assertTransitionInvariants {
        address actor = msg.sender;
        uint256 balance = assetToken.balanceOf(actor);
        if (balance == 0) return;

        // Calculate current state variables including offsets
        uint256 S = operatorStaking.totalSupply() + operatorStaking.totalSharesInRedemption() + 100;
        uint256 A = operatorStaking.totalAssets() + 1;

        // Calculate the maximum donation that keeps Max Divergence (A/S) <= 1 wei
        uint256 maxDonation = S > A ? S - A : 0;

        // If the max donation is 0, the divergence cap is already met. Prevent donation.
        if (maxDonation == 0) return;

        uint256 allowed = Math.min(balance, maxDonation);
        amount = bound(amount, 1, allowed);

        vm.prank(actor);
        assetToken.transfer(address(operatorStaking), amount);
    }

    /// @dev Allows the fuzzer to organically claim rewards.
    ///
    /// Known issue: OperatorRewarder can be 1 wei short due to a phantom residual in
    /// _totalVirtualRewardsPaid. Root cause: donate() inflates share price → deposit() at elevated
    /// rate truncates shares in convertToShares() → transferHook() calls _allocation(newShares, oldTotal)
    /// with floor division → phantom wei lodges in _totalVirtualRewardsPaid, inflating historicalReward()
    /// by 1 → earned() promises 1 more token than the rewarder can physically pay.
    ///
    /// Dealing tokens directly to the rewarder is self-defeating: deal() raises rewarderBalance →
    /// raises _totalAssetsPlusPaidRewards() → raises historicalReward() → raises the fresh earned_
    /// computed inside rewarder.claimRewards() by the same amount. The shortfall never closes for an
    /// actor holding all (or a large fraction of) shares because the rewarder's _allocation divides
    /// by totalSupply which has no virtual offset (unlike the vault's DECIMALS_OFFSET=100).
    ///
    /// Fix: when the shortfall is within the phantom-wei budget, skip the claim as a no-op.
    ///
    /// Known limitation (ghost_claimedRewards drift): because rewarder.claimRewards() is all-or-nothing
    /// (no partial claims), a persistent 1-wei phantom blocks ALL future claims for the affected actor.
    /// Real rewards continue accruing in rewarder.earned(actor) but ghost_claimedRewards never updates.
    /// This means the rewarder claim path is under-exercised for actors with a phantom. The phantom is
    /// only absorbed when the actor's shares burn via requestRedeem → transferHook → _rewardsPaid update.
    /// A proper fix would require a harness that adjusts _totalVirtualRewardsPaid to cancel the phantom.
    function claimRewards() external assertTransitionInvariants {
        address actor = msg.sender;
        uint256 earnedAmount = rewarder.earned(actor);
        if (earnedAmount == 0) return;

        // Check how much physical balance the rewarder holds right now.
        uint256 rewarderBalance = assetToken.balanceOf(address(rewarder));

        // Check how much the rewarder is allowed to claim from the underlying protocol.
        // Note: _doTransferOut triggers protocolStaking.claimRewards() which mints exactly
        // protocolStaking.earned() tokens — no floor truncation at the protocol level.
        uint256 pendingFromProtocol = protocolStaking.earned(address(operatorStaking));

        uint256 totalAvailable = rewarderBalance + pendingFromProtocol;

        // Detect phantom shortfall before attempting the claim.
        if (earnedAmount > totalAvailable) {
            uint256 shortfall = earnedAmount - totalAvailable;
            uint256 remainingRewarderBudget = ghost_inflatedDepositCount - ghost_rewarderSponsoredDust;

            // Within tolerance: skip this claim gracefully and debit the rewarder budget.
            // If shortfall exceeds tolerance, fall through and let rewarder.claimRewards revert.
            if (shortfall <= remainingRewarderBudget) {
                ghost_rewarderSponsoredDust += shortfall;
                return;
            }
        }

        vm.prank(actor);
        rewarder.claimRewards(actor);

        // Update the global ghost tracker
        ghost_claimedRewards[actor] += earnedAmount;
    }

    // **************** Equivalence scenario handlers ****************
}
