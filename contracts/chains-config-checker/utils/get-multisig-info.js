#!/usr/bin/env node

require('dotenv').config({ path: require('path').resolve(__dirname, '../.env') });
const { ethers } = require('ethers');
const { findDeploymentBlock } = require('./get-deployment-block');
const { Connection, PublicKey } = require('@solana/web3.js');
const multisig = require('@sqds/multisig');
const { Multisig } = multisig.accounts;

// ── Safe multisig addresses (from docs/addresses/mainnet) ──────────────────
const SAFE_CHAINS = {
  gateway: {
    name: 'Gateway',
    rpcEnv: 'RPC_GATEWAY',
    safeAddress: '0x5f0F86BcEad6976711C9B131bCa5D30E767fe2bE',
  },
  bsc: {
    name: 'BSC',
    rpcEnv: 'RPC_BSC',
    safeAddress: '0xa40939fDe3883D2e7Cd5C32f53AB241804d2779B',
  },
  hyperEvm: {
    name: 'HyperEVM',
    rpcEnv: 'RPC_HYPEREVM',
    safeAddress: '0x0d66642a5Bc6E32e013f47E08f9db9bDb1268827',
  },
};

// ── Aragon DAO on Ethereum ─────────────────────────────────────────────────
const ARAGON_DAO = '0xB6D69D5F334d8B97B194617B53c6aB62f8681Ef3';

// ── ABIs ───────────────────────────────────────────────────────────────────
const SAFE_ABI = [
  'function getOwners() view returns (address[])',
  'function getThreshold() view returns (uint256)',
];

const PERMISSION_MANAGER_ABI = [
  'event Granted(bytes32 indexed permissionId, address indexed here, address where, address indexed who, address condition)',
  'event Revoked(bytes32 indexed permissionId, address indexed here, address where, address indexed who)',
  'function hasPermission(address _where, address _who, bytes32 _permissionId, bytes _data) view returns (bool)'
];

const MAX_BLOCK_RANGE = 49999;

// ── Helpers ────────────────────────────────────────────────────────────────

async function queryEventsInChunks(contract, filter, fromBlock, toBlock, label) {
  const events = [];
  let currentFrom = fromBlock;

  while (currentFrom <= toBlock) {
    const currentTo = Math.min(currentFrom + MAX_BLOCK_RANGE, toBlock);
    const progress = Math.round(((currentFrom - fromBlock) / (toBlock - fromBlock)) * 100) || 0;
    process.stdout.write(`\r    ${label}: ${progress}% (block ${currentFrom})...`);

    const chunk = await contract.queryFilter(filter, currentFrom, currentTo);
    events.push(...chunk);

    currentFrom = currentTo + 1;
  }

  console.log(`\r    ${label}: 100% - found ${events.length} events`);
  return events;
}

// ── Safe multisig info ─────────────────────────────────────────────────────

async function getSafeInfo(chainConfig) {
  const { name, rpcEnv, safeAddress } = chainConfig;
  const rpcUrl = process.env[rpcEnv];

  if (!rpcUrl) {
    console.log(`  Skipping ${name}: ${rpcEnv} not configured`);
    return null;
  }

  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const safe = new ethers.Contract(safeAddress, SAFE_ABI, provider);

  const [owners, threshold] = await Promise.all([
    safe.getOwners(),
    safe.getThreshold(),
  ]);

  return {
    name,
    safeAddress,
    owners: Array.from(owners),
    threshold: Number(threshold),
  };
}

// ── Aragon DAO plugin detection ────────────────────────────────────────────

