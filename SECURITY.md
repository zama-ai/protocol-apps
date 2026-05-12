# Security

## Reporting a Vulnerability

If you find a security related bug in fhevm projects, we kindly ask you for responsible disclosure and for giving us
appropriate time to react, analyze and develop a fix to mitigate the found security vulnerability.

To report the vulnerability, please open a draft
[GitHub security advisory report](https://github.com/zama-ai/fhevm/security/advisories/new)

## Development setup

Before running any `npm` or `pnpm` commands locally, install [Aikido safe-chain](https://github.com/AikidoSec/safe-chain), which transparently wraps npm/pnpm/yarn/bun/pip and blocks installation of packages flagged as malicious:

```
curl -fsSL https://github.com/AikidoSec/safe-chain/releases/download/1.5.2/install-safe-chain.sh | sh
```

After installation, **restart your terminal** so the shell aliases load, then verify:

```
npm safe-chain-verify
```

safe-chain is also installed automatically in CI before every dependency-install step.
