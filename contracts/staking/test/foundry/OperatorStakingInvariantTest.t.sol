// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/* solhint-disable func-name-mixedcase */ // Foundry discovers invariant tests by invariant_* prefix

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Test, console} from "forge-std/Test.sol";
import {ZamaERC20} from "token/contracts/ZamaERC20.sol";
import {OperatorRewarder} from "./../../contracts/OperatorRewarder.sol";
import {OperatorStakingHandler} from "./handlers/OperatorStakingHandler.sol";
import {OperatorStakingHarness} from "./harness/OperatorStakingHarness.sol";
import {ProtocolStakingHarness} from "./harness/ProtocolStakingHarness.sol";

/// @title OperatorStakingInvariantTest
/// @notice Invariant fuzzing suite for OperatorStaking. Exercises deposit, redeem,
///         donate, stakeExcess, and reward paths through a randomized handler.
contract OperatorStakingInvariantTest is Test {
    // -------------------------------------------------------------------
    //  State
    // -------------------------------------------------------------------

    ProtocolStakingHarness internal protocolStaking;
    OperatorStakingHarness internal operatorStaking;
    ZamaERC20 internal zama;
    OperatorStakingHandler internal handler;

    address internal governor = makeAddr("governor");
    address internal manager = makeAddr("manager");
    address internal admin = makeAddr("admin");
    address internal beneficiary = makeAddr("beneficiary");

    uint256 internal constant MIN_ACTOR_COUNT = 5;
    uint256 internal constant MAX_ACTOR_COUNT = 20;

    uint256 internal constant MIN_INITIAL_DISTRIBUTION = 1e18;
    uint256 internal constant MAX_INITIAL_DISTRIBUTION = 1e30;

    uint48 internal constant MIN_UNSTAKE_COOLDOWN_PERIOD = 1 seconds;
    uint48 internal constant MAX_UNSTAKE_COOLDOWN_PERIOD = 365 days;

    uint256 internal constant MIN_REWARD_RATE = 0;
    uint256 internal constant MAX_REWARD_RATE = 1e24;

    uint16 internal constant INITIAL_MAX_FEE_BPS = 10_000;
    uint16 internal constant INITIAL_FEE_BPS = 0;

    // -------------------------------------------------------------------
    //  Setup
    // -------------------------------------------------------------------

    function setUp() public {
        uint256 initialDistribution = vm.randomUint(MIN_INITIAL_DISTRIBUTION, MAX_INITIAL_DISTRIBUTION);
        uint48 cooldown = uint48(vm.randomUint(MIN_UNSTAKE_COOLDOWN_PERIOD, MAX_UNSTAKE_COOLDOWN_PERIOD));
        uint256 rewardRate = vm.randomUint(MIN_REWARD_RATE, MAX_REWARD_RATE);
        uint256 actorCount = vm.randomUint(MIN_ACTOR_COUNT, MAX_ACTOR_COUNT);

        address[] memory actorsList = new address[](actorCount);
        uint256[] memory actorPrivateKeys = new uint256[](actorCount);
        for (uint256 i = 0; i < actorCount; i++) {
            (address addr, uint256 pk) = makeAddrAndKey(string(abi.encodePacked("Actor", vm.toString(i))));
            actorsList[i] = addr;
            actorPrivateKeys[i] = pk;
        }

        // Mint equal distributions to all actors.
        address[] memory receivers = new address[](actorCount);
        uint256[] memory amounts = new uint256[](actorCount);
        for (uint256 i = 0; i < actorCount; i++) {
            receivers[i] = actorsList[i];
            amounts[i] = initialDistribution;
        }
        zama = new ZamaERC20("Zama", "ZAMA", receivers, amounts, admin);

        // Deploy ProtocolStaking.
        ProtocolStakingHarness protocolImpl = new ProtocolStakingHarness();
        bytes memory protocolInitData = abi.encodeWithSelector(
            protocolImpl.initialize.selector,
            "Staked ZAMA",
            "stZAMA",
            "1",
            address(zama),
            governor,
            manager,
            cooldown,
            rewardRate
        );
        protocolStaking = ProtocolStakingHarness(address(new ERC1967Proxy(address(protocolImpl), protocolInitData)));

        // Deploy OperatorStaking.
        OperatorStakingHarness operatorImpl = new OperatorStakingHarness();
        bytes memory operatorInitData = abi.encodeWithSelector(
            operatorImpl.initialize.selector,
            "Operator Staked ZAMA",
            "opstZAMA",
            address(protocolStaking),
            beneficiary,
            INITIAL_MAX_FEE_BPS,
            INITIAL_FEE_BPS
        );
        operatorStaking = OperatorStakingHarness(address(new ERC1967Proxy(address(operatorImpl), operatorInitData)));

        // Grant minter role and register operator staking.
        vm.startPrank(admin);
        zama.grantRole(zama.MINTER_ROLE(), address(protocolStaking));
        vm.stopPrank();

        vm.prank(manager);
        protocolStaking.addEligibleAccount(address(operatorStaking));

        // Pre-approve all actors.
        for (uint256 i = 0; i < actorCount; i++) {
            vm.prank(actorsList[i]);
            zama.approve(address(operatorStaking), type(uint256).max);
        }

        handler = new OperatorStakingHandler(operatorStaking, zama, protocolStaking, actorsList, actorPrivateKeys);
        targetContract(address(handler));
        for (uint256 i = 0; i < actorCount; i++) {
            targetSender(actorsList[i]);
        }
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = handler.assertRedeemRevertsForDust.selector;
        excludeSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // -------------------------------------------------------------------
    //  Invariants
    // -------------------------------------------------------------------

    /// @notice Every pending redemption can be claimed at its exact cooldown timestamp.
    ///         Each iteration is isolated via snapshot/revertTo, so each gets the full
    ///         unspent tolerance budget independently.
    ///
    ///         When a truncation-leak shortfall exists within the tolerance budget, the
    ///         invariant asserts the shortfall is bounded rather than executing the redeem.
    function invariant_redeemAtExactCooldown() public {
        uint256 count = handler.getPendingRedeemsCount();
        if (count == 0) return;

        uint256 originalTimestamp = block.timestamp;

        for (uint256 i = 0; i < count; i++) {
            (address controller, uint48 releaseTime) = handler.getPendingRedeem(i);
            if (releaseTime <= originalTimestamp) continue;

            uint256 snapshotId = vm.snapshot();
            vm.warp(releaseTime);

            uint256 claimableShares = operatorStaking.maxRedeem(controller);
            (uint256 expectedAssets, uint256 availableAssets) = handler.getExpectedAssets(claimableShares);

            if (expectedAssets > availableAssets) {
                // Shortfall exists — assert it will revert with ERC20InsufficientBalance and is within the tolerance budget.
                bool reverted = handler.assertRedeemRevertsForDust(
                    controller,
                    claimableShares,
                    expectedAssets,
                    availableAssets
                );
                assertTrue(reverted, "Invariant: redeem shortfall exceeds tolerance budget");
            } else {
                // No shortfall — execute the redeem and verify the transfer.
                uint256 balanceBefore = zama.balanceOf(controller);

                vm.prank(controller);
                uint256 assetsReturned = operatorStaking.redeem(claimableShares, controller, controller);

                uint256 actualTransfer = zama.balanceOf(controller) - balanceBefore;
                assertEq(actualTransfer, assetsReturned, "Invariant: exact-cooldown redeem transfer mismatch");
            }

            vm.revertTo(snapshotId);
            vm.warp(originalTimestamp);
        }
    }

    /// @notice No user ever loses funds without slashing: recoverable value >= deposited.
    function invariant_totalRecoverableValue() public view {
        uint256 actorCount = handler.actorsLength();

        for (uint256 i = 0; i < actorCount; i++) {
            address actor = handler.actorAt(i);

            // Each deposit and redeem incurs up to 1 wei of floor-rounding loss.
            uint256 acceptableLoss = handler.ghost_actorRedeemCount(actor) + handler.ghost_actorDepositCount(actor);

            uint256 deposited = handler.ghost_deposited(actor);
            uint256 redeemed = handler.ghost_redeemed(actor);

            uint256 totalShares = operatorStaking.balanceOf(actor) +
                operatorStaking.pendingRedeemRequest(actor) +
                operatorStaking.claimableRedeemRequest(actor);
            uint256 currentValue = operatorStaking.previewRedeem(totalShares);

            assertGe(redeemed + currentValue + acceptableLoss, deposited, "Invariant: recoverable value < deposited");
        }
    }

    /// @notice Any account with a balance can always request a redemption, and the
    ///         share balance decreases by exactly the requested amount.
    function invariant_canAlwaysRequestRedeem() public {
        uint256 actorCount = handler.actorsLength();

        for (uint256 i = 0; i < actorCount; i++) {
            address actor = handler.actorAt(i);
            uint256 balance = operatorStaking.balanceOf(actor);
            if (balance == 0) continue;

            uint208 amount = SafeCast.toUint208(Math.min(balance, type(uint208).max));

            vm.prank(actor);
            operatorStaking.requestRedeem(amount, actor, actor);

            assertEq(
                balance - operatorStaking.balanceOf(actor),
                amount,
                "Invariant: requestRedeem balance delta != requested"
            );
        }
    }

    /// @notice Sum of per-actor (pending + claimable) shares == totalSharesInRedemption.
    function invariant_redemptionQueueCompleteness() public view {
        uint256 actorCount = handler.actorsLength();
        uint256 sum;

        for (uint256 i = 0; i < actorCount; i++) {
            address actor = handler.actorAt(i);
            sum += operatorStaking.pendingRedeemRequest(actor) + operatorStaking.claimableRedeemRequest(actor);
        }

        assertEq(sum, operatorStaking.totalSharesInRedemption(), "Invariant: redemption share sum mismatch");
    }

    /// @notice Checkpoint traces for each controller must have non-decreasing timestamps
    ///         and non-decreasing cumulative share amounts.
    function invariant_unstakeQueueMonotonicity() public view {
        uint256 actorCount = handler.actorsLength();

        for (uint256 i = 0; i < actorCount; i++) {
            address actor = handler.actorAt(i);
            uint256 count = operatorStaking._harness_getRedeemRequestCheckpointCount(actor);
            if (count <= 1) continue;

            (uint48 prevKey, uint208 prevValue) = operatorStaking._harness_getRedeemRequestCheckpointAt(actor, 0);
            for (uint256 j = 1; j < count; j++) {
                (uint48 key, uint208 value) = operatorStaking._harness_getRedeemRequestCheckpointAt(actor, j);
                assertGe(key, prevKey, "Invariant: checkpoint timestamps not monotonic");
                assertGe(value, prevValue, "Invariant: checkpoint shares not monotonic");
                prevKey = key;
                prevValue = value;
            }
        }
    }

    /// @notice Liquid balance + awaiting release must cover all in-flight redemption payouts,
    ///         within the tolerance budget (1 wei per inflated deposit, minus already-spent dust).
    function invariant_liquidityBufferSufficiency() public view {
        uint256 liquidBalance = zama.balanceOf(address(operatorStaking));
        uint256 awaitingRelease = protocolStaking.awaitingRelease(address(operatorStaking));
        uint256 obligation = operatorStaking.previewRedeem(operatorStaking.totalSharesInRedemption());

        uint256 tolerance = handler.ghost_inflatedDepositCount() - handler.ghost_globalSponsoredDust();

        assertGe(
            liquidBalance + awaitingRelease + tolerance,
            obligation,
            "Invariant: liquidity buffer insufficient for redemption obligation"
        );
    }

    /// @notice Two consecutive preview conversions can only lose value, never create it.
    ///         The loss is bounded by S/A (the exchange rate, shares per asset).
    ///
    ///   Derivation: previewRedeem(x) = floor(x·A/S) = x·A/S - ε where ε ∈ [0,1).
    ///   Then previewDeposit(floor(x·A/S)) = floor((x·A/S - ε)·S/A) = floor(x - ε·S/A).
    ///   Since ε < 1, the loss is strictly less than S/A. At a 100:1 exchange rate this
    ///   allows losses up to 99 shares per round-trip — the bound is loose when the rate
    ///   diverges from 1:1, but it is the tightest provable general bound.
    function invariant_sharesConversionRoundTrip() public view {
        uint256 actorCount = handler.actorsLength();

        // ceil(S/A) is the upper bound on round-trip loss.
        // Loss = floor(ε·S/A) + 1 when frac(ε·S/A) > 0, where ε ∈ [0,1).
        // This reaches floor(S/A) + 1 = ceil(S/A) when S/A is non-integer and ε is close to 1.
        uint256 s = operatorStaking.totalSupply() + operatorStaking.totalSharesInRedemption() + 100;
        uint256 a = operatorStaking.totalAssets() + 1;
        uint256 roundTripTolerance = (s + a - 1) / a; // ceil(S/A)

        for (uint256 i = 0; i < actorCount; i++) {
            address actor = handler.actorAt(i);

            uint256 totalShares = operatorStaking.balanceOf(actor) +
                operatorStaking.pendingRedeemRequest(actor) +
                operatorStaking.claimableRedeemRequest(actor);
            if (totalShares == 0) continue;

            // shares -> assets -> shares
            uint256 assets = operatorStaking.previewRedeem(totalShares);
            uint256 sharesBack = operatorStaking.previewDeposit(assets);
            assertLe(sharesBack, totalShares, "Invariant: previewDeposit(previewRedeem(x)) > x");
            assertApproxEqAbs(
                sharesBack,
                totalShares,
                roundTripTolerance,
                "Invariant: previewDeposit(previewRedeem(x)) loss exceeds S/A"
            );

            // assets -> shares -> assets
            if (assets == 0) continue;
            uint256 sharesFromAssets = operatorStaking.previewDeposit(assets);
            uint256 assetsBack = operatorStaking.previewRedeem(sharesFromAssets);
            assertLe(assetsBack, assets, "Invariant: previewRedeem(previewDeposit(x)) > x");
            assertApproxEqAbs(
                assetsBack,
                assets,
                roundTripTolerance,
                "Invariant: previewRedeem(previewDeposit(x)) loss exceeds S/A"
            );
        }
    }

    // -------------------------------------------------------------------
    //  Isolated test helpers
    // -------------------------------------------------------------------

    function _setupIsolatedStaking(
        address[] memory users,
        uint256[] memory amounts
    ) internal returns (ZamaERC20 token, ProtocolStakingHarness _staking) {
        token = new ZamaERC20("Zama", "ZAMA", users, amounts, address(this));

        ProtocolStakingHarness impl = new ProtocolStakingHarness();
        bytes memory initData = abi.encodeCall(
            impl.initialize,
            ("Staked ZAMA", "stZAMA", "1", address(token), address(this), manager, 1 days, 0)
        );
        _staking = ProtocolStakingHarness(address(new ERC1967Proxy(address(impl), initData)));

        token.grantRole(token.MINTER_ROLE(), address(_staking));
        for (uint256 i = 0; i < users.length; i++) {
            vm.prank(users[i]);
            token.approve(address(_staking), type(uint256).max);
        }
    }

    function _setupIsolatedOperatorStaking(
        address[] memory users,
        uint256[] memory amounts
    )
        internal
        returns (ZamaERC20 token, ProtocolStakingHarness _protocolStaking, OperatorStakingHarness _operatorStaking)
    {
        (token, _protocolStaking) = _setupIsolatedStaking(users, amounts);

        OperatorStakingHarness operatorImpl = new OperatorStakingHarness();
        bytes memory operatorInitData = abi.encodeCall(
            operatorImpl.initialize,
            ("Operator Staked ZAMA", "opstZAMA", _protocolStaking, address(this), 10000, 0)
        );
        _operatorStaking = OperatorStakingHarness(address(new ERC1967Proxy(address(operatorImpl), operatorInitData)));

        vm.prank(manager);
        _protocolStaking.addEligibleAccount(address(_operatorStaking));

        for (uint256 i = 0; i < users.length; i++) {
            vm.prank(users[i]);
            token.approve(address(_operatorStaking), type(uint256).max);
        }
    }

    // -------------------------------------------------------------------
    //  Illiquidity bug reproductions
    // -------------------------------------------------------------------

    /// @notice Demonstrates the truncation leak illiquidity bug.
    ///
    ///   1. Alice deposits and requests redemption.
    ///   2. Bob donates tokens directly, inflating totalAssets without minting shares.
    ///   3. stakeExcess sweeps the donation, leaving exact redemption coverage.
    ///   4. Charlie deposits at the elevated rate. Floor-rounding in _convertToShares
    ///      truncates his shares, leaking ~1.25 tokens of value into the pool.
    ///   5. Alice's previewRedeem rises but the vault has no new liquidity —
    ///      her withdrawal reverts with ERC20InsufficientBalance.
    function test_IlliquidityBug_TruncationLeak() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address charlie = makeAddr("charlie");

        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1e18;
        amounts[1] = 10_000e18;
        amounts[2] = 15_000e18;

        (ZamaERC20 _token, , OperatorStakingHarness _opStaking) = _setupIsolatedOperatorStaking(users, amounts);

        // Alice deposits 1 wei -> 100 shares (DECIMALS_OFFSET=2).
        // Her 1 wei is immediately staked into ProtocolStaking; vault liquid = 0.
        vm.prank(alice);
        _opStaking.deposit(1, alice);

        // Alice queues all 100 shares. previewRedeem(100) = 1 at baseline.
        // _burn reduces totalSupply to 0; totalSharesInRedemption = 100.
        vm.prank(alice);
        _opStaking.requestRedeem(100, alice, alice);

        // Bob donates 10,000 tokens. totalAssets inflates without minting shares.
        vm.prank(bob);
        _token.transfer(address(_opStaking), 10_000e18);

        // stakeExcess sweeps donation into ProtocolStaking, leaving exact coverage.
        _opStaking.stakeExcess();

        uint256 payoutAfterDonation = _opStaking.previewRedeem(100);
        assertEq(_token.balanceOf(address(_opStaking)), payoutAfterDonation, "stakeExcess sweep failed");

        // Charlie deposits 10,005 tokens at the inflated rate.
        // _convertToShares: 10_005e18 * 200 / (10_000e18 + 2) = 200.1 -> floor = 200.
        // The 0.1 truncated shares (~5 tokens) inflate the pool for all 400 effective shares
        // (200 supply + 100 redemption + 100 virtual). Alice captures 100/400 = 25% (+1.25 tokens).
        // Charlie's tokens are immediately staked, so the vault gains no liquidity.
        vm.prank(charlie);
        _opStaking.deposit(10_005e18, charlie);

        uint256 payoutAfterDeposit = _opStaking.previewRedeem(100);
        assertGt(payoutAfterDeposit, payoutAfterDonation, "Truncation did not inflate Alice's payout");

        uint256 liquidBalance = _token.balanceOf(address(_opStaking));
        assertGt(payoutAfterDeposit, liquidBalance, "Expected vault insolvency");

        // Warp past cooldown. Alice's redeem reverts: previewRedeem(100) > vault liquid balance.
        vm.warp(block.timestamp + MAX_UNSTAKE_COOLDOWN_PERIOD + 1);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC20InsufficientBalance(address,uint256,uint256)")),
                address(_opStaking),
                5000e18 + 2,
                5001.25e18
            )
        );
        _opStaking.redeem(100, alice, alice);
    }
}
