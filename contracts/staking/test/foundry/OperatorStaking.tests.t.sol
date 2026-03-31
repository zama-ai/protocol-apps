// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

/* solhint-disable func-name-mixedcase */

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {ZamaERC20} from "token/contracts/ZamaERC20.sol";
import {OperatorRewarder} from "./../../contracts/OperatorRewarder.sol";
import {OperatorStakingHarness} from "./harness/OperatorStakingHarness.sol";
import {ProtocolStakingHarness} from "./harness/ProtocolStakingHarness.sol";

/// @dev Bug-reproduction and tolerance-bound tests that justify constants used in the
///      OperatorStaking invariant/handler suite.
contract OperatorStakingTests is Test {
    address internal manager = makeAddr("manager");

    uint48 internal constant MAX_UNSTAKE_COOLDOWN_PERIOD = 365 days;

    // ─────────────────────────────────────────────────────────────────────────────
    // Setup helpers
    // ─────────────────────────────────────────────────────────────────────────────

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

    /// @dev Deploy contracts with rewardRate=1 and fee=0 for the phantom reward test.
    function _setupPhantomRewardContracts(
        address alice,
        address bob
    ) internal returns (ZamaERC20 _token, ProtocolStakingHarness _proto, OperatorStakingHarness _opStaking) {
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18;
        amounts[1] = 100e18;

        _token = new ZamaERC20("Zama", "ZAMA", users, amounts, address(this));

        ProtocolStakingHarness _protoImpl = new ProtocolStakingHarness();
        _proto = ProtocolStakingHarness(
            address(
                new ERC1967Proxy(
                    address(_protoImpl),
                    abi.encodeCall(
                        _protoImpl.initialize,
                        ("Staked ZAMA", "stZAMA", "1", address(_token), address(this), manager, 1 days, 1)
                    )
                )
            )
        );

        _token.grantRole(_token.MINTER_ROLE(), address(_proto));

        OperatorStakingHarness _opImpl = new OperatorStakingHarness();
        _opStaking = OperatorStakingHarness(
            address(
                new ERC1967Proxy(
                    address(_opImpl),
                    abi.encodeCall(
                        _opImpl.initialize,
                        ("Operator Staked ZAMA", "opstZAMA", _proto, address(this), 10000, 0)
                    )
                )
            )
        );

        vm.prank(manager);
        _proto.addEligibleAccount(address(_opStaking));

        vm.prank(alice);
        _token.approve(address(_opStaking), type(uint256).max);
        vm.prank(bob);
        _token.approve(address(_opStaking), type(uint256).max);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Bug reproductions
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Demonstrates the staking-side truncation leak illiquidity bug.
    ///
    ///   Root cause: a direct token transfer raises the per-share exchange rate. A
    ///   subsequent deposit at the elevated rate causes floor-rounding truncation in
    ///   _convertToShares, leaking value into the shared pool. In-flight redemptions
    ///   capture that leaked value via previewRedeem, creating an obligation the vault
    ///   cannot cover from liquid assets.
    ///
    ///   Sequence:
    ///   1. Alice deposits and requests redemption.
    ///   2. Bob donates tokens directly, inflating totalAssets without minting shares.
    ///   3. stakeExcess sweeps the donation, leaving exact redemption coverage.
    ///   4. Charlie deposits at the elevated rate. Floor-rounding in _convertToShares
    ///      truncates his shares, leaking ~1.25 tokens of value into the pool.
    ///   5. Alice's previewRedeem rises but the vault has no new liquidity —
    ///      her withdrawal reverts with ERC20InsufficientBalance.
    ///
    ///   Notation:
    ///      S        = opStaking.totalSupply()
    ///      R        = opStaking.totalSharesInRedemption()
    ///      pShares  = protocolStaking.balanceOf(opStaking)  (stZAMA, 1:1 with ZAMA)
    ///      awaiting = protocolStaking.awaitingRelease(opStaking)
    ///      liquid   = token.balanceOf(opStaking)
    ///      A        = totalAssets = liquid + pShares + awaiting
    ///      offset   = 10^DECIMALS_OFFSET = 100
    ///
    ///      previewRedeem(x)  = ⌊x · (A+1) / (S + R + offset)⌋
    ///      previewDeposit(x) = ⌊x · (S + R + offset) / (A+1)⌋
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

        // ── S=0 R=0 | pShares=0 awaiting=0 liquid=0 | A=0

        // Alice deposits 1 wei -> 100 shares (DECIMALS_OFFSET=2).
        // shares = ⌊1 · (0+0+100) / (0+1)⌋ = 100; 1 ZAMA staked 1:1 → pShares=1
        vm.prank(alice);
        _opStaking.deposit(1, alice);

        // ── S=100 R=0 | pShares=1 awaiting=0 liquid=0 | A=1
        // ── previewRedeem(100) = ⌊100·(1+1)/(100+0+100)⌋ = 1

        // Alice queues all 100 shares.
        // assetsToWithdraw = previewRedeem(100) − (liquid+awaiting) = 1 − 0 = 1
        // protocol.unstake(1) → pShares=0, awaiting=1 (locked until cooldown)
        vm.prank(alice);
        _opStaking.requestRedeem(100, alice, alice);

        // ── S=0 R=100 | pShares=0 awaiting=1 liquid=0 | A=1
        // ── previewRedeem(100) = ⌊100·(1+1)/(0+100+100)⌋ = 1

        // Bob donates 10,000 tokens. totalAssets inflates without minting shares.
        vm.prank(bob);
        _token.transfer(address(_opStaking), 10_000e18);

        // ── S=0 R=100 | pShares=0 awaiting=1 liquid=10_000e18 | A=10_000e18+1
        // ── previewRedeem(100) = ⌊100·(10_000e18+2)/200⌋ = 5000e18+1

        // stakeExcess: release() is no-op (cooldown not elapsed).
        // amountToRestake = 10_000e18 − (5000e18+1) = 5000e18−1 → protocol.stake(5000e18−1)
        _opStaking.stakeExcess();

        // ── S=0 R=100 | pShares=5000e18−1 awaiting=1 liquid=5000e18+1 | A=10_000e18+1
        // ── previewRedeem(100) = 5000e18+1 = liquid ✓ (exact buffer)

        uint256 payoutAfterDonation = _opStaking.previewRedeem(100);
        assertEq(_token.balanceOf(address(_opStaking)), payoutAfterDonation, "stakeExcess sweep failed");

        // Charlie deposits 10,005 tokens at the inflated rate.
        // shares = ⌊10_005e18 · 200 / (10_000e18+2)⌋ = 200  (exact 200.099… truncated)
        // Truncation leaks ≈5e18 of value into pool; Alice's R=100 out of 400 effective
        // shares (200 supply + 100 redemption + 100 virtual) captures 25% → +1.25e18 obligation.
        // Charlie's 10_005e18 are immediately staked; vault gains no liquidity.
        vm.prank(charlie);
        _opStaking.deposit(10_005e18, charlie);

        // ── S=200 R=100 | pShares=15_005e18−1 awaiting=1 liquid=5000e18+1 | A=20_005e18+1
        // ── previewRedeem(100) = ⌊100·(20_005e18+2)/400⌋ = 5001.25e18 > liquid (vault insolvent)

        uint256 payoutAfterDeposit = _opStaking.previewRedeem(100);
        assertGt(payoutAfterDeposit, payoutAfterDonation, "Truncation did not inflate Alice's payout");

        uint256 liquidBalance = _token.balanceOf(address(_opStaking));
        assertGt(payoutAfterDeposit, liquidBalance, "Expected vault insolvency");

        // Warp past cooldown.
        vm.warp(block.timestamp + MAX_UNSTAKE_COOLDOWN_PERIOD + 1);

        // Alice's redeem(100) enters _doTransferOut:
        // amount (5001.25e18) > liquid (5000e18+1) → release() releases awaiting=1 → liquid=5000e18+2
        // safeTransfer(alice, 5001.25e18) → ERC20InsufficientBalance(opStaking, 5000e18+2, 5001.25e18)
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

    /// @notice Demonstrates the rewarder-side phantom reward bug.
    ///
    ///   When two sequential deposits trigger transferHook's _allocation with floor
    ///   division, the sum of the individual virtualAmounts can be less than the
    ///   combined _allocation computed later in earned(). This creates a phantom
    ///   1 wei reward that the rewarder cannot pay, reverting with ERC20InsufficientBalance.
    ///
    ///   Root cause chain:
    ///     1. Alice deposits 5 wei → 500 shares (first deposit, transferHook returns early).
    ///     2. 7 seconds pass with rewardRate=1 → 7 reward tokens accrue.
    ///     3. Alice claims all 7 rewards → rewarder balance = 0.
    ///     4. Bob deposits 2 wei → 200 shares.
    ///        transferHook: V1 = floor(7 * 200 / 500) = floor(2.8) = 2.
    ///     5. Bob deposits 3 wei → 300 shares.
    ///        transferHook: V2 = floor((7+2) * 300 / 700) = floor(3.857) = 3.
    ///     6. earned(bob) = floor((7+5) * 500 / 1000) - (2+3) = 6 - 5 = 1.
    ///        But rewarder has 0 tokens and protocolStaking has 0 pending → revert.
    ///
    ///   Notation:
    ///      S           = opStaking.totalSupply()  (operator shares)
    ///      Pool        = historicalRewards + _totalVirtualPaid  (OperatorRewarder pool)
    ///      paid[x]     = rewarder._paid[x]        (virtual offset per account)
    ///      earned(x)   = ⌊Pool · shares(x) / S⌋ − paid[x]
    ///      protoEarned = proto.earned(opStaking)  (ZAMA pending collection from protocol)
    ///      rewarderBal = token.balanceOf(rewarder)
    ///
    ///   On each share mint, transferHook credits V = ⌊Pool · newShares / S_before⌋ to
    ///   paid[account] and raises _totalVirtualPaid by V, lifting Pool for all future earners.
    function test_PhantomRewardBug_RewarderInsolvency() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        (
            ZamaERC20 _token,
            ProtocolStakingHarness _proto,
            OperatorStakingHarness _opStaking
        ) = _setupPhantomRewardContracts(alice, bob);

        OperatorRewarder _rewarder = OperatorRewarder(_opStaking.rewarder());

        // ── S=0 | Pool=0 | paid[Alice]=0 paid[Bob]=0 | rewarderBal=0 protoEarned=0

        // Alice deposits 5 wei → 500 shares.
        // shares = ⌊5·(0+0+100)/(0+1)⌋ = 500; transferHook skips (totalSupply was 0, no pool to offset)
        vm.prank(alice);
        assertEq(_opStaking.deposit(5, alice), 500, "Alice should get 500 shares");

        // ── S=500 | Pool=0 | paid[Alice]=0 paid[Bob]=0 | rewarderBal=0 protoEarned=0

        // Warp 7 seconds → 7 reward tokens accrue at rewardRate=1.
        vm.warp(block.timestamp + 7);

        // ── S=500 | Pool=0 | paid[Alice]=0 paid[Bob]=0 | rewarderBal=0 protoEarned=7
        assertEq(_proto.earned(address(_opStaking)), 7, "7 rewards should accrue");

        // Alice claims all rewards: rewarder pulls 7 from protocol, pays Alice.
        // historicalRewards += 7 → Pool = 7; paid[Alice] = ⌊7·500/500⌋ = 7 (sole holder)
        assertEq(_rewarder.earned(alice), 7, "Alice earned 7");
        vm.prank(alice);
        _rewarder.claimRewards(alice);

        // ── S=500 | Pool=7 | paid[Alice]=7 paid[Bob]=0 | rewarderBal=0 protoEarned=0
        // ── earned(Alice) = ⌊7·500/500⌋ − 7 = 0
        assertEq(_token.balanceOf(address(_rewarder)), 0, "Rewarder should be empty");

        // Bob's first deposit: 2 wei → 200 shares.
        // transferHook(0→bob, 200): V1 = ⌊Pool · 200 / S⌋ = ⌊7·200/500⌋ = ⌊2.8⌋ = 2
        // paid[Bob] += 2, _totalVirtualPaid += 2 → Pool = 9
        vm.prank(bob);
        assertEq(_opStaking.deposit(2, bob), 200, "Bob first deposit: 200 shares");

        // ── S=700 | Pool=9 | paid[Alice]=7 paid[Bob]=2 | rewarderBal=0 protoEarned=0
        // ── earned(Bob) = ⌊9·200/700⌋ − 2 = ⌊2.571⌋ − 2 = 0

        // Bob's second deposit: 3 wei → 300 shares.
        // transferHook(0→bob, 300): V2 = ⌊Pool · 300 / S⌋ = ⌊9·300/700⌋ = ⌊3.857⌋ = 3
        // paid[Bob] += 3 → paid[Bob]=5, _totalVirtualPaid += 3 → Pool = 12
        vm.prank(bob);
        assertEq(_opStaking.deposit(3, bob), 300, "Bob second deposit: 300 shares");

        // ── S=1000 | Pool=12 | paid[Alice]=7 paid[Bob]=5 | rewarderBal=0 protoEarned=0
        // ── earned(Bob) = ⌊12·500/1000⌋ − 5 = 6 − 5 = 1  ← phantom wei

        // Bob has a phantom 1 wei earned despite no real reward accrual after his deposits.
        // rewarderBal=0 and protoEarned=0; rewarder cannot cover earned(Bob)=1.
        assertEq(_rewarder.earned(bob), 1, "Phantom: bob earned 1 despite no real reward accrual");
        assertEq(_token.balanceOf(address(_rewarder)), 0, "Rewarder has 0 tokens");
        assertEq(_proto.earned(address(_opStaking)), 0, "No pending protocol rewards");

        // Bob's claimRewards reverts: rewarder is insolvent by exactly 1 wei.
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC20InsufficientBalance(address,uint256,uint256)")),
                address(_rewarder),
                0,
                1
            )
        );
        vm.prank(bob);
        _rewarder.claimRewards(bob);
    }
}
