// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";

import { ConfidentialWrapperPauser } from "confidential-wrapper-pauser/ConfidentialWrapperPauser.sol";
import { ConfidentialTokenWrappersRegistryMock } from "confidential-wrapper-pauser/mocks/ConfidentialTokenWrappersRegistryMock.sol";
import { ConfidentialWrapperMock } from "confidential-wrapper-pauser/mocks/ConfidentialWrapperMock.sol";
import { PauserHandler } from "./PauserHandler.sol";

/**
 * @title PauserInvariantTest
 * @notice Stateful properties of {ConfidentialWrapperPauser} under random sequences of {PauserHandler} actions:
 * a single default admin (none once renounced) mirrored by `owner()`, a duplicate-free roster that `isPauser`
 * agrees with, pauses only by roster members, and outcome events that tell the truth about the wrappers. Runs
 * with `make unit-test`.
 */
contract PauserInvariantTest is StdInvariant, Test {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    uint48 internal constant ADMIN_DELAY = 1 days;

    ConfidentialTokenWrappersRegistryMock internal registry;
    ConfidentialWrapperPauser internal pauser;
    PauserHandler internal handler;

    function setUp() public {
        address admin = makeAddr("admin");
        address[] memory roster = new address[](2);
        roster[0] = makeAddr("roster-member-1");
        roster[1] = makeAddr("roster-member-2");
        address[] memory others = new address[](3);
        others[0] = makeAddr("outsider-1");
        others[1] = makeAddr("outsider-2");
        others[2] = makeAddr("outsider-3");

        registry = new ConfidentialTokenWrappersRegistryMock();
        pauser = new ConfidentialWrapperPauser(ADMIN_DELAY, admin, registry, roster);
        handler = new PauserHandler(pauser, registry, admin, roster, others);

        targetContract(address(handler));
    }

    /// @notice Exactly one DEFAULT_ADMIN_ROLE holder, the one the handler tracks, until it renounces; then none.
    function invariant_SingleDefaultAdminUnlessRenounced() public view {
        if (handler.ghostAdminRenounced()) {
            assertEq(pauser.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 0, "admin count after renounce");
            assertEq(pauser.defaultAdmin(), address(0), "defaultAdmin after renounce");
        } else {
            assertEq(pauser.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, "admin count");
            assertEq(pauser.defaultAdmin(), handler.ghostAdmin(), "defaultAdmin vs ghost");
            assertTrue(pauser.hasRole(DEFAULT_ADMIN_ROLE, handler.ghostAdmin()), "ghost admin lacks the role");
        }
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address actor = handler.actors(i);
            assertEq(pauser.hasRole(DEFAULT_ADMIN_ROLE, actor), actor == pauser.defaultAdmin(), "stray admin");
        }
    }

    /// @notice `owner()` (ERC-5313) always mirrors `defaultAdmin()`.
    function invariant_OwnerMirrorsDefaultAdmin() public view {
        assertEq(pauser.owner(), pauser.defaultAdmin());
    }

    /// @notice The admin only ever moves through accepted transfers, never through a direct grant or revoke.
    function invariant_DefaultAdminNeverGrantedDirectly() public view {
        assertEq(handler.ghostDirectAdminGrants(), 0, "direct DEFAULT_ADMIN_ROLE grant or revoke succeeded");
        assertEq(handler.ghostRosterChangesByNonAdmin(), 0, "admin-only call succeeded for a non-admin");
    }

    /// @notice `pausers()` has no duplicates and no zero address, agrees with `isPauser` / `hasRole` /
    /// `getRoleMember`, and matches the roster the handler tracks from the calls that succeeded.
    function invariant_RosterIsConsistent() public view {
        address[] memory members = pauser.pausers();
        assertEq(members.length, pauser.getRoleMemberCount(PAUSER_ROLE), "count");
        for (uint256 i = 0; i < members.length; i++) {
            assertNotEq(members[i], address(0), "zero member");
            assertTrue(pauser.isPauser(members[i]), "member not isPauser");
            assertTrue(pauser.hasRole(PAUSER_ROLE, members[i]), "member without role");
            assertEq(pauser.getRoleMember(PAUSER_ROLE, i), members[i], "getRoleMember order");
            for (uint256 j = i + 1; j < members.length; j++) {
                assertNotEq(members[i], members[j], "duplicate member");
            }
        }
        uint256 tracked;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address actor = handler.actors(i);
            assertEq(pauser.isPauser(actor), handler.ghostIsPauser(actor), "isPauser vs ghost");
            if (handler.ghostIsPauser(actor)) tracked++;
        }
        assertEq(members.length, tracked, "roster vs ghost");
    }

    /// @notice Only roster members pause: no pause call by a non-member ever succeeded, no wrapper flipped to
    /// paused in a call from a non-member, and no direct `pause()` on a wrapper ever went through.
    function invariant_OnlyRosterMembersPause() public view {
        assertEq(handler.ghostPausesByNonMember(), 0, "pause succeeded for a non-member");
        assertEq(handler.ghostFlipsByNonMember(), 0, "wrapper paused in a non-member call");
        assertEq(handler.ghostDirectWrapperPauses(), 0, "direct wrapper pause succeeded");
    }

    /// @notice The batch form never reverted for a member, and every call produced exactly one outcome event per
    /// entry (none when it reverted).
    function invariant_BatchIsBestEffort() public view {
        assertEq(handler.ghostBatchReverts(), 0, "batch reverted for a member");
        assertEq(handler.ghostOutcomeCountMismatches(), 0, "outcome events vs entries");
    }

    /// @notice Every WrapperPaused(w) / WrapperAlreadyPaused(w) was followed by `w.paused() == true` in the same
    /// call, none was emitted for anything but a registered armed wrapper, and the armed wrappers' state matches
    /// the state the handler rebuilt from those events and its unpauses.
    function invariant_WrapperPausedIsTruthful() public view {
        assertEq(handler.ghostUntruthfulPausedEvents(), 0, "WrapperPaused without paused() == true");
        assertEq(handler.ghostPausedEventsForNonWrappers(), 0, "WrapperPaused for a non-wrapper");
        for (uint256 i = 0; i < handler.armedCount(); i++) {
            address wrapper = handler.targets(i);
            assertEq(ConfidentialWrapperMock(wrapper).paused(), handler.ghostPaused(wrapper), "paused vs ghost");
        }
        for (uint256 i = handler.armedCount(); i < handler.targetCount(); i++) {
            address target = handler.targets(i);
            if (target.code.length == 0) continue;
            (bool ok, bytes memory answer) = target.staticcall(abi.encodeWithSignature("paused()"));
            // An unarmed wrapper is never paused; the hostile mocks never become a true word through the pauser.
            if (ok && answer.length == 32) assertNotEq(abi.decode(answer, (uint256)), 1, "non-armed target paused");
        }
    }

    /// @notice The registry is the immutable one the pauser was built with, nothing it does not list is paused, and
    /// nothing it does not list is even called (the WETH-style target never saw a call).
    function invariant_OnlyRegisteredWrappersArePaused() public view {
        assertEq(address(pauser.registry()), address(registry), "registry");
        assertEq(handler.ghostCallsToUnregistered(), 0, "unregistered target was called");
        for (uint256 i = 0; i < handler.targetCount(); i++) {
            address target = handler.targets(i);
            if (registry.isConfidentialTokenValid(target) || target.code.length == 0) continue;
            // Unregistered or revoked: paused only if it was paused while still registered (handler ghost).
            (bool ok, bytes memory answer) = target.staticcall(abi.encodeWithSignature("paused()"));
            if (ok && answer.length == 32 && abi.decode(answer, (uint256)) == 1) {
                assertTrue(handler.ghostPaused(target), "unregistered target paused outside the pauser's records");
            }
        }
    }

    /// @notice Every handler path saw only the reverts it expected.
    function invariant_HandlerSawNoUnexpectedRevert() public view {
        assertEq(handler.ghostUnexpectedReverts(), 0, "unexpected revert in a handler call");
    }
}
