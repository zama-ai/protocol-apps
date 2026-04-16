// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC7984ERC20Wrapper} from "@openzeppelin/confidential-contracts/interfaces/IERC7984ERC20Wrapper.sol";

import {VaultBatcherConfidentialUpgradeable} from "./VaultBatcherConfidentialUpgradeable.sol";

/// @title RedeemVaultBatcherConfidentialUpgradeable
/// @notice UUPS-upgradeable variant of RedeemVaultBatcherConfidential.
contract RedeemVaultBatcherConfidentialUpgradeable is VaultBatcherConfidentialUpgradeable {
    constructor(
        IERC7984ERC20Wrapper fromToken_,
        IERC7984ERC20Wrapper toToken_,
        IERC4626 vault_
    ) VaultBatcherConfidentialUpgradeable(fromToken_, toToken_, vault_) {
        _disableInitializers();
    }

    function routeDescription() public pure override returns (string memory) {
        return "Redeem ERC4626 vault shares for underlying asset.";
    }

    function _executeVaultRoute(uint256, /* batchId */ uint256 amount) internal override returns (ExecuteOutcome) {
        uint256 rawShares = amount * fromToken().rate();
        try _vault().redeem(rawShares, address(this), address(this)) {
            return ExecuteOutcome.Complete;
        } catch {
            return ExecuteOutcome.Partial;
        }
    }

    function _currentVaultRate() internal view override returns (uint64) {
        uint256 refShares = uint256(10) ** exchangeRateDecimals() * fromToken().rate();
        uint256 predictedAssets = _vault().previewRedeem(refShares);
        return uint64(predictedAssets / toToken().rate());
    }

    function _validateRouteCompatibility(
        IERC7984ERC20Wrapper fromToken_,
        IERC7984ERC20Wrapper toToken_,
        IERC4626 vault_
    ) internal view override {
        address fromUnderlying = fromToken_.underlying();
        if (fromUnderlying != address(vault_)) {
            revert RouteShareMismatch(fromUnderlying, address(vault_));
        }

        address toUnderlying = toToken_.underlying();
        address vaultAsset = vault_.asset();
        if (toUnderlying != vaultAsset) {
            revert RouteAssetMismatch(toUnderlying, vaultAsset);
        }
    }
}
