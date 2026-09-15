// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";

import { ConfidentialWrapperPauser } from "confidential-wrapper-pauser/ConfidentialWrapperPauser.sol";
import { ConfidentialTokenWrappersRegistryMock } from "confidential-wrapper-pauser/mocks/ConfidentialTokenWrappersRegistryMock.sol";
import { ConfidentialWrapperMock } from "confidential-wrapper-pauser/mocks/ConfidentialWrapperMock.sol";
import { PauserHandler } from "./PauserHandler.sol";

/**
 * @title PauserHandlerTest
 * @notice Self-test of {PauserHandler}: a scripted sequence proves every path the invariant suite relies on is
 * live (admin adds and removes, member and non-member pauses through both forms, a matured admin transfer, a
 * renounce) and moves the ghost counters the invariants read. Without it a handler that silently never reached a
 * path would make the invariants vacuous.
 */
contract PauserHandlerTest is Test {
    ConfidentialWrapperPauser internal pauser;
    PauserHandler internal handler;
    address internal admin = makeAddr("admin");
    address internal fb1 = makeAddr("roster-member-1");
    address internal fb2 = makeAddr("roster-member-2");
    address internal outsider = makeAddr("outsider-1");

    function setUp() public {
        address[] memory roster = new address[](2);
        roster[0] = fb1;
        roster[1] = fb2;
        address[] memory others = new address[](1);
        others[0] = outsider;
        ConfidentialTokenWrappersRegistryMock registry = new ConfidentialTokenWrappersRegistryMock();
        pauser = new ConfidentialWrapperPauser(1 days, admin, registry, roster);
        handler = new PauserHandler(pauser, registry, admin, roster, others);
    }

    function test_HandlerReachesEveryPath() public {
        // actors = [admin, fb1, fb2, outsider]
        handler.addPauser(0, 3, false, true);
        assertTrue(pauser.isPauser(outsider), "admin add");
        handler.removePauser(0, 3, true, true);
        assertFalse(pauser.isPauser(outsider), "admin revoke");
        handler.addPauser(3, 3, false, false); // outsider refused
        assertFalse(pauser.isPauser(outsider), "outsider add refused");
        handler.renouncePauser(2);
        assertFalse(pauser.isPauser(fb2), "renounce");
        handler.grantDefaultAdminDirectly(0, 3, false);
        handler.grantDefaultAdminDirectly(0, 0, true);

        // Pauses: member batches over the target pool, a non-member attempt, a direct wrapper call.
        handler.pauseBatch(0, 7, 8, true);
        handler.pauseBatch(0, 11, 8, true);
        assertGt(handler.ghostWrapperPausedEvents(), 0, "member batches paused something");
        assertGt(handler.ghostWrapperPauseFailedEvents(), 0, "member batches reported failures");
        handler.pauseOne(3, 0, false); // outsider
        handler.pauseWrapperDirectly(3, 0);
        handler.unpauseWrapper(0);
        handler.pauseOne(0, 0, true); // member, armed wrapper 0 again
        assertTrue(ConfidentialWrapperMock(handler.targets(0)).paused(), "member single pause");
        uint256 alreadyPausedBefore = handler.ghostWrapperAlreadyPausedEvents();
        handler.pauseOne(0, 0, true); // member, wrapper 0 a third time: already paused, reported, no revert
        assertEq(handler.ghostWrapperAlreadyPausedEvents(), alreadyPausedBefore + 1, "already-paused report");
        handler.unpauseWrapper(1);
        handler.toggleRegistration(1, false); // governance revokes wrapper 1
        handler.pauseOne(0, 1, true); // member: WrapperNotRegistered, expected PauseFailed
        assertFalse(ConfidentialWrapperMock(handler.targets(1)).paused(), "revoked wrapper not paused");
        handler.toggleRegistration(1, true);
        handler.pauseOne(0, 1, true);
        assertTrue(ConfidentialWrapperMock(handler.targets(1)).paused(), "re-registered wrapper paused");

        // Delay change then a matured admin transfer to the outsider, then a renounce by the new admin.
        handler.changeAdminDelay(0, 2 days, false, true);
        handler.warp(uint32(3 days));
        assertEq(pauser.defaultAdminDelay(), 2 days, "delay change applied");
        handler.beginAdminTransfer(0, 3, false, true);
        handler.acceptAdminTransfer(0, true, false); // too early
        assertEq(pauser.owner(), admin, "transfer not yet accepted");
        handler.acceptAdminTransfer(0, true, true); // matured
        assertEq(pauser.owner(), outsider, "transfer accepted");
        assertEq(handler.ghostAdmin(), outsider, "ghost admin follows");
        handler.cancelAdminTransfer(0, true); // nothing pending: OZ no-op, still admin-only
        handler.beginAdminTransfer(0, 0, true, true);
        handler.acceptAdminTransfer(0, true, true);
        assertTrue(handler.ghostAdminRenounced(), "renounced");
        assertEq(pauser.owner(), address(0), "owner after renounce");
        assertEq(handler.ghostAdminTransfers(), 2, "two admin changes");
        handler.addPauser(0, 3, false, true); // nobody is admin any more
        assertFalse(pauser.isPauser(outsider), "roster frozen after renounce");

        // Every refusal above was one the handler expected, and nothing slipped through.
        assertEq(handler.ghostUnexpectedReverts(), 0, "unexpected reverts");
        assertEq(handler.ghostRosterChangesByNonAdmin(), 0);
        assertEq(handler.ghostDirectAdminGrants(), 0);
        assertEq(handler.ghostPausesByNonMember(), 0);
        assertEq(handler.ghostFlipsByNonMember(), 0);
        assertEq(handler.ghostDirectWrapperPauses(), 0);
        assertEq(handler.ghostBatchReverts(), 0);
        assertEq(handler.ghostOutcomeCountMismatches(), 0);
        assertEq(handler.ghostUntruthfulPausedEvents(), 0);
        assertEq(handler.ghostPausedEventsForNonWrappers(), 0);
        assertEq(handler.ghostCallsToUnregistered(), 0);
    }
}
