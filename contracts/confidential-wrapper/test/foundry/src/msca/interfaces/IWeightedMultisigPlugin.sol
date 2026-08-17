// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

/**
 * @title IWeightedMultisigPlugin
 * @notice Circle's `WeightedWebauthnMultisigPlugin`, where an MSCA's ownership lives.
 * @dev Mutators are execution functions, so they are called on the account address.
 */
interface IWeightedMultisigPlugin {
    /// @notice Two 256-bit coordinates of a P-256 public key, for passkey owners.
    /// @dev Always passed empty here: this package configures EOA signers only.
    struct PublicKey {
        uint256 x;
        uint256 y;
    }

    /// @notice One owner's entry. Mirrors Circle's `OwnerData`.
    /// @dev `credType` is 0 for a passkey (`PUBLIC_KEY`) and 1 for an EOA (`ADDRESS`).
    struct OwnerData {
        uint256 weight;
        uint8 credType;
        address addr;
        uint256 publicKeyX;
        uint256 publicKeyY;
    }

    /// @notice Account-level ownership summary. Mirrors Circle's `OwnershipMetadata`.
    struct OwnershipMetadata {
        uint256 numOwners;
        uint256 thresholdWeight;
        uint256 totalWeight;
    }

    /// @notice Adds owners and optionally sets a new threshold weight (0 leaves it unmodified).
    function addOwners(
        address[] calldata ownersToAdd,
        uint256[] calldata weightsToAdd,
        PublicKey[] calldata publicKeyOwnersToAdd,
        uint256[] calldata publicKeyWeightsToAdd,
        uint256 newThresholdWeight
    ) external;

    /// @notice Removes owners and optionally sets a new threshold weight.
    /// @dev Reverts rather than leaving the account ownerless — add before remove.
    function removeOwners(
        address[] calldata ownersToRemove,
        PublicKey[] calldata publicKeyOwnersToRemove,
        uint256 newThresholdWeight
    ) external;

    /// @notice The full owner set of `account`.
    function ownershipInfoOf(address account)
        external
        view
        returns (bytes30[] memory ownerIds, OwnerData[] memory ownersData, OwnershipMetadata memory metadata);
}
