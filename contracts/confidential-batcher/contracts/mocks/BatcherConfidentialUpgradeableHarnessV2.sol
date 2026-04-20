// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BatcherConfidentialUpgradeableHarness} from "./BatcherConfidentialUpgradeableHarness.sol";

/// @dev V2 harness with an identical storage layout that overrides
/// `routeDescription` so upgrade tests can distinguish the active implementation.
contract BatcherConfidentialUpgradeableHarnessV2 is BatcherConfidentialUpgradeableHarness {
    function routeDescription() public pure override returns (string memory) {
        return "harnessV2";
    }
}
