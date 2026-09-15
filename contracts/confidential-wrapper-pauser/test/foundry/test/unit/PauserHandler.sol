// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { Vm } from "forge-std/Vm.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IAccessControlDefaultAdminRules } from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";

import { ConfidentialWrapperPauser } from "confidential-wrapper-pauser/ConfidentialWrapperPauser.sol";
import { IConfidentialWrapperPauser } from "confidential-wrapper-pauser/interfaces/IConfidentialWrapperPauser.sol";
import { ConfidentialTokenWrappersRegistryMock } from "confidential-wrapper-pauser/mocks/ConfidentialTokenWrappersRegistryMock.sol";
import { ConfidentialWrapperMock } from "confidential-wrapper-pauser/mocks/ConfidentialWrapperMock.sol";
import { PauserTargets } from "./PauserTargets.sol";

/**
 * @title PauserHandler
 * @notice Invariant handler over one {ConfidentialWrapperPauser} and a fixed pool of targets. Every action is a
 * plausible or hostile call some actor could make: roster changes by the admin and by outsiders, default-admin
 * transfers, delay changes, pauses through both forms by members and non-members, direct `pause()` attempts on the
 * wrappers, governance unpauses, and time passing. Each call is wrapped in `try` / `catch`, so it never reverts
 * itself (the suite runs with `fail_on_revert`); what it observes goes into ghost variables the invariants read.
 */
