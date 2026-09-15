// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import { Vm } from "forge-std/Vm.sol";

import { ConfidentialWrapperPauser } from "confidential-wrapper-pauser/ConfidentialWrapperPauser.sol";
import { IConfidentialWrapperPauser } from "confidential-wrapper-pauser/interfaces/IConfidentialWrapperPauser.sol";
import { BrokenWrapperMock } from "confidential-wrapper-pauser/mocks/BrokenWrapperMock.sol";
import { ConfidentialTokenWrappersRegistryMock } from "confidential-wrapper-pauser/mocks/ConfidentialTokenWrappersRegistryMock.sol";
import { ConfidentialWrapperMock } from "confidential-wrapper-pauser/mocks/ConfidentialWrapperMock.sol";
import { PermissiveFallbackMock } from "confidential-wrapper-pauser/mocks/PermissiveFallbackMock.sol";

/**
 * @title PauserTargets
 * @notice Shared vocabulary of the local property suites: the kinds of `pause()` target a batch can meet, how to
 * build one, what the pauser must report for it, and how to read the pauser's outcome events back. Used by the
 * fuzz tests directly and by the invariant handler.
 */
abstract contract PauserTargets {
    /// @dev Every behaviour a pause target can have, from the pauser's point of view. The registry gate decides
    /// whether the pauser calls a target at all: `Armed`, `Unarmed` and `Reverting` are listed as valid in the
    /// registry mock and are actually called; `NoCode`, `Permissive` and `Unregistered` are not listed, so they are
    /// reported as `WrapperNotRegistered` without a call. (A *registered* target without the pause API aborts the
    /// pauser instead of being reported; that accepted residual is pinned in PauserGasDrain.t.sol.)
    enum Kind {
        Armed, // ConfidentialWrapperMock whose pauser() is the pauser contract
        Unarmed, // ConfidentialWrapperMock armed with another address
        Reverting, // BrokenWrapperMock: paused() is false, pause() reverts without data
        NoCode, // an EOA-like address, not in the registry
        Permissive, // PermissiveFallbackMock (WETH-style): not in the registry, must never be called
        Unregistered // an armed ConfidentialWrapperMock the registry does not list (or a revoked one)
    }

    uint256 internal constant KIND_COUNT = 6;

    /// @dev What the pauser reported for one entry: one of its three outcome events.
    enum Result {
        Paused, // WrapperPaused
        AlreadyPaused, // WrapperAlreadyPaused
        Failed // WrapperPauseFailed
    }

    /// @dev Outcome of one batch entry as the pauser reported it.
    struct Outcome {
        Result result;
        address wrapper;
        bytes errorData;
    }

    address internal constant WRAPPER_OWNER = address(uint160(uint256(keccak256("wrapper-owner"))));

    /// @dev The registry every pauser under test is constructed with; registered targets list themselves here.
    /// Suites that build their own pauser create it here; the invariant handler receives the test's instance.
    ConfidentialTokenWrappersRegistryMock internal registry = new ConfidentialTokenWrappersRegistryMock();

    /// @dev Kind of every target this suite created (addresses without code are `NoCode`).
    mapping(address => Kind) internal kindOf;
    mapping(address => bool) internal known;

    // ----- Building targets -----

    function _deployTarget(ConfidentialWrapperPauser pauser, Kind kind, uint256 salt) internal returns (address t) {
        if (kind == Kind.Armed) {
            t = address(new ConfidentialWrapperMock(WRAPPER_OWNER, address(pauser)));
        } else if (kind == Kind.Unarmed) {
            t = address(new ConfidentialWrapperMock(WRAPPER_OWNER, WRAPPER_OWNER));
        } else if (kind == Kind.Reverting) {
            t = address(new BrokenWrapperMock());
        } else if (kind == Kind.NoCode) {
            t = address(uint160(uint256(keccak256(abi.encode("no-code", salt)))));
        } else if (kind == Kind.Permissive) {
            t = address(new PermissiveFallbackMock());
        } else {
            t = address(new ConfidentialWrapperMock(WRAPPER_OWNER, address(pauser)));
        }
        if (_isRegistered(kind)) registry.register(t);
        kindOf[t] = kind;
        known[t] = true;
    }

    /// @dev Whether targets of `kind` are listed as valid in the registry, i.e. whether the pauser calls them.
    function _isRegistered(Kind kind) internal pure returns (bool) {
        return kind == Kind.Armed || kind == Kind.Unarmed || kind == Kind.Reverting;
    }

    // ----- Expected behaviour -----

    /**
     * @dev What the pauser must report for `target` given the wrapper state `alreadyPaused` (only meaningful for
     * `Armed` targets). Mirrors the contract's documented outcome mapping, see {IConfidentialWrapperPauser}.
     */
    function _expectedOutcome(
        ConfidentialWrapperPauser pauser,
        address target,
        bool alreadyPaused
    ) internal view returns (Result result, bytes memory errorData) {
        Kind kind = kindOf[target];
        if (!_isRegistered(kind)) {
            return (
                Result.Failed,
                abi.encodeWithSelector(IConfidentialWrapperPauser.WrapperNotRegistered.selector, target)
            );
        }
        if (kind == Kind.Armed) {
            return (alreadyPaused ? Result.AlreadyPaused : Result.Paused, "");
        }
        if (kind == Kind.Unarmed) {
            return (
                Result.Failed,
                abi.encodeWithSelector(ConfidentialWrapperMock.SenderNotPauser.selector, address(pauser))
            );
        }
        // Reverting: the wrapper's own (empty) revert data.
        return (Result.Failed, "");
    }

    /// @dev True iff `paused()` on `target` returns exactly one 32-byte word equal to 1.
    function _reportsPaused(address target) internal view returns (bool) {
        (bool ok, bytes memory answer) = target.staticcall(abi.encodeWithSignature("paused()"));
        return ok && answer.length == 32 && abi.decode(answer, (uint256)) == 1;
    }

    // ----- Reading outcomes back -----

    /// @dev The WrapperPaused / WrapperAlreadyPaused / WrapperPauseFailed events `pauser` emitted among `logs`, in
    /// order.
    function _outcomes(address pauser, Vm.Log[] memory logs) internal pure returns (Outcome[] memory outcomes) {
        uint256 n = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (_isOutcome(pauser, logs[i])) n++;
        }
        outcomes = new Outcome[](n);
        uint256 k = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (!_isOutcome(pauser, logs[i])) continue;
            Result result = _resultOf(logs[i].topics[0]);
            outcomes[k++] = Outcome({
                result: result,
                wrapper: address(uint160(uint256(logs[i].topics[1]))),
                errorData: result == Result.Failed ? abi.decode(logs[i].data, (bytes)) : bytes("")
            });
        }
    }

    function _isOutcome(address pauser, Vm.Log memory log) private pure returns (bool) {
        if (log.emitter != pauser || log.topics.length != 2) return false;
        bytes32 topic = log.topics[0];
        return
            topic == IConfidentialWrapperPauser.WrapperPaused.selector ||
            topic == IConfidentialWrapperPauser.WrapperAlreadyPaused.selector ||
            topic == IConfidentialWrapperPauser.WrapperPauseFailed.selector;
    }

    function _resultOf(bytes32 topic) private pure returns (Result) {
        if (topic == IConfidentialWrapperPauser.WrapperPaused.selector) return Result.Paused;
        if (topic == IConfidentialWrapperPauser.WrapperAlreadyPaused.selector) return Result.AlreadyPaused;
        return Result.Failed;
    }

    /// @dev Number of `topic0` events `emitter` emitted among `logs`.
    function _countEvents(address emitter, bytes32 topic0, Vm.Log[] memory logs) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == topic0) n++;
        }
    }

    /// @dev Number of calls the WETH-style targets of `targets` received during `logs`: each call to a
    /// PermissiveFallbackMock writes one `Deposit` log, so this must stay zero while they are unregistered.
    function _permissiveCalls(address[] memory targets, Vm.Log[] memory logs) internal view returns (uint256 n) {
        for (uint256 i = 0; i < targets.length; i++) {
            if (!known[targets[i]] || kindOf[targets[i]] != Kind.Permissive) continue;
            n += _countEvents(targets[i], PermissiveFallbackMock.Deposit.selector, logs);
        }
    }
}
