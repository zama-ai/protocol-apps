// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ProtocolStaking} from "../../../contracts/ProtocolStaking.sol";
import {ZamaERC20} from "token/contracts/ZamaERC20.sol";

/**
 * @title ProtocolStakingHandler
 * @notice Handler for invariant tests: wraps ProtocolStaking actions, bounds inputs, and tracks ghost reward capacity.
 */
contract ProtocolStakingHandler is Test {
    ProtocolStaking public protocolStaking;
    ZamaERC20 public zama;

    address public manager;
    address public staker;

    uint256 public constant MAX_PERIOD_DURATION = 30 days;
    uint256 public constant MAX_REWARD_RATE = 1e24;

    uint256 public ghost_accumulatedRewardCapacity;
    uint256 public ghost_currentRate;

    constructor(
        ProtocolStaking _protocolStaking,
        ZamaERC20 _zama,
        address _manager,
        address _staker,
        uint256 _initialRewardRate
    ) {
        protocolStaking = _protocolStaking;
        zama = _zama;
        manager = _manager;
        staker = _staker;
        ghost_currentRate = _initialRewardRate;
    }

    function warp(uint256 duration) external {
        duration = bound(duration, 1, MAX_PERIOD_DURATION);
        ghost_accumulatedRewardCapacity += ghost_currentRate * duration;
        vm.warp(block.timestamp + duration);
    }

    function setRewardRate(uint256 rate) external {
        rate = bound(rate, 0, MAX_REWARD_RATE);
        vm.prank(manager);
        protocolStaking.setRewardRate(rate);
        ghost_currentRate = rate;
    }

    function stake(uint256 amount) external {
        uint256 balance = zama.balanceOf(staker);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(staker);
        protocolStaking.stake(amount);
    }

    function claimRewards() external {
        protocolStaking.claimRewards(staker);
    }
}
