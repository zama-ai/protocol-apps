// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/* solhint-disable func-name-mixedcase */ // Foundry discovers invariant tests by invariant_* prefix

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Test} from "forge-std/Test.sol";
import {ZamaERC20} from "token/contracts/ZamaERC20.sol";
import {ProtocolStakingHandler} from "./handlers/ProtocolStakingHandler.sol";
import {ProtocolStakingHarness} from "./harness/ProtocolStakingHarness.sol";

// Invariant fuzz test for ProtocolStaking
contract ProtocolStakingInvariantTest is Test {
    ProtocolStakingHarness internal protocolStaking;
    ZamaERC20 internal zama;
    ProtocolStakingHandler internal handler;

    address internal governor = makeAddr("governor");
    address internal manager = makeAddr("manager");
    address internal admin = makeAddr("admin");

    // Static setup constants — the fuzzer varies these dimensions via setRewardRate,
    // setUnstakeCooldownPeriod, and bounded stake/unstake amounts.
    // Actor count is fixed to 7 (5 eligible, 2 ineligible) to allow for meaningful sequence depth in the fuzzer.
    uint256 internal constant ACTOR_COUNT = 7;
    uint256 internal constant ELIGIBLE_COUNT = 5;
    uint256 internal constant INITIAL_DISTRIBUTION = type(uint128).max; // large but leaves upper 128 bits for reward mints
    uint48 internal constant INITIAL_UNSTAKE_COOLDOWN_PERIOD = 7 days;
    uint256 internal constant INITIAL_REWARD_RATE = 1e18;

    function setUp() public {
        uint256 actorCount = ACTOR_COUNT;
        uint256 initialDistribution = INITIAL_DISTRIBUTION;
        uint48 initialUnstakeCooldownPeriod = INITIAL_UNSTAKE_COOLDOWN_PERIOD;
        uint256 initialRewardRate = INITIAL_REWARD_RATE;

        address[] memory actorsList = new address[](actorCount);
        for (uint256 i = 0; i < actorCount; i++) {
            actorsList[i] = makeAddr(string(abi.encodePacked("actor", i)));
        }

        // Deploy ZamaERC20, mint to all actors, admin is DEFAULT_ADMIN
        address[] memory receivers = new address[](actorCount);
        uint256[] memory amounts = new uint256[](actorCount);
        for (uint256 i = 0; i < actorCount; i++) {
            receivers[i] = actorsList[i];
            amounts[i] = initialDistribution;
        }

        zama = new ZamaERC20("Zama", "ZAMA", receivers, amounts, admin);

        // Deploy ProtocolStaking behind ERC1967 proxy
        ProtocolStakingHarness impl = new ProtocolStakingHarness();
        bytes memory initData = abi.encodeCall(
            protocolStaking.initialize,
            (
                "Staked ZAMA",
                "stZAMA",
                "1",
                address(zama),
                governor,
                manager,
                initialUnstakeCooldownPeriod,
                initialRewardRate
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        protocolStaking = ProtocolStakingHarness(address(proxy));

        // Grant MINTER_ROLE on Zama to ProtocolStaking
        vm.startPrank(admin);
        zama.grantRole(zama.MINTER_ROLE(), address(protocolStaking));
        vm.stopPrank();

        // Make the first ELIGIBLE_COUNT actors eligible; the remaining 2 start ineligible
        vm.startPrank(manager);
        for (uint256 i = 0; i < ELIGIBLE_COUNT; i++) {
            protocolStaking.addEligibleAccount(actorsList[i]);
        }
        vm.stopPrank();

        // Approve ProtocolStaking for all actors
        for (uint256 i = 0; i < actorCount; i++) {
            vm.prank(actorsList[i]);
            zama.approve(address(protocolStaking), type(uint256).max);
        }

        // Deploy handler with actors list
        handler = new ProtocolStakingHandler(protocolStaking, zama, manager, actorsList);
        targetContract(address(handler));

        for (uint256 i = 0; i < actorCount; i++) {
            targetSender(actorsList[i]);
        }
    }

    function invariant_TotalSupplyBoundedByRewardRate() public view {
        assertLe(
            zama.totalSupply(),
            handler.ghost_initialTotalSupply() +
                handler.ghost_accumulatedRewardCapacity() +
                handler.ghost_truncationOps(),
            "totalSupply exceeds piecewise rewardRate bound + truncation tolerance"
        );
    }

    function invariant_TotalStakedWeightEqualsEligibleWeights() public view {
        assertEq(
            protocolStaking.totalStakedWeight(),
            handler.computeExpectedTotalWeight(),
            "totalStakedWeight does not match sum of eligible weights"
        );
    }

    function invariant_RewardConservation() public view {
        uint256 tolerance = handler.computeRewardConservationTolerance();
        int256 actorTotal = handler.computeActorRewardTotal();
        // When the system is empty, the actor reward total should be approximately 0:
        // | Σ _paid[account] + Σ earned(account) | ≤ tolerance
        if (protocolStaking.totalStakedWeight() == 0) {
            assertApproxEqAbs(actorTotal, 0, tolerance, "Actor reward total must be ~0 when no one is staked");
            return;
        }
        int256 protocolTotal = handler.computeProtocolRewardTotal();
        // Reward conservation: actor total ≈ protocol total (abs error ≤ tolerance)
        // Σ _paid(account) + Σ earned(account) ≈ _totalVirtualPaid + historicalReward
        assertApproxEqAbs(actorTotal, protocolTotal, tolerance, "reward conservation");
    }

    function invariant_PendingWithdrawalsSolvency() public view {
        address token = protocolStaking.stakingToken();
        uint256 balance = IERC20(token).balanceOf(address(protocolStaking));
        uint256 sumAwaitingRelease;
        for (uint256 i = 0; i < handler.actorsLength(); i++) {
            sumAwaitingRelease += protocolStaking.awaitingRelease(handler.actorAt(i));
        }
        assertGe(balance, sumAwaitingRelease, "pending withdrawals solvency");
    }

    function invariant_StakedFundsSolvency() public view {
        for (uint256 i = 0; i < handler.actorsLength(); i++) {
            address account = handler.actorAt(i);
            uint256 totalStaked = handler.ghost_totalStaked(account);
            uint256 balance = protocolStaking.balanceOf(account);
            uint256 awaiting = protocolStaking.awaitingRelease(account);
            uint256 released = handler.ghost_totalReleased(account);
            assertEq(totalStaked, balance + awaiting + released, "staked funds solvency");
        }
    }

    /// @notice Checkpoint traces for each account must have non-decreasing timestamps
    ///         and non-decreasing cumulative share amounts.
    function invariant_UnstakeQueueMonotonicity() public view {
        uint256 actorCount = handler.actorsLength();
        for (uint256 i = 0; i < actorCount; i++) {
            address actor = handler.actorAt(i);
            uint256 count = protocolStaking._harness_getUnstakeRequestCheckpointCount(actor);
            if (count <= 1) continue;

            (uint48 prevKey, uint208 prevValue) = protocolStaking._harness_getUnstakeRequestCheckpointAt(actor, 0);
            for (uint256 j = 1; j < count; j++) {
                (uint48 key, uint208 value) = protocolStaking._harness_getUnstakeRequestCheckpointAt(actor, j);
                assertGe(key, prevKey, "unstake checkpoint timestamps must be non-decreasing");
                assertGe(value, prevValue, "unstake checkpoint cumulative shares must be non-decreasing");
                prevKey = key;
                prevValue = value;
            }
        }
    }
}
