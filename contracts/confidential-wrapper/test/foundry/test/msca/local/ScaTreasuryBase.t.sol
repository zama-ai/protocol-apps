// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";

import {ICircleSca, ICircleScaFactory} from "../../../src/msca/interfaces/ICircleSca.sol";
import {TreasuryFixture} from "./TreasuryFixture.t.sol";

/**
 * @title ScaTreasuryBase
 * @notice The treasury account as `circle_6900_singleowner_v3` — Circle's SCA.
 * @dev Native owner in account storage. Handover is `transferNativeOwnership`; treasury actions are direct owner calls.
 */
abstract contract ScaTreasuryBase is TreasuryFixture {
    using MessageHashUtils for bytes32;

    ICircleSca internal sca;
    ICircleScaFactory internal scaFactory;

    /// @inheritdoc TreasuryFixture
    /// @dev Circle contracts compile at 0.8.24; `profile.circle` writes them to `out-circle/`.
    function _deployAccount() internal override {
        address pluginManager = _deployCircle("PluginManager.sol", "PluginManager");
        scaFactory = ICircleScaFactory(
            _deployCircle(
                "SingleOwnerMSCAFactory.sol", "SingleOwnerMSCAFactory", abi.encode(CANONICAL_ENTRYPOINT, pluginManager)
            )
        );
        // `sender` and `salt` only mix into the CREATE2 salt; `initializingData` carries the owner.
        sca = ICircleSca(scaFactory.createAccount(controller, bytes32(0), abi.encode(controller)));
        treasury = sca;
        vm.label(address(sca), "Treasury(SCA)");
    }

    /// @inheritdoc TreasuryFixture
    function _run(address target, bytes memory data) internal override {
        vm.prank(controller);
        sca.execute(target, 0, data);
    }

    /// @inheritdoc TreasuryFixture
    function _runNative(bytes memory callData) internal override {
        vm.prank(controller);
        (bool ok, bytes memory ret) = address(sca).call(callData);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// @inheritdoc TreasuryFixture
    /// @dev Immediate and single-step: no acceptance leg.
    function _handoverControlTo(uint256 newPk) internal override {
        vm.prank(controller);
        sca.transferNativeOwnership(vm.addr(newPk));
        controllerPk = newPk;
        controller = vm.addr(newPk);
    }

    /// @inheritdoc TreasuryFixture
    function _isController(address who) internal view override returns (bool) {
        return sca.getNativeOwner() == who;
    }

    /// @inheritdoc TreasuryFixture
    /// @dev Owner signature over the EIP-191 prefixed userOpHash. No plugin involved while a native owner is set.
    function _signUserOp(PackedUserOperation memory op) internal view override returns (bytes memory) {
        return _sign(controllerPk, entryPoint.getUserOpHash(op).toEthSignedMessageHash());
    }
}
