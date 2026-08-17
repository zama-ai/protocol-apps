// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {ERC20Mock} from "confidential-wrapper/mocks/ERC20Mock.sol";

import {ConfidentialWrapperTreasury} from "../../../src/msca/ConfidentialWrapperTreasury.sol";
import {BlocklistedUnderlyingMock} from "../../../src/msca/BlocklistedUnderlyingMock.sol";
import {TokenTransfer, TreasuryFixture} from "./TreasuryFixture.t.sol";

/**
 * @title TreasurySettlement
 * @notice The three token paths after migration: wrap, ERC-1363, finalizeUnwrap.
 * @dev Every test starts from the completed deployment. No-allowance cases are here too.
 */
abstract contract TreasurySettlement is TreasuryFixture {
    address internal alice;
    address internal bob;

    function setUp() public virtual override {
        super.setUp();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        _completeDeployment();
    }

    // ----- wrap() -----

    /// @notice Ordinary `wrap` deposits go straight to the treasury.
    function test_Wrap_DepositGoesStraightToTheTreasury() public {
        _wrap(alice, 4 * ONE);

        assertEq(underlying.balanceOf(address(treasury)), 4 * ONE, "treasury did not receive the deposit");
        assertEq(underlying.balanceOf(address(wrapper)), 0, "USDC rested at the wrapper");
        assertEq(_balance(alice), uint64(4 * ONE), "alice was not credited");
    }

    /// @notice One hop, depositor to treasury: the wrapper never holds the deposit.
    function test_Wrap_IsASingleHopAndNeverRestsAtTheWrapper() public {
        deal(address(underlying), alice, ONE);
        vm.prank(alice);
        underlying.approve(address(wrapper), ONE);

        _watchLogs();
        vm.prank(alice);
        wrapper.wrap(alice, ONE);
        TokenTransfer[] memory hops = _transfersOf(address(underlying));

        assertEq(hops.length, 1, "expected exactly one underlying transfer");
        assertEq(hops[0].from, alice, "transfer did not originate with the depositor");
        assertEq(hops[0].to, address(treasury), "transfer did not land at the treasury");
        assertEq(hops[0].value, ONE, "transfer moved the wrong amount");
    }

    /// @notice `inferredTotalSupply()` and `treasuryBalance()` track deposits as they arrive.
    function test_Wrap_ReserveViewsTrackTheTreasury() public {
        _wrap(alice, 3 * ONE);
        _wrap(bob, 2 * ONE);

        assertEq(wrapper.treasuryBalance(), 5 * ONE, "treasuryBalance does not match deposits");
        assertEq(wrapper.inferredTotalSupply(), 5 * ONE, "backing does not match deposits");
    }

    // ----- onTransferReceived() -----

    /// @notice The callback path forwards the deposit on to the treasury.
    function test_Erc1363_ForwardsTheDepositToTheTreasury() public {
        _wrapViaTransferAndCall(alice, 3 * ONE);

        assertEq(underlying.balanceOf(address(treasury)), 3 * ONE, "treasury did not receive the deposit");
        assertEq(underlying.balanceOf(address(wrapper)), 0, "the wrapper kept the remainder");
        assertEq(_balance(alice), uint64(3 * ONE), "alice was not credited");
    }

    /// @notice The callback delivers to the wrapper first, so this path cannot reach the treasury in one hop.
    function test_Erc1363_CostsOneExtraHop() public {
        deal(address(underlying), alice, ONE);

        _watchLogs();
        vm.prank(alice);
        underlying.transferAndCall(address(wrapper), ONE);
        TokenTransfer[] memory hops = _transfersOf(address(underlying));

        assertEq(hops.length, 2, "expected the deposit and the forward");
        assertEq(hops[0].from, alice, "first hop did not originate with the depositor");
        assertEq(hops[0].to, address(wrapper), "first hop did not land at the callback receiver");
        assertEq(hops[1].from, address(wrapper), "second hop did not originate with the wrapper");
        assertEq(hops[1].to, address(treasury), "second hop did not land at the treasury");
    }

    /// @notice With `rate() > 1` the dust is refunded and only the rounded remainder reaches the treasury.
    /// @dev Needs its own wrapper: the default underlying has 6 decimals, so `rate() == 1`.
    function test_Erc1363_RefundsDustThenForwardsTheRemainder() public {
        ERC20Mock coarse = new ERC20Mock("Dai", "DAI", 18);
        ConfidentialWrapperTreasury cWrapper = _newWrapperAtV3(IERC20(address(coarse)), bytes4(0), false);
        _migrate(cWrapper);
        assertEq(cWrapper.rate(), 1e12, "precondition: an 18-decimal underlying rounds to 1e12");

        uint256 dust = 7;
        uint256 amount = 3e12 + dust;
        deal(address(coarse), alice, amount);

        _watchLogs();
        vm.prank(alice);
        coarse.transferAndCall(address(cWrapper), amount);
        TokenTransfer[] memory hops = _transfersOf(address(coarse));

        assertEq(hops.length, 3, "expected deposit, refund and forward");
        assertEq(hops[1].to, alice, "the refund did not go back to the depositor");
        assertEq(hops[1].value, dust, "the refund was not the dust");
        assertEq(hops[2].to, address(treasury), "the remainder did not reach the treasury");
        assertEq(hops[2].value, 3e12, "the remainder was not the rounded amount");

        assertEq(coarse.balanceOf(address(cWrapper)), 0, "the wrapper kept something");
    }

    // ----- finalizeUnwrap() -----

    /// @notice Settlement pulls USDC from the treasury by allowance and pays the recipient.
    function test_FinalizeUnwrap_PullsFromTheTreasuryAndPaysTheRecipient() public {
        _wrap(alice, 5 * ONE);
        uint64 amount = uint64(2 * ONE);

        _finalizeUnwrap(_requestUnwrap(alice, alice, amount));

        assertEq(underlying.balanceOf(alice), amount, "recipient was not paid");
        assertEq(underlying.balanceOf(address(treasury)), 3 * ONE, "treasury was not debited");
        assertEq(underlying.balanceOf(address(wrapper)), 0, "the wrapper held underlying");
        assertEq(_balance(alice), uint64(3 * ONE), "cUSDC was not burnt");
    }

    /// @notice The payout is one hop, treasury to recipient.
    function test_FinalizeUnwrap_IsASingleHopFromTheTreasury() public {
        _wrap(alice, 5 * ONE);
        (bytes32 unwrapId, uint64 cleartext, bytes memory proof) = _pendingUnwrapOn(wrapper, alice, uint64(2 * ONE));

        _watchLogs();
        wrapper.finalizeUnwrap(unwrapId, cleartext, proof);
        TokenTransfer[] memory hops = _transfersOf(address(underlying));

        assertEq(hops.length, 1, "expected exactly one underlying transfer");
        assertEq(hops[0].from, address(treasury), "payout did not come from the treasury");
        assertEq(hops[0].to, alice, "payout did not reach the recipient");
    }

    /// @notice Settlement can pay a third party, and the money still comes from the treasury.
    function test_FinalizeUnwrap_PaysAThirdPartyRecipient() public {
        _wrap(alice, 5 * ONE);

        _finalizeUnwrap(_requestUnwrap(alice, bob, uint64(2 * ONE)));

        assertEq(underlying.balanceOf(bob), 2 * ONE, "third-party recipient was not paid");
        assertEq(underlying.balanceOf(address(treasury)), 3 * ONE, "treasury was not debited");
    }

    /// @notice An unlimited allowance is not consumed, so settlement never needs a re-grant.
    function test_FinalizeUnwrap_UnlimitedAllowanceDoesNotDecay() public {
        _wrap(alice, 5 * ONE);
        assertEq(underlying.allowance(address(treasury), address(wrapper)), type(uint256).max);

        _finalizeUnwrap(_requestUnwrap(alice, alice, uint64(2 * ONE)));

        assertEq(
            underlying.allowance(address(treasury), address(wrapper)),
            type(uint256).max,
            "an unlimited allowance should not decay"
        );
    }

    /// @notice A capped allowance is spent down instead.
    function test_FinalizeUnwrap_CappedAllowanceIsSpentDown() public {
        _grantWrapperAllowance(3 * ONE);
        _wrap(alice, 5 * ONE);

        _finalizeUnwrap(_requestUnwrap(alice, alice, uint64(2 * ONE)));

        assertEq(underlying.allowance(address(treasury), address(wrapper)), ONE, "allowance was not spent");
    }

    /// @notice Settlement fails closed without an allowance, and the request survives to settle once one is granted.
    function test_FinalizeUnwrap_RevertsWithoutAnAllowanceAndTheRequestSurvives() public {
        _grantWrapperAllowance(0);
        _wrap(alice, 5 * ONE);

        (bytes32 unwrapId, uint64 cleartext, bytes memory proof) = _pendingUnwrapOn(wrapper, alice, uint64(2 * ONE));

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(wrapper), 0, uint256(2 * ONE)
            )
        );
        wrapper.finalizeUnwrap(unwrapId, cleartext, proof);

        assertEq(underlying.balanceOf(alice), 0, "recipient was paid without an allowance");
        assertEq(underlying.balanceOf(address(treasury)), 5 * ONE, "treasury was debited without an allowance");

        _grantWrapperAllowance(type(uint256).max);
        wrapper.finalizeUnwrap(unwrapId, cleartext, proof);
        assertEq(underlying.balanceOf(alice), 2 * ONE, "the pending request could not be settled afterwards");
    }

    /// @notice Only the wrapper can spend the allowance.
    function test_Settlement_OnlyTheWrapperCanSpendTheAllowance() public {
        _wrap(alice, 5 * ONE);
        address thief = makeAddr("thief");

        vm.prank(thief);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, thief, 0, uint256(5 * ONE))
        );
        underlying.transferFrom(address(treasury), thief, 5 * ONE);

        assertEq(underlying.balanceOf(address(treasury)), 5 * ONE, "treasury was drained by a third party");
    }

    // ----- Underlying blocklist -----

    /// @notice Blocklisting the treasury halts wraps and freezes the reserve.
    function test_Blocklist_TreasuryIsASecondPointOfFailure() public {
        BlocklistedUnderlyingMock token = new BlocklistedUnderlyingMock();
        ConfidentialWrapperTreasury w = _newWrapperAtV3(IERC20(address(token)), bytes4(0), false);
        _migrate(w);
        _grantAllowance(IERC20(address(token)), address(w), type(uint256).max);

        _wrapOn(w, IERC20(address(token)), alice, 5 * ONE);
        assertEq(token.balanceOf(address(treasury)), 5 * ONE, "precondition: reserve at the treasury");

        (bytes32 unwrapId, uint64 cleartext, bytes memory proof) = _pendingUnwrapOn(w, alice, uint64(2 * ONE));

        token.setBlocklisted(address(treasury), true);

        deal(address(token), bob, ONE);
        vm.startPrank(bob);
        token.approve(address(w), ONE);
        vm.expectRevert(abi.encodeWithSelector(BlocklistedUnderlyingMock.Blocklisted.selector, address(treasury)));
        w.wrap(bob, ONE);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(BlocklistedUnderlyingMock.Blocklisted.selector, address(treasury)));
        w.finalizeUnwrap(unwrapId, cleartext, proof);

        assertEq(token.balanceOf(address(treasury)), 5 * ONE, "the reserve moved while blocklisted");
    }
}
