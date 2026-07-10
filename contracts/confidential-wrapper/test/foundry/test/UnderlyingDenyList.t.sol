// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {BaseForkTest} from "./BaseForkTest.t.sol";
import {ConfidentialWrapper} from "confidential-wrapper/ConfidentialWrapper.sol";
import {externalEuint64} from "encrypted-types/EncryptedTypes.sol";

/**
 * @notice Exercises configured underlying deny-list selectors against the baked
 * mainnet token code. This intentionally does not mock the underlying token:
 * the selector must staticcall the materialized underlying implementation and
 * return a normal boolean response before the wrapper is allowed to wrap.
 */
contract UnderlyingDenyListTest is BaseForkTest {
    function setUp() public override {
        super.setUp();
        // The null-address test completes a wrap+unwrap (mint then burn), which chains a few
        // FHE ops; relax the sequential depth cap.
        disableHCUDepthLimit();
    }

    function test_ConfiguredUnderlyingDenyListSelectors_AllWrappers() public {
        uint256 configured;

        for (uint256 i = 0; i < wrappers.length; i++) {
            address w = wrappers[i];
            string memory sym = _label(w);
            (bool isSet, bytes4 selector) = _wrapper(w).getUnderlyingDenyListSelector();
            if (!isSet) continue;

            configured++;
            address token = _wrapper(w).underlying();
            address user = makeAddr(string.concat("underlying-deny-list-user-", sym));

            assertGt(token.code.length, 0, string.concat(sym, ": missing underlying token code"));

            (bool success, bytes memory data) = token.staticcall(abi.encodeWithSelector(selector, user));
            assertTrue(success, string.concat(sym, ": underlying deny-list selector reverted"));
            assertEq(data.length, 32, string.concat(sym, ": underlying deny-list selector returned bad length"));
            assertFalse(abi.decode(data, (bool)), string.concat(sym, ": random test user is underlying-denied"));

            _dealAndWrap(w, user, _wrapper(w).rate());
            assertEq(_decryptBalance(w, user), 1, string.concat(sym, ": wrap failed with real underlying selector"));
        }

        assertGt(configured, 0, "no wrappers have underlying deny-list selectors configured");
    }

    /**
     * @notice Uses real baked blacklist membership from mainnet state and checks
     * that the wrapper's direct wrap path rejects a known blacklisted depositor.
     */
    function test_UnderlyingDenyListBlocksKnownBlacklistedWrap() public {
        uint256 exercised;

        for (uint256 i = 0; i < wrappers.length; i++) {
            (address w, bytes4 selector, address token, address denied) = _configuredDenyListCase(wrappers[i]);
            if (w == address(0)) continue;
            exercised++;
            string memory sym = _label(w);

            (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSelector(selector, denied));
            assertTrue(ok && data.length == 32, string.concat(sym, ": baked blacklist getter call failed"));
            assertTrue(abi.decode(data, (bool)), string.concat(sym, ": baked address not denied"));

            uint256 amount = 1;
            vm.prank(denied);
            vm.expectRevert(abi.encodeWithSelector(ConfidentialWrapper.UnderlyingDenyListedAddress.selector, denied));
            _wrapper(w).wrap(denied, amount);
        }

        assertGt(exercised, 0, "no known baked blacklisted depositors among supported wrappers");
    }

    function test_UnderlyingDenyListBlocksKnownBlacklistedWrapRecipient() public {
        uint256 exercised;

        for (uint256 i = 0; i < wrappers.length; i++) {
            (address w, , address token, address denied) = _configuredDenyListCase(wrappers[i]);
            if (w == address(0)) continue;
            exercised++;
            string memory sym = _label(w);

            address depositor = makeAddr(string.concat("clean-depositor-", sym));
            uint256 amount = _wrapper(w).rate();
            deal(token, depositor, amount);
            vm.startPrank(depositor);
            _approve(_underlying(w), w, amount);
            vm.expectRevert(abi.encodeWithSelector(ConfidentialWrapper.UnderlyingDenyListedAddress.selector, denied));
            _wrapper(w).wrap(denied, amount);
            vm.stopPrank();
        }

        assertGt(exercised, 0, "no known baked blacklisted recipients among supported wrappers");
    }

    function test_UnderlyingDenyListBlocksKnownBlacklistedConfidentialTransferRecipient() public {
        uint256 exercised;

        for (uint256 i = 0; i < wrappers.length; i++) {
            (address w, , , address denied) = _configuredDenyListCase(wrappers[i]);
            if (w == address(0)) continue;
            exercised++;
            string memory sym = _label(w);

            address holder = makeAddr(string.concat("transfer-holder-", sym));
            uint64 amount = 1;
            _dealAndWrap(w, holder, _wrapper(w).rate());

            (externalEuint64 enc, bytes memory proof) = encryptUint64(amount, holder, w);
            vm.prank(holder);
            vm.expectRevert(abi.encodeWithSelector(ConfidentialWrapper.UnderlyingDenyListedAddress.selector, denied));
            _wrapper(w).confidentialTransfer(denied, enc, proof);
        }

        assertGt(exercised, 0, "no known baked blacklisted transfer recipients among supported wrappers");
    }

    function test_UnderlyingDenyListBlocksKnownBlacklistedUnwrapRecipient() public {
        uint256 exercised;

        for (uint256 i = 0; i < wrappers.length; i++) {
            (address w, , , address denied) = _configuredDenyListCase(wrappers[i]);
            if (w == address(0)) continue;
            exercised++;
            string memory sym = _label(w);

            address holder = makeAddr(string.concat("unwrap-holder-", sym));
            uint64 amount = 1;
            _dealAndWrap(w, holder, _wrapper(w).rate());

            (externalEuint64 enc, bytes memory proof) = encryptUint64(amount, holder, w);
            vm.prank(holder);
            vm.expectRevert(abi.encodeWithSelector(ConfidentialWrapper.UnderlyingDenyListedAddress.selector, denied));
            _wrapper(w).unwrap(holder, denied, enc, proof);
        }

        assertGt(exercised, 0, "no known baked blacklisted unwrap recipients among supported wrappers");
    }

    /**
     * @notice A denied null address must NOT block minting or burning. `_requireNotBlocked`
     * short-circuits address(0) precisely because mint has from == 0 and burn has to == 0, and
     * some underlyings (e.g. USDT) report isBlackListed(address(0)) == true.
     */
    function test_UnderlyingDenyListNullAddressDoesNotBlock() public {
        uint256 exercised;

        for (uint256 i = 0; i < wrappers.length; i++) {
            address w = wrappers[i];
            (bool isSet, bytes4 selector) = _wrapper(w).getUnderlyingDenyListSelector();
            if (!isSet) continue;
            address token = _wrapper(w).underlying();

            (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSelector(selector, address(0)));
            if (!ok || data.length != 32 || !abi.decode(data, (bool))) continue; // underlying allows the null address
            exercised++;
            string memory sym = _label(w);

            // Mint: wrap does _update(0, holder, ...); a denied null address must not block it.
            address holder = makeAddr(string.concat("null-deny-holder-", sym));
            _dealAndWrap(w, holder, _wrapper(w).rate());
            assertEq(_decryptBalance(w, holder), 1, string.concat(sym, ": mint blocked by denied null address"));

            // Burn: unwrap does _update(holder, 0, ...); a denied null address must not block it.
            (externalEuint64 enc, bytes memory proof) = encryptUint64(1, holder, w);
            vm.prank(holder);
            _wrapper(w).unwrap(holder, holder, enc, proof);
            assertEq(_decryptTotalSupply(w), 0, string.concat(sym, ": burn blocked by denied null address"));
        }

        assertGt(exercised, 0, "no configured wrapper whose underlying denies the null address");
    }

    /**
     * @notice If the curated blacklist seed list is present, asserts each seeded address is reported
     * denied by the underlying token getter against the captured mainnet state.
     */
    function test_UnderlyingDenyListBakedBlacklist() public {
        string memory path = "config/blacklist-seeds.json";
        if (!vm.exists(path)) {
            emit log("blacklist-seeds.json absent; skipping known-blacklisted deny-list assertion");
            return;
        }

        string memory json = vm.readFile(path);
        uint256 checked;

        for (uint256 ti = 0; ; ti++) {
            string memory base = string.concat(".tokens[", vm.toString(ti), "]");
            if (!vm.keyExistsJson(json, base)) break;

            address token = vm.parseJsonAddress(json, string.concat(base, ".token"));
            bytes4 sel = _canonicalDenyListSelector(token);
            if (sel == bytes4(0)) continue;

            address[] memory listed = vm.parseJsonAddressArray(json, string.concat(base, ".blacklisted"));
            for (uint256 j = 0; j < listed.length && j < 5; j++) {
                (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSelector(sel, listed[j]));
                assertTrue(ok && data.length == 32, "baked blacklist getter call failed");
                assertTrue(abi.decode(data, (bool)), "baked address not denied by real token state");
                checked++;
            }
        }

        if (checked == 0) emit log("no baked blacklisted addresses present to check");
    }

    function _knownBakedBlacklistedAddress(address token) internal view returns (address) {
        string memory path = "config/blacklist-seeds.json";
        if (!vm.exists(path)) return address(0);

        string memory json = vm.readFile(path);
        for (uint256 ti = 0; ; ti++) {
            string memory base = string.concat(".tokens[", vm.toString(ti), "]");
            if (!vm.keyExistsJson(json, base)) break;
            if (vm.parseJsonAddress(json, string.concat(base, ".token")) != token) continue;

            address[] memory listed = vm.parseJsonAddressArray(json, string.concat(base, ".blacklisted"));
            for (uint256 j = 0; j < listed.length; j++) {
                if (listed[j] != address(0)) return listed[j];
            }
            return address(0);
        }

        return address(0);
    }

    function _configuredDenyListCase(
        address w
    ) internal view returns (address wrapper, bytes4 selector, address token, address denied) {
        bool isSet;
        (isSet, selector) = _wrapper(w).getUnderlyingDenyListSelector();
        if (!isSet) return (address(0), bytes4(0), address(0), address(0));

        token = _wrapper(w).underlying();
        denied = _knownBakedBlacklistedAddress(token);
        if (denied == address(0)) return (address(0), bytes4(0), address(0), address(0));

        return (w, selector, token, denied);
    }
}
