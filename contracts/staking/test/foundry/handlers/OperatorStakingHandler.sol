// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
    IERC20 public assetToken;
    ProtocolStaking public protocolStaking;
    address[] public actors;

    uint256 public constant MAX_PERIOD_DURATION = 30 days;

    constructor(
        OperatorStakingHarness _operatorStaking,
        IERC20 _assetToken,
        ProtocolStaking _protocolStaking,
        address[] memory _actors
    ) {
        require(_actors.length > 0, "need at least one actor");
        operatorStaking = _operatorStaking;
        assetToken = _assetToken;
        protocolStaking = _protocolStaking;
        actors = _actors;
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 index) external view returns (address) {
        if (index >= actors.length) return address(0);
        return actors[index];
    }

    function warp(uint256 duration) external {
        duration = bound(duration, 1, MAX_PERIOD_DURATION);
        vm.warp(block.timestamp + duration);
    }

    function setOperator(uint256 controllerIndex, uint256 operatorIndex, bool approved) external {}

    function deposit(uint256 actorIndex, uint256 assets) external {
        actorIndex = bound(actorIndex, 0, actors.length - 1);
        address actor = actors[actorIndex];
        uint256 balance = assetToken.balanceOf(actor);
        if (balance == 0) return;

        assets = bound(assets, 1, balance);
        vm.prank(actor);
        operatorStaking.deposit(assets, actor);
    }

    function requestRedeem(uint256 actorIndex, uint256 shares) external {
        actorIndex = bound(actorIndex, 0, actors.length - 1);
        address actor = actors[actorIndex];
        uint256 balance = operatorStaking.balanceOf(actor);
        if (balance == 0) return;

        uint256 boundedShares = bound(shares, 1, balance);

        vm.prank(actor);
        operatorStaking.requestRedeem(SafeCast.toUint208(boundedShares), actor, actor);
    }

    function redeem(uint256 actorIndex, uint256 shares) external {
        actorIndex = bound(actorIndex, 0, actors.length - 1);
        address actor = actors[actorIndex];
        uint256 maxShares = operatorStaking.maxRedeem(actor);
        if (maxShares == 0) return;

        shares = bound(shares, 1, maxShares);
        vm.prank(actor);
        operatorStaking.redeem(shares, actor, actor);
    }

    function stakeExcess() external {
        uint256 liquidBalance = assetToken.balanceOf(address(operatorStaking));
        uint256 assetsPendingRedemption = operatorStaking.previewRedeem(operatorStaking.totalSharesInRedemption());
        if (liquidBalance <= assetsPendingRedemption) return;
        operatorStaking.stakeExcess();
    }
}
