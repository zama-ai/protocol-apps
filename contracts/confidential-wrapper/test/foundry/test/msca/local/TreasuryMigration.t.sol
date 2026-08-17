// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ConfidentialWrapper} from "confidential-wrapper/ConfidentialWrapper.sol";

import {ConfidentialWrapperTreasury} from "../../../src/msca/ConfidentialWrapperTreasury.sol";
import {TreasuryFixture} from "./TreasuryFixture.t.sol";

/**
 * @title TreasuryMigration
 * @notice Upgrade to a treasury-backed wrapper, and the state it leaves.
 */
abstract contract TreasuryMigration is TreasuryFixture {
    address internal alice;
    address internal bob;

    function setUp() public virtual override {
        super.setUp();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    // ----- Final state -----

    /// @notice After migration the wrapper holds no underlying and `treasuryBalance()` matches the old reserve.
    function test_Migration_MovesTheEntireReserveToTheTreasury() public {
        _seedReserve();
        uint256 reserveBefore = underlying.balanceOf(address(wrapper));
        assertGt(reserveBefore, 0, "precondition: the wrapper should hold the reserve today");
        assertEq(underlying.balanceOf(address(treasury)), 0, "precondition: the treasury starts empty");

        _migrateToTreasury();

        assertEq(underlying.balanceOf(address(wrapper)), 0, "reserve still at the wrapper");
        assertEq(wrapper.treasuryBalance(), reserveBefore, "treasuryBalance does not match the old reserve");
        assertEq(underlying.balanceOf(address(treasury)), reserveBefore, "treasury did not receive the reserve");
    }

    /// @notice `treasury()` reports the account the reserve moved to.
    function test_Migration_SetsTheTreasuryAddress() public {
        _seedReserve();
        _migrateToTreasury();

        assertEq(wrapper.treasury(), address(treasury), "treasury() does not name the account");
    }

    /// @notice `inferredTotalSupply()` reads the treasury and the number does not move across the migration.
    function test_Migration_InferredTotalSupplyRepointsWithoutChangingValue() public {
        _seedReserve();
        uint256 supplyBefore = wrapper.inferredTotalSupply();

        _migrateToTreasury();

        assertEq(
            wrapper.inferredTotalSupply(),
            underlying.balanceOf(address(treasury)) / wrapper.rate(),
            "inferredTotalSupply is not reading the treasury"
        );
        assertEq(wrapper.inferredTotalSupply(), supplyBefore, "migration changed reported backing");
    }

    /// @notice Holders keep their cTokens: the migration touches the underlying only.
    function test_Migration_LeavesConfidentialBalancesUntouched() public {
        _seedReserve();
        uint64 aliceBefore = _balance(alice);
        uint64 bobBefore = _balance(bob);

        _migrateToTreasury();

        assertEq(_balance(alice), aliceBefore, "alice's cUSDC balance changed");
        assertEq(_balance(bob), bobBefore, "bob's cUSDC balance changed");
    }

    // ----- Upgrade pattern -----

    /// @notice `treasury()` is new surface: it reverts on the pinned implementation.
    function test_Migration_TreasuryViewsAreUnreachableBeforeTheUpgrade() public {
        (bool ok,) = address(wrapper).staticcall(abi.encodeCall(ConfidentialWrapperTreasury.treasury, ()));
        assertFalse(ok, "treasury() answered on the pinned implementation");

        _migrateToTreasury();

        (ok,) = address(wrapper).staticcall(abi.encodeCall(ConfidentialWrapperTreasury.treasury, ()));
        assertTrue(ok, "treasury() still unreachable after the upgrade");
    }

    /// @notice An upgrade that skips the initializer leaves a wrapper that cannot take a deposit.
    function test_Migration_UpgradingWithoutTheInitializerBricksDeposits() public {
        _seedReserve();

        ConfidentialWrapperTreasury impl = new ConfidentialWrapperTreasury();
        vm.prank(dao);
        wrapper.upgradeToAndCall(address(impl), "");

        assertEq(wrapper.treasury(), address(0), "treasury unexpectedly set");

        deal(address(underlying), alice, ONE);
        vm.startPrank(alice);
        underlying.approve(address(wrapper), ONE);
        vm.expectRevert(ConfidentialWrapperTreasury.InvalidTreasury.selector);
        wrapper.wrap(alice, ONE);
        vm.stopPrank();

        assertEq(underlying.balanceOf(address(wrapper)), _seededReserve(), "reserve moved on a bare upgrade");
    }

    /// @notice The treasury lives at the ERC-7201 slot derived here, not an imported constant.
    function test_Migration_TreasuryLivesInItsOwnErc7201Namespace() public {
        _seedReserve();
        _migrateToTreasury();

        bytes32 slot = keccak256(
            abi.encode(uint256(keccak256("fhevm_protocol.storage.ConfidentialWrapperTreasury")) - 1)
        ) & ~bytes32(uint256(0xff));

        assertEq(
            address(uint160(uint256(vm.load(address(wrapper), slot)))),
            address(treasury),
            "the treasury is not stored at the derived namespace slot"
        );
    }

    /// @notice The migration cannot run twice.
    function test_Migration_CannotBeReplayed() public {
        _seedReserve();
        _migrateToTreasury();

        vm.prank(dao);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        wrapper.reinitializeV4WithTreasury(new address[](0), address(treasury));
    }

    /// @notice The wrapper's own V4 initializer is tombstoned on this implementation.
    function test_Migration_BareV4InitializerIsTombstoned() public {
        _seedReserve();

        ConfidentialWrapperTreasury impl = new ConfidentialWrapperTreasury();
        vm.prank(dao);
        vm.expectRevert(ConfidentialWrapperTreasury.V4InitializerRequiresTreasury.selector);
        wrapper.upgradeToAndCall(address(impl), abi.encodeCall(ConfidentialWrapper.reinitializeV4, (new address[](0))));

        assertEq(underlying.balanceOf(address(wrapper)), _seededReserve(), "reserve moved on a rejected upgrade");
    }

    /// @notice A zero treasury is rejected, so the migration cannot burn the reserve.
    function test_Migration_RejectsTheZeroTreasury() public {
        _seedReserve();

        ConfidentialWrapperTreasury impl = new ConfidentialWrapperTreasury();
        vm.prank(dao);
        vm.expectRevert(ConfidentialWrapperTreasury.InvalidTreasury.selector);
        wrapper.upgradeToAndCall(
            address(impl),
            abi.encodeCall(ConfidentialWrapperTreasury.reinitializeV4WithTreasury, (new address[](0), address(0)))
        );
    }

    /// @notice Only the wrapper's owner can perform the migration.
    function test_Migration_IsOwnerOnly() public {
        _seedReserve();
        ConfidentialWrapperTreasury impl = new ConfidentialWrapperTreasury();
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        wrapper.upgradeToAndCall(
            address(impl),
            abi.encodeCall(
                ConfidentialWrapperTreasury.reinitializeV4WithTreasury, (new address[](0), address(treasury))
            )
        );

        assertEq(underlying.balanceOf(address(wrapper)), _seededReserve(), "reserve moved on a rejected upgrade");
    }

    // ----- Integrator-visible change -----

    /// @notice After migration, `USDC.balanceOf(wrapper)` is no longer the reserve view.
    function test_Migration_BalanceOfWrapperStopsBeingTheReserveView() public {
        _seedReserve();
        assertEq(
            underlying.balanceOf(address(wrapper)) / wrapper.rate(),
            wrapper.inferredTotalSupply(),
            "precondition: the two readings agree today"
        );

        _migrateToTreasury();

        assertEq(underlying.balanceOf(address(wrapper)), 0, "the naive reading now reports zero backing");
        assertGt(wrapper.inferredTotalSupply(), 0, "the supported reading still reports the backing");
    }

    // ----- Helpers -----

    /// @dev Two holders, reserve at the wrapper.
    function _seedReserve() private {
        _wrap(alice, 3 * ONE);
        _wrapViaTransferAndCall(bob, 2 * ONE);
        assertEq(underlying.balanceOf(address(wrapper)), _seededReserve(), "unexpected seeded reserve");
    }

    function _seededReserve() private pure returns (uint256) {
        return 5 * ONE;
    }
}
