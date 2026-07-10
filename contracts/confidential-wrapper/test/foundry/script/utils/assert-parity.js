#!/usr/bin/env node
/*
 * Assert two `forge test --json` runs produced identical per-test results and that both
 * fully passed. Used by `make regression` to prove the offline fixture reproduces the live
 * fork with nothing silently skipped.
 *
 * Usage: assert-parity.js <live-run.json> <offline-run.json>
 */

import { readFileSync } from 'node:fs';

function parseForgeJson(path) {
  const raw = readFileSync(path, 'utf8');
  let text = raw.trim();
  try {
    return JSON.parse(text);
  } catch {
    // forge may emit non-JSON preamble; fall back to the outermost JSON object.
    const start = text.indexOf('{');
    const end = text.lastIndexOf('}');
    if (start === -1 || end === -1) throw new Error(`${path} contains no JSON test results.`);
    return JSON.parse(text.slice(start, end + 1));
  }
}

// Flatten forge's { suite: { test_results: { sig: { status } } } } into "suite::sig" -> status.
function resultsMap(report) {
  const map = new Map();
  for (const [suite, suiteReport] of Object.entries(report ?? {})) {
    const tests = suiteReport?.test_results ?? {};
    for (const [sig, result] of Object.entries(tests)) {
      map.set(`${suite}::${sig}`, result?.status ?? 'Unknown');
    }
  }
  return map;
}

function main() {
  const [livePath, offlinePath] = process.argv.slice(2);
  if (!livePath || !offlinePath) {
    console.error('Usage: assert-parity.js <live-run.json> <offline-run.json>');
    process.exit(2);
  }

  const live = resultsMap(parseForgeJson(livePath));
  const offline = resultsMap(parseForgeJson(offlinePath));

  const problems = [];
  if (live.size === 0) problems.push('live run reported no tests');
  if (offline.size === 0) problems.push('offline run reported no tests');

  const allKeys = new Set([...live.keys(), ...offline.keys()]);
  for (const key of [...allKeys].sort()) {
    const liveStatus = live.get(key);
    const offlineStatus = offline.get(key);
    if (liveStatus === undefined) problems.push(`only offline ran: ${key}`);
    else if (offlineStatus === undefined) problems.push(`only live ran: ${key}`);
    else if (liveStatus !== offlineStatus) {
      problems.push(`status differs: ${key} (live=${liveStatus}, offline=${offlineStatus})`);
    } else if (liveStatus !== 'Success') {
      problems.push(`not passing in both: ${key} (${liveStatus})`);
    }
  }

  if (problems.length > 0) {
    console.error(`Regression parity FAILED (${problems.length} issue(s)):`);
    for (const p of problems) console.error(`  - ${p}`);
    process.exit(1);
  }

  console.log(`Regression parity OK: ${live.size} tests passed identically live and offline.`);
}

main();
