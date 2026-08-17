// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {ERC20Mock} from "confidential-wrapper/mocks/ERC20Mock.sol";

/**
 * @title BlocklistedUnderlyingMock
 * @notice ERC-20 that enforces a USDC-style blocklist on transfer.
 * @dev The package mock exposes `isBlacklisted` but does not revert. Same selector as USDC (`0xfe575a87`).
 */
contract BlocklistedUnderlyingMock is ERC20Mock {
    mapping(address account => bool blocked) private _blocked;

    /// @dev Matches USDC's revert on a blocked party.
    error Blocklisted(address account);

    constructor() ERC20Mock("USD Coin", "USDC", 6) {}

    function setBlocklisted(address account, bool status) external {
        _blocked[account] = status;
    }

    function isBlacklisted(address account) external view returns (bool) {
        return _blocked[account];
    }

    /// @dev `_update` covers `transfer` and `transferFrom`; the spender is checked separately.
    function _update(address from, address to, uint256 value) internal virtual override {
        if (_blocked[msg.sender]) revert Blocklisted(msg.sender);
        if (from != address(0) && _blocked[from]) revert Blocklisted(from);
        if (to != address(0) && _blocked[to]) revert Blocklisted(to);
        super._update(from, to, value);
    }
}
