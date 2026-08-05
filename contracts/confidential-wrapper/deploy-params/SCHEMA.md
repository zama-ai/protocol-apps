# Deploy params schema

Reviewed, source-of-truth inputs for the `contracts-confidential-wrapper-deploy`
workflow. How to submit a change: [README.md](./README.md).

## Layout

`<tier>/<network>/`, where **tier** = `testnet` | `mainnet` and **network** = the
Hardhat network name / chain (`sepolia`, `ethereum`, …). The directory is the source
of truth for the tier↔network mapping.

```
deploy-params/
├── testnet/sepolia/{network,wrappers}.json    # network.json: chainId, DAO, registry, …
└── mainnet/ethereum/{network,wrappers}.json
```

## `network.json`

| Field                   | Meaning                                                            |
| ----------------------- | ------------------------------------------------------------------ |
| `chainId`               | Expected chain id; preflight fails on mismatch                     |
| `dao`                   | Protocol DAO — the default wrapper `owner` |
| `registry`              | `ConfidentialTokenWrappersRegistry` address                        |
| `minDeployerBalanceWei` | Preflight min deployer balance (string wei)                        |

## `wrappers.json`

`{ wrapperSymbol: entry }` — keyed by the wrapper symbol (e.g. `cUSDT`); the wrapped token is the `underlying` field (no separate `symbol` field). 

The `name` and `contractUri` are derived following existing conventions, and `owner` is set to the `dao` entry in `network.json`.

The following fields are required:

| Field                        | Type      | Notes                                                                                     |
| ---------------------------- | --------- | ----------------------------------------------------------------------------------------- |
| `underlying`                 | address   | The ERC-20 being wrapped (looked up by the deploy dispatch); each underlying appears once |
| `blockedUsers`               | address[] | Seeded into the denylist; `[]` if none                                                    |
| `underlyingDenyListSelector` | bytes4    | `0x00000000` disables the check; a non-zero selector enables it                           |
| `initialObservers`           | address[] | Seeded V4 observers; `[]` if none                                                         |

Minimal entry:

```json
{
  "cUSDT": {
    "underlying": "0x9b5Cd13b8eFbB58Dc25A05CF411D8056058aDFfF",
    "blockedUsers": [],
    "underlyingDenyListSelector": "0x00000000",
    "initialObservers": []
  }
}
```
