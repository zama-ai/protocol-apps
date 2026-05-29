# Native confidential token example

This example project contains a minimal deployable native confidential token reference flow for the deployment guide.

For the full step-by-step deployment walkthrough, see [docs/confidential-token.md](../../docs/confidential-token.md).

> Warning:
> The concrete `NativeConfidentialToken.sol` contract in this project is a **reference example only**. It is not a protocol-supported implementation, not a production deployment target, and not a commitment that this exact contract shape will be maintained as a product surface.

## Contents

* `contracts/NativeConfidentialToken.sol`: minimal native confidential token reference example
* `scripts/deploy-native-token.ts`: minimal UUPS deployment script

## Quick start

```bash
cp .env.example .env
npm install
npx hardhat compile
npm run deploy:testnet
```

Fill the following values in `.env` before deploying:

* `PRIVATE_KEY` or `MNEMONIC`
* `SEPOLIA_RPC_URL` or `MAINNET_RPC_URL`
* `ETHERSCAN_API_KEY` if you want contract verification
* `OWNER_ADDRESS`
* `TOKEN_NAME`
* `TOKEN_SYMBOL`
* `TOKEN_CONTRACT_URI`

## Notes
* The concrete `NativeConfidentialToken.sol` contract is a reference example only and should be adapted by each integrator to their own requirements.
* The reusable abstract/helper contracts live in `contracts/confidential-token/`.
* This project depends on `contracts/confidential-token/` as a local package via `file:../../contracts/confidential-token`. Run `npm install` from `scripts/native-confidential-token/` so the local package is linked into `node_modules` before compiling.
