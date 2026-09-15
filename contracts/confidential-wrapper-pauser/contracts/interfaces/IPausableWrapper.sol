// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

/**
 * @title IPausableWrapper
 * @notice The subset of the `ConfidentialWrapper` pause surface used by {ConfidentialWrapperPauser}.
 * @dev `pause()` is restricted on the wrapper to the single address returned by its `pauser()` getter, which
 * governance points at the chain's `ConfidentialWrapperPauser` through `setPauser`; `paused()` is read first so an
 * already-paused wrapper is reported rather than called. `unpause()` is deliberately absent: restoration stays
 * `onlyOwner` on each wrapper.
 */
interface IPausableWrapper {
    /// @notice Halts every value-moving entry point of the wrapper. Reverts unless `msg.sender == pauser()`.
    function pause() external;

    /// @notice True while the wrapper is paused (OpenZeppelin `Pausable`).
    function paused() external view returns (bool);
}
