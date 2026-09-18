// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

/**
 * @title RegistryMock
 * @notice The read path of `ConfidentialTokenWrappersRegistry` the Hardhat tasks enumerate, with a setter so tests
 * can register valid and revoked pairs. Test-only.
 */
contract RegistryMock {
    struct TokenWrapperPair {
        address tokenAddress;
        address confidentialTokenAddress;
        bool isValid;
    }

    TokenWrapperPair[] private _pairs;

    function add(address token, address wrapper, bool isValid) external {
        _pairs.push(TokenWrapperPair(token, wrapper, isValid));
    }

    function getTokenConfidentialTokenPairs() external view returns (TokenWrapperPair[] memory) {
        return _pairs;
    }
}
