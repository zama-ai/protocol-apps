#!/usr/bin/env node
/*
 * Manual, network-bound fixture generator (ADR-010 "bake + commit").
 *
 * Forks mainnet with Anvil, explicitly materializes the forked accounts into
 * Anvil's local overlay, dumps the resulting raw anvil_dumpState hex to a
 * committed fixture, and writes the manifest + blacklist sidecar.
 *
 * Source reads always come from the configured archive RPC pinned to the fork
 * block. Local Anvil is only the destination for anvil_* overlay writes.
 */

import { spawn } from "node:child_process";
import { createWriteStream, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { AbiCoder, concat, id, keccak256, toBeHex, zeroPadValue } from "ethers";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = resolve(SCRIPT_DIR, "..");
const ENV_FILE = resolve(ROOT_DIR, "../../.env");

const CHAIN_ID = 31337;
const PORT = 8545;
const RPC = `http://localhost:${PORT}`;
const OUT_DIR = resolve(ROOT_DIR, "deployments/mainnet-fork");
const STATE_FILE = resolve(OUT_DIR, "anvil-state.json");
const MANIFEST_FILE = resolve(OUT_DIR, "manifest.json");
const BLACKLIST_FILE = resolve(OUT_DIR, "blacklist-cache.json");
const BLACKLIST_INTERFACES_FILE = resolve(ROOT_DIR, "config/blacklist-interfaces.json");

const REGISTRY = "0xeb5015fF021DB115aCe010f23F55C2591059bBA0";
const MAINNET_USDC = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48";
const BL_PROBE = "0x000000000000000000000000000000000000dEaD";
const IERC1363_INTERFACE_ID = "0xb0202a11";

// Standard upgradeability/admin slots read by the proxy and inherited upgradeable bases.
// These must be baked alongside code so delegatecalls, initializer guards, and owner checks
// see the same state after anvil_loadState.
const IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
const INITIALIZABLE_SLOT = "0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00";
const OWNABLE_SLOT = "0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300";

// Mainnet USDC is a legacy ZeppelinOS proxy, not EIP-1967. Metadata calls delegate
// through this implementation slot, so the bake keeps it explicit rather than relying
// on access-list side effects to discover proxy mechanics.
const USDC_LEGACY_IMPLEMENTATION_SLOT =
  "0x7050c9e0f4ca769c69bd3a8ef740bc37934f8e2c036e5a723fd8ee048ed3f8c3";

// ERC-7201 storage roots from the deployed registry/wrapper contracts. Offsets below
// are intentionally copied by semantic use, not by a broad storage dump: the fixture
// should contain only state needed by offline fork tests.
const REGISTRY_STORAGE_SLOT = "0xc361bd0b1d7584416623b46edb98317525b8de8e557ab49cee21f14d6752da00";
const ERC7984_STORAGE_SLOT = "0xabe6faf3f1b202c971f9850194a6389c7b24dbc9035a913f45a1f82a5d968c00";
const WRAPPER_STORAGE_SLOT = "0x789981291a45bfde11e7ba326d04f33e2215f03c85dfc0acebcc6167a5924700";
const CONFIDENTIAL_WRAPPER_V3_STORAGE_SLOT =
  "0xfbb2c4771bcc77528b8fd58eedad6a4f84fdaf9eea4a56a2752391a0c87eee00";
const FHEVM_CONFIG_SLOT = "0x9e7b61f58c47dc699ac88507c4f5bb9f121c03808c5676a8078fe583e4649700";

// Tests run against the local fhEVM host deployed by forge-fhevm, not the mainnet
// coprocessor/KMS contracts stored in production wrapper config.
const LOCAL_FHEVM_ACL = "0x50157CFfD6bBFA2DECe204a89ec419c23ef5755D";
const LOCAL_FHEVM_COPROCESSOR = "0xe3a9105a3a932253A70F126eb1E3b589C643dD24";
const LOCAL_FHEVM_KMS_VERIFIER = "0x901F8942346f7AB3a01F6D7613119Bca447Bb030";

const BL_CHUNK = Number(process.env.BL_CHUNK ?? "45000");
const BL_SCAN_PROGRESS = Number(process.env.BL_SCAN_PROGRESS ?? "1");
const BL_WRITE_PROGRESS = Number(process.env.BL_WRITE_PROGRESS ?? "100");
const ABI_CODER = AbiCoder.defaultAbiCoder();

function now() {
  return new Date().toISOString().slice(11, 19);
}

function sleep(ms) {
  return new Promise((resolveSleep) => setTimeout(resolveSleep, ms));
}

function normalizeAddress(address) {
  return `0x${address.toLowerCase().replace(/^0x/, "").padStart(40, "0")}`;
}

function normalizeHex(hex) {
  return hex.toLowerCase();
}

function blockHex(blockNumber) {
  return `0x${BigInt(blockNumber).toString(16)}`;
}

function wordHex(value) {
  return `0x${BigInt(value).toString(16).padStart(64, "0")}`;
}

function padAddress(address) {
  return `0x${address.toLowerCase().replace(/^0x/, "").padStart(64, "0")}`;
}

function hexAdd(hex, offset) {
  return wordHex(BigInt(hex) + BigInt(offset));
}

function parseSignatureTypes(signature) {
  const args = signature.match(/\((.*)\)$/u)?.[1]?.trim() ?? "";
  return args === "" ? [] : args.split(",").map((arg) => arg.trim());
}

function calldataFor(signature, args = []) {
  const types = parseSignatureTypes(signature);
  if (types.length !== args.length) {
    throw new Error(`${signature} expects ${types.length} args, got ${args.length}`);
  }
  const selector = id(signature).slice(0, 10);
  if (types.length === 0) return selector;
  return `${selector}${ABI_CODER.encode(types, args).slice(2)}`;
}

function canonicalEventSignature(signature) {
  const match = signature.trim().match(/^([A-Za-z_][A-Za-z0-9_]*)\((.*)\)$/u);
  if (!match) throw new Error(`Invalid event signature: ${signature}`);
  const params = match[2].trim();
  if (!params) return `${match[1]}()`;
  const types = params.split(",").map((param) => {
    const withoutIndexed = param.trim().replace(/\s+indexed\b/u, "");
    return withoutIndexed.split(/\s+/u)[0];
  });
  return `${match[1]}(${types.join(",")})`;
}

function eventTopic(signature) {
  return normalizeHex(id(canonicalEventSignature(signature)));
}

function mappingSlot(address, slot) {
  return keccak256(concat([zeroPadValue(normalizeAddress(address), 32), zeroPadValue(toBeHex(BigInt(slot)), 32)]));
}

function addressFromWord(word) {
  return normalizeAddress(`0x${word.replace(/^0x/, "").slice(-40)}`);
}

function isZeroAddress(address) {
  return normalizeAddress(address) === "0x0000000000000000000000000000000000000000";
}

function highBitWord(sourceWord, denied) {
  const bit = 1n << 255n;
  const value = BigInt(sourceWord || "0x0");
  return wordHex(denied ? value | bit : value & ~bit);
}

function wordDenyValue(denied) {
  return denied ? wordHex(1n) : wordHex(0n);
}

function readEnvValue(path, key) {
  if (!existsSync(path)) return undefined;
  for (const rawLine of readFileSync(path, "utf8").split(/\r?\n/u)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const match = line.match(/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$/u);
    if (!match || match[1] !== key) continue;
    let value = match[2].trim();
    const quote = value[0];
    if ((quote === '"' || quote === "'") && value.endsWith(quote)) {
      value = value.slice(1, -1);
    }
    return value;
  }
  return undefined;
}

async function rpc(rpcUrl, method, params = []) {
  const response = await fetch(rpcUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ id: 1, jsonrpc: "2.0", method, params }),
  });
  if (!response.ok) {
    throw new Error(`RPC ${method} failed with HTTP ${response.status}`);
  }
  const body = await response.json();
  if (body.error) {
    const code = body.error.code === undefined ? "" : ` (${body.error.code})`;
    throw new Error(body.error.message ? `RPC ${method} failed${code}: ${body.error.message}` : `RPC ${method} failed${code}`);
  }
  return body.result;
}

