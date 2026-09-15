// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import { AccessControl, IAccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { AccessControlDefaultAdminRules } from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import { AccessControlEnumerable } from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import { IConfidentialTokenWrappersRegistry } from "./interfaces/IConfidentialTokenWrappersRegistry.sol";
import { IConfidentialWrapperPauser } from "./interfaces/IConfidentialWrapperPauser.sol";
import { IPausableWrapper } from "./interfaces/IPausableWrapper.sol";

/**
 * @title ConfidentialWrapperPauser
 * @notice One deployment per chain that is both the pauser roster and the wrapper circuit breaker (P-RFC-006).
 * Governance points every confidential wrapper's `setPauser` at this contract; any single roster member can then
 * pause one wrapper or, best effort, a batch of them. Only addresses the chain's `ConfidentialTokenWrappersRegistry`
 * reports as valid wrappers are ever called, so a typo or a non-wrapper in a batch is reported, not executed, and
 * a wrapper that is already paused is reported as such. Unpausing is not offered here: it stays `onlyOwner` on
 * each wrapper, so pausing is fast (one signer) and restoring is a governance action.
 *
 * @dev Built on OpenZeppelin {AccessControl}:
 * - `DEFAULT_ADMIN_ROLE` is the chain's governance (Protocol DAO on Ethereum and Sepolia, the local multisig
 *   elsewhere). {AccessControlDefaultAdminRules} keeps it single-holder and moves it only through a delayed
 *   two-step transfer ({beginDefaultAdminTransfer} / {acceptDefaultAdminTransfer}); `owner()` (ERC-5313) mirrors it.
 * - {PAUSER_ROLE} is the roster, administered by `DEFAULT_ADMIN_ROLE` and enumerable through
 *   {AccessControlEnumerable}.
 * The RFC ABI ({addPauser}, {removePauser}, {isPauser}, {pausers}, {PauserAdded}, {PauserRemoved},
 * {SenderNotPauser}) is kept as thin wrappers over the AccessControl functions; roster changes therefore also emit
 * the standard `RoleGranted` / `RoleRevoked` events. Access checks are internal functions rather than modifiers.
 *
 * The contract is intentionally not upgradeable. Recovery from a defect is a redeploy plus a re-batched
 * `setPauser` proposal.
 */
