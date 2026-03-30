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

    /// @notice Shows the unit contribution of the phantom wei (D) term in computeRewardConservationTolerance.
    /// @dev One dilution event, a weight-increase operation while a claimant's _paid is already locked,
    ///      strands exactly 1 wei in _paid, pushing the actor total up by 1.
    ///      This is the base case for ghost_dilutionOps: each dilution event contributes at most 1 to the D term.
    ///
    ///      Notation: w = weight(balance) = sqrt(balance) for a single account.
    ///                W = _totalEligibleStakedWeight = Σ w for all eligible accounts.
    ///                Pool = historicalReward + _totalVirtualPaid.
    ///                D = ghost_dilutionOps, the count of weight-increase events.
    ///
    ///      Setup:  Alice (w=1), Bob (w=9). Pool = 29. Bob claims, locking _paid = 26.
    ///      Event:  Charlie stakes (w=1). W becomes 11. Bob's allocation drops to floor(31×9/11) = 25.
    ///      Assert: Σ _paid(account) + Σ earned(account) - _totalVirtualPaid + historicalReward == 1.
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

        // Alice stakes 1:  weight(1)  = sqrt(1)  = 1
        // Bob   stakes 81: weight(81) = sqrt(81) = 9
        //
        // ── W = 10 | historicalReward = 0 | _totalVirtualPaid = 0 | Pool = 0
        // ── _paid: [Alice=0, Bob=0, Charlie=0]
        vm.prank(alice);
        staking.stake(1);
        vm.prank(bob);
        staking.stake(81);

        // historicalReward = 0 + (29 × 1s) = 29
        //
        // ── W = 10 | historicalReward = 29 | _totalVirtualPaid = 0 | Pool = 29 + 0 = 29
        // ── _paid: [Alice=0, Bob=0, Charlie=0]
        vm.prank(manager);
        staking.setRewardRate(29);
        vm.warp(block.timestamp + 1);
        vm.prank(manager);
        staking.setRewardRate(0);

        // earned(Bob) = _allocation(9, 10) = floor(29 × 9 / 10) = floor(261 / 10) = 26
        // _paid[Bob] += 26
        //
        // ── W = 10 | historicalReward = 29 | _totalVirtualPaid = 0 | Pool = 29
        // ── _paid: [Alice=0, Bob=26, Charlie=0]
        vm.prank(bob);
        staking.claimRewards(bob);

        // Charlie stakes 1: weight(1) = 1. _updateRewards(charlie, 0, 1):
        //   virtualAmount = _allocation(1, 10) = floor(29 × 1 / 10) = floor(2.9) = 2
        //   _paid[Charlie] += 2, _totalVirtualPaid += 2
        //
        // ── W = 11 | historicalReward = 29 | _totalVirtualPaid = 2 | Pool = 29 + 2 = 31
        // ── _paid: [Alice=0, Bob=26, Charlie=2]
        //
        // Bob's allocation = _allocation(9, 11) = floor(31 × 9 / 11) = floor(25.36) = 25
        // earned(Bob) = max(0, 25 - 26) = 0  →  1 wei phantom
        vm.prank(charlie);
        staking.stake(1);

        // Bob unstakes 81: _updateRewards(bob, 9, 0):
        //   virtualAmount = _allocation(9, 11) = floor(31 × 9 / 11) = floor(25.36) = 25
        //   _paid[Bob] -= 25 → 26 - 25 = 1  (stranded phantom wei)
        //   _totalVirtualPaid -= 25 → 2 - 25 = -23
        //
        // ── W = 2 | historicalReward = 29 | _totalVirtualPaid = -23 | Pool = 29 + (-23) = 6
        // ── _paid: [Alice=0, Bob=1, Charlie=2]
        vm.prank(bob);
        staking.unstake(81);

        // rhs = _totalVirtualPaid + historicalReward = -23 + 29 = 6
        //
        // lhs = Σ(_paid[i] + earned[i]):
        //   Alice:   _paid=0 + earned=floor(6 × 1 / 2) - 0     = 0 + 3 = 3
        //   Bob:     _paid=1 + earned=0 (w=0)                   = 1 + 0 = 1
        //   Charlie: _paid=2 + earned=floor(6 × 1 / 2) - 2      = 2 + 1 = 3
        //   lhs = 3 + 1 + 3 = 7
        //
        // lhs - rhs = 7 - 6 = 1
        int256 rhs = staking._harness_getTotalVirtualPaid() + SafeCast.toInt256(staking._harness_getHistoricalReward());
        int256 lhs = 0;
        for (uint256 i = 0; i < users.length; i++) {
            lhs += staking._harness_getPaid(users[i]) + SafeCast.toInt256(staking.earned(users[i]));
        }

        assertEq(lhs - rhs, 1, "Invariant broken: Phantom wei locked in LHS");
    }

    /// @notice Shows the N term in computeRewardConservationTolerance (truncation dust).
    /// @dev N eligible accounts with equal weight and a worst-case reward rate produce exactly
    ///      N − 1 wei of truncation dust, pulling the actor total of the reward conservation invariant down by N − 1.
    ///
    ///      Notation:
    ///         N = number of eligible accounts.
    ///         rate = reward rate per second.
    ///         Pool = historicalReward + _totalVirtualPaid.
    ///
    ///
    ///      Worst-case formula: rate % N == N − 1 (maximises per-account fractional loss).
    ///      With N=20, rate=39: each account earns floor(39/20) = 1.95 -> 1, losing 0.95 each.
    ///      Aggregate dust = 39 − 20 = 19 = N − 1.
    ///      Assert: Σ _paid(account) + Σ earned(account) - _totalVirtualPaid + historicalReward == N − 1.
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

        // Each account stakes 1: weight(1) = sqrt(1) = 1
        //
        // ── W = 20 | historicalReward = 0 | _totalVirtualPaid = 0 | Pool = 0
        // ── _paid: all 0
        for (uint256 i = 0; i < n; i++) {
            vm.prank(users[i]);
            staking.stake(1);
        }

        // historicalReward = 0 + (39 × 1s) = 39
        // Rate 39 chosen so 39 % 20 == 19 == N − 1
        vm.prank(manager);
        staking.setRewardRate(39);
        vm.warp(block.timestamp + 1);
        vm.prank(manager);
        staking.setRewardRate(0);

        // ── W = 20 | historicalReward = 39 | _totalVirtualPaid = 0 | Pool = 39 + 0 = 39
        // ── _paid: all 0
        //
        // Per account: earned = _allocation(1, 20) = floor(39 × 1 / 20) = floor(1.95) = 1
        // Aggregate allocated = 20 × 1 = 20
        // Dust = Pool − allocated = 39 − 20 = 19 = N − 1
        int256 rhs = staking._harness_getTotalVirtualPaid() + SafeCast.toInt256(staking._harness_getHistoricalReward());
        int256 lhs = 0;
        for (uint256 i = 0; i < n; i++) {
            lhs += staking._harness_getPaid(users[i]) + SafeCast.toInt256(staking.earned(users[i]));
        }

        assertEq(rhs - lhs, int256(n - 1), "Truncation dust exceeds N - 1 expectation");
    }

    /// @notice Shows the unit contribution of ghost_truncationOps to invariant_TotalSupplyBoundedByRewardRate.
    /// @dev One weight-decrease op (unstake / removeEligibleAccount with staked balance) inflates _totalVirtualPaid
    ///      by 1 wei via mulDiv truncation, enabling a subsequent claimer to mint exactly 1 wei above
    ///      the authorised reward cap.
    ///
    ///      Notation: w = weight(balance) = sqrt(balance) for a single account.
    ///                W = _totalEligibleStakedWeight = Σ w for all eligible accounts.
    ///                Pool = historicalReward + _totalVirtualPaid.
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

        // Bob eligible, Alice ineligible (only Bob counts toward W).
        // weight(4) = sqrt(4) = 2, weight(9) = sqrt(9) = 3
        //
        // ── W = 3 | historicalReward = 0 | _totalVirtualPaid = 0 | Pool = 0
        // ── _paid: [Alice=0, Bob=0]
        vm.prank(manager);
        staking.addEligibleAccount(bob);
        vm.prank(alice);
        staking.stake(4);
        vm.prank(bob);
        staking.stake(9);

        // historicalReward = 0 + (10 × 1s) = 10
        //
        // ── W = 3 | historicalReward = 10 | _totalVirtualPaid = 0 | Pool = 10 + 0 = 10
        // ── _paid: [Alice=0, Bob=0]
        vm.prank(manager);
        staking.setRewardRate(10);
        vm.warp(block.timestamp + 1);
        vm.prank(manager);
        staking.setRewardRate(0);

        uint256 authorizedRewards = staking._harness_getHistoricalReward();

        assertEq(authorizedRewards, 10, "Authorized rewards should be 10");

        // Bob sole eligible (w=3, W=3):
        //   earned = _allocation(3, 3) = floor(10 × 3 / 3) = 10
        //   _paid[Bob] += 10. Mints 10 tokens.
        //
        // ── W = 3 | historicalReward = 10 | _totalVirtualPaid = 0 | Pool = 10
        // ── _paid: [Alice=0, Bob=10]
        vm.prank(bob);
        staking.claimRewards(bob);

        // addEligibleAccount(Alice): balance=4, weight(4)=2. _updateRewards(alice, 0, 2):
        //   virtualAmount = _allocation(2, 3) = floor(10 × 2 / 3) = floor(6.66) = 6
        //   _paid[Alice] += 6, _totalVirtualPaid += 6
        //
        // ── W = 5 | historicalReward = 10 | _totalVirtualPaid = 6 | Pool = 10 + 6 = 16
        // ── _paid: [Alice=6, Bob=10]
        vm.prank(manager);
        staking.addEligibleAccount(alice);

        // removeEligibleAccount(Bob): balance=9, weight(9)=3. _updateRewards(bob, 3, 0):
        //   virtualAmount = _allocation(3, 5) = floor(16 × 3 / 5) = floor(9.6) = 9
        //   (exact 9.6, floor loses 0.6 — this is the truncation op)
        //   _paid[Bob] -= 9 → 10 - 9 = 1
        //   _totalVirtualPaid -= 9 → 6 - 9 = -3
        //
        // ── W = 2 | historicalReward = 10 | _totalVirtualPaid = -3 | Pool = 10 + (-3) = 7
        // ── _paid: [Alice=6, Bob=1]
        vm.prank(manager);
        staking.removeEligibleAccount(bob);

        assertEq(token.balanceOf(alice), 0, "Alice should have no tokens before claim");

        // Alice sole eligible (w=2, W=2):
        //   earned = _allocation(2, 2) - _paid[Alice] = floor(7 × 2 / 2) - 6 = 7 - 6 = 1
        //   Mints 1 token — but only 10 were authorized. This 1 is unbacked.
        //
        // ── _paid: [Alice=7, Bob=1]
        vm.prank(alice);
        staking.claimRewards(alice);

        assertEq(token.balanceOf(alice), 1, "Alice should have 1 token after claiming abandoned dust");

        uint256 totalMinted = token.balanceOf(alice) + token.balanceOf(bob);

        assertGt(totalMinted, authorizedRewards, "Protocol minted unbacked tokens");
        assertEq(totalMinted, 11, "Printer failed to extract exactly 1 wei over cap");
    }

    /// @notice 18-decimal regression: many partial unstakes on one account keep extra mint vs authorized
    ///         rewards bounded (same class as `invariant_TotalSupplyBoundedByRewardRate`).
    /// @dev Notation: w = weight(balance) = sqrt(balance).
    ///                Pool = historicalReward + _totalVirtualPaid.
    ///
    ///      Setup:  Alice (w≈1.73e9) and Bob (w≈3.16e10) eligible; balances ~3e18 and ~1000e18.
    ///              Reward rate = 10_000e18 / s for 10s.
    ///      Event:  Bob claims, then unstakes in 20 equal weight-steps to zero. Alice claims last.
    ///      Assert: (totalSupply increase) − expectedTotalRewards == 1.
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
            amounts[0] = 2999999998188649249;
            amounts[1] = 999999999965065000000;

            (token, staking) = _setupIsolatedStaking(users, amounts);
        }

        vm.startPrank(manager);
        staking.addEligibleAccount(alice);
        staking.addEligibleAccount(bob);
        vm.stopPrank();

        // Alice stakes ~3e18:   w_alice = sqrt(~3e18)    = 1732050807
        // Bob   stakes ~1000e18: w_bob  = sqrt(~1000e18) = 31622776601
        //
        // ── W = 33354827408 | historicalReward = 0 | _totalVirtualPaid = 0 | Pool = 0
        // ── _paid: [Alice=0, Bob=0]
        vm.prank(alice);
        staking.stake(2999999998188649249);
        vm.prank(bob);
        staking.stake(999999999965065000000);

        uint256 initialTotalSupply = token.totalSupply();
        uint256 expectedTotalRewards = 10_000 * 1e18 * 10;

        // historicalReward = 0 + (10_000e18 × 10s) = 1e23
        //
        // ── W = 33354827408 | historicalReward = 1e23 | _totalVirtualPaid = 0 | Pool = 1e23
        // ── _paid: [Alice=0, Bob=0]
        vm.startPrank(manager);
        staking.setRewardRate(10_000 * 1e18);
        vm.warp(block.timestamp + 10);
        staking.setRewardRate(0);
        vm.stopPrank();

        // earned(Bob) = floor(1e23 × 31622776601 / 33354827408) = 94807196014497812448102
        // _paid[Bob] += 94807196014497812448102
        //
        // ── W = 33354827408 | historicalReward = 1e23 | _totalVirtualPaid = 0 | Pool = 1e23
        // ── _paid: [Alice=0, Bob=94807196014497812448102]
        vm.prank(bob);
        staking.claimRewards(bob);

        // Bob unstakes in 20 equal weight-steps (weightStep = floor(31622776601 / 20) = 1581138830).
        // Each step: virtualAmount = floor(Pool × Δw / W), _paid[Bob] −= va, _totalVirtualPaid −= va.
        // The 20 floors telescope, stranding exactly 1 wei in _paid[Bob].
        //
        // ── W = 1732050807 | historicalReward = 1e23 | _totalVirtualPaid ≈ −9.48e22 | Pool ≈ 5.19e21
        // ── _paid: [Alice=0, Bob=1]
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

        // earned(Alice) = Pool ≈ 5.19e21 (sole eligible; w_alice / W = 1)
        vm.prank(alice);
        staking.claimRewards(alice);

        int256 globalDrift = int256(token.totalSupply() - initialTotalSupply) - int256(expectedTotalRewards);

        // earned(Bob) + earned(Alice) = 94807196014497812448102 + 5192803985502187551899 = 1e23 + 1
        assertEq(globalDrift, 1, "Bob's 20-step exit strands exactly 1 wei of phantom");
    }

    /// @notice Shows that ghost_truncationOps scales linearly with independent weight-decrease ops.
    /// @dev Notation: w = weight(balance) = sqrt(balance).
    ///                Pool = historicalReward + _totalVirtualPaid.
    ///
    ///      Setup:  20 sybil accounts; amounts[i] = ((i × 13) + 7) × 1e18, so weights vary across
    ///              the range w[0]=2645751311 to w[19]=15937377450. Only users[0] is eligible at start.
    ///              Reward rate = 1e18 / s for 10s.
    ///      Event:  users[0] claims the full pool (sole eligible). Each of the 19 relay iterations
    ///              adds the next sybil, removes the current one, and the new sole claimer claims.
    ///              addEligibleAccount computes va_add = floor(Pool × w_next / w_curr); the subsequent
    ///              removeEligibleAccount computes va_rem = floor(Pool_new × w_curr / W) which floors
    ///              exactly 1 wei short of the current pool, leaving 1 wei extra in the pool that the
    ///              next claimer extracts above their va_add baseline.
    ///      Assert: totalDrift == relayCount − 1 == 19 (exactly 1 wei per relay iteration).
    function test_SybilRelayDustPrinter_18Decimals() public {
        uint256 wad = 1e18;
        uint256 relayCount = 20;

        address[] memory users = new address[](relayCount);
        uint256[] memory amounts = new uint256[](relayCount);

        // amounts[i] = ((i × 13) + 7) × 1e18; w[0]=2645751311, w[1]=4472135954, ..., w[19]=15937377450
        for (uint256 i = 0; i < relayCount; i++) {
            users[i] = address(uint160(uint256(keccak256(abi.encode("sybil", i)))));
            amounts[i] = ((i * 13) + 7) * wad;
        }

        ZamaERC20 token;
        ProtocolStakingHarness staking;
        (token, staking) = _setupIsolatedStaking(users, amounts);

        // All 20 sybils stake; only users[0] is eligible.
        //
        // ── W = 2645751311 | historicalReward = 0 | _totalVirtualPaid = 0 | Pool = 0
        // ── _paid: all 0
        for (uint256 i = 0; i < relayCount; i++) {
            vm.prank(users[i]);
            staking.stake(amounts[i]);
        }

        vm.prank(manager);
        staking.addEligibleAccount(users[0]);

        uint256 initialTotalSupply = token.totalSupply();

        // historicalReward = 0 + (1e18 × 10s) = 10e18
        //
        // ── W = 2645751311 | historicalReward = 10e18 | _totalVirtualPaid = 0 | Pool = 10e18
        // ── _paid: all 0
        uint256 rate = 1 * wad;
        uint256 duration = 10;
        uint256 expectedTotalRewards = rate * duration;

        vm.prank(manager);
        staking.setRewardRate(rate);
        vm.warp(block.timestamp + duration);
        vm.prank(manager);
        staking.setRewardRate(0);

        // earned(users[0]) = floor(10e18 × w[0] / w[0]) = 10e18 (sole eligible)
        // _paid[0] += 10e18
        //
        // ── W = 2645751311 | historicalReward = 10e18 | _totalVirtualPaid = 0 | Pool = 10e18
        // ── _paid: [users[0]=10e18, rest=0]
        vm.prank(users[0]);
        staking.claimRewards(users[0]);

        // Each relay passes the sole-eligible slot to the next sybil and claims.
        //
        // Example (relay 0, wi=2645751311, wn=4472135954):
        //   addEligibleAccount(users[1]):  va_add = floor(10e18 × wn / wi) = 16903085091204930711
        //                                  _paid[1] += va_add, _totalVirtualPaid += va_add
        //   removeEligibleAccount(users[0]): va_rem = floor(Pool_new × wi / W) = 9999999999999999999
        //                                   _paid[0] −= va_rem, _totalVirtualPaid −= va_rem
        //   claimRewards(users[1]):        earned = Pool − _paid[1] = 1 (one stranded wei)
        //
        // The floor in va_rem is exactly 1 short of the current pool, so earned = 1 every iteration.
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

        // totalMinted = 10e18 + 19 × 1 = 10e18 + 19; totalDrift = 19 = relayCount − 1.
        assertEq(totalDrift, int256(relayCount - 1), "Each independent relay strands exactly 1 wei of phantom");
    }

    /// @notice Shows that ghost_dilutionOps (D) must scale with event count, not account count:
    ///         repeated dilution events on a single account compound phantom wei beyond 1.
    /// @dev Notation: w = weight(balance) = sqrt(balance).
    ///                W = _totalEligibleStakedWeight = Σ w for all eligible accounts.
    ///                Pool = historicalReward + _totalVirtualPaid.
    ///                D = ghost_dilutionOps, the count of weight-increase events by eligible accounts.
    ///
    ///      Setup:  Alice (w=1), Bob (w=9) eligible. 7 diluters (w=1 each) staged ineligible with no balance.
    ///              historicalReward = 29. Bob claims, locking _paid[Bob] = 26.
    ///      Event:  Each diluter is added as eligible then stakes 1 (a weight-increase op on a fresh account).
    ///              Each stake adds floor(Pool / W) to _totalVirtualPaid, shifting Bob's allocation floor down.
    ///
    ///      Trace (Pool / W / floor(Pool × 9 / W) / phantom = 26 − alloc):
    ///        Claim:    29 / 10 / 26 / 0
    ///        After D1: 31 / 11 / 25 / 1
    ///        After D2: 33 / 12 / 24 / 2
    ///        After D3: 35 / 13 / 24 / 2
    ///        After D4: 37 / 14 / 23 / 3
    ///        After D5: 39 / 15 / 23 / 3
    ///        After D6: 41 / 16 / 23 / 3
    ///        After D7: 43 / 17 / 22 / 4
    ///      Assert: bobPhantom == 4; Σ(_paid + earned) − (_totalVirtualPaid + historicalReward) == −1
    ///              (truncation dust of 5 across Alice and diluters partially cancels phantom of 4).
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

        // Alice stakes 1:  weight(1)  = sqrt(1)  = 1
        // Bob   stakes 81: weight(81) = sqrt(81) = 9
        //
        // ── W = 10 | historicalReward = 0 | _totalVirtualPaid = 0 | Pool = 0
        // ── _paid: [Alice=0, Bob=0]
        vm.prank(alice);
        staking.stake(1);
        vm.prank(bob);
        staking.stake(81);

        // historicalReward = 0 + (29 × 1s) = 29
        //
        // ── W = 10 | historicalReward = 29 | _totalVirtualPaid = 0 | Pool = 29 + 0 = 29
        // ── _paid: [Alice=0, Bob=0]
        vm.prank(manager);
        staking.setRewardRate(29);
        vm.warp(block.timestamp + 1);
        vm.prank(manager);
        staking.setRewardRate(0);

        // earned(Bob) = _allocation(9, 10) = floor(29 × 9 / 10) = floor(26.1) = 26
        // _paid[Bob] += 26
        //
        // ── W = 10 | historicalReward = 29 | _totalVirtualPaid = 0 | Pool = 29
        // ── _paid: [Alice=0, Bob=26]
        vm.prank(bob);
        staking.claimRewards(bob);
        assertEq(staking._harness_getPaid(bob), 26, "Bob _paid after claim");
        assertEq(staking.earned(bob), 0, "Bob earned 0 after claim");

        // Each diluter: addEligibleAccount (0 balance → no weight change), then stake(1) → weight = 1.
        // On stake: virtualAmount = floor(Pool × 1 / W), added to _paid[diluter] and _totalVirtualPaid.
        //
        // ── Step │ virtualAmt = floor(Pool/W) │  Pool  │  W │ Bob alloc = floor(Pool×9/W) │ phantom
        // ── ─────┼────────────────────────────┼────────┼────┼────────────────────────────┼────────
        // ── D1   │ floor(29 / 10) = 2         │ 29+2=31│ 11 │ floor(31×9/11) = 25         │ 26-25=1
        // ── D2   │ floor(31 / 11) = 2         │ 31+2=33│ 12 │ floor(33×9/12) = 24         │ 26-24=2
        // ── D3   │ floor(33 / 12) = 2         │ 33+2=35│ 13 │ floor(35×9/13) = 24         │ 26-24=2
        // ── D4   │ floor(35 / 13) = 2         │ 35+2=37│ 14 │ floor(37×9/14) = 23         │ 26-23=3
        // ── D5   │ floor(37 / 14) = 2         │ 37+2=39│ 15 │ floor(39×9/15) = 23         │ 26-23=3
        // ── D6   │ floor(39 / 15) = 2         │ 39+2=41│ 16 │ floor(41×9/16) = 23         │ 26-23=3
        // ── D7   │ floor(41 / 16) = 2         │ 41+2=43│ 17 │ floor(43×9/17) = 22         │ 26-22=4
        for (uint256 i = 0; i < numDiluters; i++) {
            vm.prank(manager);
            staking.addEligibleAccount(users[2 + i]);
            vm.prank(users[2 + i]);
            staking.stake(1);
        }

        // ── W = 17 | historicalReward = 29 | _totalVirtualPaid = 14 | Pool = 29 + 14 = 43
        // ── _paid: [Alice=0, Bob=26, D1..D7=2 each]
        //
        // Bob alloc = floor(43 × 9 / 17) = floor(22.76) = 22 < _paid(26) → earned(Bob) = 0
        assertEq(staking.earned(bob), 0, "Bob still in phantom zone after dilution");

        // phantom = _paid[Bob] − allocation = 26 − 22 = 4
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

        // Bob unstakes 81: _updateRewards(bob, 9, 0):
        //   virtualAmount = _allocation(9, 17) = floor(43 × 9 / 17) = floor(22.76) = 22
        //   _paid[Bob] -= 22 → 26 - 22 = 4 = bobPhantom (stranded)
        //   _totalVirtualPaid -= 22 → 14 - 22 = -8
        //
        // ── W = 8 | historicalReward = 29 | _totalVirtualPaid = -8 | Pool = 29 + (-8) = 21
        // ── _paid: [Alice=0, Bob=4, D1..D7=2 each]
        vm.prank(bob);
        staking.unstake(81);
        assertEq(uint256(staking._harness_getPaid(bob)), bobPhantom, "Residual _paid equals phantom");

        // lhs = Σ(_paid[i] + earned[i]),  rhs = _totalVirtualPaid + historicalReward
        // Phantom (4 wei) pulls lhs UP via Bob's stranded _paid.
        // Truncation dust pulls lhs DOWN via floor division in each account's earned().
        // Net: lhs − rhs = −1  (truncation of 5 dominates phantom of 4)
        {
            int256 rhs = staking._harness_getTotalVirtualPaid() +
                SafeCast.toInt256(staking._harness_getHistoricalReward());
            int256 lhs = 0;
            for (uint256 i = 0; i < totalUsers; i++) {
                lhs += staking._harness_getPaid(users[i]) + SafeCast.toInt256(staking.earned(users[i]));
            }
            assertEq(lhs - rhs, -1, "Net divergence: truncation (5) vs phantom (4)");
        }
    }
}
