# Confidential Wrapper deploy params entry

> Every ConfidentialWrapper deployment runs from **reviewed, committed inputs** in `contracts/confidential-wrapper/deploy-params/`. Requesting a deployment means opening a PR that adds one entry per wrapper; merging that PR is the sign-off that the values are cleared to deploy. This runbook covers how to source each field and how to submit the entry.
>
> For the bare field reference, see: [`SCHEMA.md`](../../contracts/confidential-wrapper/deploy-params/SCHEMA.md).

---

## Requirements

Before opening a PR, collect the following for each wrapper:

| Input | Where to get it |
| --- | --- |
| `underlying` address (the JSON entry key) | Token issuer / public documentation. Confirm on a block explorer that it is the canonical token on the target chain |
| `symbol` | Convention: `c` + the underlying's `symbol()` |
| `underlyingDenyListSelector` | Underlying token's verified source / ABI. Compute with `cast sig`. Use `0x00000000` if the underlying has no denylist |
| `blockedUsers` | Compliance / legal. Use `[]` if none |
| `initialObservers` | Addresses authorized to decrypt confidential amounts on behalf of the wrapper. Use `[]` if none — see the observer scope warning below |

---

## Where the entry lives

Entries live at `<tier>/<network>/wrappers.json`, keyed by underlying address:

```
contracts/confidential-wrapper/deploy-params/
├── testnet/sepolia/{network,wrappers}.json
└── mainnet/ethereum/{network,wrappers}.json
```

---

## Sourcing each field

### Underlying address (JSON key)

The ERC-20 being wrapped. Each entry is keyed by this address; the deploy workflow `underlying` input selects it directly:

- Each underlying may appear **only once** per network. A duplicate key is a hard error at deploy time.
- Use the checksummed address from the token's own documentation or its verified explorer page.

### `symbol`

The wrapper symbol (e.g. `cUSDT`) 

Convention: `c` + the underlying's `symbol()`.

### `underlyingDenyListSelector`

The `bytes4` selector of the underlying's denylist getter. The wrapper calls it before every wrap, transfer and unwrap to check whether an address is blocked upstream.

> **The selector is token-specific — confirm it against the underlying before submitting.** Each deny-listing token names its getter differently, so read the name off the token's verified source and compute the selector. A selector the token does not implement reverts every wrap, transfer and unwrap until the owner corrects it through a governance call.

```bash
cast sig "getBlackListStatus(address)"   # 0x59bf1abe — USDT
cast sig "isBlacklisted(address)"        # 0xfe575a87 — USDC
```

Foundry must be installed ([docs](https://www.getfoundry.sh)). The
selector is the first 4 bytes of the hash of the function signature.

> **The selector alone carries enablement.** `0x00000000` means "this underlying has no denylist; skip the check"

State in the PR description which function on the underlying you took the selector from.

### `blockedUsers`

Addresses seeded into the wrapper's own denylist at deployment. This is separate from the underlying's denylist, it is the list the wrapper enforces itself. Entries can be added or removed later by the owner.

### `initialObservers`

Addresses authorized to decrypt the confidential amounts the wrapper processes.

> ⚠️ **Seed observers deliberately, and set `[]` when there are none.** Observers can decrypt **every** confidential amount the wrapper processes — balances, total supply, and individual transfer/wrap/unwrap.

### Ownership (not submitted)

The wrapper's `owner` is set to the target network's Protocol DAO (the `dao` entry in `network.json`). It is not part of your entry.

> **Important:** the initial owner must be the Protocol DAO for the target chain, not the deployer. Otherwise governance proposals fail at execution, and correcting ownership requires an additional proposal for the DAO to `acceptOwnership` (`Ownable2StepUpgradeable`).

### `name` and `contractUri` (not submitted)

Both are derived following existing conventions — `name` as `Confidential <underlying symbol()>` (e.g. `Confidential USDC`), and `contractUri` as a `data:` blob built from the name and symbol:

```
data:application/json;utf8,{"name":"...","symbol":"...","description":"..."}
```

If a token needs to deviate from these conventions, raise it in the PR rather than hand-setting the fields.

---

## Submitting the entry

### Step 1 — Add your entry

Edit `<tier>/<network>/wrappers.json` (e.g. `mainnet/ethereum/wrappers.json`), keyed by the underlying address.

All required fields must be present on every entry:

```json
{
  "0xdAC17F958D2ee523a2206206994597C13D831ec7": {
    "symbol": "cUSDT",
    "blockedUsers": [],
    "underlyingDenyListSelector": "0x59bf1abe",
    "initialObservers": []
  }
}
```

### Step 2 — Open a PR

Open a PR against `main` with your changes. In the description, state:

- the token being wrapped and the target network,
- the source for `underlyingDenyListSelector` (which function on the underlying, and the `cast sig` output),
- the source for any `blockedUsers` and `initialObservers`.

### Step 3 — Get it reviewed and merged

Merging says these values are cleared to deploy. Review focuses on the selector matching the underlying's actual source and on the observer list being intentional — both are expensive to correct after deployment.

### Step 4 — Zama dispatches the deploy

The workflow runs against the merged params. You do not need access to it.

### Step 5 — Results land back in the repo

A follow-up PR adds the deployment artifacts and addresses. Registry registration is a separate Protocol DAO governance action.

---

## Pre-PR checklist

- [ ] Entry is keyed by the underlying address, and that key is not already taken on this network
- [ ] `symbol` is set and matches the `c` + underlying `symbol()` convention
- [ ] The underlying address is canonical on the target chain
- [ ] `underlyingDenyListSelector` was computed from the underlying's **verified source**, or is `0x00000000` because the token has no denylist
- [ ] `blockedUsers` is present (`[]` if none)
- [ ] `initialObservers` is present (`[]` if none) and every listed address is intended to decrypt all amounts
- [ ] Entry contains only the required fields — no redundant `underlying`, `owner`, `name` or `contractUri`
- [ ] File is valid JSON and the PR touches nothing else

---

## Related docs

- [`deploy-wrapper-runbook.md`](./deploy-wrapper-runbook.md) — deploying, verifying and registering the wrapper locally
- [`SCHEMA.md`](../../contracts/confidential-wrapper/deploy-params/SCHEMA.md) — field-by-field params reference
