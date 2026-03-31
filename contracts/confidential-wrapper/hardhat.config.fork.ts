/**
 * Minimal hardhat config for fork-based upgrade testing.
 *
 * This config intentionally omits the @fhevm/hardhat-plugin to avoid genesis
 * storage overrides that conflict with forking.
 *
 * Usage:
 *   npx hardhat --config hardhat.config.fork.ts run scripts/test-upgrade.ts
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
const FORK_BLOCK_NUMBER = process.env.CONFIDENTIAL_WRAPPER_UPGRADE_TEST_FORK_BLOCK_NUMBER;

if (!FORK_RPC_URL) {
  throw new Error('CONFIDENTIAL_WRAPPER_UPGRADE_TEST_RPC_URL must be set in .env to run fork-based upgrade tests');
}

let forkBlockNumber: number | undefined;
if (FORK_BLOCK_NUMBER != null && FORK_BLOCK_NUMBER.trim() !== '') {
  const parsed = Number.parseInt(FORK_BLOCK_NUMBER.trim(), 10);
  if (!Number.isFinite(parsed) || parsed < 0) {
    throw new Error(
      'CONFIDENTIAL_WRAPPER_UPGRADE_TEST_FORK_BLOCK_NUMBER must be a non-negative integer when set',
    );
  }
  forkBlockNumber = parsed;
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
        ...(forkBlockNumber !== undefined ? { blockNumber: forkBlockNumber } : {}),
      },
    },
  },
  typechain: {
    outDir: 'types',
    target: 'ethers-v6',
  },
};

export default config;
