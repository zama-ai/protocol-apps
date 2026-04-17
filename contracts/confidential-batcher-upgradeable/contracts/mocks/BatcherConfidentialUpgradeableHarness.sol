// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC7984ERC20Wrapper} from "@openzeppelin/confidential-contracts/interfaces/IERC7984ERC20Wrapper.sol";

import {BatcherConfidentialUpgradeable} from "../BatcherConfidentialUpgradeable.sol";

/// @dev Minimal concrete subclass used to test the abstract BatcherConfidentialUpgradeable base.
contract BatcherConfidentialUpgradeableHarness is BatcherConfidentialUpgradeable {
    constructor(
        IERC7984ERC20Wrapper fromToken_,
        IERC7984ERC20Wrapper toToken_
    ) BatcherConfidentialUpgradeable(fromToken_, toToken_) {
        _disableInitializers();
    }

    function initialize() external initializer {
        __BatcherConfidential_init();
    }

    function routeDescription() public pure override returns (string memory) {
        return "harness";
    }

    function _executeRoute(uint256, uint256) internal pure override returns (ExecuteOutcome) {
        return ExecuteOutcome.Complete;
    }
}
