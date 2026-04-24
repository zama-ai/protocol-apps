#!/usr/bin/env node

/**
 * Script 1: gather audit + address metadata from markdown into one JSON.
 *
 * Inputs (single source of truth):
 *   - contracts/<pkg>/audits/README.md   — tags, commits, deploy status
 *   - docs/addresses/mainnet/*.md        — per-chain address rows
 *   - ./config.js                        — display-name → source mapping
 *
 * Output:
 *   - ./contract-infos.json              — one entry per deployed (chain, address)
 *
 * This is the only script that touches the markdown docs. verify.js and
 * verify-solana.js consume contract-infos.json directly.
 */

const fs = require('fs');
const path = require('path');

const config = require('./config');
const { parseAuditsReadme } = require('./lib/parse-audits-readme');
const { parseAddressesDoc } = require('./lib/parse-addresses-doc');

const REPO_ROOT = path.resolve(__dirname, '../../..');
const CONTRACTS_DIR = path.resolve(REPO_ROOT, 'contracts');
const OUTPUT_PATH = path.resolve(__dirname, 'contract-infos.json');

function main() {
  const auditsByPkg = loadAllAudits();
  const addressRowsByChain = loadAllAddressDocs();

  const evm = [];
  const solana = [];
  const skipped = [];
  const coverageProblems = [];

  // Track which audit-derived (pkg, chain) pairs produced at least one matched row.
  // Used to warn on Active tags that have no deployed addresses in config.
  const coverageKeys = new Set();

  for (const [pkg, audit] of Object.entries(auditsByPkg)) {
    const pkgConfig = config.packages[pkg];
    if (!pkgConfig) continue;

    // Resolve per-chain active tag + commit for this package.
    const activeByChain = resolveActivePerChain(audit);
    if (Object.keys(activeByChain).length === 0) continue;

    // Special-case: Solana-only package.
    if (pkgConfig.solana) {
      const activeSolana = activeByChain.solana;
      if (activeSolana) {
        solana.push({
          package: pkg,
          tag: activeSolana.tag,
          commit: activeSolana.commit,
          anchorBin: pkgConfig.solana.anchorBin,
          programAddress: pkgConfig.solana.programAddress,
        });
        coverageKeys.add(`${pkg}:solana`);
      }
      continue;
    }

    // EVM path: scan each in-scope chain's address rows for matches.
    for (const [chain, active] of Object.entries(activeByChain)) {
      if (!config.chains[chain]) continue; // out of scope
      const rows = addressRowsByChain[chain] || [];
      let matched = 0;

      for (const row of rows) {
        const resolved = resolveRow(pkg, pkgConfig, row);
        if (!resolved) continue;

        // Pick tag: per-row override > package default (per-chain active).
        const tag = resolved.overrideTag || active.tag;
        const commit = lookupCommit(audit, tag);
        if (!commit) {
          coverageProblems.push(
            `[${pkg}] ${chain} row "${row.displayName || row.role}" references tag ${tag} that is not in the tag table`
          );
          continue;
        }

        const displayName = row.displayName || row.role || '';
        evm.push({
          package: pkg,
          tag,
          commit,
          contractSource: resolved.source,
          displayName,
          ...(row.role ? { role: row.role } : {}),
          chain,
          address: row.address,
          proxy: resolved.proxy,
        });
        matched++;
      }

      coverageKeys.add(`${pkg}:${chain}`);
      if (matched === 0) {
        coverageProblems.push(
          `[${pkg}] no address rows matched on chain "${chain}" (tag ${active.tag})`
        );
      }
    }
  }

  // Any address-doc row that wasn't matched by any package config goes to skipped.
  for (const [chain, rows] of Object.entries(addressRowsByChain)) {
    for (const row of rows) {
      const matched = evm.some(
        (e) => e.chain === chain && e.address.toLowerCase() === row.address.toLowerCase()
      );
      if (matched) continue;
      // Skip if this solana row is the one we already recorded as a program deployment.
      if (chain === 'solana' && solana.some((s) => s.programAddress === row.address)) continue;

      skipped.push({
        chain,
        section: [row.section, row.subsection].filter(Boolean).join(' / '),
        displayName: row.displayName || row.role || '',
        address: row.address,
        reason: 'not in config',
      });
    }
  }

  const out = {
    generatedAt: new Date().toISOString(),
    evm,
    solana,
    skipped,
  };

  fs.writeFileSync(OUTPUT_PATH, JSON.stringify(out, null, 2) + '\n');

  console.log(`Wrote ${path.relative(process.cwd(), OUTPUT_PATH)}`);
  console.log(`  evm:     ${evm.length} entries`);
  console.log(`  solana:  ${solana.length} entries`);
  console.log(`  skipped: ${skipped.length} entries`);
  if (skipped.length > 0) {
    console.log('\nSkipped (not in config — verify this is intentional):');
    for (const s of skipped) {
      console.log(`  [${s.chain}] ${s.section || '(no section)'} - ${s.displayName} @ ${s.address}`);
    }
  }
  if (coverageProblems.length > 0) {
    console.log('\nCoverage warnings:');
    for (const p of coverageProblems) console.log(`  ${p}`);
  }
}

