#!/usr/bin/env node

require('dotenv').config({ path: require('path').resolve(__dirname, '../.env') });
const { ethers } = require('ethers');
const { isValidAddress } = require('./get-deployment-block');

const ETHEREUM_RPC_URL = process.env.RPC_ETHEREUM;
const ZAMA_OFT_ADAPTER_ETHEREUM = process.env.ZAMA_OFT_ADAPTER_ETHEREUM;

const ADAPTER_ABI = [
  'function owner() view returns (address)',
  'function endpoint() view returns (address)',
];

const ENDPOINT_ABI = [
  'function delegates(address) view returns (address)',
];

async function getOftOwnerAndDelegate() {
  if (!ETHEREUM_RPC_URL) {
    throw new Error('RPC_ETHEREUM is not configured');
  }

  if (!ZAMA_OFT_ADAPTER_ETHEREUM) {
    throw new Error('ZAMA_OFT_ADAPTER_ETHEREUM is not configured');
  }

  if (!isValidAddress(ZAMA_OFT_ADAPTER_ETHEREUM)) {
    throw new Error('Invalid ZAMA_OFT_ADAPTER_ETHEREUM address format');
  }

  const provider = new ethers.JsonRpcProvider(ETHEREUM_RPC_URL);
  const adapter = new ethers.Contract(ZAMA_OFT_ADAPTER_ETHEREUM, ADAPTER_ABI, provider);

  const [owner, endpointAddress] = await Promise.all([
    adapter.owner(),
    adapter.endpoint(),
  ]);

  const endpoint = new ethers.Contract(endpointAddress, ENDPOINT_ABI, provider);
  const delegate = await endpoint.delegates(ZAMA_OFT_ADAPTER_ETHEREUM);

  return { owner, endpointAddress, delegate, provider };
}

async function printOftOwnerAndDelegate({ owner, endpointAddress, delegate, provider }) {
  console.log('[Ethereum ZamaOFTAdapter]');
  console.log(`  Adapter address : ${ZAMA_OFT_ADAPTER_ETHEREUM}`);
  console.log(`  Endpoint address: ${endpointAddress}`);
  console.log(`  Owner           : ${owner}`);
  console.log(`  Delegate        : ${delegate}`);
}

async function main() {
  try {
    const info = await getOftOwnerAndDelegate();
    await printOftOwnerAndDelegate(info);
  } catch (error) {
    console.error(`\nError: ${error.message}`);
    process.exit(1);
  }
}

main();

