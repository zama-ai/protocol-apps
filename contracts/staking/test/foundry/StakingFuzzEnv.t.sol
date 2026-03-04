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
    uint256 internal constant MAX_TIME_DELTA = 365 days;
    uint256 internal constant INITIAL_REWARD_RATE = 1e18; // 1 token/second
    uint256 internal constant MAX_PERIODS = 50;
    uint256 internal constant MAX_PERIOD_DURATION = 30 days;
    uint256 internal constant MAX_REWARD_RATE = 1e24;

    uint256 internal initialTotalSupply;
    uint256 internal startTimestamp;

    function setUp() public {
        vm.warp(1_000_000);

        // Deploy ZamaERC20, mint all to staker, admin is DEFAULT_ADMIN
        address[] memory receivers = new address[](1);
        receivers[0] = staker;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = INITIAL_STAKER_BALANCE;

        zama = new ZamaERC20("Zama", "ZAMA", receivers, amounts, admin);
        initialTotalSupply = zama.totalSupply();

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

        // Record baseline time for the invariant
        startTimestamp = block.timestamp;

        // Deploy handler and target it for invariant tests
        handler = new ProtocolStakingHandler(
            protocolStaking,
            zama,
            manager,
            staker,
            INITIAL_REWARD_RATE
        );
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = ProtocolStakingHandler.warp.selector;
        selectors[1] = ProtocolStakingHandler.setRewardRate.selector;
        selectors[2] = ProtocolStakingHandler.stake.selector;
        selectors[3] = ProtocolStakingHandler.claimRewards.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_TotalSupplyBoundedByRewardRate() public view {
        assertLe(
            zama.totalSupply(),
            initialTotalSupply + handler.ghost_accumulatedRewardCapacity(),
            "totalSupply exceeds piecewise rewardRate bound"
        );
    }

    function testFuzz_TotalSupplyBoundedByRewardRate_MultiplePeriods(
        uint256 numPeriods,
        uint256[MAX_PERIODS] memory periodDurations,
        uint256[MAX_PERIODS] memory periodRates
    ) public {
        numPeriods = bound(numPeriods, 1, MAX_PERIODS);

        console.log("initialTotalSupply", initialTotalSupply);

        uint256 accumulatedRewardCapacity = 0;
        uint256 currentRate = INITIAL_REWARD_RATE;

        for (uint256 i = 0; i < numPeriods; i++) {
            uint256 rateThisPeriod = currentRate;
            uint256 duration = bound(periodDurations[i], 1, MAX_PERIOD_DURATION);

            // Update local upper bound capacity
            accumulatedRewardCapacity += rateThisPeriod * duration;

            // Advance time by this period
            vm.warp(block.timestamp + duration);

            // Fuzz the next reward rate for subsequent periods
            uint256 rateForNextPeriod = bound(periodRates[i], 0, MAX_REWARD_RATE);
            vm.prank(manager);
            protocolStaking.setRewardRate(rateForNextPeriod);
            currentRate = rateForNextPeriod;

            // Mint rewards for the staker
            vm.prank(staker);
            protocolStaking.claimRewards(staker);
        }
        uint256 actualSupply = zama.totalSupply();
        uint256 upperBound = initialTotalSupply + accumulatedRewardCapacity;

        assertLe(actualSupply, upperBound);
    }
}