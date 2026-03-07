// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ProtocolStaking} from "../../../contracts/ProtocolStaking.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

/**
 * @title ProtocolStakingHarness
 * @dev Inherits from ProtocolStaking purely to expose internal storage for testing.
 */
contract ProtocolStakingHarness is ProtocolStaking {
    function _harness_getPaid(address account) external view returns (int256) {
        return _getProtocolStakingStorage()._paid[account];
    }

    function _harness_getTotalVirtualPaid() external view returns (int256) {
        return _getProtocolStakingStorage()._totalVirtualPaid;
    }

    function _harness_getHistoricalReward() external view returns (uint256) {
        return _historicalReward();
    }

    function _harness_getUnstakeRequestCheckpointCount(address account) external view returns (uint256) {
        return _getProtocolStakingStorage()._unstakeRequests[account]._checkpoints.length;
    }

    function _harness_getUnstakeRequestCheckpointAt(
        address account,
        uint256 index
    ) external view returns (uint48 key, uint208 value) {
        Checkpoints.Checkpoint208 memory cp = _getProtocolStakingStorage()._unstakeRequests[account]._checkpoints[
            index
        ];
        return (cp._key, cp._value);
    }
}
