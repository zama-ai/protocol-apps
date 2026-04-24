/**
 * Partial-match bytecode comparison: strip CBOR metadata suffix, then zero out
 * byte ranges that legitimately differ between compile-time artifact and
 * on-chain code (immutables, library placeholders).
 *
 * All hex inputs are strings with leading 0x, matching ethers / hardhat
 * conventions. Byte offsets come from the hardhat artifact in decimal bytes.
 */

function toBuffer(hex) {
  if (!hex) return Buffer.alloc(0);
  const clean = hex.startsWith('0x') ? hex.slice(2) : hex;
  return Buffer.from(clean, 'hex');
}

function toHex(buf) {
  return '0x' + buf.toString('hex');
}

/**
 * Strip Solidity's CBOR metadata suffix from runtime bytecode.
 * The last 2 bytes encode the length of the preceding metadata blob.
 */
function stripMetadata(hex) {
  const buf = toBuffer(hex);
  if (buf.length < 2) return buf;
  const metaLen = buf.readUInt16BE(buf.length - 2);
  const totalSuffix = metaLen + 2;
  if (totalSuffix > buf.length) return buf; // malformed; return as-is
  return buf.subarray(0, buf.length - totalSuffix);
}

/**
 * Zero out byte ranges listed in immutableReferences within a bytecode buffer.
 *
 * immutableReferences looks like:
 *   { "123": [{ start: 456, length: 32 }, ...], ... }
 * where keys are AST ids and values are lists of byte ranges.
 */
function zeroImmutables(buf, immutableReferences) {
  if (!immutableReferences) return buf;
  const out = Buffer.from(buf); // copy
  for (const ranges of Object.values(immutableReferences)) {
    for (const r of ranges) {
      if (r.start + r.length > out.length) continue;
      out.fill(0, r.start, r.start + r.length);
    }
  }
  return out;
}

/**
 * Zero out byte ranges listed in linkReferences within a bytecode buffer.
 *
 * linkReferences looks like:
 *   { "contracts/Foo.sol": { "LibName": [{ start, length }, ...] } }
 */
function zeroLibraries(buf, linkReferences) {
  if (!linkReferences) return buf;
  const out = Buffer.from(buf);
  for (const libs of Object.values(linkReferences)) {
    for (const ranges of Object.values(libs)) {
      for (const r of ranges) {
        if (r.start + r.length > out.length) continue;
        out.fill(0, r.start, r.start + r.length);
      }
    }
  }
  return out;
}

function compare(a, b) {
  if (a.length !== b.length) {
    return {
      ok: false,
      reason: `length mismatch: ${a.length} vs ${b.length}`,
      artifactLen: a.length,
      onChainLen: b.length,
      firstDiffOffset: Math.min(a.length, b.length),
    };
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      return {
        ok: false,
        reason: 'byte mismatch',
        artifactLen: a.length,
        onChainLen: b.length,
        firstDiffOffset: i,
      };
    }
  }
  return { ok: true, artifactLen: a.length, onChainLen: b.length };
}

/**
 * Full partial-match flow for one contract.
 *
 * artifact: hardhat artifact JSON ({ deployedBytecode, immutableReferences, linkReferences })
 * onChainHex: bytecode returned by eth_getCode
 */
function comparePartial(artifact, onChainHex) {
  const artifactStripped = stripMetadata(artifact.deployedBytecode);
  const onChainStripped = stripMetadata(onChainHex);

  const onChainZeroed = zeroLibraries(
    zeroImmutables(onChainStripped, artifact.immutableReferences),
    artifact.linkReferences
  );
  // Artifact bytecode already has zeros at those ranges (placeholders), so
  // zeroing it is a no-op — but we do it for defense-in-depth.
  const artifactZeroed = zeroLibraries(
    zeroImmutables(artifactStripped, artifact.immutableReferences),
    artifact.linkReferences
  );

  return compare(artifactZeroed, onChainZeroed);
}

module.exports = {
  toBuffer,
  toHex,
  stripMetadata,
  zeroImmutables,
  zeroLibraries,
  compare,
  comparePartial,
};