contract PauserHandler is CommonBase, StdCheats, StdUtils, PauserTargets {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint256 internal constant ACTORS = 6;
    uint256 internal constant ARMED = 4;
    uint256 internal constant MAX_BATCH = 8;

    ConfidentialWrapperPauser public immutable PAUSER;

    /// @dev Everyone who ever acts: the seeded admin, the seeded roster, and outsiders. Admin transfers and
    /// roster changes stay inside this pool, so the invariants can enumerate it.
    address[] public actors;
    /// @dev Every pause target, armed wrappers first (`targets[0 .. ARMED-1]`).
    address[] public targets;

    // ----- Ghost state -----

    /// @dev The default admin as the handler tracks it through transfers and renounce.
    address public ghostAdmin;
    bool public ghostAdminRenounced;
    mapping(address => bool) public ghostIsPauser;
    /// @dev Paused state of each armed wrapper as the handler tracks it from the pauser's events and unpauses.
    mapping(address => bool) public ghostPaused;

    uint256 public ghostAdminTransfers;
    uint256 public ghostRosterChangesByNonAdmin;
    uint256 public ghostUnexpectedReverts;
    uint256 public ghostDirectAdminGrants;
    uint256 public ghostPausesByNonMember;
    uint256 public ghostBatchReverts;
    uint256 public ghostFlipsByNonMember;
    uint256 public ghostUntruthfulPausedEvents;
    uint256 public ghostPausedEventsForNonWrappers;
    uint256 public ghostCallsToUnregistered;
    uint256 public ghostDirectWrapperPauses;
    uint256 public ghostOutcomeCountMismatches;
    uint256 public ghostWrapperPausedEvents;
    uint256 public ghostWrapperAlreadyPausedEvents;
    uint256 public ghostWrapperPauseFailedEvents;

    constructor(
        ConfidentialWrapperPauser pauser,
        ConfidentialTokenWrappersRegistryMock registry_,
        address admin,
        address[] memory roster,
        address[] memory others
    ) {
        PAUSER = pauser;
        registry = registry_;
        ghostAdmin = admin;
        actors.push(admin);
        for (uint256 i = 0; i < roster.length; i++) {
            actors.push(roster[i]);
            ghostIsPauser[roster[i]] = true;
        }
        for (uint256 i = 0; i < others.length; i++) actors.push(others[i]);

        for (uint256 i = 0; i < ARMED; i++) targets.push(_deployTarget(pauser, Kind.Armed, i));
        targets.push(_deployTarget(pauser, Kind.Unarmed, 0));
        targets.push(_deployTarget(pauser, Kind.Reverting, 0));
        targets.push(_deployTarget(pauser, Kind.NoCode, 0));
        targets.push(_deployTarget(pauser, Kind.Permissive, 0));
        targets.push(_deployTarget(pauser, Kind.Unregistered, 0));
    }

    // ----- Roster -----

    function addPauser(uint256 callerSeed, uint256 accountSeed, bool viaGrantRole, bool asAdmin) external {
        address caller = _caller(callerSeed, asAdmin);
        address account = _actor(accountSeed);
        vm.prank(caller);
        bool ok;
        if (viaGrantRole) {
            try PAUSER.grantRole(PAUSER_ROLE, account) {
                ok = true;
            } catch (bytes memory reason) {
                _expectUnauthorized(caller, reason);
            }
        } else {
            try PAUSER.addPauser(account) {
                ok = true;
            } catch (bytes memory reason) {
                _expectUnauthorized(caller, reason);
            }
        }
        if (ok) {
            if (!_isAdmin(caller)) ghostRosterChangesByNonAdmin++;
            ghostIsPauser[account] = true;
        }
    }

    function removePauser(uint256 callerSeed, uint256 accountSeed, bool viaRevokeRole, bool asAdmin) external {
        address caller = _caller(callerSeed, asAdmin);
        address account = _actor(accountSeed);
        vm.prank(caller);
        bool ok;
        if (viaRevokeRole) {
            try PAUSER.revokeRole(PAUSER_ROLE, account) {
                ok = true;
            } catch (bytes memory reason) {
                _expectUnauthorized(caller, reason);
            }
        } else {
            try PAUSER.removePauser(account) {
                ok = true;
            } catch (bytes memory reason) {
                _expectUnauthorized(caller, reason);
            }
        }
        if (ok) {
            if (!_isAdmin(caller)) ghostRosterChangesByNonAdmin++;
            ghostIsPauser[account] = false;
        }
    }

    /// @dev A member steps down; for anyone else this is the OZ no-op.
    function renouncePauser(uint256 actorSeed) external {
        address account = _actor(actorSeed);
        vm.prank(account);
        try PAUSER.renounceRole(PAUSER_ROLE, account) {
            ghostIsPauser[account] = false;
        } catch {
            ghostUnexpectedReverts++;
        }
    }

    /// @dev Nobody, the admin included, grants or revokes DEFAULT_ADMIN_ROLE directly.
    function grantDefaultAdminDirectly(uint256 callerSeed, uint256 accountSeed, bool revoke) external {
        address caller = _actor(callerSeed);
        address account = _actor(accountSeed);
        vm.prank(caller);
        if (revoke) {
            try PAUSER.revokeRole(DEFAULT_ADMIN_ROLE, account) {
                ghostDirectAdminGrants++;
            } catch (bytes memory reason) {
                _expectEnforcedRules(reason);
            }
        } else {
            try PAUSER.grantRole(DEFAULT_ADMIN_ROLE, account) {
                ghostDirectAdminGrants++;
            } catch (bytes memory reason) {
                _expectEnforcedRules(reason);
            }
        }
    }

    // ----- Default admin -----

    function beginAdminTransfer(uint256 callerSeed, uint256 newAdminSeed, bool toZero, bool asAdmin) external {
        address caller = _caller(callerSeed, asAdmin);
        address newAdmin = toZero ? address(0) : _actor(newAdminSeed);
        vm.prank(caller);
        try PAUSER.beginDefaultAdminTransfer(newAdmin) {
            if (!_isAdmin(caller)) ghostRosterChangesByNonAdmin++;
        } catch (bytes memory reason) {
            _expectUnauthorized(caller, reason);
        }
    }

    function cancelAdminTransfer(uint256 callerSeed, bool asAdmin) external {
        address caller = _caller(callerSeed, asAdmin);
        vm.prank(caller);
        try PAUSER.cancelDefaultAdminTransfer() {
            if (!_isAdmin(caller)) ghostRosterChangesByNonAdmin++;
        } catch (bytes memory reason) {
            _expectUnauthorized(caller, reason);
        }
    }

    /// @dev The pending admin accepts (or, for a transfer to the zero address, the admin renounces). Either only
    /// works once the schedule has passed, which `matured` jumps to half of the time; the ghost admin follows.
    function acceptAdminTransfer(uint256 callerSeed, bool asPending, bool matured) external {
        (address pending, uint48 schedule) = PAUSER.pendingDefaultAdmin();
        if (matured && schedule != 0 && block.timestamp <= schedule) vm.warp(uint256(schedule) + 1);
        if (pending == address(0)) {
            if (ghostAdminRenounced) return;
            vm.prank(ghostAdmin);
            try PAUSER.renounceRole(DEFAULT_ADMIN_ROLE, ghostAdmin) {
                ghostAdminRenounced = true;
                ghostAdmin = address(0);
                ghostAdminTransfers++;
            } catch (bytes memory reason) {
                _expectSelector(
                    reason,
                    IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector
                );
            }
            return;
        }
        address caller = asPending ? pending : _actor(callerSeed);
        vm.prank(caller);
        try PAUSER.acceptDefaultAdminTransfer() {
            if (caller != pending) ghostRosterChangesByNonAdmin++;
            ghostAdmin = pending;
            ghostAdminTransfers++;
        } catch (bytes memory reason) {
            bytes4 selector = _selector(reason);
            bool expected =
                caller != pending
                    ? selector == IAccessControlDefaultAdminRules.AccessControlInvalidDefaultAdmin.selector
                    : selector == IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector;
            if (!expected) ghostUnexpectedReverts++;
        }
    }

    function changeAdminDelay(uint256 callerSeed, uint48 rawDelay, bool rollback, bool asAdmin) external {
        address caller = _caller(callerSeed, asAdmin);
        uint48 newDelay = uint48(bound(rawDelay, 0, 10 days));
        vm.prank(caller);
        if (rollback) {
            try PAUSER.rollbackDefaultAdminDelay() {
                if (!_isAdmin(caller)) ghostRosterChangesByNonAdmin++;
            } catch (bytes memory reason) {
                _expectUnauthorized(caller, reason);
            }
        } else {
            try PAUSER.changeDefaultAdminDelay(newDelay) {
                if (!_isAdmin(caller)) ghostRosterChangesByNonAdmin++;
            } catch (bytes memory reason) {
                _expectUnauthorized(caller, reason);
            }
        }
    }

    function warp(uint32 rawSeconds) external {
        vm.warp(block.timestamp + bound(rawSeconds, 1, 3 days));
    }

    // ----- Circuit breaker -----

    function pauseOne(uint256 callerSeed, uint256 targetSeed, bool asMember) external {
        address caller = _pauseCaller(callerSeed, asMember);
        address target = targets[targetSeed % targets.length];
        bool member = PAUSER.isPauser(caller);
        bool[] memory before = _snapshotArmed();

        vm.recordLogs();
        vm.prank(caller);
        bool ok;
        try PAUSER.pause(target) {
            ok = true;
        } catch (bytes memory reason) {
            bytes4 selector = _selector(reason);
            if (member && selector != IConfidentialWrapperPauser.PauseFailed.selector) ghostUnexpectedReverts++;
            if (!member && selector != IConfidentialWrapperPauser.SenderNotPauser.selector) ghostUnexpectedReverts++;
        }
        if (ok && !member) ghostPausesByNonMember++;
        _digest(member, before, ok ? 1 : 0);
    }

    function pauseBatch(uint256 callerSeed, uint256 seed, uint8 rawLen, bool asMember) external {
        address caller = _pauseCaller(callerSeed, asMember);
        uint256 len = bound(rawLen, 0, MAX_BATCH);
        address[] memory batch = new address[](len);
        for (uint256 i = 0; i < len; i++) {
            batch[i] = targets[uint256(keccak256(abi.encode(seed, i))) % targets.length];
        }
        bool member = PAUSER.isPauser(caller);
        bool[] memory before = _snapshotArmed();

        vm.recordLogs();
        vm.prank(caller);
        bool ok;
        try PAUSER.pause(batch) {
            ok = true;
        } catch (bytes memory reason) {
            if (member) ghostBatchReverts++;
            if (!member && _selector(reason) != IConfidentialWrapperPauser.SenderNotPauser.selector) {
                ghostUnexpectedReverts++;
            }
        }
        if (ok && !member) ghostPausesByNonMember++;
        _digest(member, before, ok ? len : 0);
    }

    /// @dev Anyone calling `pause()` on an armed wrapper directly: only the pauser contract may.
    function pauseWrapperDirectly(uint256 callerSeed, uint256 wrapperSeed) external {
        address caller = _actor(callerSeed);
        ConfidentialWrapperMock wrapper = ConfidentialWrapperMock(targets[wrapperSeed % ARMED]);
        vm.prank(caller);
        try wrapper.pause() {
            ghostDirectWrapperPauses++;
            ghostPaused[address(wrapper)] = true;
        } catch (bytes memory reason) {
            _expectSelector(reason, ConfidentialWrapperMock.SenderNotPauser.selector);
        }
    }

    /// @dev Governance restores a wrapper, so pausing can happen again in the same sequence.
    function unpauseWrapper(uint256 wrapperSeed) external {
        ConfidentialWrapperMock wrapper = ConfidentialWrapperMock(targets[wrapperSeed % ARMED]);
        if (!wrapper.paused()) return;
        vm.prank(WRAPPER_OWNER);
        try wrapper.unpause() {
            ghostPaused[address(wrapper)] = false;
        } catch {
            ghostUnexpectedReverts++;
        }
    }

    /// @dev The registry owner revokes or re-registers an armed wrapper; a revoked one must never be paused.
    function toggleRegistration(uint256 wrapperSeed, bool valid) external {
        address wrapper = targets[wrapperSeed % ARMED];
        if (valid) registry.register(wrapper);
        else registry.revoke(wrapper);
    }

    // ----- Views for the invariants -----

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function armedCount() external pure returns (uint256) {
        return ARMED;
    }

    function targetCount() external view returns (uint256) {
        return targets.length;
    }

    function isArmed(address target) external view returns (bool) {
        return known[target] && kindOf[target] == Kind.Armed;
    }

    // ----- Internals -----

    /// @dev Reads the pauser's outcome events of the call just made and checks them against the wrappers.
    function _digest(bool member, bool[] memory before, uint256 expectedOutcomes) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Outcome[] memory outcomes = _outcomes(address(PAUSER), logs);
        if (outcomes.length != expectedOutcomes) ghostOutcomeCountMismatches++;
        ghostCallsToUnregistered += _permissiveCalls(targets, logs);
        for (uint256 i = 0; i < outcomes.length; i++) {
            if (outcomes[i].result == Result.Failed) {
                ghostWrapperPauseFailedEvents++;
                continue;
            }
            if (outcomes[i].result == Result.Paused) ghostWrapperPausedEvents++;
            else ghostWrapperAlreadyPausedEvents++;
            address w = outcomes[i].wrapper;
            if (!_reportsPaused(w)) ghostUntruthfulPausedEvents++;
            if (!(known[w] && kindOf[w] == Kind.Armed)) ghostPausedEventsForNonWrappers++;
            else if (!registry.isConfidentialTokenValid(w)) ghostPausedEventsForNonWrappers++;
            else ghostPaused[w] = true;
        }
        for (uint256 i = 0; i < ARMED; i++) {
            bool now_ = ConfidentialWrapperMock(targets[i]).paused();
            if (now_ && !before[i] && !member) ghostFlipsByNonMember++;
        }
    }

    function _snapshotArmed() internal view returns (bool[] memory before) {
        before = new bool[](ARMED);
        for (uint256 i = 0; i < ARMED; i++) before[i] = ConfidentialWrapperMock(targets[i]).paused();
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Half of the admin-only calls come from the admin, so both the happy path and the refusals are covered.
    function _caller(uint256 seed, bool asAdmin) internal view returns (address) {
        return asAdmin && !ghostAdminRenounced ? ghostAdmin : _actor(seed);
    }

    /// @dev Half of the pause calls come from a current roster member, when there is one.
    function _pauseCaller(uint256 seed, bool asMember) internal view returns (address) {
        address[] memory members = PAUSER.pausers();
        return asMember && members.length > 0 ? members[seed % members.length] : _actor(seed);
    }

    function _isAdmin(address account) internal view returns (bool) {
        return !ghostAdminRenounced && account == ghostAdmin;
    }

    function _selector(bytes memory reason) internal pure returns (bytes4 selector) {
        if (reason.length < 4) return 0;
        assembly {
            selector := mload(add(reason, 32))
        }
    }

    function _expectSelector(bytes memory reason, bytes4 expected) internal {
        if (_selector(reason) != expected) ghostUnexpectedReverts++;
    }

    /// @dev A refused admin-only call must come from a non-admin and carry AccessControlUnauthorizedAccount.
    function _expectUnauthorized(address caller, bytes memory reason) internal {
        if (_isAdmin(caller)) ghostUnexpectedReverts++;
        _expectSelector(reason, IAccessControl.AccessControlUnauthorizedAccount.selector);
    }

    function _expectEnforcedRules(bytes memory reason) internal {
        _expectSelector(reason, IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector);
    }
}
