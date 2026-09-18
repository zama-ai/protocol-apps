import "@nomicfoundation/hardhat-chai-matchers";
import "@nomicfoundation/hardhat-ethers";
import "@nomicfoundation/hardhat-verify";
import "@typechain/hardhat";
import dotenv from "dotenv";
import { existsSync } from "fs";
import "hardhat-deploy";
import "hardhat-gas-reporter";
import { TASK_TEST_GET_TEST_FILES } from "hardhat/builtin-tasks/task-names";
import { extendEnvironment, subtask, task } from "hardhat/config";
import { HardhatUserConfig, HttpNetworkAccountsUserConfig } from "hardhat/types";
import { resolve, sep } from "path";
import "solidity-coverage";

import "./tasks/checkPausers";
import "./tasks/setPauserProposal";
import "./tasks/verify";

// Get the environment configuration from .env file
//
// To make use of automatic environment setup:
// - Duplicate .env.example file and name it .env
// - Fill in the environment variables
dotenv.config();

// Set your preferred authentication method
//
// If you prefer using a mnemonic, set a MNEMONIC environment variable
// to a valid mnemonic
const MNEMONIC = process.env.MNEMONIC;

// If you prefer to be authenticated using a private key, set a PRIVATE_KEY environment variable
const PRIVATE_KEY = process.env.PRIVATE_KEY;

const accounts: HttpNetworkAccountsUserConfig | undefined = MNEMONIC
  ? { mnemonic: MNEMONIC }
  : PRIVATE_KEY
    ? [PRIVATE_KEY]
    : undefined;

// Warn about a missing signer only when a real network is selected; tests and coverage run on the in-process one.
extendEnvironment((hre) => {
  if (accounts == null && hre.network.name !== "hardhat") {
    console.warn(
      "No signer configured. Read-only tasks still work; to broadcast transactions, set MNEMONIC or PRIVATE_KEY.",
    );
  }
});

// Run the test suite with environment variables from `.env.example`
task("test", "Runs the test suite with environment variables from .env.example").setAction(async (_, hre, runSuper) => {
  const envExamplePath = resolve(__dirname, ".env.example");
  if (existsSync(envExamplePath)) {
    dotenv.config({ path: envExamplePath, override: true });
  }
  await runSuper();
});

// The Foundry fork suite under test/foundry is driven by its own Makefile, not by mocha.
subtask(TASK_TEST_GET_TEST_FILES).setAction(async (args, _hre, runSuper) => {
  const testFiles = (await runSuper(args)) as string[];
  const foundryTestDir = `${sep}test${sep}foundry${sep}`;
  return testFiles.filter((file) => !file.includes(foundryTestDir));
});

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.27",
    settings: {
      metadata: {
        bytecodeHash: "none",
      },
      optimizer: {
        enabled: true,
        runs: 800,
      },
      evmVersion: "cancun",
    },
  },
  paths: {
    deploy: "deploy",
    deployments: "deployments",
  },
  networks: {
    ethereum: {
      url: process.env.ETHEREUM_RPC_URL || "",
      accounts,
      chainId: 1,
    },
    polygon: {
      url: process.env.POLYGON_RPC_URL || "",
      accounts,
      chainId: 137,
    },
    sepolia: {
      url: process.env.SEPOLIA_RPC_URL || "",
      accounts,
      chainId: 11155111,
    },
    amoy: {
      url: process.env.AMOY_RPC_URL || "",
      accounts,
      chainId: 80002,
    },
    hardhat: {
      // Need this to avoid deployment issues in test
      saveDeployments: false,
    },
  },
  namedAccounts: {
    deployer: {
      default: 0, // wallet address of index[0], of the mnemonic in .env
    },
  },
  gasReporter: {
    currency: "USD",
    enabled: process.env.REPORT_GAS === "true",
    showMethodSig: true,
  },
  typechain: {
    outDir: "types",
    target: "ethers-v6",
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY || "",
  },
  sourcify: {
    enabled: true,
  },
  blockscout: {
    enabled: true,
  },
};

export default config;
