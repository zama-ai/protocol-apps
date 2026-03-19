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
        uint256 n = 20;

        address[] memory users = new address[](n);
        uint256[] memory amounts = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            users[i] = makeAddr(string(abi.encodePacked("user", vm.toString(i))));
            amounts[i] = 1;
        }

        ZamaERC20 token;
        ProtocolStakingHarness staking;
        (token, staking) = _setupIsolatedStaking(users, amounts);

        vm.startPrank(manager);
        for (uint256 i = 0; i < n; i++) {
            staking.addEligibleAccount(users[i]);
        }
        vm.stopPrank();

        // 1. Setup weights: Every user has weight 1. (Total Weight = 20)
        for (uint256 i = 0; i < n; i++) {
            vm.prank(users[i]);
            staking.stake(1);
        }

        // 2. Generate exactly 39 wei of reward capacity.
        // Formula to maximize dust: RewardRate % TotalWeight == TotalWeight - 1
        // 39 % 20 == 19
        vm.prank(manager);
        staking.setRewardRate(39);
        vm.warp(block.timestamp + 1);
        vm.prank(manager);
        staking.setRewardRate(0);

        // 3. Mathematical result:
        //    Each User: 39 * 1 / 20 = 1.95 -> floors to 1 (loses 0.95)
        //    Total allocated = 20 * 1 = 20. Total pool = 39. Resulting dust = 19 (N - 1).

        // Evaluate invariant without any claims or unstakes
        int256 rhs = staking._harness_getTotalVirtualPaid() + SafeCast.toInt256(staking._harness_getHistoricalReward());
        int256 lhs = 0;
        for (uint256 i = 0; i < n; i++) {
            lhs += staking._harness_getPaid(users[i]) + SafeCast.toInt256(staking.earned(users[i]));
        }

        assertEq(rhs - lhs, int256(n - 1), "Truncation dust exceeds N - 1 expectation");
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

    function test_BatchUnstakePrintsGlobalDust_18Decimals() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        ZamaERC20 token;
        ProtocolStakingHarness staking;

        {
            address[] memory users = new address[](2);
            users[0] = alice;
            users[1] = bob;

            uint256[] memory amounts = new uint256[](2);
            amounts[0] = 2999999998188649249; // ~sqrt(3e18)
            amounts[1] = 999999999965065000000; // ~sqrt(1000e18)

            (token, staking) = _setupIsolatedStaking(users, amounts);
        }

        vm.startPrank(manager);
        staking.addEligibleAccount(alice);
        staking.addEligibleAccount(bob);
        vm.stopPrank();

        vm.prank(alice);
        staking.stake(2999999998188649249);
        vm.prank(bob);
        staking.stake(999999999965065000000);

        uint256 initialTotalSupply = token.totalSupply();
        uint256 expectedTotalRewards = 10_000 * 1e18 * 10;

        vm.startPrank(manager);
        staking.setRewardRate(10_000 * 1e18);
        vm.warp(block.timestamp + 10);
        staking.setRewardRate(0);
        vm.stopPrank();

        // Lock in positive debt before unstaking
        vm.prank(bob);
        staking.claimRewards(bob);

        {
            uint256 currentWeight = staking.weight(staking.balanceOf(bob));
            uint256 weightStep = currentWeight / 20;

            vm.startPrank(bob);
            for (uint256 j = 0; j < 20; j++) {
                uint256 nextWeight = currentWeight - weightStep;
                uint256 amountToUnstake;

                if (j == 19) {
                    nextWeight = 0;
                    amountToUnstake = staking.balanceOf(bob);
                } else {
                    amountToUnstake = (currentWeight * currentWeight) - (nextWeight * nextWeight);
                }

                staking.unstake(amountToUnstake);
                currentWeight = nextWeight;
            }
            vm.stopPrank();
        }

        vm.prank(alice);
        staking.claimRewards(alice);

        int256 globalDrift = int256(token.totalSupply() - initialTotalSupply) - int256(expectedTotalRewards);

        // The sum of all unstakes telescopes to approximately floor(P₀ × W_bob / W₀),
        // bounding total drift near 1 wei — the same as a single one-shot unstake.
        assertGt(globalDrift, 0, "Protocol failed to over-mint unbacked dust");
        assertLe(globalDrift, 2, "Over-minting exceeded throttling bound for single-account sequential unstakes");
    }

    /// @dev Demonstrates unbounded dust extraction
    function test_SybilRelayDustPrinter_18Decimals() public {
        uint256 wad = 1e18;
        uint256 relayCount = 20;

        address[] memory users = new address[](relayCount);
        uint256[] memory amounts = new uint256[](relayCount);

        // Setup Chaotic Sybil Weights
        for (uint256 i = 0; i < relayCount; i++) {
            users[i] = address(uint160(uint256(keccak256(abi.encode("sybil", i)))));
            amounts[i] = ((i * 13) + 7) * wad;
        }

        ZamaERC20 token;
        ProtocolStakingHarness staking;
        (token, staking) = _setupIsolatedStaking(users, amounts);

        // Initial State
        for (uint256 i = 0; i < relayCount; i++) {
            vm.prank(users[i]);
            staking.stake(amounts[i]);
        }

        vm.prank(manager);
        staking.addEligibleAccount(users[0]);

        uint256 initialTotalSupply = token.totalSupply();

        // Generate 10 tokens of reward capacity
        uint256 rate = 1 * wad;
        uint256 duration = 10;
        uint256 expectedTotalRewards = rate * duration;

        vm.prank(manager);
        staking.setRewardRate(rate);
        vm.warp(block.timestamp + duration);
        vm.prank(manager);
        staking.setRewardRate(0);

        vm.prank(users[0]);
        staking.claimRewards(users[0]);

        // The Extraction Loop
        for (uint256 i = 0; i < relayCount - 1; i++) {
            address currentSybil = users[i];
            address nextSybil = users[i + 1];

            // Pass the baton: Next enters, Current exits
            vm.startPrank(manager);
            staking.addEligibleAccount(nextSybil);
            staking.removeEligibleAccount(currentSybil);
            vm.stopPrank();

            // NextSybil claims as the lone account, bypassing claim truncation (W/W = 1)
            vm.prank(nextSybil);
            staking.claimRewards(nextSybil);
        }

        // Measure the final physical drift
        uint256 actualRewardsMinted = token.totalSupply() - initialTotalSupply;
        int256 totalDrift = int256(actualRewardsMinted) - int256(expectedTotalRewards);

        // Each relay is an independent removeEligibleAccount on a different account and
        // pool state — no cross-step throttling applies. Each produces ~1 wei of inflation
        // in _totalVirtualPaid that the next sole claimer extracts at full W/W ratio.
        assertApproxEqAbs(
            uint256(totalDrift),
            relayCount - 1,
            1,
            "Each independent relay should produce ~1 wei of drift"
        );
    }

    function test_SpongeAndMartyr_NoManagerPrivileges() public {
        address alice = makeAddr("alice"); // Honest User
        address sponge = makeAddr("sponge"); // Attacker Account 1
        address martyr = makeAddr("martyr"); // Attacker Account 2

        ZamaERC20 token;
        ProtocolStakingHarness staking;

        // Isolate the setup arrays so they drop off the stack immediately
        {
            address[] memory users = new address[](3);
            users[0] = alice;
            users[1] = sponge;
            users[2] = martyr;

            uint256[] memory amounts = new uint256[](3);
            amounts[0] = 3 * 1e18; // Alice Weight: sqrt(3e18)
            amounts[1] = 1 * 1e18; // Sponge Weight: 1e9
            amounts[2] = 1000 * 1e18; // Martyr Weight: sqrt(1000e18)

            (token, staking) = _setupIsolatedStaking(users, amounts);
        }

        // Initial Setup
        vm.prank(manager);
        staking.addEligibleAccount(alice);
        vm.prank(alice);
        staking.stake(3 * 1e18);

        vm.prank(manager);
        staking.addEligibleAccount(sponge);
        vm.prank(sponge);
        staking.stake(1 * 1e18);

        vm.prank(manager);
        staking.addEligibleAccount(martyr);
        vm.prank(martyr);
        staking.stake(1000 * 1e18);

        // Generate Rewards (Block Scoped)
        {
            vm.prank(manager);
            staking.setRewardRate(10_000 * 1e18);
            vm.warp(block.timestamp + 10);
            vm.prank(manager);
            staking.setRewardRate(0);
        }

        // Snapshot legitimate baselines before the attack
        uint256 aliceExpected = staking.earned(alice);
        uint256 spongeExpectedBaseline = staking.earned(sponge);

        // The Attack Step 1: Martyr claims legitimate rewards first
        vm.prank(martyr);
        staking.claimRewards(martyr);

        // The Attack Step 2: Martyr executes chunked unstake to print dust
        uint256 currentWeight = staking.weight(1000 * 1e18);
        uint256 weightStep = currentWeight / 10;

        vm.startPrank(martyr);
        for (uint256 j = 0; j < 10; j++) {
            uint256 nextWeight = currentWeight - weightStep;

            // On the final chunk, ensure weight zeroes out completely
            if (j == 9) nextWeight = 0;

            staking.unstake((currentWeight * currentWeight) - (nextWeight * nextWeight));
            currentWeight = nextWeight;
        }
        vm.stopPrank();

        // Measure Results
        // Alice (Honest User) claims
        vm.prank(alice);
        staking.claimRewards(alice);

        // Sponge (Attacker) claims
        vm.prank(sponge);
        staking.claimRewards(sponge);

        int256 aliceGain = int256(token.balanceOf(alice)) - int256(aliceExpected);

        int256 spongeGain = int256(token.balanceOf(sponge)) - int256(spongeExpectedBaseline);

        // Alice received free dust printed by the Martyr
        assertGt(aliceGain, 0, "Alice should have received the abandoned dust");

        // Attacker's Sponge failed to extract a meaningful amount
        // because the claim truncation and proportional sharing swallowed it.
        assertLe(spongeGain, 0, "Attacker should not profit from this vector");
    }

    /// @dev Demonstrates that phantom wei compounds beyond 1 for a single account through
    ///      repeated dilution events. Each new staker that enters while Bob is in the phantom
    ///      zone (earned == 0) causes his allocation to drop further below his locked _paid,
    ///      accumulating 4 wei of phantom on a single account with just 7 dilution events.
    ///
    ///      Truncation dust (5 wei downward) partially cancels the phantom
    ///      (4 wei upward), but a sufficiently adversarial sequence could in theory push the
    ///      total phantom past N.
    function test_CompoundPhantomWei() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        uint256 numDiluters = 7;
        uint256 totalUsers = 2 + numDiluters;

        ZamaERC20 token;
        ProtocolStakingHarness staking;
        address[] memory users;

        {
            users = new address[](totalUsers);
            uint256[] memory amounts = new uint256[](totalUsers);

            users[0] = alice;
            amounts[0] = 1; // weight = sqrt(1) = 1
            users[1] = bob;
            amounts[1] = 81; // weight = sqrt(81) = 9
            for (uint256 i = 0; i < numDiluters; i++) {
                users[2 + i] = makeAddr(string(abi.encodePacked("d", vm.toString(i))));
                amounts[2 + i] = 1; // weight = 1 each
            }

            (token, staking) = _setupIsolatedStaking(users, amounts);
        }

        vm.startPrank(manager);
        staking.addEligibleAccount(alice);
        staking.addEligibleAccount(bob);
        vm.stopPrank();

        vm.prank(alice);
        staking.stake(1);
        vm.prank(bob);
        staking.stake(81);

        // Pool = 29, W = 10. Bob's allocation = floor(29 * 9 / 10) = 26.
        vm.prank(manager);
        staking.setRewardRate(29);
        vm.warp(block.timestamp + 1);
        vm.prank(manager);
        staking.setRewardRate(0);

        // Bob claims: locks _paid[Bob] = 26. earned(Bob) = 0.
        vm.prank(bob);
        staking.claimRewards(bob);
        assertEq(staking._harness_getPaid(bob), 26, "Bob _paid after claim");
        assertEq(staking.earned(bob), 0, "Bob earned 0 after claim");

        // Add 7 diluters one at a time. Each entry adjusts the pool via a truncated
        // virtualAmount, causing Bob's allocation to drop below his locked _paid.
        for (uint256 i = 0; i < numDiluters; i++) {
            vm.prank(manager);
            staking.addEligibleAccount(users[2 + i]);
            vm.prank(users[2 + i]);
            staking.stake(1);
        }

        // Bob is still in the phantom zone: allocation < _paid, so earned = 0.
        assertEq(staking.earned(bob), 0, "Bob still in phantom zone after dilution");

        // Compute Bob's phantom: _paid - allocation
        uint256 bobPhantom;
        {
            uint256 pool = SafeCast.toUint256(
                SafeCast.toInt256(staking._harness_getHistoricalReward()) + staking._harness_getTotalVirtualPaid()
            );
            uint256 bobAllocation = Math.mulDiv(
                pool,
                staking.weight(staking.balanceOf(bob)),
                staking.totalStakedWeight()
            );
            bobPhantom = 26 - bobAllocation;
        }

        // Bob's account accumulates 4 wei of phantom
        assertEq(bobPhantom, 4, "Compound phantom: 4 wei on single account");

        // When Bob exits, the full phantom becomes stranded in _paid.
        vm.prank(bob);
        staking.unstake(81);
        assertEq(uint256(staking._harness_getPaid(bob)), bobPhantom, "Residual _paid equals phantom");

        // The reward debt invariant still holds here because truncation dust
        // (5 wei downward) partially cancels the phantom (4 wei upward).
        {
            int256 rhs = staking._harness_getTotalVirtualPaid() +
                SafeCast.toInt256(staking._harness_getHistoricalReward());
            int256 lhs = 0;
            for (uint256 i = 0; i < totalUsers; i++) {
                lhs += staking._harness_getPaid(users[i]) + SafeCast.toInt256(staking.earned(users[i]));
            }
            // Net divergence is -1 (truncation dominates), well within N=9.
            // But this only holds because the two forces happen to partially cancel.
            assertEq(lhs - rhs, -1, "Net divergence: truncation (5) vs phantom (4)");
        }
    }
}
