// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

/**
 * @title IConfidentialTokenWrappersRegistry
 * @notice The subset of the chain's `ConfidentialTokenWrappersRegistry` used by {ConfidentialWrapperPauser}.
 * @dev The registry is the source of truth for which confidential wrappers exist on a chain; the pauser only ever
 * calls `pause()` on an address the registry reports as a valid (registered, not revoked) wrapper.
 */
interface IConfidentialTokenWrappersRegistry {
    /// @notice True if `confidentialTokenAddress` is a registered, non-revoked confidential wrapper.
    function isConfidentialTokenValid(address confidentialTokenAddress) external view returns (bool);
}
