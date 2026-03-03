// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ProtocolStaking} from "../../contracts/ProtocolStaking.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ZamaERC20} from "token/contracts/ZamaERC20.sol";

// Invariant fuzz test for ProtocolStaking
contract ProtocolStakingInvariantTest is Test {
    ProtocolStaking internal protocolStaking;
    ZamaERC20 internal zama;

    address internal governor = address(1);
    address internal manager = address(2);
    address internal admin = address(3);
    address internal staker = address(4);

    uint256 internal constant INITIAL_STAKER_BALANCE = 1_000_000 ether;
    uint256 internal constant BASE_STAKE_AMOUNT = 1_000 ether;
    uint256 internal constant MAX_TIME_DELTA = 365 days;
    uint256 internal constant INITIAL_REWARD_RATE = 1e18; // 1 token/second

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
    }

    function _upperBoundSupply() internal view returns (uint256) {
        uint256 elapsed = block.timestamp - startTimestamp;
        uint256 rate = protocolStaking.rewardRate();
        return initialTotalSupply + rate * elapsed;
    }

    function _logState(string memory label) internal view {
        console2.log("=== ", label, " ===");
        console2.log("block.timestamp", block.timestamp);
        console2.log("startTimestamp", startTimestamp);
        console2.log("elapsed", block.timestamp - startTimestamp);
        console2.log("rewardRate", protocolStaking.rewardRate());
        console2.log("initialTotalSupply", initialTotalSupply);
        console2.log("currentTotalSupply", zama.totalSupply());
    }

    function testFuzz_TotalSupplyBoundedByRewardRate(
        uint256 timeDelta,
        uint256 extraStakeAmount
    ) public {
        // Bound and apply time delta
        timeDelta = bound(timeDelta, 1, MAX_TIME_DELTA);
        vm.warp(startTimestamp + timeDelta);

        // Optionally stake extra during the period
        uint256 maxExtraStake = INITIAL_STAKER_BALANCE - BASE_STAKE_AMOUNT;
        if (maxExtraStake > 0) {
            extraStakeAmount = bound(extraStakeAmount, 0, maxExtraStake);
            if (extraStakeAmount > 0) {
                vm.prank(staker);
                protocolStaking.stake(extraStakeAmount);
            }
        }

        // Claim rewards for the staker
        protocolStaking.claimRewards(staker);

        // Check simplified invariant: totalSupply <= initialTotalSupply + rewardRate * elapsed
        uint256 actualSupply = zama.totalSupply();
        uint256 upperBound = _upperBoundSupply();

        if (actualSupply > upperBound) {
            _logState("supply invariant violation");
            console2.log("upperBound", upperBound);
            console2.log("actualSupply", actualSupply);
            fail();
        }
    }
}