// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

/**
 * @title PermissiveFallbackMock
 * @notice A contract that is not a wrapper but accepts any call, the way WETH9's `deposit()` fallback does: `pause()`
 * returns successfully with no data. Used to document what happens when a roster member lists a non-wrapper: the
 * fallback emits, so it cannot run under the `paused()` staticcall, and the pauser reports the target as a failed
 * wrapper (with empty revert data) after the failed call has burnt the gas it was handed. Test-only.
 */
contract PermissiveFallbackMock {
    event Deposit(address indexed dst, uint256 wad);

    fallback() external payable {
        emit Deposit(msg.sender, msg.value);
    }
}
