// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { ConfidentialWrapperPauser } from "confidential-wrapper-pauser/ConfidentialWrapperPauser.sol";
import { IConfidentialWrapperPauser } from "confidential-wrapper-pauser/interfaces/IConfidentialWrapperPauser.sol";

/// @dev Registry enumeration path, mirrored from ConfidentialTokenWrappersRegistry. The test enumerates the live
/// wrappers from it, revoked pairs included (revocation only flips the registry flag, the wrapper keeps running);
/// the pauser itself has no registry dependency.
interface IWrappersRegistry {
    struct TokenWrapperPair {
        address tokenAddress;
        address confidentialTokenAddress;
        bool isValid;
    }

    function getTokenConfidentialTokenPairs() external view returns (TokenWrapperPair[] memory);
}

/// @dev Live wrapper surface used here (V4 pause API + Ownable owner).
interface ILiveWrapper {
    event PauserUpdated(address indexed pauser);
    event Paused(address account);
    event Unpaused(address account);

    error SenderNotPauser(address sender);

    function pauser() external view returns (address);
    function paused() external view returns (bool);
    function setPauser(address pauser_) external;
    function pause() external;
    function unpause() external;
    function symbol() external view returns (string memory);
}

/**
 * @title PauserForkTest
 * @notice P-RFC-006 migration rehearsal against the live wrappers of one chain: deploy the pauser with the chain's
 * governance as owner, have governance point every registered wrapper's `setPauser` at it, then let a single
 * roster member halt everything and governance restore it. No FHE is involved, so the suite needs only forge-std.
 *
 * @dev Runs with `make fork-test NETWORK=<ethereum|sepolia|polygon|amoy>`; the network key arrives as the
 * FORK_NETWORK env var and selects the registry from config/fork.json. Governance is read from the wrappers
 * themselves (`owner()`), so the test also proves every wrapper on the chain shares one owner.
 */
