import "@nomicfoundation/hardhat-ethers";
import "@nomicfoundation/hardhat-verify";
import "@openzeppelin/hardhat-upgrades";
import "@typechain/hardhat";
import "@fhevm/hardhat-plugin";
import dotenv from "dotenv";
import { HardhatUserConfig, HttpNetworkAccountsUserConfig } from "hardhat/types";

dotenv.config();

const MNEMONIC = process.env.MNEMONIC;
const PRIVATE_KEY = process.env.PRIVATE_KEY;

const accounts: HttpNetworkAccountsUserConfig | undefined = MNEMONIC
  ? { mnemonic: MNEMONIC }
  : PRIVATE_KEY
    ? [PRIVATE_KEY]
    : undefined;

if (accounts == null) {
  console.warn(
    "Could not find MNEMONIC or PRIVATE_KEY environment variables. It will not be possible to execute transactions.",
  );
}

const config: HardhatUserConfig = {
  paths: {
    sources: "./contracts",
  },
  solidity: {
    version: "0.8.27",
    settings: {
      optimizer: {
        enabled: true,
        runs: 800,
      },
      evmVersion: "cancun",
    },
  },
  networks: {
    mainnet: {
      url: process.env.MAINNET_RPC_URL || "",
      accounts,
      chainId: 1,
    },
    testnet: {
      url: process.env.SEPOLIA_RPC_URL || "",
      accounts,
      chainId: 11155111,
    },
  },
  typechain: {
    outDir: "types",
    target: "ethers-v6",
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY || "",
  },
};

export default config;
