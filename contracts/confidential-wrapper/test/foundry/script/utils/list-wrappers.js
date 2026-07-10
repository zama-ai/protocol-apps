#!/usr/bin/env node
/*
 * One-time banner: reads the loaded fixture registry and prints the wrappers under test.
 */

import { Interface } from 'ethers';

import { rpc, rpcUrl } from '../lib/anvil.js';

const REGISTRY = '0xeb5015fF021DB115aCe010f23F55C2591059bBA0';

const registryIface = new Interface([
  'function getTokenConfidentialTokenPairs() view returns (tuple(address token, address wrapper, bool valid)[])',
]);
const tokenIface = new Interface(['function symbol() view returns (string)', 'function name() view returns (string)']);

async function ethCall(rpcUrlValue, iface, to, fn) {
  const data = iface.encodeFunctionData(fn);
  const result = await rpc(rpcUrlValue, 'eth_call', [{ to, data }, 'latest']);
  return iface.decodeFunctionResult(fn, result);
}

async function wrapperString(rpcUrlValue, wrapper, fn) {
  try {
    return (await ethCall(rpcUrlValue, tokenIface, wrapper, fn))[0];
  } catch {
    return '<unavailable>';
  }
}

async function main() {
  const rpcUrlValue = process.argv[2] ?? rpcUrl();
  const [pairs] = await ethCall(rpcUrlValue, registryIface, REGISTRY, 'getTokenConfidentialTokenPairs');
  const valid = pairs.filter(pair => pair.valid);

  console.log(`Wrappers under test (${valid.length}):`);
  for (let i = 0; i < valid.length; i += 1) {
    const pair = valid[i];
    const symbol = await wrapperString(rpcUrlValue, pair.wrapper, 'symbol');
    const name = await wrapperString(rpcUrlValue, pair.wrapper, 'name');
    console.log(
      `  [${i}] wrapper=${pair.wrapper.toLowerCase()} underlying=${pair.token.toLowerCase()} symbol=${symbol} name=${name}`,
    );
  }
}

main().catch(error => {
  console.error(error.message);
  process.exit(1);
});
