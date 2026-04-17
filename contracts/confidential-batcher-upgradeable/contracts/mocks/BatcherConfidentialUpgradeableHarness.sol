// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC7984ERC20Wrapper} from "@openzeppelin/confidential-contracts/interfaces/IERC7984ERC20Wrapper.sol";

import {BatcherConfidentialUpgradeable} from "../BatcherConfidentialUpgradeable.sol";

/// @dev Minimal concrete subclass used to test the abstract BatcherConfidentialUpgradeable base.
contract BatcherConfidentialUpgradeableHarness is
    BatcherConfidentialUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    constructor(
        IERC7984ERC20Wrapper fromToken_,
        IERC7984ERC20Wrapper toToken_
    ) BatcherConfidentialUpgradeable(fromToken_, toToken_) {
        _disableInitializers();
    }

    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
        __BatcherConfidential_init();
    }

    function routeDescription() public pure override returns (string memory) {
        return "harness";
    }

    function _executeRoute(uint256, uint256) internal pure override returns (ExecuteOutcome) {
        return ExecuteOutcome.Complete;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
