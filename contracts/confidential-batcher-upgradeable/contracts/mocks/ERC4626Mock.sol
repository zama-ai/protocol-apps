// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

contract ERC4626Mock is ERC4626 {
    bool private _revertDeposits;
    bool private _revertRedeems;

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) ERC4626(asset_) {}

    function setRevertDeposits(bool flag) external {
        _revertDeposits = flag;
    }

    function setRevertRedeems(bool flag) external {
        _revertRedeems = flag;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        require(!_revertDeposits, "ERC4626Mock: deposits reverted");
        return super.deposit(assets, receiver);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        require(!_revertRedeems, "ERC4626Mock: redeems reverted");
        return super.redeem(shares, receiver, owner);
    }
}
