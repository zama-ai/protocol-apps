// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20, ERC1363} from "@openzeppelin/contracts/token/ERC20/extensions/ERC1363.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract ERC20Mock is ERC1363, ERC20Permit, Ownable {
    uint8 private immutable _decimals;

    /// @dev The per-call {mint} cap, in base units (accounting for decimals). Owner-settable via
    /// {setMaxMintAmount}. Set to `type(uint256).max` to effectively disable the cap (unlimited minting
    /// per call); a value of 0 is a literal cap that blocks all minting. Read via the generated
    /// {maxMintAmount} getter.
    uint256 public maxMintAmount;

    error MintAmountExceedsMax(uint256 amount, uint256 maxAmount);

    event MaxMintAmountSet(uint256 maxMintAmount);

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) ERC20Permit(name_) Ownable(msg.sender) {
        _decimals = decimals_;
        maxMintAmount = 1_000_000 * 10 ** decimals_;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    /// @dev Sets the per-call mint cap, in base units. Pass `type(uint256).max` for unlimited, or 0 to
    /// block minting. Only callable by the owner.
    function setMaxMintAmount(uint256 maxMintAmount_) public virtual onlyOwner {
        maxMintAmount = maxMintAmount_;
        emit MaxMintAmountSet(maxMintAmount_);
    }

    function mint(address to, uint256 amount) public virtual {
        if (amount > maxMintAmount) {
            revert MintAmountExceedsMax(amount, maxMintAmount);
        }
        _mint(to, amount);
    }
}

contract ERC20RevertDecimalsMock is ERC20Mock {
    constructor() ERC20Mock("ERC20RevertDecimalsMock", "ERC20RevertDecimalsMock", 18) {}

    function decimals() public pure override returns (uint8) {
        revert("Decimals not available");
    }
}

contract ERC20ExcessDecimalsMock is ERC20Mock {
    constructor() ERC20Mock("ERC20ExcessDecimalsMock", "ERC20ExcessDecimalsMock", 18) {}

    function decimals() public pure override returns (uint8) {
        assembly {
            mstore(0, 300)
            return(0, 0x20)
        }
    }
}
