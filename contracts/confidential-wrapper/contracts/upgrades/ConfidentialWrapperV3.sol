// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {externalEuint64, euint64} from "@fhevm/solidity/lib/FHE.sol";
import {ConfidentialWrapperV2} from "./ConfidentialWrapperV2.sol";

/**
 * @title ConfidentialWrapperV3
 * @notice Upgrade contract that adds an owner-controlled denylist preventing blocked addresses
 * from participating in confidential transfers, wraps, and unwraps.
 */
contract ConfidentialWrapperV3 is ConfidentialWrapperV2 {
    /// @custom:storage-location erc7201:fhevm_protocol.storage.ConfidentialWrapperV3
    struct ConfidentialWrapperV3Storage {
        mapping(address user => bool blocked) _blockedUsers;
        address _blacklistSource;
        bytes4 _blacklistSelector;
    }

    // keccak256(abi.encode(uint256(keccak256("fhevm_protocol.storage.ConfidentialWrapperV3")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CONFIDENTIAL_WRAPPER_V3_STORAGE_LOCATION =
        0xfbb2c4771bcc77528b8fd58eedad6a4f84fdaf9eea4a56a2752391a0c87eee00;

    /// @dev Emitted when `user` is added to the denylist.
    event UserBlocked(address indexed user);

    /// @dev Emitted when `user` is removed from the denylist.
    event UserUnblocked(address indexed user);

    event BlacklistSourceUpdated(address indexed previousSource, address indexed newSource);
    event BlacklistSelectorUpdated(bytes4 previousSelector, bytes4 newSelector);

    /// @dev Thrown when `user` is on the denylist and attempts a restricted operation.
    error BlockedUser(address user);

    /// @dev Thrown when attempting to add {address(0)} to the denylist.
    error CannotBlockNullAddress();

    /// @dev Thrown when attempting to block a user that is already on the denylist.
    error UserAlreadyBlocked(address user);

    /// @dev Thrown when attempting to unblock a user that is not on the denylist.
    error UserAlreadyUnblocked(address user);

    error TokenBlacklistedAddress(address account);
    error BlacklistSourceCallFailed(address source);
    error InvalidBlacklistSourceResponse(address source);

    function _getConfidentialWrapperV3Storage() internal pure returns (ConfidentialWrapperV3Storage storage $) {
        assembly {
            $.slot := CONFIDENTIAL_WRAPPER_V3_STORAGE_LOCATION
        }
    }

    /**
     * @dev Reinitializer used when upgrading from V2. Optionally seeds the denylist with `blockedUsers`.
     * Reverts if any entry in `blockedUsers` is {address(0)} or appears more than once.
     */
    /// @custom:oz-upgrades-validate-as-initializer
    function reinitializeV3(
        address[] memory blockedUsers,
        address blacklistSource_,
        bytes4 blacklistSelector_
    ) public virtual reinitializer(3) {
        uint256 length = blockedUsers.length;
        for (uint256 i = 0; i < length; i++) {
            _blockUser(blockedUsers[i]);
        }
        _setBlacklistSource(blacklistSource_);
        _setBlacklistSelector(blacklistSelector_);
    }

    /// @dev Adds `user` to the denylist. Reverts if `user` is {address(0)} or already blocked.
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

    function setBlacklistSource(address newSource) external onlyOwner {
        _setBlacklistSource(newSource);
    }

    function setBlacklistSelector(bytes4 newSelector) external onlyOwner {
        _setBlacklistSelector(newSelector);
    }

    function blacklistSource() public view returns (address) {
        return _getConfidentialWrapperV3Storage()._blacklistSource;
    }

    function blacklistSelector() public view returns (bytes4) {
        return _getConfidentialWrapperV3Storage()._blacklistSelector;
    }

    function _blockUser(address user) internal virtual {
        require(user != address(0), CannotBlockNullAddress());
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
        require(!isBlocked(user), BlockedUser(user));
    }

    function _setBlacklistSource(address source) internal {
        address previous = _getConfidentialWrapperV3Storage()._blacklistSource;
        _getConfidentialWrapperV3Storage()._blacklistSource = source;
        emit BlacklistSourceUpdated(previous, source);
    }

    function _setBlacklistSelector(bytes4 selector) internal {
        bytes4 previous = _getConfidentialWrapperV3Storage()._blacklistSelector;
        _getConfidentialWrapperV3Storage()._blacklistSelector = selector;
        emit BlacklistSelectorUpdated(previous, selector);
    }

    function _requireNotTokenBlacklisted(address account) internal view {
        ConfidentialWrapperV3Storage storage $ = _getConfidentialWrapperV3Storage();
        address source = $._blacklistSource;
        if (source == address(0)) return;
        bytes4 selector = $._blacklistSelector;
        if (selector == bytes4(0)) return;

        (bool success, bytes memory data) = source.staticcall(abi.encodePacked(selector, abi.encode(account)));
        if (!success) revert BlacklistSourceCallFailed(source);
        if (data.length != 32) revert InvalidBlacklistSourceResponse(source);
        uint256 value = abi.decode(data, (uint256));
        if (value > 1) revert InvalidBlacklistSourceResponse(source);
        if (value == 1) revert TokenBlacklistedAddress(account);
    }

    // ----- Overrides enforcing the denylist -----

    /// @dev Catches confidential transfers (both parties), the wrap recipient (mint side), and the unwrap holder (burn side).
    function _update(address from, address to, euint64 amount) internal virtual override returns (euint64) {
        // to block operators in case of confidentialTransferFrom(AndCall)
        if (msg.sender != from) {
            _requireNotBlocked(msg.sender);
            _requireNotTokenBlacklisted(msg.sender);
        }
        _requireNotBlocked(from);
        _requireNotTokenBlacklisted(from);
        _requireNotBlocked(to);
        _requireNotTokenBlacklisted(to);
        return super._update(from, to, amount);
    }

    /// @dev Catches a blocked depositor on the direct {wrap} path; the recipient is covered via {_update}.
    function wrap(address to, uint256 amount) public virtual override returns (euint64) {
        // needed because _update is not aware of msg.sender, because it's doing a _mint, i.e from is null address
        _requireNotBlocked(msg.sender);
        _requireNotTokenBlacklisted(msg.sender);
        return super.wrap(to, amount);
    }

    /// @dev Catches a blocked depositor on the ERC-1363 callback path; the recipient is covered via {_update}.
    function onTransferReceived(
        address operator,
        address from,
        uint256 amount,
        bytes calldata data
    ) public virtual override returns (bytes4) {
        // needed because _update is not aware of from, because it's doing a _mint, i.e from is null address
        _requireNotBlocked(from);
        _requireNotTokenBlacklisted(from);
        return super.onTransferReceived(operator, from, amount, data);
    }

    /// @dev Catches a blocked recipient of the underlying token; the holder `from` is covered via {_update}.
    function unwrap(address from, address to, euint64 amount) public virtual override returns (bytes32) {
        // to block operators in case of unwrap
        if (msg.sender != from) {
            _requireNotBlocked(msg.sender);
            _requireNotTokenBlacklisted(msg.sender);
        }
        _requireNotBlocked(to);
        _requireNotTokenBlacklisted(to);
        return super.unwrap(from, to, amount);
    }

    /// @dev Input-proof variant of {unwrap}; same denylist enforcement as the other overload.
    function unwrap(
        address from,
        address to,
        externalEuint64 encryptedAmount,
        bytes calldata inputProof
    ) public virtual override returns (bytes32) {
        // to block operators in case of unwrap
        if (msg.sender != from) {
            _requireNotBlocked(msg.sender);
            _requireNotTokenBlacklisted(msg.sender);
        }
        // needed because _update is not aware of to, because it's doing a _burn, i.e to is null address
        _requireNotBlocked(to);
        _requireNotTokenBlacklisted(to);
        return super.unwrap(from, to, encryptedAmount, inputProof);
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
        address requester = unwrapRequester(unwrapRequestId);
        _requireNotBlocked(requester);
        _requireNotTokenBlacklisted(requester);
        super.finalizeUnwrap(unwrapRequestId, unwrapAmountCleartext, decryptionProof);
    }
}
