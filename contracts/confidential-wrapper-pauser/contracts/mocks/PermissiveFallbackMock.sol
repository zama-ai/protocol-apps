// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

/**
 * @title PermissiveFallbackMock
 * @notice A contract that is not a wrapper but accepts any call, the way WETH9's `deposit()` fallback does: `pause()`
 * returns successfully with no data, and so does `paused()`. Used to document what happens when a roster member
 * lists a non-wrapper: the pauser cannot decode `paused()` and the call aborts. Test-only.
 */
contract PermissiveFallbackMock {
    event Deposit(address indexed dst, uint256 wad);

    fallback() external payable {
        emit Deposit(msg.sender, msg.value);
    }
}
