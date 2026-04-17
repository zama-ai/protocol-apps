// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC7984ERC20Wrapper} from "@openzeppelin/confidential-contracts/interfaces/IERC7984ERC20Wrapper.sol";

import {BatcherConfidentialUpgradeableHarness} from "./BatcherConfidentialUpgradeableHarness.sol";

/// @dev V2 harness with an identical storage layout plus a version getter.
/// Used to verify upgradeability preserves state.
contract BatcherConfidentialUpgradeableHarnessV2 is BatcherConfidentialUpgradeableHarness {
    constructor(
        IERC7984ERC20Wrapper fromToken_,
        IERC7984ERC20Wrapper toToken_
    ) BatcherConfidentialUpgradeableHarness(fromToken_, toToken_) {}

    function version() external pure returns (string memory) {
        return "v2";
    }
}
