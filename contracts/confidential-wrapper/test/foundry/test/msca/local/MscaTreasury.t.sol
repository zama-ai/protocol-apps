// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    Call,
    FunctionReference,
    ICircleAccountBase,
    NotImplemented,
    RuntimeValidationFailed
} from "../../../src/msca/interfaces/CircleTypes.sol";
import {IWeightedMultisigPlugin} from "../../../src/msca/interfaces/IWeightedMultisigPlugin.sol";
import {MscaTreasuryBase} from "./MscaTreasuryBase.t.sol";
import {TreasuryFixture} from "./TreasuryFixture.t.sol";
import {TreasuryGovernance} from "./TreasuryGovernance.t.sol";
import {TreasuryMigration} from "./TreasuryMigration.t.sol";
import {TreasurySettlement} from "./TreasurySettlement.t.sol";

interface IAddressBookPlugin {
    error UnauthorizedRecipient(address account, address recipient);

    function getAllowedRecipients(address account) external view returns (address[] memory);

    function addAllowedRecipients(address[] calldata recipientsToAdd) external;
}

/**
 * @title MscaTreasuryMigrationTest
 * @notice The migration, with `circle_6900_v1` as the treasury.
 */
contract MscaTreasuryMigrationTest is MscaTreasuryBase, TreasuryMigration {
    /// @dev Both bases reach {TreasuryFixture.setUp}; `super` walks the linearization.
    function setUp() public override(TreasuryFixture, TreasuryMigration) {
        super.setUp();
    }
}

/**
 * @title MscaTreasurySettlementTest
 * @notice The three token paths, with the MSCA as the treasury.
 */
contract MscaTreasurySettlementTest is MscaTreasuryBase, TreasurySettlement {
    /// @dev Both bases reach {TreasuryFixture.setUp}; `super` walks the linearization.
    function setUp() public override(TreasuryFixture, TreasurySettlement) {
        super.setUp();
    }
}

/**
 * @title MscaTreasuryGovernanceTest
 * @notice Access control and the standing capabilities, with the MSCA as the treasury.
 */
contract MscaTreasuryGovernanceTest is MscaTreasuryBase, TreasuryGovernance {
    /// @dev Both bases reach {TreasuryFixture.setUp}; `super` walks the linearization.
    function setUp() public override(TreasuryFixture, TreasuryGovernance) {
        super.setUp();
    }
}

/**
 * @title MscaTreasuryProductTest
 * @notice What is true of the MSCA and not of the SCA.
 */
