#!/usr/bin/env node
/*
 * Incremental blacklist-only fixture refresh.
 *
 * Loads the committed Anvil dump into a blank local Anvil, scans blacklist
 * add/remove logs forward from blacklist-cache.json, writes only the changed
 * membership slots, then re-dumps the fixture. Contract code/storage stays at
 * the committed fixture pin; only blacklistScannedBlock moves forward.
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  ENV_FILE,
  MANIFEST_FILE,
  OUT_DIR,
  REGISTRY,
  ROOT_DIR,
  RPC,
  STATE_FILE,
  blockHex,
  decodePairs,
  ethCall,
  materializeBlacklists,
  readEnvValue,
  rpc,
  startAnvil,
  stopAnvil,
} from "./bake.mjs";

function isMain() {
  return process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
}

function loadArchiveRpc() {
  const forkUrl =
    process.env.CONFIDENTIAL_WRAPPER_UPGRADE_TEST_RPC_URL ??
    readEnvValue(ENV_FILE, "CONFIDENTIAL_WRAPPER_UPGRADE_TEST_RPC_URL");
  if (!forkUrl) {
    throw new Error(
      "CONFIDENTIAL_WRAPPER_UPGRADE_TEST_RPC_URL is not set. Add it to contracts/confidential-wrapper/.env (see .env.example).",
    );
  }
  return forkUrl;
}

function readStateDump() {
  if (!existsSync(STATE_FILE)) {
    throw new Error(`Missing committed fixture: ${STATE_FILE}. Run 'make bake' first.`);
  }
  const state = readFileSync(STATE_FILE, "utf8").trim();
  if (!state.startsWith("0x")) {
    throw new Error(`${STATE_FILE} is not a raw anvil_dumpState hex string.`);
  }
  return state;
}

async function loadStateDump(state) {
  const loaded = await rpc(RPC, "anvil_loadState", [state]);
  if (loaded !== true) throw new Error("anvil_loadState did not return true.");
}

async function resolveTargetBlock(archiveRpc) {
  if (process.env.FORK_BLOCK) return Number(process.env.FORK_BLOCK);
  return Number(BigInt(await rpc(archiveRpc, "eth_blockNumber", [])));
}

async function dumpState() {
  console.log(`Dumping Anvil state -> ${STATE_FILE}`);
  const state = await rpc(RPC, "anvil_dumpState", []);
  if (typeof state !== "string" || !state.startsWith("0x")) {
    throw new Error("anvil_dumpState did not return raw hex.");
  }
  if (state.length < 10000) {
    throw new Error("anvil_dumpState is unexpectedly small; refresh likely failed.");
  }
  writeFileSync(STATE_FILE, state);
}

function updateManifest(blockNumber) {
  console.log(`Recording blacklistScannedBlock=${blockNumber} in ${MANIFEST_FILE}`);
  const manifest = JSON.parse(readFileSync(MANIFEST_FILE, "utf8"));
  manifest.blacklistScannedBlock = blockNumber;
  writeFileSync(MANIFEST_FILE, `${JSON.stringify(manifest, null, 2)}\n`);
}

async function runBlacklistRefresh() {
  process.chdir(ROOT_DIR);
  mkdirSync(OUT_DIR, { recursive: true });

  const archiveRpc = loadArchiveRpc();
  const targetBlock = await resolveTargetBlock(archiveRpc);
  const state = readStateDump();

  let anvil;
  try {
    anvil = await startAnvil({ logPath: "/tmp/bake-blacklist-anvil.log" });
    activeAnvil = anvil;

    console.log("Loading committed fixture...");
    await loadStateDump(state);

    console.log(`Refreshing blacklist storage incrementally up to block ${targetBlock}...`);
    const context = {
      localRpc: RPC,
      traceRpc: RPC,
      sourceRpc: archiveRpc,
      sourceBlockRpc: blockHex(targetBlock),
      resolvedBlock: targetBlock,
    };

    const pairsRaw = await ethCall(REGISTRY, "getTokenConfidentialTokenPairs()", [], context.localRpc, "latest");
    const pairs = decodePairs(pairsRaw);
    await materializeBlacklists(
      pairs.map((pair) => pair.token),
      "delta",
      context,
    );

    await rpc(RPC, "anvil_mine", ["0x1"]);
    await dumpState();
    updateManifest(targetBlock);
    console.log(`Done. Commit ${OUT_DIR}/*`);
  } finally {
    await stopAnvil(anvil);
    if (activeAnvil === anvil) activeAnvil = undefined;
  }
}

let activeAnvil;

if (isMain()) {
  process.once("SIGINT", async () => {
    await stopAnvil(activeAnvil);
    process.exit(130);
  });
  process.once("SIGTERM", async () => {
    await stopAnvil(activeAnvil);
    process.exit(143);
  });

  runBlacklistRefresh().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
