// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {BaseForkTest} from "./BaseForkTest.t.sol";
import {ConfidentialWrapper} from "confidential-wrapper/ConfidentialWrapper.sol";
import {externalEuint64} from "encrypted-types/EncryptedTypes.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {IERC1363} from "@openzeppelin/contracts/interfaces/IERC1363.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @notice End-to-end user flow (wrap -> transfer -> unwrap -> finalize) run against
 * every wrapper the registry enumerates at the fork block.
 */
contract WrapperFlowsTest is BaseForkTest {
    /// @dev Confidential token amount wrapped per case
    uint64 internal constant CONFIDENTIAL_AMOUNT = 1_000_000;

    function setUp() public override {
        super.setUp();
        // The full cycle chains several FHE ops; relax only the sequential depth cap.
        disableHCUDepthLimit();
    }

    function test_FullCycle_AllWrappers() public {
        assertGt(wrappers.length, 0, "no valid wrappers enumerated from registry");

        for (uint256 i = 0; i < wrappers.length; i++) {
            _runFullCycle(wrappers[i]);
        }
    }

    function test_OperatorPaths_AllWrappers() public {
        assertGt(wrappers.length, 0, "no valid wrappers enumerated from registry");

        for (uint256 i = 0; i < wrappers.length; i++) {
            _runOperatorPaths(wrappers[i]);
        }
    }

    function test_UnderlyingRateAndDecimals_AllWrappers() public view {
        assertGt(wrappers.length, 0, "no valid wrappers enumerated from registry");

        for (uint256 i = 0; i < wrappers.length; i++) {
            address w = wrappers[i];
            string memory sym = _label(w);
            address underlying = address(_underlying(w));

            assertGt(underlying.code.length, 0, string.concat(sym, ": missing underlying token code"));

            uint8 wrapperDecimals = _wrapper(w).decimals();
            uint8 underlyingDecimals = IERC20Metadata(underlying).decimals();
            assertGe(underlyingDecimals, wrapperDecimals, string.concat(sym, ": underlying decimals below wrapper"));
            assertEq(
                _wrapper(w).rate(),
                10 ** (underlyingDecimals - wrapperDecimals),
                string.concat(sym, ": rate does not match decimals")
            );
        }
    }

    function test_UnderlyingStaticStorageSmoke_AllWrappers() public view {
        assertGt(wrappers.length, 0, "no valid wrappers enumerated from registry");

        for (uint256 i = 0; i < wrappers.length; i++) {
            address w = wrappers[i];
            string memory sym = _label(w);
            address underlying = address(_underlying(w));

            assertGt(underlying.code.length, 0, string.concat(sym, ": missing underlying token code"));
            _assertNonEmptyStringCall(underlying, abi.encodeCall(IERC20Metadata.name, ()), sym, "name");
            _assertNonEmptyStringCall(underlying, abi.encodeCall(IERC20Metadata.symbol, ()), sym, "symbol");

            (bool decimalsOk, bytes memory decimalsData) = underlying.staticcall(
                abi.encodeCall(IERC20Metadata.decimals, ())
            );
            assertTrue(decimalsOk && decimalsData.length == 32, string.concat(sym, ": decimals static call failed"));
            assertGt(
                abi.decode(decimalsData, (uint8)),
                0,
                string.concat(sym, ": underlying decimals not readable on fork")
            );

            (bool supplyOk, bytes memory supplyData) = underlying.staticcall(abi.encodeCall(IERC20.totalSupply, ()));
            assertTrue(supplyOk && supplyData.length == 32, string.concat(sym, ": totalSupply static call failed"));
            assertGt(
                abi.decode(supplyData, (uint256)),
                0,
                string.concat(sym, ": underlying totalSupply not readable on fork")
            );

            _assertErc165StaticStorageIfImplemented(underlying, sym);
        }
    }

    function _runFullCycle(address w) internal {
        string memory sym = _label(w);

        address alice = makeAddr(string.concat("alice-", sym));
        address bob = makeAddr(string.concat("bob-", sym));

        uint256 rate = _wrapper(w).rate();
        uint64 c = CONFIDENTIAL_AMOUNT;
        uint64 half = c / 2;

        _runWrapPath(w, sym, alice, c, rate);
        _runConfidentialTransferPath(w, sym, alice, bob, c, half);
        bytes32 unwrapId = _runUnwrapPath(w, sym, bob, c, half);
        _runFinalizeUnwrapPath(w, sym, bob, unwrapId, half, rate);
        _runOnTransferReceivedPath(w, sym);
    }

    function _runOperatorPaths(address w) internal {
        string memory sym = _label(w);

        address holder = makeAddr(string.concat("operator-holder-", sym));
        address recipient = makeAddr(string.concat("operator-transfer-recipient-", sym));
        address operator = makeAddr(string.concat("operator-path-", sym));
        address operatorRecipient = makeAddr(string.concat("operator-unwrap-recipient-", sym));

        uint256 rate = _wrapper(w).rate();
        uint64 startingBalance = 2;
        uint64 amount = 1;

        _runWrapPath(w, sym, holder, startingBalance, rate);
        _runOperatorTransferPath(w, sym, holder, recipient, operator, startingBalance, amount);
        bytes32 unwrapId = _runOperatorUnwrapPath(
            w,
            sym,
            recipient,
            operator,
            operatorRecipient,
            startingBalance,
            amount
        );
        _runFinalizeUnwrapPath(w, sym, operatorRecipient, unwrapId, amount, rate);
    }

    function _runWrapPath(address w, string memory sym, address alice, uint64 amount, uint256 rate) internal {
        IERC20 underlying = _underlying(w);
        uint256 underlyingAmount = uint256(amount) * rate;
        uint256 aliceUnderlyingBefore = underlying.balanceOf(alice);
        uint256 wrapperUnderlyingBefore = underlying.balanceOf(w);

        _dealAndWrap(w, alice, underlyingAmount);

        assertEq(
            underlying.balanceOf(alice),
            aliceUnderlyingBefore,
            string.concat(sym, ": user underlying after wrap")
        );
        assertEq(
            underlying.balanceOf(w) - wrapperUnderlyingBefore,
            underlyingAmount,
            string.concat(sym, ": wrapper underlying after wrap")
        );
        assertEq(_decryptBalance(w, alice), amount, string.concat(sym, ": alice balance after wrap"));
        // Total supply handle is zeroed at setUp, so it starts fresh from this wrap.
        assertEq(_decryptTotalSupply(w), amount, string.concat(sym, ": total supply after wrap"));
    }

    function _runConfidentialTransferPath(
        address w,
        string memory sym,
        address alice,
        address bob,
        uint64 startingBalance,
        uint64 amount
    ) internal {
        (externalEuint64 enc, bytes memory proof) = encryptUint64(amount, alice, w);
        vm.prank(alice);
        _wrapper(w).confidentialTransfer(bob, enc, proof);

        assertEq(
            _decryptBalance(w, alice),
            startingBalance - amount,
            string.concat(sym, ": alice balance after transfer")
        );
        assertEq(_decryptBalance(w, bob), amount, string.concat(sym, ": bob balance after transfer"));
    }

    function _runOperatorTransferPath(
        address w,
        string memory sym,
        address holder,
        address recipient,
        address operator,
        uint64 startingHolderBalance,
        uint64 amount
    ) internal {
        vm.prank(holder);
        _wrapper(w).setOperator(operator, uint48(block.timestamp + 1 days));
        assertTrue(_wrapper(w).isOperator(holder, operator), string.concat(sym, ": operator not approved"));

        (externalEuint64 enc, bytes memory proof) = encryptUint64(amount, operator, w);
        vm.prank(operator);
        _wrapper(w).confidentialTransferFrom(holder, recipient, enc, proof);

        assertEq(
            _decryptBalance(w, holder),
            startingHolderBalance - amount,
            string.concat(sym, ": holder balance after operator transfer")
        );
        assertEq(
            _decryptBalance(w, recipient),
            amount,
            string.concat(sym, ": recipient balance after operator transfer")
        );
    }

    function _runUnwrapPath(
        address w,
        string memory sym,
        address bob,
        uint64 totalSupplyBefore,
        uint64 amount
    ) internal returns (bytes32 unwrapId) {
        (externalEuint64 enc, bytes memory proof) = encryptUint64(amount, bob, w);
        vm.prank(bob);
        unwrapId = _wrapper(w).unwrap(bob, bob, enc, proof);

        // Burn already happened in unwrap, so supply decreases now.
        assertEq(_decryptTotalSupply(w), totalSupplyBefore - amount, string.concat(sym, ": total supply after unwrap"));
    }

    function _runOperatorUnwrapPath(
        address w,
        string memory sym,
        address holder,
        address operator,
        address recipient,
        uint64 totalSupplyBefore,
        uint64 amount
    ) internal returns (bytes32 unwrapId) {
        vm.prank(holder);
        _wrapper(w).setOperator(operator, uint48(block.timestamp + 1 days));

        (externalEuint64 enc, bytes memory proof) = encryptUint64(amount, operator, w);
        vm.prank(operator);
        unwrapId = _wrapper(w).unwrap(holder, recipient, enc, proof);

        assertEq(
            _decryptTotalSupply(w),
            totalSupplyBefore - amount,
            string.concat(sym, ": total supply after operator unwrap")
        );
        assertEq(_wrapper(w).unwrapRequester(unwrapId), recipient, string.concat(sym, ": bad unwrap recipient"));
    }

    function _runFinalizeUnwrapPath(
        address w,
        string memory sym,
        address bob,
        bytes32 unwrapId,
        uint64 amount,
        uint256 rate
    ) internal {
        uint256 bobUnderlyingBefore = _underlying(w).balanceOf(bob);
        (uint64 cleartext, bytes memory decryptionProof) = _publicDecryptEuint64(unwrapId);

        assertEq(cleartext, amount, string.concat(sym, ": decrypted unwrap amount"));
        _wrapper(w).finalizeUnwrap(unwrapId, cleartext, decryptionProof);

        assertEq(
            _underlying(w).balanceOf(bob) - bobUnderlyingBefore,
            uint256(amount) * rate,
            string.concat(sym, ": underlying returned to bob")
        );
    }

    /// @dev Drives the real ERC-1363 wrap path: only runs when the underlying
    /// advertises ERC-1363 support via ERC-165.
    function _runOnTransferReceivedPath(address w, string memory sym) internal {
        address underlying = address(_underlying(w));
        if (!ERC165Checker.supportsInterface(underlying, type(IERC1363).interfaceId)) return;

        ConfidentialWrapper wrapper = _wrapper(w);
        address sender = makeAddr(string.concat("erc1363-sender-", sym));
        address recipient = makeAddr(string.concat("erc1363-recipient-", sym));
        uint256 rate = wrapper.rate();
        uint256 underlyingAmount = uint256(CONFIDENTIAL_AMOUNT) * rate;

        deal(underlying, sender, _underlying(w).balanceOf(sender) + underlyingAmount);

        vm.prank(sender);
        IERC1363(underlying).transferAndCall(w, underlyingAmount, abi.encodePacked(recipient));

        assertEq(
            _decryptBalance(w, recipient),
            CONFIDENTIAL_AMOUNT,
            string.concat(sym, ": ERC-1363 transferAndCall did not mint to recipient")
        );
    }

    function _assertNonEmptyStringCall(
        address target,
        bytes memory callData,
        string memory sym,
        string memory label
    ) internal view {
        (bool ok, bytes memory data) = target.staticcall(callData);
        assertTrue(ok, string.concat(sym, ": ", label, " static call failed"));
        assertGe(data.length, 64, string.concat(sym, ": ", label, " returned bad data"));
        assertGt(bytes(abi.decode(data, (string))).length, 0, string.concat(sym, ": ", label, " not readable on fork"));
    }

    function _assertErc165StaticStorageIfImplemented(address underlying, string memory sym) internal view {
        (bool ok, bytes memory data) = underlying.staticcall(
            abi.encodeCall(IERC165.supportsInterface, (type(IERC165).interfaceId))
        );

        // Most deployed ERC-20s do not implement ERC-165. If the call does return
        // a normal bool, ERC-165 requires the IERC165 interface id to be supported.
        if (!ok || data.length != 32) return;
        assertTrue(abi.decode(data, (bool)), string.concat(sym, ": ERC165 support not readable on fork"));

        (bool erc1363Ok, bytes memory erc1363Data) = underlying.staticcall(
            abi.encodeCall(IERC165.supportsInterface, (type(IERC1363).interfaceId))
        );
        assertTrue(erc1363Ok && erc1363Data.length == 32, string.concat(sym, ": IERC1363 support check failed"));
    }
}
