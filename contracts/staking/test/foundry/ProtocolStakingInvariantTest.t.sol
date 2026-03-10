// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/* solhint-disable func-name-mixedcase */ // Foundry discovers invariant tests by invariant_* prefix

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Test, console} from "forge-std/Test.sol";
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
        uint48 initialUnstakeCooldownPeriod = uint48(
            vm.randomUint(MIN_UNSTAKE_COOLDOWN_PERIOD, MAX_UNSTAKE_COOLDOWN_PERIOD)
        );
        uint256 initialRewardRate = uint256(vm.randomUint(MIN_REWARD_RATE, MAX_REWARD_RATE));
        uint256 actorCount = uint256(vm.randomUint(MIN_ACTOR_COUNT, MAX_ACTOR_COUNT));

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
            // TODO: Account for tolerance in the invariant due to phantom wei minting,
            // see test_FractionalDustPrinter for the proof of concept.
            handler.ghost_initialTotalSupply() + handler.ghost_accumulatedRewardCapacity(),
            "totalSupply exceeds piecewise rewardRate bound"
        );
    }

    function invariant_RewardDebtConservation() public view {
        uint256 tolerance = handler.computeRewardDebtTolerance();
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

    // ---------- Phantom Wei & Rounding Tests ----------

    /// @dev Helper to quickly spin up an isolated protocol instance with specific token distributions
    function _setupIsolatedStaking(
        address[] memory users,
        uint256[] memory amounts
    ) internal returns (ZamaERC20 token, ProtocolStakingHarness staking) {
        token = new ZamaERC20("Zama", "ZAMA", users, amounts, address(this));

        ProtocolStakingHarness impl = new ProtocolStakingHarness();
        bytes memory initData = abi.encodeCall(
            impl.initialize,
            ("Staked ZAMA", "stZAMA", "1", address(token), address(this), manager, 1 days, 0)
        );
        staking = ProtocolStakingHarness(address(new ERC1967Proxy(address(impl), initData)));

        token.grantRole(token.MINTER_ROLE(), address(staking));

        for (uint256 i = 0; i < users.length; i++) {
            vm.prank(users[i]);
            token.approve(address(staking), type(uint256).max);
        }
    }

    /// @dev Demonstrates the "phantom wei" lock-in: claiming rewards, suffering ratio dilution,
    /// and unstaking leaves an unbacked 1 wei in the user's _paid tracker.
    function test_DilutionTrap() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address charlie = makeAddr("charlie");

        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1;
        amounts[1] = 81;
        amounts[2] = 1;

        ZamaERC20 token;
        ProtocolStakingHarness staking;
        (token, staking) = _setupIsolatedStaking(users, amounts);

        vm.startPrank(manager);
        staking.addEligibleAccount(alice);
        staking.addEligibleAccount(bob);
        staking.addEligibleAccount(charlie);
        vm.stopPrank();

        // Setup initial pool
        vm.prank(alice);
        staking.stake(1);
        vm.prank(bob);
        staking.stake(81);

        // Accrue rewards
        vm.prank(manager);
        staking.setRewardRate(29);
        vm.warp(block.timestamp + 1);
        vm.prank(manager);
        staking.setRewardRate(0);

        // 1. Claim: Locks Bob's _paid at 26 (29 pool * 9 weight / 10 total = 26.1 -> 26).
        vm.prank(bob);
        staking.claimRewards(bob);

        // 2. Dilute: Charlie adds 1 weight. Total pool becomes 31. Total weight becomes 11.
        //    Bob's new theoretical allocation drops to 25 (31 * 9 / 11 = 25.36 -> 25).
        vm.prank(charlie);
        staking.stake(1);

        // 3. Unstake: Subtracts Bob's current allocation (25) from his _paid (26).
        //    Bob's weight becomes 0, but 1 wei remains permanently locked in his _paid.
        vm.prank(bob);
        staking.unstake(81);

        // Evaluate invariant
        int256 rhs = staking._harness_getTotalVirtualPaid() + SafeCast.toInt256(staking._harness_getHistoricalReward());
        int256 lhs = 0;
        for (uint256 i = 0; i < users.length; i++) {
            lhs += staking._harness_getPaid(users[i]) + SafeCast.toInt256(staking.earned(users[i]));
        }

        assertEq(lhs - rhs, 1, "Invariant broken: Phantom wei locked in LHS");
    }

    /// @dev Validates the maximum expected truncation dust (N - 1) for active users.
    function test_MaxNormalTruncationDust() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address charlie = makeAddr("charlie");

        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 9;
        amounts[1] = 9;
        amounts[2] = 16;

        ZamaERC20 token;
        ProtocolStakingHarness staking;
        (token, staking) = _setupIsolatedStaking(users, amounts);

        vm.startPrank(manager);
        for (uint256 i = 0; i < users.length; i++) {
            staking.addEligibleAccount(users[i]);
        }
        vm.stopPrank();

        // 1. Setup weights: Alice=3, Bob=3, Charlie=4. (Total Weight = 10)
        vm.prank(alice);
        staking.stake(9);
        vm.prank(bob);
        staking.stake(9);
        vm.prank(charlie);
        staking.stake(16);

        // 2. Generate exactly 29 wei of reward capacity.
        vm.prank(manager);
        staking.setRewardRate(29);
        vm.warp(block.timestamp + 1);
        vm.prank(manager);
        staking.setRewardRate(0);

        // 3. Mathematical result:
        //    Alice:   29 * 3 / 10 = 8.7 -> floors to 8 (loses 0.7)
        //    Bob:     29 * 3 / 10 = 8.7 -> floors to 8 (loses 0.7)
        //    Charlie: 29 * 4 / 10 = 11.6 -> floors to 11 (loses 0.6)
        //    Total allocated = 27. Total pool = 29. Resulting dust = 2 (N - 1).

        // Evaluate invariant without any claims or unstakes
        int256 rhs = staking._harness_getTotalVirtualPaid() + SafeCast.toInt256(staking._harness_getHistoricalReward());
        int256 lhs = 0;
        for (uint256 i = 0; i < users.length; i++) {
            lhs += staking._harness_getPaid(users[i]) + SafeCast.toInt256(staking.earned(users[i]));
        }

        assertEq(rhs - lhs, 2, "Truncation dust exceeds N - 1 expectation");
    }

    /// @dev Dust Printing PoC: Demonstrates that downward rounding on exit abandons fractional dust
    ///      in the virtual pool, allowing remaining users to mint unauthorized tokens.
    function test_FractionalDustPrinter() public {
        address alice = makeAddr("alice"); // Target Weight: 2
        address bob = makeAddr("bob"); // Target Weight: 3

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 4;
        amounts[1] = 9;

        ZamaERC20 token;
        ProtocolStakingHarness staking;
        (token, staking) = _setupIsolatedStaking(users, amounts);

        // Initial state: Bob eligible, Alice ineligible
        vm.prank(manager);
        staking.addEligibleAccount(bob);
        vm.prank(alice);
        staking.stake(4);
        vm.prank(bob);
        staking.stake(9);

        // Generate exactly 10 wei of capacity
        vm.prank(manager);
        staking.setRewardRate(10);
        vm.warp(block.timestamp + 1);
        vm.prank(manager);
        staking.setRewardRate(0);

        uint256 authorizedRewards = staking._harness_getHistoricalReward();

        assertEq(authorizedRewards, 10, "Authorized rewards should be 10");

        // Bob extracts maximum theoretical value (10 wei)
        vm.prank(bob);
        staking.claimRewards(bob);

        // Alice enters, Bob exits (abandoning fractional dust)
        vm.prank(manager);
        staking.addEligibleAccount(alice);
        vm.prank(manager);
        staking.removeEligibleAccount(bob);

        assertEq(token.balanceOf(alice), 0, "Alice should have no tokens");

        // Alice claims the abandoned dust
        vm.prank(alice);
        staking.claimRewards(alice);

        assertEq(token.balanceOf(alice), 1, "Alice should have 1 token after claiming abandoned dust");

        uint256 totalMinted = token.balanceOf(alice) + token.balanceOf(bob);

        assertGt(totalMinted, authorizedRewards, "Protocol minted unbacked tokens");
        assertEq(totalMinted, 11, "Printer failed to extract exactly 1 wei over cap");
    }
}
