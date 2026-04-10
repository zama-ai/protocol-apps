#!/usr/bin/env node

require('dotenv').config({ path: require('path').resolve(__dirname, '../.env') });
const { ethers } = require('ethers');
const { findDeploymentBlock } = require('./get-deployment-block');
const { Connection, PublicKey } = require('@solana/web3.js');
const multisig = require('@sqds/multisig');
const { Multisig } = multisig.accounts;

// Safe multisigs
const SAFE_CHAINS = {
  gateway: {
    name: 'Gateway',
    rpcEnv: 'RPC_GATEWAY',
    safeAddressEnv: 'ZAMA_SAFE_GATEWAY',
  },
  bsc: {
    name: 'BSC',
    rpcEnv: 'RPC_BSC',
    safeAddressEnv: 'ZAMA_SAFE_BSC',
  },
  hyperEvm: {
    name: 'HyperEVM',
    rpcEnv: 'RPC_HYPEREVM',
    safeAddressEnv: 'ZAMA_SAFE_HYPEREVM',
  },
};

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

async function getSafeInfo(chainConfig) {
  const { name, rpcEnv, safeAddressEnv } = chainConfig;
  const rpcUrl = process.env[rpcEnv];
  const safeAddress = process.env[safeAddressEnv];

  if (!rpcUrl) {
    console.log(`  Skipping ${name}: ${rpcEnv} not configured`);
    return null;
  }
  if (!safeAddress) {
    console.log(`  Skipping ${name}: ${safeAddressEnv} not configured`);
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

async function getAragonPlugins(rpcUrl, daoAddress) {
  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const dao = new ethers.Contract(daoAddress, PERMISSION_MANAGER_ABI, provider);

  const EXECUTE_PERMISSION_ID = ethers.keccak256(ethers.toUtf8Bytes('EXECUTE_PERMISSION'));

  console.log(`  Finding deployment block for DAO ${daoAddress}...`);
  const fromBlock = await findDeploymentBlock(daoAddress, { rpcUrl, silent: true });
  const toBlock = await provider.getBlockNumber();
  console.log(`  Deployment block: ${fromBlock}, current block: ${toBlock}`);

  // Filter: permissionId = EXECUTE_PERMISSION_ID, here = any, where = DAO address
  const grantFilter = dao.filters.Granted(EXECUTE_PERMISSION_ID);
  const revokeFilter = dao.filters.Revoked(EXECUTE_PERMISSION_ID);

  console.log('  Fetching permission events...');
  const grantEvents = await queryEventsInChunks(dao, grantFilter, fromBlock, toBlock, 'Granted');
  const revokeEvents = await queryEventsInChunks(dao, revokeFilter, fromBlock, toBlock, 'Revoked');

  const allEvents = [
    ...grantEvents
      .filter((e) => e.args.where.toLowerCase() === daoAddress.toLowerCase())
      .map((e) => ({
        type: 'grant',
        who: e.args.who,
        block: e.blockNumber,
        logIndex: e.index,
      })),
    ...revokeEvents
      .filter((e) => e.args.where.toLowerCase() === daoAddress.toLowerCase())
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
    const isActuallyActive = await dao.hasPermission(daoAddress, whoAddress, EXECUTE_PERMISSION_ID, "0x");
    const isExpectedActive = activePlugins.has(whoAddress);

    if (isActuallyActive !== isExpectedActive) {
      throw new Error(`On-chain permission state mismatch for ${whoAddress}`);
    }
  }
  console.log('  Sanity check passed.');

  return Array.from(activePlugins).sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()));
}

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

function printSafeInfo(info) {
  console.log(`\n[${info.name}]`);
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
    console.log(`    ${base}/${addr.toLowerCase()}`);
  }
}

// ── Main ───────────────────────────────────────────────────────────────────

async function main() {
  const ethRpc = process.env.RPC_ETHEREUM;
  const aragonDao = process.env.ZAMA_ARAGON_DAO;
  let hadError = false;

  // Part 1: Safe multisigs
  console.log('\n=== Safe Multisig Wallets ===');

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
          console.log(`\nWARNING: Owners DIFFER between ${safeResults[0].name} and ${safeResults[i].name}`);
        }
        if (!thresholdMatch) {
          console.log(`\nWARNING: Threshold DIFFERS between ${safeResults[0].name} (${refThreshold}) and ${safeResults[i].name} (${safeResults[i].threshold})`);
        }
      }
    }

    if (allMatch) {
      console.log(`\nAll Safe wallets have IDENTICAL owners and threshold (${refThreshold} of ${refOwners.size})`);
    }
  }

  // Part 2: Aragon DAO plugins
  console.log('\n=== Aragon DAO Plugins ===');
  console.log(`  DAO: ${aragonDao || '(not set)'}`);

  if (!ethRpc || !aragonDao) {
    if (!ethRpc) console.log('  Skipping: RPC_ETHEREUM not configured');
    if (!aragonDao) console.log('  Skipping: ZAMA_ARAGON_DAO not configured');
  } else try {
    const pluginAddresses = await getAragonPlugins(ethRpc, aragonDao);

    if (pluginAddresses.length === 0) {
      console.log('\nNo plugins detected with EXECUTE_PERMISSION');
    } else {
      console.log(`\nDetected ${pluginAddresses.length} active plugin address(es):`);
      printAragonPluginAddresses(pluginAddresses);
    }
  } catch (error) {
    console.error(`\n[Aragon] Error: ${error.message}`);
    hadError = true;
  }

  // Part 3: Solana Squads
  console.log('\n=== Solana Squads Multisig ===');

  try {
    const squadsInfo = await getSolanaSquadsInfo();
    if (squadsInfo) {
      console.log(`\n[Solana Squads]`);
      console.log(`  Multisig account : ${squadsInfo.address}`);
      console.log(`  Threshold        : ${squadsInfo.threshold} of ${squadsInfo.owners.length}`);
      console.log('  Members:');
      for (let i = 0; i < squadsInfo.owners.length; i++) {
        console.log(`    ${i + 1}. ${squadsInfo.owners[i]}`);
      }
    }
  } catch (error) {
    console.error(`\n[Solana Squads] Error: ${error.message}`);
    hadError = true;
  }

  if (hadError) {
    process.exit(1);
  }
}

main();