contract MscaTreasuryProductTest is MscaTreasuryBase {
    /// @dev The key a later signer rotation moves control to.
    uint256 internal constant ROTATION_PK = 0xDA02;

    /// @dev `bytes4(keccak256("runtimeValidationFunction(uint8,address,uint256,bytes)"))`.
    bytes4 internal constant RUNTIME_VALIDATION_SELECTOR = 0xbfd151c1;

    /// @dev Set while the account is above threshold 1 and both signers must sign.
    bool internal cosigning;

    /// @inheritdoc MscaTreasuryBase
    function _cosignerPks() internal view override returns (uint256[] memory pks) {
        if (!cosigning) return new uint256[](0);
        pks = new uint256[](1);
        pks[0] = ROTATION_PK;
    }

    /// @dev External so `vm.expectRevert` binds to `handleOps` rather than the deposit top-up.
    function accountUserOpExternal(bytes calldata callData) external {
        _accountUserOp(callData);
    }

    /// @notice The MSCA has no owner accessor: control can only be read from the plugin.
    function test_Msca_AccountItselfNamesNoOwner() public {
        (bool ok,) = address(msca).staticcall(abi.encodeWithSignature("getNativeOwner()"));
        assertFalse(ok, "the MSCA answered an owner query");

        (,, IWeightedMultisigPlugin.OwnershipMetadata memory metadata) = multisigPlugin.ownershipInfoOf(address(msca));
        assertEq(metadata.numOwners, 1, "the plugin does not hold the signer set");
        assertEq(metadata.thresholdWeight, 1, "unexpected threshold");
        assertTrue(_isController(deployer), "the deployer is not in the signer set");
    }

    /// @notice The installed plugin set is enumerable.
    function test_Msca_InstalledPluginsAreEnumerable() public view {
        address[] memory plugins = msca.getInstalledPlugins();
        assertEq(plugins.length, 1, "unexpected plugin count on a fresh account");
        assertEq(plugins[0], address(multisigPlugin), "unexpected plugin installed");
    }

    /// @notice The plugin denies runtime validation, so every DAO action is a signed user operation.
    function test_Msca_RuntimeExecuteIsDeniedEvenForASigner() public {
        _handoverToDao();

        vm.prank(dao);
        vm.expectRevert();
        msca.execute(address(underlying), 0, abi.encodeCall(IERC20.approve, (address(wrapper), type(uint256).max)));

        assertEq(underlying.allowance(address(treasury), address(wrapper)), 0, "the runtime path granted an allowance");
    }

    /// @notice Handover has a window: both signers are present and either meets the threshold alone.
    /// @dev `removeOwners` refuses a zero-owner account, so add must precede remove.
    function test_Msca_HandoverPassesThroughATwoSignerWindow() public {
        address[] memory toAdd = new address[](1);
        toAdd[0] = dao;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;
        _accountUserOp(
            abi.encodeCall(
                IWeightedMultisigPlugin.addOwners,
                (toAdd, weights, new IWeightedMultisigPlugin.PublicKey[](0), new uint256[](0), 1)
            )
        );

        (,, IWeightedMultisigPlugin.OwnershipMetadata memory metadata) = multisigPlugin.ownershipInfoOf(address(msca));
        assertEq(metadata.numOwners, 2, "expected both signers during the handover");
        assertEq(metadata.thresholdWeight, 1, "either signer alone still meets the threshold");
        assertTrue(_isController(deployer), "the outgoing signer lost control too early");
        assertTrue(_isController(dao), "the incoming signer was not added");
    }

    /// @notice `executeBatch([addOwners, removeOwners])` cannot collapse the two owner-set changes.
    /// @dev Those selectors are reached as runtime calls; the plugin implements no runtime validation.
    function test_Msca_OwnerChangesCannotBeBatchedAtomically() public {
        address[] memory toAdd = new address[](1);
        toAdd[0] = dao;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;
        address[] memory toRemove = new address[](1);
        toRemove[0] = deployer;

        Call[] memory calls = new Call[](2);
        calls[0] = Call({
            target: address(msca),
            value: 0,
            data: abi.encodeCall(
                IWeightedMultisigPlugin.addOwners,
                (toAdd, weights, new IWeightedMultisigPlugin.PublicKey[](0), new uint256[](0), 0)
            )
        });
        calls[1] = Call({
            target: address(msca),
            value: 0,
            data: abi.encodeCall(
                IWeightedMultisigPlugin.removeOwners, (toRemove, new IWeightedMultisigPlugin.PublicKey[](0), 1)
            )
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                UserOpReverted.selector,
                abi.encodeWithSelector(
                    RuntimeValidationFailed.selector,
                    address(multisigPlugin),
                    uint8(0),
                    abi.encodeWithSelector(NotImplemented.selector, RUNTIME_VALIDATION_SELECTOR, uint8(0))
                )
            )
        );
        this.accountUserOpExternal(abi.encodeCall(ICircleAccountBase.executeBatch, (calls)));

        assertTrue(_isController(deployer), "the owner set changed despite the revert");
        assertFalse(_isController(dao), "the owner set changed despite the revert");
    }

    /// @notice Raising the threshold while adding closes the unilateral window: neither key can act alone.
    function test_Msca_RaisingTheThresholdRemovesTheUnilateralWindow() public {
        _completeDeployment();
        _wrap(makeAddr("alice"), 5 * ONE);

        address incoming = vm.addr(ROTATION_PK);

        address[] memory toAdd = new address[](1);
        toAdd[0] = incoming;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;
        _accountUserOp(
            abi.encodeCall(
                IWeightedMultisigPlugin.addOwners,
                (toAdd, weights, new IWeightedMultisigPlugin.PublicKey[](0), new uint256[](0), 2)
            )
        );

        (,, IWeightedMultisigPlugin.OwnershipMetadata memory metadata) = multisigPlugin.ownershipInfoOf(address(msca));
        assertEq(metadata.numOwners, 2, "expected both signers");
        assertEq(metadata.thresholdWeight, 2, "the threshold was not raised");

        address attacker = makeAddr("attacker");
        vm.expectRevert();
        this.execViaUserOpExternal(address(underlying), abi.encodeCall(IERC20.transfer, (attacker, 5 * ONE)));
        assertEq(underlying.balanceOf(address(treasury)), 5 * ONE, "a single signer moved the reserve");

        cosigning = true;
        address[] memory toRemove = new address[](1);
        toRemove[0] = dao;
        _accountUserOp(
            abi.encodeCall(
                IWeightedMultisigPlugin.removeOwners, (toRemove, new IWeightedMultisigPlugin.PublicKey[](0), 1)
            )
        );
        cosigning = false;

        controllerPk = ROTATION_PK;
        controller = incoming;
        assertTrue(_isController(incoming), "the incoming signer did not end up in control");
        assertFalse(_isController(dao), "the outgoing signer was not removed");
    }

    // ----- Address Book plugin -----

    /// @notice An empty Address Book allowlist blocks direct execute and approve, including the wrapper.
    function test_Msca_AddressBookOptionBlocksDirectExecuteAndApprove() public {
        _completeDeployment();
        _wrap(makeAddr("alice"), 5 * ONE);
        _installAddressBookWithEmptyAllowlist();
        address attacker = makeAddr("attacker");

        vm.expectRevert();
        this.execViaUserOpExternal(address(underlying), abi.encodeCall(IERC20.transfer, (attacker, 5 * ONE)));
        assertEq(underlying.balanceOf(address(treasury)), 5 * ONE, "the reserve was moved");

        vm.expectRevert();
        this.execViaUserOpExternal(address(underlying), abi.encodeCall(IERC20.approve, (attacker, 5 * ONE)));
        assertEq(underlying.allowance(address(treasury), attacker), 0, "an allowance was granted");

        vm.expectRevert();
        this.execViaUserOpExternal(
            address(underlying), abi.encodeCall(IERC20.approve, (address(wrapper), type(uint256).max))
        );
    }

    /// @notice Settlement is unaffected: the wrapper pulls with `transferFrom` and never asks the account to execute.
    function test_Msca_AddressBookDoesNotInterfereWithSettlement() public {
        _completeDeployment();
        address alice = makeAddr("alice");
        _wrap(alice, 5 * ONE);
        _installAddressBookWithEmptyAllowlist();

        _finalizeUnwrap(_requestUnwrap(alice, alice, uint64(2 * ONE)));

        assertEq(underlying.balanceOf(alice), 2 * ONE, "settlement was blocked by Address Book");
        assertEq(underlying.balanceOf(address(treasury)), 3 * ONE, "treasury was not debited");
    }

    /// @dev No allowed recipients; depends on the account and the multisig plugin for validation.
    function _installAddressBookWithEmptyAllowlist() private {
        IAddressBookPlugin addressBook =
            IAddressBookPlugin(_deployCircle("ColdStorageAddressBookPlugin.sol", "ColdStorageAddressBookPlugin"));

        FunctionReference[] memory dependencies = new FunctionReference[](2);
        dependencies[0] = FunctionReference({plugin: address(msca), functionId: 0});
        dependencies[1] = FunctionReference({plugin: address(multisigPlugin), functionId: 0});

        _accountUserOp(
            abi.encodeCall(
                ICircleAccountBase.installPlugin,
                (address(addressBook), _manifestHash(address(addressBook)), abi.encode(new address[](0)), dependencies)
            )
        );

        assertEq(addressBook.getAllowedRecipients(address(msca)).length, 0, "expected an empty allowlist");
    }
}
