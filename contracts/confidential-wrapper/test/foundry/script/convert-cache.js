#!/usr/bin/env node
/*
 * Convert a committed forge fork read-cache into the offline Anvil fixture.
 *
 * `forge test --fork-url <archive>` lazily reads exactly the code and storage the
 * suite touches and flushes it to ~/.foundry/cache/rpc/<chain>/<block>. `make bake`
 * copies that file to deployments/mainnet-fork/read-cache.json; this script replays
 * it into a blank Anvil overlay (which anvil_dumpState can serialize) and writes
 * the raw anvil_dumpState hex to anvil-state.json plus a manifest.
 */

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { rpc, rpcUrl, startAnvil, stopAnvil } from './lib/anvil.js';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = resolve(SCRIPT_DIR, '..');
const OUT_DIR = resolve(ROOT_DIR, 'deployments/mainnet-fork');
const READ_CACHE_FILE = resolve(OUT_DIR, 'read-cache.json');
const STATE_FILE = resolve(OUT_DIR, 'anvil-state.json');
const MANIFEST_FILE = resolve(OUT_DIR, 'manifest.json');

const CHAIN_ID = 31337;
const REGISTRY = '0xeb5015fF021DB115aCe010f23F55C2591059bBA0';
const PORT = 8545;
const RPC = rpcUrl(PORT);

function normalizeAddress(address) {
  return `0x${address.toLowerCase().replace(/^0x/u, '').padStart(40, '0')}`;
}

function word(hex) {
  return `0x${hex.toLowerCase().replace(/^0x/u, '').padStart(64, '0')}`;
}

function quantity(value = 0) {
  return `0x${BigInt(value).toString(16)}`;
}

function codeShape(code) {
  if (!code) return 'empty';
  if (typeof code === 'string') return 'string';
  return Object.keys(code).sort().join('+') || 'object';
}

function normalizeCodeHex(hex) {
  const body = hex.replace(/^0x/u, '');
  return body.length === 0 ? '0x' : `0x${body}`;
}

// forge serializes bytecode either as a plain "0x.." string or as tagged
// objects. LegacyAnalyzed bytecode carries an analysis pad beyond the real code;
// keep only original_len bytes. Other known raw encodings can be replayed as-is.
function accountCode(address, code) {
  if (!code) return '0x';
  if (typeof code === 'string') return normalizeCodeHex(code);

  if (code.LegacyAnalyzed) {
    const analyzed = code.LegacyAnalyzed;
    if (typeof analyzed.bytecode !== 'string') {
      throw new Error(`Unsupported LegacyAnalyzed bytecode for ${address}.`);
    }
    const len = Number(analyzed.original_len ?? 0);
    return normalizeCodeHex(analyzed.bytecode.replace(/^0x/u, '').slice(0, len * 2));
  }

  if (typeof code.LegacyRaw === 'string') return normalizeCodeHex(code.LegacyRaw);
  if (typeof code.LegacyRaw?.bytecode === 'string') return normalizeCodeHex(code.LegacyRaw.bytecode);
  if (typeof code.LegacyRaw?.raw === 'string') return normalizeCodeHex(code.LegacyRaw.raw);
  if (typeof code.Eip7702?.raw === 'string') return normalizeCodeHex(code.Eip7702.raw);

  throw new Error(`Unsupported bytecode shape for ${address}: ${Object.keys(code).join(', ')}`);
}

function readCache() {
  let raw;
  try {
    raw = readFileSync(READ_CACHE_FILE, 'utf8');
  } catch {
    throw new Error(`Missing ${READ_CACHE_FILE}. Run 'make bake' to warm and copy the forge read cache first.`);
  }
  const cache = JSON.parse(raw);
  const accounts = cache.accounts ?? {};
  const storage = cache.storage ?? {};
  if (Object.keys(accounts).length === 0) {
    throw new Error(`${READ_CACHE_FILE} has no accounts; the warm-up run did not populate the fork cache.`);
  }
  const hasRegistry = Object.keys(accounts).some(a => normalizeAddress(a) === normalizeAddress(REGISTRY));
  if (!hasRegistry) {
    throw new Error(`${READ_CACHE_FILE} has no registry account ${REGISTRY}; the warm-up run is incomplete.`);
  }
  const blockEnv = cache.meta?.block_env;
  if (!blockEnv?.number) {
    throw new Error(`${READ_CACHE_FILE} is missing meta.block_env.number; cannot write a pinned manifest.`);
  }
  const blockNumber = Number(BigInt(blockEnv.number));
  return { accounts, storage, blockNumber, blockEnv, blockHashes: cache.block_hashes ?? {} };
}

