// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {FhevmTest} from "forge-fhevm/FhevmTest.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {euint64, externalEuint64} from "encrypted-types/EncryptedTypes.sol";
import {Vm} from "forge-std/Vm.sol";

import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";

import {ConfidentialWrapper} from "confidential-wrapper/ConfidentialWrapper.sol";
import {ERC20Mock} from "confidential-wrapper/mocks/ERC20Mock.sol";

import {ConfidentialWrapperTreasury} from "../../../src/msca/ConfidentialWrapperTreasury.sol";
import {ICircleAccountBase} from "../../../src/msca/interfaces/CircleTypes.sol";

interface IManifestHasher {
    function manifestHash(address plugin) external view returns (bytes32);
}

/// @notice One decoded ERC-20 `Transfer`, for asserting on the hop path.
struct TokenTransfer {
    address from;
    address to;
    uint256 value;
}

/**
 * @title TreasuryFixture
 * @notice One confidential wrapper, one Circle ERC-6900 treasury account, and the migration between them.
 * @dev Starts the wrapper on the pinned implementation with the reserve at its own address.
 * Subclasses supply the account (MSCA or SCA) and how the DAO drives it.
 */
abstract contract TreasuryFixture is FhevmTest {
    /// @dev CoprocessorConfig ERC-7201 base (acl, coprocessor, kmsVerifier at +0/+1/+2).
    bytes32 internal constant FHEVM_CONFIG_BASE = 0x9e7b61f58c47dc699ac88507c4f5bb9f121c03808c5676a8078fe583e4649700;

    /// @dev OZ `Initializable` ERC-7201 slot: `_initialized` (uint64) packed with `_initializing`.
    bytes32 internal constant INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    /// @dev forge-fhevm's in-process host addresses. Deployed by {FhevmTest.setUp}.
    address internal constant LOCAL_FHEVM_ACL = 0x50157CFfD6bBFA2DECe204a89ec419c23ef5755D;
    address internal constant LOCAL_FHEVM_COPROCESSOR = 0xe3a9105a3a932253A70F126eb1E3b589C643dD24;
    address internal constant LOCAL_FHEVM_KMS_VERIFIER = 0x901F8942346f7AB3a01F6D7613119Bca447Bb030;

    /// @dev Canonical ERC-4337 v0.7 EntryPoint.
    address internal constant CANONICAL_ENTRYPOINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    /// @dev Protocol DAO. Owns the wrapper and receives the treasury at handover.
    uint256 internal constant DAO_PK = 0xDA0;

    /// @dev Third party that deploys the treasury account and hands it over.
    uint256 internal constant DEPLOYER_PK = 0xC1C1E;

    /// @dev 6 decimals so the wrapper rate is 1 and amounts map 1:1 with cUSDC.
    uint8 internal constant UNDERLYING_DECIMALS = 6;

    /// @dev 1.0 USDC.
    uint256 internal constant ONE = 1_000_000;

    ERC20Mock internal underlying;
    EntryPoint internal entryPoint;

    /// @notice The wrapper proxy, typed at the treasury implementation.
    /// @dev Treasury members only answer after {_migrateToTreasury}; before it the pinned V4 implementation runs.
    ConfidentialWrapperTreasury internal wrapper;

    /// @notice The Circle ERC-6900 account that holds the reserve.
    ICircleAccountBase internal treasury;

    /// @notice The wrapper's `owner()`, and so the only address that can migrate.
    address internal dao;

    /// @notice The third party that deploys the treasury account and hands it over.
    address internal deployer;

    /// @notice The key currently authorised to act for the treasury account.
    /// @dev Starts as {deployer}, becomes {dao} at handover.
    uint256 internal controllerPk = DEPLOYER_PK;

    /// @notice The address {controllerPk} belongs to.
    address internal controller;

    error UserOpReverted(bytes reason);

    function setUp() public virtual override {
        super.setUp();

        dao = vm.addr(DAO_PK);
        deployer = vm.addr(DEPLOYER_PK);
        controller = vm.addr(controllerPk);
        vm.label(dao, "ProtocolDAO");
        vm.label(deployer, "AccountDeployer");

        _deployEntryPoint();
        _deployAccount();
        _deployWrapperAtV3();
    }

    // ----- Subclass hooks -----

    /// @dev Deploy the Circle account and assign {treasury}.
    function _deployAccount() internal virtual;

    /// @notice Make the treasury account call `data` on `target`.
    /// @dev SCA: direct owner call. MSCA: signed user operation.
    function _run(address target, bytes memory data) internal virtual;

    /// @notice Same, for the account's own native functions (`installPlugin` and friends).
    function _runNative(bytes memory callData) internal virtual;

    /// @notice Hand control of the treasury account to `newPk`.
    function _handoverControlTo(uint256 newPk) internal virtual;

    /// @notice Whether `who` is currently recorded as a controller of the treasury account.
    function _isController(address who) internal view virtual returns (bool);

    // ----- Deployment -----

    /// @notice Puts the EntryPoint at its canonical address, which both Circle products hardcode.
    /// @dev Deployed first so its constructor creates `SenderCreator`, then etched. Virtual so a
    /// fork suite can bind to the live EntryPoint instead.
    function _deployEntryPoint() internal virtual {
        EntryPoint deployed = new EntryPoint();
        vm.etch(CANONICAL_ENTRYPOINT, address(deployed).code);
        entryPoint = EntryPoint(payable(CANONICAL_ENTRYPOINT));
        vm.label(CANONICAL_ENTRYPOINT, "EntryPoint");
    }

    /// @notice Deploys the wrapper on the pinned implementation, reserve at its own address.
    /// @dev Virtual so a fork suite can bind {wrapper} to a live proxy.
    function _deployWrapperAtV3() internal virtual {
        underlying = new ERC20Mock("USD Coin", "USDC", UNDERLYING_DECIMALS);
        vm.label(address(underlying), "USDC");

        wrapper = _newWrapperAtV3(IERC20(address(underlying)), bytes4(0), false);
        vm.label(address(wrapper), "cUSDC");
    }

    /// @notice Another wrapper on the pinned implementation, for cases the default 6-decimal USDC cannot reach.
    function _newWrapperAtV3(IERC20 token, bytes4 denyListSelector, bool hasDenyListSelector)
        internal
        returns (ConfidentialWrapperTreasury w)
    {
        ConfidentialWrapper impl = new ConfidentialWrapper();
        bytes memory initData = abi.encodeCall(
            ConfidentialWrapper.initialize,
            (
                "Confidential USD Coin",
                "cUSDC",
                "https://example.org/cusdc",
                token,
                dao,
                new address[](0),
                denyListSelector,
                hasDenyListSelector,
                new address[](0)
            )
        );
        w = ConfidentialWrapperTreasury(address(new ERC1967Proxy(address(impl), initData)));
        _repointFhevmConfig(address(w));
        _rewindToV3(address(w));
    }

    /**
     * @notice Puts a freshly deployed proxy back on initializer version 3, where the live wrappers are.
     * @dev `ConfidentialWrapper.initialize` advances to 4, past the version the migration upgrades from.
     */
    function _rewindToV3(address w) internal {
        vm.store(w, INITIALIZABLE_STORAGE, bytes32(uint256(3)));
    }

    /// @notice Repoints `w`'s FHE config at the in-process forge-fhevm host.
    function _repointFhevmConfig(address w) internal {
        vm.store(w, FHEVM_CONFIG_BASE, bytes32(uint256(uint160(LOCAL_FHEVM_ACL))));
        vm.store(w, bytes32(uint256(FHEVM_CONFIG_BASE) + 1), bytes32(uint256(uint160(LOCAL_FHEVM_COPROCESSOR))));
        vm.store(w, bytes32(uint256(FHEVM_CONFIG_BASE) + 2), bytes32(uint256(uint160(LOCAL_FHEVM_KMS_VERIFIER))));
    }

    // ----- Deployment sequence -----

    /// @notice Upgrades the wrapper with the V4 migration reinitializer, moving the reserve in the same transaction.
    function _migrateToTreasury() internal {
        _migrate(wrapper);
    }

    /// @notice {_migrateToTreasury} for a wrapper other than the default one.
    /// @dev Pranks `w.owner()`, not {dao}: on a fork those are different keys.
    function _migrate(ConfidentialWrapperTreasury w) internal {
        ConfidentialWrapperTreasury impl = new ConfidentialWrapperTreasury();
        vm.prank(w.owner());
        w.upgradeToAndCall(
            address(impl),
            abi.encodeCall(
                ConfidentialWrapperTreasury.reinitializeV4WithTreasury, (new address[](0), address(treasury))
            )
        );
    }

    /// @notice Grants the wrapper its USDC allowance from the treasury.
    function _grantWrapperAllowance(uint256 amount) internal {
        _grantAllowance(IERC20(address(underlying)), address(wrapper), amount);
    }

    /// @notice {_grantWrapperAllowance} for an arbitrary token and spender.
    function _grantAllowance(IERC20 token, address spender, uint256 amount) internal {
        _run(address(token), abi.encodeCall(IERC20.approve, (spender, amount)));
    }

    /// @notice Hands ownership of the treasury account to the Protocol DAO.
    function _handoverToDao() internal {
        _handoverControlTo(DAO_PK);
    }

    /// @notice Handover, allowance, then migration — allowance first so settlement is armed when the reserve arrives.
    function _completeDeployment() internal {
        _handoverToDao();
        _grantWrapperAllowance(type(uint256).max);
        _migrateToTreasury();
    }

    // ----- Wrapper flows -----

    /// @notice A user wraps `amount` through the direct {ConfidentialWrapper.wrap} path.
    function _wrap(address user, uint256 amount) internal returns (euint64) {
        return _wrapOn(wrapper, IERC20(address(underlying)), user, amount);
    }

    /// @notice {_wrap} against a wrapper other than the default one.
    function _wrapOn(ConfidentialWrapperTreasury w, IERC20 token, address user, uint256 amount)
        internal
        returns (euint64)
    {
        deal(address(token), user, amount);
        vm.startPrank(user);
        token.approve(address(w), amount);
        euint64 minted = w.wrap(user, amount);
        vm.stopPrank();
        return minted;
    }

    /// @notice A user wraps `amount` through the ERC-1363 `transferAndCall` callback path.
    function _wrapViaTransferAndCall(address user, uint256 amount) internal {
        deal(address(underlying), user, amount);
        vm.prank(user);
        underlying.transferAndCall(address(wrapper), amount);
    }

    /// @notice Requests an unwrap of `amount` from `user` to `to`, returning the request id.
    function _requestUnwrap(address user, address to, uint64 amount) internal returns (bytes32) {
        return _requestUnwrapOn(wrapper, user, to, amount);
    }

    /// @notice {_requestUnwrap} against a wrapper other than the default one.
    function _requestUnwrapOn(ConfidentialWrapperTreasury w, address user, address to, uint64 amount)
        internal
        returns (bytes32)
    {
        (externalEuint64 enc, bytes memory proof) = encryptUint64(amount, user, address(w));
        vm.prank(user);
        return w.unwrap(user, to, enc, proof);
    }

    /// @notice A burnt, decrypted unwrap request waiting only on the underlying transfer.
    function _pendingUnwrapOn(ConfidentialWrapperTreasury w, address user, uint64 amount)
        internal
        returns (bytes32 unwrapId, uint64 cleartext, bytes memory proof)
    {
        unwrapId = _requestUnwrapOn(w, user, user, amount);
        (cleartext, proof) = _publicDecryptEuint64(unwrapId);
    }

    /// @notice Runs the two-phase unwrap settlement: public-decrypt the amount, then finalize.
    function _finalizeUnwrap(bytes32 unwrapId) internal {
        (uint64 cleartext, bytes memory decryptionProof) = _publicDecryptEuint64(unwrapId);
        wrapper.finalizeUnwrap(unwrapId, cleartext, decryptionProof);
    }

    /// @notice Publicly decrypts one euint64 handle and builds the scalar proof `finalizeUnwrap` expects.
    function _publicDecryptEuint64(bytes32 handle) internal returns (uint64 cleartext, bytes memory decryptionProof) {
        _processNewLogs();
        if (!_acl.isAllowedForDecryption(handle)) {
            revert HandleNotAllowedForPublicDecryption(handle);
        }
        cleartext = uint64(_plaintexts[handle]);
        decryptionProof = buildDecryptionProof(handle, abi.encode(cleartext));
    }

    /// @notice Decrypts a holder's confidential balance via the local mock DB.
    function _balance(address holder) internal returns (uint64) {
        return decrypt(wrapper.confidentialBalanceOf(holder));
    }

    // ----- Execution: ERC-4337 user-op path -----

    /// @dev Product-specific. SCA: EIP-191 over the userOpHash. MSCA: plugin encoding.
    function _signUserOp(PackedUserOperation memory op) internal view virtual returns (bytes memory);

    /// @notice `execute(target, 0, data)` through a signed user operation.
    function _execViaUserOp(address target, bytes memory data) internal {
        _accountUserOp(abi.encodeCall(ICircleAccountBase.execute, (target, 0, data)));
    }

    /// @notice Runs arbitrary account-native calldata through a signed user operation.
    function _accountUserOp(bytes memory callData) internal {
        bytes memory reason = _runUserOp(callData);
        if (reason.length != 0) {
            revert UserOpReverted(reason);
        }
    }

    /// @notice External entry point to {_execViaUserOp}, so a test can assert submission reverts.
    /// @dev Failed validation reverts `handleOps`; `vm.expectRevert` would otherwise bind to the deposit top-up.
    function execViaUserOpExternal(address target, bytes calldata data) external {
        _execViaUserOp(target, data);
    }

    /// @dev Signs and submits one user op; returns the revert payload, or empty bytes on success.
    function _runUserOp(bytes memory callData) private returns (bytes memory) {
        vm.deal(address(treasury), 1 ether);
        vm.prank(address(treasury));
        entryPoint.depositTo{value: 1 ether}(address(treasury));

        PackedUserOperation memory op = PackedUserOperation({
            sender: address(treasury),
            nonce: entryPoint.getNonce(address(treasury), 0),
            initCode: "",
            callData: callData,
            // verificationGasLimit (high 128 bits) | callGasLimit (low 128 bits)
            accountGasLimits: bytes32((uint256(2_000_000) << 128) | uint256(5_000_000)),
            preVerificationGas: 100_000,
            // maxPriorityFeePerGas (high 128 bits) | maxFeePerGas (low 128 bits)
            gasFees: bytes32((uint256(1 gwei) << 128) | uint256(10 gwei)),
            paymasterAndData: "",
            signature: ""
        });
        op.signature = _signUserOp(op);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;

        // Use {FhevmTest.getRecordedLogs}, never `vm.getRecordedLogs()`: the raw cheatcode drains
        // the buffer without dispatching FHE events, emptying the mock plaintext DB.
        getRecordedLogs();
        entryPoint.handleOps(ops, payable(makeAddr("bundler")));
        return _findUserOpRevertReason(getRecordedLogs());
    }

    /// @dev Extracts the reason from a `UserOperationRevertReason(bytes32,address,uint256,bytes)` log.
    function _findUserOpRevertReason(Vm.Log[] memory logs) private pure returns (bytes memory) {
        bytes32 topic = keccak256("UserOperationRevertReason(bytes32,address,uint256,bytes)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                (, bytes memory reason) = abi.decode(logs[i].data, (uint256, bytes));
                return reason;
            }
        }
        return "";
    }

    // ----- Small helpers -----

    /// @dev 65-byte ECDSA signature over `digest` from `pk` (r || s || v).
    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Deploys a contract compiled by `profile.circle` into `out-circle/`.
    function _deployCircle(string memory file, string memory name) internal returns (address) {
        return deployCode(string.concat("out-circle/", file, "/", name, ".json"));
    }

    /// @dev {_deployCircle} with constructor args.
    function _deployCircle(string memory file, string memory name, bytes memory args) internal returns (address) {
        return deployCode(string.concat("out-circle/", file, "/", name, ".json"), args);
    }

    /// @dev The manifest hash `installPlugin` verifies, for any ERC-6900 v0.7 plugin.
    function _manifestHash(address plugin) internal returns (bytes32) {
        return IManifestHasher(_deployCircle("ManifestHasher.sol", "ManifestHasher")).manifestHash(plugin);
    }

    // ----- Log inspection -----

    /// @notice Discards everything logged so far, so the next {_transfersOf} sees only what follows.
    /// @dev Never `vm.getRecordedLogs()` here — see {_runUserOp}.
    function _watchLogs() internal {
        getRecordedLogs();
    }

    /// @notice Every ERC-20 `Transfer` emitted by `token` since the last {_watchLogs}, in order.
    function _transfersOf(address token) internal returns (TokenTransfer[] memory transfers) {
        bytes32 topic = keccak256("Transfer(address,address,uint256)");
        Vm.Log[] memory logs = getRecordedLogs();

        uint256 count;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == token && logs[i].topics.length == 3 && logs[i].topics[0] == topic) count++;
        }

        transfers = new TokenTransfer[](count);
        uint256 j;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != token || logs[i].topics.length != 3 || logs[i].topics[0] != topic) continue;
            transfers[j++] = TokenTransfer({
                from: address(uint160(uint256(logs[i].topics[1]))),
                to: address(uint160(uint256(logs[i].topics[2]))),
                value: abi.decode(logs[i].data, (uint256))
            });
        }
    }
}
