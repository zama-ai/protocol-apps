// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {ZamaConfig} from "confidential-wrapper/fhevm/ZamaConfig.sol";
import {ZamaConfigRouterUpgradeable} from "confidential-wrapper/fhevm/ZamaConfigRouterUpgradeable.sol";

/// @dev Minimal concrete contract exposing the initializer under test.
contract ZamaConfigRouterHarness is ZamaConfigRouterUpgradeable {
    function initialize() external initializer {
        __ZamaConfigRouter_init();
    }
}

/**
 * @title ZamaConfigRoutingTest
 * @notice Covers the `block.chainid` routing in {ZamaConfigRouterUpgradeable}.
 *
 * @dev A single implementation is deployed to every supported network, so the coprocessor config
 * is chosen at initialization time rather than by inheriting a chain-family base contract. The
 * hardhat suite always runs on chainId 31337, so this is the only coverage of the non-local
 * branches. No fork is needed: `FHE.setCoprocessor` only writes storage.
 */
contract ZamaConfigRoutingTest is Test {
    /// @dev CoprocessorConfig ERC-7201 base in the harness (acl, coprocessor, kmsVerifier at +0/+1/+2).
    bytes32 internal constant FHEVM_CONFIG_BASE = 0x9e7b61f58c47dc699ac88507c4f5bb9f121c03808c5676a8078fe583e4649700;

    function test_RoutesEthereumMainnetToEthereumConfig() public {
        ZamaConfigRouterHarness harness = _initializeOnChain(1);

        _assertConfig(
            harness,
            0xcA2E8f1F656CD25C01F05d0b243Ab1ecd4a8ffb6,
            0xD82385dADa1ae3E969447f20A3164F6213100e75,
            0x77627828a55156b04Ac0DC0eb30467f1a552BB03
        );
        assertEq(harness.confidentialProtocolId(), 1, "protocolId");
    }

    function test_RoutesSepoliaToSepoliaConfig() public {
        ZamaConfigRouterHarness harness = _initializeOnChain(11155111);

        _assertConfig(
            harness,
            0xf0Ffdc93b7E186bC2f8CB3dAA75D86d1930A433D,
            0x92C920834Ec8941d2C77D188936E1f7A6f49c127,
            0xbE0E383937d564D7FF0BC3b46c51f0bF8d5C311A
        );
        assertEq(harness.confidentialProtocolId(), 10001, "protocolId");
    }

    function test_RoutesPolygonAmoyToPolygonConfig() public {
        ZamaConfigRouterHarness harness = _initializeOnChain(80002);

        _assertConfig(
            harness,
            0xD99Cb9Fc3c42c87f2A4A12e8Fd60318d6bDdf985,
            0x89420269f61e4db00545cd99da0aEcA7fF0912f9,
            0xCD1D89E311bce4C8DEa9a0857a0c9A4E153D4041
        );
        assertEq(harness.confidentialProtocolId(), 10001, "protocolId");
    }

    function test_RoutesLocalToLocalConfig() public {
        ZamaConfigRouterHarness harness = _initializeOnChain(31337);

        // The KMSVerifier address differs from the one shipped in @fhevm/solidity: it matches what
        // the hardhat plugin mock environment deploys for this package. See {ZamaConfig}.
        _assertConfig(
            harness,
            0x50157CFfD6bBFA2DECe204a89ec419c23ef5755D,
            0xe3a9105a3a932253A70F126eb1E3b589C643dD24,
            0xbE0E383937d564D7FF0BC3b46c51f0bF8d5C311A
        );
        assertEq(harness.confidentialProtocolId(), type(uint256).max, "protocolId");
    }

    function test_RevertWhen_ChainIsUnsupported() public {
        vm.chainId(137);
        ZamaConfigRouterHarness harness = new ZamaConfigRouterHarness();

        vm.expectRevert(ZamaConfig.ZamaProtocolUnsupported.selector);
        harness.initialize();
    }

    function _initializeOnChain(uint256 chainId) internal returns (ZamaConfigRouterHarness harness) {
        vm.chainId(chainId);
        harness = new ZamaConfigRouterHarness();
        harness.initialize();
    }

    function _assertConfig(
        ZamaConfigRouterHarness harness,
        address expectedACL,
        address expectedCoprocessor,
        address expectedKMSVerifier
    ) internal view {
        assertEq(_readConfigAddress(harness, 0), expectedACL, "ACLAddress");
        assertEq(_readConfigAddress(harness, 1), expectedCoprocessor, "CoprocessorAddress");
        assertEq(_readConfigAddress(harness, 2), expectedKMSVerifier, "KMSVerifierAddress");
    }

    function _readConfigAddress(ZamaConfigRouterHarness harness, uint256 offset) internal view returns (address) {
        bytes32 slot = bytes32(uint256(FHEVM_CONFIG_BASE) + offset);
        return address(uint160(uint256(vm.load(address(harness), slot))));
    }
}
