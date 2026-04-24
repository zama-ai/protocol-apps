#!/usr/bin/env node

/**
 * Script 3: Solana program bytecode verification.
 *
 * For each entry in contract-infos.json's solana[]:
 *   - build contracts/solanaOFT at the tag's commit with `anchor build
 *     --verifiable` (requires Docker), producing a deterministic .so
 *   - fetch on-chain program bytes (via `solana program dump` when the CLI
 *     is installed, else via @solana/web3.js reading the ProgramData PDA)
 *   - byte-compare the two
 *
 * No CBOR metadata / immutables / library placeholders apply here — a
 * verifiable anchor build is expected to be byte-for-byte reproducible.
 */

require('dotenv').config({ path: require('path').resolve(__dirname, '../.env') });

const fs = require('fs');
const path = require('path');
const { execSync, spawnSync } = require('child_process');
const { Connection, PublicKey } = require('@solana/web3.js');

const config = require('./config');
const { addWorktree, removeWorktree } = require('./lib/worktree');

const INFO_PATH = path.resolve(__dirname, 'contract-infos.json');
const WORKTREE_ROOT = path.resolve('/tmp/verify-bytecode');
const REPO_ROOT = path.resolve(__dirname, '../../..');

const BPF_UPGRADEABLE_LOADER_PROGRAM_ID = new PublicKey('BPFLoaderUpgradeab1e11111111111111111111111');

async function main() {
  if (!fs.existsSync(INFO_PATH)) {
    console.log('contract-infos.json missing — running gather step first.');
    execSync(`node ${path.join(__dirname, 'gather-contract-infos.js')}`, { stdio: 'inherit' });
  }

  const info = JSON.parse(fs.readFileSync(INFO_PATH, 'utf8'));

  if (info.solana.length === 0) {
    console.log('No solana entries to verify.');
    return;
  }

  const rpcUrl = process.env[config.chains.solana.rpcEnv];
  if (!rpcUrl) {
    console.error(`Missing env var ${config.chains.solana.rpcEnv}`);
    process.exit(2);
  }
  const connection = new Connection(rpcUrl, 'confirmed');

  let anyMismatch = false;

  for (const entry of info.solana) {
    console.log(`\n[${entry.tag} @ ${entry.commit.slice(0, 7)}]  contracts/${entry.package}`);
    const worktreePath = path.join(WORKTREE_ROOT, entry.commit);
    const pkgDirInWorktree = path.join(worktreePath, 'contracts', entry.package);

    try {
      addWorktree(REPO_ROOT, entry.commit, worktreePath);
      runAnchorVerifiableBuild(pkgDirInWorktree);

      const builtPath = path.join(pkgDirInWorktree, 'target', 'verifiable', `${entry.anchorBin}.so`);
      if (!fs.existsSync(builtPath)) {
        throw new Error(`built .so not found at ${builtPath}`);
      }
      const builtBytes = fs.readFileSync(builtPath);

      const onChainBytes = await fetchOnChainProgramBytes(connection, new PublicKey(entry.programAddress));

      const ok = builtBytes.length === onChainBytes.length && builtBytes.equals(onChainBytes);
      if (ok) {
        console.log(`  ${entry.programAddress} => ok (${builtBytes.length} bytes)`);
      } else {
        anyMismatch = true;
        console.log(
          `  ${entry.programAddress} => MISMATCH: built ${builtBytes.length} bytes, on-chain ${onChainBytes.length} bytes`
        );
      }
    } catch (e) {
      anyMismatch = true;
      console.error(`  error: ${e.message}`);
    } finally {
      if (fs.existsSync(worktreePath)) removeWorktree(REPO_ROOT, worktreePath);
    }
  }

  process.exit(anyMismatch ? 1 : 0);
}

function runAnchorVerifiableBuild(pkgDir) {
  // Anchor verifiable build runs inside Docker to produce deterministic output.
  const result = spawnSync('anchor', ['build', '--verifiable'], {
    cwd: pkgDir,
    stdio: 'inherit',
    shell: false,
  });
  if (result.error && result.error.code === 'ENOENT') {
    throw new Error(`"anchor" not found on PATH. Install Anchor (https://www.anchor-lang.com) and ensure Docker is running.`);
  }
  if (result.status !== 0) {
    throw new Error(`anchor build --verifiable failed (exit ${result.status}). Make sure Docker is running.`);
  }
}

/**
 * Prefer `solana program dump` when the CLI is installed — it's the simplest
 * reliable path. Fall back to reading the ProgramData account via RPC if not.
 */
async function fetchOnChainProgramBytes(connection, programId) {
  const dump = trySolanaProgramDump(programId);
  if (dump) return dump;
  return fetchProgramDataViaRpc(connection, programId);
}

function trySolanaProgramDump(programId) {
  const tmp = path.join(require('os').tmpdir(), `program-${programId.toBase58()}.so`);
  const result = spawnSync('solana', ['program', 'dump', programId.toBase58(), tmp], {
    stdio: 'pipe',
    shell: false,
  });
  if (result.error || result.status !== 0) return null;
  try {
    const bytes = fs.readFileSync(tmp);
    fs.unlinkSync(tmp);
    return bytes;
  } catch {
    return null;
  }
}

async function fetchProgramDataViaRpc(connection, programId) {
  // Upgradeable programs store their executable bytes in a ProgramData account
  // whose address is [programId]'s PDA under the BPF upgradeable loader.
  const [programDataAddr] = PublicKey.findProgramAddressSync(
    [programId.toBuffer()],
    BPF_UPGRADEABLE_LOADER_PROGRAM_ID
  );
  const acct = await connection.getAccountInfo(programDataAddr, 'confirmed');
  if (!acct) throw new Error(`ProgramData account ${programDataAddr.toBase58()} not found`);
  // ProgramData account layout: 45-byte header (4 state + 8 slot + 1 option + 32 pubkey)
  // followed by program bytes.
  return acct.data.subarray(45);
}

if (require.main === module) {
  main().catch((e) => {
    console.error(e.stack || e.message);
    process.exit(2);
  });
}
