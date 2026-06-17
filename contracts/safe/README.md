# AdminModule for the Safe MultiSig wallet to be used on Gateway

## Deploy Multisig Safe Wallet with only the deployer as owner

**NOTE** This first step is only needed on chains which do not support canonical Safe deployment (eg: Gateway or Polygon Amoy Testnet). For chains which do support the canonical Safe deployment (eg: Polygon Mainnet), the Safe account shoud be deployed via the official [Safe App UI](https://app.safe.global/) instead.

Be sure to start with an `.env` - or copy paste the `.env.example.deploy` and fill its values (not to be confused with `.env.example.test` to be used to run tests in hardhat only!) - with just those filled variables:

```
PRIVATE_KEY=
RPC_URL_<NETWORK>=
```

Then run:

```
npx hardhat compile
npx hardhat task:deploySafe --network <NETWORK>
```

This will deploy `SafeL2` singleton contract, as well as `SafeProxyFactory` and `SafeL2Proxy`. The `SafeL2Proxy` is actually the multisig wallet which will become later the owner of `GatewayConfig`.

Then, after waiting for around 1 minute for the block explorer indexing to take into consideration newly deployed contracts, run:

```
npx hardhat task:verifySafe --network <NETWORK>
```

## Deploy, verify and enable the AdminModule

Add in your `.env` a value for the `ADMIN_ADDRESS`, which should be the address of an already deployed `GovernanceOAppReceiver` contract.

Deploy then the AdminModule with:

```
npx hardhat task:deployAdminModule --network <NETWORK>
```

By default, the Safe proxy address is read from `deployments/<NETWORK>/SafeL2Proxy.json` (i.e. a Safe deployed through the `task:deploySafe` task above). To target a Safe created outside `hardhat-deploy` (eg. one deployed via the official [Safe App UI](https://app.safe.global/)), set its address in the `SAFE_PROXY_ADDRESS` env variable and pass the `--use-safe-proxy-address-env` flag:

```
npx hardhat task:deployAdminModule --use-safe-proxy-address-env --network <NETWORK>
```

And, after waiting for around 1 minute for the block explorer indexing, verify it with:

```
npx hardhat task:verifyAdminModule --network <NETWORK>
```

Finally, enable the safe module with:

```
npx hardhat task:enableAdminModule --network <NETWORK>
```

As with the deploy task, the Safe proxy address defaults to the one in `deployments/<NETWORK>/SafeL2Proxy.json`. To target a Safe created outside `hardhat-deploy`, set its address in the `SAFE_PROXY_ADDRESS` env variable and pass the `--use-safe-proxy-address-env` flag:

```
npx hardhat task:enableAdminModule --use-safe-proxy-address-env --network <NETWORK>
```

## Accept ownership of GatewayConfig contract

This step supposes that the original owner of `GatewayConfig`/`ACL` already called the `transferOwnership` function of `GatewayConfig`/`ACL` with the Safe proxy address as a new owner. Since `GatewayConfig`/`ACL` inherits from `Ownable2StepUpgradeable`, the Safe wallet still need to call `acceptOwnership` to effectively become the owner. This can be done using:

```
npx hardhat task:acceptGatewayConfigOwnership --network <NETWORK>
```

## Change owners and threshold of the Safe proxy

This can be done in the 3 following steps, in order to be careful and limit risk of errors.