async function getAragonPlugins(rpcUrl) {
  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const dao = new ethers.Contract(ARAGON_DAO, PERMISSION_MANAGER_ABI, provider);

  const EXECUTE_PERMISSION_ID = ethers.keccak256(ethers.toUtf8Bytes('EXECUTE_PERMISSION'));

  console.log(`  Finding deployment block for DAO ${ARAGON_DAO}...`);
  const fromBlock = await findDeploymentBlock(ARAGON_DAO, { rpcUrl, silent: true });
  const toBlock = await provider.getBlockNumber();
  console.log(`  Deployment block: ${fromBlock}, current block: ${toBlock}`);

  // Filter: permissionId = EXECUTE_PERMISSION_ID, here = any, where = DAO address
  const grantFilter = dao.filters.Granted(EXECUTE_PERMISSION_ID);
  const revokeFilter = dao.filters.Revoked(EXECUTE_PERMISSION_ID);

  console.log('  Fetching permission events...');
  const grantEvents = await queryEventsInChunks(dao, grantFilter, fromBlock, toBlock, 'Granted');
  const revokeEvents = await queryEventsInChunks(dao, revokeFilter, fromBlock, toBlock, 'Revoked');

  // Combine and sort chronologically
  const allEvents = [
    ...grantEvents
      .filter((e) => e.args.where.toLowerCase() === ARAGON_DAO.toLowerCase())
      .map((e) => ({
        type: 'grant',
        who: e.args.who,
        block: e.blockNumber,
        logIndex: e.index,
      })),
    ...revokeEvents
      .filter((e) => e.args.where.toLowerCase() === ARAGON_DAO.toLowerCase())
      .map((e) => ({
        type: 'revoke',
        who: e.args.who,
        block: e.blockNumber,
        logIndex: e.index,
      })),
  ].sort((a, b) => {
    if (a.block !== b.block) return a.block - b.block;
    return a.logIndex - b.logIndex;
  });

  // Build the set of addresses that currently hold EXECUTE_PERMISSION
  const activePlugins = new Set();
  for (const event of allEvents) {
    if (event.type === 'grant') {
      activePlugins.add(event.who);
    } else {
      activePlugins.delete(event.who);
    }
  }

  console.log('  Running on-chain sanity check...');
  
  // Get every unique address that ever had a grant/revoke event
  const allUniqueAddresses = new Set(allEvents.map(e => e.who));

  for (const whoAddress of allUniqueAddresses) {
    // Call the live mapping. _data is "0x" because we are just checking standard permissions without conditional data.
    const isActuallyActive = await dao.hasPermission(ARAGON_DAO, whoAddress, EXECUTE_PERMISSION_ID, "0x");
    const isExpectedActive = activePlugins.has(whoAddress);

    if (isActuallyActive !== isExpectedActive) {
      console.log(`  [WARNING] State mismatch for ${whoAddress}!`);
      console.log(`    Events expected: ${isExpectedActive}`);
      console.log(`    On-chain reality: ${isActuallyActive}`);
      
      // Correct the Set based on the source of truth (the on-chain state)
      if (isActuallyActive) {
        activePlugins.add(whoAddress);
      } else {
        activePlugins.delete(whoAddress);
      }
    }
  }
  console.log('  Sanity check verified.');

  return Array.from(activePlugins).sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()));
}

// ── Solana Squads Info ─────────────────────────────────────────────────────

async function getSolanaSquadsInfo() {
  const rpcUrl = process.env.SOLANA_RPC_URL;
  const squadsAddress = process.env.SOLANA_SQUADS_MULTISIG_ACCOUNT;

  if (!rpcUrl || !squadsAddress) {
    console.log(`  Skipping Solana Squads: SOLANA_RPC_URL or SOLANA_SQUADS_MULTISIG_ACCOUNT not configured`);
    return null;
  }

  const connection = new Connection(rpcUrl);
  const multisigPda = new PublicKey(squadsAddress);

  // Uses the pattern from the Squads docs
  const multisigAccount = await Multisig.fromAccountAddress(connection, multisigPda);

  return {
    address: squadsAddress,
    owners: multisigAccount.members.map(m => m.key.toBase58()),
    threshold: multisigAccount.threshold,
  };
}

// ── Output ─────────────────────────────────────────────────────────────────

function printSafeInfo(info) {
  console.log(`\n  [${info.name}]`);
  console.log(`  Safe address : ${info.safeAddress}`);
  console.log(`  Threshold    : ${info.threshold} of ${info.owners.length}`);
  console.log('  Owners:');
  for (let i = 0; i < info.owners.length; i++) {
    console.log(`    ${i + 1}. ${info.owners[i]}`);
  }
}

