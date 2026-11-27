// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {ConfidentialHooklessWrapper} from "./ConfidentialHooklessWrapper.sol";

/**
 * @title ConfidentialOAVWrapper
 * @dev {ConfidentialHooklessWrapper} over Yield OAV shares. An OAV mints {OAV_VIRTUAL_SHARES} shares per
 * strategy share, which the decimals-derived rate ignores, flooring the batcher's exchange rate to
 * zero. {rate} includes the factor; {decimals} does not, so convert through {rate}, never decimals.
 *
 * The OAV must hold a seed of at least one whole unit of its underlying before its deposit batcher goes live
 * (INVARIANTS P-41): a donation to an empty OAV prices its shares so high that every deposit batch settles
 * below the batcher's minimum exchange rate and refunds at its deadline.
 *
 * Deploy only behind a fresh proxy. Never repoint a standard proxy here or back: it rescales every
 * balance and pending unwrap.
 */
contract ConfidentialOAVWrapper is ConfidentialHooklessWrapper {
    /// @dev OAV shares minted per strategy share, on top of the decimals-derived rate.
    uint256 public constant OAV_VIRTUAL_SHARES = 1e6;

    /// @dev An upgrade would change {rate}.
    error UpgradeChangesRate(uint256 previousRate, uint256 newRate);

    /// @dev The decimals-derived rate times {OAV_VIRTUAL_SHARES}.
    function rate() public view virtual override returns (uint256) {
        return super.rate() * OAV_VIRTUAL_SHARES;
    }

    /// @dev Reverts if the upgrade, including `data`, changes {rate}.
    function upgradeToAndCall(address newImplementation, bytes memory data) public payable virtual override {
        uint256 previousRate = rate();
        super.upgradeToAndCall(newImplementation, data);
        // External, so it runs the new implementation.
        uint256 newRate = this.rate();
        if (newRate != previousRate) revert UpgradeChangesRate(previousRate, newRate);
    }
}
