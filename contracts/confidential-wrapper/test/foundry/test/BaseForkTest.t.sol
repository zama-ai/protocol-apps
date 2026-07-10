// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.27;

import {FhevmTest} from "forge-fhevm/FhevmTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {euint64} from "encrypted-types/EncryptedTypes.sol";

import {ConfidentialWrapper} from "confidential-wrapper/ConfidentialWrapper.sol";
import {ConfidentialTokenWrappersRegistry} from "registry/ConfidentialTokenWrappersRegistry.sol";

/**
 * @title BaseForkTest
 * @notice Shared harness for mainnet-fork tests over the live Confidential Wrappers.
 *
 * @dev The suite runs against an Anvil instance booted from the committed
 * `deployments/mainnet-fork/anvil-state.json` fixture (forked mainnet data). The
 * deployed wrappers point their FHE config at the real Zama mainnet coprocessor,
 * whose compute happens off-chain, so a bare fork cannot produce usable
 * ciphertext/decryptions.
 *
 * To make FHE satisfiable natively in Solidity, this harness inherits
 * {FhevmTest}: its `setUp()` deploys the fhEVM host contracts in-process at
 * their canonical local addresses and records executor logs into an in-memory
 * plaintext DB. The committed fixture already points each baked wrapper's FHE
 * config at that local host and zeroes the cached total-supply handle, so tests
 * do not patch wrapper storage at runtime.
 */
