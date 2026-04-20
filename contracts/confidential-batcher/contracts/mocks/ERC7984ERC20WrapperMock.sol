// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";
import {ERC7984} from "@openzeppelin/confidential-contracts/token/ERC7984/ERC7984.sol";
import {ERC7984ERC20Wrapper} from "@openzeppelin/confidential-contracts/token/ERC7984/extensions/ERC7984ERC20Wrapper.sol";

/// @dev Concrete mock of the abstract ERC7984ERC20Wrapper for testing.
contract ERC7984ERC20WrapperMock is ERC7984ERC20Wrapper {
    constructor(
        IERC20 underlying_,
        string memory name_,
        string memory symbol_
    ) ERC7984(name_, symbol_, "") ERC7984ERC20Wrapper(underlying_) {}

    function name() public view override(ERC7984, IERC7984) returns (string memory) {
        return super.name();
    }

    function symbol() public view override(ERC7984, IERC7984) returns (string memory) {
        return super.symbol();
    }
}
