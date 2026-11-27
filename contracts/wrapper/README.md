# wrapper

| Contract | Source |
| --- | --- |
| `ConfidentialWrapper` | `src/wrapper/ConfidentialWrapper.sol` |
| `ERC1967Proxy` | `dependencies/wrapper-deployed-oz-contracts-5.6.1/proxy/ERC1967/ERC1967Proxy.sol` |

## Rebuild

With Foundry 1.7.1, from this directory:

```sh
forge soldeer install
FOUNDRY_PROFILE=wrapper_deployed forge build --skip test --skip script
FOUNDRY_PROFILE=wrapper_deployed forge build dependencies/wrapper-deployed-oz-contracts-5.6.1/proxy/ERC1967/ERC1967Proxy.sol
```

Each contract's `deployedBytecode` then equals the deployed code, immutables aside.
