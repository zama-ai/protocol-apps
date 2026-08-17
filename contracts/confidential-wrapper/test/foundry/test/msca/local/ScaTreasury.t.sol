// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ScaTreasuryBase} from "./ScaTreasuryBase.t.sol";
import {TreasuryFixture} from "./TreasuryFixture.t.sol";
import {TreasuryGovernance} from "./TreasuryGovernance.t.sol";
import {TreasuryMigration} from "./TreasuryMigration.t.sol";
import {TreasurySettlement} from "./TreasurySettlement.t.sol";

/**
 * @title ScaTreasuryMigrationTest
 * @notice The migration, with `circle_6900_singleowner_v3` as the treasury.
 */
contract ScaTreasuryMigrationTest is ScaTreasuryBase, TreasuryMigration {
    /// @dev Both bases reach {TreasuryFixture.setUp}; `super` walks the linearization.
    function setUp() public override(TreasuryFixture, TreasuryMigration) {
        super.setUp();
    }
}

/**
 * @title ScaTreasurySettlementTest
 * @notice The three token paths, with the SCA as the treasury.
 */
contract ScaTreasurySettlementTest is ScaTreasuryBase, TreasurySettlement {
    /// @dev Both bases reach {TreasuryFixture.setUp}; `super` walks the linearization.
    function setUp() public override(TreasuryFixture, TreasurySettlement) {
        super.setUp();
    }
}

/**
 * @title ScaTreasuryGovernanceTest
 * @notice Access control and the standing capabilities, with the SCA as the treasury.
 */
contract ScaTreasuryGovernanceTest is ScaTreasuryBase, TreasuryGovernance {
    /// @dev Both bases reach {TreasuryFixture.setUp}; `super` walks the linearization.
    function setUp() public override(TreasuryFixture, TreasuryGovernance) {
        super.setUp();
    }
}

/**
 * @title ScaTreasuryProductTest
 * @notice What is true of the SCA and not of the MSCA.
 */
contract ScaTreasuryProductTest is ScaTreasuryBase {
    /// @notice Control is one call on the account.
    function test_Sca_ControlIsReadableFromTheAccountItself() public {
        assertEq(sca.getNativeOwner(), deployer, "the account does not name its deployer");

        _handoverToDao();

        assertEq(sca.getNativeOwner(), dao, "the account does not name its new owner");
    }

    /// @notice The DAO grants the settlement allowance with a plain owner transaction.
    function test_Sca_AllowanceIsGrantedByADirectOwnerCall() public {
        _handoverToDao();

        vm.prank(dao);
        sca.execute(address(underlying), 0, abi.encodeCall(IERC20.approve, (address(wrapper), type(uint256).max)));

        assertEq(underlying.allowance(address(treasury), address(wrapper)), type(uint256).max);
    }

    /// @notice A non-owner cannot drive the account.
    function test_Sca_RuntimeExecuteIsOwnerOnly() public {
        _completeDeployment();
        deal(address(underlying), address(sca), 5 * ONE);
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert();
        sca.execute(address(underlying), 0, abi.encodeCall(IERC20.transfer, (stranger, 5 * ONE)));

        assertEq(underlying.balanceOf(address(sca)), 5 * ONE, "a stranger moved the reserve");
    }

    /// @notice Handover is a single, immediate transfer with no acceptance leg.
    function test_Sca_HandoverIsSingleStepAndUnconfirmed() public {
        address fatFingered = makeAddr("wrongAddress");

        vm.prank(deployer);
        sca.transferNativeOwnership(fatFingered);

        assertEq(sca.getNativeOwner(), fatFingered, "ownership did not move immediately");
        assertFalse(_isController(dao), "the account landed on the DAO despite the wrong address");
    }
}
