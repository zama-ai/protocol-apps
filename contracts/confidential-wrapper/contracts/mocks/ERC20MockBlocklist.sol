// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC20Mock} from "./ERC20Mock.sol";

/// @dev cUSDC-style underlying: isBlacklisted(address) — selector 0xfe575a87
contract ERC20MockCUSDC is ERC20Mock {
    mapping(address => bool) private _denyListed;

    constructor() ERC20Mock("Mock USDC", "mUSDC", 6) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setDenyListed(address account, bool status) external {
        _denyListed[account] = status;
    }

    function isBlacklisted(address account) external view returns (bool) {
        return _denyListed[account];
    }
}

/// @dev cUSDT-style underlying: getBlackListStatus(address) — selector 0x59bf1abe
contract ERC20MockCUSDT is ERC20Mock {
    mapping(address => bool) private _denyListed;

    constructor() ERC20Mock("Mock USDT", "mUSDT", 6) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setDenyListed(address account, bool status) external {
        _denyListed[account] = status;
    }

    function getBlackListStatus(address account) external view returns (bool) {
        return _denyListed[account];
    }
}

/// @dev tGBP-style underlying: isBanned(address) — selector 0x97f735d5
contract ERC20MockTGBP is ERC20Mock {
    mapping(address => bool) private _denyListed;

    constructor() ERC20Mock("Mock GBP", "mGBP", 6) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setDenyListed(address account, bool status) external {
        _denyListed[account] = status;
    }

    function isBanned(address account) external view returns (bool) {
        return _denyListed[account];
    }
}

/// @dev XAUt-style underlying: isBlocked(address) — selector 0xfbac3951
contract ERC20MockXAUt is ERC20Mock {
    mapping(address => bool) private _denyListed;

    constructor() ERC20Mock("Mock Gold", "mXAUt", 6) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setDenyListed(address account, bool status) external {
        _denyListed[account] = status;
    }

    function isBlocked(address account) external view returns (bool) {
        return _denyListed[account];
    }
}

/// @dev Deny-list call always reverts — triggers UnderlyingDenyListCallFailed
contract ERC20MockRevertingDenyList is ERC20Mock {
    constructor() ERC20Mock("Mock Reverting", "mREV", 6) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    // Same selector as isBlacklisted(address): 0xfe575a87 — always reverts
    function isBlacklisted(address) external pure returns (bool) {
        revert();
    }
}

/// @dev Underlying whose deny-list check answers on selector 0x00000000, exercised via the
///      fallback. Proves (selector = 0x00000000, isSet = true) is a legal, active configuration:
///      a mined zero selector is treated as an ordinary selector, not as "check disabled".
contract ERC20MockZeroSelector is ERC20Mock {
    mapping(address => bool) private _denyListed;

    constructor() ERC20Mock("Mock Zero", "mZERO", 6) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setDenyListed(address account, bool status) external {
        _denyListed[account] = status;
    }

    // The wrapper calls staticcall(abi.encodeWithSelector(0x00000000, account)); no declared
    // function matches selector 0x00000000, so the call lands here. Reads only state, so it is
    // safe under staticcall. `data` is the full calldata: 4-byte selector followed by the address.
    fallback(bytes calldata data) external returns (bytes memory) {
        address account = abi.decode(data[4:], (address));
        return abi.encode(_denyListed[account]);
    }
}

/// @dev Deny-list call returns empty data (0 bytes) — triggers InvalidUnderlyingDenyListResponse
contract ERC20MockInvalidDenyList is ERC20Mock {
    constructor() ERC20Mock("Mock Invalid", "mINV", 6) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    // Same selector as isBlacklisted(address): 0xfe575a87 — returns nothing (length != 32)
    function isBlacklisted(address) external pure {}
}
