#!/usr/bin/env node

require('dotenv').config({ path: require('path').resolve(__dirname, '../.env') });
const { ethers } = require('ethers');
const { isValidAddress } = require('./get-deployment-block');

const CHAINS = {
  ethereumGovernanceOAppSender: {
    name: 'Ethereum GovernanceOAppSender',
    rpcEnv: 'RPC_ETHEREUM',
    addrEnv: 'ZAMA_GOVERNANCE_OAPP_SENDER_ETHEREUM',
  },
  gatewayGovernanceOAppReceiver: {
    name: 'Gateway GovernanceOAppReceiver',
    rpcEnv: 'RPC_GATEWAY',
    addrEnv: 'ZAMA_GOVERNANCE_OAPP_RECEIVER_GATEWAY',
  },
};

const OAPP_ABI = [
  'function owner() view returns (address)',
  'function endpoint() view returns (address)',
];

const ENDPOINT_ABI = [
  'function delegates(address) view returns (address)',
];

function buildChainConfigs() {
  return Object.entries(CHAINS).map(([key, chain]) => ({
    key,
    name: chain.name,
    rpcUrl: process.env[chain.rpcEnv],
    contractAddress: process.env[chain.addrEnv],
  }));
}

async function getOwnerAndDelegateForChain(chainConfig) {
  const { name, rpcUrl, contractAddress } = chainConfig;

  if (!rpcUrl) throw new Error(`[${name}] RPC URL is not configured`);
  if (!contractAddress) throw new Error(`[${name}] Contract address is not configured`);
  if (!isValidAddress(contractAddress)) throw new Error(`[${name}] Invalid contract address format`);

  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const oapp = new ethers.Contract(contractAddress, OAPP_ABI, provider);

  const [owner, endpointAddress] = await Promise.all([
    oapp.owner(),
    oapp.endpoint(),
  ]);

  const endpoint = new ethers.Contract(endpointAddress, ENDPOINT_ABI, provider);
  const delegate = await endpoint.delegates(contractAddress);

  return {
    name,
    contractAddress,
    owner,
    delegate,
    equal: owner === delegate,
  };
}

function printOwnerAndDelegate(info) {
  const { name, contractAddress, owner, delegate } = info;
  console.log(`\n[${name}]`);
  console.log(`  OApp address : ${contractAddress}`);
  console.log(`  Owner        : ${owner}`);
  console.log(`  Delegate     : ${delegate}`);
}

async function main() {
  const configs = buildChainConfigs();
  const toRun = configs.filter((c) => c.rpcUrl && c.contractAddress && isValidAddress(c.contractAddress));
  const toSkip = configs.filter((c) => !c.rpcUrl || !c.contractAddress || !isValidAddress(c.contractAddress || ''));

  for (const c of toSkip) {
    if (!c.rpcUrl) {
      console.log(`  Skipping ${c.name}: RPC not configured`);
    } else if (!c.contractAddress) {
      console.log(`  Skipping ${c.name}: Contract address not configured`);
    } else {
      console.log(`  Skipping ${c.name}: Invalid address format`);
    }
  }

  if (toRun.length === 0) {
    console.error('Error: No chains configured. Set RPC and contract address env vars in .env');
    process.exit(1);
  }

  let hadError = false;
  const equalityResults = [];

  console.log('\n=== Governance OApp ===');
  for (const chainConfig of toRun) {
    try {
      const info = await getOwnerAndDelegateForChain(chainConfig);
      printOwnerAndDelegate(info);
      equalityResults.push({ name: chainConfig.name, equal: info.equal });
    } catch (error) {
      console.error(`\n[${chainConfig.name}] Error: ${error.message}`);
      hadError = true;
    }
  }

  if (hadError) process.exit(1);

  const failed = equalityResults.filter((r) => !r.equal);
  if (failed.length > 0) {
    for (const { name } of failed) {
      console.error(`Owner and Delegate are NOT IDENTICAL on ${name}`);
    }
    process.exit(1);
  }

  console.log('\nOwner and Delegate should be IDENTICAL on each chain.');
}

main();
