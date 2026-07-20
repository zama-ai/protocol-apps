// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {BaseForkTest} from "./BaseForkTest.t.sol";
import {ConfidentialWrapper} from "confidential-wrapper/ConfidentialWrapper.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @notice Upgrade-safety checks for swapping every live proxy onto the repo-HEAD implementation.
/// @dev The swap itself runs in {BaseForkTest.setUp}; these tests assert it preserved storage and
/// that the upgrade path stays owner-gated and non-replayable.
contract UpgradeTest is BaseForkTest {
    /// @notice Every storage-backed getter and raw ERC-7201 slot survives the impl swap, and the
    /// implementation pointer now references the freshly-deployed impl.
    function test_UpgradePreservesStorage_AllWrappers() public view {
        for (uint256 i = 0; i < wrappers.length; i++) {
            address proxy = wrappers[i];
            string memory sym = _label(proxy);
            PreUpgradeSnapshot storage snapshot = preUpgrade[proxy];
            ConfidentialWrapper wrapper = _wrapper(proxy);

            assertEq(wrapper.name(), snapshot.name, string.concat(sym, ": name changed"));
            assertEq(wrapper.symbol(), snapshot.symbol, string.concat(sym, ": symbol changed"));
            assertEq(wrapper.contractURI(), snapshot.contractUri, string.concat(sym, ": contractURI changed"));
            assertEq(uint256(wrapper.decimals()), uint256(snapshot.decimals), string.concat(sym, ": decimals changed"));
            assertEq(address(wrapper.underlying()), snapshot.underlying, string.concat(sym, ": underlying changed"));
            assertEq(wrapper.rate(), snapshot.rate, string.concat(sym, ": rate changed"));
            assertEq(_wrapperOwner(proxy), snapshot.owner, string.concat(sym, ": owner changed"));
            assertEq(wrapper.maxTotalSupply(), snapshot.maxTotalSupply, string.concat(sym, ": maxTotalSupply changed"));
            (bool hasUnderlyingDenyListSelector, bytes4 underlyingDenyListSelector) = wrapper
                .getUnderlyingDenyListSelector();
            assertEq(
                hasUnderlyingDenyListSelector,
                snapshot.hasUnderlyingDenyListSelector,
                string.concat(sym, ": underlying deny-list flag changed")
            );
            assertEq(
                underlyingDenyListSelector,
                snapshot.underlyingDenyListSelector,
                string.concat(sym, ": underlying deny-list selector changed")
            );

            assertEq(_implementationOf(proxy), address(newImplementation), string.concat(sym, ": impl not updated"));
            assertTrue(_implementationOf(proxy) != snapshot.implementation, string.concat(sym, ": impl unchanged"));

            // Raw-slot check, below the getters. The getters above prove the observable, getter-backed
            // state is intact. These raw reads add what the getters cannot: they cover storage no checked
            // getter exposes (the _balances/_operators/_unwrapRequests mapping bases, the packed
            // _underlying+_decimals neighbor bits, the _totalSupply handle word, and the V3 mapping bases),
            // and they anchor the namespace origin independently of any getter's implementation. We read the
            // contiguous head of each namespaced struct (bases declared in BaseForkTest):
            //   ERC7984 (6 words): _balances base, _operators base, _totalSupply handle, _name,
            //                      _symbol, _contractURI.
            //   wrapper (3 words): _underlying+_decimals (packed), _rate, _unwrapRequests base.
            //   V3 (3 words): _blockedUsers base, _unwrapContexts base, _underlyingDenyListSelector + bool.
            // Mapping bases hold no entries here; comparing them anchors the namespace origin.
            for (uint256 j = 0; j < 6; j++) {
                assertEq(
                    vm.load(proxy, bytes32(uint256(ERC7984_STORAGE_BASE) + j)),
                    snapshot.erc7984Slots[j],
                    string.concat(sym, ": ERC7984 slot changed")
                );
            }
            for (uint256 j = 0; j < 3; j++) {
                assertEq(
                    vm.load(proxy, bytes32(uint256(WRAPPER_STORAGE_BASE) + j)),
                    snapshot.wrapperSlots[j],
                    string.concat(sym, ": wrapper slot changed")
                );
            }
            for (uint256 j = 0; j < 3; j++) {
                assertEq(
                    vm.load(proxy, bytes32(uint256(CONFIDENTIAL_WRAPPER_V3_STORAGE_BASE) + j)),
                    snapshot.v3Slots[j],
                    string.concat(sym, ": V3 slot changed")
                );
            }
            assertEq(
                vm.load(proxy, _v3BlockedUserSlot(snapshot.blockedUser)),
                bytes32(uint256(1)),
                string.concat(sym, ": V3 blocked-user entry changed")
            );

            bytes32 contextSlot = _v3UnwrapContextSlot(snapshot.pendingUnwrapId);
            assertEq(
                vm.load(proxy, contextSlot),
                bytes32(uint256(uint160(snapshot.blockedUser))),
                string.concat(sym, ": V3 unwrap context from changed")
            );
            assertEq(
                vm.load(proxy, bytes32(uint256(contextSlot) + 1)),
                bytes32(uint256(uint160(snapshot.pendingUnwrapOperator))),
                string.concat(sym, ": V3 unwrap context operator changed")
            );
        }
    }

    /// @notice A pending unwrap request seeded before the upgrade stays readable via
    /// unwrapRequester() after it, proving populated `_unwrapRequests` entries survive the swap.
    function test_PendingUnwrapSurvivesUpgrade_AllWrappers() public view {
        for (uint256 i = 0; i < wrappers.length; i++) {
            address proxy = wrappers[i];
            PreUpgradeSnapshot storage snapshot = preUpgrade[proxy];
            assertEq(
                _wrapper(proxy).unwrapRequester(snapshot.pendingUnwrapId),
                snapshot.pendingUnwrapRecipient,
                string.concat(_label(proxy), ": pending unwrap recipient lost across upgrade")
            );
        }
    }

    /// @notice V3-specific blocked-user and unwrap-context mappings remain readable through the
    /// upgraded implementation.
    function test_ConfidentialWrapperV3StorageSurvivesUpgrade_AllWrappers() public {
        for (uint256 i = 0; i < wrappers.length; i++) {
            address proxy = wrappers[i];
            PreUpgradeSnapshot storage snapshot = preUpgrade[proxy];

            assertTrue(
                _wrapper(proxy).isBlocked(snapshot.blockedUser),
                string.concat(_label(proxy), ": seeded V3 blocked user not preserved")
            );

            vm.expectRevert(abi.encodeWithSelector(ConfidentialWrapper.BlockedUser.selector, snapshot.blockedUser));
            _wrapper(proxy).finalizeUnwrap(snapshot.pendingUnwrapId, 0, "");
        }
    }

    /// @notice Neither initializer is replayable after the upgrade (proxies are at version 3).
    function test_ReinitializationBlocked_AllWrappers() public {
        address[] memory empty = new address[](0);
        for (uint256 i = 0; i < wrappers.length; i++) {
            address proxy = wrappers[i];

            vm.expectRevert(Initializable.InvalidInitialization.selector);
            _wrapper(proxy).reinitializeV3(empty, bytes4(0), false);

            vm.expectRevert(Initializable.InvalidInitialization.selector);
            _wrapper(proxy).initialize("", "", "", IERC20(address(0)), address(0), empty, bytes4(0), false);
        }
    }

    /// @notice The UUPS upgrade entrypoint stays owner-gated.
    function test_NonOwnerCannotUpgrade_AllWrappers() public {
        ConfidentialWrapper freshImpl = new ConfidentialWrapper();
        address nonOwner = makeAddr("nonOwner");
        for (uint256 i = 0; i < wrappers.length; i++) {
            address proxy = wrappers[i];
            vm.prank(nonOwner);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
            _wrapper(proxy).upgradeToAndCall(address(freshImpl), "");
        }
    }
}
