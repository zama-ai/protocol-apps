// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import {ZamaEthereumConfig, ZamaConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {FHE, euint64} from "@fhevm/solidity/lib/FHE.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC7984ERC20Wrapper} from "@openzeppelin/confidential-contracts/interfaces/IERC7984ERC20Wrapper.sol";

import {BatcherConfidentialUpgradeable} from "./vendor/BatcherConfidentialUpgradeable.sol";
import {IVaultBatcherConfidential} from "./interfaces/IVaultBatcherConfidential.sol";

/// @dev Minimal interface to detect VaultV2's time-based management fee without importing the full dependency.
/// Used by the fee-aware slippage check to adjust tolerance for fee-driven rate degradation.
interface IManagementFeeVault {
    function managementFee() external view returns (uint96);
}

/// @title VaultBatcherConfidentialUpgradeable
/// @notice UUPS-upgradeable variant of VaultBatcherConfidential.
/// @dev Immutables (fromToken, toToken, vault) are set in the implementation constructor.
///      Storage (minBatchAge, retryWindow, ownership) is set via `initialize()` on the proxy.
abstract contract VaultBatcherConfidentialUpgradeable is
    IVaultBatcherConfidential,
    ZamaEthereumConfig,
    OwnableUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    BatcherConfidentialUpgradeable
{
    IERC4626 private immutable _VAULT;

    uint256 private _minBatchAge;
    uint256 private _retryWindow;
    uint16 private _maxSlippageBps;

    mapping(uint256 batchId => uint64 pinnedRate) private _batchPinnedRate;
    mapping(uint256 batchId => uint16 maxSlippageBps) private _batchMaxSlippageBps;
    mapping(uint256 batchId => uint256 timestamp) private _batchCreatedAt;
    mapping(uint256 batchId => uint256 timestamp) private _batchDispatchedAt;

    /// @notice Constructor: stores immutables only. Call `initialize()` on the proxy.
    constructor(
        IERC7984ERC20Wrapper fromToken_,
        IERC7984ERC20Wrapper toToken_,
        IERC4626 vault_
    ) BatcherConfidentialUpgradeable(fromToken_, toToken_) {
        _VAULT = vault_;
    }

    /// @notice Initializes proxy storage: ownership, policy parameters, approvals, and first batch.
    function initialize(
        address owner_,
        uint256 minBatchAge_,
        uint256 retryWindow_
    ) public initializer {
        // Re-apply the FHE coprocessor config in the proxy's storage context.
        // ZamaEthereumConfig's constructor sets these in the implementation's storage, but the proxy
        // uses its own storage for the namespaced FHE slot, so we must initialize it here too.
        FHE.setCoprocessor(ZamaConfig.getEthereumCoprocessorConfig());
        __BatcherConfidential_init();
        __Ownable_init(owner_);
        __Pausable_init();

        _validateRouteCompatibility(fromToken(), toToken(), _VAULT);
        require(fromToken().rate() > 0, InvalidTokenRate());
        require(toToken().rate() > 0, InvalidTokenRate());

        _minBatchAge = minBatchAge_;
        _retryWindow = retryWindow_;

        _initializeApprovals(fromToken(), toToken(), _VAULT);
        _initializeCurrentBatch();
    }

    /// @dev Only the owner can authorize UUPS upgrades.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    function vault() external view returns (IERC4626) {
        return _VAULT;
    }

    function minBatchAge() external view returns (uint256) {
        return _minBatchAge;
    }

    function retryWindow() external view returns (uint256) {
        return _retryWindow;
    }

    function maxSlippageBps() external view returns (uint16) {
        return _maxSlippageBps;
    }

    function batchCreatedAt(uint256 batchId) external view returns (uint256) {
        return _batchCreatedAt[batchId];
    }

    function batchDispatchedAt(uint256 batchId) external view returns (uint256) {
        return _batchDispatchedAt[batchId];
    }

    function batchPinnedRate(uint256 batchId) external view returns (uint64) {
        return _batchPinnedRate[batchId];
    }

    function batchMaxSlippageBps(uint256 batchId) external view returns (uint16) {
        return _batchMaxSlippageBps[batchId];
    }

    function setMinBatchAge(uint256 minBatchAge_) external onlyOwner {
        _minBatchAge = minBatchAge_;
        emit MinBatchAgeSet(minBatchAge_);
    }

    function setRetryWindow(uint256 retryWindow_) external onlyOwner {
        _retryWindow = retryWindow_;
        emit RetryWindowSet(retryWindow_);
    }

    function setMaxSlippageBps(uint16 maxSlippageBps_) external onlyOwner {
        require(maxSlippageBps_ <= 10_000, InvalidMaxSlippageBps());
        _maxSlippageBps = maxSlippageBps_;
        emit MaxSlippageBpsSet(maxSlippageBps_);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function dispatchBatch() public virtual override whenNotPaused {
        uint256 batchId = currentBatchId();
        uint256 elapsed = block.timestamp - _batchCreatedAt[batchId];

        require(elapsed >= _minBatchAge, BatchTooYoung(batchId, elapsed, _minBatchAge));

        _batchPinnedRate[batchId] = _currentVaultRate();

        super.dispatchBatch();
        _batchDispatchedAt[batchId] = block.timestamp;
        _initializeCurrentBatch();
    }

    function dispatchBatchCallback(uint256 batchId, uint64 unwrapAmountCleartext, bytes calldata decryptionProof)
        public
        virtual
        override
    {
        super.dispatchBatchCallback(batchId, unwrapAmountCleartext, decryptionProof);

        uint16 frozenMaxSlippageBps = _batchMaxSlippageBps[batchId];
        if (frozenMaxSlippageBps != 0 && batchState(batchId) == BatchState.Finalized) {
            uint64 pinned = _batchPinnedRate[batchId];
            uint256 effectiveSlippageBps = uint256(frozenMaxSlippageBps) + _expectedFeeImpactBps(batchId);
            if (effectiveSlippageBps > 10_000) {
                emit SlippageToleranceCapped(batchId, effectiveSlippageBps);
                effectiveSlippageBps = 10_000;
            }
            uint64 minimum = uint64(uint256(pinned) * (10_000 - effectiveSlippageBps) / 10_000);
            uint64 actualRate = exchangeRate(batchId);
            require(actualRate >= minimum, SlippageExceeded(batchId, actualRate, minimum));
        }
    }

    function _join(address to, euint64 amount) internal virtual override whenNotPaused returns (euint64) {
        return super._join(to, amount);
    }

    function _validateRouteCompatibility(
        IERC7984ERC20Wrapper fromToken_,
        IERC7984ERC20Wrapper toToken_,
        IERC4626 vault_
    ) internal view virtual;

    function _initializeApprovals(IERC7984ERC20Wrapper fromToken_, IERC7984ERC20Wrapper toToken_, IERC4626 vault_)
        internal
        virtual
    {}

    function _executeRoute(uint256 batchId, uint256 amount) internal virtual override returns (ExecuteOutcome) {
        if (paused()) return ExecuteOutcome.Cancel;
        ExecuteOutcome outcome = _executeVaultRoute(batchId, amount);
        if (outcome == ExecuteOutcome.Complete) return outcome;
        if (block.timestamp >= _batchDispatchedAt[batchId] + _retryWindow) return ExecuteOutcome.Cancel;
        return outcome;
    }

    function _executeVaultRoute(uint256 batchId, uint256 amount) internal virtual returns (ExecuteOutcome);

    function _currentVaultRate() internal view virtual returns (uint64);

    function _vault() internal view returns (IERC4626) {
        return _VAULT;
    }

    function _initializeCurrentBatch() internal {
        uint256 batchId = currentBatchId();
        _batchCreatedAt[batchId] = block.timestamp;
        _batchMaxSlippageBps[batchId] = _maxSlippageBps;
        _afterInitializeCurrentBatch(batchId);
    }

    function _afterInitializeCurrentBatch(uint256 _batchId) internal virtual {}

    function _expectedFeeImpactBps(uint256 batchId) internal view virtual returns (uint256) {
        try IManagementFeeVault(address(_VAULT)).managementFee() returns (uint96 fee) {
            uint256 elapsed = block.timestamp - _batchDispatchedAt[batchId];
            return (uint256(fee) * elapsed * 10_000) / 1e18;
        } catch {
            return 0;
        }
    }

    /// @dev Reserves storage slots for future base contract upgrades.
    uint256[43] private __gap;
}
