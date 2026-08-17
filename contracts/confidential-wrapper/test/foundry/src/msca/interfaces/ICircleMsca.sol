// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {ICircleAccountBase} from "./CircleTypes.sol";

/**
 * @title ICircleMsca: Circle's MSCA, `circle_6900_v1`
 * @notice Upstream: `UpgradableMSCA`. Ownership lives in installed plugins, not on the account.
 *
 * | | |
 * | --- | --- |
 * | Product | `circle_6900_v1` |
 * | ERC-6900 | v0.7 |
 * | ERC-4337 | **v0.7** (EntryPoint `0x0000000071727De22E5E9d8BAf0edAc6f37da032`) |
 * | Factory | `0x0000000DF7E6c9Dc387cAFc5eCBfa6c3a6179AdD` |
 * | Implementation | `0xA70F1296869DA9D7CB69578123F21888E6dB2B62` |
 */
interface ICircleMsca is ICircleAccountBase {}

/// @notice `UpgradableMSCAFactory`.
/// @dev Gates installation behind a plugin allowlist. `sender` is `bytes32`; the account is initialised with plugins.
interface ICircleMscaFactory {
    /// @param initializingData `abi.encode(address[] plugins, bytes32[] manifestHashes, bytes[] pluginInstallData)`.
    function createAccount(bytes32 sender, bytes32 salt, bytes calldata initializingData)
        external
        returns (address account);

    /// @dev A plugin must be permitted here before `createAccount` will install it.
    function setPlugins(address[] calldata plugins, bool[] calldata permissions) external;
}
