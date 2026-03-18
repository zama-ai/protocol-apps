// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/* solhint-disable func-name-mixedcase */

import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {OperatorStaking} from "./../../../contracts/OperatorStaking.sol";

/**
 * @title OperatorStakingHarness
 * @dev Inherits from OperatorStaking to expose internal storage for testing.
 */
contract OperatorStakingHarness is OperatorStaking {
    function _harness_getTotalSharesInRedemption() external view returns (uint256) {
        return _getOperatorStakingStorage()._totalSharesInRedemption;
    }

    function _harness_getSharesReleased(address controller) external view returns (uint256) {
        return _getOperatorStakingStorage()._sharesReleased[controller];
    }

    function _harness_getRedeemRequestCheckpointCount(address controller) external view returns (uint256) {
        return _getOperatorStakingStorage()._redeemRequests[controller]._checkpoints.length;
    }

    function _harness_getRedeemRequestCheckpointAt(
        address controller,
        uint256 index
    ) external view returns (uint48 key, uint208 value) {
        Checkpoints.Checkpoint208 memory cp = _getOperatorStakingStorage()._redeemRequests[controller]._checkpoints[
            index
        ];
        return (cp._key, cp._value);
    }
}
