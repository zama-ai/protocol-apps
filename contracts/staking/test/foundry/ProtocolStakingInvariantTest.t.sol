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

    uint256 internal constant ACTOR_COUNT = 5;
    uint256 internal constant INITIAL_TOTAL_SUPPLY = 1_000_000 ether;
    uint256 internal constant INITIAL_REWARD_RATE = 1e18; // 1 token/second

    function setUp() public {
        address[] memory actorsList = new address[](ACTOR_COUNT);
        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            actorsList[i] = address(uint160(4 + i));
        }

        // Deploy ZamaERC20, mint to all actors, admin is DEFAULT_ADMIN
        uint256 initialActorBalance = INITIAL_TOTAL_SUPPLY / ACTOR_COUNT;
        address[] memory receivers = new address[](ACTOR_COUNT);
        uint256[] memory amounts = new uint256[](ACTOR_COUNT);
        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            receivers[i] = actorsList[i];
            amounts[i] = initialActorBalance;
        }

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

        // Approve ProtocolStaking for all actors
        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            vm.prank(actorsList[i]);
            zama.approve(address(protocolStaking), type(uint256).max);
        }

        // Deploy handler with actors list
        handler = new ProtocolStakingHandler(
            protocolStaking,
            zama,
            manager,
            actorsList
        );
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = ProtocolStakingHandler.warp.selector;
        selectors[1] = ProtocolStakingHandler.setRewardRate.selector;
        selectors[2] = ProtocolStakingHandler.addEligibleAccount.selector;
        selectors[3] = ProtocolStakingHandler.removeEligibleAccount.selector;
        selectors[4] = ProtocolStakingHandler.stake.selector;
        selectors[5] = ProtocolStakingHandler.unstake.selector;
        selectors[6] = ProtocolStakingHandler.claimRewards.selector;
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

    // /**
    //  * Regression test: replay the exact failing invariant sequence (shrunk) with raw args.
    //  * Handler's bound() is applied inside each call, so we pass the same fuzz inputs.
    //  */
    // function test_Regression_TotalSupplyBounded_ReplaySequence() public {
    //     uint256 warpArg = 115792089237316195423570985008687907853269984665640564039457584007913129639935;
    //     uint256 claimActor0 = 0;
    //     uint256 stakeAmount = 1850516410237196839017186097888669920685906233373366;
    //     uint256 stakeActor = 44;
    //     uint256 addEligibleArg = 29457029157298376876832589705601458738507623714791313838295191856;
    //     uint256 removeEligibleArg = 3245075685557285;
    //     uint256 claimActor1 = 170327125951;

    //     handler.warp(warpArg);
    //     handler.claimRewards(claimActor0);
    //     handler.stake(stakeAmount, stakeActor);
    //     handler.addEligibleAccount(addEligibleArg);
    //     handler.removeEligibleAccount(removeEligibleArg);
    //     handler.claimRewards(claimActor1);

    //     uint256 upperBound = handler.ghost_initialTotalSupply() + handler.ghost_accumulatedRewardCapacity();
    //     uint256 actualSupply = zama.totalSupply();
    //     console.log("upperBound (ghost)", upperBound);
    //     console.log("actualSupply", actualSupply);
    //     console.log("diff", actualSupply > upperBound ? actualSupply - upperBound : 0);

    //     assertLe(
    //         actualSupply,
    //         upperBound,
    //         "totalSupply exceeds piecewise rewardRate bound"
    //     );
    // }
}