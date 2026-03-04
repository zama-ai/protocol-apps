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
    address[] public actors;

    uint256 public constant MAX_PERIOD_DURATION = 30 days;
    uint256 public constant MAX_REWARD_RATE = 1e24;

    uint256 public ghost_accumulatedRewardCapacity;
    uint256 public ghost_currentRate;
    uint256 public ghost_initialTotalSupply;

    address[] public ghost_eligibleAccounts;
    mapping(address => bool) public ghost_eligibleAccountsSeen;

    constructor(
        ProtocolStaking _protocolStaking,
        ZamaERC20 _zama,
        address _manager,
        address[] memory _actors
    ) {
        require(_actors.length > 0, "need at least one actor");
        protocolStaking = _protocolStaking;
        zama = _zama;
        manager = _manager;
        actors = _actors;
        ghost_currentRate = _protocolStaking.rewardRate();
        ghost_initialTotalSupply = _zama.totalSupply();
    }

    // **************** Helper functions ****************

    function ghost_eligibleAccountsLength() external view returns (uint256) {
        return ghost_eligibleAccounts.length;
    }

    function computeExpectedTotalWeight() external view returns (uint256 total) {
        for (uint256 i = 0; i < ghost_eligibleAccounts.length; i++) {
            address account = ghost_eligibleAccounts[i];
            if (protocolStaking.isEligibleAccount(account)) {
                total += protocolStaking.weight(protocolStaking.balanceOf(account));
            }
        }
    }

    // Move the block timestamp forward by a given duration.
    function warp(uint256 duration) external {
        duration = bound(duration, 1, MAX_PERIOD_DURATION);
        ghost_accumulatedRewardCapacity += ghost_currentRate * duration;
        vm.warp(block.timestamp + duration);
    }

    // **************** ProtocolStaking actions ****************

    function setRewardRate(uint256 rate) external {
        rate = bound(rate, 0, MAX_REWARD_RATE);
        vm.prank(manager);
        protocolStaking.setRewardRate(rate);
        ghost_currentRate = rate;
    }

    function addEligibleAccount(uint256 actorIndex) external {
        actorIndex = bound(actorIndex, 0, actors.length - 1);
        address account = actors[actorIndex];
        if (protocolStaking.isEligibleAccount(account)) return;
        vm.prank(manager);
        protocolStaking.addEligibleAccount(account);
        if (!ghost_eligibleAccountsSeen[account]) {
            ghost_eligibleAccountsSeen[account] = true;
            ghost_eligibleAccounts.push(account);
        }
    }

    function removeEligibleAccount(uint256 actorIndex) external {
        actorIndex = bound(actorIndex, 0, actors.length - 1);
        address account = actors[actorIndex];
        if (!protocolStaking.isEligibleAccount(account)) return;
        vm.prank(manager);
        protocolStaking.removeEligibleAccount(account);
    }

    function stake(uint256 actorIndex, uint256 amount) external {
        actorIndex = bound(actorIndex, 0, actors.length - 1);
        address actor = actors[actorIndex];
        uint256 balance = zama.balanceOf(actor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(actor);
        protocolStaking.stake(amount);
    }

    function unstake(uint256 actorIndex, uint256 amount) external {
        actorIndex = bound(actorIndex, 0, actors.length - 1);
        address actor = actors[actorIndex];
        uint256 stakedBalance = protocolStaking.balanceOf(actor);
        if (stakedBalance == 0) return;
        amount = bound(amount, 1, stakedBalance);
        vm.prank(actor);
        protocolStaking.unstake(amount);
    }

    function claimRewards(uint256 actorIndex) external {
        actorIndex = bound(actorIndex, 0, actors.length - 1);
        protocolStaking.claimRewards(actors[actorIndex]);
    }
}
