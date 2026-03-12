# Staking

The Zama Protocol uses a Delegated Proof of Stake (DPoS) system to help secure the network and provide an incentive layer for operators. $ZAMA token holders can delegate their tokens to eligible operators who manage the network's critical infrastructure, including Key Management Service (KMS) nodes and Fully Homomorphic Encryption (FHE) coprocessors.

The protocol uses two distinct yet structurally identical staking ecosystems for the KMS and coprocessor operators. Tokens delegated to a KMS operator only earn from the KMS reward pool and are governed by the specific KMS staking contracts, while tokens delegated to a coprocessor operator earn from the coprocessor reward pool and are governed by the coprocessor staking contracts.

Staking rewards are funded by protocol inflation at a rate set by the Protocol DAO governance (see [protocol governance](governance.md)). A single rate is set by governance which is then applied proportionally to the KMS and coprocessor staking contracts, with the KMS operators receiving 60% of the rewards and the coprocessor operators receiving the remaining 40%. For each operator staking contract, the rewards are then distributed to the delegators based on the weight of their shares, and the operator receives a commission fee on these rewards as their payment for running a node. A slashing mechanism is in place to penalize operators for misbehavior.

## Terminology

* **Protocol Staking Contract**: The root contract in the hierarchy where operators stake $ZAMA on the protocol.
* **Operator Staking Contract**: A contract deployed per operator that pools $ZAMA from the operator and their delegators to stake in the Protocol Staking contract.
* **Operator Rewarder Contract**: A contract associated with each Operator Staking contract, responsible for distributing staking rewards and commission fees to delegators and operators, respectively.
* **Operator**: An entity that runs at least one Zama Protocol node (KMS or Coprocessor) and receives staking commission fees in compensation. More info about operators in the [litepaper](https://docs.zama.org/protocol/zama-protocol-litepaper#components).
* **Delegator**: A token holder who delegates their $ZAMA into an Operator Staking contract to earn staking rewards.
* **Beneficiary**: The address authorized by an operator to manage their Operator Rewarder contract (e.g., set commission rates, claim and receive accumulated fees).
* **Staking Rewards**: Yields accumulated in the Protocol Staking contract that are distributed to delegators through the Operator Rewarder contract.
* **Commission Fee**: The percentage cut of the Staking Rewards taken by the operator as payment for their services. The commission fee is set by the operator and can be set to a maximum of 20%.
* **Owner**: The owner of all staking contracts, holding several administrative rights. For mainnet, the owner is the Protocol DAO governance (see [protocol governance](governance.md)).

## Contract addresses

All deployed staking contract addresses can be found in the [ethereum addresses directory](addresses/mainnet/ethereum.md) for mainnet and the [sepolia addresses directory](addresses/testnet/sepolia.md) for testnet.

## Overview

Staking in the Zama protocol happens in a two level hierarchy:

* Operators stake $ZAMA on the protocol
* Token holders delegate $ZAMA to operators to stake on their behalf

Anyone can stake on the protocol, but only the elected operators receive commission fees, and only the delegators on elected operators receive staking rewards. Operators are chosen multiple times per year via governance and have a responsibility to participate in the daily execution of the protocol.

{% hint style="success" %}
All staking happens on Ethereum. Only non-confidential $ZAMA is supported for now.
{% endhint %}

### Structure

The hierarchy is implemented by a [protocol staking contract](#contract-protocolstaking) and an [operator staking contract](#contract-operatorstaking). The protocol staking contract is at the root, and one operator staking contract is deployed per operator. An accompying [operator rewarder contract](#contract-operatorrewarder) is deployed for each operator staking contract, and this rewarder contract is responsible for paying out commission fees and staking rewards.

```mermaid
flowchart TB
    ProtocolStaking --- OperatorStaking-A --- OperatorRewarder-A
    ProtocolStaking --- OperatorStaking-B --- OperatorRewarder-B
```

### Staking and delegating

The operator staking contracts are used by token holders to delegate $ZAMA on the protocol, and token holders may delegate to multiple operator staking contracts at the same time.

```mermaid


flowchart BT
    OperatorStaking-A -- stake $ZAMA --> ProtocolStaking
    Delegator-1 -- delegate $ZAMA --> OperatorStaking-A
    Delegator-2 -- delegate $ZAMA --> OperatorStaking-A
```

In return, the operator staking contract obtains [protocol staking shares](#protocol-staking-token), and the delegator obtains [operator staking shares](#operator-staking-token). The operator staking shares use the `$stZAMA-OperatorName-Network` naming convention. In the diagram below these are `$stZAMA` and `$stZAMA-Zama-KMS`, respectively.

```mermaid
flowchart TB
    ProtocolStaking -. $stZAMA .-> OperatorStaking-A
    OperatorStaking-A -. $stZAMA-Zama-KMS .-> Delegator-1
    OperatorStaking-A -. $stZAMA-Zama-KMS .-> Delegator-2
```

The operator staking shares are liquid and unique for each operator staking contract, while the protocol staking shares are not liquid, meaning they can only be redeemed for $ZAMA by the operator staking contract.

### Fees and rewards

The protocol staking contracts are continuously distributing staking rewards to the operator staking contracts. Operators are entitled to a commission fee on the rewards, and the rest is distributed to the delegators. All commission fees and staking rewards are paid in $ZAMA.

```mermaid


flowchart TB
    ProtocolStaking -. rewards .-> OperatorStaking-A
    OperatorStaking-A -. fees .-> Operator-A
    OperatorStaking-A -. rewards minus fees .-> Delegator-1
    OperatorStaking-A -. rewards minus fees .-> Delegator-2
```

The commission fee percentage is independently set (within the maximum allowed by [Protocol DAO governance](governance.md)) for each operator staking contract by the assigned operator.

## Quick Start

{% hint style="info" %}

Many common staking operations can be performed through the Zama staking dashboard. See the [Zama apps](./apps.md) page.

{% endhint %}

### Delegate $ZAMA

Delegating $ZAMA to an operator is a two-step process. First, you must approve the operator's staking contract to spend your tokens, and then you call the `deposit` function to mint shares.

```solidity
// 1. Approve the OperatorStaking contract to spend your $ZAMA

bool approvalSuccess = zamaToken.approve(operatorStakingAddress, amountToDelegate);

// 2. Deposit (Delegate) the $ZAMA

// amountToDelegate: amount of assets to deposit.
// receiver: address to receive the minted shares.
// shares: amount of shares minted.

uint256 shares = operatorStaking.deposit(amountToDelegate, receiver);
```

### Claim staking rewards

First, fetch the `OperatorRewarder` contract from the `OperatorStaking` address:

```solidity
address rewarderAddress = operatorStaking.rewarder();
```

Once you have the `OperatorRewarder` address, you can call `claimRewards(receiver)` to claim your pending rewards. All rewards are paid out in $ZAMA tokens directly to the receiver.

```solidity
IOperatorRewarder(rewarderAddress).claimRewards(receiver);
```

#### Set rewards claimer

A **claimer** is an address authorized to invoke the `claimRewards` function on behalf of a delegator. This role is useful for delegators who wish to transfer the responsibility of claiming rewards to another address without compromising security. For example, a delegator may set a smart contract as the claimer that automatically claims rewards as part of a broader yield strategy.

A delegator can have only one authorized claimer at any given time. If no claimer is explicitly set, the delegator address is considered its own authorized claimer by default.

To authorize an address to claim rewards on your behalf, call `setClaimer` on the `OperatorRewarder` contract with the address you wish to authorize to claim your rewards:

```solidity
IOperatorRewarder(rewarderAddress).setClaimer(claimerAddress);
```

### Claim commission fees

Operators can claim their accumulated commission fees from their `OperatorRewarder` contract. Only the [beneficiary](#operatorrewarder-beneficiary) set in the contract can claim the fees, and the fees are sent directly to the beneficiary.

```solidity
IOperatorRewarder(rewarderAddress).claimFee();
```

### Redeem shares

Redeeming from operator staking contracts is a two-step process subject to a cooldown period (determined by the protocol staking contract). The period is currently set to 7 days on mainnet (3 minutes on testnet) and is updatable by the owner. Note that operator staking contract shares are transferable (as ordinary ERC20), and hence offer an alternative “withdrawal" process without being subject to the cooldown period.

Note that all operator staking shares use 20 decimals. See [Operator Staking decimals](#operator-staking-decimals) for more information.

```solidity
// 1. Request redeem

// shares: amount of shares to redeem.
// controllerAddress: the address that will manage this withdrawal (usually msg.sender)
// ownerAddress: the owner of the shares.
// releaseTime: the timestamp when the assets will be available for withdrawal.

uint48 releaseTime = operatorStaking.requestRedeem(shares, controllerAddress, ownerAddress);

// Wait for the cooldown period to pass

// 2. Redeem

// shares: amount of shares to redeem (use max uint256 for all claimable).
// receiverAddress: the address to receive the assets.
// controllerAddress: the same address used in step 1.

uint256 assetsReceived = operatorStaking.redeem(shares, receiverAddress, controllerAddress);
```

## Contract: ProtocolStaking

The `ProtocolStaking` contract acts as the root of the hierarchy where operators stake their pooled $ZAMA.

### Protocol Staking token

The `ProtocolStaking` contract issues a share token to acknowledge the amount of $ZAMA staked by an operator. There are two separate protocol staking tokens, one for each of the deployed KMS and coprocessor `ProtocolStaking` contracts:

* `$stZAMA-KMS`
* `$stZAMA-Coprocessor`

These tokens use 18 decimals and are non-transferable.

### Protocol Staking functions

#### Manage eligible accounts

Manages which operator pools are currently eligible to earn global rewards from the protocol.

```solidity
protocolStaking.addEligibleAccount(operatorAddress);
protocolStaking.removeEligibleAccount(operatorAddress);
```

#### Set reward rate

Adjusts the global tokens-per-second reward rate distributed among all eligible pools.

```solidity
protocolStaking.setRewardRate(newRewardRate);
```

#### Set unstake cooldown period

Updates the mandatory waiting period between unstaking and releasing tokens.

```solidity
protocolStaking.setUnstakeCooldownPeriod(newCooldownPeriod);
```

### Events

| Event | Description |
| ----- | ----------- |
| `RewardRateSet(rewardRate)` | Emitted when the global token rewards rate is updated. |
| `RewardsClaimed(account, recipient, amount)` | Emitted when an operator pool claims rewards. |
| `RewardsRecipientSet(account, recipient)` | Emitted when a staker's reward recipient is updated. |
| `TokensReleased(recipient, amount)` | Emitted when tokens are released to a recipient after the unstaking cooldown period. |
| `TokensStaked(account, amount)` | Emitted when $ZAMA is staked into the protocol. |
| `TokensUnstaked(account, amount, releaseTime)` | Emitted when an unstake is requested, initiating the cooldown. |
| `UnstakeCooldownPeriodSet(unstakeCooldownPeriod)` | Emitted when the owner adjusts the unstaking waiting period. |

### Errors

| Error | Cause |
| ----- | ----- |
| `InvalidEligibleAccount(account)` | The zero address was attempted to be added to the eligible accounts list. |
| `InvalidUnstakeCooldownPeriod()` | The requested cooldown period is invalid. |
| `TransferDisabled()` | An attempt was made to transfer to or from the zero address. |

## Contract: OperatorStaking

The `OperatorStaking` contract serves as a dedicated staking pool for a specific network operator. It enables delegators to pool their $ZAMA tokens, which are then collectively staked into the `ProtocolStaking` contract to earn rewards.

### Operator Staking token

Each operator has their own `OperatorStaking` instance, acting as an [ERC4626](https://eips.ethereum.org/EIPS/eip-4626)-compliant vault. When users delegate $ZAMA, they receive operator-specific staking shares representing their proportional ownership of the pool's assets and future rewards. These token shares are fully transferable and use 20 decimals. 

#### Operator Staking decimals

To mitigate the well-known ERC4626 inflation attack, the `OperatorStaking` contract implements a decimal offset of 2. This means that 1 unit of the underlying asset is represented as 100 units of shares. 

Because the underlying staked asset ($ZAMA) has 18 decimals, the resulting operator staking shares will always possess 20 decimals. When interacting with the contracts or calculating balances, it is important to remember this distinction. 

For example, when looking at the total stake of a pool or calculating historical rewards across different contracts:
* Calling `totalSupply()` on an `OperatorStaking` contract returns the total pool shares in the form of virtual shares. If the value returned is **100 * 10^20**, this equates to 100 `$stZAMA-Zama-KMS` shares because the shares use 20 decimals.

### Operator eligibility

It is important to note that only _eligible_ operator staking contracts generate rewards. Requesting eligibility is a manual process ending with a protocol governance proposal. As part of the process, operators are asked to run certain off-chain services to participate in the execution of the protocol.

Any operator who’s operator staking contract has staked sufficiently on the protocol can ask to be considered eligible at the next operator election.

### The controller

`OperatorStaking` decouples share ownership from withdrawal management. This is handled via the **controller** role.

Every redemption request is tracked against a controller address rather than the share owner. This allows a user to delegate the administrative task of "watching the cooldown" to a separate address (like a hot wallet or a bot) without giving that address full control over their shares.

A controller can further delegate their power by calling `setOperator()`. An authorized operator can call the `redeem()` function on behalf of the controller.

### Operator Staking functions

#### Stake excess

Restakes any excess liquid $ZAMA held by the `OperatorStaking` contract back into the `ProtocolStaking` contract. Excess tokens can accumulate from direct $ZAMA donations or transfers to the contract, or from unredeemed slashed positions.

```solidity
operatorStaking.stakeExcess();
```

#### Delegate with permit

Allows a user to approve and deposit $ZAMA in a single transaction using an [EIP-2612](https://eips.ethereum.org/EIPS/eip-2612) permit signature.

```solidity
operatorStaking.depositWithPermit(assets, receiver, deadline, v, r, s);
```

#### Authorize redemption operator

Allows a controller to authorize an address to request or release redemptions on their behalf.

```solidity
// msg.sender (the controller) authorizes operatorAddress
operatorStaking.setOperator(operatorAddress, true);
```

#### Check claimable redemption

Returns the amount of assets that are currently eligible for redemption after the cooldown period has passed.

```solidity
uint256 claimable = operatorStaking.claimableRedeemRequest(controllerAddress);
```

### Events

| Event | Description |
| ----- | ----------- |
| `OperatorSet(controller, operator, approved)` | Emitted when an operator approval is set for a controller. |
| `RedeemRequest(controller, owner, sender, shares, assets, releaseTime)` | Emitted when a user requests to redeem shares. |
| `RewarderSet(oldRewarder, newRewarder)` | Emitted when the rewarder contract is changed. |

### Errors

| Error | Cause |
| ----- | ----- |
| `CallerNotProtocolStakingOwner(caller)` | The caller is not the owner of the contract. |
| `InvalidController()` | The controller address is zero. |
| `InvalidRewarder(rewarder)` | The new rewarder address is invalid. |
| `InvalidShares()` | The number of shares to redeem or request redemption is zero. |
| `NoExcessBalance(liquidBalance, assetsPendingRedemption)` | The liquid asset balance is insufficient to cover pending redemptions in `stakeExcess()`. |
| `Unauthorized()` | The caller to the redeem function is not the controller or an operator set by the controller. |

## Contract: OperatorRewarder

The `OperatorRewarder` handles the distribution of rewards and the claiming of operator commission fees. Every `OperatorStaking` pool has one corresponding `OperatorRewarder` contract.

### OperatorRewarder beneficiary

The beneficiary of an `OperatorRewarder` contract is the address that can set and claim fees. The beneficiary is set on the deployment of the `OperatorRewarder` contract and can be changed by the owner through the `transferBeneficiary(address newBeneficiary)` function.

To find the beneficiary of an `OperatorRewarder` contract, you can use the `beneficiary()` view function.

An `OperatorRewarder` beneficiary has the authority to change the fee percentage for the associated contract through the `setFee(uint16 basisPoints)` function. The fee percentage is set in basis points, where 10000 is 100%. Note that fees are subject to a maximum of 20% (2000 basis points) set by the owner.

If an operator wants to receive "regular" staking rewards in addition to their commission fee, they can simply act as a delegator by staking assets into their own `OperatorStaking` contract. They would then receive both:
* The **Commission Fee** on the pool's total generated rewards.
* The **Proportional Reward** for the assets they personally staked.

### Operator Rewarder functions

#### Get fee basis points

Returns the current commission fee percentage.

```solidity
// Returns the current fee in basis points (e.g., 1000 = 10%)
uint16 currentFee = operatorRewarder.feeBasisPoints();
```

#### Get maximum fee basis points

Returns the maximum fee percentage allowed by the protocol in basis points.

```solidity
uint16 maxFee = operatorRewarder.maxFeeBasisPoints();
```

#### Get unpaid fee

Returns the total amount of unclaimed $ZAMA commission fees accumulated for the operator.

```solidity
uint256 unpaid = operatorRewarder.unpaidFee();
```

#### Check earned rewards

Returns the amount of $ZAMA rewards accrued by a delegator that are available to be claimed.

```solidity
uint256 pending = operatorRewarder.earned(delegatorAddress);
```

#### Set commission fee

Allows the beneficiary of the rewarder contract to update the commission fee.

```solidity
// Sets the fee to 10% (1000 basis points)
operatorRewarder.setFee(1000);
```

### Events

| Event | Description |
| ----- | ----------- |
| `BeneficiaryTransferred(oldBeneficiary, newBeneficiary)` | Emitted when the beneficiary is updated. |
| `ClaimerAuthorized(receiver, claimer)` | Emitted when a delegator authorizes another address to claim their rewards. |
| `FeeClaimed(beneficiary, amount)` | Emitted when commission fees are claimed. |
| `FeeUpdated(oldFee, newFee)` | Emitted when the commission fee is changed. |
| `MaxFeeUpdated(oldFee, newFee)` | Emitted when the maximum allowed fee is changed by the owner. |
| `RewardsClaimed(receiver, amount)` | Emitted when a delegator claims their rewards. |
| `Shutdown()` | Emitted when the `OperatorRewarder` is shut down by the owner, preventing future rewards distribution. |

### Errors

| Error | Cause |
| ----- | ----- |
| `AlreadyShutdown()` | Attempted an action, but the rewarder is already shut down. |
| `AlreadyStarted()` | Attempted to start a rewarder that has already been started. |
| `BeneficiaryAlreadySet(beneficiary)` | The new beneficiary is identical to the current one. |
| `CallerNotBeneficiary(caller)` | The caller is not the authorized beneficiary. |
| `CallerNotOperatorStaking(caller)` | The caller is not the linked `OperatorStaking` contract. |
| `CallerNotProtocolStakingOwner(caller)` | The caller is not the owner of the `ProtocolStaking` contract. |
| `ClaimerAlreadySet(receiver, claimer)` | The new claimer is identical to the current one. |
| `ClaimerNotAuthorized(receiver, claimer)` | The caller does not have permission to claim on behalf of the delegator. |
| `FeeAlreadySet(feeBasisPoints)` | The new fee is identical to the current one. |
| `InvalidBasisPoints(basisPoints)` | The basis points input is out of bounds (e.g., above 10000). |
| `InvalidBeneficiary(beneficiary)` | The provided beneficiary address is zero. |
| `InvalidClaimer(claimer)` | The provided claimer address is zero. |
| `MaxBasisPointsExceeded(basisPoints, maxBasisPoints)` | The new fee exceeds the maximum set by the owner. |
| `MaxFeeAlreadySet(maxFeeBasisPoints)` | The new maximum fee is identical to the current one. |
| `NotStarted()` | Attempted an action, but the rewarder hasn't been started yet. |

## Staking rewards calculation

> [!TIP]
> For a full interactive walkthrough with example outputs, see the [APY notebook](../contracts/staking/APY.ipynb).

### Calculating the rewards rate

The rewards rate is defined as tokens-per-second and is determined as follows:

1. The total yearly rewards amount to be paid out is determined once a year as a percentage of the current total supply of $ZAMA. This percentage (`TOTAL_YEARLY_INFLATION_PROPORTION`) is **a variable controlled by the Protocol DAO governance** and is currently set to **5%**.
2. This total amount is divided between the roles, with 40% going to coprocessor operators and 60% to KMS operators.
3. Each per role amount is converted into a per role tokens-per-second reward rate for the year.

```python
SECONDS_PER_YEAR = 365 * 24 * 60 * 60
TOTAL_SUPPLY = 11_000_000_000 * 10**18

def get_reward_rate(total_yearly_inflation_proportion: float) -> tuple[int, int]:
    """
    Compute the reward rates for KMS and Coprocessors based on total supply.

    :param total_yearly_inflation_proportion: Decimal value of the total yearly inflation (e.g. 0.05)
    :return: A tuple (rate_kms, rate_coprocessors) in tokens per second (with 18 decimals)
    """
    total_fees_rewards = int(TOTAL_SUPPLY * total_yearly_inflation_proportion)

    total_fees_rewards_kms = int(total_fees_rewards * 0.60)
    total_fees_rewards_coprocessors = int(total_fees_rewards * 0.40)

    rate_kms = total_fees_rewards_kms // SECONDS_PER_YEAR
    rate_coprocessors = total_fees_rewards_coprocessors // SECONDS_PER_YEAR

    return rate_kms, rate_coprocessors
```

### Calculating the APR

The native APR for delegating to an operator depends on several factors:

1. [**Reward Rate:**](#calculating-the-rewards-rate) The rate of tokens per second, retrieved from `ProtocolStaking.rewardRate()`.
2. **Tokens per Pool:** The number of deposited tokens in each eligible `OperatorStaking` pool, retrieved from `ProtocolStaking.balanceOf(address(OperatorStaking))`.
3. **Fees per Pool:** The commission fee for each corresponding `OperatorRewarder` in basis points, retrieved from `OperatorRewarder.feeBasisPoints()`.

```python
import math

SECONDS_PER_YEAR = 365 * 24 * 60 * 60

def compute_native_apr(
    reward_rate: int, 
    num_tokens_per_pool: list[int], 
    fees_per_pool: list[int]
) -> list[float]:
    """
    Compute the native APR for each eligible OperatorStaking pool.
    
    :return: List of percentage APRs for each pool
    """
    assert len(num_tokens_per_pool) == len(fees_per_pool), "Pool/Fee length mismatch"
    assert all(0 <= fee <= 10000 for fee in fees_per_pool), "Fees must be within 0 and 10000"
    assert all(0 <= tokens for tokens in num_tokens_per_pool), "Token amounts must be non-negative"
    assert reward_rate >= 0, "Reward rate must be non-negative"

    weights = [int(math.sqrt(tokens)) for tokens in num_tokens_per_pool]
    total_weight = sum(weights)
    
    fee_factors = [1 - (fee / 10000) for fee in fees_per_pool]
    rate_per_sec_per_pool = [reward_rate * (weight / total_weight) for weight in weights]
    
    pool_aprs = []
    for i in range(len(fee_factors)):
        net_reward_per_sec = rate_per_sec_per_pool[i] * fee_factors[i]
        pool_apr = (net_reward_per_sec / num_tokens_per_pool[i]) * SECONDS_PER_YEAR * 100
        pool_aprs.append(pool_apr)
    
    return pool_aprs
```
