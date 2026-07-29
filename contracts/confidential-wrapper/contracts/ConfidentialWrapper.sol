// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {FHE, externalEuint64, euint64} from "@fhevm/solidity/lib/FHE.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC7984ERC20WrapperUpgradeable} from "./extensions/ERC7984ERC20WrapperUpgradeable.sol";
import {ZamaEthereumConfigUpgradeable} from "./fhevm/ZamaEthereumConfigUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/**
 * @title ConfidentialWrapper
 * @dev An upgradeable wrapper contract built on top of {ERC7984Upgradeable} that allows wrapping an `ERC20` token
 * into an `ERC7984` token. The wrapper contract implements the `IERC1363Receiver` interface
 * which allows users to transfer `ERC1363` tokens directly to the wrapper with a callback to wrap the tokens.
 *
 * WARNING: Minting assumes the full amount of the underlying token transfer has been received, hence some non-standard
 * tokens such as fee-on-transfer or other deflationary-type tokens are not supported by this wrapper.
 *
 * @dev Versioning follows a flat-file model: each release is a git tag of this file. To upgrade the proxy,
 * deploy a new implementation from the target tag and call `upgradeToAndCall` with the appropriate
 * `reinitializeVX` calldata. Previous initializers are tombstoned to prevent misuse.
 */
