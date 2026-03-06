// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ProtocolStaking} from "../../../contracts/ProtocolStaking.sol";
import {ZamaERC20} from "token/contracts/ZamaERC20.sol";

/**
 * @title ProtocolStakingHandler
 * @notice Handler for invariant tests: wraps ProtocolStaking actions, bounds inputs, and tracks ghost state.
 */
contract ProtocolStakingHandler is Test {
    ProtocolStaking public protocolStaking;
    ZamaERC20 public zama;

    address public manager;
    address[] public actors;

    // @dev Maximum duration to warp the block timestamp by. Must be <= 365 days for the cooldown period.
    uint256 public constant MAX_PERIOD_DURATION = 30 days;
    uint256 public constant MAX_REWARD_RATE = 1e24;

    // Amount in wei to allow for rounding errors in equivalence invariants.
    uint256 public constant EQUIVALENCE_EARNED_TOLERANCE = 50;

    uint256 public ghost_accumulatedRewardCapacity;
    uint256 public ghost_currentRate;
    uint256 public ghost_initialTotalSupply;

    address[] public ghost_eligibleAccounts;
    mapping(address => bool) public ghost_eligibleAccountsSeen;

    mapping(address => uint256) public ghost_claimed;
    mapping(address => uint256) public ghost_totalStaked;
    mapping(address => uint256) public ghost_totalReleased;

    // Flag to exempt an account from the awaitingRelease monotonicity check
    address public ghost_releasedAccount;

    // Equivalence scenario: store results for invariant to assert (only set when scenario runs)
    uint256 public ghost_sharesSingle;
    uint256 public ghost_sharesDouble;
    uint256 public ghost_weightSingle;
    uint256 public ghost_weightDouble;
    uint256 public ghost_earnedSingle;
    uint256 public ghost_earnedDouble;

    uint256 public ghost_sharesUnstakeA;
    uint256 public ghost_sharesUnstakeB;
    uint256 public ghost_weightUnstakeA;
    uint256 public ghost_weightUnstakeB;
    uint256 public ghost_earnedUnstakeA;
    uint256 public ghost_earnedUnstakeB;

    /// @dev _STORAGE_BASE_SLOT must match ProtocolStaking.PROTOCOL_STAKING_STORAGE_LOCATION and struct slot offsets
    uint256 private constant _STORAGE_BASE_SLOT = 0xd955b2342c0487c5e5b5f50f5620ec67dcb16d94462ba5d080d7b7472b67b900;
    uint256 private constant _UNSTAKE_REQUESTS_SLOT = 3;
    uint256 private constant _LAST_UPDATE_TIMESTAMP_SLOT = 5;
    uint256 private constant _LAST_UPDATE_REWARD_SLOT = 6;
    uint256 private constant _REWARD_RATE_SLOT = 7;
    uint256 private constant _PAID_SLOT = 9;
    uint256 private constant _TOTAL_VIRTUAL_PAID_SLOT = 10;

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

    // **************** Transition Invariant Modifiers ****************

    /// @dev Master modifier to check all transition invariants (State A -> State B)
    modifier assertTransitionInvariants() {
        uint256 eligibleLen = ghost_eligibleAccounts.length;
        uint256 actorsLen = actors.length;
        
        // Allocate memory for pre-states
        uint256[] memory preClaimedEarned = new uint256[](eligibleLen);
        uint256[] memory preAwaitingRelease = new uint256[](actorsLen);
        uint48[] memory preKeys = new uint48[](actorsLen);
        uint208[] memory preValues = new uint208[](actorsLen);
        bool[] memory hadCheckpoint = new bool[](actorsLen);
        
        // Capture pre-states: Claimed + Earned
        for (uint256 i = 0; i < eligibleLen; i++) {
            address account = ghost_eligibleAccounts[i];
            preClaimedEarned[i] = ghost_claimed[account] + protocolStaking.earned(account);
        }

        // Capture pre-states: Awaiting Release & Unstake Queue
        for (uint256 i = 0; i < actorsLen; i++) {
            address account = actors[i];
            preAwaitingRelease[i] = protocolStaking.awaitingRelease(account);
            
            uint256 count = getUnstakeRequestCheckpointCount(account);
            if (count > 0) {
                (preKeys[i], preValues[i]) = getUnstakeRequestCheckpointAt(account, count - 1);
                hadCheckpoint[i] = true;
            }
        }

        _; // Execute the handler action

        // Assert post-states: Claimed + Earned must not decrease
        for (uint256 i = 0; i < eligibleLen; i++) {
            address account = ghost_eligibleAccounts[i];
            uint256 postClaimedEarned = ghost_claimed[account] + protocolStaking.earned(account);
            
            assertGe(
                postClaimedEarned + EQUIVALENCE_EARNED_TOLERANCE, 
                preClaimedEarned[i], 
                "claimed+claimable must not decrease"
            );
        }

        // Assert post-states: Awaiting Release & Unstake Queue must not decrease except after release
        for (uint256 i = 0; i < actorsLen; i++) {
            address account = actors[i];
            
            // Awaiting Release Check
            if (account != ghost_releasedAccount) {
                uint256 postAwaitingRelease = protocolStaking.awaitingRelease(account);
                assertGe(
                    postAwaitingRelease, 
                    preAwaitingRelease[i], 
                    "awaitingRelease must not decrease except after release"
                );
            }
            
            // Unstake Queue Monotonicity Check
            uint256 count = getUnstakeRequestCheckpointCount(account);
            if (count > 0) {
                (uint48 postKey, uint208 postValue) = getUnstakeRequestCheckpointAt(account, count - 1);
                
                if (hadCheckpoint[i]) {
                    assertGe(postKey, preKeys[i], "unstake request keys must be non-decreasing");
                    if (postKey == preKeys[i]) {
                        assertGe(postValue, preValues[i], "unstake request values must be non-decreasing for same key");
                    }
                }
            }
            
            // Ensure awaitingRelease() never reverts: released[account] <= unstakeRequests[account].latest()
            protocolStaking.awaitingRelease(account);
        }
        
        // Reset the released account flag for the next fuzz step
        ghost_releasedAccount = address(0);
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

    // **************** Storage reading functions ****************

    function _readPaid(address proxy, address account) internal view returns (int256) {
        bytes32 slot = keccak256(abi.encode(account, bytes32(_STORAGE_BASE_SLOT + _PAID_SLOT)));
        return int256(uint256(vm.load(proxy, slot)));
    }

    function _readTotalVirtualPaid(address proxy) internal view returns (int256) {
        bytes32 slot = bytes32(_STORAGE_BASE_SLOT + _TOTAL_VIRTUAL_PAID_SLOT);
        return int256(uint256(vm.load(proxy, slot)));
    }

    function _readHistoricalReward(address proxy) internal view returns (uint256) {
        uint256 lastUpdateTimestamp = uint256(vm.load(proxy, bytes32(_STORAGE_BASE_SLOT + _LAST_UPDATE_TIMESTAMP_SLOT)));
        uint256 lastUpdateReward = uint256(vm.load(proxy, bytes32(_STORAGE_BASE_SLOT + _LAST_UPDATE_REWARD_SLOT)));
        uint256 rewardRate = uint256(vm.load(proxy, bytes32(_STORAGE_BASE_SLOT + _REWARD_RATE_SLOT)));
        return lastUpdateReward + (block.timestamp - lastUpdateTimestamp) * rewardRate;
    }

    /// @dev Returns the length of _unstakeRequests[account]._checkpoints for an actor
    function getUnstakeRequestCheckpointCount(address account) public view returns (uint256) {
        bytes32 traceSlot = keccak256(abi.encode(account, bytes32(_STORAGE_BASE_SLOT + _UNSTAKE_REQUESTS_SLOT)));
        return uint256(vm.load(address(protocolStaking), traceSlot));
    }

    /// @dev Returns the checkpoint at index for _unstakeRequests[account] (key = timestamp, value = cumulative amount).
    function getUnstakeRequestCheckpointAt(address account, uint256 index) public view returns (uint48 key, uint208 value)
    {
        bytes32 traceSlot = keccak256(abi.encode(account, bytes32(_STORAGE_BASE_SLOT + _UNSTAKE_REQUESTS_SLOT)));
        bytes32 arrayBase = keccak256(abi.encode(traceSlot));
        bytes32 checkpointSlot = bytes32(uint256(arrayBase) + index);
        uint256 data = uint256(vm.load(address(protocolStaking), checkpointSlot));
        key = uint48(data);
        value = uint208(data >> 48);
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

    // **************** ProtocolStaking actions ****************

    /// @dev Move the block timestamp forward by a given duration.
    function warp(uint256 duration) public assertTransitionInvariants {
        duration = bound(duration, 1, MAX_PERIOD_DURATION);
        ghost_accumulatedRewardCapacity += ghost_currentRate * duration;
        vm.warp(block.timestamp + duration);
    }

    function setRewardRate(uint256 rate) external assertTransitionInvariants {
        rate = bound(rate, 0, MAX_REWARD_RATE);
        vm.prank(manager);
        protocolStaking.setRewardRate(rate);
        ghost_currentRate = rate;
    }

    function addEligibleAccount(uint256 actorIndex) public assertTransitionInvariants {
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

    function removeEligibleAccount(uint256 actorIndex) external assertTransitionInvariants {
        actorIndex = bound(actorIndex, 0, actors.length - 1);
        address account = actors[actorIndex];
        if (!protocolStaking.isEligibleAccount(account)) return;
        vm.prank(manager);
        protocolStaking.removeEligibleAccount(account);
    }

    function setUnstakeCooldownPeriod(uint256 cooldownPeriod) external assertTransitionInvariants {
        cooldownPeriod = bound(cooldownPeriod, 1, MAX_PERIOD_DURATION - 1);
        vm.prank(manager);
        protocolStaking.setUnstakeCooldownPeriod(SafeCast.toUint48(cooldownPeriod));
    }

    function stake(uint256 actorIndex, uint256 amount) public assertTransitionInvariants {
        actorIndex = bound(actorIndex, 0, actors.length - 1);
        address actor = actors[actorIndex];
        uint256 balance = zama.balanceOf(actor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(actor);
        protocolStaking.stake(amount);
        ghost_totalStaked[actor] += amount;
    }

    function unstake(uint256 actorIndex, uint256 amount) public assertTransitionInvariants {
        actorIndex = bound(actorIndex, 0, actors.length - 1);
        address actor = actors[actorIndex];
        uint256 stakedBalance = protocolStaking.balanceOf(actor);
        if (stakedBalance == 0) return;
        amount = bound(amount, 1, stakedBalance);
        vm.prank(actor);
        protocolStaking.unstake(amount);
    }

    function claimRewards(uint256 actorIndex) external assertTransitionInvariants {
        actorIndex = bound(actorIndex, 0, actors.length - 1);
        address account = actors[actorIndex];
        uint256 amount = protocolStaking.earned(account);
        protocolStaking.claimRewards(account);
        assertEq(protocolStaking.earned(account), 0, "earned(account) must be 0 after claimRewards");
        ghost_claimed[account] += amount;
    }

    function release(uint256 actorIndex) external assertTransitionInvariants {
        actorIndex = bound(actorIndex, 0, actors.length - 1);
        address account = actors[actorIndex];
        uint256 awaitingBefore = protocolStaking.awaitingRelease(account);
        protocolStaking.release(account);
        uint256 awaitingAfter = protocolStaking.awaitingRelease(account);
        ghost_totalReleased[account] += (awaitingBefore - awaitingAfter);
        ghost_releasedAccount = account;
    }

    /// @notice Unstake then warp past cooldown to allow for valid release() calls.
    function unstakeThenWarp(uint256 actorIndex) external assertTransitionInvariants {
        actorIndex = bound(actorIndex, 0, actors.length - 1);
        address account = actors[actorIndex];
        uint256 stakedBalance = protocolStaking.balanceOf(account);
        if (stakedBalance == 0) return;

        vm.prank(account);
        unstake(actorIndex, stakedBalance);

        uint256 cooldown = protocolStaking.unstakeCooldownPeriod();
        warp(cooldown + 1);
    }

    // **************** Equivalence scenario handlers ****************

    // Compare stake(amount1+amount2) once vs stake(amount1) then stake(amount2).
    function stakeEquivalenceScenario(
        uint256 actorIndex,
        uint256 amount1,
        uint256 amount2,
        uint256 duration
    ) external {
        actorIndex = bound(actorIndex, 0, actors.length - 1);
        address account = actors[actorIndex];

        addEligibleAccount(actorIndex);

        uint256 balance = zama.balanceOf(account);
        if (balance < 2) return;
        amount1 = bound(amount1, 1, balance - 1);
        amount2 = bound(amount2, 1, balance - amount1);
        uint256 totalAmount = amount1 + amount2;

        duration = bound(duration, 1, MAX_PERIOD_DURATION);

        uint256 snapshot = vm.snapshotState();

        // Path A: single stake
        stake(actorIndex, totalAmount);
        uint256 sharesSingle = protocolStaking.balanceOf(account);
        uint256 weightSingle = protocolStaking.weight(protocolStaking.balanceOf(account));

        // Warp past the duration to allow for valid earned() calls.
        warp(duration);
        uint256 earnedSingle = protocolStaking.earned(account);

        vm.revertToState(snapshot);

        // Path B: double stake
        stake(actorIndex, amount1);
        stake(actorIndex, amount2);
        uint256 sharesDouble = protocolStaking.balanceOf(account);
        uint256 weightDouble = protocolStaking.weight(protocolStaking.balanceOf(account));

        warp(duration);
        uint256 earnedDouble = protocolStaking.earned(account);

        ghost_sharesSingle = sharesSingle;
        ghost_sharesDouble = sharesDouble;
        ghost_weightSingle = weightSingle;
        ghost_weightDouble = weightDouble;
        ghost_earnedSingle = earnedSingle;
        ghost_earnedDouble = earnedDouble;
    }

    // Compare partial unstake (to targetStake) vs unstake all then stake(targetStake).
    function unstakeEquivalenceScenario(
        uint256 actorIndex,
        uint256 initialStake,
        uint256 targetStake,
        uint256 duration
    ) external {
        actorIndex = bound(actorIndex, 0, actors.length - 1);
        address account = actors[actorIndex];

        addEligibleAccount(actorIndex);

        uint256 balance = zama.balanceOf(account);
        // Need at least 2 to stake, and leave at least 1 for path B restake (unstaked tokens are queued until release)
        if (balance < 3) return;
        initialStake = bound(initialStake, 2, balance - 1);
        // targetStake must be <= balance - initialStake so path B can restake
        targetStake = bound(targetStake, 1, Math.min(initialStake - 1, balance - initialStake));
        uint256 unstakeAmount = initialStake - targetStake;
        duration = bound(duration, 1, MAX_PERIOD_DURATION);

        uint256 snapshot = vm.snapshotState();

        stake(actorIndex, initialStake);
        warp(duration);

        // Path A: partial unstake
        unstake(actorIndex, unstakeAmount);
        uint256 sharesA = protocolStaking.balanceOf(account);
        uint256 weightA = protocolStaking.weight(protocolStaking.balanceOf(account));

        warp(duration);
        uint256 earnedA = protocolStaking.earned(account);

        vm.revertToState(snapshot);

        // Path B: unstake all then restake target
        stake(actorIndex, initialStake);
        warp(duration);

        unstake(actorIndex, initialStake);
        stake(actorIndex, targetStake);
        uint256 sharesB = protocolStaking.balanceOf(account);
        uint256 weightB = protocolStaking.weight(protocolStaking.balanceOf(account));

        warp(duration);
        uint256 earnedB = protocolStaking.earned(account);

        ghost_sharesUnstakeA = sharesA;
        ghost_sharesUnstakeB = sharesB;
        ghost_weightUnstakeA = weightA;
        ghost_weightUnstakeB = weightB;
        ghost_earnedUnstakeA = earnedA;
        ghost_earnedUnstakeB = earnedB;
    }
}
