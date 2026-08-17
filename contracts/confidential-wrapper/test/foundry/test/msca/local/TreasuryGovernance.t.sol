// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {FunctionReference, ICircleAccountBase} from "../../../src/msca/interfaces/CircleTypes.sol";
import {TreasuryFixture} from "./TreasuryFixture.t.sol";

/**
 * @title TreasuryGovernance
 * @notice Handover, standing capabilities, and what the wrapper cannot do.
 */
abstract contract TreasuryGovernance is TreasuryFixture {
    address internal alice;

    function setUp() public virtual override {
        super.setUp();
        alice = makeAddr("alice");
    }

    // ----- Handover -----

    /// @notice A fresh account holds nothing and carries no leftover allowance.
    function test_Handover_FreshAccountHasNoBalanceAndNoResidualAllowance() public view {
        assertEq(underlying.balanceOf(address(treasury)), 0, "a fresh treasury already holds underlying");
        assertEq(
            underlying.allowance(address(treasury), address(wrapper)),
            0,
            "a fresh treasury already approves the wrapper"
        );
        assertEq(underlying.allowance(address(treasury), deployer), 0, "a fresh treasury already approves its deployer");
    }

    /// @notice Control moves from the deployer to the Protocol DAO.
    function test_Handover_MovesControlFromTheDeployerToTheDao() public {
        assertTrue(_isController(deployer), "precondition: the deployer controls the account");
        assertFalse(_isController(dao), "precondition: the DAO does not yet control the account");

        _handoverToDao();

        assertTrue(_isController(dao), "the DAO was not recorded as controller");
        assertFalse(_isController(deployer), "the deployer still holds control");
    }

    /// @notice After handover the deployer cannot move the reserve.
    function test_Handover_DeployerRetainsNoAccess() public {
        _completeDeployment();
        _wrap(alice, 5 * ONE);

        vm.prank(deployer);
        (bool ok,) = address(treasury).call(
            abi.encodeCall(
                ICircleAccountBase.execute,
                (address(underlying), 0, abi.encodeCall(IERC20.transfer, (deployer, 5 * ONE)))
            )
        );

        assertFalse(ok, "the deployer could still drive the account");
        assertEq(underlying.balanceOf(address(treasury)), 5 * ONE, "the deployer moved the reserve");
    }

    /// @notice After handover the DAO can grant the settlement allowance and migrate.
    function test_Handover_DaoCanCompleteTheDeployment() public {
        _completeDeployment();

        assertEq(
            underlying.allowance(address(treasury), address(wrapper)),
            type(uint256).max,
            "the DAO could not grant the allowance"
        );
        assertEq(wrapper.treasury(), address(treasury), "the DAO could not migrate the wrapper");
    }

    /// @notice Granting the allowance after the migration leaves unwraps unable to settle until it lands.
    function test_Deployment_GrantingTheAllowanceLastLeavesAnUnsettleableWindow() public {
        _handoverToDao();
        _migrateToTreasury();
        _wrap(alice, 5 * ONE);

        (bytes32 unwrapId, uint64 cleartext, bytes memory proof) = _pendingUnwrapOn(wrapper, alice, uint64(2 * ONE));

        vm.expectRevert();
        wrapper.finalizeUnwrap(unwrapId, cleartext, proof);

        _grantWrapperAllowance(type(uint256).max);

        wrapper.finalizeUnwrap(unwrapId, cleartext, proof);
        assertEq(underlying.balanceOf(alice), 2 * ONE, "the request did not settle once the allowance landed");
    }

    // ----- Standing capabilities -----

    /// @notice The wrapper address can pull the whole balance at any time, with no unwrap request behind it.
    function test_Risk_TheAllowanceIsAClaimOnTheWholeReserve() public {
        _completeDeployment();
        _wrap(alice, 5 * ONE);

        vm.prank(address(wrapper));
        underlying.transferFrom(address(treasury), makeAddr("anywhere"), 5 * ONE);

        assertEq(underlying.balanceOf(address(treasury)), 0, "the standing allowance did not reach the whole balance");
    }

    /// @notice Governance can move backing below what is owed; the wrapper still accepts deposits.
    function test_Risk_GovernanceCanBreakSolvencyWhileTheWrapperKeepsAcceptingDeposits() public {
        _completeDeployment();
        _wrap(alice, 5 * ONE);
        uint256 owed = wrapper.inferredTotalSupply();

        _run(address(underlying), abi.encodeCall(IERC20.transfer, (makeAddr("elsewhere"), 4 * ONE)));

        assertEq(wrapper.inferredTotalSupply(), ONE, "the reserve did not move");
        assertLt(wrapper.inferredTotalSupply(), owed, "backing did not fall below the obligation");

        _wrap(makeAddr("laterDepositor"), ONE);
        assertEq(_balance(makeAddr("laterDepositor")), uint64(ONE), "the wrapper stopped accepting deposits");
    }

    /// @notice Governance can approve any spender.
    function test_Risk_GovernanceCanApproveAnySpender() public {
        _completeDeployment();
        _wrap(alice, 5 * ONE);
        address stranger = makeAddr("stranger");

        _grantAllowance(IERC20(address(underlying)), stranger, type(uint256).max);

        vm.prank(stranger);
        underlying.transferFrom(address(treasury), stranger, 5 * ONE);
        assertEq(underlying.balanceOf(stranger), 5 * ONE, "the granted allowance was not spendable");
    }

    /// @notice A plugin can transfer USDC during its own installation (`onInstall` after permissions are written).
    function test_Risk_AHostilePluginDrainsTheTreasuryDuringItsOwnInstall() public {
        _completeDeployment();
        _wrap(alice, 5 * ONE);
        address attacker = makeAddr("attacker");

        address drain = _deployCircle("StubInstallDrainPlugin.sol", "StubInstallDrainPlugin");
        _runNative(
            abi.encodeCall(
                ICircleAccountBase.installPlugin,
                (drain, _manifestHash(drain), abi.encode(address(underlying), attacker), new FunctionReference[](0))
            )
        );

        assertEq(underlying.balanceOf(address(treasury)), 0, "the install callback did not drain the treasury");
        assertEq(underlying.balanceOf(attacker), 5 * ONE, "the drain did not reach the attacker");
    }

    // ----- What the wrapper cannot do -----

    /// @notice The wrapper is only an ERC-20 spender: it holds no admin rights over the account.
    function test_AccessControl_TheWrapperCannotDriveTheTreasuryAccount() public {
        _completeDeployment();
        _wrap(alice, 5 * ONE);

        vm.prank(address(wrapper));
        (bool ok,) = address(treasury).call(
            abi.encodeCall(
                ICircleAccountBase.execute, (address(underlying), 0, abi.encodeCall(IERC20.transfer, (dao, ONE)))
            )
        );
        assertFalse(ok, "the wrapper was able to execute on the treasury account");
        assertEq(underlying.balanceOf(address(treasury)), 5 * ONE, "the treasury balance moved");
    }

    /// @notice Nothing in the deployment gives the wrapper a way to grant itself an allowance.
    function test_AccessControl_TheWrapperCannotGrantItsOwnAllowance() public {
        _migrateToTreasury();

        vm.prank(address(wrapper));
        (bool ok,) = address(treasury).call(
            abi.encodeCall(
                ICircleAccountBase.execute,
                (address(underlying), 0, abi.encodeCall(IERC20.approve, (address(wrapper), type(uint256).max)))
            )
        );
        assertFalse(ok, "the wrapper approved itself");
        assertEq(underlying.allowance(address(treasury), address(wrapper)), 0, "an allowance appeared");
    }
}
