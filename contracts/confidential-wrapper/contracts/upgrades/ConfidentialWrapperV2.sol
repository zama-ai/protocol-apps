// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ConfidentialWrapper} from "../ConfidentialWrapper.sol";

/**
 * @title ConfidentialWrapperV2
 * @notice Upgrade contract to align with OpenZeppelin/openzeppelin-confidential-contracts v0.4.0.
 */
contract ConfidentialWrapperV2 is ConfidentialWrapper {
    /// @dev Thrown when the wrong initializer is called for the contract version.
    error ConfidentialWrapperInvalidInitializerVersion();

    /// @dev Disabled in V2. Use {initializeV2} instead.
    /// @custom:oz-upgrades-unsafe-allow missing-initializer-call
    function initialize(string memory, string memory, string memory, IERC20, address) public virtual override {
        revert ConfidentialWrapperInvalidInitializerVersion();
    }

    /**
     * @notice Initializes the contract when deployed fresh at V2.
     * Advances the initializer version to 2 so reinitializers below this version cannot be replayed.
     */
    function initializeV2(
        string memory name_,
        string memory symbol_,
        string memory contractURI_,
        IERC20 underlying_,
        address owner_
    ) public virtual reinitializer(2) {
        __ConfidentialWrapperV2_init(name_, symbol_, contractURI_, underlying_, owner_);
    }

    function __ConfidentialWrapperV2_init(
        string memory name_,
        string memory symbol_,
        string memory contractURI_,
        IERC20 underlying_,
        address owner_
    ) internal onlyInitializing {
        __ConfidentialWrapper_init(name_, symbol_, contractURI_, underlying_, owner_);
        __ConfidentialWrapperV2_init_unchained();
    }

    /// @dev No V2-specific storage.
    function __ConfidentialWrapperV2_init_unchained() internal onlyInitializing {}

    /**
     * @notice Re-initializes the contract when upgrading from V1.
     */
    function reinitializeV2() public virtual reinitializer(2) {
        __ConfidentialWrapperV2_init_unchained();
    }
}
