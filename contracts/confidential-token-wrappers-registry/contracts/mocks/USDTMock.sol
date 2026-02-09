// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.20;

import {ERC20Mock} from "./ERC20Mock.sol";

/**
 * @title USDTMock
 * @dev A more realistic USDT mock that replicates the real USDT's approve quirk:
 * to change a non-zero allowance, it must first be reset to 0.
 */
contract USDTMock is ERC20Mock {
    error AllowanceMustBeResetToZero(address spender, uint256 currentAllowance);

    constructor() ERC20Mock("Tether USD (Mock)", "USDTMock", 6) {}

    /**
     * @dev Overrides the approve function to require that the allowance is first reset to 0
     * before setting a new non-zero value. This replicates the real USDT behavior.
     * Note: the real USDT reverts with an empty data error when the allowance is not reset to 0,
     * as opposed to this mock.
     */
    function approve(address spender, uint256 value) public override returns (bool) {
        if (value != 0 && allowance(msg.sender, spender) != 0) {
            revert AllowanceMustBeResetToZero(spender, allowance(msg.sender, spender));
        }
        return super.approve(spender, value);
    }
}
