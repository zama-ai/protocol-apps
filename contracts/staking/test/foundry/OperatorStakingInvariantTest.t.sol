// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ZamaERC20} from "token/contracts/ZamaERC20.sol";
import {ProtocolStaking} from "../../contracts/ProtocolStaking.sol";
import {OperatorStakingHarness} from "./harness/OperatorStakingHarness.sol";
import {OperatorStakingHandler} from "./handlers/OperatorStakingHandler.sol";

// Invariant fuzz scaffold for OperatorStaking
contract OperatorStakingInvariantTest is Test {
    ProtocolStaking internal protocolStaking;
    OperatorStakingHarness internal operatorStaking;
    ZamaERC20 internal zama;
    OperatorStakingHandler internal handler;

    address internal governor = address(1);
    address internal manager = address(2);
    address internal admin = address(3);
    address internal beneficiary = address(4);

    uint256 internal constant ACTOR_COUNT = 5;
    uint256 internal constant INITIAL_TOTAL_SUPPLY = 1_000_000 ether;
    uint256 internal constant INITIAL_REWARD_RATE = 1e18; // 1 token/second
    uint48 internal constant INITIAL_UNSTAKE_COOLDOWN_PERIOD = 60 seconds;
    uint16 internal constant INITIAL_MAX_FEE_BPS = 10_000;
    uint16 internal constant INITIAL_FEE_BPS = 0;

    function setUp() public {
        address[] memory actorsList = new address[](ACTOR_COUNT);
        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            actorsList[i] = address(uint160(10 + i));
        }

        uint256 initialActorBalance = INITIAL_TOTAL_SUPPLY / ACTOR_COUNT;
        address[] memory receivers = new address[](ACTOR_COUNT);
        uint256[] memory amounts = new uint256[](ACTOR_COUNT);
        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            receivers[i] = actorsList[i];
            amounts[i] = initialActorBalance;
        }
        zama = new ZamaERC20("Zama", "ZAMA", receivers, amounts, admin);

        ProtocolStaking protocolImpl = new ProtocolStaking();
        bytes memory protocolInitData = abi.encodeWithSelector(
            ProtocolStaking.initialize.selector,
            "Staked ZAMA",
            "stZAMA",
            "1",
            address(zama),
            governor,
            manager,
            INITIAL_UNSTAKE_COOLDOWN_PERIOD,
            INITIAL_REWARD_RATE
        );
        protocolStaking = ProtocolStaking(address(new ERC1967Proxy(address(protocolImpl), protocolInitData)));

        OperatorStakingHarness operatorImpl = new OperatorStakingHarness();
        bytes memory operatorInitData = abi.encodeWithSelector(
            bytes4(keccak256("initialize(string,string,address,address,uint16,uint16)")),
            "Operator Staked ZAMA",
            "opstZAMA",
            address(protocolStaking),
            beneficiary,
            INITIAL_MAX_FEE_BPS,
            INITIAL_FEE_BPS
        );
        operatorStaking = OperatorStakingHarness(address(new ERC1967Proxy(address(operatorImpl), operatorInitData)));

        vm.startPrank(admin);
        zama.grantRole(zama.MINTER_ROLE(), address(protocolStaking));
        vm.stopPrank();

        vm.prank(manager);
        protocolStaking.addEligibleAccount(address(operatorStaking));

        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            vm.prank(actorsList[i]);
            zama.approve(address(operatorStaking), type(uint256).max);
        }

        handler = new OperatorStakingHandler(operatorStaking, IERC20(address(zama)), protocolStaking, actorsList);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = OperatorStakingHandler.warp.selector;
        selectors[1] = OperatorStakingHandler.setOperator.selector;
        selectors[2] = OperatorStakingHandler.deposit.selector;
        selectors[3] = OperatorStakingHandler.requestRedeem.selector;
        selectors[4] = OperatorStakingHandler.redeem.selector;
        selectors[5] = OperatorStakingHandler.stakeExcess.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // Placeholder invariant while scaffold is being built out.
    function invariant_ScaffoldConfigured() public view {
        assertTrue(address(handler) != address(0), "handler should be configured");
        assertTrue(address(operatorStaking) != address(0), "operator staking should be deployed");
        assertTrue(address(protocolStaking) != address(0), "protocol staking should be deployed");
    }
}
