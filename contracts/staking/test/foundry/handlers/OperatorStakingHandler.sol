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
    // Tracks rounding allowance per actor caused by floor division in redeem
    mapping(address => uint256) public ghost_actorFloorRedemptionTolerance;
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

    // Total number of direct donations. Each donation+deposit interaction can produce exactly
    // 1 wei of truncation shortfall in the liquidity buffer; this count is used as the tolerance.
    uint256 public ghost_donationCount;

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
    /// We compare against the pre-call previewRedeem snapshot (ghost_lastRedeemExpected)
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

        // Skip if the vault is insolvent due to the known truncation/donation inflation bug
        if (expectedAssets > availableAssets) {
            return 0;
        }

        // Execute redeem
        vm.prank(actor);
        assetsOut = operatorStaking.redeem(shares, actor, actor);

        // Track global ghost state
        ghost_redeemed[actor] += assetsOut;
        ghost_lastRedeemAssets = assetsOut;
        ghost_lastRedeemExpected = expectedAssets;
        ghost_redeemCalled = true;
        // allow 1 wei of rounding tolerance per redeem (due to floor division)
        ghost_actorFloorRedemptionTolerance[actor]++;

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

        vm.prank(actor);
        uint256 sharesMinted = operatorStaking.deposit(assets, actor);

        // get present value of shares to account for donation inflation
        ghost_deposited[actor] += operatorStaking.previewRedeem(sharesMinted);
    }

    function depositWithPermit(uint256 receiverIndex, uint256 assets) external assertTransitionInvariants {
        address actor = msg.sender;
        uint256 balance = assetToken.balanceOf(actor);
        if (balance == 0) return;

        assets = bound(assets, 1, balance);

        uint256 deadline = block.timestamp + 1;
        address receiver = actors[receiverIndex % actors.length];

        (uint8 v, bytes32 r, bytes32 s) = _getSignature(actor, assets, deadline);

        vm.prank(actor);
        uint256 sharesMinted = operatorStaking.depositWithPermit(assets, receiver, deadline, v, r, s);

        // get present value of shares to account for donation inflation
        ghost_deposited[receiver] += operatorStaking.previewRedeem(sharesMinted);
        ghost_lastPermitActor = actor;
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
        uint256 liquidBalance = assetToken.balanceOf(address(operatorStaking));
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

        // not using full balance to allow actor to perform other actions
        uint256 maxDonation = balance / 4;

        // account for tiny balances
        if (maxDonation == 0) return;

        amount = bound(amount, 1, maxDonation);

        vm.prank(actor);
        assetToken.transfer(address(operatorStaking), amount);
        ghost_donationCount++;
    }

    /// @dev Allows the fuzzer to organically claim rewards
    function claimRewards() external assertTransitionInvariants {
        address actor = msg.sender;
        uint256 earned = rewarder.earned(actor);

        // Execute the claim
        vm.prank(actor);
        rewarder.claimRewards(actor);

        // Update the global ghost tracker
        ghost_claimedRewards[actor] += earned;
    }

    // **************** Equivalence scenario handlers ****************
}