contract ConfidentialWrapper is
    ERC7984ERC20WrapperUpgradeable,
    ZamaEthereumConfigUpgradeable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    PausableUpgradeable
{
    using EnumerableSet for EnumerableSet.AddressSet;

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
        address _pauser;
        EnumerableSet.AddressSet _observers;
    }

    // keccak256(abi.encode(uint256(keccak256("fhevm_protocol.storage.ConfidentialWrapperV3")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CONFIDENTIAL_WRAPPER_V3_STORAGE_LOCATION =
        0xfbb2c4771bcc77528b8fd58eedad6a4f84fdaf9eea4a56a2752391a0c87eee00;

    /// @dev Emitted when `user` is added to the denylist.
    event UserBlocked(address indexed user);

    /// @dev Emitted when `user` is removed from the denylist.
    event UserUnblocked(address indexed user);

    /// @dev Emitted when the pauser is set to `pauser`.
    event PauserUpdated(address indexed pauser);

    /// @dev Emitted when the underlying deny-list selector configuration is updated.
    event UnderlyingDenyListSelectorUpdated(bytes4 indexed selector, bool isSet);

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

    /// @dev Thrown when the underlying deny-list selector is already configured with the given (selector, isSet) pair.
    error UnderlyingDenyListSelectorAlreadySet(bytes4 selector, bool isSet);

    /// @dev Thrown when a non-zero selector is provided with `isSet = false`, which is an invalid configuration.
    error NonZeroSelectorRequiresIsSet(bytes4 selector);

    /// @dev Thrown when `sender` calls {pause} without being the pauser.
    error SenderNotPauser(address sender);

    /// @dev Emitted when `observer` is granted wildcard user-decryption access.
    event ObserverAdded(address indexed observer);

    /// @dev Emitted when `observer` has wildcard user-decryption access revoked.
    event ObserverRemoved(address indexed observer);

    /// @dev Thrown when `observer` cannot be configured as an observer.
    error InvalidObserver(address observer);

    /// @dev Thrown when attempting to add an observer that is already configured.
    error ObserverAlreadyConfigured(address observer);

    /// @dev Thrown when attempting to remove or renounce an observer that is not configured.
    error ObserverNotConfigured(address observer);

    /// @dev ACL sentinel for delegating user-decryption access across all wrapper-owned handles.
    address public constant WILDCARD_CONTRACT = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;

    /// @dev Every initializer entry point advances straight to this version, so the contract only
    /// ever rests in one of two states: freshly deployed via {initialize}, or upgraded via
    /// {reinitializeV4}. Leaving a lower intermediate version reachable would let anyone call
    /// {initialize} on an already-owned proxy and seize ownership.
    uint64 private constant REINITIALIZER_VERSION = 4;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev Restricts a call to a freshly deployed proxy whose initializer version is still zero.
    /// Must run before {reinitializer}, which bumps the stored version before the function body executes.
    modifier onlyOnDeployment() {
        if (_getInitializedVersion() != 0) {
            revert Initializable.InvalidInitialization();
        }
        _;
    }

    function _getConfidentialWrapperV3Storage() internal pure returns (ConfidentialWrapperV3Storage storage $) {
        assembly {
            $.slot := CONFIDENTIAL_WRAPPER_V3_STORAGE_LOCATION
        }
    }

    /**
     * @notice Initializes the contract when deployed behind an empty proxy.
     * @dev Guarded by {onlyOnDeployment} so it can only run on a proxy whose initializer version is
     * still zero. Advances the initializer version to V4 so older reinitializers cannot be replayed.
     */
    /// @custom:oz-upgrades-validate-as-initializer
    function initialize(
        string memory name_,
        string memory symbol_,
        string memory contractURI_,
        IERC20 underlying_,
        address owner_,
        address[] memory blockedUsers,
        bytes4 underlyingDenyListSelector,
        bool hasUnderlyingDenyListSelector_,
        address[] memory initialObservers
    ) public virtual onlyOnDeployment reinitializer(REINITIALIZER_VERSION) {
        __ConfidentialWrapper_init(name_, symbol_, contractURI_, underlying_, owner_);
        __ConfidentialWrapperV3_init(blockedUsers, underlyingDenyListSelector, hasUnderlyingDenyListSelector_);
        __ConfidentialWrapperV4_init(initialObservers);
    }

    /**
     * @notice Re-initializes the contract from V3. Optionally seeds the observer set with
     * `initialObservers`; reverts if the array contains a duplicate.
     * @dev Seeds V4 state only, calling this directly from V1/V2 skips the V3
     * initializer, leaving the underlying deny-list check disabled.
     */
    /// @custom:oz-upgrades-unsafe-allow missing-initializer-call
    /// @custom:oz-upgrades-validate-as-initializer
    function reinitializeV4(address[] memory initialObservers) public virtual onlyOwner reinitializer(REINITIALIZER_VERSION) {
        __ConfidentialWrapperV4_init(initialObservers);
        __Pausable_init();
    }

    function __ConfidentialWrapper_init(
        string memory name_,
        string memory symbol_,
        string memory contractURI_,
        IERC20 underlying_,
        address owner_
    ) internal onlyInitializing {
        __ERC7984_init(name_, symbol_, contractURI_);
        __ERC7984ERC20Wrapper_init(underlying_);
        __ZamaEthereumConfig_init();
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __Pausable_init();
    }

    /**
     * @dev V3-specific initialization logic. Optionally seeds the denylist with `blockedUsers`.
     * Reverts if any entry in `blockedUsers` appears more than once.
     */
    /// @custom:oz-upgrades-unsafe-allow missing-initializer-call
    function __ConfidentialWrapperV3_init(
        address[] memory blockedUsers,
        bytes4 underlyingDenyListSelector,
        bool hasUnderlyingDenyListSelector_
    ) internal onlyInitializing {
        uint256 length = blockedUsers.length;
        for (uint256 i = 0; i < length; i++) {
            _blockUser(blockedUsers[i]);
        }
        _setUnderlyingDenyListSelector(underlyingDenyListSelector, hasUnderlyingDenyListSelector_);
    }

    /**
     * @dev V4-specific initialization logic. Optionally seeds observers.
     * Reverts if any observer entry appears more than once.
     */
    /// @custom:oz-upgrades-unsafe-allow missing-initializer-call
    function __ConfidentialWrapperV4_init(address[] memory initialObservers) internal onlyInitializing {
        uint256 length = initialObservers.length;
        for (uint256 i = 0; i < length; i++) {
            _addObserver(initialObservers[i]);
        }
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

    /**
     * @dev Sets the flag and selector used to query the underlying token for deny-list status.
     * Allows activating, deactivating, or changing the check after deployment.
     * Reverts if the configuration already matches, so a no-op call is not silently accepted.
     */
    function setUnderlyingDenyListSelector(bool isSet_, bytes4 selector_) external virtual onlyOwner {
        ConfidentialWrapperV3Storage storage $ = _getConfidentialWrapperV3Storage();
        if ($._underlyingDenyListSelector == selector_ && $._hasUnderlyingDenyListSelector == isSet_) {
            revert UnderlyingDenyListSelectorAlreadySet(selector_, isSet_);
        }
        _setUnderlyingDenyListSelector(selector_, isSet_);
    }

    /**
     * @dev Validates and writes the underlying deny-list configuration, then emits
     * {UnderlyingDenyListSelectorUpdated}. Shared by the initializer and {setUnderlyingDenyListSelector}
     * so the `selector != 0 => isSet` invariant and the event have a single definition.
     */
    function _setUnderlyingDenyListSelector(bytes4 selector_, bool isSet_) internal {
        if (selector_ != bytes4(0) && !isSet_) revert NonZeroSelectorRequiresIsSet(selector_);
        ConfidentialWrapperV3Storage storage $ = _getConfidentialWrapperV3Storage();
        $._underlyingDenyListSelector = selector_;
        $._hasUnderlyingDenyListSelector = isSet_;
        emit UnderlyingDenyListSelectorUpdated(selector_, isSet_);
    }

    /// @dev Adds `observer` and grants wildcard user-decryption access to wrapper-owned handles.
    function addObserver(address observer) external virtual onlyOwner {
        _addObserver(observer);
    }

    /// @dev Removes `observer` and revokes wildcard user-decryption access to wrapper-owned handles.
    function removeObserver(address observer) external virtual onlyOwner {
        _removeObserver(observer);
    }

    /// @dev Allows an observer to revoke their own wildcard user-decryption access.
    function renounceObserver() external virtual {
        _removeObserver(msg.sender);
    }

    /// @dev Returns whether `observer` is currently configured.
    function isObserver(address observer) public view virtual returns (bool) {
        return _getConfidentialWrapperV3Storage()._observers.contains(observer);
    }

    /// @dev Returns the observer at `index`.
    function observerAt(uint256 index) public view virtual returns (address) {
        return _getConfidentialWrapperV3Storage()._observers.at(index);
    }

    /// @dev Returns the number of configured observers.
    function observerCount() public view virtual returns (uint256) {
        return _getConfidentialWrapperV3Storage()._observers.length();
    }

    /// @dev Returns all configured observers.
    function observers() public view virtual returns (address[] memory) {
        return _getConfidentialWrapperV3Storage()._observers.values();
    }

    // ----- Pausing -----

    /// @dev Returns the address allowed to call {pause}. `address(0)` means no address can pause.
    function pauser() public view virtual returns (address) {
        return _getConfidentialWrapperV3Storage()._pauser;
    }

    /// @dev Sets the address allowed to call {pause}. Set to `address(0)` to disable pausing.
    function setPauser(address pauser_) external virtual onlyOwner {
        _getConfidentialWrapperV3Storage()._pauser = pauser_;
        emit PauserUpdated(pauser_);
    }

    /// @dev Halts wrapping, unwrapping, unwrap finalization and confidential transfers.
    function pause() external virtual {
        // an unset pauser is address(0), which msg.sender can never equal
        require(msg.sender == pauser(), SenderNotPauser(msg.sender));
        _pause();
    }

    /// @dev Resumes the operations halted by {pause}.
    function unpause() external virtual onlyOwner {
        _unpause();
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

    function _addObserver(address observer) internal virtual {
        if (observer == address(0) || observer == address(this) || observer == WILDCARD_CONTRACT) {
            revert InvalidObserver(observer);
        }

        ConfidentialWrapperV3Storage storage $ = _getConfidentialWrapperV3Storage();
        if (!$._observers.add(observer)) {
            revert ObserverAlreadyConfigured(observer);
        }

        FHE.delegateUserDecryptionWithoutExpiration(observer, WILDCARD_CONTRACT);
        emit ObserverAdded(observer);
    }

    function _removeObserver(address observer) internal virtual {
        ConfidentialWrapperV3Storage storage $ = _getConfidentialWrapperV3Storage();
        if ($._observers.remove(observer)) {
            FHE.revokeUserDecryptionDelegation(observer, WILDCARD_CONTRACT);
            emit ObserverRemoved(observer);
        }
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

    // ----- Overrides enforcing the denylist and the pause -----

    /// @dev Catches confidential transfers (both parties), the wrap recipient (mint side), and the unwrap holder (burn side).
    /// `whenNotPaused` here gates every entry point that moves cTokens, including ones added later.
    /// {finalizeUnwrap} carries the only other gate.
    function _update(
        address from,
        address to,
        euint64 amount
    ) internal virtual override whenNotPaused returns (euint64) {
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
     * @dev Prevents finalization of the underlying transfer to a recipient that became
     * blocked between {unwrap} and {finalizeUnwrap}. `whenNotPaused` is required here
     * because the cTokens were burnt in {unwrap}, so finalization never reaches {_update}.
     */
    function finalizeUnwrap(
        bytes32 unwrapRequestId,
        uint64 unwrapAmountCleartext,
        bytes calldata decryptionProof
    ) public virtual override whenNotPaused {
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

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
