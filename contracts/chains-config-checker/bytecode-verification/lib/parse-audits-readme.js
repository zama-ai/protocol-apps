const fs = require('fs');

/**
 * Parse a contracts/<pkg>/audits/README.md file.
 *
 * Extracts the per-tag table (Tag, Commit, Deploy status) and — when present —
 * the per-chain deploy matrix (Chain, Tag, Deploy status). Also derives the
 * list of chains referenced by the README header's "Deployed addresses" bullet.
 *
 * "Active" detection is loose by design: statuses like "Active", "Active (*)",
 * and "Active (**)" all count as active. Footnote semantics (e.g. "deployed
 * for Luganodes only") are not parsed — resolution happens in the gather step
 * using the config's `overrides`.
 */
function parseAuditsReadme(filePath) {
  const content = fs.readFileSync(filePath, 'utf8');

  return {
    tags: extractTagTable(content),
    chains: extractChainsFromHeader(content),
    chainTagMatrix: extractChainTagMatrix(content),
  };
}

// `[`abc1234`](https://github.com/zama-ai/protocol-apps/commit/<full-sha>)` → full SHA
const COMMIT_FULL_SHA_RE = /\[`[a-f0-9]+`\]\(https:\/\/github\.com\/[^/]+\/[^/)]+\/commit\/([a-f0-9]{7,40})\)/i;

function extractTagTable(content) {
  const tables = findTables(content);
  const out = [];

  for (const table of tables) {
    const { headers, rows } = table;

    const tagIdx = headers.findIndex((h) => /^tag$/i.test(h));
    const commitIdx = headers.findIndex((h) => /^commit$/i.test(h));
    if (tagIdx === -1 || commitIdx === -1) continue;
    // Skip the per-chain matrix — that one has a Chain column.
    if (headers.some((h) => /^chain$/i.test(h))) continue;

    // Deploy status is optional here; packages with a per-chain matrix (e.g. token)
    // keep deploy status out of the tag table.
    const statusIdx = headers.findIndex((h) => /^deploy status$/i.test(h));

    for (const row of rows) {
      const tag = stripBackticks(row[tagIdx]);
      const commitCell = row[commitIdx];
      if (!tag || !commitCell) continue;

      const m = commitCell.match(COMMIT_FULL_SHA_RE);
      if (!m) continue;

      const statusRaw = statusIdx === -1 ? null : (row[statusIdx] || '').trim();
      out.push({
        tag,
        commit: m[1],
        status: statusRaw === null ? null : normalizeStatus(statusRaw),
        statusRaw,
      });
    }
  }

  return out;
}

function extractChainTagMatrix(content) {
  const tables = findTables(content);
  const out = [];

  for (const table of tables) {
    const { headers, rows } = table;
    const chainIdx = headers.findIndex((h) => /^chain$/i.test(h));
    const tagIdx = headers.findIndex((h) => /^tag$/i.test(h));
    const statusIdx = headers.findIndex((h) => /^deploy status$/i.test(h));
    if (chainIdx === -1 || tagIdx === -1 || statusIdx === -1) continue;

    for (const row of rows) {
      const chain = (row[chainIdx] || '').trim();
      const tag = stripBackticks(row[tagIdx]);
      const statusRaw = (row[statusIdx] || '').trim();
      if (!chain || !tag) continue;
      out.push({
        chain: normalizeChainName(chain),
        tag,
        status: normalizeStatus(statusRaw),
        statusRaw,
      });
    }
  }

  return out.length > 0 ? out : null;
}

// Header bullet: "- Deployed addresses: [Ethereum mainnet](../../../docs/addresses/mainnet/ethereum.md), ..."
function extractChainsFromHeader(content) {
  const m = content.match(/^-\s*Deployed addresses:\s*(.+)$/im);
  if (!m) return [];

  const links = [...m[1].matchAll(/\(([^)]*docs\/addresses\/[^)]+)\)/g)];
  const chains = new Set();
  for (const link of links) {
    const href = link[1];
    // .../mainnet/<chain>.md or .../testnet/<chain>.md
    const fm = href.match(/\/(mainnet|testnet)\/([^/]+?)\.md$/);
    if (!fm) continue;
    // Only keep mainnet here — scope decision.
    if (fm[1] !== 'mainnet') continue;
    chains.add(normalizeChainName(fm[2]));
  }
  return [...chains];
}

function normalizeChainName(raw) {
  return raw.toLowerCase().replace(/[\s_-]/g, '');
}

function normalizeStatus(raw) {
  const s = raw.replace(/[*_`]/g, '').trim().toLowerCase();
  // ✅ in a per-chain Deploy status column means "deployed", i.e. active.
  if (s.includes('✅') || s.startsWith('active')) return 'active';
  if (s.startsWith('upcoming')) return 'upcoming';
  if (s.startsWith('skipped')) return 'skipped';
  if (s === '-' || s === '—' || s === '') return 'none';
  return s;
}

function stripBackticks(cell) {
  if (!cell) return '';
  const m = cell.match(/`([^`]+)`/);
  return (m ? m[1] : cell).trim();
}

// Walk markdown lines, collecting GFM pipe tables as {headers, rows}.
function findTables(content) {
  const lines = content.split(/\r?\n/);
  const tables = [];

  for (let i = 0; i < lines.length - 1; i++) {
    const headerLine = lines[i];
    const sepLine = lines[i + 1];
    if (!isPipeRow(headerLine) || !isSeparatorRow(sepLine)) continue;

    const headers = splitRow(headerLine);
    const rows = [];
    let j = i + 2;
    while (j < lines.length && isPipeRow(lines[j]) && !isSeparatorRow(lines[j])) {
      rows.push(splitRow(lines[j]));
      j++;
    }
    tables.push({ headers, rows });
    i = j - 1;
  }

  return tables;
}

function isPipeRow(line) {
  if (!line) return false;
  const trimmed = line.trim();
  return trimmed.startsWith('|') && trimmed.endsWith('|');
}

function isSeparatorRow(line) {
  if (!isPipeRow(line)) return false;
  return splitRow(line).every((cell) => /^:?-{2,}:?$/.test(cell.trim()));
}

function splitRow(line) {
  // Trim outer pipes, split on unescaped pipes.
  const inner = line.trim().replace(/^\|/, '').replace(/\|$/, '');
  return inner.split(/(?<!\\)\|/).map((c) => c.trim());
}

module.exports = { parseAuditsReadme };
