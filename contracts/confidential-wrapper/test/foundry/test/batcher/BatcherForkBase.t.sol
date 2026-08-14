// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {euint64, externalEuint64} from "encrypted-types/EncryptedTypes.sol";

import {BaseForkTest} from "../BaseForkTest.t.sol";
import {IVaultBatcher} from "./IVaultBatcher.sol";

/**
 * @title BatcherForkBase
 * @notice Harness for driving the live Confidential DeFi Gateway batchers against the candidate
 * wrapper implementation {BaseForkTest} upgrades every registry proxy onto.
 *
 * @dev The batchers are read from mainnet, not deployed here. Like the wrappers they store their FHE
 * config in the `CoprocessorConfig` ERC-7201 slot (`ZamaEthereumConfig`'s constructor calls
 * `FHE.setCoprocessor`), so {_prepareBatcher} can repoint them at the in-process fhEVM host the same
 * way {BaseForkTest} repoints the proxies.
 */
abstract contract BatcherForkBase is BaseForkTest {
    /// @notice Deployed batcher/wrapper/vault addresses, mirrored from zama-ai/confidential-defi.
    string internal constant BATCHERS_PATH = "config/batchers.json";

    /// @dev Canonical mainnet fhEVM addresses (ZamaConfig Ethereum config) the deployed batchers
    /// must point at.
    address internal constant MAINNET_FHEVM_ACL = 0xcA2E8f1F656CD25C01F05d0b243Ab1ecd4a8ffb6;
    address internal constant MAINNET_FHEVM_COPROCESSOR = 0xD82385dADa1ae3E969447f20A3164F6213100e75;
    address internal constant MAINNET_FHEVM_KMS_VERIFIER = 0x77627828a55156b04Ac0DC0eb30467f1a552BB03;

    /// @dev `BatcherConfidential._batches` in the deployed layout. `Ownable._owner` (20 bytes) and
    /// `Pausable._paused` (1 byte) pack together into slot 0.
    uint256 internal constant BATCHES_SLOT = 1;

    IVaultBatcher internal depositBatcher;
    IVaultBatcher internal redeemBatcher;
    address internal cUsdc;
    address internal cShare;
    address internal morphoVault;

    function setUp() public virtual override {
        super.setUp();
        // Batch flows chain far more FHE ops than the direct wrapper flows.
        disableHCUDepthLimit();

        string memory json = vm.readFile(BATCHERS_PATH);
        depositBatcher = IVaultBatcher(vm.parseJsonAddress(json, ".depositBatcher"));
        redeemBatcher = IVaultBatcher(vm.parseJsonAddress(json, ".redeemBatcher"));
        cUsdc = vm.parseJsonAddress(json, ".cUsdc");
        cShare = vm.parseJsonAddress(json, ".cShare");
        morphoVault = vm.parseJsonAddress(json, ".morphoVault");

        _prepareBatcher(depositBatcher);
        _prepareBatcher(redeemBatcher);
    }

    /// @notice Makes a deployed batcher drivable under the in-process fhEVM host.
    function _prepareBatcher(IVaultBatcher batcher) internal {
        address b = address(batcher);
        require(b.code.length > 0, "missing batcher code");

        _repointBatcherFhevmHost(b);
        _resetCurrentBatch(batcher);
        _resetConfidentialBalance(batcher.fromToken(), b);
        _resetConfidentialBalance(batcher.toToken(), b);

        if (batcher.paused()) {
            vm.prank(batcher.owner());
            batcher.unpause();
        }
    }

    /// @notice Points `batcher`'s FHE config at forge-fhevm's in-process host, after asserting it
    /// currently holds the canonical mainnet addresses.
    function _repointBatcherFhevmHost(address batcher) internal {
        require(_fhevmConfigAt(batcher, 0) == MAINNET_FHEVM_ACL, "batcher: unexpected ACL");
        require(_fhevmConfigAt(batcher, 1) == MAINNET_FHEVM_COPROCESSOR, "batcher: unexpected coprocessor");
        require(_fhevmConfigAt(batcher, 2) == MAINNET_FHEVM_KMS_VERIFIER, "batcher: unexpected KMS verifier");

        vm.store(batcher, FHEVM_CONFIG_BASE, bytes32(uint256(uint160(LOCAL_FHEVM_ACL))));
        vm.store(batcher, bytes32(uint256(FHEVM_CONFIG_BASE) + 1), bytes32(uint256(uint160(LOCAL_FHEVM_COPROCESSOR))));
        vm.store(batcher, bytes32(uint256(FHEVM_CONFIG_BASE) + 2), bytes32(uint256(uint160(LOCAL_FHEVM_KMS_VERIFIER))));
    }

    /// @dev Reads the `acl`/`coprocessor`/`kmsVerifier` word at `index` of the CoprocessorConfig struct.
    function _fhevmConfigAt(address target, uint256 index) internal view returns (address) {
        return address(uint160(uint256(vm.load(target, bytes32(uint256(FHEVM_CONFIG_BASE) + index)))));
    }

    /// @notice Clears the open batch's aggregate deposit handle so the tests can rebuild it locally.
    /// @dev The live handle was produced by Zama's mainnet coprocessor and has no entry in the
    /// in-process plaintext DB, so any FHE op reading it fails. Same trade-off {BaseForkTest} makes
    /// when it zeroes each wrapper's cached total supply.
    function _resetCurrentBatch(IVaultBatcher batcher) internal {
        address b = address(batcher);
        uint256 batchId = batcher.currentBatchId();
        // `totalDeposits` is the first field of BatcherConfidential.Batch.
        bytes32 slot = keccak256(abi.encode(batchId, BATCHES_SLOT));

        // Round-trip a sentinel through the public getter first. If the getter reads it back, the
        // slot derivation is proven outright, so a layout change fails here instead of silently
        // corrupting unrelated storage.
        bytes32 sentinel = keccak256(abi.encode("batcher-fork:total-deposits-probe", b));
        vm.store(b, slot, sentinel);
        require(euint64.unwrap(batcher.totalDeposits(batchId)) == sentinel, "unexpected batcher layout");

        vm.store(b, slot, bytes32(0));
        require(euint64.unwrap(batcher.totalDeposits(batchId)) == bytes32(0), "batch reset failed");
    }

    /// @notice Clears `account`'s confidential balance on `wrapper`, for the same reason
    /// {_resetCurrentBatch} clears the batch handle. Any real in-flight deposits the deployed batcher
    /// holds are discarded along with it.
    function _resetConfidentialBalance(address wrapper, address account) internal {
        // `_balances` is the first field of ERC7984Storage.
        vm.store(wrapper, keccak256(abi.encode(account, uint256(ERC7984_STORAGE_BASE))), bytes32(0));
        require(euint64.unwrap(_wrapper(wrapper).confidentialBalanceOf(account)) == bytes32(0), "balance reset failed");
    }

    /// @notice Deposits into `batcher` over the push path: the wrapper transfers and calls back into
    /// `onConfidentialTransferReceived`. The proof is bound to the wrapper, which runs `FHE.fromExternal`.
    function _joinPush(IVaultBatcher batcher, address user, uint64 amount) internal {
        address token = batcher.fromToken();
        (externalEuint64 enc, bytes memory proof) = encryptUint64(amount, user, token);

        vm.prank(user);
        _wrapper(token).confidentialTransferAndCall(address(batcher), enc, proof, "");
    }

    /// @notice Deposits `user`'s funds into `batcher` through `operator`, which `user` has approved.
    /// @dev Reaches the wrapper's `msg.sender != from` branch of `_update` — the operator deny-list
    /// check — which the plain push path never touches. The batch is still credited to `user`, since
    /// `onConfidentialTransferReceived` joins on behalf of the holder rather than the caller.
    function _joinViaOperator(IVaultBatcher batcher, address user, address operator, uint64 amount) internal {
        // Read the getter before pranking: it is an external call, so it would otherwise consume the
        // prank and `setOperator` would approve on behalf of the test contract instead of `user`.
        address token = batcher.fromToken();

        vm.prank(user);
        _wrapper(token).setOperator(operator, uint48(block.timestamp + 1 days));

        (externalEuint64 enc, bytes memory proof) = encryptUint64(amount, operator, token);
        vm.prank(operator);
        _wrapper(token).confidentialTransferFromAndCall(user, address(batcher), enc, proof, "");
    }

    /// @notice Ages the open batch past its minimum and dispatches it, returning the dispatched id.
    function _dispatch(IVaultBatcher batcher) internal returns (uint256 batchId) {
        batchId = batcher.currentBatchId();
        vm.warp(block.timestamp + batcher.minBatchAge() + 1);
        batcher.dispatchBatch();
    }

    /// @notice Settles a dispatched batch with a KMS proof over its unwrap amount.
    /// @dev The wrapper's `unwrapAmount(id)` is `euint64.wrap(id)`, so the request id is the handle.
    function _callback(IVaultBatcher batcher, uint256 batchId) internal {
        (uint64 cleartext, bytes memory decryptionProof) = _publicDecryptEuint64(batcher.unwrapRequestId(batchId));
        batcher.dispatchBatchCallback(batchId, cleartext, decryptionProof);
    }

    /// @notice Runs a batch end to end and returns the amount `user` claimed in `toToken` units.
    function _runBatch(IVaultBatcher batcher, address user, uint64 amount) internal returns (uint64 claimed) {
        _joinPush(batcher, user, amount);
        uint256 batchId = _dispatch(batcher);
        _callback(batcher, batchId);

        require(batcher.batchState(batchId) == IVaultBatcher.BatchState.Finalized, "batch did not finalize");
        claimed = decrypt(batcher.claim(batchId, user));
    }
}
