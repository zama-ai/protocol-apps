// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {BaseForkTest} from "./BaseForkTest.t.sol";
import {ConfidentialWrapper} from "confidential-wrapper/ConfidentialWrapper.sol";
import {externalEuint64} from "encrypted-types/EncryptedTypes.sol";

/**
 * @notice Exercises configured underlying deny-list selectors against the real
 * mainnet token code on the fork. This intentionally does not mock the underlying
 * token: the selector must staticcall the live underlying implementation and
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

            assertFalse(
                _queryUnderlyingDenyList(token, selector, user),
                string.concat(sym, ": random test user is underlying-denied")
            );

            _dealAndWrap(w, user, _wrapper(w).rate());
            assertEq(_decryptBalance(w, user), 1, string.concat(sym, ": wrap failed with real underlying selector"));
        }

        assertGt(configured, 0, "no wrappers have underlying deny-list selectors configured");
    }

    /**
     * @notice Uses real blacklist membership from mainnet state and checks
     * that the wrapper's direct wrap path rejects a known blacklisted depositor.
     */
    function test_UnderlyingDenyListBlocksKnownBlacklistedWrap() public {
        uint256 exercised;

        for (uint256 i = 0; i < wrappers.length; i++) {
            (address w, bytes4 selector, address token, address denied) = _configuredDenyListCase(wrappers[i]);
            if (w == address(0)) continue;
            exercised++;
            string memory sym = _label(w);

            assertTrue(
                _queryUnderlyingDenyList(token, selector, denied),
                string.concat(sym, ": seeded address not denied by real token state")
            );

            uint256 amount = 1;
            vm.prank(denied);
            vm.expectRevert(abi.encodeWithSelector(ConfidentialWrapper.UnderlyingDenyListedAddress.selector, denied));
            _wrapper(w).wrap(denied, amount);
        }

        assertGt(exercised, 0, "no known blacklisted depositors among supported wrappers");
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

        assertGt(exercised, 0, "no known blacklisted recipients among supported wrappers");
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

        assertGt(exercised, 0, "no known blacklisted transfer recipients among supported wrappers");
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

        assertGt(exercised, 0, "no known blacklisted unwrap recipients among supported wrappers");
    }

    /**
     * @notice Freshly blacklists a brand-new user through the underlying token's own admin setter
     * (pranked as the token's configured authority), then proves every wrapper entry point rejects that
     * user. This exercises deny-list enforcement even for underlyings that have no pre-existing
     * blacklisted address in mainnet state (e.g. TGBP), which the known-blacklist tests skip.
     */
    function test_UnderlyingDenyListBlocksFreshlyBlacklistedUser() public {
        uint256 exercised;

        for (uint256 i = 0; i < wrappers.length; i++) {
            address w = wrappers[i];
            (bool isSet, bytes4 getter) = _wrapper(w).getUnderlyingDenyListSelector();
            if (!isSet) continue;

            address token = _wrapper(w).underlying();
            UnderlyingDenyListInterface memory iface = _underlyingDenyListInterface(token);

            exercised++;
            string memory sym = _label(w);
            address victim = makeAddr(string.concat("freshly-blacklisted-", sym));
            assertFalse(_queryUnderlyingDenyList(token, getter, victim), string.concat(sym, ": victim pre-denied"));

            // Prank the token's own admin and add `victim` to the real underlying deny-list.
            address authority = _underlyingDenyListAuthority(token, iface.authority);
            vm.prank(authority);
            (bool ok, ) = token.call(abi.encodeWithSelector(iface.setter, victim));
            assertTrue(ok, string.concat(sym, ": underlying blacklist setter reverted"));
            assertTrue(
                _queryUnderlyingDenyList(token, getter, victim),
                string.concat(sym, ": victim not denied after admin blacklist")
            );

            _assertAllWrapperOpsBlocked(w, sym, victim);
        }

        assertGt(exercised, 0, "no wrapper underlying exposes a configured blacklist setter + authority");
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

            if (!_queryUnderlyingDenyList(token, selector, address(0))) continue; // underlying allows the null address
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
     * denied by the underlying token getter against the real mainnet state on the fork.
     */
    function test_UnderlyingDenyListSeededBlacklist() public {
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
                assertTrue(
                    _queryUnderlyingDenyList(token, sel, listed[j]),
                    "seeded address not denied by real token state"
                );
                checked++;
            }
        }

        if (checked == 0) emit log("no seeded blacklisted addresses present to check");
    }

    function _knownBlacklistedAddress(address token) internal view returns (address) {
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

    /// @notice Staticcalls an underlying deny-list getter (`selector(account)`) against the real token
    /// code on the fork and returns whether it reports `account` as denied. Reverts when the getter is
    /// unreadable (the call failed or did not return a 32-byte boolean).
    /// @dev We only hold the raw getter selector, so the call must stay low-level
    function _queryUnderlyingDenyList(
        address token,
        bytes4 selector,
        address account
    ) internal view returns (bool isDenied) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSelector(selector, account));
        require(success && data.length == 32, "underlying deny-list getter unreadable on fork");
        return abi.decode(data, (bool));
    }

    /// @notice Reads the address allowed to mutate `token`'s deny-list via its configured authority
    /// getter (e.g. `owner()`, `blacklister()`). Reverts when the getter is unreadable on the fork.
    function _underlyingDenyListAuthority(address token, bytes4 authoritySelector) internal view returns (address) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSelector(authoritySelector));
        require(success && data.length == 32, "underlying deny-list authority unreadable on fork");
        return abi.decode(data, (address));
    }

    /// @notice Asserts every wrapper entry point rejects `denied` with UnderlyingDenyListedAddress:
    /// direct wrap by the denied depositor, wrap crediting the denied recipient, confidential transfer
    /// to the denied recipient, and unwrap to the denied recipient.
    function _assertAllWrapperOpsBlocked(address w, string memory sym, address denied) internal {
        ConfidentialWrapper wrapper = _wrapper(w);
        uint256 amount = wrapper.rate();
        bytes memory expectedRevert = abi.encodeWithSelector(
            ConfidentialWrapper.UnderlyingDenyListedAddress.selector,
            denied
        );

        // Direct wrap by the denied depositor: rejected before any underlying funds move.
        vm.prank(denied);
        vm.expectRevert(expectedRevert);
        wrapper.wrap(denied, amount);

        // Wrap crediting the denied recipient, funded and pranked from a clean depositor.
        address depositor = makeAddr(string.concat("fresh-block-depositor-", sym));
        deal(address(_underlying(w)), depositor, amount);
        vm.startPrank(depositor);
        _approve(_underlying(w), w, amount);
        vm.expectRevert(expectedRevert);
        wrapper.wrap(denied, amount);
        vm.stopPrank();

        // Confidential transfer and unwrap targeting the denied recipient, from a funded holder.
        address holder = makeAddr(string.concat("fresh-block-holder-", sym));
        _dealAndWrap(w, holder, amount);

        (externalEuint64 transferEnc, bytes memory transferProof) = encryptUint64(1, holder, w);
        vm.prank(holder);
        vm.expectRevert(expectedRevert);
        wrapper.confidentialTransfer(denied, transferEnc, transferProof);

        (externalEuint64 unwrapEnc, bytes memory unwrapProof) = encryptUint64(1, holder, w);
        vm.prank(holder);
        vm.expectRevert(expectedRevert);
        wrapper.unwrap(holder, denied, unwrapEnc, unwrapProof);
    }

    function _configuredDenyListCase(
        address w
    ) internal view returns (address wrapper, bytes4 selector, address token, address denied) {
        bool isSet;
        (isSet, selector) = _wrapper(w).getUnderlyingDenyListSelector();
        if (!isSet) return (address(0), bytes4(0), address(0), address(0));

        token = _wrapper(w).underlying();
        denied = _knownBlacklistedAddress(token);
        if (denied == address(0)) return (address(0), bytes4(0), address(0), address(0));

        return (w, selector, token, denied);
    }
}
