// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ZamaERC20} from "./ZamaERC20.sol";
import {OperatorRewarder} from "../../contracts/OperatorRewarder.sol";
import {OperatorStaking} from "../../contracts/OperatorStaking.sol";
import {ProtocolStaking} from "../../contracts/ProtocolStaking.sol";

interface Vm {
    function prank(address) external;
    function warp(uint256) external;
}

contract POC {
    event log(string);
    event log_named_address(string key, address val);
    event log_named_uint(string key, uint256 val);

    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address internal constant ADMIN = address(0xA11CE);
    address internal constant MANAGER = address(0xB0B);
    address internal constant BENEFICIARY = address(0xBEEF);
    address internal constant ALICE = address(0xA71CE);
    address internal constant BOB = address(0xB0B0);
    address internal constant CAROL = address(0xCA20);

    uint256 internal constant DEPOSIT = 100e18;
    uint256 internal constant REWARD_RATE = 1e18;
    uint256 internal constant ACCRUAL_SECONDS = 1000;
    uint48 internal constant COOLDOWN = 1 days;

    ZamaERC20 internal token;
    ProtocolStaking internal protocolStaking;
    OperatorStaking internal operatorStaking;
    OperatorRewarder internal rewarderOld;

    function setUp() public {
        address[] memory receivers = new address[](3);
        receivers[0] = ALICE;
        receivers[1] = BOB;
        receivers[2] = CAROL;

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1000e18;
        amounts[1] = 1000e18;
        amounts[2] = 1000e18;

        token = new ZamaERC20("Zama", "ZAMA", receivers, amounts, ADMIN);

        ProtocolStaking protocolImpl = new ProtocolStaking();
        bytes memory protocolInit = abi.encodeCall(
            ProtocolStaking.initialize,
            ("Staked ZAMA", "stZAMA", "1", address(token), ADMIN, MANAGER, COOLDOWN, REWARD_RATE)
        );
        protocolStaking = ProtocolStaking(address(new ERC1967Proxy(address(protocolImpl), protocolInit)));

        bytes32 minterRole = token.MINTER_ROLE();
        vm.prank(ADMIN);
        token.grantRole(minterRole, address(protocolStaking));

        OperatorStaking operatorImpl = new OperatorStaking();
        bytes memory operatorInit = abi.encodeCall(
            OperatorStaking.initialize,
            ("Operator Stake", "opZAMA", protocolStaking, BENEFICIARY, uint16(10_000), uint16(0))
        );
        operatorStaking = OperatorStaking(address(new ERC1967Proxy(address(operatorImpl), operatorInit)));
        rewarderOld = OperatorRewarder(operatorStaking.rewarder());

        vm.prank(MANAGER);
        protocolStaking.addEligibleAccount(address(operatorStaking));

        vm.prank(ALICE);
        token.approve(address(operatorStaking), type(uint256).max);
        vm.prank(BOB);
        token.approve(address(operatorStaking), type(uint256).max);
        vm.prank(CAROL);
        token.approve(address(operatorStaking), type(uint256).max);

        emit log_named_address("initial rewarder", address(rewarderOld));
    }

    function test_reward_accounting_survives_post_rotation_redeem() public {
        vm.prank(ALICE);
        operatorStaking.deposit(DEPOSIT, ALICE);
        vm.prank(BOB);
        operatorStaking.deposit(DEPOSIT, BOB);

        uint256 bobShares = operatorStaking.balanceOf(BOB);

        vm.warp(block.timestamp + ACCRUAL_SECONDS);
        _rotateRewarder();

        uint256 pool = token.balanceOf(address(rewarderOld));
        uint256 aliceEarnedAtSwap = rewarderOld.earned(ALICE);
        uint256 bobEarnedAtSwap = rewarderOld.earned(BOB);

        emit log("after rotation, old rewarder holds the accrued reward pool");
        emit log_named_uint("old rewarder pool", pool);
        emit log_named_uint("alice fair earned at swap", aliceEarnedAtSwap);
        emit log_named_uint("bob fair earned at swap", bobEarnedAtSwap);

        _assertApproxEqAbs(aliceEarnedAtSwap, pool / 2, 2, "alice did not start with half the pool");
        _assertApproxEqAbs(bobEarnedAtSwap, pool / 2, 2, "bob did not start with half the pool");

        vm.prank(BOB);
        operatorStaking.requestRedeem(uint208(bobShares), BOB, BOB);

        uint256 aliceEarnedAfter = rewarderOld.earned(ALICE);
        uint256 bobEarnedAfter = rewarderOld.earned(BOB);

        emit log("bob performs a normal redeem request after the rotation");
        emit log_named_uint("alice earned after bob redeem", aliceEarnedAfter);
        emit log_named_uint("bob earned after bob redeem", bobEarnedAfter);

        _assertApproxEqAbs(aliceEarnedAfter, aliceEarnedAtSwap, 2, "alice's old reward allocation changed");
        _assertApproxEqAbs(bobEarnedAfter, bobEarnedAtSwap, 2, "bob's old reward allocation changed");

        uint256 aliceBefore = token.balanceOf(ALICE);
        uint256 bobBefore = token.balanceOf(BOB);
        vm.prank(ALICE);
        rewarderOld.claimRewards(ALICE);
        vm.prank(BOB);
        rewarderOld.claimRewards(BOB);
        uint256 alicePayout = token.balanceOf(ALICE) - aliceBefore;
        uint256 bobPayout = token.balanceOf(BOB) - bobBefore;

        emit log("alice and bob claim from the old rewarder");
        emit log_named_uint("alice payout", alicePayout);
        emit log_named_uint("bob payout", bobPayout);
        emit log_named_uint("old rewarder residual", token.balanceOf(address(rewarderOld)));

        _assertApproxEqAbs(alicePayout, aliceEarnedAtSwap, 2, "alice payout changed");
        _assertApproxEqAbs(bobPayout, bobEarnedAtSwap, 2, "bob payout changed");
        _assertEq(token.balanceOf(address(rewarderOld)), 0, "old rewarder pool was not drained");
    }

    function test_reward_accounting_survives_post_rotation_deposit() public {
        vm.prank(ALICE);
        operatorStaking.deposit(DEPOSIT, ALICE);
        vm.prank(BOB);
        operatorStaking.deposit(DEPOSIT, BOB);

        vm.warp(block.timestamp + ACCRUAL_SECONDS);
        _rotateRewarder();

        uint256 pool = token.balanceOf(address(rewarderOld));
        uint256 aliceEarnedAtSwap = rewarderOld.earned(ALICE);
        uint256 bobEarnedAtSwap = rewarderOld.earned(BOB);
        uint256 sumBefore = aliceEarnedAtSwap + bobEarnedAtSwap;

        emit log("after rotation, alice and bob can claim the whole old pool");
        emit log_named_uint("old rewarder pool", pool);
        emit log_named_uint("alice+bob earned before carol", sumBefore);

        _assertApproxEqAbs(sumBefore, pool, 4, "alice+bob did not initially own the old pool");

        vm.prank(CAROL);
        operatorStaking.deposit(DEPOSIT, CAROL);

        uint256 aliceEarnedAfter = rewarderOld.earned(ALICE);
        uint256 bobEarnedAfter = rewarderOld.earned(BOB);
        uint256 carolEarnedAfter = rewarderOld.earned(CAROL);

        emit log("carol deposits after rotation; the old rewarder remains neutral to new shares");
        emit log_named_uint("alice earned after carol deposit", aliceEarnedAfter);
        emit log_named_uint("bob earned after carol deposit", bobEarnedAfter);
        emit log_named_uint("carol earned on old rewarder", carolEarnedAfter);

        _assertApproxEqAbs(aliceEarnedAfter, aliceEarnedAtSwap, 2, "alice's old reward allocation changed");
        _assertApproxEqAbs(bobEarnedAfter, bobEarnedAtSwap, 2, "bob's old reward allocation changed");
        _assertEq(carolEarnedAfter, 0, "carol received old reward allocation");

        uint256 aliceBefore = token.balanceOf(ALICE);
        uint256 bobBefore = token.balanceOf(BOB);
        vm.prank(ALICE);
        rewarderOld.claimRewards(ALICE);
        vm.prank(BOB);
        rewarderOld.claimRewards(BOB);

        uint256 paid = (token.balanceOf(ALICE) - aliceBefore) + (token.balanceOf(BOB) - bobBefore);
        uint256 stranded = token.balanceOf(address(rewarderOld));

        emit log("alice and bob claim; no residual stays in old rewarder");
        emit log_named_uint("paid to alice+bob", paid);
        emit log_named_uint("stranded residual", stranded);

        _assertApproxEqAbs(paid, pool, 4, "alice+bob did not claim the old pool");
        _assertEq(stranded, 0, "old rewarder pool was stranded");
    }

    function _rotateRewarder() internal returns (OperatorRewarder rewarderNew) {
        rewarderNew = new OperatorRewarder(BENEFICIARY, protocolStaking, operatorStaking, 10_000, 0);

        vm.prank(ADMIN);
        operatorStaking.setRewarder(address(rewarderNew));

        emit log_named_address("new rewarder", address(rewarderNew));
        _assertEq(uint256(rewarderOld.isShutdown() ? 1 : 0), 1, "old rewarder was not shut down");
        _assertEq(uint256(rewarderNew.isShutdown() ? 1 : 0), 0, "new rewarder is unexpectedly shut down");
    }

    function _assertEq(uint256 a, uint256 b, string memory message) internal pure {
        if (a != b) revert(message);
    }

    function _assertGt(uint256 a, uint256 b, string memory message) internal pure {
        if (a <= b) revert(message);
    }

    function _assertLt(uint256 a, uint256 b, string memory message) internal pure {
        if (a >= b) revert(message);
    }

    function _assertApproxEqAbs(uint256 a, uint256 b, uint256 maxDelta, string memory message) internal pure {
        uint256 delta = a > b ? a - b : b - a;
        if (delta > maxDelta) revert(message);
    }
}
