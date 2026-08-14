// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {euint64} from "encrypted-types/EncryptedTypes.sol";

/**
 * @notice The slice of the deployed batchers' ABI these tests drive.
 * @dev Declared here rather than vendored from zama-ai/confidential-defi: the mainnet batchers are
 * non-upgradeable, so the deployed bytecode is what a wrapper upgrade has to keep working, and that
 * repo pins a conflicting dependency set (fhevm-solidity 0.13.0, OpenZeppelin confidential-contracts
 * 0.5.1) while already depending on this one. One interface covers both batchers; they differ only in
 * the vault route they run behind `dispatchBatchCallback`.
 */
interface IVaultBatcher {
    enum BatchState {
        Pending,
        Dispatched,
        Finalized,
        Canceled
    }

    function fromToken() external view returns (address);

    function toToken() external view returns (address);

    function vault() external view returns (address);

    function owner() external view returns (address);

    function paused() external view returns (bool);

    function minBatchAge() external view returns (uint256);

    function currentBatchId() external view returns (uint256);

    function batchState(uint256 batchId) external view returns (BatchState);

    function unwrapRequestId(uint256 batchId) external view returns (bytes32);

    function totalDeposits(uint256 batchId) external view returns (euint64);

    function deposits(uint256 batchId, address account) external view returns (euint64);

    function unpause() external;

    // NOTE: no `join`. The pull entry point was added to VaultBatcherConfidential after these
    // batchers were deployed, so on-chain there is no such selector.
    // Deposits reach a deployed batch only through the wrapper's transfer-and-call
    // paths, which is what {BatcherForkBase._joinPush} and {_joinViaOperator} drive.

    function dispatchBatch() external;

    function dispatchBatchCallback(uint256 batchId, uint64 unwrapAmountCleartext, bytes calldata decryptionProof)
        external;

    function claim(uint256 batchId, address account) external returns (euint64);

    function quit(uint256 batchId) external returns (euint64);
}
