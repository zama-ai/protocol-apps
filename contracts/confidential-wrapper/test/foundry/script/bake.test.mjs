import assert from "node:assert/strict";
import test from "node:test";

import {
  applyBlacklistEvents,
  calldataFor,
  canonicalEventSignature,
  configuredBlacklistBaseSlot,
  configuredDeployBlock,
  decodePairs,
  eventTopic,
  highBitWord,
  mappingSlot,
  upsertSidecar,
  validateDeltaNotBackwards,
  wordDenyValue,
  wordHex,
} from "./bake.mjs";

function word(value) {
  return BigInt(value).toString(16).padStart(64, "0");
}

function addressWord(address) {
  return address.toLowerCase().replace(/^0x/u, "").padStart(64, "0");
}

test("decodePairs decodes registry tuple array ABI", () => {
  const token = "0x00000000000000000000000000000000000000aa";
  const wrapper = "0x00000000000000000000000000000000000000bb";
  const raw = `0x${word(32)}${word(1)}${addressWord(token)}${addressWord(wrapper)}${word(1)}`;

  assert.deepEqual(decodePairs(raw), [{ token, wrapper, valid: true }]);
});

test("calldataFor encodes simple function signatures", () => {
  assert.equal(calldataFor("decimals()"), "0x313ce567");
  assert.equal(
    calldataFor("supportsInterface(bytes4)", ["0xb0202a11"]),
    "0x01ffc9a7b0202a1100000000000000000000000000000000000000000000000000000000",
  );
});

test("eventTopic hashes canonical event signatures", () => {
  assert.equal(canonicalEventSignature("Banned(address indexed account)"), "Banned(address)");
  assert.equal(canonicalEventSignature("AddedBlackList(address _user)"), "AddedBlackList(address)");
  assert.equal(
    eventTopic("Banned(address indexed account)"),
    "0x30d1df1214d91553408ca5384ce29e10e5866af8423c628be22860e41fb81005",
  );
});

test("mappingSlot matches Solidity mapping slot layout", () => {
  assert.equal(
    mappingSlot("0x000000000000000000000000000000000000dEaD", 9),
    "0x960b1051749987b45b5679007fff577a1c2f763ec21c15a6c5eb193075003785",
  );
});

test("applyBlacklistEvents folds add/remove events onto prior members", () => {
  const prior = new Set([
    "0x00000000000000000000000000000000000000aa",
    "0x00000000000000000000000000000000000000bb",
  ]);

  assert.deepEqual(
    applyBlacklistEvents(prior, [
      { kind: "REMOVE", address: "0x00000000000000000000000000000000000000aa" },
      { kind: "ADD", address: "0x00000000000000000000000000000000000000cc" },
    ]),
    [
      "0x00000000000000000000000000000000000000bb",
      "0x00000000000000000000000000000000000000cc",
    ],
  );
});

test("highBitWord preserves low bits while toggling bit 255", () => {
  const source = wordHex(0x1234n);
  const denied = highBitWord(source, true);
  assert.equal(denied, "0x8000000000000000000000000000000000000000000000000000000000001234");
  assert.equal(highBitWord(denied, false), source);
  assert.equal(wordDenyValue(true), wordHex(1n));
  assert.equal(wordDenyValue(false), wordHex(0n));
});

test("validateDeltaNotBackwards rejects stale target blocks", () => {
  const sidecar = upsertSidecar(
    { tokens: [] },
    "0x00000000000000000000000000000000000000aa",
    "word",
    9,
    100,
    [],
    100,
  );

  assert.throws(
    () => validateDeltaNotBackwards(sidecar, ["0x00000000000000000000000000000000000000aa"], 99),
    /Refusing backwards delta/u,
  );
  assert.doesNotThrow(() =>
    validateDeltaNotBackwards(sidecar, ["0x00000000000000000000000000000000000000aa"], 100),
  );
});

test("configuredDeployBlock validates optional blacklist deployBlock", () => {
  assert.equal(configuredDeployBlock({ deployBlock: 123 }), 123);
  assert.equal(configuredDeployBlock({}), undefined);
  assert.throws(() => configuredDeployBlock({ name: "BAD", deployBlock: -1 }), /Invalid deployBlock/u);
  assert.throws(() => configuredDeployBlock({ name: "BAD", deployBlock: 1.5 }), /Invalid deployBlock/u);
});

test("configuredBlacklistBaseSlot validates optional blacklist baseSlot", () => {
  assert.equal(configuredBlacklistBaseSlot({ baseSlot: 9 }), 9);
  assert.equal(
    configuredBlacklistBaseSlot({ baseSlot: "0x9" }),
    "0x0000000000000000000000000000000000000000000000000000000000000009",
  );
  assert.equal(configuredBlacklistBaseSlot({ baseSlot: "9" }), wordHex(9n));
  assert.equal(configuredBlacklistBaseSlot({}), undefined);
  assert.throws(() => configuredBlacklistBaseSlot({ name: "BAD", baseSlot: -1 }), /Invalid baseSlot/u);
  assert.throws(() => configuredBlacklistBaseSlot({ name: "BAD", baseSlot: "nope" }), /Invalid baseSlot/u);
});
