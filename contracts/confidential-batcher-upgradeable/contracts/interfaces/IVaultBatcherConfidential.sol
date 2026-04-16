// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IVaultBatcherConfidential
/// @notice Errors, events, and external view signatures for the Confidential DeFi Gateway batchers.
interface IVaultBatcherConfidential {
    // ──────────────────────────────────────────────── Errors ────────────────────────────────────────────────

    /// @notice Thrown when dispatch is attempted before the minimum batch age.
    /// @param batchId The batch being dispatched.
    /// @param elapsed Seconds elapsed since batch creation.
    /// @param required Required minimum age in seconds.
    error BatchTooYoung(uint256 batchId, uint256 elapsed, uint256 required);

    /// @notice Thrown when a required constructor argument is the zero address.
    error ZeroAddress();

    /// @notice Thrown when a token wrapper reports a zero rate (non-standard wrapper).
    error InvalidTokenRate();

    /// @notice Thrown when the route asset token wiring does not match the expected vault-side asset.
    /// @param actualAsset Token address actually exposed by the route input/output wrapper.
    /// @param expectedAsset Token address expected for this route.
    error RouteAssetMismatch(address actualAsset, address expectedAsset);

    /// @notice Thrown when the route share token wiring does not match the expected vault-side share token.
    /// @param actualShare Token address actually exposed by the route input/output wrapper.
    /// @param expectedShare Token address expected for this route.
    error RouteShareMismatch(address actualShare, address expectedShare);

    /// @notice Thrown when the post-settlement exchange rate deviates too far from the pinned rate.
    /// @param batchId The batch that failed the slippage check.
    /// @param actual The observed exchange rate after route execution.
    /// @param minimum The minimum acceptable rate derived from pinned rate and slippage tolerance.
    error SlippageExceeded(uint256 batchId, uint64 actual, uint64 minimum);

    /// @notice Thrown when maxSlippageBps exceeds 10 000 (100 %).
    error InvalidMaxSlippageBps();

    // ──────────────────────────────────────────────── Events ────────────────────────────────────────────────

    /// @notice Emitted when the minimum batch age is updated.
    /// @param minBatchAge New minimum batch age in seconds.
    event MinBatchAgeSet(uint256 minBatchAge);

    /// @notice Emitted when the retry window is updated.
    /// @param retryWindow New retry window in seconds.
    event RetryWindowSet(uint256 retryWindow);

    /// @notice Emitted when the maximum slippage tolerance is updated.
    /// @param maxSlippageBps New maximum slippage in basis points.
    event MaxSlippageBpsSet(uint16 maxSlippageBps);

    /// @notice Emitted when the fee-adjusted slippage tolerance exceeds 100 % and is capped at 10 000 bps.
    /// @dev This disables slippage protection for the batch; off-chain monitoring should flag this.
    /// @param batchId The batch whose tolerance was capped.
    /// @param uncappedBps The raw fee-adjusted slippage value before capping.
    event SlippageToleranceCapped(uint256 indexed batchId, uint256 uncappedBps);

    // ──────────────────────────────────────────── View functions ────────────────────────────────────────────

    /// @notice Returns the configured ERC4626 vault.
    function vault() external view returns (IERC4626);

    /// @notice Returns the minimum batch age required before dispatch.
    function minBatchAge() external view returns (uint256);

    /// @notice Returns the retry window for dispatched batches.
    function retryWindow() external view returns (uint256);

    /// @notice Returns the creation timestamp for a batch.
    function batchCreatedAt(uint256 batchId) external view returns (uint256);

    /// @notice Returns the dispatch timestamp for a batch.
    function batchDispatchedAt(uint256 batchId) external view returns (uint256);

    /// @notice Returns the vault rate pinned when a batch was dispatched.
    function batchPinnedRate(uint256 batchId) external view returns (uint64);

    /// @notice Returns the slippage tolerance frozen when a batch was opened.
    function batchMaxSlippageBps(uint256 batchId) external view returns (uint16);

    /// @notice Returns the maximum slippage tolerance in basis points.
    function maxSlippageBps() external view returns (uint16);
}
