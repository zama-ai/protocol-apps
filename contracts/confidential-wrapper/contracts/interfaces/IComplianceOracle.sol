// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

interface IComplianceOracle {
    function isSanctioned(address account) external view returns (bool);
}
