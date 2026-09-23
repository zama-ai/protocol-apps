// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

/**
 * @title UnreadableWrapperMock
 * @notice A pause target whose `paused()` reverts, the way a wrapper behind a broken or mid-upgrade proxy would,
 * while its `pause()` would succeed. Checks the pauser reports the pre-read failure as the wrapper's own instead of
 * aborting the call. Test-only.
 */
contract UnreadableWrapperMock {
    error PausedUnavailable();

    function paused() external pure returns (bool) {
        revert PausedUnavailable();
    }

    function pause() external pure {}
}
