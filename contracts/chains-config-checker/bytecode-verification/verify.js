#!/usr/bin/env node

/**
 * Script 2: EVM partial-match bytecode verification.
 *
 * For each entry in contract-infos.json's evm[]:
 *   - (proxy) resolve EIP-1967 implementation
 *   - fetch on-chain runtime bytecode via eth_getCode
 *   - compile contracts/<pkg> at the tag's commit in a git worktree
 *   - strip CBOR metadata, zero immutables + library placeholders
 *   - byte-compare and report ok | mismatch | error
 *
 * Entries are grouped by commit so each tag is compiled exactly once, even
 * when a tag applies to many deployments (18 OperatorStaking proxies, 7
 * ConfidentialWrapper proxies, …).
 */

require('dotenv').config({ path: require('path').resolve(__dirname, '../.env') });

const fs = require('fs');
const path = require('path');
const { ethers } = require('ethers');
const { execSync } = require('child_process');

const config = require('./config');
const {
  addWorktree,
  removeWorktree,
  detectPackageManager,
  installAndCompile,
} = require('./lib/worktree');
const { comparePartial, toHex } = require('./lib/bytecode-compare');

const INFO_PATH = path.resolve(__dirname, 'contract-infos.json');
const WORKTREE_ROOT = path.resolve('/tmp/verify-bytecode');
const REPO_ROOT = path.resolve(__dirname, '../../..');

// EIP-1967 implementation storage slot:
//   bytes32(uint256(keccak256('eip1967.proxy.implementation')) - 1)
const EIP1967_IMPL_SLOT =
  '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';

async function main() {
  if (!fs.existsSync(INFO_PATH)) {
    console.log('contract-infos.json missing — running gather step first.');
    execSync(`node ${path.join(__dirname, 'gather-contract-infos.js')}`, { stdio: 'inherit' });
  }

  const info = JSON.parse(fs.readFileSync(INFO_PATH, 'utf8'));
  const results = [];

  const byCommit = groupByCommit(info.evm);
  for (const [commit, entries] of byCommit) {
    const firstEntry = entries[0];
    const pkg = firstEntry.package;
    const worktreePath = path.join(WORKTREE_ROOT, commit);
    const pkgDirInWorktree = path.join(worktreePath, 'contracts', pkg);

    console.log(`\n[${firstEntry.tag} @ ${commit.slice(0, 7)}]  contracts/${pkg}`);

    try {
      addWorktree(REPO_ROOT, commit, worktreePath);
      const pkgManagerOverride =
        config.packages[pkg] && config.packages[pkg].packageManager;
      const pm = detectPackageManager(pkgDirInWorktree, pkgManagerOverride);
      installAndCompile(pkgDirInWorktree, pm);

      const sourcesInGroup = [...new Set(entries.map((e) => e.contractSource))];
      const artifactsBySource = {};
      for (const src of sourcesInGroup) {
        artifactsBySource[src] = loadArtifact(pkgDirInWorktree, src);
      }
      const solcVersion = readSolcVersion(artifactsBySource[sourcesInGroup[0]]);
      console.log(`  solc ${solcVersion || '(unknown)'}`);

      for (const entry of entries) {
        const artifact = artifactsBySource[entry.contractSource];
        const res = await verifyEntry(entry, artifact);
        results.push({ entry, ...res });
        logResult(entry, res);
      }
    } catch (e) {
      console.error(`  error: ${e.message}`);
      for (const entry of entries) {
        results.push({ entry, ok: false, reason: `setup error: ${e.message}` });
      }
    } finally {
      if (fs.existsSync(worktreePath)) removeWorktree(REPO_ROOT, worktreePath);
    }
  }

  printSummary(results);
  const anyMismatch = results.some((r) => !r.ok);
  process.exit(anyMismatch ? 1 : 0);
}

function groupByCommit(entries) {
  const map = new Map();
  for (const e of entries) {
    if (!map.has(e.commit)) map.set(e.commit, []);
    map.get(e.commit).push(e);
  }
  return map;
}

function loadArtifact(pkgDir, contractSource) {
  const p = path.join(
    pkgDir,
    'artifacts',
    'contracts',
    `${contractSource}.sol`,
    `${contractSource}.json`
  );
  if (!fs.existsSync(p)) {
    throw new Error(`artifact not found: ${p}`);
  }
  return JSON.parse(fs.readFileSync(p, 'utf8'));
}

function readSolcVersion(artifact) {
  if (!artifact || !artifact.metadata) return null;
  try {
    const meta = typeof artifact.metadata === 'string' ? JSON.parse(artifact.metadata) : artifact.metadata;
    return meta.compiler && meta.compiler.version;
  } catch {
    return null;
  }
}

async function verifyEntry(entry, artifact) {
  const chainDef = config.chains[entry.chain];
  if (!chainDef) return { ok: false, reason: `chain ${entry.chain} not in config` };

  const rpcUrl = process.env[chainDef.rpcEnv];
  if (!rpcUrl) return { ok: false, reason: `missing env var ${chainDef.rpcEnv}` };

  const provider = new ethers.JsonRpcProvider(rpcUrl);

  let targetAddress = entry.address;
  if (entry.proxy) {
    const implSlot = await provider.getStorage(entry.address, EIP1967_IMPL_SLOT);
    const implAddress = '0x' + implSlot.slice(-40);
    if (!/^0x[0-9a-fA-F]{40}$/.test(implAddress) || implAddress === '0x' + '0'.repeat(40)) {
      return { ok: false, reason: `EIP-1967 impl slot empty for ${entry.address}` };
    }
    targetAddress = implAddress;
  }

  const onChainHex = await provider.getCode(targetAddress);
  if (!onChainHex || onChainHex === '0x') {
    return { ok: false, reason: `no code at ${targetAddress}` };
  }

  const cmp = comparePartial(artifact, onChainHex);
  return { ...cmp, implAddress: entry.proxy ? targetAddress : undefined };
}

function logResult(entry, res) {
  const label = `[${entry.chain}] ${entry.displayName}${entry.role ? ` (${entry.role})` : ''} (${entry.contractSource}) @ ${entry.address}`;
  if (res.ok) {
    const implSuffix = res.implAddress ? ` (impl ${res.implAddress})` : '';
    console.log(`  ${label}${implSuffix} => ok (${res.artifactLen} bytes)`);
  } else {
    console.log(`  ${label} => MISMATCH: ${res.reason}${res.firstDiffOffset !== undefined ? ` at offset ${res.firstDiffOffset}` : ''}`);
  }
}

function printSummary(results) {
  const ok = results.filter((r) => r.ok).length;
  const bad = results.length - ok;
  console.log(`\nSummary: ${ok} ok, ${bad} mismatch/error (of ${results.length})`);
}

if (require.main === module) {
  main().catch((e) => {
    console.error(e.stack || e.message);
    process.exit(2);
  });
}