async function startAnvil({ forkUrl, forkBlock, logPath = "/tmp/bake-anvil.log" } = {}) {
  let portBusy = false;
  try {
    await rpc(RPC, "eth_chainId", []);
    portBusy = true;
  } catch {
    // Expected when nothing is listening yet.
  }
  if (portBusy) {
    throw new Error(`Port ${PORT} is already serving Ethereum RPC at ${RPC}. Stop that Anvil process before baking.`);
  }

  const args = ["--chain-id", String(CHAIN_ID), "--port", String(PORT)];
  if (forkUrl) args.push("--fork-url", forkUrl);
  if (forkBlock) args.push("--fork-block-number", String(forkBlock));

  console.log(forkUrl ? "Starting fork Anvil..." : "Starting blank Anvil...");
  const log = createWriteStream(logPath, { flags: "w" });
  const child = spawn("anvil", args, {
    cwd: ROOT_DIR,
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (child.pid === undefined) throw new Error("Failed to start Anvil");
  child.stdout.pipe(log, { end: false });
  child.stderr.pipe(log, { end: false });

  child.once("exit", (code, signal) => {
    log.end();
    if (code !== null && code !== 0) console.error(`Anvil exited with code ${code}`);
    if (signal) console.error(`Anvil exited from signal ${signal}`);
  });

  console.log("Waiting for Anvil...");
  for (let i = 0; i < 60; i += 1) {
    if (child.exitCode !== null) throw new Error("Anvil exited before accepting RPC connections");
    try {
      await rpc(RPC, "eth_blockNumber", []);
      return child;
    } catch {
      await sleep(500);
    }
  }
  throw new Error("Timed out waiting for Anvil");
}

async function stopAnvil(child) {
  if (!child || child.exitCode !== null) return;
  child.kill();
  await Promise.race([
    new Promise((resolveStop) => child.once("exit", resolveStop)),
    sleep(2000),
  ]);
  if (child.exitCode === null) child.kill("SIGKILL");
}

async function ethCall(target, signature, args, rpcUrl, blockTag) {
  return rpc(rpcUrl, "eth_call", [{ to: target, data: calldataFor(signature, args) }, blockTag]);
}

async function createAccessList(target, signature, args, rpcUrl, blockTag, { quiet = false } = {}) {
  try {
    return await rpc(rpcUrl, "eth_createAccessList", [
      { from: BL_PROBE, to: target, data: calldataFor(signature, args) },
      blockTag,
    ]);
  } catch (error) {
    if (quiet) return null;
    throw error;
  }
}

function accessListEntries(accessListJson) {
  const list = accessListJson?.accessList ?? accessListJson ?? [];
  if (!Array.isArray(list)) return [];
  return list;
}

async function sourceStorageAt(address, slot, context) {
  return normalizeHex(await rpc(context.sourceRpc, "eth_getStorageAt", [address, slot, context.sourceBlockRpc]));
}

async function localStorageAt(address, slot, context) {
  return normalizeHex(await rpc(context.localRpc, "eth_getStorageAt", [address, slot, "latest"]));
}

async function setStorage(address, slot, value, context) {
  await rpc(context.localRpc, "anvil_setStorageAt", [address, slot, value]);
}

async function touchStorage(address, slot, context) {
  await setStorage(address, slot, await sourceStorageAt(address, slot, context), context);
}

async function materializeCode(address, context) {
  // anvil_dumpState only persists overlay accounts. Copy code and balance explicitly for
  // every proxy, implementation, registry, and underlying account the offline fixture calls.
  const code = await rpc(context.sourceRpc, "eth_getCode", [address, context.sourceBlockRpc]);
  if (code && code !== "0x") {
    await rpc(context.localRpc, "anvil_setCode", [address, code]);
  }
  const balance = await rpc(context.sourceRpc, "eth_getBalance", [address, context.sourceBlockRpc]);
  await rpc(context.localRpc, "anvil_setBalance", [address, balance]);
}

async function materializeImplAtSlot(proxy, slot, context) {
  // Proxy implementation accounts are separate accounts in the dump. If only the proxy code
  // is baked, later delegatecalls can land on an empty implementation after anvil_loadState.
  const impl = addressFromWord(await sourceStorageAt(proxy, slot, context));
  if (isZeroAddress(impl)) return;

  const code = await rpc(context.sourceRpc, "eth_getCode", [impl, context.sourceBlockRpc]);
  if (!code || code === "0x") return;

  await touchStorage(proxy, slot, context);
  await materializeCode(impl, context);
}

async function collectCallStorageSlots(address, signature, args, context, options = {}) {
  // Static metadata calls can touch proxy and implementation slots through delegatecall.
  // Keep every access-list entry, not only the target token, so those call paths survive
  // when the fork cache is gone.
  let accessListJson;
  try {
    accessListJson = await createAccessList(address, signature, args, context.traceRpc, "latest", {
      quiet: options.quiet,
    });
  } catch {
    if (!options.quiet) {
      console.error(`collectCallStorageSlots: access-list failed for ${address} ${signature}; skipping`);
    }
    return [];
  }
  if (!accessListJson) return [];

  const slots = [];
  for (const entry of accessListEntries(accessListJson)) {
    const entryAddress = entry.address ? normalizeAddress(entry.address) : null;
    if (!entryAddress) continue;
    for (const key of entry.storageKeys ?? []) {
      slots.push({ address: entryAddress, slot: normalizeHex(key) });
    }
  }
  return slots;
}

async function copyUnderlyingStaticStorage(token, context) {
  // Underlying ERC-20 metadata/supply/ERC-165 calls are the static calls currently used by
  // wrapper tests. Mapping-like user-specific calls stay out of this path and are handled
  // explicitly where needed, such as blacklist membership below.
  const calls = [
    { signature: "name()", args: [] },
    { signature: "symbol()", args: [] },
    { signature: "decimals()", args: [] },
    { signature: "totalSupply()", args: [] },
    { signature: "supportsInterface(bytes4)", args: [IERC1363_INTERFACE_ID], quiet: true },
  ];

  const byKey = new Map();
  for (const call of calls) {
    const slots = await collectCallStorageSlots(token, call.signature, call.args, context, { quiet: call.quiet });
    for (const slot of slots) byKey.set(`${slot.address}:${slot.slot}`, slot);
  }

  const values = [];
  for (const slot of [...byKey.values()].sort((a, b) => `${a.address}:${a.slot}`.localeCompare(`${b.address}:${b.slot}`))) {
    values.push({ ...slot, value: await sourceStorageAt(slot.address, slot.slot, context) });
  }

  for (const entry of values) {
    await setStorage(entry.address, entry.slot, entry.value, context);
  }
}

async function copyUnderlyingCode(token, context) {
  // Discover static-call storage before writing local code/storage overlays. Access-list
  // tracing should see the pinned fork behavior, then source values are copied directly
  // from the archive RPC.
  await copyUnderlyingStaticStorage(token, context);
  await materializeImplAtSlot(token, IMPL_SLOT, context);
  if (normalizeAddress(token) === MAINNET_USDC) {
    await materializeImplAtSlot(token, USDC_LEGACY_IMPLEMENTATION_SLOT, context);
  }
  await touchStorage(token, IMPL_SLOT, context);
  // Keep the root storage word for legacy/proxy underlyings. It is a cheap conservative
  // carry-over for tokens whose core layout or proxy metadata uses slot 0.
  await touchStorage(token, wordHex(0n), context);
  await materializeCode(token, context);
}

async function copyRegistryStorage(pairsRaw, pairs, context) {
  await materializeCode(REGISTRY, context);
  await materializeImplAtSlot(REGISTRY, IMPL_SLOT, context);
  await touchStorage(REGISTRY, IMPL_SLOT, context);
  await touchStorage(REGISTRY, INITIALIZABLE_SLOT, context);
  await touchStorage(REGISTRY, OWNABLE_SLOT, context);

  // Registry storage is namespaced at REGISTRY_STORAGE_SLOT. The pair list is a dynamic
  // array at namespace offset 4; copying its length and packed element words preserves
  // getTokenConfidentialTokenPairs() after anvil_loadState.
  const arraySlot = hexAdd(REGISTRY_STORAGE_SLOT, 4n);
  const elementsSlot = keccak256(arraySlot);
  await touchStorage(REGISTRY, arraySlot, context);

  for (let i = 0; i < pairs.length; i += 1) {
    const pair = pairs[i];
    // TokenWrapperPair packs across two array element words: token address, wrapper address,
    // and validity. These slots preserve enumeration by index.
    await touchStorage(REGISTRY, hexAdd(elementsSlot, BigInt(i * 2)), context);
    await touchStorage(REGISTRY, hexAdd(elementsSlot, BigInt(i * 2 + 1)), context);

    // The registry also has direct lookup mappings at namespace offsets 0..3:
    // token->wrapper, wrapper->token, wrapper validity, and token index. Copying these keeps
    // lookup paths consistent with the baked array, rather than only preserving enumeration.
    await touchStorage(REGISTRY, mappingSlot(pair.token, hexAdd(REGISTRY_STORAGE_SLOT, 0n)), context);
    await touchStorage(REGISTRY, mappingSlot(pair.wrapper, hexAdd(REGISTRY_STORAGE_SLOT, 1n)), context);
    await touchStorage(REGISTRY, mappingSlot(pair.wrapper, hexAdd(REGISTRY_STORAGE_SLOT, 2n)), context);
    await touchStorage(REGISTRY, mappingSlot(pair.token, hexAdd(REGISTRY_STORAGE_SLOT, 3n)), context);
  }
}

async function copyWrapperStorage(wrapper, context) {
  await materializeCode(wrapper, context);
  await materializeImplAtSlot(wrapper, IMPL_SLOT, context);

  // Proxy/base upgradeable state needed by owner-gated deny-list tests and by UUPS/proxy
  // dispatch after the fixture is loaded without a backing fork.
  await touchStorage(wrapper, IMPL_SLOT, context);
  await touchStorage(wrapper, INITIALIZABLE_SLOT, context);
  await touchStorage(wrapper, OWNABLE_SLOT, context);

  // ERC7984Upgradeable storage:
  //   offset 2: encrypted total supply handle, reset below for the local fhEVM executor;
  //   offsets 3..5: name, symbol, and contractURI used by metadata/smoke tests.
  await touchStorage(wrapper, hexAdd(ERC7984_STORAGE_SLOT, 3n), context);
  await touchStorage(wrapper, hexAdd(ERC7984_STORAGE_SLOT, 4n), context);
  await touchStorage(wrapper, hexAdd(ERC7984_STORAGE_SLOT, 5n), context);
  // Mainnet encrypted handles have no plaintext entry in forge-fhevm's local DB. Starting
  // from zero lets local mint/burn operations rebuild total supply against the test executor.
  await setStorage(wrapper, hexAdd(ERC7984_STORAGE_SLOT, 2n), wordHex(0n), context);

  // ERC7984ERC20WrapperUpgradeable storage: underlying token, wrapper decimals, and rate.
  // These back underlying(), decimals(), rate(), and wrap/unwrap amount conversion.
  await touchStorage(wrapper, hexAdd(WRAPPER_STORAGE_SLOT, 0n), context);
  await touchStorage(wrapper, hexAdd(WRAPPER_STORAGE_SLOT, 1n), context);
  await touchStorage(wrapper, hexAdd(WRAPPER_STORAGE_SLOT, 2n), context);

  // ConfidentialWrapperV3 stores the configured underlying deny-list selector flags used
  // by wrap guards and by the underlying support/smoke tests. Per-user blocked mappings
  // remain test-local state and are not globally enumerated here.
  await touchStorage(wrapper, hexAdd(CONFIDENTIAL_WRAPPER_V3_STORAGE_SLOT, 2n), context);

  // Re-point wrappers from mainnet fhEVM contracts to the local forge-fhevm host contracts.
  // Without this override, encrypted operations would call production coprocessor/KMS
  // addresses that do not exist in the offline fixture.
  await setStorage(wrapper, hexAdd(FHEVM_CONFIG_SLOT, 0n), padAddress(LOCAL_FHEVM_ACL), context);
  await setStorage(wrapper, hexAdd(FHEVM_CONFIG_SLOT, 1n), padAddress(LOCAL_FHEVM_COPROCESSOR), context);
  await setStorage(wrapper, hexAdd(FHEVM_CONFIG_SLOT, 2n), padAddress(LOCAL_FHEVM_KMS_VERIFIER), context);
}

function decodePairs(rawHex) {
  const raw = rawHex.replace(/^0x/u, "");
  const word = (index) => raw.slice(index * 64, (index + 1) * 64);
  const length = Number(BigInt(`0x${word(1)}`));
  const pairs = [];
  for (let i = 0; i < length; i += 1) {
    const base = 2 + i * 3;
    pairs.push({
      token: normalizeAddress(`0x${word(base).slice(24)}`),
      wrapper: normalizeAddress(`0x${word(base + 1).slice(24)}`),
      valid: BigInt(`0x${word(base + 2)}`) !== 0n,
    });
  }
  return pairs;
}

function loadJsonIfExists(path, fallback) {
  if (!existsSync(path)) return fallback;
  return JSON.parse(readFileSync(path, "utf8"));
}

function hasFiniteManifestScanBlock(path) {
  const manifest = loadJsonIfExists(path, null);
  return Number.isFinite(manifest?.blacklistScannedBlock);
}

function selectBakeMode() {
  const hasFixture = existsSync(STATE_FILE) && statSync(STATE_FILE).size > 0;
  const hasCache = existsSync(BLACKLIST_FILE);
  const hasScanBlock = hasFiniteManifestScanBlock(MANIFEST_FILE);
  return hasFixture && hasCache && hasScanBlock ? "delta" : "full";
}

function sidecarEntry(sidecar, token) {
  const normalized = normalizeAddress(token);
  return (sidecar.tokens ?? []).find((entry) => normalizeAddress(entry.token) === normalized);
}

function sidecarSet(sidecar, token) {
  const entry = sidecarEntry(sidecar, token);
  return new Set((entry?.blacklisted ?? []).map(normalizeAddress));
}

function sidecarLastBlock(sidecar, token) {
  const entry = sidecarEntry(sidecar, token);
  return Number.isFinite(entry?.lastScannedBlock) ? Number(entry.lastScannedBlock) : undefined;
}

function validateDeltaNotBackwards(sidecar, tokens, targetBlock) {
  for (const token of tokens) {
    const lastBlock = sidecarLastBlock(sidecar, token);
    if (lastBlock !== undefined && lastBlock > targetBlock) {
      throw new Error(
        [
          `Refusing backwards delta for ${normalizeAddress(token)}:`,
          `sidecar lastScannedBlock ${lastBlock} > target ${targetBlock}.`,
          "Delta bakes only move forward; reconstructing older membership needs a full rebake.",
        ].join(" "),
      );
    }
  }
}

async function discoverDeployBlock(token, context) {
  let lo = 0;
  let hi = context.resolvedBlock;
  while (lo < hi) {
    const mid = Math.floor((lo + hi) / 2);
    const code = await rpc(context.sourceRpc, "eth_getCode", [token, blockHex(mid)]);
    if (!code || code === "0x") lo = mid + 1;
    else hi = mid;
  }
  return lo;
}

function configuredDeployBlock(adapter) {
  if (adapter.deployBlock === undefined || adapter.deployBlock === null) return undefined;
  const block = Number(adapter.deployBlock);
  if (!Number.isSafeInteger(block) || block < 0) {
    throw new Error(`Invalid deployBlock for ${adapter.token ?? adapter.name ?? "blacklist token"}: ${adapter.deployBlock}`);
  }
  return block;
}

async function blacklistFullScanStart(token, adapter, context) {
  const block = configuredDeployBlock(adapter);
  if (block !== undefined) return { block, source: "configured" };
  return { block: await discoverDeployBlock(token, context), source: "discovered" };
}

function configuredBlacklistBaseSlot(adapter) {
  if (adapter.baseSlot === undefined || adapter.baseSlot === null) return undefined;
  if (typeof adapter.baseSlot === "number") {
    if (!Number.isSafeInteger(adapter.baseSlot) || adapter.baseSlot < 0) {
      throw new Error(`Invalid baseSlot for ${adapter.token ?? adapter.name ?? "blacklist token"}: ${adapter.baseSlot}`);
    }
    return adapter.baseSlot;
  }
  if (typeof adapter.baseSlot === "string") {
    const raw = adapter.baseSlot.trim();
    if (!/^(?:0x[0-9a-fA-F]+|[0-9]+)$/u.test(raw)) {
      throw new Error(`Invalid baseSlot for ${adapter.token ?? adapter.name ?? "blacklist token"}: ${adapter.baseSlot}`);
    }
    return raw.startsWith("0x") ? wordHex(BigInt(raw)) : wordHex(BigInt(raw));
  }
  throw new Error(`Invalid baseSlot for ${adapter.token ?? adapter.name ?? "blacklist token"}: ${adapter.baseSlot}`);
}

async function discoverBlacklistBase(token, adapter, context) {
  // Blacklist mappings are intentionally config-driven but not slot-hardcoded. Trace the
  // declared getter for a known probe address, then match the touched mapping slot against
  // candidate base slots. This keeps USDC/USDT/XAUT layouts explicit without baking random
  // user-keyed mappings.
  const accessListJson = await createAccessList(token, adapter.getter, [BL_PROBE], context.traceRpc, "latest");
  const observed = new Set();
  for (const entry of accessListEntries(accessListJson)) {
    if (!entry.address || normalizeAddress(entry.address) !== normalizeAddress(token)) continue;
    for (const key of entry.storageKeys ?? []) observed.add(normalizeHex(key));
  }
  if (observed.size === 0) throw new Error(`Blacklist getter traced no storage for ${token}`);

  const configuredBaseSlot = configuredBlacklistBaseSlot(adapter);
  if (configuredBaseSlot !== undefined) {
    const configuredMemberSlot = mappingSlot(BL_PROBE, configuredBaseSlot);
    if (!observed.has(configuredMemberSlot)) {
      throw new Error(
        [
          `Configured blacklist baseSlot for ${token} did not match getter storage.`,
          `baseSlot=${configuredBaseSlot}`,
          `expected member slot ${configuredMemberSlot}.`,
          `observed: ${[...observed].join(", ")}`,
        ].join(" "),
      );
    }
    return { baseSlot: configuredBaseSlot, source: "configured" };
  }

  for (let candidate = 0; candidate <= 255; candidate += 1) {
    const slot = mappingSlot(BL_PROBE, candidate);
    if (observed.has(slot)) return { baseSlot: candidate, source: "discovered" };
  }
  throw new Error(
    [
      `No blacklist base slot in 0..255 matched traced storage for ${token}.`,
      "If this token uses namespaced storage, add a baseSlot to config/blacklist-interfaces.json.",
      `observed: ${[...observed].join(", ")}`,
    ].join(" "),
  );
}

function parseBlacklistLogs(logs, addTopic, addrIndexed) {
  return logs.map((log) => {
    const kind = normalizeHex(log.topics[0]) === addTopic ? "ADD" : "REMOVE";
    const addr = addrIndexed
      ? `0x${log.topics[1].slice(26)}`
      : `0x${log.data.replace(/^0x/u, "").slice(24, 64)}`;
    return { kind, address: normalizeAddress(addr) };
  });
}

function applyBlacklistEvents(priorMembers, events) {
  const members = new Set([...priorMembers].map(normalizeAddress));
  for (const event of events) {
    if (event.kind === "ADD") members.add(normalizeAddress(event.address));
    if (event.kind === "REMOVE") members.delete(normalizeAddress(event.address));
  }
  return [...members].sort();
}

async function collectBlacklistEvents(token, adapter, fromBlock, toBlock, context) {
  // Sparse blacklist mappings cannot be discovered by scanning storage. Reconstruct the
  // current member set from add/remove logs, using the sidecar block as an incremental
  // checkpoint when available.
  const addTopic = eventTopic(adapter.addEvent);
  const removeTopic = eventTopic(adapter.removeEvent);
  const events = [];
  let start = fromBlock;
  const totalChunks = Math.floor((toBlock - fromBlock) / (BL_CHUNK + 1)) + 1;
  let chunkIndex = 0;

  while (start <= toBlock) {
    const end = Math.min(start + BL_CHUNK, toBlock);
    chunkIndex += 1;
    if (BL_SCAN_PROGRESS > 0) {
      console.log(`    [${now()}] scan chunk ${chunkIndex}/${totalChunks}: blocks ${start}..${end}`);
    }
    const logs = await rpc(context.sourceRpc, "eth_getLogs", [
      {
        address: token,
        fromBlock: blockHex(start),
        toBlock: blockHex(end),
        topics: [[addTopic, removeTopic]],
      },
    ]);
    events.push(...parseBlacklistLogs(logs, addTopic, adapter.addrIndexed === true));
    start = end + 1;
  }

  return events;
}

async function writeBlacklistSlot(token, baseSlot, member, denied, encoding, context, { preserveFrom = "source" } = {}) {
  const slot = mappingSlot(member, baseSlot);
  let value;
  if (encoding === "highBit") {
    // USDC packs the blacklist flag into bit 255 of a word that also contains low-bit state
    // such as balances. Preserve the rest of the word from the source chain for fresh bakes,
    // or from the loaded overlay for blacklist-only delta refreshes.
    const sourceWord = preserveFrom === "local" ? await localStorageAt(token, slot, context) : await sourceStorageAt(token, slot, context);
    value = highBitWord(sourceWord, denied);
  } else {
    value = wordDenyValue(denied);
  }
  await setStorage(token, slot, value, context);
}

async function writeBlacklistMembers(token, baseSlot, members, encoding, context, { denied = true, label = "fresh overlay blacklist slots", preserveFrom = "source" } = {}) {
  const progress = BL_WRITE_PROGRESS;
  for (let i = 0; i < members.length; i += 1) {
    await writeBlacklistSlot(token, baseSlot, members[i], denied, encoding, context, { preserveFrom });
    const count = i + 1;
    if (progress > 0 && (count === 1 || count % progress === 0 || count === members.length)) {
      console.log(`    [${now()}] ${label}: wrote ${count}/${members.length}`);
    }
  }
}

function setDifference(left, right) {
  return [...left].filter((value) => !right.has(value)).sort();
}

function upsertSidecar(sidecar, token, encoding, baseSlot, lastBlock, members, forkBlock) {
  const normalized = normalizeAddress(token);
  const next = {
    ...sidecar,
    forkBlock,
    tokens: [...(sidecar.tokens ?? [])],
  };
  const entry = {
    token: normalized,
    encoding,
    baseSlot,
    lastScannedBlock: lastBlock,
    blacklisted: [...members].map(normalizeAddress).sort(),
  };
  const index = next.tokens.findIndex((item) => normalizeAddress(item.token) === normalized);
  if (index >= 0) next.tokens[index] = entry;
  else next.tokens.push(entry);
  next.tokens.sort((a, b) => normalizeAddress(a.token).localeCompare(normalizeAddress(b.token)));
  return next;
}

async function materializeBlacklists(tokens, mode, context) {
  // Full bake/delta-rebuild writes the full current member set into a fresh overlay.
  // Blacklist-only delta loads an existing fixture and writes only set/clear diffs.
  const config = loadJsonIfExists(BLACKLIST_INTERFACES_FILE, { tokens: [] });
  const adapters = new Map((config.tokens ?? []).map((entry) => [normalizeAddress(entry.token), entry]));
  let sidecar = loadJsonIfExists(BLACKLIST_FILE, { tokens: [] });

  if (mode === "delta" || mode === "delta-rebuild") {
    validateDeltaNotBackwards(sidecar, tokens, context.resolvedBlock);
  }

  for (const token of tokens.map(normalizeAddress)) {
    const adapter = adapters.get(token);
    if (!adapter) continue;

    console.log(`  [blacklist] ${token} (${adapter.getter}, ${adapter.encoding})`);
    const { baseSlot, source: baseSlotSource } = await discoverBlacklistBase(token, adapter, context);
    console.log(`    base slot: ${baseSlot} (${baseSlotSource})`);

    let priorMembers = new Set();
    let fromBlock;
    const lastBlock = mode === "delta" || mode === "delta-rebuild" ? sidecarLastBlock(sidecar, token) : undefined;
    if ((mode === "delta" || mode === "delta-rebuild") && lastBlock !== undefined) {
      priorMembers = sidecarSet(sidecar, token);
      fromBlock = lastBlock + 1;
      if (fromBlock <= context.resolvedBlock) {
        console.log(`    incremental scan blocks ${fromBlock}..${context.resolvedBlock} (prior lastScannedBlock=${lastBlock})`);
      } else {
        console.log(`    incremental scan skipped; sidecar already at target block ${context.resolvedBlock}`);
      }
    } else {
      const scanStart = await blacklistFullScanStart(token, adapter, context);
      fromBlock = scanStart.block;
      console.log(
        mode === "delta" || mode === "delta-rebuild"
          ? `    no prior cache for token; full scan from ${scanStart.source} deploy block ${fromBlock}`
          : `    full scan from ${scanStart.source} deploy block ${fromBlock}`,
      );
    }

    let events = [];
    if (fromBlock <= context.resolvedBlock) {
      console.log(`    [${now()}] collecting events...`);
      events = await collectBlacklistEvents(token, adapter, fromBlock, context.resolvedBlock, context);
      console.log(`    [${now()}] collected ${events.length} blacklist events`);
    }

    console.log(`    [${now()}] applying events to cached set (${priorMembers.size} prior members)`);
    const members = applyBlacklistEvents(priorMembers, events);
    console.log(`    [${now()}] computed ${members.length} current members`);
    if (mode === "delta") {
      const priorSet = new Set([...priorMembers].map(normalizeAddress));
      const nextSet = new Set(members.map(normalizeAddress));
      const toSet = setDifference(nextSet, priorSet);
      const toClear = setDifference(priorSet, nextSet);
      console.log(`    [${now()}] writing membership diff to overlay (${toSet.length} set, ${toClear.length} clear)`);
      await writeBlacklistMembers(token, baseSlot, toSet, adapter.encoding, context, {
        denied: true,
        label: "setting blacklist slots",
        preserveFrom: "local",
      });
      await writeBlacklistMembers(token, baseSlot, toClear, adapter.encoding, context, {
        denied: false,
        label: "clearing blacklist slots",
        preserveFrom: "local",
      });
    } else {
      console.log(`    [${now()}] writing ${members.length} members to fresh overlay`);
      await writeBlacklistMembers(token, baseSlot, members, adapter.encoding, context);
    }
    console.log(`    [${now()}] overlay writes complete`);
    console.log(`    current blacklisted members: ${members.length}`);
    console.log(`    [${now()}] updating blacklist sidecar`);
    sidecar = upsertSidecar(sidecar, token, adapter.encoding, baseSlot, context.resolvedBlock, members, context.resolvedBlock);
    console.log(`    [${now()}] sidecar updated`);
  }

  writeFileSync(BLACKLIST_FILE, `${JSON.stringify(sidecar, null, 2)}\n`);
}

async function runBake() {
  process.chdir(ROOT_DIR);
  mkdirSync(OUT_DIR, { recursive: true });

  const forkUrl =
    process.env.CONFIDENTIAL_WRAPPER_UPGRADE_TEST_RPC_URL ??
    readEnvValue(ENV_FILE, "CONFIDENTIAL_WRAPPER_UPGRADE_TEST_RPC_URL");
  if (!forkUrl) {
    throw new Error(
      "CONFIDENTIAL_WRAPPER_UPGRADE_TEST_RPC_URL is not set. Add it to contracts/confidential-wrapper/.env (see .env.example).",
    );
  }

  let anvil;
  try {
    anvil = await startAnvil({ forkUrl, forkBlock: process.env.FORK_BLOCK });
    activeAnvil = anvil;
    const resolvedBlock = Number(BigInt(await rpc(RPC, "eth_blockNumber", [])));
    console.log(`Forked at block ${resolvedBlock}`);

    const bakeMode = selectBakeMode();
    console.log(`Bake strategy: ${bakeMode}`);

    // Source state is read from the archive RPC at one pinned block. The forked Anvil is
    // only used to trace access lists before overlay writes and to receive anvil_set*
    // materialization calls before anvil_dumpState.
    const context = {
      localRpc: RPC,
      traceRpc: RPC,
      sourceRpc: forkUrl,
      sourceBlockRpc: blockHex(resolvedBlock),
      resolvedBlock,
    };
    console.log(`Materialization reads pinned archive state at block ${resolvedBlock}.`);

    const pairsRaw = await ethCall(REGISTRY, "getTokenConfidentialTokenPairs()", [], context.sourceRpc, context.sourceBlockRpc);
    const pairs = decodePairs(pairsRaw);

    console.log(`Discovered ${pairs.length} registry wrapper pairs:`);
    pairs.forEach((pair, index) => {
      console.log(
        `  [${index}] wrapper=${pair.wrapper} underlying=${pair.token} valid=${pair.valid ? "true" : "false"}`,
      );
    });

    console.log("Materializing registry, wrappers, and underlyings into local Anvil state...");
    await copyRegistryStorage(pairsRaw, pairs, context);
    const underlyingTokens = [];
    for (const pair of pairs) {
      await copyUnderlyingCode(pair.token, context);
      await copyWrapperStorage(pair.wrapper, context);
      underlyingTokens.push(pair.token);
    }

    const blacklistMode = bakeMode === "delta" ? "delta-rebuild" : "rebuild";
    console.log(`Materializing underlying blacklist storage: ${blacklistMode}`);
    await materializeBlacklists(underlyingTokens, blacklistMode, context);

    await rpc(RPC, "anvil_mine", ["0x1"]);

    console.log(`Dumping Anvil state -> ${STATE_FILE}`);
    const state = await rpc(RPC, "anvil_dumpState", []);
    if (typeof state !== "string" || !state.startsWith("0x")) {
      throw new Error("anvil_dumpState did not return raw hex.");
    }
    if (state.length < 10000) {
      throw new Error("anvil_dumpState is unexpectedly small; materialization likely failed.");
    }
    writeFileSync(STATE_FILE, state);

    console.log(`Writing manifest -> ${MANIFEST_FILE}`);
    const generatedAt = new Date().toISOString().replace(/\.\d{3}Z$/u, "Z");
    writeFileSync(
      MANIFEST_FILE,
      `${JSON.stringify(
        {
          forkBlock: resolvedBlock,
          blacklistScannedBlock: resolvedBlock,
          chainId: CHAIN_ID,
          registry: REGISTRY,
          pairsRaw,
          generatedAt,
        },
        null,
        2,
      )}\n`,
    );

    console.log(`Done. Commit ${resolve(ROOT_DIR, "deployments/mainnet-fork")}/*`);
  } finally {
    await stopAnvil(anvil);
    if (activeAnvil === anvil) activeAnvil = undefined;
  }
}

function isMain() {
  return process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
}

let activeAnvil;

export {
  BLACKLIST_FILE,
  CHAIN_ID,
  ENV_FILE,
  MANIFEST_FILE,
  OUT_DIR,
  REGISTRY,
  ROOT_DIR,
  RPC,
  STATE_FILE,
  applyBlacklistEvents,
  blockHex,
  canonicalEventSignature,
  configuredBlacklistBaseSlot,
  configuredDeployBlock,
  decodePairs,
  ethCall,
  eventTopic,
  highBitWord,
  normalizeAddress,
  mappingSlot,
  materializeBlacklists,
  calldataFor,
  readEnvValue,
  rpc,
  startAnvil,
  stopAnvil,
  upsertSidecar,
  validateDeltaNotBackwards,
  wordDenyValue,
  wordHex,
};

if (isMain()) {
  process.once("SIGINT", async () => {
    await stopAnvil(activeAnvil);
    process.exit(130);
  });
  process.once("SIGTERM", async () => {
    await stopAnvil(activeAnvil);
    process.exit(143);
  });

  runBake().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
