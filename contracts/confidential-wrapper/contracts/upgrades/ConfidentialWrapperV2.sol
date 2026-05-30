// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {ConfidentialWrapper} from "../ConfidentialWrapper.sol";

/**
 * @title ConfidentialWrapperV2
 * @notice Upgrade contract to align with OpenZeppelin/openzeppelin-confidential-contracts v0.4.0.
 */
contract ConfidentialWrapperV2 is ConfidentialWrapper {
    /**
     * @notice Re-initializes the contract.
     */
    /// @custom:oz-upgrades-validate-as-initializer
    function reinitializeV2() public virtual reinitializer(2) {}
}
