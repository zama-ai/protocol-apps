// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ZamaERC20} from "token/contracts/ZamaERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Test} from "forge-std/Test.sol";
import {ProtocolStaking} from "./../../../contracts/ProtocolStaking.sol";
import {OperatorStakingHarness} from "./../harness/OperatorStakingHarness.sol";

/**
 * @title OperatorStakingHandler
 * @notice Handler for OperatorStaking invariant tests.
 * @dev Wraps state-changing actions and bounds fuzz inputs.
 */
contract OperatorStakingHandler is Test {
    OperatorStakingHarness public operatorStaking;
    ZamaERC20 public assetToken;
    ProtocolStaking public protocolStaking;
    address[] public actors;
    mapping(address => uint256) public actorPrivateKeys;

    uint256 public constant MAX_PERIOD_DURATION = 365 days * 3;

    mapping(address => uint256) public ghost_deposited;
    mapping(address => uint256) public ghost_redeemed;

    // Flag to exempt an account from the monotonicity check
    address public ghost_lastRedeemActor;
    address public ghost_lastPermitActor;

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
        actors = _actors;
        for (uint256 i = 0; i < _actors.length; i++) {
            actorPrivateKeys[_actors[i]] = _actorPrivateKeys[i];
        }
    }

    // **************** Transition Invariant Modifiers ****************

    /// @dev Master modifier to check all transition invariants (State A -> State B)
    modifier assertTransitionInvariants() {
        _; // Execute the handler action

        // Repair allowance if needed after permit
        _repairAllowanceWhenPermit();

        ghost_lastRedeemActor = address(0);
    }

    // **************** Transition invariant assertions ****************

    // **************** Helper functions ****************

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 index) external view returns (address) {
        if (index >= actors.length) return address(0);
        return actors[index];
    }

    function _repairAllowanceWhenPermit() internal {
        if (ghost_lastPermitActor != address(0)) {
            vm.prank(ghost_lastPermitActor);
            assetToken.approve(address(operatorStaking), type(uint256).max);
            ghost_lastPermitActor = address(0);
        }
    }

    // **************** OperatorStaking actions ****************

    function warp(uint256 duration) external assertTransitionInvariants {
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

    function depositWithPermit(
        uint256 receiverIndex,
        uint256 assets,
        uint256 deadlineOffset
    ) external assertTransitionInvariants {
        address actor = msg.sender;

        // Bound the receiver to our known actors
        receiverIndex = bound(receiverIndex, 0, actors.length - 1);
        address receiver = actors[receiverIndex];

        uint256 balance = assetToken.balanceOf(actor);
        if (balance == 0) return;
        assets = bound(assets, 1, balance);

        // Ensure deadline is in the future
        uint256 deadline = block.timestamp + bound(deadlineOffset, 1, MAX_PERIOD_DURATION);

        uint256 nonce = assetToken.nonces(actor);
        uint256 privateKey = actorPrivateKeys[actor];

        // Construct ERC-2612 Permit Hash
        bytes32 permitTypehash = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;

        bytes32 structHash = keccak256(
            abi.encode(permitTypehash, actor, address(operatorStaking), assets, nonce, deadline)
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", assetToken.DOMAIN_SEPARATOR(), structHash));

        // Sign with the private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        // Execute the transaction
        vm.prank(actor);
        operatorStaking.depositWithPermit(assets, receiver, deadline, v, r, s);

        ghost_deposited[actor] += assets;
        ghost_lastPermitActor = actor;
    }

    function requestRedeem(uint256 shares) external assertTransitionInvariants {
        address actor = msg.sender;
        uint256 balance = operatorStaking.balanceOf(actor);
        if (balance == 0) return;

        uint256 boundedShares = bound(shares, 1, balance);

        vm.prank(actor);
        operatorStaking.requestRedeem(SafeCast.toUint208(boundedShares), actor, actor);
    }

    function redeem(uint256 shares) external assertTransitionInvariants {
        address actor = msg.sender;
        uint256 maxShares = operatorStaking.maxRedeem(actor);
        if (maxShares == 0) return;

        shares = bound(shares, 1, maxShares);

        vm.prank(actor);
        uint256 assetsOut = operatorStaking.redeem(shares, actor, actor);

        ghost_redeemed[actor] += assetsOut;
        ghost_lastRedeemActor = actor;
    }

    function stakeExcess() external assertTransitionInvariants {
        uint256 liquidBalance = assetToken.balanceOf(address(operatorStaking));
        uint256 assetsPendingRedemption = operatorStaking.previewRedeem(operatorStaking.totalSharesInRedemption());
        if (liquidBalance <= assetsPendingRedemption) return;
        operatorStaking.stakeExcess();
    }

    // **************** Equivalence scenario handlers ****************
}
