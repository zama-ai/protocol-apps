# Governance

This document describes how governance works in the Zama Protocol from an operator’s perspective.

## Structure

Governance in the Zama protocol is controlled by the currently elected operators, which itself is subject to change by a governance proposal. All operators have the same voting weight independent of their staking amounts.&#x20;

Governance is implemented by an Aragon DAO on Ethereum, with multisigs controlled by the operators. This means that proposals are voted onchain and (most of them) automatically executed. Interacting with the Aragon DAO is done through the Aragon App or by calling the underlying contracts directly.

The Aragon DAO on Ethereum is set up to own contracts on both Ethereum and the Gateway, using LayerZero in the latter case. All actions for the Gateway are routed through a Gnosis Safe on the Gateway, which, as a backup, can also be used directly as a multisig.

Circuit breakers are furthermore deployed on both Ethereum and the Gateway. Any operator can trigger any of these on their own to pause parts of the protocol, but a governance vote is needed to unpause again.

## Wallets

Each governance operator is expected to have a `GOVERNANCE` address that can be used to approve proposals in the Aragon DAO. This will typically be done using the Aragon App which supports Wallet Connect, but may also be done by interacting directly with the underlying contracts. Expect moderate usage of the wallet, say monthly, and it needs to be funded on Ethereum.

{% hint style="warning" %}
Due to the security sensitive nature of governance, we recommend using a **hardware**, **MPC**, or **multisig wallet**.
{% endhint %}

Each governance operator is expected to have a `GOVERNANCE_SAFE` address that can be used to sign EIP712 messages for the Gnosis Safe in exceptional cases. This may be the same wallet as `GOVERNANCE`, but we leave the option open for it being separate since it is only used in exceptional cases. The wallet does not need to be funded since it is only used for signing.

Each governance operator is expected to have a `PAUSER` address that can be used to trigger the circuit breakers. This address presents a trade-off between being readily available, for instance to anyone who’s on-call, while also being able to potentially cause significant damage if misused. One potential implementation is as a hot wallet kept as a secret in the deployment system. The wallet needs to be funded on both Ethereum and the Gateway. Even if pausing transactions are relatively simply, the wallet should have sufficient funding to have transactions executed even during periods with high gas cost.

## Governance proposal flow

Any operator can create proposals but in practice we expect that Zama will typically do this. Proposals can be created using the Aragon App dashboard or by direct interaction with the governance contracts. All proposals should be announced on Slack. Every governance operator is expected to review shortly afterwards, and act within the deadline set in the proposal.

Voting is typically done through the Aragon App dashboard using the `GOVERNANCE` address. Proposals will typically include actions for calling other contracts, and operators are expected to review these as well. When proposals are accepted, anyone can execute them through the Aragon DAO, and again we expect that Zama will typically do this.

## Governance actions

Below is an expected list of actions that will be taken by governance. Initially we only use one threshold of 2/3, but we will expand with more soon, to be used for less critical tasks. This is noted as "Q4-25 threshold" and "Q1-26 threshold" in the table below.

| Action                           | Q4-25 threshold | Q1-26 threshold | Execution |
| -------------------------------- | --------------- | --------------- | --------- |
| Update contracts                 | 2/3             | 2/3             | Onchain   |
| Update offchain services         | 2/3             | 2/3             | Depends   |
| Elect operators                  | 2/3             | 1/2             | Onchain   |
| Slash operators                  | 2/3             | 2/3             | Onchain   |
| Update the reward rate           | 2/3             | 1/2             | Onchain   |
| Update unstaking cooldown period | 2/3             | 2/3             | Onchain   |
| Pausing                          | 1/n             | 1/n             | Onchain   |
| Unpausing                        | 2/3             | 1/2             | Onchain   |
| Address / contract blocking      | 2/3             | 1/6             | Onchain   |
| Address / contract unblocking    | 2/3             | 1/2             | Onchain   |
| LayerZero re-configuration       | 2/3             | 2/3             | Onchain   |
| Update cryptographic parameters  | 2/3             | 2/3             | None      |
| Resharing the FHE key            | 2/3             | 1/6             | Onchain   |
| Generating new FHE key           | 2/3             | 2/3             | Onchain   |

### Update contracts

New implementations of host and Gateway contracts are deployed directly by Zama, but a governance proposal is used to update the protocol (the proxies) to use them. Operators must verify that the new implementations match the specified release version.

{% hint style="danger" %}
**Some contracts cannot be upgraded**: $ZAMA token, operator staking contracts, pauser contracts
{% endhint %}

### Update offchain services

Some components allow version verification while other do not. When possible, these proposals will included the needed actions to verify versions of offchain services. In all cases must the operator verify that the version matches with the one discussed offchain.

### Elect operators

The set of operators is negotiated offchain, and made effective with a governance proposal. Operators must verify that the proposal updates all the relevant contracts and with the correct set of operator addresses.

### Slash operators

In the rare event than an operator is deviating from the desired behavior of the protocol, a governance proposal can be made to slash (part of) the stake of the operator. Details will be discussed offchain, resulting in a slashing amount. Operators must verify that the correct amount is used, and approve the proposal if they agree with the offence.

### Update the reward rate

The tokens per second rate is used by protocol staking to mint rewards and fees. The value is negotiated offchain, and operator must verify that the correct value is used.

### Update unstaking cooldown period

Determines the unstaking delay for operators and token holders. The value is negotiated offchain, and operator must verify that the correct value is used. Low values risk making slashing less effective, and gives less time to find replacement operators if needed. Note that operator staking shares are transferable, so token holders have alternative means of “unstaking”.

### Pausing

Used to pause the protocol. Any operator on their own can pause in of case of incidents.

### Unpausing

Used to unpause the protocol after it has been paused. Negotiation of when it’s safe to unpause happens offchain by the incident team. Operators must be confident that it is safe to unpause before approving.

### Address / contract blocking

An address can be blocked on host chains if needed. The reasons for this will be discussed on Slack first, and a proposal created to execute.

### Address / contract unblocking

An address can be unblocked on host chains if needed. The reasons for this will be discussed on Slack first, and a proposal created to execute.

### LayerZero re-configuration

In rare cases, we may need to adjust the LayerZero configuration. Details of this will be discussed offchain, including the responsibility of operators. Operators must make sure to understand implication of changes before approving.

### Update cryptographic parameters

Occasionally we may need to update the cryptographic parameters of the protocol, including for the FHE scheme or the MPC threshold protocol. This includes tweaks that improves security and performance. Proposals will likely not include onchain actions, but rather serve as a consensus point, will follow-up software updates.

### Resharing the FHE key

The shares of the FHE secret key may need to be updated once in a while. Approval will trigger a Gateway request to the KMS nodes to execute a resharing.

### Generating new FHE key

The FHE key may need to be renewed once in a while. Approval will trigger a Gateway request to the KMS nodes to re-execute key generation.

## Pausing

Pausing is done using the `PAUSER` address on both Ethereum and the Gateway.

## Using the Gnosis Safe as a backup

Interacting with the Safe only requires offchain signatures from the operators.
