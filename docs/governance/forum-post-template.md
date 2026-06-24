# Forum Post Template: New DAO Proposal

Use this template to draft a community forum post that presents a new DAO proposal and gives reviewers the context they need for reviewing it.

For how to create and review the on-chain proposal itself, see [Quickstart: Creator](quickstart-creator.md) and [Quickstart: Reviewer](quickstart-reviewer.md).

## How to use this template

1. Copy everything below the `---` line into a new forum post.
2. Fill in every section. If a section does not apply, write "N/A" and say why — don't delete it.
3. Keep it concise but complete: a reviewer should be able to understand and verify the proposal from this post plus the on-chain actions alone.

---

# [Proposal ID] - [Proposal Title]

<!-- A short, descriptive title. Match the Title used in the on-chain Aragon proposal. -->

## Summary

<!-- 2-4 sentences. What does this proposal do, and what is the outcome if it passes? Someone should grasp the gist from this section alone. -->

## Motivation & Context

<!-- Why is this needed now? What problem does it solve, or what opportunity does it capture? Link to any prior discussion, RFC, incident, or audit that prompted it. -->

## Proposed Changes

<!-- What exactly will happen on-chain if this passes. List each action: target contract, function called, and key arguments, in plain language. Note whether it targets Ethereum mainnet, the Gateway (cross-chain), or testnet. -->

- **Action 1:** [contract / function / args + what it does]
- **Action 2:** ...

## Technical Details

<!-- For reviewers verifying the proposal. Fill in what applies: -->

- **Network:** [Ethereum mainnet / Gateway / Sepolia testnet]
- **Target contract(s) & addresses:** [list addresses; note where they are documented — e.g. protocol-registry]
- **Magic constants / encoded data:** [e.g. for upgrades, `cast calldata "reinitializeV2()"` = 0x...]
- **Cross-chain:** [if `sendRemoteProposal`, note the destination and how to track delivery (LayerZeroScan)]
- **Code / PR references:** [links to the relevant code, PR, or commit]

## Other considerations

<!-- Other considerations that are important for the reviewer to consider. -->

## Resources

<!-- Links: RFC, audits, related proposals, docs, discussions. -->

-
