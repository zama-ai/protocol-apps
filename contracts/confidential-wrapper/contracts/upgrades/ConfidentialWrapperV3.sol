// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {externalEuint64, euint64} from "@fhevm/solidity/lib/FHE.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ConfidentialWrapperV2} from "./ConfidentialWrapperV2.sol";

/**
 * @title ConfidentialWrapperV3
 * @notice Upgrade contract that adds an owner-controlled denylist preventing blocked addresses
 * from participating in confidential transfers, wraps, and unwraps.
 */
contract ConfidentialWrapperV3 is ConfidentialWrapperV2 {
    /// @dev to persist context of the unwrap between the unwrap and the finalizeUnwrap calls
    struct UnwrapContext {
        address from;
        address operator;
    }

    /// @custom:storage-location erc7201:fhevm_protocol.storage.ConfidentialWrapperV3
    struct ConfidentialWrapperV3Storage {
        mapping(address user => bool blocked) _blockedUsers;
        mapping(bytes32 unwrapRequestId => UnwrapContext unwrapContext) _unwrapContexts;
        bytes4 _underlyingDenyListSelector;
        bool _hasUnderlyingDenyListSelector;
    }

    // keccak256(abi.encode(uint256(keccak256("fhevm_protocol.storage.ConfidentialWrapperV3")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CONFIDENTIAL_WRAPPER_V3_STORAGE_LOCATION =
        0xfbb2c4771bcc77528b8fd58eedad6a4f84fdaf9eea4a56a2752391a0c87eee00;

    /// @dev Emitted when `user` is added to the denylist.
    event UserBlocked(address indexed user);

    /// @dev Emitted when `user` is removed from the denylist.
    event UserUnblocked(address indexed user);

    /// @dev Thrown when `user` is on the denylist and attempts a restricted operation.
    error BlockedUser(address user);

    /// @dev Thrown when attempting to block a user that is already on the denylist.
    error UserAlreadyBlocked(address user);

    /// @dev Thrown when attempting to unblock a user that is not on the denylist.
    error UserAlreadyUnblocked(address user);

    /// @dev Thrown when the underlying denylist call fails.
    error UnderlyingDenyListCallFailed();

    /// @dev Thrown when the underlying denylist call returns an invalid response.
    error InvalidUnderlyingDenyListResponse();

    /// @dev Thrown when the underlying denylist call returns a true value for the given address.
    error UnderlyingDenyListedAddress(address user);

    function _getConfidentialWrapperV3Storage() internal pure returns (ConfidentialWrapperV3Storage storage $) {
        assembly {
            $.slot := CONFIDENTIAL_WRAPPER_V3_STORAGE_LOCATION
        }
    }

    /// @dev Disabled in V3. Use {initializeV3} instead.
    /// @custom:oz-upgrades-unsafe-allow missing-initializer-call
    function initializeV2(string memory, string memory, string memory, IERC20, address) public virtual override {
        revert ConfidentialWrapperInvalidInitializerVersion();
    }

    /**
     * @notice Initializes the contract when deployed fresh at V3.
     * Advances the initializer version to 3 so reinitializers below this version cannot be replayed.
     */
    function initializeV3(
        string memory name_,
        string memory symbol_,
        string memory contractURI_,
        IERC20 underlying_,
        address owner_,
        address[] memory blockedUsers,
        bytes4 underlyingDenyListSelector,
        bool hasUnderlyingDenyListSelector_
    ) public virtual reinitializer(3) {
        __ConfidentialWrapperV3_init(
            name_,
            symbol_,
            contractURI_,
            underlying_,
            owner_,
            blockedUsers,
            underlyingDenyListSelector,
            hasUnderlyingDenyListSelector_
        );
    }

    /// @dev Chains V2 initialization with V3-specific storage initialization.
    function __ConfidentialWrapperV3_init(
        string memory name_,
        string memory symbol_,
        string memory contractURI_,
        IERC20 underlying_,
        address owner_,
        address[] memory blockedUsers,
        bytes4 underlyingDenyListSelector,
        bool hasUnderlyingDenyListSelector_
    ) internal onlyInitializing {
        __ConfidentialWrapperV2_init(name_, symbol_, contractURI_, underlying_, owner_);
        __ConfidentialWrapperV3_init_unchained(
            blockedUsers,
            underlyingDenyListSelector,
            hasUnderlyingDenyListSelector_
        );
    }

    /**
     * @dev V3-specific initialization logic. Optionally seeds the denylist with `blockedUsers`.
     * Reverts if any entry in `blockedUsers` appears more than once.
     */
    function __ConfidentialWrapperV3_init_unchained(
        address[] memory blockedUsers,
        bytes4 underlyingDenyListSelector,
        bool hasUnderlyingDenyListSelector_
    ) internal onlyInitializing {
        uint256 length = blockedUsers.length;
        for (uint256 i = 0; i < length; i++) {
            _blockUser(blockedUsers[i]);
        }
        ConfidentialWrapperV3Storage storage $ = _getConfidentialWrapperV3Storage();
        $._underlyingDenyListSelector = underlyingDenyListSelector;
        $._hasUnderlyingDenyListSelector = hasUnderlyingDenyListSelector_;
    }

    /**
     * @dev Reinitializer used when upgrading from V2. Optionally seeds the denylist with `blockedUsers`.
     * Reverts if any entry in `blockedUsers` appears more than once.
     */
    function reinitializeV3(
        address[] memory blockedUsers,
        bytes4 underlyingDenyListSelector,
        bool hasUnderlyingDenyListSelector_
    ) public virtual reinitializer(3) {
        __ConfidentialWrapperV3_init_unchained(
            blockedUsers,
            underlyingDenyListSelector,
            hasUnderlyingDenyListSelector_
        );
    }

    /// @dev Adds `user` to the denylist.
    function blockUser(address user) external virtual onlyOwner {
        _blockUser(user);
    }

    /// @dev Removes `user` from the denylist. Reverts if `user` is not currently blocked.
    function unblockUser(address user) external virtual onlyOwner {
        _unblockUser(user);
    }

    /// @dev Returns whether `user` is currently on the denylist.
    function isBlocked(address user) public view virtual returns (bool) {
        return _getConfidentialWrapperV3Storage()._blockedUsers[user];
    }

    /**
     * @dev Returns the underlying denylist configuration as a `(isSet, selector)` pair.
     * `isSet` indicates whether an underlying denylist check is enabled, and `selector`
     * is the 4-byte function selector to call on {underlying} when it is set.
     */
    function getUnderlyingDenyListSelector() public view virtual returns (bool isSet, bytes4 selector) {
        ConfidentialWrapperV3Storage storage $ = _getConfidentialWrapperV3Storage();
        return ($._hasUnderlyingDenyListSelector, $._underlyingDenyListSelector);
    }

    function _blockUser(address user) internal virtual {
        ConfidentialWrapperV3Storage storage $ = _getConfidentialWrapperV3Storage();
        require(!$._blockedUsers[user], UserAlreadyBlocked(user));
        $._blockedUsers[user] = true;
        emit UserBlocked(user);
    }

    function _unblockUser(address user) internal virtual {
        ConfidentialWrapperV3Storage storage $ = _getConfidentialWrapperV3Storage();
        require($._blockedUsers[user], UserAlreadyUnblocked(user));
        $._blockedUsers[user] = false;
        emit UserUnblocked(user);
    }

    function _requireNotBlocked(address user) internal view {
        // to not block mints and burns, also needed because for e.g. USDT.getBlackListStatus(address(0))
        if (user == address(0)) return;
        require(!isBlocked(user), BlockedUser(user));
        ConfidentialWrapperV3Storage storage $ = _getConfidentialWrapperV3Storage();
        if ($._hasUnderlyingDenyListSelector) {
            (bool success, bytes memory data) = underlying().staticcall(
                abi.encodeWithSelector($._underlyingDenyListSelector, user)
            );
            if (!success) revert UnderlyingDenyListCallFailed();
            if (data.length != 32) revert InvalidUnderlyingDenyListResponse();
            bool value = abi.decode(data, (bool));
            if (value == true) revert UnderlyingDenyListedAddress(user);
        }
    }

    // ----- Overrides enforcing the denylist -----

    /// @dev Catches confidential transfers (both parties), the wrap recipient (mint side), and the unwrap holder (burn side).
    function _update(address from, address to, euint64 amount) internal virtual override returns (euint64) {
        // to block operators in case of confidentialTransferFrom(AndCall)
        if (msg.sender != from) _requireNotBlocked(msg.sender);
        _requireNotBlocked(from);
        _requireNotBlocked(to);
        return super._update(from, to, amount);
    }

    /// @dev Catches a blocked depositor on the direct {wrap} path; the recipient is covered via {_update}.
    function wrap(address to, uint256 amount) public virtual override returns (euint64) {
        // needed because _update is not aware of msg.sender, because it's doing a _mint, i.e from is null address
        _requireNotBlocked(msg.sender);
        return super.wrap(to, amount);
    }

    /// @dev Catches a blocked depositor on the ERC-1363 callback path; the recipient is covered via {_update}.
    function onTransferReceived(
        address operator,
        address from,
        uint256 amount,
        bytes calldata data
    ) public virtual override returns (bytes4) {
        // needed because _update is not aware of from nor operator, because it's doing a _mint, i.e from is null address
        _requireNotBlocked(from);
        if (operator != from) _requireNotBlocked(operator);
        return super.onTransferReceived(operator, from, amount, data);
    }

    /// @dev Internal logic for handling the creation of unwrap requests. Returns the unwrap request id.
    function _unwrap(address from, address to, euint64 amount) internal virtual override returns (bytes32) {
        // needed because _update is not aware of to, because it's doing a _burn, i.e to is null address
        _requireNotBlocked(to);
        ConfidentialWrapperV3Storage storage $ = _getConfidentialWrapperV3Storage();
        bytes32 unwrapRequestId = super._unwrap(from, to, amount);
        $._unwrapContexts[unwrapRequestId] = UnwrapContext(from, msg.sender);
        return unwrapRequestId;
    }

    /**
     * @dev Prevents settlement of the underlying transfer to a recipient that became
     * blocked between {unwrap} and {finalizeUnwrap}.
     */
    function finalizeUnwrap(
        bytes32 unwrapRequestId,
        uint64 unwrapAmountCleartext,
        bytes calldata decryptionProof
    ) public virtual override {
        // needed because _update is no longer called in finalizeUnwrap, because cTokens were already burnt in unwrap
        _requireNotBlocked(unwrapRequester(unwrapRequestId));
        // also check both original holder and operator from the corresponding unwrap call
        ConfidentialWrapperV3Storage storage $ = _getConfidentialWrapperV3Storage();
        UnwrapContext memory unwrapContext = $._unwrapContexts[unwrapRequestId];
        _requireNotBlocked(unwrapContext.from);
        if (unwrapContext.from != unwrapContext.operator) {
            _requireNotBlocked(unwrapContext.operator);
        }
        delete $._unwrapContexts[unwrapRequestId];
        super.finalizeUnwrap(unwrapRequestId, unwrapAmountCleartext, decryptionProof);
    }
}