async function materialize({ accounts, storage }) {
  let accountCount = 0;
  let codeCount = 0;
  const bytecodeShapes = {};
  for (const [address, account] of Object.entries(accounts)) {
    await rpc(RPC, 'anvil_setBalance', [address, account.balance ?? '0x0']);
    await rpc(RPC, 'anvil_setNonce', [address, quantity(account.nonce ?? 0)]);
    const shape = codeShape(account.code);
    bytecodeShapes[shape] = (bytecodeShapes[shape] ?? 0) + 1;
    const code = accountCode(address, account.code);
    if (code !== '0x') {
      await rpc(RPC, 'anvil_setCode', [address, code]);
      codeCount += 1;
    }
    accountCount += 1;
  }

  let slotCount = 0;
  for (const [address, slots] of Object.entries(storage)) {
    for (const [slot, value] of Object.entries(slots)) {
      await rpc(RPC, 'anvil_setStorageAt', [address, word(slot), word(value)]);
      slotCount += 1;
    }
  }
  return { accountCount, bytecodeShapes, codeCount, slotCount };
}

async function dumpState() {
  const state = await rpc(RPC, 'anvil_dumpState', []);
  if (typeof state !== 'string' || !state.startsWith('0x')) {
    throw new Error('anvil_dumpState did not return raw hex.');
  }
  if (state.length < 10000) {
    throw new Error('anvil_dumpState is unexpectedly small; materialization likely failed.');
  }
  writeFileSync(STATE_FILE, state);
}

function writeManifest({ blockNumber, blockEnv, blockHashes }) {
  const generatedAt = new Date().toISOString().replace(/\.\d{3}Z$/u, 'Z');
  writeFileSync(
    MANIFEST_FILE,
    `${JSON.stringify(
      {
        forkBlock: blockNumber,
        readCacheBlock: blockNumber,
        chainId: CHAIN_ID,
        registry: REGISTRY,
        generatedAt,
        sourceBlockEnv: blockEnv,
        sourceBlockHashes: blockHashes,
      },
      null,
      2,
    )}\n`,
  );
}

async function run() {
  mkdirSync(OUT_DIR, { recursive: true });
  const cache = readCache();
  console.log(
    `Read cache: ${Object.keys(cache.accounts).length} accounts, fork block ${cache.blockNumber ?? 'unknown'}`,
  );

  let anvil;
  try {
    anvil = await startAnvil({ port: PORT, chainId: CHAIN_ID, logPath: '/tmp/convert-cache-anvil.log' });
    activeAnvil = anvil;

    console.log('Replaying read cache into Anvil overlay...');
    const { accountCount, bytecodeShapes, codeCount, slotCount } = await materialize(cache);
    console.log(`Materialized ${accountCount} accounts (${codeCount} with code) and ${slotCount} storage slots.`);
    console.log(
      `Bytecode shapes: ${Object.entries(bytecodeShapes)
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([shape, count]) => `${shape}=${count}`)
        .join(', ')}`,
    );

    await rpc(RPC, 'anvil_mine', ['0x1']);

    console.log(`Dumping Anvil state -> ${STATE_FILE}`);
    await dumpState();
    console.log(`Writing manifest -> ${MANIFEST_FILE}`);
    writeManifest(cache);
    console.log(`Done. Commit ${OUT_DIR}/*`);
  } finally {
    await stopAnvil(anvil);
    if (activeAnvil === anvil) activeAnvil = undefined;
  }
}

let activeAnvil;

process.once('SIGINT', async () => {
  await stopAnvil(activeAnvil);
  process.exit(130);
});
process.once('SIGTERM', async () => {
  await stopAnvil(activeAnvil);
  process.exit(143);
});

run().catch(error => {
  console.error(error.message);
  process.exit(1);
});
