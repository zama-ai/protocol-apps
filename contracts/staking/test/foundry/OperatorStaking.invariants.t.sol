// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/* solhint-disable func-name-mixedcase */ // Foundry discovers invariant tests by invariant_* prefix

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Test} from "forge-std/Test.sol";
import {ZamaERC20} from "token/contracts/ZamaERC20.sol";
import {OperatorStakingHandler} from "./handlers/OperatorStakingHandler.sol";
import {OperatorStakingHarness} from "./harness/OperatorStakingHarness.sol";
import {ProtocolStakingHarness} from "./harness/ProtocolStakingHarness.sol";

/// @title OperatorStakingInvariantTest
/// @notice Invariant fuzzing suite for OperatorStaking. Exercises deposit, redeem,
///         donate, stakeExcess, and reward paths through a handler.
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

    // Static setup constants — the fuzzer varies reward rate, cooldown, deposit/redeem amounts,
    // and fee parameters through handler actions.
    uint256 internal constant ACTOR_COUNT = 5;
    uint256 internal constant INITIAL_DISTRIBUTION = type(uint128).max;
    uint48 internal constant INITIAL_UNSTAKE_COOLDOWN_PERIOD = 7 days;
    uint256 internal constant INITIAL_REWARD_RATE = 1e18;

    uint16 internal constant INITIAL_MAX_FEE_BPS = 10_000;
    uint16 internal constant INITIAL_FEE_BPS = 0;

    // -------------------------------------------------------------------
    //  Setup
    // -------------------------------------------------------------------

    function setUp() public {
        uint256 actorCount = ACTOR_COUNT;
        uint256 initialDistribution = INITIAL_DISTRIBUTION;
        uint48 cooldown = INITIAL_UNSTAKE_COOLDOWN_PERIOD;
        uint256 rewardRate = INITIAL_REWARD_RATE;

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
        bytes memory protocolInitData = abi.encodeCall(
            protocolImpl.initialize,
            ("Staked ZAMA", "stZAMA", "1", address(zama), governor, manager, cooldown, rewardRate)
        );
        ERC1967Proxy protocolProxy = new ERC1967Proxy(address(protocolImpl), protocolInitData);
        protocolStaking = ProtocolStakingHarness(address(protocolProxy));

        // Deploy OperatorStaking.
        OperatorStakingHarness operatorImpl = new OperatorStakingHarness();
        bytes memory operatorInitData = abi.encodeCall(
            operatorImpl.initialize,
            ("Operator Staked ZAMA", "opstZAMA", protocolStaking, beneficiary, INITIAL_MAX_FEE_BPS, INITIAL_FEE_BPS)
        );
        ERC1967Proxy operatorProxy = new ERC1967Proxy(address(operatorImpl), operatorInitData);
        operatorStaking = OperatorStakingHarness(address(operatorProxy));

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
        selectors[0] = handler.assertRedeemRevertsWithinBudget.selector;
        excludeSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // -------------------------------------------------------------------
    //  Invariants
    // -------------------------------------------------------------------

    /// @notice Every pending redemption can be claimed at its exact cooldown timestamp.
    ///         Each iteration is isolated via snapshotState/revertToState, so each gets the full
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

            uint256 snapshotId = vm.snapshotState();
            vm.warp(releaseTime);

            uint256 claimableShares = operatorStaking.maxRedeem(controller);
            (uint256 expectedAssets, uint256 availableAssets) = handler.getExpectedAssets(claimableShares);

            if (expectedAssets > availableAssets) {
                // Shortfall exists — assert it will revert with ERC20InsufficientBalance and is within the tolerance budget.
                bool reverted = handler.assertRedeemRevertsWithinBudget(
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

            vm.revertToState(snapshotId);
            vm.warp(originalTimestamp);
        }
    }

    /// @notice No user ever loses funds without slashing: recoverable value >= deposited.
    function invariant_totalRecoverableValue() public view {
        uint256 actorCount = handler.actorsLength();

        for (uint256 i = 0; i < actorCount; i++) {
            address actor = handler.actorAt(i);

            uint256 acceptableLoss = handler.ghost_actorRedeemCount(actor) + handler.ghost_actorDepositBudget(actor);

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
    ///         within the tolerance budget (ceil(A/S) per deposit while redemptions are in-flight).
    function invariant_liquidityBufferSufficiency() public view {
        uint256 liquidBalance = zama.balanceOf(address(operatorStaking));
        uint256 awaitingRelease = protocolStaking.awaitingRelease(address(operatorStaking));
        uint256 obligation = operatorStaking.previewRedeem(operatorStaking.totalSharesInRedemption());

        uint256 tolerance = handler.ghost_globalRedemptionBudget();

        assertGe(
            liquidBalance + awaitingRelease + tolerance,
            obligation,
            "Invariant: liquidity buffer insufficient for redemption obligation"
        );
    }

    /// @notice Two consecutive preview conversions can only lose value, never create it.
    ///
    ///   shares -> assets -> shares (previewDeposit(previewRedeem(x))):
    ///     previewRedeem(x) = floor(x·A/S) = x·A/S - ε,  ε ∈ [0,1)
    ///     previewDeposit(above) = floor((x·A/S - ε)·S/A) = floor(x - ε·S/A)
    ///     loss = ceil(ε·S/A) ≤ ceil(S/A)
    ///
    ///   assets -> shares -> assets (previewRedeem(previewDeposit(x))):
    ///     previewDeposit(x) = floor(x·S/A) = x·S/A - ε',  ε' ∈ [0,1)
    ///     previewRedeem(above) = floor((x·S/A - ε')·A/S) = floor(x - ε'·A/S)
    ///     loss = ceil(ε'·A/S) ≤ ceil(A/S)
    function invariant_sharesConversionRoundTrip() public view {
        uint256 actorCount = handler.actorsLength();

        uint256 s = operatorStaking.totalSupply() + operatorStaking.totalSharesInRedemption() + 100;
        uint256 a = operatorStaking.totalAssets() + 1;
        uint256 toleranceSharesRoundTrip = (s + a - 1) / a; // ceil(S/A)
        uint256 toleranceAssetsRoundTrip = (a + s - 1) / s; // ceil(A/S)

        for (uint256 i = 0; i < actorCount; i++) {
            address actor = handler.actorAt(i);

            uint256 totalShares = operatorStaking.balanceOf(actor) +
                operatorStaking.pendingRedeemRequest(actor) +
                operatorStaking.claimableRedeemRequest(actor);
            if (totalShares == 0) continue;

            // shares -> assets -> shares: loss ≤ ceil(S/A)
            uint256 assets = operatorStaking.previewRedeem(totalShares);
            uint256 sharesBack = operatorStaking.previewDeposit(assets);
            assertLe(sharesBack, totalShares, "Invariant: previewDeposit(previewRedeem(x)) > x");
            assertApproxEqAbs(
                sharesBack,
                totalShares,
                toleranceSharesRoundTrip,
                "Invariant: previewDeposit(previewRedeem(x)) loss exceeds ceil(S/A)"
            );

            // assets -> shares -> assets: loss ≤ ceil(A/S)
            if (assets == 0) continue;
            uint256 sharesFromAssets = operatorStaking.previewDeposit(assets);
            uint256 assetsBack = operatorStaking.previewRedeem(sharesFromAssets);
            assertLe(assetsBack, assets, "Invariant: previewRedeem(previewDeposit(x)) > x");
            assertApproxEqAbs(
                assetsBack,
                assets,
                toleranceAssetsRoundTrip,
                "Invariant: previewRedeem(previewDeposit(x)) loss exceeds ceil(A/S)"
            );
        }
    }
}
