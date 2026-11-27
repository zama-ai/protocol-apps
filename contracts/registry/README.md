# registry

| Contract | Source |
| --- | --- |
| `ConfidentialTokenWrappersRegistry` | `src/registry/ConfidentialTokenWrappersRegistry.sol` |
| `ERC1967Proxy` | `dependencies/registry-deployed-oz-contracts-5.4.0/proxy/ERC1967/ERC1967Proxy.sol` |

## Rebuild

With Foundry 1.7.1, from this directory:

```sh
forge soldeer install
FOUNDRY_PROFILE=registry_deployed forge build --skip test --skip script
FOUNDRY_PROFILE=registry_deployed forge build dependencies/registry-deployed-oz-contracts-5.4.0/proxy/ERC1967/ERC1967Proxy.sol
```

Each contract's `deployedBytecode` then equals the deployed code, immutables aside.