function loadAllAudits() {
  const result = {};
  const pkgs = fs.readdirSync(CONTRACTS_DIR, { withFileTypes: true });
  for (const entry of pkgs) {
    if (!entry.isDirectory()) continue;
    const readmePath = path.join(CONTRACTS_DIR, entry.name, 'audits', 'README.md');
    if (!fs.existsSync(readmePath)) continue;
    result[entry.name] = parseAuditsReadme(readmePath);
  }
  return result;
}

function loadAllAddressDocs() {
  const result = {};
  for (const [chain, def] of Object.entries(config.chains)) {
    const docPath = path.resolve(REPO_ROOT, def.addressesDoc);
    if (!fs.existsSync(docPath)) continue;
    result[chain] = parseAddressesDoc(docPath);
  }
  return result;
}

/**
 * For each chain this package deploys to, figure out the "default" active tag
 * and its commit. Preference order:
 *   1. chainTagMatrix row for that chain (if the README has one)
 *   2. First Active tag in the tag table, broadcast to every chain listed
 *      in the "Deployed addresses" bullet
 */
function resolveActivePerChain(audit) {
  const out = {};

  if (audit.chainTagMatrix && audit.chainTagMatrix.length > 0) {
    for (const m of audit.chainTagMatrix) {
      if (m.status !== 'active') continue;
      const commit = lookupCommit(audit, m.tag);
      if (!commit) continue;
      out[m.chain] = { tag: m.tag, commit };
    }
    return out;
  }

  // No matrix: pick the first active tag in table order. If there are multiple
  // active tags (e.g. staking main + -luganodes variant), the first one in
  // table order is the "main" default; others surface via overrides only.
  const activeTag = audit.tags.find((t) => t.status === 'active');
  if (!activeTag) return out;

  for (const chain of audit.chains) {
    out[chain] = { tag: activeTag.tag, commit: activeTag.commit };
  }
  return out;
}

function lookupCommit(audit, tag) {
  const t = audit.tags.find((x) => x.tag === tag);
  return t ? t.commit : null;
}

/**
 * Given a parsed address-doc row, return {source, proxy, overrideTag?} if the
 * config routes this row to a source contract in this package, else null.
 */
function resolveRow(pkg, pkgConfig, row) {
  // contracts: exact display-name match
  if (pkgConfig.contracts && row.displayName && pkgConfig.contracts[row.displayName]) {
    const def = pkgConfig.contracts[row.displayName];
    return { source: def.source, proxy: !!def.proxy };
  }

  // sections: row's section or subsection matches
  if (pkgConfig.sections) {
    for (const [sectionKey, def] of Object.entries(pkgConfig.sections)) {
      if (row.section === sectionKey || row.subsection === sectionKey) {
        const override =
          pkgConfig.overrides &&
          pkgConfig.overrides[sectionKey] &&
          pkgConfig.overrides[sectionKey][row.displayName];
        return {
          source: def.source,
          proxy: !!def.proxy,
          overrideTag: override ? override.tag : undefined,
        };
      }
    }
  }

  return null;
}

if (require.main === module) {
  main();
}

module.exports = { main };
