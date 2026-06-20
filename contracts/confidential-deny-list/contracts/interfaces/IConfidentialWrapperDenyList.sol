// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

interface IConfidentialWrapperDenyList {
    /// @dev Returns whether `account` is on the deny-list.
    function isDenied(address account) external view returns (bool);
}
