# Security

## Reporting a Vulnerability

If you find a security related bug in fhevm projects, we kindly ask you for responsible disclosure and for giving us
appropriate time to react, analyze and develop a fix to mitigate the found security vulnerability.

To report the vulnerability, please open a draft
[GitHub security advisory report](https://github.com/zama-ai/fhevm/security/advisories/new)

## Audit & verification status

Top-level index for the security verification status of contracts in this repository. Each package maintains its own status matrix in `contracts/<package>/audits/README.md`.

### Packages

| Package | Tag prefix | Upgradability | Status matrix |
| ------- | ---------- | ------------- | ------------- |
| Confidential Wrapper | `wrapper` | Upgradable (UUPS) | [`contracts/confidential-wrapper/audits`](./contracts/confidential-wrapper/audits/README.md) |
| Confidential Token Wrappers Registry | `registry` | Upgradable (UUPS) | [`contracts/confidential-token-wrappers-registry/audits`](./contracts/confidential-token-wrappers-registry/audits/README.md) |
| Staking | `staking` | Mixed | [`contracts/staking/audits`](./contracts/staking/audits/README.md) |
| Governance | `governance` | Immutable | [`contracts/governance/audits`](./contracts/governance/audits/README.md) |
| Token (EVM) | `token` | Immutable | [`contracts/token/audits`](./contracts/token/audits/README.md) |
| Solana OFT | `solanaOFT` | Immutable | [`contracts/solanaOFT/audits`](./contracts/solanaOFT/audits/README.md) |
| Fees Burner | `fees` | Immutable | [`contracts/feesBurner/audits`](./contracts/feesBurner/audits/README.md) |
| Pauser Set Wrapper | `pauserSetWrapper` | Immutable | [`contracts/pauserSetWrapper/audits`](./contracts/pauserSetWrapper/audits/README.md) |
| Safe (Admin Module) | `safe` | Immutable | [`contracts/safe/audits`](./contracts/safe/audits/README.md) |

### Conventions

#### Git tags

Each package uses its own scoped semver tag: `<prefix>-vX.Y.Z`. See the Tag prefix column above.

- For **upgradable** contracts, a tag is a candidate source snapshot for a proxy upgrade; the matching row in the package's status matrix is filled in once the tag has been audited and/or deployed.
- For **immutable** contracts, a tag is the source snapshot for a specific on-chain deployment.

#### Verification tracks

Columns used in each package's status matrix:

- **Pre-deploy audit** — external audit on the source contracts and deployment scripts before deployment.
- **Post-deploy audit** — external review of the deployed bytecode, configuration, and state against the audited source.
- **Fuzzing and invariants** — property-based fuzzing and invariant tests run against the release.

#### Status

Each row in a package's status matrix carries a **Status** value indicating where that tag sits in its lifecycle:

- **Upcoming** — tag is planned or in audit, not yet deployed.
- **Active** — tag is the currently deployed source for at least one chain.
- **Sunset** — tag has been superseded by a later version and is no longer the active deployment.

#### Deployed addresses

See [`docs/addresses/`](./docs/addresses/README.md) for the current on-chain addresses of each package across all supported chains.
