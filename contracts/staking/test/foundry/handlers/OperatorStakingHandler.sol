// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ZamaERC20} from "token/contracts/ZamaERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {ProtocolStaking} from "./../../../contracts/ProtocolStaking.sol";
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
    ProtocolStaking public protocolStaking;
    OperatorRewarder public rewarder;

    struct PendingRedeem {
        address controller;
        uint48 releaseTime;
    }

    uint256 public constant MAX_PERIOD_DURATION = 365 days * 3;

    // TODO: will be updated once the rounding logic is analyzed.
    uint256 public constant STAKED_FUND_RECOVERY_ROUNDING_TOLERANCE = 10;

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

    // Flag to exempt an account from the monotonicity check
    address public ghost_lastRedeemActor;
    address public ghost_lastPermitActor;

    PendingRedeem[] public ghost_pendingRedeems;

    constructor(
        OperatorStakingHarness _operatorStaking,
        ZamaERC20 _assetToken,
        ProtocolStaking _protocolStaking,
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
        ghost_lastRedeemActor = address(0);

        _snapshotActorTotalRewards();

        _; // Execute the handler action

        _assertActorTotalRewardsMonotonicity();

        // hack to repair allowance when permit is used (overrides max allowance from setUp)
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

    /// @dev Returns the rounding tolerance used for the no loss of funds invariant. Currently set arbitrarily to 10.
    /// will be updated once the rounding logic is analyzed.
    function getStakedFundRecoveryRoundingTolerance() external pure returns (uint256) {
        return STAKED_FUND_RECOVERY_ROUNDING_TOLERANCE;
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

    /// @dev Core logic for redeeming and cleaning up state
    function _executeRedeem(address actor, uint256 shares) internal returns (uint256 assetsOut) {
        // Execute redeem
        vm.prank(actor);
        assetsOut = operatorStaking.redeem(shares, actor, actor);

        // Track global ghost state
        ghost_redeemed[actor] += assetsOut;
        ghost_lastRedeemActor = actor;

        // If this actor has claimed everything currently available to them,
        // we can safely wipe all of their past requests from the ghost array.
        if (operatorStaking.claimableRedeemRequest(actor) == 0) {
            for (uint256 i = ghost_pendingRedeems.length; i > 0; i--) {
                uint256 index = i - 1;
                PendingRedeem memory pending = ghost_pendingRedeems[index];

                // If it belongs to the actor and the cooldown has passed, delete it
                if (pending.controller == actor && pending.releaseTime <= block.timestamp) {
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
        operatorStaking.deposit(assets, actor);
        ghost_deposited[actor] += assets;
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
        operatorStaking.depositWithPermit(assets, receiver, deadline, v, r, s);

        ghost_deposited[receiver] += assets;
        ghost_lastPermitActor = actor;
    }

    /// @dev Note that requesting redemption of 1 share returns 0 assets due to rounding, but the share is still burned.
    /// This means that continually redeeming tiny amounts of shares can break invariant_totalRecoverableValue
    /// if the total amount of shares burned with zero assets exceeds the rounding tolerance.
    function requestRedeem(uint256 shares) external assertTransitionInvariants {
        address actor = msg.sender;
        uint256 balance = operatorStaking.balanceOf(actor);
        if (balance == 0) return;

        uint256 allowed = Math.min(balance, type(uint208).max);
        if (allowed == 0) return;

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
        uint256 shares = type(uint256).max;

        _executeRedeem(actor, shares);
    }

    function stakeExcess() external assertTransitionInvariants {
        uint256 liquidBalance = assetToken.balanceOf(address(operatorStaking));
        uint256 assetsPendingRedemption = operatorStaking.previewRedeem(operatorStaking.totalSharesInRedemption());
        if (liquidBalance <= assetsPendingRedemption) return;
        operatorStaking.stakeExcess();
    }

    /// TODO: direct donations are currently breaking redemption invariants due to in-flight
    /// redemptions increasing in value. If a donation is staked in the contract through stakeExcess
    /// while redemptions are pending, the per share asset value of in-flight redemptions will increase.
    /// This means that when the redemptions are finally executed, they will receive more assets
    /// than they would have if the donation had not been staked. However, the contract will not have additional
    /// assets to cover the increased redemption value (they were staked), so the asset transfer in the redeem function will fail.

    // function donate(uint256 amount) external assertTransitionInvariants {
    //     address actor = msg.sender;
    //     uint256 balance = assetToken.balanceOf(actor);
    //     if (balance == 0) return;

    //     // not using full balance to allow actor to perform other actions
    //     amount = bound(amount, 0, balance / 4);

    //     // Direct donation
    //     vm.prank(actor);
    //     assetToken.transfer(address(operatorStaking), amount);
    // }

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
