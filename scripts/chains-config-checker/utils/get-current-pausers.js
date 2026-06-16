#!/usr/bin/env node

require('dotenv').config({ path: require('path').resolve(__dirname, '../.env') });
const { ethers } = require('ethers');
const { findDeploymentBlock, isValidAddress } = require('./get-deployment-block');
const { queryEventsInChunks } = require('./lib/events');

// PauserSet event signatures
const PAUSER_SET_ABI = [
  'event AddPauser(address account)',
  'event RemovePauser(address account)',
  'event SwapPauser(address oldAccount, address newAccount)',
];

// Chain configurations from environment.
// `symbol` is the native gas token, used only for balance display.
const CHAINS = {
  ethereum: {
    name: 'Ethereum',
    symbol: 'ETH',
    rpcUrl: process.env.RPC_ETHEREUM,
    pauserSetAddress: process.env.PAUSER_SET_ETHEREUM,
  },
  gateway: {
    name: 'Gateway',
    symbol: 'ETH',
    rpcUrl: process.env.RPC_GATEWAY,
    pauserSetAddress: process.env.PAUSER_SET_GATEWAY,
  },
  polygon: {
    name: 'Polygon',
    symbol: 'POL',
    rpcUrl: process.env.RPC_POLYGON,
    pauserSetAddress: process.env.PAUSER_SET_POLYGON,
  },
};

async function getPausersForChain(chainConfig) {
  const { name, rpcUrl, pauserSetAddress } = chainConfig;

  if (!rpcUrl) {
    console.log(`  Skipping ${name}: RPC_URL not configured`);
    return null;
  }

  if (!pauserSetAddress) {
    console.log(`  Skipping ${name}: PAUSER_SET address not configured`);
    return null;
  }

  if (!isValidAddress(pauserSetAddress)) {
    console.log(`  Skipping ${name}: Invalid address format`);
    return null;
  }

  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const contract = new ethers.Contract(pauserSetAddress, PAUSER_SET_ABI, provider);

  // Find deployment block
  console.log(`  Finding deployment block for ${pauserSetAddress}...`);
  const fromBlock = await findDeploymentBlock(pauserSetAddress, { rpcUrl, silent: true });
  console.log(`  Deployment block: ${fromBlock}`);

  // Get current block
  const toBlock = await provider.getBlockNumber();
  console.log(`  Current block: ${toBlock}`);

  // Query all events from deployment to latest (in chunks, sequentially for clean output)
  console.log('  Fetching pauser events...');

  const addEvents = await queryEventsInChunks(contract, contract.filters.AddPauser(), fromBlock, toBlock, 'AddPauser');
  const removeEvents = await queryEventsInChunks(contract, contract.filters.RemovePauser(), fromBlock, toBlock, 'RemovePauser');
  const swapEvents = await queryEventsInChunks(contract, contract.filters.SwapPauser(), fromBlock, toBlock, 'SwapPauser');

  // Combine and sort all events by block number and log index
  const allEvents = [
    ...addEvents.map((e) => ({ type: 'add', account: e.args.account, block: e.blockNumber, logIndex: e.index })),
    ...removeEvents.map((e) => ({ type: 'remove', account: e.args.account, block: e.blockNumber, logIndex: e.index })),
    ...swapEvents.map((e) => ({
      type: 'swap',
      oldAccount: e.args.oldAccount,
      newAccount: e.args.newAccount,
      block: e.blockNumber,
      logIndex: e.index,
    })),
  ].sort((a, b) => {
    if (a.block !== b.block) return a.block - b.block;
    return a.logIndex - b.logIndex;
  });

  // Process events chronologically to build current pauser set
  const pausers = new Set();

  for (const event of allEvents) {
    switch (event.type) {
      case 'add':
        pausers.add(event.account);
        break;
      case 'remove':
        pausers.delete(event.account);
        break;
      case 'swap':
        pausers.delete(event.oldAccount);
        pausers.add(event.newAccount);
        break;
    }
  }

  return { pausers: Array.from(pausers), provider };
}

function formatNative(balanceWei) {
  const balance = ethers.formatEther(balanceWei);
  // Format to 6 decimal places, removing trailing zeros
  const formatted = parseFloat(balance).toFixed(6).replace(/\.?0+$/, '');
  return formatted === '' ? '0' : formatted;
}

async function printPausers(chainName, symbol, pausers, provider) {
  console.log(`\n${chainName} pausers:`);
  if (pausers === null) {
    console.log('  (not configured)');
  } else if (pausers.length === 0) {
    console.log('  (none)');
  } else {
    for (let i = 0; i < pausers.length; i++) {
      const pauser = pausers[i];
      const balance = await provider.getBalance(pauser);
      const balanceFormatted = formatNative(balance);
      console.log(`  ${i + 1}. ${pauser} (${balanceFormatted} ${symbol})`);
    }
  }
  if (pausers !== null) {
    console.log(`  Total: ${pausers.length} pauser(s)`);
  }
}

// Compare the pauser sets across every chain that returned results.
function compareAcrossChains(results) {
  const configured = Object.keys(results).filter((key) => results[key]?.pausers);
  if (configured.length < 2) return;

  console.log('\n' + '-'.repeat(50));

  // Map each pauser to the set of chains it currently appears on.
  const presence = new Map(); // pauser => Set(chain keys)
  for (const key of configured) {
    for (const pauser of results[key].pausers) {
      if (!presence.has(pauser)) presence.set(pauser, new Set());
      presence.get(pauser).add(key);
    }
  }

  const chainCount = configured.length;
  const identical = [...presence.values()].every((chains) => chains.size === chainCount);

  if (identical) {
    console.log(`Pausers are IDENTICAL across all ${chainCount} configured chains.`);
    return;
  }

  console.log('WARNING: Pausers DIFFER between chains!');
  for (const [pauser, chains] of presence) {
    if (chains.size === chainCount) continue;
    const present = configured.filter((key) => chains.has(key)).map((key) => CHAINS[key].name);
    const missing = configured.filter((key) => !chains.has(key)).map((key) => CHAINS[key].name);
    console.log(`\n  ${pauser}`);
    console.log(`    on:      ${present.join(', ')}`);
    console.log(`    missing: ${missing.join(', ')}`);
  }
}

async function main() {
  // Determine which chains are fully configured (both RPC and address present).
  const configuredKeys = Object.keys(CHAINS).filter(
    (key) => CHAINS[key].rpcUrl && CHAINS[key].pauserSetAddress
  );

  if (configuredKeys.length === 0) {
    console.error('Error: No chains configured. Please set environment variables in .env file:');
    for (const key of Object.keys(CHAINS)) {
      const suffix = key.toUpperCase();
      console.error(`  RPC_${suffix}, PAUSER_SET_${suffix}`);
    }
    process.exit(1);
  }

  const results = {};

  try {
    // Fetch pausers for every configured chain.
    for (const key of configuredKeys) {
      console.log(`\n[${CHAINS[key].name}]`);
      results[key] = await getPausersForChain(CHAINS[key]);
    }

    // Print summary
    console.log('\n' + '='.repeat(50));
    console.log('SUMMARY');
    console.log('='.repeat(50));

    for (const key of configuredKeys) {
      await printPausers(
        CHAINS[key].name,
        CHAINS[key].symbol,
        results[key]?.pausers ?? null,
        results[key]?.provider
      );
    }

    // Compare pausers across all configured chains.
    compareAcrossChains(results);
  } catch (error) {
    console.error(`\nError: ${error.message}`);
    process.exit(1);
  }
}

main();
