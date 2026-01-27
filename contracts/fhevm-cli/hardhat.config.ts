import "@fhevm/hardhat-plugin";
import "@nomicfoundation/hardhat-chai-matchers";
import "@nomicfoundation/hardhat-ethers";
import "@nomicfoundation/hardhat-verify";
import dotenv from "dotenv";
import { HardhatUserConfig } from "hardhat/config";
import { resolve } from "path";

import "./tasks/allow";
import "./tasks/deployment/multisig";
import "./tasks/deployment/verify";
import "./tasks/encrypt";
import "./tasks/publicDecrypt";
import "./tasks/userDecrypt";

const NUM_ACCOUNTS = 10;

const dotenvConfigPath: string = process.env.DOTENV_CONFIG_PATH || "./.env";
dotenv.config({ path: resolve(__dirname, dotenvConfigPath) });

// Ensure that we have all the environment variables we need.
let mnemonic: string | undefined = process.env.MNEMONIC;
if (!mnemonic) {
  mnemonic = "adapt mosquito move limb mobile illegal tree voyage juice mosquito burger raise father hope layer"; // default mnemonic in case it is undefined (needed to avoid panicking when deploying on real network)
}

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.28",
    settings: {
      evmVersion: "cancun",
    },
  },
  networks: {
    // ChainID must be specified in order to be able to verify contracts using the fhevm hardhat plugin
    mainnet: {
      url: process.env.MAINNET_RPC_URL || "",
      chainId: 1,
      accounts: {
        count: NUM_ACCOUNTS,
        mnemonic,
        path: "m/44'/60'/0'/0",
      },
    },
    // ChainID must be specified in order to be able to verify contracts using the fhevm hardhat plugin
    testnet: {
      url: process.env.TESTNET_RPC_URL || "",
      chainId: 11155111,
      accounts: {
        count: NUM_ACCOUNTS,
        mnemonic,
        path: "m/44'/60'/0'/0",
      },
    },
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY!,
  },
};

export default config;
