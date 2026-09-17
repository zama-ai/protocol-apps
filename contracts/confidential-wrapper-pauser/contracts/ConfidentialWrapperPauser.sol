// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import { Ownable, Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { IConfidentialWrapperPauser } from "./interfaces/IConfidentialWrapperPauser.sol";
import { IPausableWrapper } from "./interfaces/IPausableWrapper.sol";

/**
 * @title ConfidentialWrapperPauser
 * @notice One deployment per chain that is both the pauser roster and the wrapper circuit breaker (P-RFC-006).
 * Governance points every confidential wrapper's `setPauser` at this contract; any single roster member can then
 * pause one wrapper or, best effort, a batch of them. Unpausing is not offered here: it stays `onlyOwner` on each
 * wrapper, so pausing is fast (one signer) and restoring is a governance action.
 *
 * @dev The owner is the chain's governance (Protocol DAO on Ethereum and Sepolia, the local multisig elsewhere),
 * under OpenZeppelin {Ownable2Step}: ownership moves only through `transferOwnership` accepted by the new owner
 * with `acceptOwnership`, and {renounceOwnership} is disabled because a roster nobody can change is a redeploy.
 * The roster is an {EnumerableSet} the owner edits with {addPauser} / {removePauser}.
 *
 * The pause path trusts the roster: a target is called as a `ConfidentialWrapper` with the V4 pause API, its
 * `paused()` is read first so an already-paused wrapper is reported rather than tripping on its `EnforcedPause`,
 * and a revert from either call is the wrapper's failure (`SenderNotPauser` from `pause()` when governance has not
 * pointed its `setPauser` at this contract yet, or a `paused()` that reverts while its proxy is broken). An address
 * that is not a wrapper is not filtered out: one that answers `paused()` with nothing to decode aborts the call,
 * one whose fallback fails is reported after burning the gas it was handed, and picking valid targets is a roster
 * member's responsibility.
 *
 * The contract is intentionally not upgradeable. Recovery from a defect is a redeploy plus a re-batched
 * `setPauser` proposal.
 */
contract ConfidentialWrapperPauser is IConfidentialWrapperPauser, Ownable2Step {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Thrown when {renounceOwnership} is called by the owner.
    error RenounceOwnershipDisabled();

    EnumerableSet.AddressSet private _pausers;

    /**
     * @param initialOwner The chain's governance address.
     * @param initialPausers The day-one roster. Duplicates are added once.
     */
    constructor(address initialOwner, address[] memory initialPausers) Ownable(initialOwner) {
        for (uint256 i = 0; i < initialPausers.length; ++i) {
            _addPauser(initialPausers[i]);
        }
    }

    // ----- Roster -----

    /// @inheritdoc IConfidentialWrapperPauser
    function addPauser(address account) external onlyOwner {
        _addPauser(account);
    }

    /// @inheritdoc IConfidentialWrapperPauser
    function removePauser(address account) external onlyOwner {
        if (_pausers.remove(account)) emit PauserRemoved(account);
    }

    /// @inheritdoc IConfidentialWrapperPauser
    function isPauser(address account) external view returns (bool) {
        return _pausers.contains(account);
    }

    /// @inheritdoc IConfidentialWrapperPauser
    function pausers() external view returns (address[] memory) {
        return _pausers.values();
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

    // ----- Ownership -----

    /**
     * @notice Disabled. An ownerless pauser has a roster nobody can rotate; retiring the contract is a redeploy plus
     * a re-batched `setPauser` proposal instead, as for any other defect.
     */
    function renounceOwnership() public view override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    // ----- Internals -----

    /// @dev Adds `account` to the roster and emits {PauserAdded} if it was not a member yet.
    function _addPauser(address account) private {
        if (_pausers.add(account)) emit PauserAdded(account);
    }

    /// @dev Reverts with {SenderNotPauser} unless the caller is on the roster.
    function _checkPauser() private view {
        address sender = _msgSender();
        if (!_pausers.contains(sender)) revert SenderNotPauser(sender);
    }

    /**
     * @dev Pauses one wrapper and reports the outcome: `strict` (the single form) reverts with {PauseFailed} when
     * the wrapper rejects the call, the batch form emits {WrapperPauseFailed} and moves on. A `paused()` that
     * reverts is reported the same way, so one broken wrapper never rolls back the rest of a batch.
     */
    function _pause(address wrapper, bool strict) private {
        bool alreadyPaused;
        try IPausableWrapper(wrapper).paused() returns (bool isPaused) {
            alreadyPaused = isPaused;
        } catch (bytes memory reason) {
            _reportFailure(wrapper, strict, reason);
            return;
        }
        if (alreadyPaused) {
            emit WrapperAlreadyPaused(wrapper);
            return;
        }
        try IPausableWrapper(wrapper).pause() {
            emit WrapperPaused(wrapper);
        } catch (bytes memory reason) {
            _reportFailure(wrapper, strict, reason);
        }
    }

    /// @dev Reverts with {PauseFailed} in the single form, emits {WrapperPauseFailed} in the batch form.
    function _reportFailure(address wrapper, bool strict, bytes memory reason) private {
        if (strict) revert PauseFailed(wrapper, reason);
        emit WrapperPauseFailed(wrapper, reason);
    }
}
