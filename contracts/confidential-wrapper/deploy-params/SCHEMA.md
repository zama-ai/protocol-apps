# Deploy params schema

Reviewed, source-of-truth inputs for the `contracts-confidential-wrapper-deploy`
workflow. How to submit a change: [deploy params entry runbook](../../../docs/deployment/deploy-wrapper-param-entry-runbook.md).

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

`{ underlyingAddress: entry }` — keyed by the underlying ERC-20 address (e.g. `0xdAC17F…`).
The deploy dispatch `underlying` input selects the entry; `symbol` on the entry drives
deployment artifact names (`ConfidentialWrapper_<symbol>_Proxy`, etc.).

The `name` and `contractUri` are derived following existing conventions, and `owner` is set to the `dao` entry in `network.json`.

The following fields are required on every entry:

| Field                        | Type      | Notes                                                                                     |
| ---------------------------- | --------- | ----------------------------------------------------------------------------------------- |
| `symbol`                     | string    | Wrapper symbol (e.g. `cUSDT`); used for artifact filenames, not the JSON key              |
| `blockedUsers`               | address[] | Seeded into the denylist; `[]` if none                                                    |
| `underlyingDenyListSelector` | bytes4    | `0x00000000` disables the check; a non-zero selector enables it                           |
| `initialObservers`           | address[] | Seeded V4 observers; `[]` if none                                                         |

Minimal entry:

```json
{
  "0x9b5Cd13b8eFbB58Dc25A05CF411D8056058aDFfF": {
    "symbol": "cUSDT",
    "blockedUsers": [],
    "underlyingDenyListSelector": "0x00000000",
    "initialObservers": []
  }
}
```
