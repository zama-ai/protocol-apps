// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ZamaERC20} from "token/contracts/ZamaERC20.sol";
import {ProtocolStakingHarness} from "./harness/ProtocolStakingHarness.sol";
import {OperatorStakingHarness} from "./harness/OperatorStakingHarness.sol";
import {OperatorStakingHandler} from "./handlers/OperatorStakingHandler.sol";
import {OperatorRewarder} from "../../contracts/OperatorRewarder.sol";

// Invariant fuzz scaffold for OperatorStaking
contract OperatorStakingInvariantTest is Test {
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

        ProtocolStakingHarness protocolImpl = new ProtocolStakingHarness();
        bytes memory protocolInitData = abi.encodeWithSelector(
            protocolImpl.initialize.selector,
            "Staked ZAMA",
            "stZAMA",
            "1",
            address(zama),
            governor,
            manager,
            initialUnstakeCooldownPeriod,
            initialRewardRate
        );
        protocolStaking = ProtocolStakingHarness(address(new ERC1967Proxy(address(protocolImpl), protocolInitData)));

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

    /// @notice Proves that every pending redemption can be successfully claimed exactly at cooldown.
    function invariant_redeemAtExactCooldown() public {
        uint256 count = handler.getPendingRedeemsCount();
        if (count == 0) return;

        uint256 originalTimestamp = block.timestamp;
        uint256 donationBudget = handler.ghost_inflatedDepositCount() - handler.ghost_globalSponsoredDust();

        for (uint256 i = 0; i < count; i++) {
            (address controller, uint48 releaseTime) = handler.getPendingRedeem(i);

            if (releaseTime > originalTimestamp) {
                uint256 snapshotId = vm.snapshot();

                vm.warp(releaseTime);

                uint256 claimableShares = operatorStaking.maxRedeem(controller);
                (uint256 expectedAssets, uint256 availableAssets) = handler.getExpectedAssets(claimableShares);

                if (expectedAssets > availableAssets) {
                    uint256 shortfall = expectedAssets - availableAssets;
                    // Each iteration is isolated via snapshot/revertTo — deals from previous
                    // iterations are reverted, so each gets the full unspent budget independently.
                    if (shortfall <= donationBudget) {
                        uint256 currentBalance = zama.balanceOf(address(operatorStaking));
                        deal(address(zama), address(operatorStaking), currentBalance + shortfall);
                    }
                }

                uint256 balanceBefore = zama.balanceOf(controller);

                vm.prank(controller);
                uint256 assetsReturned = operatorStaking.redeem(claimableShares, controller, controller);

                uint256 actualTransfer = zama.balanceOf(controller) - balanceBefore;
                assertEq(actualTransfer, assetsReturned, "Invariant: Exact cooldown redeem did not transfer the expected amount");

                vm.revertTo(snapshotId);
                vm.warp(originalTimestamp);
            }
        }
    }

    /// @notice Ensures no user ever loses funds without slashing (Total Recoverable >= Deposited)
    function invariant_totalRecoverableValue() public view {
        uint256 actorCount = handler.actorsLength();

        for (uint256 i = 0; i < actorCount; i++) {
            address actor = handler.actorAt(i);

            // Acceptable loss is the sum of rounding errors from deposits and redeems
            // Each count represents 1 wei lost to truncation
            uint256 acceptableLoss = handler.ghost_actorRedeemCount(actor) + handler.ghost_actorDepositCount(actor);

            uint256 deposited = handler.ghost_deposited(actor);
            uint256 redeemed = handler.ghost_redeemed(actor);

            // Sum up all shares the user currently owns across all possible states
            uint256 liquidShares = operatorStaking.balanceOf(actor);
            uint256 pendingShares = operatorStaking.pendingRedeemRequest(actor);
            uint256 claimableShares = operatorStaking.claimableRedeemRequest(actor);

            uint256 totalShares = liquidShares + pendingShares + claimableShares;

            // Calculate the current underlying asset value of all combined shares
            uint256 currentValue = operatorStaking.previewRedeem(totalShares);

            // The core invariant: Past withdrawals + Current value >= Total historical deposits
            assertGe(
                redeemed + currentValue + acceptableLoss,
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
                uint208 amountToRedeem = SafeCast.toUint208(Math.min(initialBalance, type(uint208).max));
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

    /// @notice The sum of per-actor pending + claimable shares must equal totalSharesInRedemption.
    function invariant_redemptionQueueCompleteness() public view {
        uint256 actorCount = handler.actorsLength();
        uint256 sumSharesInRedemption;

        for (uint256 i = 0; i < actorCount; i++) {
            address actor = handler.actorAt(i);
            sumSharesInRedemption +=
                operatorStaking.pendingRedeemRequest(actor) +
                operatorStaking.claimableRedeemRequest(actor);
        }

        assertEq(
            sumSharesInRedemption,
            operatorStaking.totalSharesInRedemption(),
            "Invariant: Sum of per-actor redemption shares != totalSharesInRedemption"
        );
    }

    /// @notice Each controller's redeem-request checkpoint trace must have non-decreasing
    /// timestamps and non-decreasing cumulative share amounts.
    function invariant_unstakeQueueMonotonicity() public view {
        uint256 actorCount = handler.actorsLength();

        for (uint256 i = 0; i < actorCount; i++) {
            address actor = handler.actorAt(i);
            uint256 count = operatorStaking._harness_getRedeemRequestCheckpointCount(actor);
            if (count <= 1) continue;

            (uint48 prevKey, uint208 prevValue) = operatorStaking._harness_getRedeemRequestCheckpointAt(actor, 0);
            for (uint256 j = 1; j < count; j++) {
                (uint48 key, uint208 value) = operatorStaking._harness_getRedeemRequestCheckpointAt(actor, j);
                assertGe(key, prevKey, "Invariant: Checkpoint timestamps not monotonically non-decreasing");
                assertGe(value, prevValue, "Invariant: Checkpoint cumulative shares not monotonically non-decreasing");
                prevKey = key;
                prevValue = value;
            }
        }
    }

    /// @notice The contract's liquid asset balance plus queued ProtocolStaking releases must
    /// always cover the previewed payout for all in-flight redemption shares.
    function invariant_liquidityBufferSufficiency() public view {
        uint256 liquidBalance = zama.balanceOf(address(operatorStaking));
        uint256 awaitingRelease = protocolStaking.awaitingRelease(address(operatorStaking));
        uint256 redemptionObligation = operatorStaking.previewRedeem(operatorStaking.totalSharesInRedemption());

        // Inflation is explicitly allowed up to 1 wei per deposit at inflated rate
        uint256 maxAcceptableDivergence = handler.ghost_inflatedDepositCount() - handler.ghost_globalSponsoredDust();

        assertGe(
            liquidBalance + awaitingRelease + maxAcceptableDivergence,
            redemptionObligation,
            "Invariant: Vault liquid balance + awaiting release is less than redemption obligation"
        );
    }

    /// @dev Helper to quickly spin up an isolated protocol instance with specific token distributions
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

    /// @dev Helper to quickly spin up an isolated OperatorStaking instance connected to an isolated ProtocolStaking
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
            (
                "Operator Staked ZAMA",
                "opstZAMA",
                _protocolStaking,
                address(this), // beneficiary
                10000, // initialMaxFeeBasisPoints
                0 // initialFeeBasisPoints
            )
        );
        _operatorStaking = OperatorStakingHarness(address(new ERC1967Proxy(address(operatorImpl), operatorInitData)));

        vm.prank(manager);
        _protocolStaking.addEligibleAccount(address(_operatorStaking));

        for (uint256 i = 0; i < users.length; i++) {
            vm.prank(users[i]);
            token.approve(address(_operatorStaking), type(uint256).max);
        }
    }

    /// @notice Demonstrates the exact sequence described in `donate()`:
    ///   1. Alice has an in-flight redemption.
    ///   2. Bob donates directly, inflating `totalAssets` without minting shares.
    ///   3. `stakeExcess` sweeps the donation, leaving the vault with exactly
    ///      enough liquid assets to cover Alice's now-inflated payout.
    ///   4. Charlie deposits at the elevated exchange rate. ERC4626 floor-rounding
    ///      truncates his shares by 0.1, leaking ~1.25 tokens of value into the pool.
    ///   5. Alice's `previewRedeem` rises by 1.25 tokens but the vault has no new
    ///      liquidity to cover it leading to `ERC20InsufficientBalance` on withdrawal.
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

        // Alice deposits 1 wei for 100 shares (decimalsOffset = 2 means 100 virtual shares).
        // Her 1 wei is immediately staked into ProtocolStaking; vault liquid = 0.
        vm.prank(alice);
        _opStaking.deposit(1, alice);

        // Alice requests to redeem all 100 shares.
        // requestRedeem computes previewRedeem(100) = 1 wei at the current baseline rate
        // and queues that 1 wei for unstaking from ProtocolStaking.
        // _burn reduces totalSupply to 0; sharesInRedemption = 100.
        vm.prank(alice);
        _opStaking.requestRedeem(100, alice, alice);

        // Bob donates 10,000 tokens directly (bypasses deposit/mint).
        // totalAssets rises to 10_000e18 + 1 without any new shares being minted.
        // Per-share value (previewRedeem) inflates dramatically while Alice's redemption
        // is already in-flight.
        vm.prank(bob);
        _token.transfer(address(_opStaking), 10_000e18);

        // stakeExcess stakes the donation back into ProtocolStaking, leaving exactly
        // enough liquid assets to honour Alice's now-inflated payout. ProtocolStaking had 10_000e18 + 1 wei.
        // stakeExcess tells it to unstake 5000e18 - 1 wei. The remaining staked liquid balance is:
        // 10_000e18 + 1 wei minus 5000e18 - 1 wei = 5000e18 + 2 wei.
        _opStaking.stakeExcess();

        uint256 payoutAfterDonation = _opStaking.previewRedeem(100);
        assertEq(_token.balanceOf(address(_opStaking)), payoutAfterDonation, "stakeExcess sweep failed");

        // Charlie deposits 10_005e18 at the inflated exchange rate.
        // _convertToShares: 10_005e18 * 200 / (10_000e18 + 2) ≈ 200.1 → floor = 200 shares.
        // The 0.1 truncated shares (~5 tokens) inflate the pool value for all 400 shares
        // (200 supply + 100 redemption + 100 virtual). Alice's 100 pending shares capture
        // 100/400 = 25% of this truncation (+1.25 tokens).
        // Charlie's tokens are immediately staked by _deposit(), so the vault gains no liquidity.
        vm.prank(charlie);
        _opStaking.deposit(10_005e18, charlie);

        uint256 payoutAfterDeposit = _opStaking.previewRedeem(100);
        assertGt(payoutAfterDeposit, payoutAfterDonation, "Truncation did not inflate Alice's payout");

        // Confirm the vault is now insolvent: payout owed exceeds liquid assets on hand.
        uint256 liquidBalance = _token.balanceOf(address(_opStaking));
        assertGt(payoutAfterDeposit, liquidBalance, "Expected vault insolvency");

        // Warp past cooldown so Alice can claim.
        vm.warp(block.timestamp + MAX_UNSTAKE_COOLDOWN_PERIOD + 1);

        // Alice's withdrawal reverts: previewRedeem(100) = 5001.25e18 but
        // vault liquid = 5000e18 + 2
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
