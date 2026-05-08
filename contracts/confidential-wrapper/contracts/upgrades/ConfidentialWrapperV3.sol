// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {euint64} from "@fhevm/solidity/lib/FHE.sol";
import {ERC7984Upgradeable} from "../token/ERC7984Upgradeable.sol";
import {ERC7984ERC20WrapperUpgradeable} from "../extensions/ERC7984ERC20WrapperUpgradeable.sol";
import {ERC7984UpgradeableCompliance} from "../extensions/ERC7984UpgradeableCompliance.sol";
import {ConfidentialWrapperV2} from "./ConfidentialWrapperV2.sol";

contract ConfidentialWrapperV3 is ConfidentialWrapperV2, ERC7984UpgradeableCompliance {
    /// @custom:oz-upgrades-validate-as-initializer
    function reinitializeV3() public reinitializer(3) {}

    function setComplianceOracle(address oracle) external onlyOwner {
        _setComplianceOracle(oracle);
    }

    function transferObserver(address newObserver) external onlyOwner {
        _setObserver(newObserver);
    }

    function revokeObserver() external onlyOwner {
        _revokeObserver();
    }

    function wrap(
        address to,
        uint256 amount
    ) public override(ERC7984UpgradeableCompliance, ERC7984ERC20WrapperUpgradeable) returns (euint64) {
        return super.wrap(to, amount);
    }

    function onTransferReceived(
        address operator,
        address from,
        uint256 amount,
        bytes calldata data
    ) public override(ERC7984UpgradeableCompliance, ERC7984ERC20WrapperUpgradeable) returns (bytes4) {
        return super.onTransferReceived(operator, from, amount, data);
    }

    function _transfer(
        address from,
        address to,
        euint64 amount
    ) internal override(ERC7984UpgradeableCompliance, ERC7984Upgradeable) returns (euint64) {
        return super._transfer(from, to, amount);
    }

    function _unwrap(
        address from,
        address to,
        euint64 amount
    ) internal override(ERC7984UpgradeableCompliance, ERC7984ERC20WrapperUpgradeable) returns (bytes32) {
        return super._unwrap(from, to, amount);
    }
}
