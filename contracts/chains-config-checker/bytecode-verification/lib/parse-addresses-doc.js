const fs = require('fs');

/**
 * Parse a docs/addresses/<network>/<chain>.md file into a flat list of rows.
 *
 * Each row is {section, subsection, displayName, role, address}.
 *   - section: nearest `##` heading
 *   - subsection: nearest `###` heading (null if none)
 *   - displayName: first "name-like" column (not Role/Symbol/Underlying*)
 *   - role: value of a `Role` column if present (e.g. "KMS", "Coprocessor"),
 *     else null. Kept so multi-instance rows (2× ProtocolStaking, 18×
 *     OperatorStaking) stay distinguishable downstream.
 *   - address: first `0x…` address in the row (extracted from the markdown
 *     backtick-wrapped link)
 */
function parseAddressesDoc(filePath) {
  const content = fs.readFileSync(filePath, 'utf8');
  const lines = content.split(/\r?\n/);

  const rows = [];
  let section = null;
  let subsection = null;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    const h2 = line.match(/^##\s+(.+?)\s*$/);
    if (h2) {
      section = h2[1].trim();
      subsection = null;
      continue;
    }

    const h3 = line.match(/^###\s+(.+?)\s*$/);
    if (h3) {
      subsection = h3[1].trim();
      continue;
    }

    if (!isPipeRow(line)) continue;

    // Need a header + separator to start parsing this table.
    const headerLine = line;
    const sepLine = lines[i + 1];
    if (!isPipeRow(sepLine) || !isSeparatorRow(sepLine)) continue;

    const headers = splitRow(headerLine);
    const nameColIdx = findNameColumn(headers);
    const roleColIdx = headers.findIndex((h) => /^role$/i.test(h));

    let j = i + 2;
    while (j < lines.length && isPipeRow(lines[j]) && !isSeparatorRow(lines[j])) {
      const cells = splitRow(lines[j]);
      const address = extractFirstAddress(cells);
      if (address) {
        rows.push({
          section,
          subsection,
          displayName: nameColIdx >= 0 ? stripMarkdown(cells[nameColIdx]) : null,
          role: roleColIdx >= 0 ? stripMarkdown(cells[roleColIdx]) : null,
          address,
        });
      }
      j++;
    }
    i = j - 1;
  }

  return rows;
}

const NON_NAME_HEADERS = [
  /^role$/i,
  /^symbol$/i,
  /^underlying/i,
  /^address$/i,
];

function findNameColumn(headers) {
  for (let i = 0; i < headers.length; i++) {
    if (!NON_NAME_HEADERS.some((re) => re.test(headers[i]))) return i;
  }
  return -1;
}

// Accepts EVM 0x… (40 hex) and base58 Solana addresses (32+ chars, no 0/O/I/l).
// Returns the first address-looking token in the row.
function extractFirstAddress(cells) {
  for (const cell of cells) {
    const backtick = cell.match(/`([^`]+)`/);
    if (!backtick) continue;
    const raw = backtick[1].trim();
    if (/^0x[a-fA-F0-9]{40}$/.test(raw)) return raw;
    if (/^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(raw)) return raw;
  }
  return null;
}

function stripMarkdown(cell) {
  if (!cell) return '';
  // Strip link syntax: [text](href) -> text
  let s = cell.replace(/\[([^\]]+)\]\([^)]+\)/g, '$1');
  // Strip backticks
  s = s.replace(/`/g, '');
  return s.trim();
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
  const inner = line.trim().replace(/^\|/, '').replace(/\|$/, '');
  return inner.split(/(?<!\\)\|/).map((c) => c.trim());
}

module.exports = { parseAddressesDoc };
