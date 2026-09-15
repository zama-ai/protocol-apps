// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import { Test, Vm } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IAccessControlDefaultAdminRules } from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";

import { ConfidentialWrapperPauser } from "confidential-wrapper-pauser/ConfidentialWrapperPauser.sol";
import { IConfidentialTokenWrappersRegistry } from "confidential-wrapper-pauser/interfaces/IConfidentialTokenWrappersRegistry.sol";
import { IConfidentialWrapperPauser } from "confidential-wrapper-pauser/interfaces/IConfidentialWrapperPauser.sol";
import { ConfidentialWrapperMock } from "confidential-wrapper-pauser/mocks/ConfidentialWrapperMock.sol";
import { PauserTargets } from "./PauserTargets.sol";

/**
 * @title PauserFuzzTest
 * @notice Property tests of {ConfidentialWrapperPauser} over the package mocks, no fork: the roster follows any
 * add / remove sequence, the batch form reports exactly one outcome per entry and never reverts whatever the
 * targets are, the single form agrees with the batch form entry by entry, and the constructor seeds any roster.
 * Runs with `make unit-test`.
 */
contract PauserFuzzTest is Test, PauserTargets {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    uint48 internal constant ADMIN_DELAY = 1 days;
    uint256 internal constant POOL = 8;
    uint256 internal constant MAX_BATCH = 24;

    address internal admin = makeAddr("admin");
    address internal fb1 = makeAddr("roster-member-1");
    address internal fb2 = makeAddr("roster-member-2");
    address[] internal pool;

    ConfidentialWrapperPauser internal pauser;

    function setUp() public {
        address[] memory roster = new address[](2);
        roster[0] = fb1;
        roster[1] = fb2;
        pauser = new ConfidentialWrapperPauser(ADMIN_DELAY, admin, registry, roster);
        for (uint256 i = 0; i < POOL; i++) {
            pool.push(makeAddr(string.concat("candidate-", vm.toString(i))));
        }
    }

    // ----- Roster -----

    /// @notice Any sequence of add / remove / raw grant / raw revoke / renounce leaves `pausers()` equal to the
    /// expectedMember set, with one PauserAdded / PauserRemoved per actual change and `isPauser` in agreement.
    function testFuzz_RosterFollowsAnyAddRemoveSequence(uint256 seed, uint8 rawOps) public {
        uint256 ops = bound(rawOps, 0, 48);
        bool[] memory expectedMember = new bool[](POOL);
        uint256 expectedAdds;
        uint256 expectedRemoves;

        vm.recordLogs();
        for (uint256 i = 0; i < ops; i++) {
            uint256 word = uint256(keccak256(abi.encode(seed, i)));
            uint256 idx = word % POOL;
            uint256 op = (word >> 8) % 5;
            address account = pool[idx];

            if (op == 0) {
                vm.prank(admin);
                pauser.addPauser(account);
                if (!expectedMember[idx]) expectedAdds++;
                expectedMember[idx] = true;
            } else if (op == 1) {
                vm.prank(admin);
                pauser.removePauser(account);
                if (expectedMember[idx]) expectedRemoves++;
                expectedMember[idx] = false;
            } else if (op == 2) {
                vm.prank(admin);
                pauser.grantRole(PAUSER_ROLE, account);
                if (!expectedMember[idx]) expectedAdds++;
                expectedMember[idx] = true;
            } else if (op == 3) {
                vm.prank(admin);
                pauser.revokeRole(PAUSER_ROLE, account);
                if (expectedMember[idx]) expectedRemoves++;
                expectedMember[idx] = false;
            } else {
                vm.prank(account);
                pauser.renounceRole(PAUSER_ROLE, account);
                if (expectedMember[idx]) expectedRemoves++;
                expectedMember[idx] = false;
            }
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(
            _countEvents(address(pauser), IConfidentialWrapperPauser.PauserAdded.selector, logs),
            expectedAdds,
            "PauserAdded count"
        );
        assertEq(
            _countEvents(address(pauser), IConfidentialWrapperPauser.PauserRemoved.selector, logs),
            expectedRemoves,
            "PauserRemoved count"
        );
        assertEq(
            _countEvents(address(pauser), IAccessControl.RoleGranted.selector, logs),
            expectedAdds,
            "RoleGranted count"
        );
        assertEq(
            _countEvents(address(pauser), IAccessControl.RoleRevoked.selector, logs),
            expectedRemoves,
            "RoleRevoked count"
        );

        // The two seeded members were never touched.
        uint256 expectedCount = 2;
        for (uint256 i = 0; i < POOL; i++) {
            assertEq(pauser.isPauser(pool[i]), expectedMember[i], "isPauser vs expectedMember");
            if (expectedMember[i]) expectedCount++;
        }
        _assertRosterConsistent(expectedCount);
    }

    /// @notice Nobody but the default admin changes the roster, through any of the four entry points, and
    /// `DEFAULT_ADMIN_ROLE` itself is never granted or revoked directly, not even by the admin.
    function testFuzz_OnlyAdminManagesRoster(address caller, address account) public {
        vm.assume(caller != admin);
        bytes memory unauthorized = abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            caller,
            DEFAULT_ADMIN_ROLE
        );

        vm.prank(caller);
        vm.expectRevert(unauthorized);
        pauser.addPauser(account);
        vm.prank(caller);
        vm.expectRevert(unauthorized);
        pauser.removePauser(account);
        vm.prank(caller);
        vm.expectRevert(unauthorized);
        pauser.grantRole(PAUSER_ROLE, account);
        vm.prank(caller);
        vm.expectRevert(unauthorized);
        pauser.revokeRole(PAUSER_ROLE, account);

        bytes memory enforced = abi.encodeWithSelector(
            IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector
        );
        vm.prank(admin);
        vm.expectRevert(enforced);
        pauser.grantRole(DEFAULT_ADMIN_ROLE, account);
        vm.prank(admin);
        vm.expectRevert(enforced);
        pauser.revokeRole(DEFAULT_ADMIN_ROLE, admin);
        vm.prank(caller);
        vm.expectRevert(enforced);
        pauser.grantRole(DEFAULT_ADMIN_ROLE, caller);

        _assertRosterConsistent(2);
        assertEq(pauser.owner(), admin);
    }

    // ----- Circuit breaker -----

    /// @notice Nobody off the roster pauses anything, through either form, whatever the target.
    function testFuzz_OnlyRosterMembersPause(address caller, uint256 seed) public {
        vm.assume(caller != fb1 && caller != fb2);
        address target = _deployTarget(pauser, Kind(seed % KIND_COUNT), seed);
        address[] memory batch = new address[](1);
        batch[0] = target;
        bytes memory expected = abi.encodeWithSelector(IConfidentialWrapperPauser.SenderNotPauser.selector, caller);

        vm.prank(caller);
        vm.expectRevert(expected);
        pauser.pause(target);
        vm.prank(caller);
        vm.expectRevert(expected);
        pauser.pause(batch);
        if (kindOf[target] == Kind.Armed) assertFalse(ConfidentialWrapperMock(target).paused(), "paused by outsider");
    }

    /**
     * @notice The batch form never reverts and reports exactly one outcome per entry, in order, over any mix of
     * armed, unarmed, already-paused, reverting and unregistered (code-less, WETH-style, revoked) targets,
     * duplicates included; WrapperPaused is emitted iff the target now reports `paused() == true`, and an
     * unregistered target is never called.
     */
    function testFuzz_BatchReportsOneOutcomePerEntryAndNeverReverts(uint256 seed, uint8 rawLen) public {
        uint256 len = bound(rawLen, 0, MAX_BATCH);
        address[] memory batch = new address[](len);
        Result[] memory expectedResult = new Result[](len);
        bytes[] memory expectedError = new bytes[](len);
        uint256 distinct;

        // Build the batch: each slot is either a fresh target of a random kind (armed ones sometimes paused up
        // front) or a duplicate of an earlier slot, and walk the pauser's expected state alongside.
        for (uint256 i = 0; i < len; i++) {
            uint256 word = uint256(keccak256(abi.encode(seed, i)));
            if (i > 0 && word % 4 == 0) {
                batch[i] = batch[(word >> 8) % i];
            } else {
                batch[i] = _deployTarget(pauser, Kind((word >> 16) % KIND_COUNT), word);
                distinct++;
                if (kindOf[batch[i]] == Kind.Armed && (word >> 24) % 3 == 0) {
                    vm.prank(fb2);
                    pauser.pause(batch[i]);
                }
            }
        }
        for (uint256 i = 0; i < len; i++) {
            bool alreadyPaused = kindOf[batch[i]] == Kind.Armed && _pausedInSimulation(batch, i);
            (expectedResult[i], expectedError[i]) = _expectedOutcome(pauser, batch[i], alreadyPaused);
        }

        vm.recordLogs();
        vm.prank(fb1);
        pauser.pause(batch); // the RFC property: never reverts
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Outcome[] memory outcomes = _outcomes(address(pauser), logs);

        assertEq(outcomes.length, len, "one outcome per entry");
        for (uint256 i = 0; i < len; i++) {
            string memory at = string.concat("entry ", vm.toString(i));
            assertEq(outcomes[i].wrapper, batch[i], string.concat(at, ": wrapper"));
            assertEq(uint256(outcomes[i].result), uint256(expectedResult[i]), string.concat(at, ": outcome"));
            assertEq(outcomes[i].errorData, expectedError[i], string.concat(at, ": errorData"));
            bool reportedHalted = outcomes[i].result != Result.Failed;
            if (reportedHalted) assertTrue(_reportsPaused(batch[i]), string.concat(at, ": paused() after"));
            if (kindOf[batch[i]] == Kind.Armed) assertTrue(_reportsPaused(batch[i]), string.concat(at, ": armed"));
            if (kindOf[batch[i]] != Kind.Armed) assertFalse(reportedHalted, string.concat(at, ": false success"));
        }
        assertEq(_permissiveCalls(batch, logs), 0, "unregistered WETH-style target was called");
        assertGe(len, distinct);
    }

    /// @notice The single form reverts with `PauseFailed(target, errorData)` exactly when the batch form reports
    /// `WrapperPauseFailed(target, errorData)` for the same target in the same state, and otherwise emits the same
    /// `WrapperPaused` / `WrapperAlreadyPaused` event the batch form does.
    function testFuzz_SingleFormAgreesWithBatchForm(uint256 seed) public {
        address target = _deployTarget(pauser, Kind(seed % KIND_COUNT), seed);
        if (kindOf[target] == Kind.Armed && (seed >> 8) % 2 == 0) {
            vm.prank(fb2);
            pauser.pause(target);
        }
        address[] memory batch = new address[](1);
        batch[0] = target;

        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        vm.prank(fb1);
        pauser.pause(batch);
        Outcome[] memory outcomes = _outcomes(address(pauser), vm.getRecordedLogs());
        assertEq(outcomes.length, 1);
        assertTrue(vm.revertToState(snapshot));

        if (outcomes[0].result == Result.Paused) {
            vm.expectEmit(true, false, false, true, address(pauser));
            emit IConfidentialWrapperPauser.WrapperPaused(target);
        } else if (outcomes[0].result == Result.AlreadyPaused) {
            vm.expectEmit(true, false, false, true, address(pauser));
            emit IConfidentialWrapperPauser.WrapperAlreadyPaused(target);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(IConfidentialWrapperPauser.PauseFailed.selector, target, outcomes[0].errorData)
            );
        }
        vm.prank(fb1);
        pauser.pause(target);
        assertEq(_reportsPaused(target), kindOf[target] == Kind.Armed, "state after single");
        if (!_isRegistered(kindOf[target])) assertFalse(_reportsPaused(target), "unregistered never called");
    }

    // ----- Constructor and default admin -----

    /// @notice Any delay, admin and roster (duplicates included) deploys with the admin as sole default admin and
    /// owner, the roster deduplicated in first-seen order and one PauserAdded per distinct member.
    function testFuzz_ConstructorSeedsAnyRoster(uint48 delay, address newAdmin, uint256 seed, uint8 rawLen) public {
        vm.assume(newAdmin != address(0));
        address[] memory roster = new address[](bound(rawLen, 0, 16));
        for (uint256 i = 0; i < roster.length; i++) {
            roster[i] = pool[uint256(keccak256(abi.encode(seed, i))) % POOL];
        }

        vm.recordLogs();
        ConfidentialWrapperPauser deployed = new ConfidentialWrapperPauser(delay, newAdmin, registry, roster);
        uint256 added = _countEvents(
            address(deployed),
            IConfidentialWrapperPauser.PauserAdded.selector,
            vm.getRecordedLogs()
        );

        _assertFreshAdmin(deployed, newAdmin, delay);

        address[] memory expected = _dedupe(roster);
        address[] memory members = deployed.pausers();
        assertEq(members.length, expected.length, "roster length");
        assertEq(added, expected.length, "PauserAdded count");
        for (uint256 i = 0; i < expected.length; i++) {
            assertEq(members[i], expected[i], "roster order");
            assertTrue(deployed.isPauser(expected[i]));
        }
        assertEq(deployed.isPauser(newAdmin), _contains(expected, newAdmin), "admin on roster only if seeded");
        assertEq(address(deployed.registry()), address(registry), "registry");
    }

    /// @notice A registry address without code is never accepted, whatever the other inputs.
    function testFuzz_ConstructorRejectsCodelessRegistry(uint48 delay, address bogusRegistry) public {
        vm.assume(bogusRegistry.code.length == 0);
        address[] memory roster = new address[](1);
        roster[0] = fb1;
        vm.expectRevert(abi.encodeWithSelector(IConfidentialWrapperPauser.InvalidRegistry.selector, bogusRegistry));
        new ConfidentialWrapperPauser(delay, admin, IConfidentialTokenWrappersRegistry(bogusRegistry), roster);
    }

    /// @notice The zero address is never accepted as the initial admin, whatever the delay and roster.
    function testFuzz_ConstructorRejectsZeroAdmin(uint48 delay, uint8 rawLen) public {
        address[] memory roster = new address[](bound(rawLen, 0, 4));
        for (uint256 i = 0; i < roster.length; i++) roster[i] = pool[i];
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlInvalidDefaultAdmin.selector,
                address(0)
            )
        );
        new ConfidentialWrapperPauser(delay, address(0), registry, roster);
    }

    /// @notice A delay change waits `min(newDelay, 5 days)` when raising and `current - newDelay` when lowering,
    /// then governs the next transfer; the roster is untouched throughout.
    function testFuzz_DelayChangeFollowsDefaultAdminRules(uint48 rawInitial, uint48 rawNew) public {
        uint48 initial = uint48(bound(rawInitial, 0, 30 days));
        uint48 newDelay = uint48(bound(rawNew, 0, 365 days));
        address[] memory roster = new address[](1);
        roster[0] = fb1;
        ConfidentialWrapperPauser deployed = new ConfidentialWrapperPauser(initial, admin, registry, roster);
        uint48 schedule = uint48(block.timestamp) + _expectedDelayWait(deployed, initial, newDelay);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(deployed));
        emit IAccessControlDefaultAdminRules.DefaultAdminDelayChangeScheduled(newDelay, schedule);
        deployed.changeDefaultAdminDelay(newDelay);

        _assertPendingDelay(deployed, newDelay, schedule);
        assertEq(deployed.defaultAdminDelay(), initial, "delay before schedule");

        vm.warp(uint256(schedule) + 1);
        assertEq(deployed.defaultAdminDelay(), newDelay, "delay after schedule");
        _assertPendingDelay(deployed, 0, 0);

        vm.prank(admin);
        deployed.beginDefaultAdminTransfer(fb2);
        (address pendingAdmin, uint48 transferSchedule) = deployed.pendingDefaultAdmin();
        assertEq(pendingAdmin, fb2);
        assertEq(transferSchedule, uint48(block.timestamp) + newDelay);

        address[] memory members = deployed.pausers();
        assertEq(members.length, 1);
        assertEq(members[0], fb1);
    }

    // ----- Helpers -----

    /// @dev The wait `AccessControlDefaultAdminRules` applies to a delay change from `current` to `next`.
    function _expectedDelayWait(
        ConfidentialWrapperPauser deployed,
        uint48 current,
        uint48 next
    ) internal view returns (uint48) {
        if (next <= current) return current - next;
        uint48 cap = deployed.defaultAdminDelayIncreaseWait();
        return next < cap ? next : cap;
    }

    function _assertPendingDelay(ConfidentialWrapperPauser deployed, uint48 delay, uint48 schedule) internal view {
        (uint48 pendingDelay, uint48 pendingSchedule) = deployed.pendingDefaultAdminDelay();
        assertEq(pendingDelay, delay, "pending delay");
        assertEq(pendingSchedule, schedule, "pending delay schedule");
    }

    /// @dev Whether `batch[i]` (an armed wrapper) is paused when the pauser reaches slot `i`: either it was paused
    /// before the batch, or an earlier slot of the same batch names it.
    function _pausedInSimulation(address[] memory batch, uint256 i) internal view returns (bool) {
        if (ConfidentialWrapperMock(batch[i]).paused()) return true;
        for (uint256 j = 0; j < i; j++) {
            if (batch[j] == batch[i]) return true;
        }
        return false;
    }

    function _assertRosterConsistent(uint256 expectedCount) internal view {
        address[] memory members = pauser.pausers();
        assertEq(members.length, expectedCount, "roster length");
        assertEq(pauser.getRoleMemberCount(PAUSER_ROLE), expectedCount, "member count");
        for (uint256 i = 0; i < members.length; i++) {
            assertTrue(pauser.isPauser(members[i]), "member not isPauser");
            assertTrue(pauser.hasRole(PAUSER_ROLE, members[i]), "member without role");
            assertEq(pauser.getRoleMember(PAUSER_ROLE, i), members[i], "getRoleMember order");
            assertNotEq(members[i], address(0), "zero member");
            for (uint256 j = i + 1; j < members.length; j++) {
                assertNotEq(members[i], members[j], "duplicate member");
            }
        }
    }

    function _contains(address[] memory list, address account) internal pure returns (bool) {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == account) return true;
        }
        return false;
    }

    /// @dev `list` without repeats, keeping the first occurrence of each address in place.
    function _dedupe(address[] memory list) internal pure returns (address[] memory unique) {
        address[] memory scratch = new address[](list.length);
        uint256 n;
        for (uint256 i = 0; i < list.length; i++) {
            bool seen;
            for (uint256 j = 0; j < n; j++) {
                if (scratch[j] == list[i]) seen = true;
            }
            if (!seen) scratch[n++] = list[i];
        }
        unique = new address[](n);
        for (uint256 i = 0; i < n; i++) unique[i] = scratch[i];
    }

    /// @dev The default-admin state right after construction.
    function _assertFreshAdmin(ConfidentialWrapperPauser deployed, address expectedAdmin, uint48 delay) internal view {
        assertEq(deployed.owner(), expectedAdmin);
        assertEq(deployed.defaultAdmin(), expectedAdmin);
        assertTrue(deployed.hasRole(DEFAULT_ADMIN_ROLE, expectedAdmin));
        assertEq(deployed.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1);
        assertEq(deployed.defaultAdminDelay(), delay);
        (address pendingAdmin, uint48 schedule) = deployed.pendingDefaultAdmin();
        assertEq(pendingAdmin, address(0));
        assertEq(schedule, 0);
        _assertPendingDelay(deployed, 0, 0);
        assertEq(deployed.getRoleAdmin(PAUSER_ROLE), DEFAULT_ADMIN_ROLE);
    }
}
