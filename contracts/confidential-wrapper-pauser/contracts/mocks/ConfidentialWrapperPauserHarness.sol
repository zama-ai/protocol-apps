// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import { ConfidentialWrapperPauser } from "../ConfidentialWrapperPauser.sol";
import { IConfidentialTokenWrappersRegistry } from "../interfaces/IConfidentialTokenWrappersRegistry.sol";

/**
 * @title ConfidentialWrapperPauserHarness
 * @notice Exposes the internal `_setRoleAdmin` resolution of {ConfidentialWrapperPauser}, which no external path
 * reaches, so the unit tests can prove the default-admin rules still apply to it. Test-only.
 */
contract ConfidentialWrapperPauserHarness is ConfidentialWrapperPauser {
    constructor(
        uint48 initialDelay,
        address initialAdmin,
        IConfidentialTokenWrappersRegistry registry_,
        address[] memory initialPausers
    ) ConfidentialWrapperPauser(initialDelay, initialAdmin, registry_, initialPausers) {}

    function exposedSetRoleAdmin(bytes32 role, bytes32 adminRole) external {
        _setRoleAdmin(role, adminRole);
    }
}
