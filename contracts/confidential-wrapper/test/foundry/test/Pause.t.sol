// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {BaseForkTest} from "./BaseForkTest.t.sol";
import {ConfidentialWrapper} from "confidential-wrapper/ConfidentialWrapper.sol";
import {externalEuint64} from "encrypted-types/EncryptedTypes.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {IERC1363} from "@openzeppelin/contracts/interfaces/IERC1363.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Pause behavior across every registered wrapper, running against live mainnet state.
/// @dev The pauser is storage the live proxies have never written, so these tests also cover
/// arming it on real V3 state without disturbing the deny-list config it shares a slot with.
contract PauseTest is BaseForkTest {
    /// @dev Confidential token amount wrapped per case.
    uint64 internal constant CONFIDENTIAL_AMOUNT = 1_000_000;

    function setUp() public override {
        super.setUp();
        // Wrapping and transferring in one case chains several FHE ops; relax only the depth cap.
        disableHCUDepthLimit();
    }

    /// @notice Live proxies come out of the upgrade unpaused with no pauser, so nobody can pause yet.
    function test_PauserUnsetAfterUpgrade_AllWrappers() public {
        address anyone = makeAddr("anyone");
        for (uint256 i = 0; i < wrappers.length; i++) {
            address w = wrappers[i];
            string memory sym = _label(w);

            assertEq(_wrapper(w).pauser(), address(0), string.concat(sym, ": pauser set after upgrade"));
            assertFalse(_wrapper(w).paused(), string.concat(sym, ": paused after upgrade"));

            vm.prank(anyone);
            vm.expectRevert(abi.encodeWithSelector(ConfidentialWrapper.SenderNotPauser.selector, anyone));
            _wrapper(w).pause();
        }
    }

    /// @notice The owner arms the pauser, the pauser pauses, and the owner unpauses.
    /// Arming writes into the same slot as the deny-list config, which must survive.
    function test_OwnerArmsPauserAndPauses_AllWrappers() public {
        for (uint256 i = 0; i < wrappers.length; i++) {
            address w = wrappers[i];
            string memory sym = _label(w);
            address owner = _wrapperOwner(w);
            address pauser = makeAddr(string.concat("pauser-", sym));

            (bool hasSelectorBefore, bytes4 selectorBefore) = _wrapper(w).getUnderlyingDenyListSelector();
            bytes32 slotBefore = vm.load(w, _v3PauserSlot());

            vm.prank(owner);
            vm.expectEmit(true, false, false, false, w);
            emit ConfidentialWrapper.PauserUpdated(pauser);
            _wrapper(w).setPauser(pauser);
            assertEq(_wrapper(w).pauser(), pauser, string.concat(sym, ": pauser not set"));

            // The pauser packs above the deny-list selector and flag in the same word.
            assertEq(
                vm.load(w, _v3PauserSlot()),
                slotBefore | bytes32(uint256(uint160(pauser)) << 40),
                string.concat(sym, ": pauser did not pack above the deny-list config")
            );
            (bool hasSelectorAfter, bytes4 selectorAfter) = _wrapper(w).getUnderlyingDenyListSelector();
            assertEq(hasSelectorAfter, hasSelectorBefore, string.concat(sym, ": deny-list flag clobbered"));
            assertEq(selectorAfter, selectorBefore, string.concat(sym, ": deny-list selector clobbered"));

            vm.prank(pauser);
            _wrapper(w).pause();
            assertTrue(_wrapper(w).paused(), string.concat(sym, ": not paused"));

            vm.prank(owner);
            _wrapper(w).unpause();
            assertFalse(_wrapper(w).paused(), string.concat(sym, ": still paused"));
        }
    }

    /// @notice Only the owner can arm the pauser, and only the owner can unpause.
    function test_AccessControl_AllWrappers() public {
        address attacker = makeAddr("attacker");
        for (uint256 i = 0; i < wrappers.length; i++) {
            address w = wrappers[i];
            string memory sym = _label(w);
            address owner = _wrapperOwner(w);
            address pauser = makeAddr(string.concat("access-pauser-", sym));

            vm.prank(attacker);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
            _wrapper(w).setPauser(attacker);

            vm.prank(owner);
            _wrapper(w).setPauser(pauser);

            vm.prank(attacker);
            vm.expectRevert(abi.encodeWithSelector(ConfidentialWrapper.SenderNotPauser.selector, attacker));
            _wrapper(w).pause();

            // The owner holds the unpause key, not the pause key.
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(ConfidentialWrapper.SenderNotPauser.selector, owner));
            _wrapper(w).pause();

            vm.prank(pauser);
            _wrapper(w).pause();

            vm.prank(pauser);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, pauser));
            _wrapper(w).unpause();
        }
    }

    /// @notice Clearing the pauser back to the zero address revokes the ability to pause, and doing
    /// so mid-incident leaves the owner able to unpause.
    function test_ZeroPauserRevokes_AllWrappers() public {
        for (uint256 i = 0; i < wrappers.length; i++) {
            address w = wrappers[i];
            string memory sym = _label(w);
            address owner = _wrapperOwner(w);
            address pauser = makeAddr(string.concat("revoked-pauser-", sym));

            vm.startPrank(owner);
            _wrapper(w).setPauser(pauser);
            _wrapper(w).setPauser(address(0));
            vm.stopPrank();

            assertEq(_wrapper(w).pauser(), address(0), string.concat(sym, ": pauser not cleared"));

            vm.prank(pauser);
            vm.expectRevert(abi.encodeWithSelector(ConfidentialWrapper.SenderNotPauser.selector, pauser));
            _wrapper(w).pause();

            // Clearing the pauser while paused must not strand the wrapper: unpause reads owner(),
            // never the pauser.
            vm.prank(owner);
            _wrapper(w).setPauser(pauser);
            vm.prank(pauser);
            _wrapper(w).pause();

            vm.startPrank(owner);
            _wrapper(w).setPauser(address(0));
            assertTrue(_wrapper(w).paused(), string.concat(sym, ": pause lost when the pauser was cleared"));
            _wrapper(w).unpause();
            vm.stopPrank();

            assertFalse(_wrapper(w).paused(), string.concat(sym, ": owner could not unpause without a pauser"));
        }
    }

    /// @notice A pause closes every value-moving entry point on the live wrapper, and unpausing reopens them.
    function test_PauseHaltsValueFlows_AllWrappers() public {
        for (uint256 i = 0; i < wrappers.length; i++) {
            _runPauseCycle(wrappers[i]);
        }
    }

    function _runPauseCycle(address w) internal {
        string memory sym = _label(w);
        address owner = _wrapperOwner(w);
        address pauser = makeAddr(string.concat("halt-pauser-", sym));
        address alice = makeAddr(string.concat("halt-alice-", sym));
        address bob = makeAddr(string.concat("halt-bob-", sym));

        uint256 underlyingAmount = uint256(CONFIDENTIAL_AMOUNT) * _wrapper(w).rate();
        _dealAndWrap(w, alice, underlyingAmount);

        vm.prank(owner);
        _wrapper(w).setPauser(pauser);
        vm.prank(pauser);
        _wrapper(w).pause();

        _expectWrapPathsHalted(w, sym, alice, underlyingAmount);
        _expectConfidentialPathsHalted(w, alice, bob);

        // The pause gate precedes the deny-list check: the seeded context holds a blocked
        // address, yet EnforcedPause is what surfaces.
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        _wrapper(w).finalizeUnwrap(preUpgrade[w].pendingUnwrapId, 0, "");

        vm.prank(owner);
        _wrapper(w).unpause();

        // Wrapping works again, and the underlying actually moves. Bob wraps rather than alice
        // because USDT rejects a second non-zero approval over a live allowance.
        IERC20 underlying = _underlying(w);
        uint256 wrapperBalanceBefore = underlying.balanceOf(w);
        _dealAndWrap(w, bob, underlyingAmount);
        assertEq(
            underlying.balanceOf(w) - wrapperBalanceBefore,
            underlyingAmount,
            string.concat(sym, ": wrap did not resume after unpause")
        );
    }

    /// @dev Both mint-side entry points reach the gate through `_mint`
    function _expectWrapPathsHalted(address w, string memory sym, address alice, uint256 underlyingAmount) internal {
        IERC20 underlying = _underlying(w);
        deal(address(underlying), alice, underlying.balanceOf(alice) + underlyingAmount);
        uint256 aliceBalanceBefore = underlying.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        _wrapper(w).wrap(alice, underlyingAmount);

        if (ERC165Checker.supportsInterface(address(underlying), type(IERC1363).interfaceId)) {
            vm.prank(alice);
            vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
            IERC1363(address(underlying)).transferAndCall(w, underlyingAmount, abi.encodePacked(alice));
        }

        assertEq(
            underlying.balanceOf(alice),
            aliceBalanceBefore,
            string.concat(sym, ": underlying moved on a paused wrap")
        );
    }

    /// @dev Transfers and unwraps route through `_update`, which carries the gate.
    function _expectConfidentialPathsHalted(address w, address alice, address bob) internal {
        (externalEuint64 transferAmount, bytes memory transferProof) = encryptUint64(1, alice, w);
        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        _wrapper(w).confidentialTransfer(bob, transferAmount, transferProof);

        (externalEuint64 unwrapAmount, bytes memory unwrapProof) = encryptUint64(1, alice, w);
        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        _wrapper(w).unwrap(alice, alice, unwrapAmount, unwrapProof);
    }
}
