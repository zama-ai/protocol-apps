// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title ConfidentialWrapperMock
 * @notice Reproduces the pause surface of `ConfidentialWrapper` (`pauser()`, `setPauser`, `pause`, `unpause`,
 * `paused`, `PauserUpdated`, `SenderNotPauser`) without any FHE dependency. Test-only.
 */
contract ConfidentialWrapperMock is Ownable, Pausable {
    address private _pauser;

    event PauserUpdated(address indexed pauser);

    error SenderNotPauser(address sender);

    constructor(address owner_, address pauser_) Ownable(owner_) {
        _pauser = pauser_;
        emit PauserUpdated(pauser_);
    }

    function pauser() public view returns (address) {
        return _pauser;
    }

    function setPauser(address pauser_) external onlyOwner {
        _pauser = pauser_;
        emit PauserUpdated(pauser_);
    }

    function pause() external {
        require(msg.sender == pauser(), SenderNotPauser(msg.sender));
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