abstract contract BaseForkTest is FhevmTest {
    address internal constant REGISTRY = 0xeb5015fF021DB115aCe010f23F55C2591059bBA0;

    ConfidentialTokenWrappersRegistry internal registry;

    /// @dev ERC-1967 implementation slot: bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1).
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// @dev ERC7984Upgradeable ERC-7201 storage base (name/symbol/contractURI/balances/operators/totalSupply).
    bytes32 internal constant ERC7984_STORAGE_BASE = 0xabe6faf3f1b202c971f9850194a6389c7b24dbc9035a913f45a1f82a5d968c00;
    /// @dev ERC7984ERC20WrapperUpgradeable ERC-7201 storage base (underlying+decimals packed, rate, unwrapRequests).
    bytes32 internal constant WRAPPER_STORAGE_BASE = 0x789981291a45bfde11e7ba326d04f33e2215f03c85dfc0acebcc6167a5924700;
    /// @dev CoprocessorConfig ERC-7201 base in the wrapper (acl, coprocessor, kmsVerifier at +0/+1/+2).
    bytes32 internal constant FHEVM_CONFIG_BASE = 0x9e7b61f58c47dc699ac88507c4f5bb9f121c03808c5676a8078fe583e4649700;

    /// @dev forge-fhevm's in-process host addresses (dependencies/forge-fhevm-.../FHEVMHostAddresses.sol),
    /// deployed by {FhevmTest.setUp}. The live wrappers instead store Zama's mainnet coprocessor
    /// addresses, so encrypted ops are repointed here at runtime (see {_repointFhevmConfig}).
    address internal constant LOCAL_FHEVM_ACL = 0x50157CFfD6bBFA2DECe204a89ec419c23ef5755D;
    address internal constant LOCAL_FHEVM_COPROCESSOR = 0xe3a9105a3a932253A70F126eb1E3b589C643dD24;
    address internal constant LOCAL_FHEVM_KMS_VERIFIER = 0x901F8942346f7AB3a01F6D7613119Bca447Bb030;

    /// @notice Blacklist interface for an underlying token.
    /// @dev Each token declares its own getter explicitly in the shared config.
    struct UnderlyingDenyListInterface {
        bytes4 getter;
        bool supported;
    }

    /// @notice Per-wrapper state captured immediately before the setUp upgrade, used by
    /// {UpgradeTest} to prove the impl swap preserves storage.
    struct PreUpgradeSnapshot {
        string name;
        string symbol;
        string contractUri;
        uint8 decimals;
        address underlying;
        uint256 rate;
        address owner;
        uint256 maxTotalSupply;
        address implementation;
        // Contiguous head of each ERC-7201 struct, captured raw so {UpgradeTest} can prove the
        // storage layout did not shift under the impl swap.
        // ERC7984: [_balances base, _operators base, _totalSupply, _name, _symbol, _contractURI].
        bytes32[6] erc7984Slots;
        // wrapper: [_underlying+_decimals packed, _rate, _unwrapRequests base].
        bytes32[3] wrapperSlots;
        // A pending unwrap request seeded into `_unwrapRequests` before the upgrade (see
        // {_seedPendingUnwrap}); {UpgradeTest} proves this hashed-slot entry survives the swap.
        bytes32 pendingUnwrapId;
        address pendingUnwrapRecipient;
    }

    /// @dev Pre-upgrade snapshot keyed by wrapper proxy address.
    mapping(address wrapper => PreUpgradeSnapshot) internal preUpgrade;

    /// @dev The freshly-compiled implementation every proxy is upgraded to in {setUp}.
    ConfidentialWrapper internal newImplementation;

    /// @notice Address-keyed underlying deny-list interface config (getter selectors), read by
    /// these tests. Known-denied test vectors live separately in config/blacklist-seeds.json.
    string internal constant DENY_LIST_INTERFACES_PATH = "config/blacklist-interfaces.json";

    /// @dev Valid (non-revoked) confidential wrapper proxies enumerated from the registry.
    address[] internal wrappers;

    function setUp() public virtual override {
        // Deploys the in-process fhEVM host at canonical addresses, sets chainId 31337,
        // and starts recording executor logs into the plaintext DB.
        super.setUp();

        registry = ConfidentialTokenWrappersRegistry(REGISTRY);

        ConfidentialTokenWrappersRegistry.TokenWrapperPair[] memory pairs = registry.getTokenConfidentialTokenPairs();

        for (uint256 i = 0; i < pairs.length; i++) {
            if (!pairs[i].isValid) continue;
            address wrapper = pairs[i].confidentialTokenAddress;
            wrappers.push(wrapper);
        }

        _upgradeAllWrappersToLatest();
    }

    /// @notice Deploys one fresh implementation from repo HEAD and upgrades every enumerated proxy
    /// onto it, so the whole suite exercises the candidate impl against live mainnet state. Each
    /// proxy's pre-upgrade state is snapshotted first for {UpgradeTest}.
    /// @dev Empty `upgradeToAndCall` data is correct while HEAD stays at reinitializer(3) and the
    /// live proxies are already at initialized version 3. When HEAD adds a new reinitializer (V4+),
    /// pass its encoded call as the `data` argument here.
    function _upgradeAllWrappersToLatest() internal {
        newImplementation = new ConfidentialWrapper();
        for (uint256 i = 0; i < wrappers.length; i++) {
            address w = wrappers[i];
            _repointFhevmConfig(w);
            _snapshotPreUpgrade(w);
            _seedPendingUnwrap(w);
            vm.prank(_wrapperOwner(w));
            ConfidentialWrapper(w).upgradeToAndCall(address(newImplementation), "");
        }
    }

    /// @notice Repoints `w`'s FHE config at the in-process forge-fhevm host and zeroes its cached
    /// total-supply handle, so encrypted ops resolve locally instead of at Zama's mainnet coprocessor.
    /// @dev Applied identically to the live warm-up (`make bake`) and the offline run, so the committed
    /// fixture stays pure captured mainnet state and both modes see the same wrapper config. Runs before
    /// {_snapshotPreUpgrade} so the zeroed handle is captured pre-upgrade and {UpgradeTest} still sees it
    /// unchanged after the swap. A mainnet handle has no entry in the local plaintext DB, so zeroing lets
    /// the first local mint/burn rebuild total supply against the in-process executor.
    function _repointFhevmConfig(address w) internal {
        vm.store(w, FHEVM_CONFIG_BASE, bytes32(uint256(uint160(LOCAL_FHEVM_ACL))));
        vm.store(w, bytes32(uint256(FHEVM_CONFIG_BASE) + 1), bytes32(uint256(uint160(LOCAL_FHEVM_COPROCESSOR))));
        vm.store(w, bytes32(uint256(FHEVM_CONFIG_BASE) + 2), bytes32(uint256(uint160(LOCAL_FHEVM_KMS_VERIFIER))));
        vm.store(w, bytes32(uint256(ERC7984_STORAGE_BASE) + 2), bytes32(0));
    }

    /// @notice Writes a pending unwrap request into `w`'s `_unwrapRequests` before the upgrade.
    /// @dev Written raw at the real production slot rather than through `unwrap` to avoid mutating
    /// the shared FHE total-supply state; the sentinel requestId cannot collide with a real handle.
    function _seedPendingUnwrap(address w) internal {
        PreUpgradeSnapshot storage s = preUpgrade[w];
        bytes32 requestId = keccak256(abi.encode("fork-upgrade-test:pending-unwrap", w));
        address recipient = makeAddr(string.concat("pending-unwrap-recipient-", _label(w)));
        bytes32 entrySlot = keccak256(abi.encode(requestId, uint256(WRAPPER_STORAGE_BASE) + 2));
        vm.store(w, entrySlot, bytes32(uint256(uint160(recipient))));
        require(_wrapper(w).unwrapRequester(requestId) == recipient, "seed pending unwrap failed");
        s.pendingUnwrapId = requestId;
        s.pendingUnwrapRecipient = recipient;
    }

    /// @dev Captures the storage-backed getters and raw ERC-7201 slots of `w` before its upgrade.
    function _snapshotPreUpgrade(address w) internal {
        ConfidentialWrapper cw = _wrapper(w);
        PreUpgradeSnapshot storage s = preUpgrade[w];
        s.name = cw.name();
        s.symbol = cw.symbol();
        s.contractUri = cw.contractURI();
        s.decimals = cw.decimals();
        s.underlying = address(cw.underlying());
        s.rate = cw.rate();
        s.owner = _wrapperOwner(w);
        s.maxTotalSupply = cw.maxTotalSupply();
        s.implementation = _implementationOf(w);
        for (uint256 i = 0; i < 6; i++) {
            s.erc7984Slots[i] = vm.load(w, bytes32(uint256(ERC7984_STORAGE_BASE) + i));
        }
        for (uint256 i = 0; i < 3; i++) {
            s.wrapperSlots[i] = vm.load(w, bytes32(uint256(WRAPPER_STORAGE_BASE) + i));
        }
    }

    /// @notice Reads the ERC-1967 implementation address of proxy `w`.
    function _implementationOf(address w) internal view returns (address) {
        return address(uint160(uint256(vm.load(w, IMPL_SLOT))));
    }

    function _wrapper(address w) internal pure returns (ConfidentialWrapper) {
        return ConfidentialWrapper(w);
    }

    function _underlying(address w) internal view returns (IERC20) {
        return IERC20(_wrapper(w).underlying());
    }

    function _wrapperOwner(address w) internal view returns (address) {
        return Ownable(w).owner();
    }

    /// @notice Returns the explicit blacklist interface for `token`, read from the shared
    /// config file (not hardcoded). `supported == false` for tokens with no entry.
    function _underlyingDenyListInterface(
        address token
    ) internal view returns (UnderlyingDenyListInterface memory iface) {
        if (!vm.exists(DENY_LIST_INTERFACES_PATH)) return iface;
        string memory json = vm.readFile(DENY_LIST_INTERFACES_PATH);
        // Foundry JSON cheatcodes are index-addressed here; config tokens are a dense array, so
        // the first missing `.tokens[i]` marks the end.
        for (uint256 i = 0; ; i++) {
            string memory base = string.concat(".tokens[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, base)) break;
            if (vm.parseJsonAddress(json, string.concat(base, ".token")) != token) continue;

            string memory getterSig = vm.parseJsonString(json, string.concat(base, ".getter"));
            iface.getter = bytes4(keccak256(bytes(getterSig)));
            iface.supported = true;
            return iface;
        }
    }

    /// @notice Canonical underlying deny-list getter selector, or `bytes4(0)` if none.
    function _canonicalDenyListSelector(address token) internal view returns (bytes4) {
        return _underlyingDenyListInterface(token).getter;
    }

    /// @notice Funds `user` with the wrapper's underlying and wraps `amount` into confidential tokens.
    function _dealAndWrap(address w, address user, uint256 amount) internal {
        IERC20 underlying = _underlying(w);
        deal(address(underlying), user, underlying.balanceOf(user) + amount);

        vm.startPrank(user);
        _approve(underlying, w, type(uint256).max);
        _wrapper(w).wrap(user, amount);
        vm.stopPrank();
    }

    /// @notice Approves tokens that either return true or return no value, like USDT.
    function _approve(IERC20 token, address spender, uint256 amount) internal {
        (bool success, bytes memory returndata) = address(token).call(
            abi.encodeCall(IERC20.approve, (spender, amount))
        );
        require(success && (returndata.length == 0 || abi.decode(returndata, (bool))), "approve failed");
    }

    /// @notice Decrypts the confidential balance of `account` on wrapper `w`.
    function _decryptBalance(address w, address account) internal returns (uint64) {
        euint64 bal = _wrapper(w).confidentialBalanceOf(account);
        return decrypt(bal);
    }

    /// @notice Decrypts the confidential total supply of wrapper `w`.
    function _decryptTotalSupply(address w) internal returns (uint64) {
        return decrypt(_wrapper(w).confidentialTotalSupply());
    }

    /// @notice Publicly decrypts one euint64 handle and builds the scalar proof finalizeUnwrap expects.
    /// @dev forge-fhevm's publicDecrypt signs abi.encode(uint256[]). finalizeUnwrap verifies
    /// abi.encode(uint64), so use forge-fhevm's public buildDecryptionProof helper with that payload.
    function _publicDecryptEuint64(bytes32 handle) internal returns (uint64 cleartext, bytes memory decryptionProof) {
        _processNewLogs();
        if (!_acl.isAllowedForDecryption(handle)) {
            revert HandleNotAllowedForPublicDecryption(handle);
        }

        cleartext = uint64(_plaintexts[handle]);
        decryptionProof = buildDecryptionProof(handle, abi.encode(cleartext));
    }

    /// @notice Short symbol used in failure labels, falling back to the address.
    function _label(address w) internal view returns (string memory) {
        try _wrapper(w).symbol() returns (string memory s) {
            return s;
        } catch {
            return vm.toString(w);
        }
    }
}
