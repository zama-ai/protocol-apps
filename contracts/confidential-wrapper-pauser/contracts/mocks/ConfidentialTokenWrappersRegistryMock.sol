// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import { IConfidentialTokenWrappersRegistry } from "../interfaces/IConfidentialTokenWrappersRegistry.sol";

/**
 * @title ConfidentialTokenWrappersRegistryMock
 * @notice The `isConfidentialTokenValid` read path of `ConfidentialTokenWrappersRegistry`, with free registration
 * and revocation so tests can list any address, wrapper or not, as a valid entry. Test-only.
 */
contract ConfidentialTokenWrappersRegistryMock is IConfidentialTokenWrappersRegistry {
    mapping(address confidentialToken => bool isValid) private _valid;

    function register(address confidentialToken) external {
        _valid[confidentialToken] = true;
    }

    function revoke(address confidentialToken) external {
        _valid[confidentialToken] = false;
    }

    function isConfidentialTokenValid(address confidentialToken) external view override returns (bool) {
        return _valid[confidentialToken];
    }
}
