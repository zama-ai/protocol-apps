#!/usr/bin/env node

import { AbiCoder } from "ethers";

import { REGISTRY, RPC, decodePairs, ethCall, normalizeAddress } from "../bake.mjs";

const ABI_CODER = AbiCoder.defaultAbiCoder();

function decodeString(raw) {
  return ABI_CODER.decode(["string"], raw)[0];
}

async function wrapperString(wrapper, signature, rpcUrl) {
  try {
    return decodeString(await ethCall(wrapper, signature, [], rpcUrl, "latest"));
  } catch {
    return "<unavailable>";
  }
}

async function main() {
  const rpcUrl = process.argv[2] ?? RPC;
  const pairsRaw = await ethCall(REGISTRY, "getTokenConfidentialTokenPairs()", [], rpcUrl, "latest");
  const pairs = decodePairs(pairsRaw).filter((pair) => pair.valid);

  console.log(`Wrappers under test (${pairs.length}):`);
  for (let i = 0; i < pairs.length; i += 1) {
    const pair = pairs[i];
    const symbol = await wrapperString(pair.wrapper, "symbol()", rpcUrl);
    const name = await wrapperString(pair.wrapper, "name()", rpcUrl);
    console.log(
      `  [${i}] wrapper=${normalizeAddress(pair.wrapper)} underlying=${normalizeAddress(pair.token)} symbol=${symbol} name=${name}`,
    );
  }
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
