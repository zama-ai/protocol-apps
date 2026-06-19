// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {IConfidentialWrapperDenyList} from "confidential-deny-list/contracts/interfaces/IConfidentialWrapperDenyList.sol";

/// @dev Test-only mock for {IConfidentialWrapperDenyList}. No access control — permissionless writes.
contract MockConfidentialWrapperDenyList is IConfidentialWrapperDenyList {
    mapping(address account => bool denied) private _denied;

    function addToDenyList(address[] calldata accounts) external {
        for (uint256 i = 0; i < accounts.length; i++) {
            _denied[accounts[i]] = true;
        }
    }

    function isDenied(address account) external view returns (bool) {
        return _denied[account];
    }
}
