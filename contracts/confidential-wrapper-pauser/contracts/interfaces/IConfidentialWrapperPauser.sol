// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

/**
 * @title IConfidentialWrapperPauser
 * @notice Roster and circuit breaker for every confidential wrapper on a chain (P-RFC-006).
 * @dev The roster is a set of addresses managed by the contract owner (the chain's governance). Any roster member
 * can pause one wrapper or a batch of them; nobody can unpause through this contract.
 */
interface IConfidentialWrapperPauser {
    /// @notice Emitted when `account` joins the roster.
    event PauserAdded(address indexed account);

    /// @notice Emitted when `account` leaves the roster.
    event PauserRemoved(address indexed account);

    /// @notice Emitted for each wrapper this contract paused.
    event WrapperPaused(address indexed wrapper);

    /// @notice Emitted, by either form, for a wrapper that was already paused when the call reached it. Not a
    /// failure: the wrapper is halted, which is the point, and the single form does not revert on it.
    event WrapperAlreadyPaused(address indexed wrapper);

    /**
     * @notice Emitted by the batch form when a wrapper rejected the call. The batch continues.
     * @param wrapper The wrapper that is still running.
     * @param errorData Its revert data (typically `SenderNotPauser(address(this))` when governance has not armed
     * the wrapper with this contract yet).
     */
    event WrapperPauseFailed(address indexed wrapper, bytes errorData);

    /// @notice Thrown when `sender` calls {pause} without being on the roster.
    error SenderNotPauser(address sender);

    /**
     * @notice The single-wrapper form reverts with this error when the wrapper rejected the call.
     * @param wrapper The wrapper that rejected the call.
     * @param errorData Its revert data (typically `SenderNotPauser(address(this))` when governance has not armed
     * the wrapper with this contract yet).
     */
    error PauseFailed(address wrapper, bytes errorData);

    /**
     * @notice Adds `account` to the roster. Restricted to the owner (governance).
     * @dev A no-op, without event, if `account` is already on the roster, so a governance batch that lists a member
     * twice still succeeds.
     */
    function addPauser(address account) external;

    /**
     * @notice Removes `account` from the roster. Restricted to the owner (governance).
     * @dev A no-op, without event, if `account` is not on the roster.
     */
    function removePauser(address account) external;

    /// @notice Returns true if `account` is on the roster.
    function isPauser(address account) external view returns (bool);

    /// @notice Returns every roster member, in no particular order. Readable on-chain so a scheduled job can
    /// compare chains.
    function pausers() external view returns (address[] memory);

    /**
     * @notice Pauses one wrapper. Restricted to roster members.
     * @dev Reverts with {PauseFailed} if the wrapper rejects the call; emits {WrapperAlreadyPaused} and returns if
     * it is already paused.
     */
    function pause(address wrapper) external;

    /**
     * @notice Pauses several wrappers, best effort. Restricted to roster members.
     * @dev Every entry gets exactly one of {WrapperPaused}, {WrapperAlreadyPaused} or {WrapperPauseFailed}; a
     * wrapper that rejects the call never stops the rest.
     */
    function pause(address[] calldata wrappers) external;
}
