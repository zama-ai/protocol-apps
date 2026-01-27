# How to add ZamaOFT on Solana Chain

Currently, we have `ZamaERC20` and `ZamaOFTAdapter` deployed on Ethereum mainnet (and `ZamaOFT` deployed on both Gateway and BNB testnet). The `ZamaOFTAdapter` contract's owner and delegate are already setup to be an Aragon DAO contract.

The goal of this runbook is to guide you step by step on how to deploy a ZAMA OFT instance on Solana Chain, and how to wire it to the already deployed `ZamaOFTAdapter` on Ethereum, via the Aragon DAO. We only add a single bidirectional pathway: `Solana devnet <-> Ethereum Sepolia`.

## Step 1 : Deploy the OFT on Solana devnet Chain

First make sure you have installed all needed dependencies via `pnpm i` and filled the `.env` file correctly (see [`.env.example`](./.env.example) file).

### Prepare the Solana OFT Program keypair

Run `anchor keys sync -p oft` command. This will create the OFT `programId` keypair and also automatically update `Anchor.toml` to use the generated keypair's public key. The default path for the program's keypair will be `target/deploy/oft-keypair.json`. The program keypair is only used for initial deployment of the program. 

__Optional:__ you can use `anchor keys list` to view the program ID's based on the generated keypairs.

Copy the `oft` program ID value for use in the build step later.

### Building the Solana OFT Program

Ensure you have Docker running before running the build command.

This step could take more than half an hour:

```bash
anchor build -v -e OFT_ID=<OFT_PROGRAM_ID>
```

Where `<OFT_PROGRAM_ID>` is replaced with your OFT Program ID copied from the previous step.

### (Recommended) Deploying with a priority fee

The `deploy` command will run with a priority fee. Read the section on ['Deploying Solana programs with a priority fee'](https://docs.layerzero.network/v2/developers/solana/technical-reference/solana-guidance#deploying-solana-programs-with-a-priority-fee) to learn more.

### Run the deploy command

First make sure your local key has at least `5 SOL`, for e.g you can check it via `solana balance` if you use the keypair at the default path.

```bash
solana program deploy --program-id target/deploy/oft-keypair.json target/verifiable/oft.so -u devnet --with-compute-unit-price <COMPUTE_UNIT_PRICE_IN_MICRO_LAMPORTS>
```

Usually a value of `200000` is good for `<COMPUTE_UNIT_PRICE_IN_MICRO_LAMPORTS>`.

### Create the Solana OFT

Rename the `layerzero.config.testnet.ts` file at the root of this project as `layerzero.config.ts`. Then run this command:

```bash
pnpm hardhat lz:oft:solana:create --eid 40168 --program-id <PROGRAM_ID> --only-oft-store true
```

The above command will create a Solana OFT which will have only the OFT Store as the Mint Authority.

## Step 2 : Wire the Solana devnet OFT to Ethereum Sepolia OFTAdapter

This can be done easily, since your deployer hot wallet is still the owner and delegate of the OFT instance on Solana Chain - later, after full wiring on both chains, owner/admin and delegate roles, as well as other Solana-specific roles, should be transferred to governance on Solana Chain, which should be a Squads multisig wallet.

Run the following command to initialize the SendConfig and ReceiveConfig Accounts. This step is unique to pathways that involve Solana.

```bash
npx hardhat lz:oft:solana:init-config --oapp-config layerzero.config.ts
```

Run the wiring task on the Solana side:

```bash
pnpm hardhat lz:oapp:wire --oapp-config layerzero.config.ts --skip-connections-from-eids <EID_ETHEREUM_V2_TESTNET>
```

Where `<EID_ETHEREUM_V2_TESTNET>` value is `40161`.

## Step 3 : Wire the Ethereum OFTAdapter to BNB OFT

This step is more complex, since the delegate of the OFTAdapter is an Aragon DAO, i.e it requires creating, approving and executing a DAO proposal via the Aragon DAO.

First, create an `ethereum-wiring.json` file containing the different transactions needed to be done, by running:

```
npx hardhat lz:oapp:wire --output-filename ethereum-wiring.json
```

When running previous command, select **no** when requested if you would you like to submit the required transactions (otherwise it would fail anyways). You should now have generated a new `ethereum-wiring.json` file in the root of the directory.

Now, run:

```
npx ts-node scripts/convertToAragonProposal.ts ethereum-wiring.json aragonProposal.json
```

This will convert the `ethereum-wiring.json` file to a new `aragonProposal.json` which could be directly uploaded inside the Aragon App UI, when creating an Aragon proposal, to streamling the process.

More precisely, in Aragon App, when you reach "Step 2 of 3" of proposal creation, click on the `Upload` button there, in select the newly created `aragonProposal.json` file to upload it and create the wiring proposal on Ethereum.

![Aragon Proposal Upload](images/AragonUpload.png)

After voting and execution of the wiring proposal, your OFT is now successfully setup.

## Step 4 : Test OFT transfers

You can test that the OFT BNB has been correctly wired by sending some amount of tokens from Ethereum to BNB Chain, and the other way around, by using commands such as: 

```
npx hardhat lz:oft:send --src-eid 30101 --dst-eid 30102 --amount 0.1 --to <RECEIVER_ADDRESS> --oapp-config layerzero.config.mainnet.bnb.ts
```

to send 0.1 Zama token from Ethereum to BNB mainnet, and: 

```
npx hardhat lz:oft:send --src-eid 30102 --dst-eid 30101 --amount 0.1 --to <RECEIVER_ADDRESS> --oapp-config layerzero.config.mainnet.bnb.ts
```

to send 0.1 Zama token from BNB mainnet to Ethereum.

## Step 5 : transfer delegate and owner

Once the transfer tests are successful, don't forget to transfer the delegate and owners roles of the BNB OFT instance to governance (i.e BNB Safe Multisig).

Those `cast` commands are helpful for transferring roles:

To get current OFT owner address:

```
cast call <BNB_OFT_ADDRESS> "owner()(address)" --rpc-url <BNB_RPC_URL>
```

To get current `EndpointV2` address:

```
cast call <BNB_OFT_ADDRESS> "endpoint()(address)" --rpc-url <BNB_RPC_URL>
```

To get current delegate:

```
cast call <LZ_ENDPOINT_V2_ADDRESS> "delegates(address)(address)" <BNB_OFT_ADDRESS> --rpc-url <BNB_RPC_URL>
```

To transfer delegate role:

```
cast send <BNB_OFT_ADDRESS> "setDelegate(address)" <BNB_SAFE_ADDRESS> --rpc-url <BNB_RPC_URL> --private-key <DEPLOYER_PRIVATE_KEY>
```

To transfer owner role:

```
cast send <BNB_OFT_ADDRESS> "transferOwnership(address)" <BNB_SAFE_ADDRESS> --rpc-url <BNB_RPC_URL> --private-key <DEPLOYER_PRIVATE_KEY>
```
