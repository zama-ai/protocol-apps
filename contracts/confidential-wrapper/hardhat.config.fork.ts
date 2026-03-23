/**
 * Minimal hardhat config for fork-based upgrade testing.
 *
 * This config intentionally omits the @fhevm/hardhat-plugin to avoid genesis
 * storage overrides that conflict with forking.
 *
 * Usage:
 *   npx hardhat --config hardhat.config.fork.ts test test/ConfidentialWrapperUpgrade.test.ts
 */

import '@nomicfoundation/hardhat-chai-matchers';
import '@nomicfoundation/hardhat-ethers';
import '@openzeppelin/hardhat-upgrades';
import '@typechain/hardhat';
import dotenv from 'dotenv';
import { HardhatUserConfig } from 'hardhat/types';
import { resolve } from 'path';

dotenv.config({ path: resolve(__dirname, '.env') });

const FORK_RPC_URL = process.env.CONFIDENTIAL_WRAPPER_UPGRADE_TEST_RPC_URL;

if (!FORK_RPC_URL) {
  throw new Error(
    'CONFIDENTIAL_WRAPPER_UPGRADE_TEST_RPC_URL must be set in .env to run fork-based upgrade tests',
  );
}

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
    hardhat: {
      forking: {
        url: FORK_RPC_URL,
      },
    },
  },
  typechain: {
    outDir: 'types',
    target: 'ethers-v6',
  },
};

export default config;
