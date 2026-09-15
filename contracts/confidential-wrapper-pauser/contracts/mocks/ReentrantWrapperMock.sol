// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import { IConfidentialWrapperPauser } from "../interfaces/IConfidentialWrapperPauser.sol";

/**
 * @title ReentrantWrapperMock
 * @notice A pause target whose `pause()` calls back into the pauser contract before it pauses itself, to prove the
 * roster check and the best-effort batch hold against reentrancy. The callback is picked per test: a pause of
 * another wrapper, a batch pause, or a roster change. Because the mock is not a roster member (and not the admin),
 * every callback reverts; `swallow` decides whether the mock lets that revert bubble up (so the pauser reports it in
 * `PauseFailed` / `WrapperPauseFailed`) or catches it and pauses itself anyway. Test-only.
 */
contract ReentrantWrapperMock {
    enum Callback {
        PauseOther,
        PauseBatch,
        AddSelf
    }

    IConfidentialWrapperPauser public immutable PAUSER;
    address public immutable OTHER;

    Callback public callback;
    bool public swallow;
    bool private _paused;

    /// @notice Bubbled up when `swallow` is false, wrapping the pauser's own revert data.
    error CallbackRejected(bytes reason);

    constructor(IConfidentialWrapperPauser pauser_, address other_) {
        PAUSER = pauser_;
        OTHER = other_;
    }

    function configure(Callback callback_, bool swallow_) external {
        callback = callback_;
        swallow = swallow_;
    }

    function paused() external view returns (bool) {
        return _paused;
    }

    function pause() external {
        bytes memory data;
        if (callback == Callback.PauseOther) {
            data = abi.encodeWithSignature("pause(address)", OTHER);
        } else if (callback == Callback.PauseBatch) {
            address[] memory batch = new address[](2);
            batch[0] = OTHER;
            batch[1] = address(this);
            data = abi.encodeWithSignature("pause(address[])", batch);
        } else {
            data = abi.encodeCall(IConfidentialWrapperPauser.addPauser, (address(this)));
        }

        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory reason) = address(PAUSER).call(data);
        if (!ok && !swallow) revert CallbackRejected(reason);
        _paused = true;
    }
}
