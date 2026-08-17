// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {FHE, euint64} from "@fhevm/solidity/lib/FHE.sol";
import {IERC1363Receiver} from "@openzeppelin/contracts/interfaces/IERC1363Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ConfidentialWrapper} from "confidential-wrapper/ConfidentialWrapper.sol";

/**
 * @title ConfidentialWrapperTreasury
 * @notice Wrapper whose underlying reserve lives at a dedicated treasury account.
 * @dev Proof of concept under this package's `src/`, not a shipping implementation.
 *
 * Overrides the reserve hooks so wrap, unwrap, and inferredTotalSupply keep their base bodies.
 * `onTransferReceived` is copied: the ERC-1363 path must forward to the treasury before minting.
 */
contract ConfidentialWrapperTreasury is ConfidentialWrapper {
    /// @custom:storage-location erc7201:fhevm_protocol.storage.ConfidentialWrapperTreasury
    struct ConfidentialWrapperTreasuryStorage {
        address _treasury;
    }

    // keccak256(abi.encode(uint256(keccak256("fhevm_protocol.storage.ConfidentialWrapperTreasury")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CONFIDENTIAL_WRAPPER_TREASURY_STORAGE_LOCATION =
        0x009893c69930911c5c4fab52a062825f3f438f092098b143e26e23cc4b4ff700;

    /// @dev Matches `ConfidentialWrapper.REINITIALIZER_VERSION`. Live proxies are still on 3.
    uint64 private constant TREASURY_REINITIALIZER_VERSION = 4;

    /// @dev Emitted when the treasury account is set. Only {reinitializeV4WithTreasury} can emit it.
    event TreasuryUpdated(address indexed treasury);

    /// @dev Emitted with the reserve balance moved out of the wrapper during the migration.
    event ReserveMigrated(address indexed treasury, uint256 amount);

    /// @dev Thrown when the treasury is unset, or would be set to the zero address.
    error InvalidTreasury();

    /// @dev Thrown by the inherited one-argument {reinitializeV4}, which this implementation tombstones.
    error V4InitializerRequiresTreasury();

    function _getConfidentialWrapperTreasuryStorage()
        internal
        pure
        returns (ConfidentialWrapperTreasuryStorage storage $)
    {
        assembly {
            $.slot := CONFIDENTIAL_WRAPPER_TREASURY_STORAGE_LOCATION
        }
    }

    /**
     * @notice Upgrades a V3 proxy to V4, sets the treasury, and moves the existing reserve there.
     * @dev Assignment and transfer share a transaction so {inferredTotalSupply} never reads an empty
     * treasury while the reserve is still here. Does not grant the settlement allowance.
     *
     * Named rather than overloaded on `reinitializeV4` so `abi.encodeCall` can name it.
     */
    /// @custom:oz-upgrades-unsafe-allow missing-initializer-call
    /// @custom:oz-upgrades-validate-as-initializer
    function reinitializeV4WithTreasury(address[] memory initialObservers, address treasury_)
        public
        virtual
        onlyOwner
        reinitializer(TREASURY_REINITIALIZER_VERSION)
    {
        require(treasury_ != address(0), InvalidTreasury());

        __ConfidentialWrapperV4_init(initialObservers);
        __Pausable_init();

        _getConfidentialWrapperTreasuryStorage()._treasury = treasury_;
        emit TreasuryUpdated(treasury_);

        IERC20 token = IERC20(underlying());
        uint256 balance = token.balanceOf(address(this));
        if (balance > 0) SafeERC20.safeTransfer(token, treasury_, balance);
        emit ReserveMigrated(treasury_, balance);
    }

    /**
     * @inheritdoc ConfidentialWrapper
     * @dev Tombstoned. Both initializers consume version 4; this one would leave the wrapper with no treasury.
     * Use {reinitializeV4WithTreasury}.
     */
    function reinitializeV4(address[] memory) public virtual override {
        revert V4InitializerRequiresTreasury();
    }

    // ----- Reserve visibility -----

    /// @notice The account that holds the reserve. `address(0)` until {reinitializeV4WithTreasury} has run.
    function treasury() public view virtual returns (address) {
        return _getConfidentialWrapperTreasuryStorage()._treasury;
    }

    /// @notice The underlying balance held by the treasury account.
    /// @dev Zero before migration (`_reserve` is then `address(0)`). Views do not revert; token paths fail closed.
    function treasuryBalance() public view virtual returns (uint256) {
        return _reserveBalance();
    }

    // ----- Reserve hooks -----

    /// @dev `inferredTotalSupply` now reads the treasury. Does not revert while unset (view path).
    function _reserve() internal view virtual override returns (address) {
        return treasury();
    }

    /// @dev Same transfer as the base, landing at the treasury.
    function _depositUnderlyingFrom(address from, uint256 amount) internal virtual override {
        SafeERC20.safeTransferFrom(IERC20(underlying()), from, _requireTreasury(), amount);
    }

    /// @dev Spends the standing allowance after the base deny-list and signature checks.
    function _payUnderlying(address to, uint256 amount) internal virtual override {
        SafeERC20.safeTransferFrom(IERC20(underlying()), _requireTreasury(), to, amount);
    }

    // ----- ERC-1363 path -----

    /**
     * @inheritdoc ConfidentialWrapper
     * @dev Copied from the base because the remainder must reach the treasury before minting.
     * The ERC-1363 callback already delivered tokens here, so this path costs one extra transfer.
     */
    function onTransferReceived(address operator, address from, uint256 amount, bytes calldata data)
        public
        virtual
        override
        returns (bytes4)
    {
        address treasury_ = _requireTreasury();
        require(underlying() == msg.sender, ERC7984UnauthorizedCaller(msg.sender));
        _requireNotBlocked(from);
        if (operator != from) _requireNotBlocked(operator);

        uint256 excess = amount % rate();
        if (excess > 0) SafeERC20.safeTransfer(IERC20(underlying()), from, excess);
        SafeERC20.safeTransfer(IERC20(underlying()), treasury_, amount - excess);

        address to = data.length < 20 ? from : address(bytes20(data));
        euint64 encryptedWrappedAmount = _mint(to, FHE.asEuint64(SafeCast.toUint64(amount / rate())));

        emit Wrap(to, amount - excess, encryptedWrappedAmount);

        return IERC1363Receiver.onTransferReceived.selector;
    }

    /// @dev Token-moving paths fail closed if the treasury is unset.
    function _requireTreasury() internal view returns (address treasury_) {
        treasury_ = treasury();
        require(treasury_ != address(0), InvalidTreasury());
    }
}
