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
import { task } from 'hardhat/config';
import { HardhatUserConfig, HttpNetworkAccountsUserConfig } from 'hardhat/types';
import { resolve } from 'path';
import 'solidity-coverage';
import 'hardhat-exposed';

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
    'Could not find MNEMONIC or PRIVATE_KEY environment variables. It will not be possible to execute transactions in your example.',
  );
}

task('test', 'Runs the test suite with environment variables from .env.example').setAction(async (_, hre, runSuper) => {
  const envExamplePath = resolve(__dirname, '.env.example');
  if (existsSync(envExamplePath)) {
    dotenv.config({ path: envExamplePath, override: true });
  }
  await runSuper();
});

const config: HardhatUserConfig = {
  solidity: {
    version: '0.8.27',
    settings: {
      optimizer: {
        enabled: true,
        runs: 800,
      },
      evmVersion: 'cancun',
    },
  },
  networks: {
    mainnet: {
      url: process.env.MAINNET_RPC_URL || '',
      accounts,
      chainId: 1,
    },
    testnet: {
      url: process.env.SEPOLIA_RPC_URL || '',
      accounts,
      chainId: 11155111,
    },
    hardhat: {
      saveDeployments: false,
    },
  },
  namedAccounts: {
    deployer: {
      default: 0,
    },
    alice: {
      default: 1,
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
  exposed: {
    imports: true,
    initializers: true,
  },
};

export default config;
