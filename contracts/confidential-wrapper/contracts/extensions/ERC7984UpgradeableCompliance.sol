// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {FHE, euint64} from "@fhevm/solidity/lib/FHE.sol";
import {ERC7984ERC20WrapperUpgradeable} from "./ERC7984ERC20WrapperUpgradeable.sol";
import {IComplianceOracle} from "../interfaces/IComplianceOracle.sol";

abstract contract ERC7984UpgradeableCompliance is ERC7984ERC20WrapperUpgradeable {
    /// @custom:storage-location erc7201:fhevm_protocol.storage.ERC7984UpgradeableCompliance
    struct ComplianceStorage {
        IComplianceOracle complianceOracle;
        address observer;
    }

    // keccak256(abi.encode(uint256(keccak256("fhevm_protocol.storage.ERC7984UpgradeableCompliance")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant COMPLIANCE_STORAGE_LOCATION =
        0x37bb7e1038390dc71ec6a94ecc7d0d3a9c505a7b3ce20733d36fc94be402f500;

    // wildcard sentinel: delegates decryption rights for all handles regardless of originating contract
    address private constant WILDCARD_DELEGATION_ADDRESS = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;

    // --- Events ---

    event ComplianceOracleUpdated(address indexed newOracle, address oldOracle);
    event ObserverTransferred(address indexed newObserver, address previousObserver);
    event ObserverRevoked(address indexed observer);

    // --- Errors ---

    error SanctionedAddress(address account);
    error UnauthorizedObserver(address caller);
    error InvalidObserver();

    // --- Modifiers ---

    modifier onlyObserver() {
        if (msg.sender != _getComplianceStorage().observer) revert UnauthorizedObserver(msg.sender);
        _;
    }

    // --- Storage accessors ---

    function _getComplianceStorage() internal pure returns (ComplianceStorage storage $) {
        assembly {
            $.slot := COMPLIANCE_STORAGE_LOCATION
        }
    }

    // --- Oracle management ---

    function complianceOracle() public view returns (address) {
        return address(_getComplianceStorage().complianceOracle);
    }

    function _setComplianceOracle(address oracle) internal {
        ComplianceStorage storage $ = _getComplianceStorage();
        address old = address($.complianceOracle);
        $.complianceOracle = IComplianceOracle(oracle);
        emit ComplianceOracleUpdated(oracle, old);
    }

    // --- Observer management ---

    function observer() public view returns (address) {
        return _getComplianceStorage().observer;
    }

    function renounceObserver() external onlyObserver {
        _revokeObserver();
    }

    function _setObserver(address newObserver) internal {
        if (newObserver == address(0)) revert InvalidObserver();
        ComplianceStorage storage $ = _getComplianceStorage();
        address previous = $.observer;
        if (previous != address(0)) {
            FHE.revokeUserDecryptionDelegation(previous, WILDCARD_DELEGATION_ADDRESS);
        }
        $.observer = newObserver;
        FHE.delegateUserDecryptionWithoutExpiration(newObserver, WILDCARD_DELEGATION_ADDRESS);
        emit ObserverTransferred(newObserver, previous);
    }

    function _revokeObserver() internal {
        ComplianceStorage storage $ = _getComplianceStorage();
        address current = $.observer;
        if (current == address(0)) return;
        $.observer = address(0);
        FHE.revokeUserDecryptionDelegation(current, WILDCARD_DELEGATION_ADDRESS);
        emit ObserverRevoked(current);
    }

    // --- Sanctions hooks ---

    function _transfer(address from, address to, euint64 amount) internal virtual override returns (euint64) {
        _validateTransferCompliance(from, to);
        return super._transfer(from, to, amount);
    }

    function wrap(address to, uint256 amount) public virtual override returns (euint64) {
        _validateMintCompliance(msg.sender, to);
        return super.wrap(to, amount);
    }

    function onTransferReceived(
        address operator,
        address from,
        uint256 amount,
        bytes calldata data
    ) public virtual override returns (bytes4) {
        address to = data.length < 20 ? from : address(bytes20(data));
        _validateMintCompliance(from, to);
        return super.onTransferReceived(operator, from, amount, data);
    }

    function _unwrap(address from, address to, euint64 amount) internal virtual override returns (bytes32) {
        _validateUnwrapCompliance(from, to);
        return super._unwrap(from, to, amount);
    }

    function _validateTransferCompliance(address from, address to) internal virtual {
        _validateCompliance(from, to);
    }

    function _validateMintCompliance(address sender, address to) internal virtual {
        _validateCompliance(sender, to);
    }

    function _validateUnwrapCompliance(address from, address to) internal virtual {
        _validateCompliance(from, to);
    }

    function _validateCompliance(address from, address to) internal virtual {
        IComplianceOracle oracle = _getComplianceStorage().complianceOracle;
        if (address(oracle) == address(0)) return;
        if (from != address(0)) _requireNotSanctioned(oracle, from);
        if (to != address(0)) _requireNotSanctioned(oracle, to);
        if (msg.sender != from && msg.sender != to) _requireNotSanctioned(oracle, msg.sender);
    }

    function _requireNotSanctioned(IComplianceOracle oracle, address account) private view {
        if (oracle.isSanctioned(account)) revert SanctionedAddress(account);
    }
}
