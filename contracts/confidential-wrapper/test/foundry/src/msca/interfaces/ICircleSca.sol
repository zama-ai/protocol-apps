// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {ICircleAccountBase} from "./CircleTypes.sol";

/**
 * @title ICircleSca: Circle's SCA, `circle_6900_singleowner_v3`
 * @notice Upstream: `SingleOwnerMSCA`. Native owner in account storage.
 *
 * | | |
 * | --- | --- |
 * | Product | `circle_6900_singleowner_v3` |
 * | ERC-6900 | v0.7 |
 * | ERC-4337 | **v0.6** as deployed (EntryPoint `0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789`) |
 * | Factory | `0xf61023061ed45fa9eAC4D2670649cE1FD37ce536` |
 * | Implementation | `0xD206aC7fEf53d83ED4563E770b28Dba90D0D9eC8` |
 */
interface ICircleSca is ICircleAccountBase {
    function getNativeOwner() external view returns (address);

    function transferNativeOwnership(address newOwner) external;
}

/// @dev `SingleOwnerMSCAFactory`. `createAccount` returns `SingleOwnerMSCA`; a contract type is `address` in the ABI.
interface ICircleScaFactory {
    function createAccount(address sender, bytes32 salt, bytes calldata initializingData)
        external
        returns (address account);
}
