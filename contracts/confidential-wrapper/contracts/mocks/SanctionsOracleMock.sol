// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {IComplianceOracle} from "../interfaces/IComplianceOracle.sol";

contract SanctionsOracleMock is IComplianceOracle {
    mapping(address => bool) private _sanctioned;

    function isSanctioned(address account) external view returns (bool) {
        return _sanctioned[account];
    }

    function setSanctioned(address account, bool sanctioned) external {
        _sanctioned[account] = sanctioned;
    }
}
