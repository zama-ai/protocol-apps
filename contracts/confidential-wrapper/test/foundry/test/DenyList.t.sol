// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {BaseForkTest} from "./BaseForkTest.t.sol";
import {ConfidentialWrapper} from "confidential-wrapper/ConfidentialWrapper.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deny-list behavior (per-wrapper local block list, owner gating, and the
/// wrap guard) across every registered wrapper.
contract DenyListTest is BaseForkTest {
    function test_OwnerBlockUnblock_AllWrappers() public {
        for (uint256 i = 0; i < wrappers.length; i++) {
            address w = wrappers[i];
            string memory sym = _label(w);
            address owner = _wrapperOwner(w);
            address user = makeAddr(string.concat("blocked-", sym));

            assertFalse(_wrapper(w).isBlocked(user), string.concat(sym, ": user unexpectedly blocked"));

            vm.prank(owner);
            _wrapper(w).blockUser(user);
            assertTrue(_wrapper(w).isBlocked(user), string.concat(sym, ": user not blocked after blockUser"));

            vm.prank(owner);
            _wrapper(w).unblockUser(user);
            assertFalse(_wrapper(w).isBlocked(user), string.concat(sym, ": user still blocked after unblockUser"));
        }
    }

    function test_NonOwnerCannotBlock_AllWrappers() public {
        address attacker = makeAddr("attacker");
        for (uint256 i = 0; i < wrappers.length; i++) {
            address w = wrappers[i];
            vm.prank(attacker);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
            _wrapper(w).blockUser(attacker);
        }
    }

    function test_BlockedDepositorCannotWrap_AllWrappers() public {
        for (uint256 i = 0; i < wrappers.length; i++) {
            address w = wrappers[i];
            string memory sym = _label(w);
            address owner = _wrapperOwner(w);
            address depositor = makeAddr(string.concat("depositor-", sym));
            uint256 amount = _wrapper(w).rate();

            vm.prank(owner);
            _wrapper(w).blockUser(depositor);

            IERC20 underlying = _underlying(w);
            deal(address(underlying), depositor, amount);

            vm.startPrank(depositor);
            _approve(underlying, w, amount);
            vm.expectRevert(abi.encodeWithSelector(ConfidentialWrapper.BlockedUser.selector, depositor));
            _wrapper(w).wrap(depositor, amount);
            vm.stopPrank();
        }
    }

}
