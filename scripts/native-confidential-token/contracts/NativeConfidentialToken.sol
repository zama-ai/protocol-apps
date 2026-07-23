// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {FHE, externalEuint64, euint64} from "@fhevm/solidity/lib/FHE.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ZamaEthereumConfigUpgradeable} from "confidential-token-base/contracts/fhevm/ZamaEthereumConfigUpgradeable.sol";
import {ERC7984Upgradeable} from "confidential-token-base/contracts/token/ERC7984Upgradeable.sol";

/// @title NativeConfidentialToken
/// @notice Minimal reproducible example of a native upgradeable ERC7984 token.
/// @dev This contract is a reference example for documentation and testing only.
/// It is not an officially supported implementation, not a production-ready deployment target,
/// and not a commitment that this exact contract shape will be maintained as a supported surface.
contract NativeConfidentialToken is
    ERC7984Upgradeable,
    ZamaEthereumConfigUpgradeable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable
{
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name_,
        string memory symbol_,
        string memory contractURI_,
        address owner_
    ) public initializer {
        __ERC7984_init(name_, symbol_, contractURI_);
        __ZamaEthereumConfig_init();
        __Ownable_init(owner_);
        __Ownable2Step_init();
    }

    function mint(
        address to,
        externalEuint64 encryptedAmount,
        bytes calldata inputProof
    ) external onlyOwner returns (euint64) {
        return _mint(to, FHE.fromExternal(encryptedAmount, inputProof));
    }

    function burn(
        externalEuint64 encryptedAmount,
        bytes calldata inputProof
    ) external returns (euint64) {
        return _burn(msg.sender, FHE.fromExternal(encryptedAmount, inputProof));
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
