// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/Impl.sol";
import "@fhevm/solidity/config/ZamaConfig.sol";

interface ISafe {
    function getOwners() external view returns (address[] memory);
}

/// Helper contract to facilitate usage of fhevm with multisig accounts
contract FHEVMMultiSigHelper {
    /// @notice Returned if the list of input handles is empty
    error EmptyInputHandles();

    /// @notice Returned if the list of owners is empty
    error EmptyOwners();

    /// @notice Returned if the multisig address is null
    error NullMultisig();

    /// @notice Returned if one of the handles is null
    error UninitializedHandle();

    constructor() {
        FHE.setCoprocessor(ZamaConfig.getEthereumCoprocessorConfig());
    }

    /// @notice Helper method to allow a list of handles to the owners of a Safe multisig contract and to the Safe itself
    /// @param safeMultisig The Safe account address
    /// @param inputHandles The list of initialized handles that we want to allow to the Safe and its owners, must be non-empty
    /// @param inputProof The input proof corresponding to the list of inputHandles, must be non-empty
    /// @dev It is possible to use this method with any (initialized, non-null) handle type
    function allowForSafeMultiSig(
        address safeMultisig,
        bytes32[] memory inputHandles,
        bytes memory inputProof
    ) external {
        address[] memory owners = ISafe(safeMultisig).getOwners();
        uint256 numOwners = owners.length;
        _allowHandlesForMultiSigAndOwners(safeMultisig, inputHandles, inputProof, owners, numOwners);
    }

    /// @notice More general helper method to allow a list of handles  to a custom list of owners and a multisig,
    /// @notice but requires the user to manually input correct list of owners as argument
    /// @notice WARNING: the user is responsible to enter the correct list of owners corresponding to the multisig
    /// @notice Can also be used with non-Safe multisigs (eg Aragon, CoinbaseSmartWallet, etc)
    /// @param multisig The multisig account address (could be a non-Safe account)
    /// @param owners The list of owners, must be non-empty
    /// @param inputHandles The list of initialized handles that we want to allow to the owners, must be non-empty
    /// @param inputProof The input proof corresponding to the list of inputHandles, must be non-empty
    /// @dev It is possible to use this same function with any (initialized, non-null) handle type
    function allowForCustomMultiSigOwners(
        address multisig,
        address[] memory owners,
        bytes32[] memory inputHandles,
        bytes memory inputProof
    ) external {
        uint256 numOwners = owners.length;
        if (numOwners == 0) revert EmptyOwners();
        _allowHandlesForMultiSigAndOwners(multisig, inputHandles, inputProof, owners, numOwners);
    }

    /// @notice Internal function to allow list of input handles to the multisig account and its owners
    /// @param multisig The multisig account address (could be a non-Safe account)
    /// @param inputHandles The list of initialized handles that we want to allow to the owners, must be non-empty
    /// @param inputProof The input proof corresponding to the list of inputHandles, must be non-empty
    /// @param owners The list of owners, must be non-empty
    /// @param numOwners The number of owners
    function _allowHandlesForMultiSigAndOwners(
        address multisig,
        bytes32[] memory inputHandles,
        bytes memory inputProof,
        address[] memory owners,
        uint256 numOwners
    ) internal {
        if (multisig == address(0)) revert NullMultisig();
        uint256 inputHandlesLength = inputHandles.length;
        if (inputHandlesLength == 0) revert EmptyInputHandles();
        for (uint256 idxHandle = 0; idxHandle < inputHandlesLength; idxHandle++) {
            bytes32 inputHandle = inputHandles[idxHandle];
            if (inputHandle == bytes32(0)) revert UninitializedHandle();
            Impl.verify(inputHandle, inputProof, FheType(uint8(inputHandle[30])));
            Impl.allow(inputHandle, multisig);
            for (uint256 idxOwner; idxOwner < numOwners; idxOwner++) {
                Impl.allow(inputHandle, owners[idxOwner]);
            }
        }
    }
}
