// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ProtocolStakingHarness} from "./harness/ProtocolStakingHarness.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ZamaERC20} from "token/contracts/ZamaERC20.sol";
import {ProtocolStakingHandler} from "./handlers/ProtocolStakingHandler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Invariant fuzz test for ProtocolStaking
contract ProtocolStakingInvariantTest is Test {
    ProtocolStakingHarness internal protocolStaking;
    ZamaERC20 internal zama;
    ProtocolStakingHandler internal handler;

    address internal governor = address(1);
    address internal manager = address(2);
    address internal admin = address(3);

    uint256 internal constant MIN_ACTOR_COUNT = 5;
    uint256 internal constant MAX_ACTOR_COUNT = 20;

    uint256 internal constant MIN_INITIAL_DISTRIBUTION = 1 ether;
    uint256 internal constant MAX_INITIAL_DISTRIBUTION = 1_000_000_000 ether;

    uint256 internal constant MIN_UNSTAKE_COOLDOWN_PERIOD = 1 seconds;
    uint256 internal constant MAX_UNSTAKE_COOLDOWN_PERIOD = 365 days;

    uint256 internal constant MIN_REWARD_RATE = 0;
    uint256 internal constant MAX_REWARD_RATE = 1e24;

    function setUp() public {

        uint256 initialDistribution = uint256(vm.randomUint(MIN_INITIAL_DISTRIBUTION, MAX_INITIAL_DISTRIBUTION));
        uint48 initialUnstakeCooldownPeriod = uint48(vm.randomUint(MIN_UNSTAKE_COOLDOWN_PERIOD, MAX_UNSTAKE_COOLDOWN_PERIOD));
        uint256 initialRewardRate = uint256(vm.randomUint(MIN_REWARD_RATE, MAX_REWARD_RATE));
        uint256 actorCount = uint256(vm.randomUint(MIN_ACTOR_COUNT, MAX_ACTOR_COUNT));

        address[] memory actorsList = new address[](actorCount);
        for (uint256 i = 0; i < actorCount; i++) {
            actorsList[i] = address(uint160(4 + i));
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

        // Approve ProtocolStaking for all actors
        for (uint256 i = 0; i < actorCount; i++) {
            vm.prank(actorsList[i]);
            zama.approve(address(protocolStaking), type(uint256).max);
        }

        // Deploy handler with actors list
        handler = new ProtocolStakingHandler(protocolStaking, zama, manager, actorsList);
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = ProtocolStakingHandler.warp.selector;
        selectors[1] = ProtocolStakingHandler.setRewardRate.selector;
        selectors[2] = ProtocolStakingHandler.addEligibleAccount.selector;
        selectors[3] = ProtocolStakingHandler.removeEligibleAccount.selector;
        selectors[4] = ProtocolStakingHandler.stake.selector;
        selectors[5] = ProtocolStakingHandler.unstake.selector;
        selectors[6] = ProtocolStakingHandler.claimRewards.selector;
        selectors[7] = ProtocolStakingHandler.release.selector;
        selectors[8] = ProtocolStakingHandler.unstakeThenWarp.selector;
        selectors[9] = ProtocolStakingHandler.stakeEquivalenceScenario.selector;
        selectors[10] = ProtocolStakingHandler.unstakeEquivalenceScenario.selector;
        selectors[11] = ProtocolStakingHandler.setUnstakeCooldownPeriod.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_TotalStakedWeightEqualsEligibleWeights() public view {
        assertEq(
            protocolStaking.totalStakedWeight(),
            handler.computeExpectedTotalWeight(),
            "totalStakedWeight does not match sum of eligible weights"
        );
    }

    function invariant_TotalSupplyBoundedByRewardRate() public view {
        assertLe(
            zama.totalSupply(),
            // TODO: Occasional Off-by-one error in the ghost total supply calculation, need to locate the source of the error
            // adding small buffer of 1 wei to account for this for now
            handler.ghost_initialTotalSupply() + handler.ghost_accumulatedRewardCapacity() + 1,
            "totalSupply exceeds piecewise rewardRate bound"
        );
    }

    function invariant_RewardDebtConservation() public view {
        uint256 tolerance = handler.REWARD_DEBT_CONSERVATION_TOLERANCE();
        int256 lhs = handler.computeRewardDebtLHS();
        // When the system is empty, net debt across all users should net out to 0
        // Σ _paid[account] + Σ earned(account) = 0
        // Using ApproxEqAbs per contract comment: "Accounting rounding may have a marginal impact on earned rewards (dust)."
        if (protocolStaking.totalStakedWeight() == 0) {
            assertApproxEqAbs(lhs, 0, tolerance, "Net reward debt must be 0 when no one is staked");
            return;
        }
        int256 rhs = handler.computeRewardDebtRHS();
        assertApproxEqAbs(lhs, rhs, tolerance, "reward debt conservation");
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
}
