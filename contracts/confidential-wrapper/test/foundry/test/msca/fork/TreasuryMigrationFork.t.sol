// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {euint64, externalEuint64} from "encrypted-types/EncryptedTypes.sol";

import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";

import {ERC20Mock} from "confidential-wrapper/mocks/ERC20Mock.sol";

import {ConfidentialWrapperTreasury} from "../../../src/msca/ConfidentialWrapperTreasury.sol";
import {MscaTreasuryBase} from "../local/MscaTreasuryBase.t.sol";
import {TokenTransfer} from "../local/TreasuryFixture.t.sol";

/**
 * @title LiveCusdcTreasuryMigrationTest
 * @notice Deployment sequence against the live Confidential USDC wrapper.
 * @dev Sibling suites in `test/msca/local` deploy a fresh wrapper. This one starts from mainnet
 * bytecode and storage. Needs an archive fork (`make fork-test`); excluded from `make msca-test`.
 */
contract LiveCusdcTreasuryMigrationTest is MscaTreasuryBase {
    /// @dev The live Confidential USDC proxy. See `docs/addresses/mainnet/ethereum.md`.
    address internal constant LIVE_CUSDC = 0xe978F22157048E5DB8E5d07971376e86671672B2;

    /// @dev ERC7984Upgradeable ERC-7201 storage base; `+2` holds the cached total-supply handle.
    bytes32 internal constant ERC7984_STORAGE_BASE = 0xabe6faf3f1b202c971f9850194a6389c7b24dbc9035a913f45a1f82a5d968c00;

    /// @notice The live reserve, read before this suite touches anything.
    uint256 internal liveReserve;

    address internal alice;
    address internal bob;
    address internal operator;

    function setUp() public virtual override {
        super.setUp();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        operator = makeAddr("operator");
    }

    /// @dev Bind to the live EntryPoint instead of etching a local build over it.
    function _deployEntryPoint() internal override {
        require(CANONICAL_ENTRYPOINT.code.length > 0, "no EntryPoint at the canonical address: run with --fork-url");
        entryPoint = EntryPoint(payable(CANONICAL_ENTRYPOINT));
        vm.label(CANONICAL_ENTRYPOINT, "EntryPoint(live)");
    }

    /**
     * @dev Bind {wrapper} to the live proxy and apply the same FHE injection as `test/BaseForkTest.t.sol`:
     * repoint coprocessor config slots, zero the cached total-supply handle.
     */
    function _deployWrapperAtV3() internal override {
        require(LIVE_CUSDC.code.length > 0, "no code at the live cUSDC address: run with --fork-url");

        // Migration consumes version 4, so the live proxy must still be below it.
        uint64 liveVersion = uint64(uint256(vm.load(LIVE_CUSDC, INITIALIZABLE_STORAGE)));
        require(liveVersion < 4, "live cUSDC is already at V4 or later: renumber the treasury reinitializer");

        wrapper = ConfidentialWrapperTreasury(LIVE_CUSDC);
        underlying = ERC20Mock(wrapper.underlying());

        _repointFhevmConfig(LIVE_CUSDC);
        vm.store(LIVE_CUSDC, bytes32(uint256(ERC7984_STORAGE_BASE) + 2), bytes32(0));

        liveReserve = IERC20(address(underlying)).balanceOf(LIVE_CUSDC);

        vm.label(LIVE_CUSDC, "cUSDC(live)");
        vm.label(address(underlying), "USDC(live)");
    }

    // ----- Main flow -----

    /// @notice Wrap on the live implementation, upgrade, then unwrap out of the treasury.
    function test_LiveCusdc_ReserveMovesOnUpgradeAndSettlementComesFromTheTreasury() public {
        assertGt(liveReserve, 0, "precondition: the live wrapper holds a reserve");
        assertEq(underlying.balanceOf(address(treasury)), 0, "precondition: a fresh treasury holds nothing");

        _wrap(alice, 100 * ONE);
        assertEq(_balance(alice), uint64(100 * ONE), "alice was not credited on the live implementation");
        assertEq(underlying.balanceOf(LIVE_CUSDC), liveReserve + 100 * ONE, "the deposit did not rest at the wrapper");

        uint256 backingBefore = wrapper.inferredTotalSupply();
        assertEq(backingBefore, (liveReserve + 100 * ONE) / wrapper.rate(), "precondition: backing reads the wrapper");

        _completeDeployment();

        assertEq(wrapper.treasury(), address(treasury), "treasury() does not name the account");
        assertEq(underlying.balanceOf(LIVE_CUSDC), 0, "the wrapper still holds underlying");
        assertEq(underlying.balanceOf(address(treasury)), liveReserve + 100 * ONE, "the whole reserve did not arrive");
        assertEq(wrapper.treasuryBalance(), liveReserve + 100 * ONE, "treasuryBalance does not match");
        assertEq(wrapper.inferredTotalSupply(), backingBefore, "the migration changed the reported backing");
        assertEq(_balance(alice), uint64(100 * ONE), "alice's balance changed across the migration");

        _wrap(alice, 50 * ONE);
        assertEq(underlying.balanceOf(LIVE_CUSDC), 0, "a post-upgrade deposit rested at the wrapper");
        assertEq(
            underlying.balanceOf(address(treasury)), liveReserve + 150 * ONE, "the deposit did not reach the treasury"
        );

        (bytes32 unwrapId, uint64 cleartext, bytes memory proof) = _pendingUnwrapOn(wrapper, alice, uint64(60 * ONE));

        _watchLogs();
        wrapper.finalizeUnwrap(unwrapId, cleartext, proof);
        TokenTransfer[] memory hops = _transfersOf(address(underlying));

        assertEq(hops.length, 1, "expected exactly one underlying transfer");
        assertEq(hops[0].from, address(treasury), "the payout did not come from the treasury");
        assertEq(hops[0].to, alice, "the payout did not reach the holder");
        assertEq(hops[0].value, 60 * ONE, "the payout moved the wrong amount");

        assertEq(underlying.balanceOf(alice), 60 * ONE, "alice was not paid");
        assertEq(_balance(alice), uint64(90 * ONE), "alice's cUSDC was not burnt");
        assertEq(underlying.balanceOf(address(treasury)), liveReserve + 90 * ONE, "the treasury was not debited");
    }

    /// @notice A wrap funded by a third party is unwrappable by the holder alone.
    function test_LiveCusdc_OperatorFundedWrapIsUnwrappableByTheHolderAlone() public {
        _completeDeployment();

        deal(address(underlying), operator, 40 * ONE);
        vm.startPrank(operator);
        IERC20(address(underlying)).approve(address(wrapper), 40 * ONE);
        wrapper.wrap(alice, 40 * ONE);
        vm.stopPrank();

        assertEq(underlying.balanceOf(operator), 0, "the payer was not debited");
        assertEq(_balance(alice), uint64(40 * ONE), "the holder was not credited");
        assertEq(
            underlying.balanceOf(address(treasury)), liveReserve + 40 * ONE, "the deposit did not reach the treasury"
        );

        (bytes32 unwrapId, uint64 cleartext, bytes memory proof) = _pendingUnwrapOn(wrapper, alice, uint64(40 * ONE));

        _watchLogs();
        wrapper.finalizeUnwrap(unwrapId, cleartext, proof);
        TokenTransfer[] memory hops = _transfersOf(address(underlying));

        assertEq(hops.length, 1, "expected exactly one underlying transfer");
        assertEq(hops[0].from, address(treasury), "the payout did not come from the treasury");
        assertEq(hops[0].to, alice, "the payout did not reach the holder");

        assertEq(underlying.balanceOf(alice), 40 * ONE, "the holder was not paid");
        assertEq(underlying.balanceOf(operator), 0, "the payer was paid instead of the holder");
        assertEq(_balance(alice), 0, "the holder's cUSDC was not burnt");
    }

    /**
     * @notice The whole cToken lifecycle, entirely after the upgrade.
     *
     * @dev The other tests each straddle the migration. This one starts from the migrated wrapper and
     * runs wrap -> confidential transfer -> unwrap -> finalize for holders that did not exist before
     * it, so the steady state is covered end to end rather than only at the seam. The transfer leg
     * matters because it is the one step that touches no underlying at all: it must keep working
     * while the reserve sits somewhere else.
     */
    function test_LiveCusdc_FullWrapToUnwrapCycleAfterTheUpgrade() public {
        _completeDeployment();
        uint256 reserveAfterMigration = underlying.balanceOf(address(treasury));

        // ----- Wrap: underlying in, cTokens out -----
        _wrap(alice, 80 * ONE);
        assertEq(_balance(alice), uint64(80 * ONE), "alice was not credited");
        assertEq(underlying.balanceOf(address(treasury)), reserveAfterMigration + 80 * ONE, "deposit missed treasury");
        assertEq(underlying.balanceOf(LIVE_CUSDC), 0, "the deposit rested at the wrapper");

        // ----- Confidential transfer: no underlying moves -----
        _watchLogs();
        (externalEuint64 encAmount, bytes memory transferProof) = encryptUint64(uint64(30 * ONE), alice, LIVE_CUSDC);
        vm.prank(alice);
        wrapper.confidentialTransfer(bob, encAmount, transferProof);

        assertEq(_transfersOf(address(underlying)).length, 0, "a confidential transfer moved underlying");
        assertEq(_balance(alice), uint64(50 * ONE), "the sender was not debited");
        assertEq(_balance(bob), uint64(30 * ONE), "the recipient was not credited");
        assertEq(
            underlying.balanceOf(address(treasury)), reserveAfterMigration + 80 * ONE, "the reserve moved on a transfer"
        );

        // ----- Unwrap: the recipient exits for underlying he never deposited -----
        (bytes32 bobUnwrap, uint64 bobCleartext, bytes memory bobProof) =
            _pendingUnwrapOn(wrapper, bob, uint64(30 * ONE));

        _watchLogs();
        wrapper.finalizeUnwrap(bobUnwrap, bobCleartext, bobProof);
        TokenTransfer[] memory hops = _transfersOf(address(underlying));

        assertEq(hops.length, 1, "expected exactly one underlying transfer");
        assertEq(hops[0].from, address(treasury), "the payout did not come from the treasury");
        assertEq(hops[0].to, bob, "the payout did not reach the recipient");
        assertEq(hops[0].value, 30 * ONE, "the payout moved the wrong amount");
        assertEq(_balance(bob), 0, "the recipient's cUSDC was not burnt");

        // ----- And the original depositor exits too, leaving the reserve where it started -----
        (bytes32 aliceUnwrap, uint64 aliceCleartext, bytes memory aliceProof) =
            _pendingUnwrapOn(wrapper, alice, uint64(50 * ONE));
        wrapper.finalizeUnwrap(aliceUnwrap, aliceCleartext, aliceProof);

        assertEq(underlying.balanceOf(alice), 50 * ONE, "the depositor was not paid");
        assertEq(underlying.balanceOf(bob), 30 * ONE, "the recipient was not paid");
        assertEq(_balance(alice), 0, "the depositor's cUSDC was not burnt");
        assertEq(
            underlying.balanceOf(address(treasury)),
            reserveAfterMigration,
            "the round trip did not leave the reserve where it started"
        );
    }

    // ----- FHE permissions -----

    /**
     * @notice The upgrade disturbs no handle permission, and the treasury acquires none.
     *
     * @dev Every ACL grant the wrapper makes goes to `address(this)` (`FHE.allowThis` on balances,
     * total supply and the transferred amount), to a holder (`FHE.allow`), or to an observer
     * (`delegateUserDecryptionWithoutExpiration`). The reserve holder is not one of those, and the
     * reserve itself is plain ERC-20 with no handle attached — so there is nothing to re-grant when
     * it moves. This test states both halves: the wrapper's grants survive the implementation swap,
     * and the treasury settles a payout while holding no FHE access at all.
     *
     * `address(this)` is the proxy and the proxy address does not change, which is why the swap is
     * invisible to the ACL.
     *
     * NOTE: only handles created inside this test are visible here. The live wrapper's real holders
     * have their grants in Zama's mainnet ACL, and {_repointFhevmConfig} points the wrapper at the
     * in-process host instead, which knows nothing about them.
     */
    function test_LiveCusdc_UpgradePreservesHandlePermissionsAndTheTreasuryGetsNone() public {
        _wrap(alice, 50 * ONE);

        bytes32 balanceHandle = euint64.unwrap(wrapper.confidentialBalanceOf(alice));
        bytes32 supplyHandle = euint64.unwrap(wrapper.confidentialTotalSupply());
        assertTrue(_acl.persistAllowed(balanceHandle, alice), "precondition: the holder can use their balance");
        assertTrue(_acl.persistAllowed(balanceHandle, LIVE_CUSDC), "precondition: the wrapper can use it too");
        assertTrue(_acl.persistAllowed(supplyHandle, LIVE_CUSDC), "precondition: the wrapper owns total supply");

        _completeDeployment();

        // The handle is the same one, and both grants are intact: an implementation swap is not an
        // address change, and the ACL keys on the address.
        assertEq(euint64.unwrap(wrapper.confidentialBalanceOf(alice)), balanceHandle, "the balance handle was replaced");
        assertTrue(_acl.persistAllowed(balanceHandle, alice), "the holder lost access across the upgrade");
        assertTrue(_acl.persistAllowed(balanceHandle, LIVE_CUSDC), "the wrapper lost access across the upgrade");
        assertTrue(_acl.persistAllowed(supplyHandle, LIVE_CUSDC), "the wrapper lost its total-supply handle");

        // The account that now holds the reserve is party to none of it.
        assertFalse(_acl.persistAllowed(balanceHandle, address(treasury)), "the treasury was granted a balance handle");
        assertFalse(_acl.persistAllowed(supplyHandle, address(treasury)), "the treasury was granted total supply");

        // And the preserved grants are usable, not merely present: alice settles after the upgrade,
        // with the treasury still holding no access to the amount it just paid out on.
        (bytes32 unwrapId, uint64 cleartext, bytes memory proof) = _pendingUnwrapOn(wrapper, alice, uint64(20 * ONE));
        wrapper.finalizeUnwrap(unwrapId, cleartext, proof);

        assertEq(underlying.balanceOf(alice), 20 * ONE, "the preserved permissions did not survive a settlement");
        assertFalse(_acl.persistAllowed(unwrapId, address(treasury)), "the treasury was granted the unwrap amount");
        assertTrue(_acl.isAllowedForDecryption(unwrapId), "the unwrap amount should stay publicly decryptable");
    }

    /// @notice An unwrap requested before the upgrade still settles after it.
    function test_LiveCusdc_UnwrapRequestedBeforeTheUpgradeSettlesAfterIt() public {
        _wrap(alice, 100 * ONE);

        (bytes32 unwrapId, uint64 cleartext, bytes memory proof) = _pendingUnwrapOn(wrapper, alice, uint64(30 * ONE));
        assertEq(wrapper.unwrapRequester(unwrapId), alice, "precondition: the request is pending pre-upgrade");

        _completeDeployment();

        assertEq(wrapper.unwrapRequester(unwrapId), alice, "the pending request did not survive the upgrade");

        _watchLogs();
        wrapper.finalizeUnwrap(unwrapId, cleartext, proof);
        TokenTransfer[] memory hops = _transfersOf(address(underlying));

        assertEq(hops.length, 1, "expected exactly one underlying transfer");
        assertEq(hops[0].from, address(treasury), "the in-flight request did not settle from the treasury");
        assertEq(hops[0].to, alice, "the payout did not reach the holder");

        assertEq(underlying.balanceOf(alice), 30 * ONE, "the in-flight request was not paid");
        assertEq(_balance(alice), uint64(70 * ONE), "the remaining cUSDC is wrong");
    }
}
