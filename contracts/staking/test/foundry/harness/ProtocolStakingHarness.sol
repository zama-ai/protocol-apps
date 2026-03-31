// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/* solhint-disable func-name-mixedcase */ // _harness_ prefix

import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";
import {ProtocolStaking} from "./../../../contracts/ProtocolStaking.sol";

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

    /// @notice Read-only version of `release()`: returns how many tokens are currently
    /// claimable for `account` without executing the transfer.
    function _harness_amountToRelease(address account) external view returns (uint256) {
        ProtocolStakingStorage storage $ = _getProtocolStakingStorage();
        uint256 totalAmountCooledDown = Checkpoints.upperLookup($._unstakeRequests[account], Time.timestamp());
        return totalAmountCooledDown - $._released[account];
    }
}
