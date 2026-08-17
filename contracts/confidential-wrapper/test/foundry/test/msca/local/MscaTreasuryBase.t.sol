// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";

import {ICircleMsca, ICircleMscaFactory} from "../../../src/msca/interfaces/ICircleMsca.sol";
import {IWeightedMultisigPlugin} from "../../../src/msca/interfaces/IWeightedMultisigPlugin.sol";
import {TreasuryFixture} from "./TreasuryFixture.t.sol";

/**
 * @title MscaTreasuryBase
 * @notice The treasury account as `circle_6900_v1` — Circle's MSCA.
 * @dev Control lives in `WeightedWebauthnMultisigPlugin`. Handover is a signer-set rotation.
 * Every DAO action is a signed user operation. Starts as one EOA signer at threshold 1.
 */
abstract contract MscaTreasuryBase is TreasuryFixture {
    ICircleMsca internal msca;
    ICircleMscaFactory internal mscaFactory;
    IWeightedMultisigPlugin internal multisigPlugin;

    /// @inheritdoc TreasuryFixture
    /// @dev Circle contracts compile at 0.8.24; `profile.circle` writes them to `out-circle/`.
    function _deployAccount() internal override {
        address pluginManager = _deployCircle("PluginManager.sol", "PluginManager");
        multisigPlugin = IWeightedMultisigPlugin(
            _deployCircle(
                "WeightedWebauthnMultisigPlugin.sol", "WeightedWebauthnMultisigPlugin", abi.encode(CANONICAL_ENTRYPOINT)
            )
        );

        address factoryOwner = makeAddr("factoryOwner");
        mscaFactory = ICircleMscaFactory(
            _deployCircle(
                "UpgradableMSCAFactory.sol",
                "UpgradableMSCAFactory",
                abi.encode(factoryOwner, CANONICAL_ENTRYPOINT, pluginManager)
            )
        );

        // Factory refuses to install a plugin it has not been told to trust.
        address[] memory plugins = new address[](1);
        plugins[0] = address(multisigPlugin);
        bool[] memory permissions = new bool[](1);
        permissions[0] = true;
        vm.prank(factoryOwner);
        mscaFactory.setPlugins(plugins, permissions);

        bytes32[] memory manifestHashes = new bytes32[](1);
        manifestHashes[0] = _manifestHash(address(multisigPlugin));

        bytes[] memory installData = new bytes[](1);
        installData[0] = _multisigInstallData(controller);

        msca = ICircleMsca(
            mscaFactory.createAccount(
                bytes32(uint256(uint160(controller))), bytes32(0), abi.encode(plugins, manifestHashes, installData)
            )
        );
        treasury = msca;
        vm.label(address(msca), "Treasury(MSCA)");
    }

    /// @inheritdoc TreasuryFixture
    function _run(address target, bytes memory data) internal override {
        _execViaUserOp(target, data);
    }

    /// @inheritdoc TreasuryFixture
    function _runNative(bytes memory callData) internal override {
        _accountUserOp(callData);
    }

    /**
     * @inheritdoc TreasuryFixture
     * @dev Add the incoming signer, then remove the outgoing one. `removeOwners` refuses a zero-owner
     * account, and the two calls cannot be batched. In between, either signer can act at threshold 1.
     */
    function _handoverControlTo(uint256 newPk) internal override {
        address newOwner = vm.addr(newPk);

        address[] memory toAdd = new address[](1);
        toAdd[0] = newOwner;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;
        _accountUserOp(
            abi.encodeCall(
                IWeightedMultisigPlugin.addOwners,
                (toAdd, weights, new IWeightedMultisigPlugin.PublicKey[](0), new uint256[](0), 1)
            )
        );

        address[] memory toRemove = new address[](1);
        toRemove[0] = controller;
        _accountUserOp(
            abi.encodeCall(
                IWeightedMultisigPlugin.removeOwners, (toRemove, new IWeightedMultisigPlugin.PublicKey[](0), 1)
            )
        );

        controllerPk = newPk;
        controller = newOwner;
    }

    /// @inheritdoc TreasuryFixture
    /// @dev Read from the plugin; the account has no owner accessor.
    function _isController(address who) internal view override returns (bool) {
        (bytes30[] memory ownerIds,,) = multisigPlugin.ownershipInfoOf(address(msca));
        bytes30 id = _ownerId(who);
        for (uint256 i; i < ownerIds.length; i++) {
            if (ownerIds[i] == id) return true;
        }
        return false;
    }

    /**
     * @inheritdoc TreasuryFixture
     * @dev One 65-byte frame per signing owner, ordered by owner id ascending, exactly one marked
     * with `v + 32` to show it covers the actual user-op digest rather than the minimal one.
     */
    function _signUserOp(PackedUserOperation memory op) internal view override returns (bytes memory) {
        bytes32 actualDigest = MessageHashUtils.toEthSignedMessageHash(entryPoint.getUserOpHash(op));
        bytes32 minimalDigest = MessageHashUtils.toEthSignedMessageHash(_minimalUserOpHash(op));

        uint256[] memory pks = _signingPks();
        bytes memory frames;
        for (uint256 i; i < pks.length; i++) {
            bool marked = i == 0;
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(pks[i], marked ? actualDigest : minimalDigest);
            frames = abi.encodePacked(frames, r, s, marked ? v + 32 : v);
        }
        return frames;
    }

    /// @dev Signing keys ordered by owner id ascending: `checkNSignatures` rejects any owner id `<= lastOwner`.
    function _signingPks() internal view returns (uint256[] memory pks) {
        uint256[] memory extra = _cosignerPks();
        pks = new uint256[](1 + extra.length);
        pks[0] = controllerPk;
        for (uint256 i; i < extra.length; i++) {
            pks[1 + i] = extra[i];
        }

        for (uint256 i = 1; i < pks.length; i++) {
            uint256 held = pks[i];
            uint256 j = i;
            while (j > 0 && uint240(_ownerId(vm.addr(pks[j - 1]))) > uint240(_ownerId(vm.addr(held)))) {
                pks[j] = pks[j - 1];
                j--;
            }
            pks[j] = held;
        }
    }

    /// @dev Additional keys that must co-sign. Empty by default; a test raising the threshold sets it.
    function _cosignerPks() internal view virtual returns (uint256[] memory) {
        return new uint256[](0);
    }

    /// @dev `BaseMultisigPlugin._getMinimalUserOpDigest`: user-op hash with gas fields and `paymasterAndData` zeroed.
    function _minimalUserOpHash(PackedUserOperation memory op) internal view returns (bytes32) {
        bytes32 inner = keccak256(
            abi.encode(
                op.sender,
                op.nonce,
                keccak256(op.initCode),
                keccak256(op.callData),
                bytes32(0), // accountGasLimits
                uint256(0), // preVerificationGas
                bytes32(0), // gasFees
                keccak256("") // paymasterAndData
            )
        );
        return keccak256(abi.encode(inner, CANONICAL_ENTRYPOINT, block.chainid));
    }

    /// @dev The 30-byte key the plugin stores and orders an EOA owner under.
    function _ownerId(address addr) internal pure returns (bytes30) {
        return bytes30(uint240(uint160(addr)));
    }

    /// @dev The plugin's `onInstall` payload: one EOA owner at weight 1, threshold 1.
    function _multisigInstallData(address owner_) private pure returns (bytes memory) {
        address[] memory owners = new address[](1);
        owners[0] = owner_;
        uint256[] memory ownerWeights = new uint256[](1);
        ownerWeights[0] = 1;
        return
            abi.encode(owners, ownerWeights, new IWeightedMultisigPlugin.PublicKey[](0), new uint256[](0), uint256(1));
    }
}
