// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
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

    mapping(address => uint256) public ghost_claimed;
    mapping(address => uint256) public ghost_lastClaimedPlusEarned;
    mapping(address => uint256) public ghost_lastAwaitingRelease;
    mapping(address => uint256) public ghost_totalStaked;
    mapping(address => uint256) public ghost_totalReleased;

    // Must match ProtocolStaking.PROTOCOL_STAKING_STORAGE_LOCATION
    uint256 private _STORAGE_BASE_SLOT = 0xd955b2342c0487c5e5b5f50f5620ec67dcb16d94462ba5d080d7b7472b67b900;

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

    function ghost_eligibleAccountAt(uint256 index) external view returns (address) {
        if (index >= ghost_eligibleAccounts.length) return address(0);
        return ghost_eligibleAccounts[index];
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 index) external view returns (address) {
        if (index >= actors.length) return address(0);
        return actors[index];
    }

    function setLastClaimedPlusEarned(address account, uint256 value) external {
        ghost_lastClaimedPlusEarned[account] = value;
    }

    function setLastAwaitingRelease(address account, uint256 value) external {
        ghost_lastAwaitingRelease[account] = value;
    }

    // **************** Storage reading functions ****************

    function _readPaid(address proxy, address account) internal view returns (int256) {
        bytes32 slot = keccak256(abi.encode(account, bytes32(_STORAGE_BASE_SLOT + 9)));
        return int256(uint256(vm.load(proxy, slot)));
    }

    function _readTotalVirtualPaid(address proxy) internal view returns (int256) {
        bytes32 slot = bytes32(_STORAGE_BASE_SLOT + 10);
        return int256(uint256(vm.load(proxy, slot)));
    }

    function _readHistoricalReward(address proxy) internal view returns (uint256) {
        uint256 lastUpdateTimestamp = uint256(vm.load(proxy, bytes32(_STORAGE_BASE_SLOT + 5)));
        uint256 lastUpdateReward = uint256(vm.load(proxy, bytes32(_STORAGE_BASE_SLOT + 6)));
        uint256 rewardRate = uint256(vm.load(proxy, bytes32(_STORAGE_BASE_SLOT + 7)));
        return lastUpdateReward + (block.timestamp - lastUpdateTimestamp) * rewardRate;
    }


    // **************** Invariant functions ****************

    function computeRewardDebtLHS() external view returns (int256) {
        int256 sumPaid;
        uint256 sumEarned;
        address proxy = address(protocolStaking);
        for (uint256 i = 0; i < ghost_eligibleAccounts.length; i++) {
            address account = ghost_eligibleAccounts[i];
            sumPaid += _readPaid(proxy, account);
            sumEarned += protocolStaking.earned(account);
        }
        return sumPaid + SafeCast.toInt256(sumEarned);
    }

    function computeRewardDebtRHS() external view returns (int256) {
        address proxy = address(protocolStaking);
        int256 totalVirtualPaid = _readTotalVirtualPaid(proxy);
        uint256 histReward = _readHistoricalReward(proxy);
        return totalVirtualPaid + SafeCast.toInt256(histReward);
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
    function warp(uint256 duration) public {
        duration = bound(duration, 1, MAX_PERIOD_DURATION);
        if (protocolStaking.totalStakedWeight() > 0) {
            ghost_accumulatedRewardCapacity += ghost_currentRate * duration;
        }
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
        ghost_totalStaked[actor] += amount;
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
        address account = actors[actorIndex];
        uint256 amount = protocolStaking.earned(account);
        protocolStaking.claimRewards(account);
        assertEq(protocolStaking.earned(account), 0, "earned(account) must be 0 after claimRewards");
        ghost_claimed[account] += amount;
    }

    function release(uint256 actorIndex) external {
        actorIndex = bound(actorIndex, 0, actors.length - 1);
        address account = actors[actorIndex];
        uint256 awaitingBefore = protocolStaking.awaitingRelease(account);
        protocolStaking.release(account);
        uint256 awaitingAfter = protocolStaking.awaitingRelease(account);
        ghost_totalReleased[account] += (awaitingBefore - awaitingAfter);
        ghost_lastAwaitingRelease[account] = awaitingAfter;
    }

    /// @notice Unstake then warp past cooldown to allow for valid release() calls.
    function unstakeThenWarp(uint256 actorIndex) external {
        actorIndex = bound(actorIndex, 0, actors.length - 1);
        address account = actors[actorIndex];
        uint256 stakedBalance = protocolStaking.balanceOf(account);
        if (stakedBalance == 0) return;

        vm.prank(account);
        protocolStaking.unstake(stakedBalance);

        uint256 cooldown = protocolStaking.unstakeCooldownPeriod();
        warp(cooldown + 1);
    }
}
