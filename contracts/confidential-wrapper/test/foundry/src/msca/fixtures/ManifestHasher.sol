// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.24;

import {IPlugin} from "circle-msca/msca/6900/v0.7/interfaces/IPlugin.sol";

/**
 * @title ManifestHasher
 * @notice `keccak256(abi.encode(plugin.pluginManifest()))` for ERC-6900 v0.7 plugins.
 * @dev Lives at 0.8.24 because `PluginManifest` is a Circle type.
 */
contract ManifestHasher {
    function manifestHash(address plugin) external view returns (bytes32) {
        return keccak256(abi.encode(IPlugin(plugin).pluginManifest()));
    }
}