contract PauserForkTest is Test {
    string internal constant FORK_CONFIG_PATH = "config/fork.json";

    IWrappersRegistry internal registry;
    address[] internal wrappers;
    address internal governance;

    ConfidentialWrapperPauser internal pauser;
    address internal fb1 = makeAddr("roster-member-1");
    address internal fb2 = makeAddr("roster-member-2");
    address internal outsider = makeAddr("outsider");

    function setUp() public {
        string memory network = vm.envOr("FORK_NETWORK", string("ethereum"));
        string memory json = vm.readFile(FORK_CONFIG_PATH);
        string memory key = string.concat(".", network, ".registry");
        require(vm.keyExistsJson(json, key), string.concat("config/fork.json has no registry for ", network));
        registry = IWrappersRegistry(vm.parseJsonAddress(json, key));

        IWrappersRegistry.TokenWrapperPair[] memory pairs = registry.getTokenConfidentialTokenPairs();
        for (uint256 i = 0; i < pairs.length; i++) {
            wrappers.push(pairs[i].confidentialTokenAddress);
        }
        require(wrappers.length > 0, "no wrappers enumerated from the registry");

        // Every wrapper must be owned by the same governance address: it is the pauser's owner and the proposer
        // of the setPauser batch.
        governance = Ownable(wrappers[0]).owner();
        for (uint256 i = 1; i < wrappers.length; i++) {
            assertEq(Ownable(wrappers[i]).owner(), governance, string.concat(_label(wrappers[i]), ": owner differs"));
        }

        // Migration step 1: anyone deploys, governance is the owner, the roster is seeded.
        address[] memory roster = new address[](2);
        roster[0] = fb1;
        roster[1] = fb2;
        pauser = new ConfidentialWrapperPauser(governance, roster);
        assertEq(pauser.owner(), governance, "pauser owner is not the wrappers' owner");
        assertEq(pauser.pendingOwner(), address(0), "pauser has a pending owner");
    }

    /// @notice Baseline: the live proxies expose the V4 pause API and nobody can pause them yet, because every
    /// wrapper's `pauser()` is the zero address (the property the runbook relies on). PRO-704 arms them with the
    /// chain pauser; this assertion then flips to `pauser() == <chain pauser>`.
    function test_LiveWrappersAreUnarmed() public view {
        for (uint256 i = 0; i < wrappers.length; i++) {
            ILiveWrapper w = ILiveWrapper(wrappers[i]);
            string memory sym = _label(wrappers[i]);
            assertFalse(w.paused(), string.concat(sym, ": already paused"));
            assertEq(w.pauser(), address(0), string.concat(sym, ": already armed"));
        }
    }

    /// @notice Migration step 2 + a roster member's batch pause + governance unpause, across every wrapper.
    function test_ArmPauseAllAndRestore() public {
        _armAll();

        // Before arming completes nobody but the pauser contract can pause; the contract itself needs a member.
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IConfidentialWrapperPauser.SenderNotPauser.selector, outsider));
        pauser.pause(wrappers);

        // Governance is the owner, not a roster member.
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IConfidentialWrapperPauser.SenderNotPauser.selector, governance));
        pauser.pause(wrappers);

        // One signer halts the whole chain.
        for (uint256 i = 0; i < wrappers.length; i++) {
            vm.expectEmit(true, true, false, true, address(pauser));
            emit IConfidentialWrapperPauser.WrapperPaused(wrappers[i], fb1);
        }
        vm.prank(fb1);
        pauser.pause(wrappers);

        for (uint256 i = 0; i < wrappers.length; i++) {
            assertTrue(ILiveWrapper(wrappers[i]).paused(), string.concat(_label(wrappers[i]), ": not paused"));
        }

        // A second signer cannot unpause anything, and neither can the pauser contract.
        vm.prank(fb2);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, fb2));
        ILiveWrapper(wrappers[0]).unpause();

        // Only governance restores, wrapper by wrapper.
        for (uint256 i = 0; i < wrappers.length; i++) {
            vm.prank(governance);
            ILiveWrapper(wrappers[i]).unpause();
            assertFalse(ILiveWrapper(wrappers[i]).paused(), string.concat(_label(wrappers[i]), ": still paused"));
        }

        // And the roster can pause again afterwards, one wrapper at a time.
        vm.prank(fb2);
        pauser.pause(wrappers[0]);
        assertTrue(ILiveWrapper(wrappers[0]).paused(), "single pause after restore failed");
    }

    /// @notice A partially armed chain: the batch pauses what it can and reports the rest, never reverting.
    function test_BatchIsBestEffortOnPartiallyArmedChain() public {
        if (wrappers.length < 2) return; // nothing partial to test on a single-wrapper chain

        // Arm every wrapper but the last one.
        for (uint256 i = 0; i + 1 < wrappers.length; i++) {
            vm.prank(governance);
            ILiveWrapper(wrappers[i]).setPauser(address(pauser));
        }
        address unarmed = wrappers[wrappers.length - 1];
        bytes memory wrapperError = abi.encodeWithSelector(ILiveWrapper.SenderNotPauser.selector, address(pauser));

        vm.expectEmit(true, true, false, true, address(pauser));
        emit IConfidentialWrapperPauser.WrapperPauseFailed(unarmed, fb1, wrapperError);
        vm.prank(fb1);
        pauser.pause(wrappers);

        for (uint256 i = 0; i + 1 < wrappers.length; i++) {
            assertTrue(ILiveWrapper(wrappers[i]).paused(), string.concat(_label(wrappers[i]), ": not paused"));
        }
        assertFalse(ILiveWrapper(unarmed).paused(), string.concat(_label(unarmed), ": paused while unarmed"));

        // The strict form surfaces the same wrapper error.
        vm.prank(fb1);
        vm.expectRevert(abi.encodeWithSelector(IConfidentialWrapperPauser.PauseFailed.selector, unarmed, wrapperError));
        pauser.pause(unarmed);
    }

    /// @notice Roster rotation by governance takes effect immediately on the live wrappers.
    function test_GovernanceRotatesRoster() public {
        _armAll();

        // A roster member cannot rotate the roster.
        vm.prank(fb1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, fb1));
        pauser.addPauser(outsider);

        vm.prank(governance);
        pauser.removePauser(fb1);
        vm.prank(governance);
        pauser.addPauser(outsider);

        vm.prank(fb1);
        vm.expectRevert(abi.encodeWithSelector(IConfidentialWrapperPauser.SenderNotPauser.selector, fb1));
        pauser.pause(wrappers[0]);

        vm.prank(outsider);
        pauser.pause(wrappers[0]);
        assertTrue(ILiveWrapper(wrappers[0]).paused(), "rotated-in member could not pause");

        address[] memory roster = pauser.pausers();
        assertEq(roster.length, 2, "roster size after rotation");
        assertEq(roster[0], fb2);
        assertEq(roster[1], outsider);
    }

    /// @dev Migration step 2 as governance would execute it, with the post-execution assertion of the RFC.
    function _armAll() internal {
        for (uint256 i = 0; i < wrappers.length; i++) {
            vm.prank(governance);
            vm.expectEmit(true, false, false, false, wrappers[i]);
            emit ILiveWrapper.PauserUpdated(address(pauser));
            ILiveWrapper(wrappers[i]).setPauser(address(pauser));
        }
        for (uint256 i = 0; i < wrappers.length; i++) {
            assertEq(
                ILiveWrapper(wrappers[i]).pauser(),
                address(pauser),
                string.concat(_label(wrappers[i]), ": pauser() is not the chain pauser")
            );
        }
    }

    /// @notice Short symbol used in failure labels, falling back to the address.
    function _label(address w) internal view returns (string memory) {
        try ILiveWrapper(w).symbol() returns (string memory s) {
            return s;
        } catch {
            return vm.toString(w);
        }
    }
}
