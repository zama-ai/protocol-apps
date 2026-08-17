// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

/**
 * @title CircleTypes
 * @notice ERC-6900 v0.7 types and errors shared by both Circle account products.
 * @dev ABI-identical redeclarations. Circle is 0.8.24 and the wrapper is `^0.8.27`, so there is no
 * shared compilation unit. Instances come from `deployCode`.
 */

// ---------------------------------------------------------------------------------------------
// Types: copies of circle-msca/msca/6900/v0.7/common/Structs.sol
// ---------------------------------------------------------------------------------------------

struct Call {
    address target;
    uint256 value;
    bytes data;
}

struct FunctionReference {
    address plugin;
    uint8 functionId;
}

// ---------------------------------------------------------------------------------------------
// Errors: redeclared so traces decode and expectRevert selectors match
// ---------------------------------------------------------------------------------------------

/// @dev circle-msca/msca/6900/shared/common/Errors.sol
error NotImplemented(bytes4 selector, uint8 functionId);

/// @dev circle-msca/msca/6900/v0.7/account/BaseMSCA.sol
error RuntimeValidationFailed(address plugin, uint8 functionId, bytes revertReason);

// ---------------------------------------------------------------------------------------------
// Shared account surface
// ---------------------------------------------------------------------------------------------

/// @notice The `BaseMSCA` surface both Circle products inherit.
interface ICircleAccountBase {
    function execute(address target, uint256 value, bytes calldata data) external payable returns (bytes memory);

    function executeBatch(Call[] calldata calls) external payable returns (bytes[] memory);

    function installPlugin(
        address plugin,
        bytes32 manifestHash,
        bytes calldata pluginInstallData,
        FunctionReference[] calldata dependencies
    ) external;

    /// @dev `IAccountLoupe`. Lists installed plugins but not the selectors they claim.
    function getInstalledPlugins() external view returns (address[] memory);
}
