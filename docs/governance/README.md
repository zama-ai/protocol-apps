# Governance Runbooks

Operational runbooks for creating, reviewing, and managing governance proposals on the Protocol DAO (Aragon-based, on Ethereum mainnet and Sepolia testnet).

| # | Runbook | Description |
|---|---------|-------------|
| 1a | [Creating Ethereum Proposals](creating-proposals-ethereum.md) | Full guide for creating Ethereum proposals via the Aragon frontend (wallet setup, actions, simulation). |
| 2b | [Creating Gateway Proposals](creating-proposals-gateway.md) | Full guide for cross-chain Gateway proposals (with the `governance-proposal-builder` script) and tracking cross-chain status. |
| 3 | [Reviewing Proposals](reviewing-proposals.md) | Full guide for UI-based review (proxied contracts, magic constants, cross-chain actions) and independent CLI verification with the `aragon-proposal-inspector`. Includes worked examples. |
| 4 | [Manual Execution: Gateway](manual-execution-gateway.md) | Recovery procedure when a cross-chain proposal was approved and executed on Ethereum but delivery to Gateway failed (manually calling `lzReceive`). |

## Reference

| # | Document | Description |
|---|----------|-------------|
| 5 | [CLI Reference](cli-reference.md) | Complete reference for `fill-options-gateway-proposal`, `decode-options-gateway-proposal`, and `aragon-proposal-inspector` (installation, usage, inputs/outputs, common errors). |

## Typical Workflow

```
Creator                          Reviewer                          Anyone
───────                          ────────                          ──────
1. Read creator runbooks
2. Create a community forum post
3. Create proposal via Aragon frontend
4. Submit proposal
5. Notify reviewers
  - First code owners
  - Then DAO members
                                 6. Read reviewer runbooks
                                 7. Verify via Aragon frontend
                                 8. Verify via CLI inspector
                                 9. (DAO member only) Sign 
                                    proposal in wallet
                                                                  10. (In case of failure)
                                                                     Execute lzReceive
                                                                     on Gateway manually
                           
```