function printAragonPluginAddresses(addresses) {
  const base = 'https://etherscan.io/address';
  for (const addr of addresses) {
    console.log(`  ${base}/${addr.toLowerCase()}`);
  }
}

// ── Main ───────────────────────────────────────────────────────────────────

async function main() {
  const ethRpc = process.env.RPC_ETHEREUM;
  let hadError = false;

  // ── Part 1: Safe multisigs ───────────────────────────────────────────────
  console.log('\n' + '='.repeat(60));
  console.log('SAFE MULTISIG WALLETS');
  console.log('='.repeat(60));

  const safeResults = [];
  for (const [, chainConfig] of Object.entries(SAFE_CHAINS)) {
    try {
      const info = await getSafeInfo(chainConfig);
      if (info) {
        safeResults.push(info);
        printSafeInfo(info);
      }
    } catch (error) {
      console.error(`\n  [${chainConfig.name}] Error: ${error.message}`);
      hadError = true;
    }
  }

  // Cross-check: owners and threshold should match across all Safes
  if (safeResults.length > 1) {
    console.log('\n  ' + '-'.repeat(50));
    const refOwners = new Set(safeResults[0].owners);
    const refThreshold = safeResults[0].threshold;
    let allMatch = true;

    for (let i = 1; i < safeResults.length; i++) {
      const otherOwners = new Set(safeResults[i].owners);
      const ownersMatch = refOwners.size === otherOwners.size && [...refOwners].every((o) => otherOwners.has(o));
      const thresholdMatch = refThreshold === safeResults[i].threshold;

      if (!ownersMatch || !thresholdMatch) {
        allMatch = false;
        if (!ownersMatch) {
          console.log(`  WARNING: Owners DIFFER between ${safeResults[0].name} and ${safeResults[i].name}`);
        }
        if (!thresholdMatch) {
          console.log(`  WARNING: Threshold DIFFERS between ${safeResults[0].name} (${refThreshold}) and ${safeResults[i].name} (${safeResults[i].threshold})`);
        }
      }
    }

    if (allMatch) {
      console.log(`  All Safe wallets have IDENTICAL owners and threshold (${refThreshold} of ${refOwners.size})`);
    }
  }

  // ── Part 2: Aragon DAO plugins ───────────────────────────────────────────
  console.log('\n' + '='.repeat(60));
  console.log('ARAGON DAO PLUGINS');
  console.log(`DAO: ${ARAGON_DAO}`);
  console.log('='.repeat(60));

  if (!ethRpc) {
    console.error('  Error: RPC_ETHEREUM not configured');
    process.exit(1);
  }

  try {
    const pluginAddresses = await getAragonPlugins(ethRpc);

    if (pluginAddresses.length === 0) {
      console.log('\n  No plugins detected with EXECUTE_PERMISSION');
    } else {
      console.log(`\n  Detected ${pluginAddresses.length} active plugin address(es):`);
      printAragonPluginAddresses(pluginAddresses);
    }
  } catch (error) {
    console.error(`\n  Error fetching Aragon plugins: ${error.message}`);
    hadError = true;
  }

  // ── Part 3: Solana Squads ────────────────────────────────────────────────
  console.log('\n' + '='.repeat(60));
  console.log('SOLANA SQUADS MULTISIG');
  console.log('='.repeat(60));

  try {
    const squadsInfo = await getSolanaSquadsInfo();
    if (squadsInfo) {
      console.log(`\n  [Solana Squads]`);
      console.log(`  Multisig account address : ${squadsInfo.address}`);
      console.log(`  Threshold    : ${squadsInfo.threshold} of ${squadsInfo.owners.length}`);
      console.log('  Members:');
      for (let i = 0; i < squadsInfo.members.length; i++) {
        console.log(`    ${i + 1}. ${squadsInfo.members[i]}`);
      }
    }
  } catch (error) {
    console.error(`\n  Error fetching Solana Squads: ${error.message}`);
    hadError = true;
  }

  if (hadError) {
    process.exit(1);
  }
}

main();
