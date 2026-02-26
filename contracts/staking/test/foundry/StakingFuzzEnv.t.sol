// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

/**
 * @title StakingFuzzEnv
 * @notice Minimal sanity test to verify Foundry compiles and runs tests.
 */
contract StakingFuzzEnv is Test {
    function test_Environment_Succeeds() public {
        assertTrue(true);
    }
}
