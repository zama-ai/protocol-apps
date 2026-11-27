// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {IERC1363Receiver} from "@openzeppelin/contracts/interfaces/IERC1363Receiver.sol";
import {ConfidentialWrapper} from "./ConfidentialWrapper.sol";

/**
 * @title ConfidentialHooklessWrapper
 * @dev {ConfidentialWrapper} with the ERC-1363 wrap hook closed. Use it for an underlying that can be made to
 * call any target, such as a Yield OAV (whitelisted `claimAdditionalRewards` calls) or a Nest share
 * (`NestShareOFT.manage`): a hook call from such a token proves no transfer, so the standard wrapper would mint
 * unbacked tokens. Wrap through {wrap}.
 */
contract ConfidentialHooklessWrapper is ConfidentialWrapper {
    /// @dev The ERC-1363 wrap hook is closed.
    error TransferHookDisabled();

    /// @dev Always reverts with {TransferHookDisabled}.
    function onTransferReceived(address, address, uint256, bytes calldata) public pure override returns (bytes4) {
        revert TransferHookDisabled();
    }

    /// @dev Does not report {IERC1363Receiver}.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId != type(IERC1363Receiver).interfaceId && super.supportsInterface(interfaceId);
    }
}
