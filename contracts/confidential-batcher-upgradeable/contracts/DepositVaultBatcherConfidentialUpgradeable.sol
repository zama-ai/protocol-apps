// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC7984ERC20Wrapper} from "@openzeppelin/confidential-contracts/interfaces/IERC7984ERC20Wrapper.sol";

import {VaultBatcherConfidentialUpgradeable} from "./VaultBatcherConfidentialUpgradeable.sol";

/// @title DepositVaultBatcherConfidentialUpgradeable
/// @notice UUPS-upgradeable variant of DepositVaultBatcherConfidential.
contract DepositVaultBatcherConfidentialUpgradeable is VaultBatcherConfidentialUpgradeable {
    constructor(
        IERC7984ERC20Wrapper fromToken_,
        IERC7984ERC20Wrapper toToken_,
        IERC4626 vault_
    ) VaultBatcherConfidentialUpgradeable(fromToken_, toToken_, vault_) {
        _disableInitializers();
    }

    function routeDescription() public pure override returns (string memory) {
        return "Deposit underlying asset into ERC4626 vault and receive vault shares.";
    }

    function _executeVaultRoute(uint256, /* batchId */ uint256 amount) internal override returns (ExecuteOutcome) {
        uint256 underlyingAmount = amount * fromToken().rate();
        SafeERC20.safeIncreaseAllowance(IERC20(fromToken().underlying()), address(_vault()), underlyingAmount);
        try _vault().deposit(underlyingAmount, address(this)) {
            return ExecuteOutcome.Complete;
        } catch {
            SafeERC20.safeDecreaseAllowance(IERC20(fromToken().underlying()), address(_vault()), underlyingAmount);
            return ExecuteOutcome.Partial;
        }
    }

    function _currentVaultRate() internal view override returns (uint64) {
        uint256 refUnderlying = uint256(10) ** exchangeRateDecimals() * fromToken().rate();
        uint256 predictedShares = _vault().previewDeposit(refUnderlying);
        return uint64(predictedShares / toToken().rate());
    }

    function _validateRouteCompatibility(
        IERC7984ERC20Wrapper fromToken_,
        IERC7984ERC20Wrapper toToken_,
        IERC4626 vault_
    ) internal view override {
        address fromUnderlying = fromToken_.underlying();
        address vaultAsset = vault_.asset();
        if (fromUnderlying != vaultAsset) {
            revert RouteAssetMismatch(fromUnderlying, vaultAsset);
        }

        address toUnderlying = toToken_.underlying();
        if (toUnderlying != address(vault_)) {
            revert RouteShareMismatch(toUnderlying, address(vault_));
        }
    }
}
