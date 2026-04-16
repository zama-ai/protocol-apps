// SPDX-License-Identifier: MIT
// Forked from OpenZeppelin Confidential Contracts v0.4.0-rc.0 (finance/BatcherConfidential.sol)
// Changes: split constructor into constructor (immutables) + initializer (storage/approvals) for UUPS proxy compatibility.

pragma solidity ^0.8.24;

import {FHE, externalEuint64, euint64, ebool, euint128} from "@fhevm/solidity/lib/FHE.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC7984ERC20Wrapper} from "@openzeppelin/confidential-contracts/interfaces/IERC7984ERC20Wrapper.sol";
import {IERC7984Receiver} from "@openzeppelin/confidential-contracts/interfaces/IERC7984Receiver.sol";
import {FHESafeMath} from "@openzeppelin/confidential-contracts/utils/FHESafeMath.sol";

/**
 * @dev Upgradeable fork of `BatcherConfidential` from OpenZeppelin Confidential Contracts v0.4.0-rc.0.
 *
 * The only structural change is splitting the constructor into:
 * - constructor: ERC165 validation + immutable assignments
 * - __BatcherConfidential_init: storage initialization (_currentBatchId) + token approvals
 *
 * All other logic is identical to the upstream contract.
 */
abstract contract BatcherConfidentialUpgradeable is Initializable, ReentrancyGuardTransient, IERC7984Receiver {
    enum BatchState {
        Pending,
        Dispatched,
        Finalized,
        Canceled
    }

    enum ExecuteOutcome {
        Complete,
        Partial,
        Cancel
    }

    struct Batch {
        euint64 totalDeposits;
        bytes32 unwrapRequestId;
        uint64 exchangeRate;
        bool canceled;
        mapping(address => euint64) deposits;
    }

    IERC7984ERC20Wrapper private immutable _fromToken;
    IERC7984ERC20Wrapper private immutable _toToken;
    mapping(uint256 => Batch) private _batches;
    uint256 private _currentBatchId;

    event BatchDispatched(uint256 indexed batchId);
    event BatchCanceled(uint256 indexed batchId);
    event BatchFinalized(uint256 indexed batchId, uint64 exchangeRate);
    event Joined(uint256 indexed batchId, address indexed account, euint64 amount);
    event Claimed(uint256 indexed batchId, address indexed account, euint64 amount);
    event Quit(uint256 indexed batchId, address indexed account, euint64 amount);

    error BatchNonexistent(uint256 batchId);
    error ZeroDeposits(uint256 batchId, address account);
    error BatchUnexpectedState(uint256 batchId, BatchState current, bytes32 expectedStates);
    error InvalidExchangeRate(uint256 batchId, uint256 totalDeposits, uint64 exchangeRate);
    error Unauthorized();
    error InvalidWrapperToken(address token);

    /// @dev Constructor: validates interfaces and stores immutables only.
    constructor(IERC7984ERC20Wrapper fromToken_, IERC7984ERC20Wrapper toToken_) {
        require(
            ERC165Checker.supportsInterface(address(fromToken_), type(IERC7984ERC20Wrapper).interfaceId),
            InvalidWrapperToken(address(fromToken_))
        );
        require(
            ERC165Checker.supportsInterface(address(toToken_), type(IERC7984ERC20Wrapper).interfaceId),
            InvalidWrapperToken(address(toToken_))
        );

        _fromToken = fromToken_;
        _toToken = toToken_;
    }

    /// @dev Initializer: sets storage state and token approvals on the proxy.
    function __BatcherConfidential_init() internal onlyInitializing {
        _currentBatchId = 1;
        SafeERC20.forceApprove(IERC20(fromToken().underlying()), address(fromToken()), type(uint256).max);
        SafeERC20.forceApprove(IERC20(toToken().underlying()), address(toToken()), type(uint256).max);
    }

    function claim(uint256 batchId, address account) public virtual nonReentrant returns (euint64) {
        return _claim(batchId, account);
    }

    function quit(uint256 batchId) public virtual nonReentrant returns (euint64) {
        _validateStateBitmap(batchId, _encodeStateBitmap(BatchState.Pending) | _encodeStateBitmap(BatchState.Canceled));

        euint64 deposit = deposits(batchId, msg.sender);
        require(FHE.isInitialized(deposit), ZeroDeposits(batchId, msg.sender));

        euint64 totalDeposits_ = totalDeposits(batchId);

        FHE.allowTransient(deposit, address(fromToken()));
        euint64 sent = fromToken().confidentialTransfer(msg.sender, deposit);
        euint64 newTotalDeposits = FHE.sub(totalDeposits_, sent);
        euint64 newDeposit = FHE.sub(deposit, sent);

        FHE.allowThis(newTotalDeposits);
        FHE.allowThis(newDeposit);
        FHE.allow(newDeposit, msg.sender);

        _batches[batchId].totalDeposits = newTotalDeposits;
        _batches[batchId].deposits[msg.sender] = newDeposit;

        emit Quit(batchId, msg.sender, sent);

        return sent;
    }

    function dispatchBatch() public virtual {
        uint256 batchId = _getAndIncreaseBatchId();

        euint64 amountToUnwrap = totalDeposits(batchId);
        FHE.allowTransient(amountToUnwrap, address(fromToken()));
        _batches[batchId].unwrapRequestId = fromToken().unwrap(
            address(this),
            address(this),
            externalEuint64.wrap(euint64.unwrap(amountToUnwrap)),
            ""
        );

        emit BatchDispatched(batchId);
    }

    function dispatchBatchCallback(
        uint256 batchId,
        uint64 unwrapAmountCleartext,
        bytes calldata decryptionProof
    ) public virtual nonReentrant {
        _validateStateBitmap(batchId, _encodeStateBitmap(BatchState.Dispatched));

        bytes32 unwrapRequestId_ = unwrapRequestId(batchId);
        try IERC7984ERC20Wrapper(fromToken()).finalizeUnwrap(unwrapRequestId_, unwrapAmountCleartext, decryptionProof) {
        } catch {
            bytes32[] memory handles = new bytes32[](1);
            handles[0] = euint64.unwrap(fromToken().unwrapAmount(unwrapRequestId_));
            FHE.checkSignatures(handles, abi.encode(unwrapAmountCleartext), decryptionProof);
        }

        ExecuteOutcome outcome;
        if (unwrapAmountCleartext == 0) {
            outcome = ExecuteOutcome.Cancel;
        } else {
            outcome = _executeRoute(batchId, unwrapAmountCleartext);
        }

        if (outcome == ExecuteOutcome.Complete) {
            uint256 swappedAmount = IERC20(toToken().underlying()).balanceOf(address(this));

            toToken().wrap(address(this), swappedAmount);

            uint256 wrappedAmount = swappedAmount / toToken().rate();
            uint64 exchangeRate_ = SafeCast.toUint64(
                Math.mulDiv(wrappedAmount, uint256(10) ** exchangeRateDecimals(), unwrapAmountCleartext)
            );

            require(
                exchangeRate_ != 0 && wrappedAmount <= type(uint64).max,
                InvalidExchangeRate(batchId, unwrapAmountCleartext, exchangeRate_)
            );
            _batches[batchId].exchangeRate = exchangeRate_;

            emit BatchFinalized(batchId, exchangeRate_);
        } else if (outcome == ExecuteOutcome.Cancel) {
            fromToken().wrap(address(this), unwrapAmountCleartext * fromToken().rate());
            _batches[batchId].canceled = true;

            emit BatchCanceled(batchId);
        }
    }

    function onConfidentialTransferReceived(
        address,
        address from,
        euint64 amount,
        bytes calldata
    ) external returns (ebool) {
        require(msg.sender == address(fromToken()), Unauthorized());
        ebool success = FHE.gt(_join(from, amount), FHE.asEuint64(0));
        FHE.allowTransient(success, msg.sender);
        return success;
    }

    function fromToken() public view virtual returns (IERC7984ERC20Wrapper) {
        return _fromToken;
    }

    function toToken() public view virtual returns (IERC7984ERC20Wrapper) {
        return _toToken;
    }

    function currentBatchId() public view virtual returns (uint256) {
        return _currentBatchId;
    }

    function unwrapRequestId(uint256 batchId) public view virtual returns (bytes32) {
        return _batches[batchId].unwrapRequestId;
    }

    function totalDeposits(uint256 batchId) public view virtual returns (euint64) {
        return _batches[batchId].totalDeposits;
    }

    function deposits(uint256 batchId, address account) public view virtual returns (euint64) {
        return _batches[batchId].deposits[account];
    }

    function exchangeRate(uint256 batchId) public view virtual returns (uint64) {
        return _batches[batchId].exchangeRate;
    }

    function exchangeRateDecimals() public pure virtual returns (uint8) {
        return 6;
    }

    function routeDescription() public pure virtual returns (string memory);

    function batchState(uint256 batchId) public view virtual returns (BatchState) {
        if (_batches[batchId].canceled) {
            return BatchState.Canceled;
        }
        if (exchangeRate(batchId) != 0) {
            return BatchState.Finalized;
        }
        if (unwrapRequestId(batchId) != 0) {
            return BatchState.Dispatched;
        }
        if (batchId == currentBatchId()) {
            return BatchState.Pending;
        }

        revert BatchNonexistent(batchId);
    }

    function _claim(uint256 batchId, address account) internal virtual returns (euint64) {
        _validateStateBitmap(batchId, _encodeStateBitmap(BatchState.Finalized));

        euint64 deposit = deposits(batchId, account);
        require(FHE.isInitialized(deposit), ZeroDeposits(batchId, account));

        euint64 amountToSend = FHE.asEuint64(
            FHE.div(FHE.mul(FHE.asEuint128(deposit), exchangeRate(batchId)), uint128(10) ** exchangeRateDecimals())
        );
        FHE.allowTransient(amountToSend, address(toToken()));

        euint64 amountTransferred = toToken().confidentialTransfer(account, amountToSend);

        ebool transferSuccess = FHE.ne(amountTransferred, FHE.asEuint64(0));
        euint64 newDeposit = FHE.select(transferSuccess, FHE.asEuint64(0), deposit);

        FHE.allowThis(newDeposit);
        FHE.allow(newDeposit, account);
        _batches[batchId].deposits[account] = newDeposit;

        emit Claimed(batchId, account, amountTransferred);

        return amountTransferred;
    }

    function _join(address to, euint64 amount) internal virtual returns (euint64) {
        uint256 batchId = currentBatchId();

        (ebool success, euint64 newTotalDeposits) = FHESafeMath.tryIncrease(totalDeposits(batchId), amount);
        euint64 joinedAmount = FHE.select(success, amount, FHE.asEuint64(0));
        euint64 newDeposits = FHE.add(deposits(batchId, to), joinedAmount);

        FHE.allowThis(newTotalDeposits);
        FHE.allowThis(newDeposits);
        FHE.allow(newDeposits, to);
        FHE.allow(joinedAmount, to);

        _batches[batchId].totalDeposits = newTotalDeposits;
        _batches[batchId].deposits[to] = newDeposits;

        emit Joined(batchId, to, joinedAmount);

        return joinedAmount;
    }

    function _executeRoute(uint256 batchId, uint256 amount) internal virtual returns (ExecuteOutcome);

    function _validateStateBitmap(uint256 batchId, bytes32 allowedStates) internal view returns (BatchState) {
        BatchState currentState = batchState(batchId);
        if (_encodeStateBitmap(currentState) & allowedStates == bytes32(0)) {
            revert BatchUnexpectedState(batchId, currentState, allowedStates);
        }
        return currentState;
    }

    function _getAndIncreaseBatchId() internal virtual returns (uint256) {
        return _currentBatchId++;
    }

    function _encodeStateBitmap(BatchState batchState_) internal pure returns (bytes32) {
        return bytes32(1 << uint8(batchState_));
    }

    /// @dev Reserves storage slots for future base contract upgrades.
    uint256[48] private __gap;
}
