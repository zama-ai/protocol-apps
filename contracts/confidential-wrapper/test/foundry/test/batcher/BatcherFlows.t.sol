// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {BatcherForkBase} from "./BatcherForkBase.t.sol";
import {IVaultBatcher} from "./IVaultBatcher.sol";

/**
 * @notice Every wrapper entry point the deployed batchers touch, driven end to end: the push and
 * pull deposit paths, `unwrap`/`finalizeUnwrap` across dispatch and settlement, `wrap` on the
 * output leg, and `confidentialTransfer` on claim and quit.
 */
contract BatcherFlowsTest is BatcherForkBase {
    /// @dev 1,000 USDC in wrapped units (cUSDC tracks USDC's 6 decimals at rate 1).
    uint64 internal constant DEPOSIT_AMOUNT = 1_000_000_000;

    /// @notice The batchers are wired to the wrappers this suite upgraded, in opposite directions.
    /// Without this the rest of the file could pass against an unrelated wrapper.
    function test_DeployedBatchers_WiredToUpgradedWrappers() public view {
        assertEq(depositBatcher.fromToken(), cUsdc, "deposit batcher: fromToken");
        assertEq(depositBatcher.toToken(), cShare, "deposit batcher: toToken");
        assertEq(depositBatcher.vault(), morphoVault, "deposit batcher: vault");

        assertEq(redeemBatcher.fromToken(), cShare, "redeem batcher: fromToken");
        assertEq(redeemBatcher.toToken(), cUsdc, "redeem batcher: toToken");
        assertEq(redeemBatcher.vault(), morphoVault, "redeem batcher: vault");

        assertTrue(_isRegistryWrapper(cUsdc), "cUSDC not enumerated from the registry");
        assertTrue(_isRegistryWrapper(cShare), "cShare not enumerated from the registry");
        assertEq(_implementationOf(cUsdc), address(newImplementation), "cUSDC not on the candidate impl");
        assertEq(_implementationOf(cShare), address(newImplementation), "cShare not on the candidate impl");
    }

    /// @notice Deposit into the vault and redeem back out, covering both deployed batchers.
    function test_DepositRedeemRoundTrip() public {
        address user = makeAddr("round-trip-user");
        _dealAndWrap(cUsdc, user, uint256(DEPOSIT_AMOUNT) * _wrapper(cUsdc).rate());

        uint64 shares = _runBatch(depositBatcher, user, DEPOSIT_AMOUNT);
        assertGt(shares, 0, "deposit leg returned no shares");
        assertEq(_decryptBalance(cShare, user), shares, "cShare not credited to user");

        uint64 assets = _runBatch(redeemBatcher, user, shares);
        assertGt(assets, 0, "redeem leg returned no assets");
        assertEq(_decryptBalance(cUsdc, user), assets, "cUSDC not credited to user");
    }

    /// @notice A deposit moved by an approved operator, then withdrawn with `quit`. Covers the
    /// wrapper's operator branch of `_update` and its `confidentialTransfer` back out of the batcher.
    function test_OperatorJoinAndQuit() public {
        address user = makeAddr("operator-join-user");
        address operator = makeAddr("operator-join-relayer");
        _dealAndWrap(cUsdc, user, uint256(DEPOSIT_AMOUNT) * _wrapper(cUsdc).rate());

        uint256 batchId = depositBatcher.currentBatchId();
        _joinViaOperator(depositBatcher, user, operator, DEPOSIT_AMOUNT);

        assertEq(decrypt(depositBatcher.deposits(batchId, user)), DEPOSIT_AMOUNT, "deposit not recorded");
        assertEq(_decryptBalance(cUsdc, user), 0, "cUSDC not pulled from user");

        vm.prank(user);
        depositBatcher.quit(batchId);

        assertEq(_decryptBalance(cUsdc, user), DEPOSIT_AMOUNT, "cUSDC not returned on quit");
    }

    /// @notice Dispatching a batch nobody joined burns from an uninitialized balance handle. Before
    /// the 0.5.3 confidential-contracts parity update that reverted with `ERC7984ZeroBalance` and left
    /// the batcher permanently stuck on its batch, as happened to the Sepolia staging batcher.
    function test_EmptyBatchDispatch() public {
        _runEmptyBatch(depositBatcher, "deposit batcher");
        _runEmptyBatch(redeemBatcher, "redeem batcher");
    }

    function _runEmptyBatch(IVaultBatcher batcher, string memory label) internal {
        uint256 batchId = _dispatch(batcher);
        assertEq(
            uint8(batcher.batchState(batchId)),
            uint8(IVaultBatcher.BatchState.Dispatched),
            string.concat(label, ": empty batch did not dispatch")
        );

        _callback(batcher, batchId);
        assertEq(
            uint8(batcher.batchState(batchId)),
            uint8(IVaultBatcher.BatchState.Canceled),
            string.concat(label, ": empty batch did not cancel")
        );
    }

    function _isRegistryWrapper(address wrapper) internal view returns (bool) {
        for (uint256 i = 0; i < wrappers.length; i++) {
            if (wrappers[i] == wrapper) return true;
        }
        return false;
    }
}
