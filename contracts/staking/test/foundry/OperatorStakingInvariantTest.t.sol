// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ZamaERC20} from "token/contracts/ZamaERC20.sol";
import {ProtocolStaking} from "../../contracts/ProtocolStaking.sol";
import {OperatorStakingHarness} from "./harness/OperatorStakingHarness.sol";
import {OperatorStakingHandler} from "./handlers/OperatorStakingHandler.sol";

// Invariant fuzz scaffold for OperatorStaking
contract OperatorStakingInvariantTest is Test {
    ProtocolStaking internal protocolStaking;
    OperatorStakingHarness internal operatorStaking;
    ZamaERC20 internal zama;
    OperatorStakingHandler internal handler;

    address internal governor = makeAddr("governor");
    address internal manager = makeAddr("manager");
    address internal admin = makeAddr("admin");
    address internal beneficiary = makeAddr("beneficiary");

    uint256 internal constant MIN_ACTOR_COUNT = 5;
    uint256 internal constant MAX_ACTOR_COUNT = 20;

    uint256 internal constant MIN_INITIAL_DISTRIBUTION = 1 ether;
    uint256 internal constant MAX_INITIAL_DISTRIBUTION = 1_000_000_000 ether;

    uint48 internal constant MIN_UNSTAKE_COOLDOWN_PERIOD = 1 seconds;
    uint48 internal constant MAX_UNSTAKE_COOLDOWN_PERIOD = 365 days;

    uint256 internal constant MIN_REWARD_RATE = 0;
    uint256 internal constant MAX_REWARD_RATE = 1e24;

    uint16 internal constant INITIAL_MAX_FEE_BPS = 10_000;
    uint16 internal constant INITIAL_FEE_BPS = 0;

    function setUp() public {
        uint256 initialDistribution = uint256(vm.randomUint(MIN_INITIAL_DISTRIBUTION, MAX_INITIAL_DISTRIBUTION));
        uint48 initialUnstakeCooldownPeriod = uint48(
            vm.randomUint(MIN_UNSTAKE_COOLDOWN_PERIOD, MAX_UNSTAKE_COOLDOWN_PERIOD)
        );
        uint256 initialRewardRate = uint256(vm.randomUint(MIN_REWARD_RATE, MAX_REWARD_RATE));
        uint256 actorCount = uint256(vm.randomUint(MIN_ACTOR_COUNT, MAX_ACTOR_COUNT));

        address[] memory actorsList = new address[](actorCount);
        uint256[] memory actorPrivateKeys = new uint256[](actorCount);

        for (uint256 i = 0; i < actorCount; i++) {
            // Generate a deterministic wallet for each actor
            (address addr, uint256 pk) = makeAddrAndKey(string(abi.encodePacked("Actor", vm.toString(i))));
            actorsList[i] = addr;
            actorPrivateKeys[i] = pk;
        }

        // Deploy ZamaERC20, mint to all actors, admin is DEFAULT_ADMIN
        address[] memory receivers = new address[](actorCount);
        uint256[] memory amounts = new uint256[](actorCount);
        for (uint256 i = 0; i < actorCount; i++) {
            receivers[i] = actorsList[i];
            amounts[i] = initialDistribution;
        }

        zama = new ZamaERC20("Zama", "ZAMA", receivers, amounts, admin);

        ProtocolStaking protocolImpl = new ProtocolStaking();
        bytes memory protocolInitData = abi.encodeWithSelector(
            ProtocolStaking.initialize.selector,
            "Staked ZAMA",
            "stZAMA",
            "1",
            address(zama),
            governor,
            manager,
            initialUnstakeCooldownPeriod,
            initialRewardRate
        );
        protocolStaking = ProtocolStaking(address(new ERC1967Proxy(address(protocolImpl), protocolInitData)));

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

        vm.startPrank(admin);
        zama.grantRole(zama.MINTER_ROLE(), address(protocolStaking));
        vm.stopPrank();

        vm.prank(manager);
        protocolStaking.addEligibleAccount(address(operatorStaking));

        for (uint256 i = 0; i < actorCount; i++) {
            vm.prank(actorsList[i]);
            zama.approve(address(operatorStaking), type(uint256).max);
        }

        handler = new OperatorStakingHandler(operatorStaking, zama, protocolStaking, actorsList, actorPrivateKeys);
        targetContract(address(handler));

        for (uint256 i = 0; i < actorCount; i++) {
            targetSender(actorsList[i]);
        }
    }

    /// @notice Proves that every pending redemption can be successfully claimed the exact second its cooldown elapses.
    function invariant_redeemAtExactCooldown() public {
        uint256 count = handler.getPendingRedeemsCount();
        if (count == 0) return;

        uint256 originalTimestamp = block.timestamp;

        for (uint256 i = 0; i < count; i++) {
            (address controller, uint48 releaseTime) = handler.getPendingRedeem(i);

            if (releaseTime > originalTimestamp) {
                vm.warp(releaseTime);

                uint256 claimableShares = operatorStaking.claimableRedeemRequest(controller);

                // If a previous loop iteration already redeemed this user's pooled shares,
                // skip it to prevent InvalidShares() revert on 0.
                if (claimableShares == 0) {
                    vm.warp(originalTimestamp);
                    continue;
                }

                uint256 expectedAssets = operatorStaking.previewRedeem(claimableShares);

                vm.prank(controller);
                uint256 assetsReturned = operatorStaking.redeem(claimableShares, controller, controller);

                assertEq(assetsReturned, expectedAssets, "Invariant: Exact cooldown redeem returned wrong amount");
                vm.warp(originalTimestamp);
            }
        }
    }

    /// @notice Ensures no user ever loses funds without slashing (Total Recoverable >= Deposited)
    function invariant_totalRecoverableValue() public view {
        uint256 actorCount = handler.actorsLength();

        uint256 roundingTolerance = handler.getStakedFundRecoveryRoundingTolerance();

        for (uint256 i = 0; i < actorCount; i++) {
            address actor = handler.actorAt(i);

            uint256 deposited = handler.ghost_deposited(actor);
            uint256 redeemed = handler.ghost_redeemed(actor);

            // Sum up all shares the user currently owns across all possible states
            uint256 liquidShares = operatorStaking.balanceOf(actor);
            uint256 pendingShares = operatorStaking.pendingRedeemRequest(actor);
            uint256 claimableShares = operatorStaking.claimableRedeemRequest(actor);

            uint256 totalShares = liquidShares + pendingShares + claimableShares;

            // Calculate the current underlying asset value of all combined shares
            uint256 currentValue = operatorStaking.previewRedeem(totalShares);

            uint256 currentValueAdjusted = currentValue + roundingTolerance;

            // The core invariant: Past withdrawals + Current value >= Total historical deposits
            assertGe(
                redeemed + currentValueAdjusted,
                deposited,
                "Invariant: User recoverable value is less than deposited"
            );
        }
    }

    /// @notice Ensures that any account with a balance can always successfully request a redemption,
    /// and their share balance decreases by exactly the requested amount.
    function invariant_canAlwaysRequestRedeem() public {
        uint256 actorCount = handler.actorsLength();

        for (uint256 i = 0; i < actorCount; i++) {
            address actor = handler.actorAt(i);
            uint256 initialBalance = operatorStaking.balanceOf(actor);

            if (initialBalance > 0) {
                uint208 amountToRedeem = uint208(initialBalance);
                vm.prank(actor);
                operatorStaking.requestRedeem(amountToRedeem, actor, actor);

                uint256 finalBalance = operatorStaking.balanceOf(actor);

                assertEq(
                    initialBalance - finalBalance,
                    amountToRedeem,
                    "Invariant: requestRedeem did not decrease balance by exactly the requested amount"
                );
            }
        }
    }

    // Placeholder invariant while scaffold is being built out.
    function invariant_ScaffoldConfigured() public view {
        assertTrue(address(handler) != address(0), "handler should be configured");
        assertTrue(address(operatorStaking) != address(0), "operator staking should be deployed");
        assertTrue(address(protocolStaking) != address(0), "protocol staking should be deployed");
    }
}
