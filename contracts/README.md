# v3.1.0

Adds ConfidentialHooklessWrapper and ConfidentialOAVWrapper.

The sources of the contracts deployed from this release.

| Contract | Source |
| --- | --- |
| `ConfidentialHooklessWrapper` | `src/wrapper/ConfidentialHooklessWrapper.sol` |
| `ConfidentialOAVWrapper` | `src/wrapper/ConfidentialOAVWrapper.sol` |
| `ConfidentialWrapper` | `src/wrapper/ConfidentialWrapper.sol` |
| `ERC1967Proxy` | `dependencies/@openzeppelin-contracts-5.1.0/proxy/ERC1967/ERC1967Proxy.sol` |

## Rebuild

With Foundry 1.7.1:

```sh
forge soldeer install
FOUNDRY_PROFILE=default forge build --skip test --skip script
FOUNDRY_PROFILE=default forge build dependencies/@openzeppelin-contracts-5.1.0/proxy/ERC1967/ERC1967Proxy.sol
```

Each contract's `deployedBytecode` then equals the deployed code, immutables aside.
