// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

/**
 * @title BrokenWrapperMock
 * @notice A registered pause target that reports itself unpaused but whose `pause()` reverts without data, to check
 * the pauser reports empty revert data. Test-only.
 */
contract BrokenWrapperMock {
    function paused() external pure returns (bool) {
        return false;
    }

    function pause() external pure {
        // solhint-disable-next-line reason-string, gas-custom-errors
        revert();
    }
}
