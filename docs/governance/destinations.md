# Cross-Chain Governance Destinations

The Protocol DAO on Ethereum can execute governance actions on multiple EVM
destination chains. Each destination has its own one-way pipeline:

```
Aragon DAO (Ethereum)
  └─ sendRemoteProposal → GovernanceOAppSender (Ethereum, one per destination)
       └─ LayerZero → GovernanceOAppReceiver (destination)
            └─ AdminModule.executeSafeTransactions → destination multisig (Safe)
                 └─ executes the target calls
```

There is **one `GovernanceOAppSender` per destination** on the source chain
(Ethereum mainnet / Sepolia). A proposal's `to` is the sender for the chosen
destination; the tooling runs `eth_estimateGas` against the destination chain
with the destination multisig as the (unsigned) `from` to size the LayerZero
execution gas.

## Destination registry

The scripts only need a few fields per destination — the `GovernanceOAppSender`,
the destination multisig and the RPC — and those live in
[`scripts/governance-proposal-builder/destinations.js`](../../scripts/governance-proposal-builder/destinations.js)
(run `node destinations.js` / `npm run list-destinations` to print them). All
other per-destination data (LZ EID, `EndpointV2`, block explorer, receiver /
module addresses, …) lives in the
[protocol-registry](https://github.com/zama-ai/protocol-registry) repo — the
source of truth; always re-verify addresses there. (protocol-registry publishes
mainnet/testnet only; devnet addresses come from the devnet deployment.) The
table below combines both for convenience.

| Destination id | Chain | Env | `GovernanceOAppSender` (source) | Destination multisig | RPC env var | LZ EID | Explorer |
|---|---|---|---|---|---|---|---|
| `gateway-mainnet` | Zama Gateway | mainnet | `0x1c5D750D18917064915901048cdFb2dB815e0910` | `0x5f0F86BcEad6976711C9B131bCa5D30E767fe2bE` | `RPC_GATEWAY_MAINNET` | 30397 | https://explorer.mainnet.zama.org |
| `gateway-testnet` | Zama Gateway | testnet | `0x909692c2f4979ca3fa11B5859d499308A1ec4932` | `0x3241b3A4036a356c5D7e36a432Da2B8e5739D9c9` | `RPC_GATEWAY_TESTNET` | 40424 | https://explorer.testnet.zama.org |
| `gateway-devnet` | Zama Gateway (devnet, on the testnet chain) | devnet | `0x369CDAD997981C06aa02f82b74564C1F4A4D36ae` | `0xb8E03De46F3539aEA7FEb072eEAE6A8f4A14913B` | `RPC_GATEWAY_DEVNET` | 40424 | https://explorer.testnet.zama.org |
| `amoy-testnet` | Polygon Amoy | testnet | `0xe57ea2f14f3051296d3965Bae8caAF86acdd6050` | `0xF0b1FE5DecfFe400fb141BBEAF9B181bCF76E3Cb` | `RPC_AMOY_TESTNET` | 40267 | https://amoy.polygonscan.com |

> The LZ EID and the destination's `EndpointV2` address (needed only for
> [manual execution recovery](manual-execution-remote.md)) are **not** used by
> the fill/decode scripts — the authoritative EID lives in the on-chain sender.
> Known `EndpointV2` addresses: Gateway mainnet =
> `0x6F475642a6e85809B1c36Fa62763669b1b48DD5B`; Polygon Amoy =
> `0x6EDCE65403992e310A62460808c4b910D972f10f` (the shared LayerZero V2 testnet
> endpoint). For any other destination look it up in the
> [LayerZero deployments](https://docs.layerzero.network/v2/deployments/deployed-contracts)
> or the [protocol-registry](https://github.com/zama-ai/protocol-registry) repo.

> **Polygon mainnet** governance is coming soon (the LayerZero config already
> exists in the contracts). A `polygon-mainnet` destination will be added here
> once its sender/receiver/multisig are deployed and published to
> protocol-registry.

## Adding a new EVM destination

The on-chain contracts (`GovernanceOAppSender` on Ethereum,
`GovernanceOAppReceiver` + `AdminModule` + multisig on the destination, and the
LayerZero peers) must already be deployed and wired. Then, to make the tooling
and runbooks cover the new chain — **no script code changes required**:

1. Add an entry to `scripts/governance-proposal-builder/destinations.js` with
   just the script fields: `displayName`, the deployed `oappSender`,
   `destinationExecutor` (multisig), `rpcEnvVar` and `defaultRpc`. (The LZ EID,
   `EndpointV2`, explorer, etc. belong in protocol-registry, not here.)
2. Add the matching RPC variable to `.env.example`.
3. Add a row to the table above (pulling the reference columns from protocol-registry).
4. Smoke-test with a no-op proposal:
   `npm run fill-options-remote-proposal -- --destination <id>`.

No per-destination template is needed — the single minimal input file
(`remote-proposal-temp.example.json`) works for every destination; the script
fills the per-destination `to` from the registry.
