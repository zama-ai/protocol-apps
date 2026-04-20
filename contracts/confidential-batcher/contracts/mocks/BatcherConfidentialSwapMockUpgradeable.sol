// SPDX-License-Identifier: MIT
// Ported from https://github.com/OpenZeppelin/openzeppelin-confidential-contracts/blob/v0.4.0-rc.0/contracts/mocks/finance/BatcherConfidentialSwapMock.sol
pragma solidity ^0.8.27;

import {FHE, externalEuint64, euint64} from "@fhevm/solidity/lib/FHE.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC7984ERC20Wrapper} from "@openzeppelin/confidential-contracts/interfaces/IERC7984ERC20Wrapper.sol";

import {BatcherConfidentialUpgradeable} from "../BatcherConfidentialUpgradeable.sol";
import {ZamaEthereumConfigUpgradeable} from "../fhevm/ZamaEthereumConfigUpgradeable.sol";
import {ExchangeMock} from "./ExchangeMock.sol";

/// @dev Upgradeable port of upstream `BatcherConfidentialSwapMock`.
/// Concrete UUPS subclass used by the ported upstream test suite.
contract BatcherConfidentialSwapMockUpgradeable is
    BatcherConfidentialUpgradeable,
    ZamaEthereumConfigUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    /// @custom:storage-location erc7201:fhevm_protocol.storage.BatcherConfidentialSwapMock
    struct BatcherConfidentialSwapMockStorage {
        ExchangeMock _exchange;
        address _admin;
        ExecuteOutcome _outcome;
    }

    // keccak256(abi.encode(uint256(keccak256("fhevm_protocol.storage.BatcherConfidentialSwapMock")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BATCHER_CONFIDENTIAL_SWAP_MOCK_STORAGE_LOCATION =
        0xf57b4427f9f8d52d17fde4d99c06aaa51cf21b89900074f213cee71ec2a9ec00;

    function _getBatcherConfidentialSwapMockStorage()
        internal
        pure
        returns (BatcherConfidentialSwapMockStorage storage $)
    {
        assembly {
            $.slot := BATCHER_CONFIDENTIAL_SWAP_MOCK_STORAGE_LOCATION
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        IERC7984ERC20Wrapper fromToken_,
        IERC7984ERC20Wrapper toToken_,
        ExchangeMock exchange_,
        address admin_,
        address owner_
    ) external initializer {
        __BatcherConfidential_init(fromToken_, toToken_);
        __ZamaEthereumConfig_init();
        __Ownable_init(owner_);

        BatcherConfidentialSwapMockStorage storage $ = _getBatcherConfidentialSwapMockStorage();
        $._exchange = exchange_;
        $._admin = admin_;
        $._outcome = ExecuteOutcome.Complete;
    }

    function exchange() public view returns (ExchangeMock) {
        return _getBatcherConfidentialSwapMockStorage()._exchange;
    }

    function admin() public view returns (address) {
        return _getBatcherConfidentialSwapMockStorage()._admin;
    }

    function outcome() public view returns (ExecuteOutcome) {
        return _getBatcherConfidentialSwapMockStorage()._outcome;
    }

    function routeDescription() public pure override returns (string memory) {
        return "Exchange fromToken for toToken by swapping through the mock exchange.";
    }

    function setExecutionOutcome(ExecuteOutcome outcome_) public {
        _getBatcherConfidentialSwapMockStorage()._outcome = outcome_;
    }

    /// @dev Join the current batch with `externalAmount` and `inputProof`.
    function join(externalEuint64 externalAmount, bytes calldata inputProof) public virtual returns (euint64) {
        euint64 amount = FHE.fromExternal(externalAmount, inputProof);
        FHE.allowTransient(amount, address(fromToken()));
        euint64 transferred = fromToken().confidentialTransferFrom(msg.sender, address(this), amount);

        euint64 joinedAmount = _join(msg.sender, transferred);
        euint64 refundAmount = FHE.sub(transferred, joinedAmount);

        FHE.allowTransient(refundAmount, address(fromToken()));

        fromToken().confidentialTransfer(msg.sender, refundAmount);

        return joinedAmount;
    }

    function join(uint64 amount) public {
        euint64 ciphertext = FHE.asEuint64(amount);
        FHE.allowTransient(ciphertext, msg.sender);

        bytes memory callData = abi.encodeWithSignature(
            "join(bytes32,bytes)",
            externalEuint64.wrap(euint64.unwrap(ciphertext)),
            hex""
        );

        Address.functionDelegateCall(address(this), callData);
    }

    function quit(uint256 batchId) public virtual override returns (euint64) {
        euint64 amount = super.quit(batchId);
        FHE.allow(totalDeposits(batchId), admin());
        return amount;
    }

    function _join(address to, euint64 amount) internal virtual override returns (euint64) {
        euint64 joinedAmount = super._join(to, amount);
        FHE.allow(totalDeposits(currentBatchId()), admin());
        return joinedAmount;
    }

    function _executeRoute(uint256, uint256 unwrapAmount) internal override returns (ExecuteOutcome) {
        ExecuteOutcome currentOutcome = outcome();
        if (currentOutcome == ExecuteOutcome.Complete) {
            uint256 rawAmount = unwrapAmount * fromToken().rate();
            IERC20(fromToken().underlying()).approve(address(exchange()), rawAmount);
            exchange().swapAToB(rawAmount);
        }
        return currentOutcome;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
