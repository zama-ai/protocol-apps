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

    // ─────────────────────────────────────────────────────────────────────────────
    // Tolerance Bound Proofs
    //
    // Each test constructs a minimal, numerically exact scenario to prove the bound
    // of one tolerance term in the invariant suite. Together they justify every
    // constant and ghost counter used in the handler.
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev Deploys a fresh ZamaERC20 + ProtocolStaking pair for isolated unit tests,
    ///      independent of the fuzz setUp state.
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

    /// @notice Shows that the unit contribution of the phantom wei (D) term in computeRewardDebtTolerance.
    /// @dev One dilution event — a weight-increase op while a claimant's _paid is already locked —
    ///      strands exactly 1 wei in `_paid`, pushing the reward debt LHS up by 1.
    ///      This is the base case for ghost_dilutionOps: each dilution event contributes at most 1
    ///      to the D term.
    ///
    ///      Setup:  Alice (w=1), Bob (w=9). Pool = 29. Bob claims, locking _paid = 26.
    ///      Event:  Charlie stakes (w=1). W becomes 11. Bob's allocation drops to floor(31×9/11) = 25.
    ///      Assert: lhs − rhs == 1.
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

        // Claim: locks _paid[Bob] = floor(29 × 9 / 10) = 26.
        vm.prank(bob);
        staking.claimRewards(bob);

        // Dilute: Charlie stakes. Pool → 31, W → 11. Bob's allocation drops to floor(31 × 9 / 11) = 25.
        vm.prank(charlie);
        staking.stake(1);

        // Unstake: _updateRewards credits Bob floor(31 × 9 / 11) = 25, but _paid is 26. 1 wei stranded.
        vm.prank(bob);
        staking.unstake(81);

        int256 rhs = staking._harness_getTotalVirtualPaid() + SafeCast.toInt256(staking._harness_getHistoricalReward());
        int256 lhs = 0;
        for (uint256 i = 0; i < users.length; i++) {
            lhs += staking._harness_getPaid(users[i]) + SafeCast.toInt256(staking.earned(users[i]));
        }

        assertEq(lhs - rhs, 1, "Invariant broken: Phantom wei locked in LHS");
    }

    /// @notice Shows the N term in computeRewardDebtTolerance (truncation dust).
    /// @dev N eligible accounts with equal weight and a worst-case reward rate produce exactly
    ///      N − 1 wei of truncation dust, pulling the reward debt LHS down by N − 1.
    ///
    ///      Worst-case formula: rate % N == N − 1 (maximises per-account fractional loss).
    ///      With N=20, rate=39: each account earns floor(39/20) = 1, losing 0.95 each.
    ///      Aggregate dust = 39 − 20 = 19 = N − 1.
    ///      Assert: rhs − lhs == N − 1.
    function test_MaxNormalTruncationDust() public {
        uint256 n = vm.randomUint(1, 100);

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

        // N accounts, weight 1 each (W = 20).
        for (uint256 i = 0; i < n; i++) {
            vm.prank(users[i]);
            staking.stake(1);
        }

        // Rate 39 chosen so 39 % 20 == 19 = N − 1 (maximises per-account fractional loss).
        // Each account earns floor(39 × 1 / 20) = 1. Aggregate allocated = 20. Dust = 19.
        vm.prank(manager);
        staking.setRewardRate(39);
        vm.warp(block.timestamp + 1);
        vm.prank(manager);
        staking.setRewardRate(0);

        int256 rhs = staking._harness_getTotalVirtualPaid() + SafeCast.toInt256(staking._harness_getHistoricalReward());
        int256 lhs = 0;
        for (uint256 i = 0; i < n; i++) {
            lhs += staking._harness_getPaid(users[i]) + SafeCast.toInt256(staking.earned(users[i]));
        }

        assertEq(rhs - lhs, int256(n - 1), "Truncation dust exceeds N - 1 expectation");
    }

    /// @notice Shows the unit contribution of ghost_truncationOps to invariant_TotalSupplyBoundedByRewardRate.
    /// @dev One weight-decrease op (removeEligibleAccount with staked balance) inflates _totalVirtualPaid
    ///      by 1 wei via mulDiv truncation, enabling a subsequent claimer to mint exactly 1 wei above
    ///      the authorised reward cap.
    ///
    ///      Setup:  Bob (w=3) is the sole eligible staker. Pool = 10. Bob claims all 10.
    ///      Event:  Alice (w=2) enters, Bob exits via removeEligibleAccount (1 truncation op).
    ///      Result: Alice claims 1 unbacked wei. totalMinted = 11 > historicalReward = 10.
    ///      Assert: totalMinted == authorizedRewards + 1 (invariant_TotalSupplyBoundedByRewardRate
    ///              would fail without the + ghost_truncationOps tolerance term).
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

        // Bob (sole eligible, W/W = 1) claims all 10. No truncation.
        vm.prank(bob);
        staking.claimRewards(bob);

        // Alice enters, Bob exits. removeEligibleAccount inflates _totalVirtualPaid by 1 wei (1 truncation op).
        vm.prank(manager);
        staking.addEligibleAccount(alice);
        vm.prank(manager);
        staking.removeEligibleAccount(bob);

        assertEq(token.balanceOf(alice), 0, "Alice should have no tokens before claim");

        // Alice (now sole eligible) claims. The inflated pool lets her mint 1 unbacked wei.
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

    /// @notice Shows that ghost_truncationOps scales linearly with independent weight-decrease ops.
    /// @dev Each relay calls removeEligibleAccount on a different account and pool state, so the
    ///      throttling recurrence does not apply — each exit inflates _totalVirtualPaid by ~1 wei
    ///      and the next sole claimer extracts it at full W/W = 1. Over relayCount − 1 iterations,
    ///      total drift ≈ relayCount − 1 wei.
    ///
    ///      This validates that one ghost_truncationOps increment per weight-decrease op is the
    ///      tight upper bound for invariant_TotalSupplyBoundedByRewardRate.
    ///      Assert: totalDrift ≈ relayCount − 1 (within ±1 wei).
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

        // Relay loop: each iteration hands the eligible slot to the next sybil.
        // removeEligibleAccount inflates _totalVirtualPaid by ~1 wei (independent pool state each time).
        // The incoming sole claimer extracts that inflation at W/W = 1 — no truncation.
        for (uint256 i = 0; i < relayCount - 1; i++) {
            address currentSybil = users[i];
            address nextSybil = users[i + 1];

            vm.startPrank(manager);
            staking.addEligibleAccount(nextSybil);
            staking.removeEligibleAccount(currentSybil);
            vm.stopPrank();

            vm.prank(nextSybil);
            staking.claimRewards(nextSybil);
        }

        uint256 actualRewardsMinted = token.totalSupply() - initialTotalSupply;
        int256 totalDrift = int256(actualRewardsMinted) - int256(expectedTotalRewards);

        // relayCount - 1 exits × ~1 wei each = ~relayCount - 1 total drift.
        assertApproxEqAbs(
            uint256(totalDrift),
            relayCount - 1,
            1,
            "Each independent relay should produce ~1 wei of drift"
        );
    }

    /// @notice Shows that phantom wei compounds across multiple dilution events on a single account,
    ///         justifying ghost_dilutionOps (D) as the correct bound rather than a per-account constant.
    /// @dev After Bob claims (locking _paid = 26), each new staker reduces his allocation via
    ///      truncated virtualAmount arithmetic. With 7 diluters, Bob accumulates 4 wei of phantom —
    ///      exceeding the naive 1-per-account assumption and proving D must scale with event count.
    ///
    ///      Trace (pool / W / Bob alloc / phantom):
    ///        Claim:    29 / 10 / 26 / 0
    ///        After D1: 31 / 11 / 25 / 1
    ///        After D2: 33 / 12 / 24 / 2
    ///        After D3: 35 / 13 / 24 / 2
    ///        After D4: 37 / 14 / 23 / 3
    ///        After D5: 39 / 15 / 23 / 3
    ///        After D6: 41 / 16 / 23 / 3
    ///        After D7: 43 / 17 / 22 / 4
    ///      Assert: bobPhantom == 4, lhs − rhs == −1 (truncation dust of 5 partially cancels phantom of 4).
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

        // Each diluter's addEligibleAccount + stake adjusts the pool via truncated virtualAmount,
        // compounding Bob's phantom one step at a time (see trace in function natspec).
        for (uint256 i = 0; i < numDiluters; i++) {
            vm.prank(manager);
            staking.addEligibleAccount(users[2 + i]);
            vm.prank(users[2 + i]);
            staking.stake(1);
        }

        // Bob remains in the phantom zone after all 7 dilutions (allocation < _paid → earned = 0).
        assertEq(staking.earned(bob), 0, "Bob still in phantom zone after dilution");

        // phantom = _paid − current allocation
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

        assertEq(bobPhantom, 4, "Compound phantom: 4 wei on single account");

        // On exit, _updateRewards credits the floored allocation; residual _paid == phantom.
        vm.prank(bob);
        staking.unstake(81);
        assertEq(uint256(staking._harness_getPaid(bob)), bobPhantom, "Residual _paid equals phantom");

        // Invariant still holds: truncation dust (5 wei down) partially cancels phantom (4 wei up).
        {
            int256 rhs = staking._harness_getTotalVirtualPaid() +
                SafeCast.toInt256(staking._harness_getHistoricalReward());
            int256 lhs = 0;
            for (uint256 i = 0; i < totalUsers; i++) {
                lhs += staking._harness_getPaid(users[i]) + SafeCast.toInt256(staking.earned(users[i]));
            }
            // Net = −1: truncation dust (5↓) dominates phantom (4↑). Both forces within N+D tolerance.
            assertEq(lhs - rhs, -1, "Net divergence: truncation (5) vs phantom (4)");
        }
    }
}
