// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {OperatorStaking} from "../OperatorStaking.sol";

/**
 * @title LuganodesOperatorStakingV2
 * @notice Upgrade contract to fix swapped name and symbol in the Luganodes OperatorStaking deployment.
 * @dev The original deployment had name and symbol swapped. This upgrade overrides name() and
 * symbol() to return the correct values.
 */
contract LuganodesOperatorStakingV2 is OperatorStaking {
    /**
     * @notice Returns the correct name of the token.
     * @return The name "Luganodes Staked ZAMA (Coprocessor)".
     */
    function name() public pure override returns (string memory) {
        return "Luganodes Staked ZAMA (Coprocessor)";
    }

    /**
     * @notice Returns the correct symbol of the token.
     * @return The symbol "stZAMA-Luganodes-Coprocessor".
     */
    function symbol() public pure override returns (string memory) {
        return "stZAMA-Luganodes-Coprocessor";
    }
}
