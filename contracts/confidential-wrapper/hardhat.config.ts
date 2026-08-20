import '@nomicfoundation/hardhat-chai-matchers';
import '@nomicfoundation/hardhat-ethers';
import '@nomicfoundation/hardhat-verify';
import '@openzeppelin/hardhat-upgrades';
import '@typechain/hardhat';
import dotenv from 'dotenv';
import { existsSync } from 'fs';
import 'hardhat-deploy';
import 'hardhat-gas-reporter';
import 'hardhat-ignore-warnings';
import '@fhevm/hardhat-plugin';
import { subtask, task } from 'hardhat/config';
import { TASK_TEST_GET_TEST_FILES } from 'hardhat/builtin-tasks/task-names';
import { HardhatUserConfig, HttpNetworkAccountsUserConfig } from 'hardhat/types';
import { sep, resolve } from 'path';
import 'solidity-coverage';
import 'hardhat-exposed';

import './tasks/accounts';
import './tasks/deploy';
import './tasks/verify';

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

if (accounts == null) {
  console.warn(
    'No signer configured. Read-only tasks still work; to broadcast transactions, set MNEMONIC or PRIVATE_KEY.',
  );
}

// Run the test suite with environment variables from `.env.example`
task('test', 'Runs the test suite with environment variables from .env.example').setAction(async (_, hre, runSuper) => {
  // Load `.env.example`
  const envExamplePath = resolve(__dirname, '.env.example');
  if (existsSync(envExamplePath)) {
    dotenv.config({ path: envExamplePath, override: true });
  }
  await runSuper();
});

subtask(TASK_TEST_GET_TEST_FILES).setAction(async (args, _hre, runSuper) => {
  const testFiles = (await runSuper(args)) as string[];
  const foundryTestDir = `${sep}test${sep}foundry${sep}`;
  return testFiles.filter(file => !file.includes(foundryTestDir));
});

const config: HardhatUserConfig = {
  solidity: {
    // Hardhat picks the highest compiler matching a pragma, so listing 0.8.29 for
    // hardhat-verify (OZ's precompiled ERC1967Proxy is 0.8.29) would also bump our
    // ^0.8.27 impls. Pin ConfidentialWrapper via overrides; keep 0.8.29 in compilers
    // so verify can match the proxy bytecode without CompilerVersionsMismatchError.
    compilers: [
      {
        version: '0.8.27',
        settings: {
          optimizer: {
            enabled: true,
            runs: 800,
          },
          evmVersion: 'cancun',
        },
      },
      {
        version: '0.8.29',
        settings: {
          optimizer: {
            enabled: true,
            runs: 800,
          },
          evmVersion: 'cancun',
        },
      },
    ],
    overrides: {
      'contracts/ConfidentialWrapper.sol': {
        version: '0.8.27',
        settings: {
          optimizer: {
            enabled: true,
            runs: 800,
          },
          evmVersion: 'cancun',
        },
      },
    },
  },
  networks: {
    // ChainID must be specified in order to be able to verify contracts using the fhevm hardhat plugin
    ethereum: {
      url: process.env.DEPLOYMENT_RPC_URL || process.env.ETHEREUM_RPC_URL || '',
      accounts,
      chainId: 1,
    },
    sepolia: {
      url: process.env.DEPLOYMENT_RPC_URL || process.env.SEPOLIA_RPC_URL || '',
      accounts,
      chainId: 11155111,
    },
    // FHEVM config for chainId 80002 comes from the locally vendored
    // contracts/fhevm/ZamaConfig.sol (aligned with @fhevm/solidity 0.13.2).
    'polygon-amoy': {
      url: process.env.AMOY_RPC_URL || '',
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
    alice: {
      default: 1, // wallet address of index[1], of the mnemonic in .env
    },
  },
  gasReporter: {
    currency: 'USD',
    enabled: process.env.REPORT_GAS === 'true',
    showMethodSig: true,
    includeBytecodeInJSON: true,
  },
  typechain: {
    outDir: 'types',
    target: 'ethers-v6',
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY!,
  },
  sourcify: {
    enabled: true,
  },
  blockscout: {
    enabled: true,
  },
  exposed: {
    imports: true,
    initializers: true,
  },
};

export default config;
