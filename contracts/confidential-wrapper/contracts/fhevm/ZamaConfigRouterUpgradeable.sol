// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {FHE} from "@fhevm/solidity/lib/FHE.sol";
import {CoprocessorConfig} from "@fhevm/solidity/lib/Impl.sol";
import {ZamaConfig} from "./ZamaConfig.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title   ZamaConfigRouterUpgradeable.
 * @dev     Upgradeable counterpart of the `ZamaEthereumConfig` and `ZamaPolygonConfig` contracts
 *          declared in {ZamaConfig}. Those pick a chain family at compile time through inheritance,
 *          which a single implementation deployed to every supported network cannot do, so the
 *          coprocessor config is routed by `block.chainid` at initialization time instead.
 */
abstract contract ZamaConfigRouterUpgradeable is Initializable {
    function __ZamaConfigRouter_init() internal onlyInitializing {
        __ZamaConfigRouter_init_unchained();
    }

    function __ZamaConfigRouter_init_unchained() internal onlyInitializing {
        FHE.setCoprocessor(_getCoprocessorConfig());
    }

    function confidentialProtocolId() public view returns (uint256) {
        return ZamaConfig.getConfidentialProtocolId();
    }

    /**
     * @dev Routes to the coprocessor config of the chain family the current chain belongs to.
     *      Supported chains are enumerated here rather than left to the routed getter, so that an
     *      unsupported chain reverts with `ZamaProtocolUnsupported` instead of failing inside
     *      whichever family happened to be the fallback. Keep in sync with {ZamaConfig}.
     */
    function _getCoprocessorConfig() private view returns (CoprocessorConfig memory config) {
        if (block.chainid == 1 || block.chainid == 11155111 || block.chainid == 31337) {
            config = ZamaConfig.getEthereumCoprocessorConfig();
        } else if (block.chainid == 80002) {
            config = ZamaConfig.getPolygonCoprocessorConfig();
        } else {
            revert ZamaConfig.ZamaProtocolUnsupported();
        }
    }
}
