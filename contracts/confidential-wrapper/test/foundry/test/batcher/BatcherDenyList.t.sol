// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {externalEuint64} from "encrypted-types/EncryptedTypes.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {ConfidentialWrapper} from "confidential-wrapper/ConfidentialWrapper.sol";
import {BatcherForkBase} from "./BatcherForkBase.t.sol";
import {IVaultBatcher} from "./IVaultBatcher.sol";

/**
 * @notice How the wrapper's deny list and pause switch surface through a batcher. Run against the
 * deposit batcher and cUSDC only: the guards live in the wrapper, so the redeem batcher would
 * re-run identical code.
 */
contract BatcherDenyListTest is BatcherForkBase {
    uint64 internal constant DEPOSIT_AMOUNT = 1_000_000_000;

    /// @notice A blocked account cannot deposit into a batch.
    function test_BlockedUserCannotJoin() public {
        address user = makeAddr("blocked-join-user");
        _dealAndWrap(cUsdc, user, uint256(DEPOSIT_AMOUNT) * _wrapper(cUsdc).rate());

        // Encrypt before blocking so the input proof is not what fails.
        (externalEuint64 enc, bytes memory proof) = encryptUint64(DEPOSIT_AMOUNT, user, cUsdc);

        vm.prank(_wrapperOwner(cUsdc));
        _wrapper(cUsdc).blockUser(user);

        vm.expectRevert(abi.encodeWithSelector(ConfidentialWrapper.BlockedUser.selector, user));
        vm.prank(user);
        _wrapper(cUsdc).confidentialTransferAndCall(address(depositBatcher), enc, proof, "");
    }

    /// @notice Blocking a depositor after they joined must not strand the batch. The wrapper's
    /// `finalizeUnwrap` deny-list check reads the unwrap context, whose holder and operator are the
    /// batcher rather than any depositor, so dispatch and settlement stay unaffected.
    function test_BlockedDepositorDoesNotBrickBatch() public {
        address user = makeAddr("blocked-after-join-user");
        _dealAndWrap(cUsdc, user, uint256(DEPOSIT_AMOUNT) * _wrapper(cUsdc).rate());

        _joinPush(depositBatcher, user, DEPOSIT_AMOUNT);

        vm.prank(_wrapperOwner(cUsdc));
        _wrapper(cUsdc).blockUser(user);

        uint256 batchId = _dispatch(depositBatcher);
        _callback(depositBatcher, batchId);

        assertEq(
            uint8(depositBatcher.batchState(batchId)),
            uint8(IVaultBatcher.BatchState.Finalized),
            "batch stranded by a blocked depositor"
        );
        assertGt(decrypt(depositBatcher.claim(batchId, user)), 0, "blocked depositor could not claim");
    }

    /// @notice A paused input wrapper fails the batch closed rather than half-executing it: dispatch
    /// reverts on the unwrap burn and succeeds once the wrapper is unpaused.
    function test_PausedWrapperBlocksDispatch() public {
        address user = makeAddr("paused-dispatch-user");
        address owner = _wrapperOwner(cUsdc);
        address pauser = makeAddr("cusdc-pauser");
        _dealAndWrap(cUsdc, user, uint256(DEPOSIT_AMOUNT) * _wrapper(cUsdc).rate());

        _joinPush(depositBatcher, user, DEPOSIT_AMOUNT);
        uint256 batchId = depositBatcher.currentBatchId();
        vm.warp(block.timestamp + depositBatcher.minBatchAge() + 1);

        vm.prank(owner);
        _wrapper(cUsdc).setPauser(pauser);
        vm.prank(pauser);
        _wrapper(cUsdc).pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        depositBatcher.dispatchBatch();

        vm.prank(owner);
        _wrapper(cUsdc).unpause();

        depositBatcher.dispatchBatch();
        assertEq(
            uint8(depositBatcher.batchState(batchId)),
            uint8(IVaultBatcher.BatchState.Dispatched),
            "batch did not dispatch after unpause"
        );
    }
}
