// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IConfidentialWrapperDenyList} from "./interfaces/IConfidentialWrapperDenyList.sol";

/**
 * @title ConfidentialWrapperDenyList
 * @notice Shared on-chain deny-list registry, inspired by the deprecated
 * Chainalysis sanctions oracle. Centralizes denied addresses (e.g. OFAC-sanctioned) so they
 * do not need to be maintained separately on each {ConfidentialWrapperV4}.
 */
contract ConfidentialWrapperDenyList is IConfidentialWrapperDenyList, UUPSUpgradeable, Ownable2StepUpgradeable {
    /// @custom:storage-location erc7201:fhevm_protocol.storage.ConfidentialWrapperDenyList
    struct ConfidentialWrapperDenyListStorage {
        mapping(address account => bool denied) _denied;
    }

    // keccak256(abi.encode(uint256(keccak256("fhevm_protocol.storage.ConfidentialWrapperDenyList")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CONFIDENTIAL_WRAPPER_DENY_LIST_STORAGE_LOCATION =
        0xbcfd86ba1ea9e3dba11fed554b5611c778a7b7489c88978678afa4cc3a8c4100;

    event DeniedAddressesAdded(address[] accounts);
    event DeniedAddressesRemoved(address[] accounts);

    /// @dev Thrown when attempting to add an account that is already on the deny-list.
    error AccountAlreadyDenied(address account);

    /// @dev Thrown when attempting to remove an account that is not on the deny-list.
    error AccountNotDenied(address account);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _getConfidentialWrapperDenyListStorage()
        internal
        pure
        returns (ConfidentialWrapperDenyListStorage storage $)
    {
        assembly {
            $.slot := CONFIDENTIAL_WRAPPER_DENY_LIST_STORAGE_LOCATION
        }
    }

    /// @dev Sets the initial owner
    function initialize(address owner_) public initializer {
        __Ownable_init(owner_);
        __Ownable2Step_init();
    }

    function name() external pure returns (string memory) {
        return "Confidential Wrapper DenyList";
    }

    /// @dev Adds `accounts` to the deny-list. Reverts if any account is already denied.
    function addToDenyList(address[] calldata accounts) external onlyOwner {
        ConfidentialWrapperDenyListStorage storage $ = _getConfidentialWrapperDenyListStorage();
        uint256 length = accounts.length;
        for (uint256 i = 0; i < length; i++) {
            if ($._denied[accounts[i]]) revert AccountAlreadyDenied(accounts[i]);
            $._denied[accounts[i]] = true;
        }
        emit DeniedAddressesAdded(accounts);
    }

    /// @dev Removes `accounts` from the deny-list. Reverts if any account is not currently denied.
    function removeFromDenyList(address[] calldata accounts) external onlyOwner {
        ConfidentialWrapperDenyListStorage storage $ = _getConfidentialWrapperDenyListStorage();
        uint256 length = accounts.length;
        for (uint256 i = 0; i < length; i++) {
            if (!$._denied[accounts[i]]) revert AccountNotDenied(accounts[i]);
            $._denied[accounts[i]] = false;
        }
        emit DeniedAddressesRemoved(accounts);
    }

    /// @dev Returns whether `account` is on the deny-list.
    function isDenied(address account) public view returns (bool) {
        return _getConfidentialWrapperDenyListStorage()._denied[account];
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
