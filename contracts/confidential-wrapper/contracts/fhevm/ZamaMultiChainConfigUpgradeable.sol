// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {FHE} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaConfig} from "./ZamaConfig.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title   ZamaMultiChainConfigUpgradeable.
 * @dev     Upgradeable counterpart of {ZamaMultiChainConfig}. The non-upgradeable base sets the
 *          coprocessor in its constructor via `ZamaConfig.getCoprocessorConfig()`; this contract
 *          does the same at initialization time so a single implementation can be deployed on
 *          every supported network.
 */
abstract contract ZamaMultiChainConfigUpgradeable is Initializable {
    function __ZamaMultiChainConfig_init() internal onlyInitializing {
        __ZamaMultiChainConfig_init_unchained();
    }

    function __ZamaMultiChainConfig_init_unchained() internal onlyInitializing {
        FHE.setCoprocessor(ZamaConfig.getCoprocessorConfig());
    }

    function confidentialProtocolId() public view returns (uint256) {
        return ZamaConfig.getConfidentialProtocolId();
    }
}