contract ConfidentialWrapperPauser is
    IConfidentialWrapperPauser,
    AccessControlDefaultAdminRules,
    AccessControlEnumerable
{
    /// @notice Role of the roster members: each holder can call {pause}.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @inheritdoc IConfidentialWrapperPauser
    IConfidentialTokenWrappersRegistry public immutable registry;

    /**
     * @param initialDelay Delay, in seconds, that every default admin transfer must wait before it can be accepted
     * (see {AccessControlDefaultAdminRules}).
     * @param initialAdmin The chain's governance address, holder of `DEFAULT_ADMIN_ROLE`.
     * @param registry_ The chain's `ConfidentialTokenWrappersRegistry`. Immutable: a registry redeploy means a
     * pauser redeploy, like any other defect.
     * @param initialPausers The day-one roster. Duplicates are granted once.
     */
    constructor(
        uint48 initialDelay,
        address initialAdmin,
        IConfidentialTokenWrappersRegistry registry_,
        address[] memory initialPausers
    ) AccessControlDefaultAdminRules(initialDelay, initialAdmin) {
        if (address(registry_).code.length == 0) revert InvalidRegistry(address(registry_));
        registry = registry_;
        for (uint256 i = 0; i < initialPausers.length; ++i) {
            _grantRole(PAUSER_ROLE, initialPausers[i]);
        }
    }

    // ----- Roster (RFC ABI over AccessControl) -----

    /// @inheritdoc IConfidentialWrapperPauser
    function addPauser(address account) external {
        grantRole(PAUSER_ROLE, account);
    }

    /// @inheritdoc IConfidentialWrapperPauser
    function removePauser(address account) external {
        revokeRole(PAUSER_ROLE, account);
    }

    /// @inheritdoc IConfidentialWrapperPauser
    function isPauser(address account) external view returns (bool) {
        return hasRole(PAUSER_ROLE, account);
    }

    /// @inheritdoc IConfidentialWrapperPauser
    function pausers() external view returns (address[] memory) {
        return getRoleMembers(PAUSER_ROLE);
    }

    // ----- Circuit breaker -----

    /// @inheritdoc IConfidentialWrapperPauser
    function pause(address wrapper) external {
        _checkPauser();
        _pause(wrapper, true);
    }

    /// @inheritdoc IConfidentialWrapperPauser
    function pause(address[] calldata wrappers) external {
        _checkPauser();
        for (uint256 i = 0; i < wrappers.length; ++i) {
            _pause(wrappers[i], false);
        }
    }

    // ----- AccessControl diamond -----
    // `AccessControlDefaultAdminRules` and `AccessControlEnumerable` both derive from `AccessControl`, so every
    // function either of them overrides must be resolved here; the resolutions below only forward to `super`, the
    // default-admin rules and the enumeration bookkeeping are untouched.

    /// @inheritdoc AccessControl
    function grantRole(
        bytes32 role,
        address account
    ) public override(AccessControl, AccessControlDefaultAdminRules, IAccessControl) {
        super.grantRole(role, account);
    }

    /// @inheritdoc AccessControl
    function revokeRole(
        bytes32 role,
        address account
    ) public override(AccessControl, AccessControlDefaultAdminRules, IAccessControl) {
        super.revokeRole(role, account);
    }

    /// @inheritdoc AccessControl
    function renounceRole(
        bytes32 role,
        address callerConfirmation
    ) public override(AccessControl, AccessControlDefaultAdminRules, IAccessControl) {
        super.renounceRole(role, callerConfirmation);
    }

    /// @inheritdoc AccessControl
    function _setRoleAdmin(
        bytes32 role,
        bytes32 adminRole
    ) internal override(AccessControl, AccessControlDefaultAdminRules) {
        super._setRoleAdmin(role, adminRole);
    }

    // ----- ERC-165 -----

    /// @inheritdoc AccessControl
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(AccessControlDefaultAdminRules, AccessControlEnumerable) returns (bool) {
        return interfaceId == type(IConfidentialWrapperPauser).interfaceId || super.supportsInterface(interfaceId);
    }

    // ----- Internals -----

    /// @dev Reverts with {SenderNotPauser} unless the caller is on the roster.
    function _checkPauser() private view {
        address sender = _msgSender();
        if (!hasRole(PAUSER_ROLE, sender)) revert SenderNotPauser(sender);
    }

    /**
     * @dev Resolves the {AccessControlDefaultAdminRules} / {AccessControlEnumerable} diamond and emits the RFC
     * {PauserAdded} event whenever an account actually joins the roster, whichever path granted the role.
     */
    function _grantRole(
        bytes32 role,
        address account
    ) internal override(AccessControlDefaultAdminRules, AccessControlEnumerable) returns (bool granted) {
        granted = super._grantRole(role, account);
        if (granted && role == PAUSER_ROLE) emit PauserAdded(account);
    }

    /**
     * @dev Resolves the {AccessControlDefaultAdminRules} / {AccessControlEnumerable} diamond and emits the RFC
     * {PauserRemoved} event whenever an account actually leaves the roster, whichever path revoked the role
     * ({removePauser}, `revokeRole` or the member's own `renounceRole`).
     */
    function _revokeRole(
        bytes32 role,
        address account
    ) internal override(AccessControlDefaultAdminRules, AccessControlEnumerable) returns (bool revoked) {
        revoked = super._revokeRole(role, account);
        if (revoked && role == PAUSER_ROLE) emit PauserRemoved(account);
    }

    /**
     * @dev Pauses one wrapper and reports the outcome: `strict` (the single form) reverts with {PauseFailed} on a
     * failure, the batch form emits {WrapperPauseFailed} and moves on. The registry check is the trust boundary:
     * an address the chain's registry does not list as a valid wrapper is never called, so a typo or a non-wrapper
     * in a batch costs one lookup and cannot interfere with the rest. Everything the registry lists is a
     * `ConfidentialWrapper` with the V4 pause API, so `paused()` and `pause()` are ordinary calls: a wrapper that
     * is already paused is reported with {WrapperAlreadyPaused} and left alone rather than tripping on its
     * `EnforcedPause`, and the only revert left to catch is the wrapper refusing the call (`SenderNotPauser` when
     * governance has not pointed its `setPauser` at this contract yet).
     */
    function _pause(address wrapper, bool strict) private {
        if (!registry.isConfidentialTokenValid(wrapper)) {
            _fail(wrapper, abi.encodeWithSelector(WrapperNotRegistered.selector, wrapper), strict);
            return;
        }
        if (IPausableWrapper(wrapper).paused()) {
            emit WrapperAlreadyPaused(wrapper);
            return;
        }
        try IPausableWrapper(wrapper).pause() {
            emit WrapperPaused(wrapper);
        } catch (bytes memory reason) {
            _fail(wrapper, reason, strict);
        }
    }

    /// @dev Reverts with {PauseFailed} in the single form, emits {WrapperPauseFailed} in the batch form.
    function _fail(address wrapper, bytes memory errorData, bool strict) private {
        if (strict) revert PauseFailed(wrapper, errorData);
        emit WrapperPauseFailed(wrapper, errorData);
    }
}
