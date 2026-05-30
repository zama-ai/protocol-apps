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

    /// @dev Thrown when attempting to add {address(0)} to the denylist.
    error CannotBlockNullAddress();

    /// @dev Thrown when attempting to block a user that is already on the denylist.
    error UserAlreadyBlocked(address user);

    /// @dev Thrown when attempting to unblock a user that is not on the denylist.
    error UserAlreadyUnblocked(address user);

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
    function reinitializeV3(address[] memory blockedUsers) public virtual reinitializer(3) {
        uint256 length = blockedUsers.length;
        for (uint256 i = 0; i < length; i++) {
            _blockUser(blockedUsers[i]);
        }
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
        // needed because _update is not aware of from, because it's doing a _mint, i.e from is null address
        _requireNotBlocked(from);
        return super.onTransferReceived(operator, from, amount, data);
    }

    /// @dev Catches a blocked recipient of the underlying token; the holder `from` is covered via {_update}.
    function unwrap(address from, address to, euint64 amount) public virtual override returns (bytes32) {
        // to block operators in case of unwrap
        if (msg.sender != from) _requireNotBlocked(msg.sender);
        _requireNotBlocked(to);
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
        if (msg.sender != from) _requireNotBlocked(msg.sender);
        // needed because _update is not aware of to, because it's doing a _burn, i.e to is null address
        _requireNotBlocked(to);
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
        _requireNotBlocked(unwrapRequester(unwrapRequestId));
        super.finalizeUnwrap(unwrapRequestId, unwrapAmountCleartext, decryptionProof);
    }
}
