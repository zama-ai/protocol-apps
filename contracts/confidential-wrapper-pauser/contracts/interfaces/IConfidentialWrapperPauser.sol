// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import { IConfidentialTokenWrappersRegistry } from "./IConfidentialTokenWrappersRegistry.sol";

/**
 * @title IConfidentialWrapperPauser
 * @notice Roster and circuit breaker for every confidential wrapper on a chain (P-RFC-006).
 * @dev The roster is the `PAUSER_ROLE` of an OpenZeppelin `AccessControl`, managed by the `DEFAULT_ADMIN_ROLE` holder
 * (the chain's governance, under `AccessControlDefaultAdminRules`). Any roster member can pause one wrapper or a
 * batch of them, as long as the chain's `ConfidentialTokenWrappersRegistry` lists it as a valid wrapper; nobody can
 * unpause through this contract.
 */
interface IConfidentialWrapperPauser {
    /// @notice Emitted when `account` joins the roster (alongside the standard `RoleGranted`).
    event PauserAdded(address indexed account);

    /// @notice Emitted when `account` leaves the roster (alongside the standard `RoleRevoked`).
    event PauserRemoved(address indexed account);

    /// @notice Emitted for each wrapper this contract paused.
    event WrapperPaused(address indexed wrapper);

    /// @notice Emitted, by either form, for a wrapper that was already paused when the call reached it. Not a
    /// failure: the wrapper is halted, which is the point, and the single form does not revert on it.
    event WrapperAlreadyPaused(address indexed wrapper);

    /**
     * @notice Emitted by the batch form when a wrapper could not be paused. The batch continues.
     * @param wrapper The wrapper that is still running.
     * @param errorData Its revert data (typically `SenderNotPauser(address(this))` when governance has not armed
     * the wrapper with this contract yet), or an ABI-encoded {WrapperNotRegistered}.
     */
    event WrapperPauseFailed(address indexed wrapper, bytes errorData);

    /// @notice Thrown when `sender` calls {pause} without being on the roster.
    error SenderNotPauser(address sender);

    /**
     * @notice The single-wrapper form reverts with this error when the wrapper could not be paused.
     * @param wrapper The wrapper that rejected the call.
     * @param errorData Its revert data (typically `SenderNotPauser(address(this))` when governance has not armed
     * the wrapper with this contract yet), or an ABI-encoded {WrapperNotRegistered}.
     */
    error PauseFailed(address wrapper, bytes errorData);

    /// @notice Thrown by the constructor when the registry address has no code.
    error InvalidRegistry(address registry);

    /**
     * @notice Encoded into `errorData` when the target is not a valid wrapper of the chain's registry (never
     * registered, or revoked). No call is made to such an address, so a stray non-wrapper cannot burn the batch's
     * gas or otherwise interfere.
     */
    error WrapperNotRegistered(address wrapper);

    /**
     * @notice Adds `account` to the roster. Restricted to the default admin (governance).
     * @dev Thin wrapper over `grantRole(PAUSER_ROLE, account)`: a no-op, without events, if `account` is already
     * on the roster; reverts with `AccessControlUnauthorizedAccount` for any other caller.
     */
    function addPauser(address account) external;

    /**
     * @notice Removes `account` from the roster. Restricted to the default admin (governance).
     * @dev Thin wrapper over `revokeRole(PAUSER_ROLE, account)`: a no-op, without events, if `account` is not on
     * the roster, so a governance batch still succeeds if the member renounced first.
     */
    function removePauser(address account) external;

    /// @notice Returns true if `account` is on the roster (`hasRole(PAUSER_ROLE, account)`).
    function isPauser(address account) external view returns (bool);

    /// @notice Returns every roster member (`getRoleMembers(PAUSER_ROLE)`). Readable on-chain so a scheduled job can
    /// compare chains.
    function pausers() external view returns (address[] memory);

    /// @notice The chain's `ConfidentialTokenWrappersRegistry`; only wrappers it reports as valid can be paused.
    function registry() external view returns (IConfidentialTokenWrappersRegistry);

    /**
     * @notice Pauses one wrapper. Restricted to roster members.
     * @dev Reverts with {PauseFailed} if the wrapper is not a valid registry entry or rejects the call; emits
     * {WrapperAlreadyPaused} and returns if it is already paused.
     */
    function pause(address wrapper) external;

    /**
     * @notice Pauses several wrappers, best effort. Restricted to roster members.
     * @dev Every entry gets exactly one of {WrapperPaused}, {WrapperAlreadyPaused} or {WrapperPauseFailed}; a
     * failing entry never stops the rest.
     */
    function pause(address[] calldata wrappers) external;
}
