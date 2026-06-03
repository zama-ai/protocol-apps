# Governance Runbooks

Operational runbooks for creating, reviewing, and managing governance proposals on the Protocol DAO (Aragon-based, on Ethereum mainnet and Sepolia testnet).

## Quickstart Guides

Start here depending on your role:

| # | Guide | Audience | Description |
|---|-------|----------|-------------|
| 1 | [Quickstart: Creator](quickstart-creator.md) | Proposal authors | Step-by-step to submit an Ethereum or cross-chain Gateway proposal. |
| 2 | [Quickstart: Reviewer](quickstart-reviewer.md) | DAO members & code owners | Step-by-step to verify a proposal via UI and CLI before signing. |

## Detailed Runbooks

For the full procedures with screenshots, edge cases, and troubleshooting:

| # | Runbook | Description |
|---|---------|-------------|
| 3a | [Creating Ethereum Proposals](creating-proposals-ethereum.md) | Full guide for creating Ethereum proposals via the Aragon frontend (wallet setup, actions, simulation). |
| 3b | [Creating Gateway Proposals](creating-proposals-gateway.md) | Full guide for cross-chain Gateway proposals (with the `governance-proposal-builder` script) and tracking cross-chain status. |
| 4 | [Reviewing Proposals](reviewing-proposals.md) | Full guide for UI-based review (proxied contracts, magic constants, cross-chain actions) and independent CLI verification with the `aragon-proposal-inspector`. Includes worked examples. |
| 5 | [Manual Execution: Gateway](manual-execution-gateway.md) | Recovery procedure when a cross-chain proposal was approved and executed on Ethereum but delivery to Gateway failed (manually calling `lzReceive`). |

## Reference

| # | Document | Description |
|---|----------|-------------|
| 6 | [CLI Reference](cli-reference.md) | Complete reference for `fill-options-gateway-proposal`, `decode-options-gateway-proposal`, and `aragon-proposal-inspector` (installation, usage, inputs/outputs, common errors). |

## Typical Workflow

```
Creator                          Reviewer                          Anyone
───────                          ────────                          ──────
1. Read creator runbooks
2. Create proposal via Aragon frontend
3. Submit proposal
4. Notify reviewers
  - First code owners
  - Then DAO members
                                 5. Read reviewer runbooks
                                 6. Verify via Aragon frontend
                                 7. Verify via CLI inspector
                                 8. (DAO member only) Sign 
                                    proposal in wallet
                                                                  9. (In case of failure)
                                                                     Execute lzReceive
                                                                     on Gateway manually
                           
```
