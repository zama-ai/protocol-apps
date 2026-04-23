// SPDX-License-Identifier: MIT
// Ported (minimal subset) from
// https://github.com/OpenZeppelin/openzeppelin-confidential-contracts/blob/v0.4.0-rc.0/contracts/mocks/token/ERC7984Mock.sol
pragma solidity ^0.8.27;

import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {FHE, euint64} from "@fhevm/solidity/lib/FHE.sol";
import {ERC7984} from "@openzeppelin/confidential-contracts/token/ERC7984/ERC7984.sol";

// solhint-disable func-name-mixedcase
contract ERC7984Mock is ERC7984, ZamaEthereumConfig {
    constructor(
        string memory name_,
        string memory symbol_,
        string memory tokenURI_
    ) ERC7984(name_, symbol_, tokenURI_) {}

    function $_mint(address to, uint64 amount) public returns (euint64) {
        return _mint(to, FHE.asEuint64(amount));
    }

    function $_burn(address from, uint64 amount) public returns (euint64) {
        return _burn(from, FHE.asEuint64(amount));
    }
}
