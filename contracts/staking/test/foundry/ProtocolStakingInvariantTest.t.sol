// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ProtocolStaking} from "../../contracts/ProtocolStaking.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ZamaERC20} from "token/contracts/ZamaERC20.sol";
import {ProtocolStakingHandler} from "./handlers/ProtocolStakingHandler.sol";

// Invariant fuzz test for ProtocolStaking
contract ProtocolStakingInvariantTest is Test {
    ProtocolStaking internal protocolStaking;
    ZamaERC20 internal zama;
    ProtocolStakingHandler internal handler;

    address internal governor = address(1);
    address internal manager = address(2);
    address internal admin = address(3);
    address internal staker = address(4);

    uint256 internal constant INITIAL_STAKER_BALANCE = 1_000_000 ether;
    uint256 internal constant BASE_STAKE_AMOUNT = 1_000 ether;
    uint256 internal constant INITIAL_REWARD_RATE = 1e18; // 1 token/second

    function setUp() public {

        // Deploy ZamaERC20, mint all to staker, admin is DEFAULT_ADMIN
        address[] memory receivers = new address[](1);
        receivers[0] = staker;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = INITIAL_STAKER_BALANCE;

        zama = new ZamaERC20("Zama", "ZAMA", receivers, amounts, admin);

        // Deploy ProtocolStaking behind ERC1967 proxy
        ProtocolStaking impl = new ProtocolStaking();
        bytes memory initData = abi.encodeCall(
            ProtocolStaking.initialize,
            (
                "Staked ZAMA",
                "stZAMA",
                "1",
                address(zama),
                governor,
                manager,
                uint48(7 days),
                INITIAL_REWARD_RATE
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        protocolStaking = ProtocolStaking(address(proxy));

        // Grant MINTER_ROLE on Zama to ProtocolStaking
        vm.startPrank(admin);
        zama.grantRole(zama.MINTER_ROLE(), address(protocolStaking));
        vm.stopPrank();

        // Make staker eligible
        vm.prank(manager);
        protocolStaking.addEligibleAccount(staker);

        // Approve and do a base stake so staker starts earning
        vm.startPrank(staker);
        zama.approve(address(protocolStaking), type(uint256).max);
        protocolStaking.stake(BASE_STAKE_AMOUNT);
        vm.stopPrank();

        // Deploy handler and target it for invariant tests
        handler = new ProtocolStakingHandler(
            protocolStaking,
            zama,
            manager,
            staker
        );
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = ProtocolStakingHandler.warp.selector;
        selectors[1] = ProtocolStakingHandler.setRewardRate.selector;
        selectors[2] = ProtocolStakingHandler.stake.selector;
        selectors[3] = ProtocolStakingHandler.unstake.selector;
        selectors[4] = ProtocolStakingHandler.claimRewards.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_TotalStakedWeightEqualsEligibleWeights() public view {
        assertEq(
            protocolStaking.totalStakedWeight(),
            handler.computeExpectedTotalWeight(),
            "totalStakedWeight does not match sum of eligible weights"
        );
    }

    function invariant_TotalSupplyBoundedByRewardRate() public view {
        assertLe(
            zama.totalSupply(),
            handler.ghost_initialTotalSupply() + handler.ghost_accumulatedRewardCapacity(),
            "totalSupply exceeds piecewise rewardRate bound"
        );
    }
}