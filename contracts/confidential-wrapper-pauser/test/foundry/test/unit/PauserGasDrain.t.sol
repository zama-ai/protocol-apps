// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";

import { ConfidentialWrapperPauser } from "confidential-wrapper-pauser/ConfidentialWrapperPauser.sol";
import { IConfidentialWrapperPauser } from "confidential-wrapper-pauser/interfaces/IConfidentialWrapperPauser.sol";
import { ConfidentialTokenWrappersRegistryMock } from "confidential-wrapper-pauser/mocks/ConfidentialTokenWrappersRegistryMock.sol";
import { ConfidentialWrapperMock } from "confidential-wrapper-pauser/mocks/ConfidentialWrapperMock.sol";
import { PermissiveFallbackMock } from "confidential-wrapper-pauser/mocks/PermissiveFallbackMock.sol";

/**
 * @title PauserGasDrainTest
 * @notice Regression tests for the gas drain the batch fuzz test found on 2026-09-15. A WETH9-style target
 * (permissive fallback that writes a log) made the `paused()` read-back halt with `StateChangeDuringStaticCall`,
 * an exceptional halt that burns every unit of gas forwarded to it, 63/64 of what the batch had left: one such
 * entry cost the caller almost the whole gas limit and two of them reverted the batch. The fix is the registry
 * gate: an address the chain's `ConfidentialTokenWrappersRegistry` does not list as a valid wrapper is never
 * called. The residual (a *registered* target without the pause API aborts the pauser instead of being reported)
 * is accepted, since the live registry only admits ERC-7984 wrappers, and is pinned here too so the trade-off
 * stays visible.
 */
contract PauserGasDrainTest is Test {
    uint256 internal constant BLOCK_GAS = 30_000_000;

    address internal admin = makeAddr("admin");
    address internal fb = makeAddr("roster-member");
    ConfidentialTokenWrappersRegistryMock internal registry;
    ConfidentialWrapperPauser internal pauser;

    function setUp() public {
        address[] memory roster = new address[](1);
        roster[0] = fb;
        registry = new ConfidentialTokenWrappersRegistryMock();
        pauser = new ConfidentialWrapperPauser(0, admin, registry, roster);
    }

    /// @notice Baseline: forty armed wrappers pause for well under a million gas.
    function test_FortyArmedWrappersAreCheap() public {
        address[] memory batch = _batch(0, false, 40);
        vm.prank(fb);
        uint256 before = gasleft();
        pauser.pause{ gas: BLOCK_GAS }(batch);
        assertLt(before - gasleft(), 1_500_000, "forty wrappers");
    }

    /// @notice Unregistered WETH-style entries are reported, never called: five of them followed by twenty
    /// wrappers cost a few registry lookups more than the wrappers alone, and every wrapper is paused.
    function test_UnregisteredPermissiveEntriesCostOnlyALookup() public {
        address[] memory batch = _batch(5, false, 20);
        vm.prank(fb);
        uint256 before = gasleft();
        for (uint256 i = 0; i < 5; i++) {
            vm.expectEmit(true, false, false, true, address(pauser));
            emit IConfidentialWrapperPauser.WrapperPauseFailed(
                batch[i],
                abi.encodeWithSelector(IConfidentialWrapperPauser.WrapperNotRegistered.selector, batch[i])
            );
        }
        pauser.pause{ gas: BLOCK_GAS }(batch);
        assertLt(before - gasleft(), 1_500_000, "five WETH-style entries plus twenty wrappers");
        for (uint256 i = 5; i < batch.length; i++) {
            assertTrue(ConfidentialWrapperMock(batch[i]).paused(), "wrapper after the unregistered entries");
        }
    }

    /// @notice Accepted residual: a *registered* WETH-style entry is called, its `paused()` read-back halts the
    /// pauser, and the whole batch reverts without data instead of reporting the entry; nothing gets paused.
    function test_Residual_RegisteredPermissiveEntryAbortsTheBatch() public {
        address[] memory batch = _batch(1, true, 20);
        vm.prank(fb);
        vm.expectRevert(bytes(""));
        pauser.pause{ gas: BLOCK_GAS }(batch);
        for (uint256 i = 1; i < batch.length; i++) {
            assertFalse(ConfidentialWrapperMock(batch[i]).paused(), "wrapper paused despite the aborted batch");
        }
    }

    /// @dev `permissives` WETH-style targets (registered or not) followed by `armed` registered wrappers.
    function _batch(
        uint256 permissives,
        bool registerPermissives,
        uint256 armed
    ) internal returns (address[] memory batch) {
        batch = new address[](permissives + armed);
        for (uint256 i = 0; i < permissives; i++) {
            batch[i] = address(new PermissiveFallbackMock());
            if (registerPermissives) registry.register(batch[i]);
        }
        for (uint256 i = 0; i < armed; i++) {
            address wrapper = address(new ConfidentialWrapperMock(admin, address(pauser)));
            registry.register(wrapper);
            batch[permissives + i] = wrapper;
        }
    }
}
