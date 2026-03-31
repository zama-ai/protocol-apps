/**
 * Fork-based upgrade simulation for ConfidentialWrapper.
 *
 * Forks the live network, captures state, upgrades the proxy, and verifies
 * that all storage is preserved and new functionality is accessible.
 *
 * Uses hardhat.config.fork.ts (no @fhevm/hardhat-plugin) to avoid genesis
 * storage overrides that conflict with hardhat's forking mode.
 * 
 * Performs best when using an archive node for the forked network.
 * 
 * NOTE: THIS SCRIPT IS ONLY FOR TESTING PURPOSES. DO NOT USE IT IN A PRODUCTION ENVIRONMENT.
 *
 * Usage:
 *   npx hardhat --config hardhat.config.fork.ts run scripts/test-upgrade.ts
 */

import { Contract, Log } from 'ethers';
import { ethers } from 'hardhat';
import { impersonateAccount, setBalance } from '@nomicfoundation/hardhat-network-helpers';
import { CONTRACT_NAME } from '../tasks/deploy';

const WRAPPER_ADDRESS = process.env.CONFIDENTIAL_WRAPPER_UPGRADE_TEST_ADDRESS;
const DEPLOY_BLOCK = parseInt(process.env.CONFIDENTIAL_WRAPPER_UPGRADE_TEST_DEPLOY_BLOCK || '0');

// ERC7201 namespaced storage locations
const ERC7984_BASE = '0xabe6faf3f1b202c971f9850194a6389c7b24dbc9035a913f45a1f82a5d968c00';
const WRAPPER_BASE = '0x789981291a45bfde11e7ba326d04f33e2215f03c85dfc0acebcc6167a5924700';
const IMPLEMENTATION_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';

// Number of finalized requests to sample for verification
const FINALIZED_SAMPLE_SIZE = 3;

// ── Helpers ──────────────────────────────────────────────────────────────────

// Call the old `totalSupply()` selector on the pre-upgrade deployed contract.
async function readTotalSupplyPreUpgrade(address: string): Promise<bigint> {
  const old = new Contract(address, ['function totalSupply() view returns (uint256)'], ethers.provider);
  return (await old.totalSupply()) as bigint;
}

function getMappingSlot(key: string, baseSlot: bigint): string {
  const encoded = ethers.AbiCoder.defaultAbiCoder().encode(['bytes32', 'uint256'], [key, baseSlot]);
  return ethers.keccak256(encoded);
}

async function readStorageSlots(address: string, base: bigint, count: number): Promise<string[]> {
  const values: string[] = [];
  for (let i = 0; i < count; i++) {
    const slot = ethers.toBeHex(base + BigInt(i), 32);
    values.push(await ethers.provider.getStorage(address, slot));
  }
  return values;
}

function addressFromSlotValue(raw: string): string {
  return ethers.getAddress('0x' + raw.slice(26));
}

async function getImplementationAddress(proxyAddress: string): Promise<string> {
  const raw = await ethers.provider.getStorage(proxyAddress, IMPLEMENTATION_SLOT);
  return addressFromSlotValue(raw);
}

async function getLogsChunked(filter: {
  address: string;
  topics: (string | string[])[];
  fromBlock: number;
  toBlock: number;
}): Promise<Log[]> {
  const CHUNK = 5000;
  const allLogs: Log[] = [];
  for (let from = filter.fromBlock; from <= filter.toBlock; from += CHUNK) {
    const to = Math.min(from + CHUNK - 1, filter.toBlock);
    const logs = await ethers.provider.getLogs({ ...filter, fromBlock: from, toBlock: to });
    allLogs.push(...logs);
  }
  return allLogs;
}

interface PendingUnwrap {
  requestId: string;
  recipient: string;
  storageSlot: string;
  rawValue: string;
}

interface UnwrapRequests {
  pending: PendingUnwrap[];
  finalizedIds: string[];
}

async function findUnwrapRequests(wrapperAddress: string): Promise<UnwrapRequests> {
  const latestBlock = await ethers.provider.getBlockNumber();

  // Only old event signatures exist pre-upgrade
  const requestedTopic = ethers.id('UnwrapRequested(address,bytes32)');
  const finalizedTopic = ethers.id('UnwrapFinalized(address,bytes32,uint64)');

  const blockRange = { fromBlock: DEPLOY_BLOCK, toBlock: latestBlock };

  const requestedLogs = await getLogsChunked({
    address: wrapperAddress,
    topics: [requestedTopic],
    ...blockRange,
  });

  const finalizedLogs = await getLogsChunked({
    address: wrapperAddress,
    topics: [finalizedTopic],
    ...blockRange,
  });

  const requestedIds = new Set(
    requestedLogs.map(log => ethers.AbiCoder.defaultAbiCoder().decode(['bytes32'], log.data)[0] as string),
  );
  const finalizedIds = new Set(
    finalizedLogs.map(log => ethers.AbiCoder.defaultAbiCoder().decode(['bytes32', 'uint64'], log.data)[0] as string),
  );

  const unwrapMappingBase = BigInt(WRAPPER_BASE) + 2n;
  const pending: PendingUnwrap[] = [];

  for (const requestId of requestedIds) {
    if (finalizedIds.has(requestId)) continue;

    const storageSlot = getMappingSlot(requestId, unwrapMappingBase);
    const rawValue = await ethers.provider.getStorage(wrapperAddress, storageSlot);
    const recipient = addressFromSlotValue(rawValue);

    assert(recipient !== ethers.ZeroAddress, `pending request ${requestId} has zero-address recipient in storage`);
    pending.push({ requestId, recipient, storageSlot, rawValue });
  }

  return { pending, finalizedIds: [...finalizedIds] };
}

function assert(condition: boolean, message: string) {
  if (!condition) {
    throw new Error(`ASSERTION FAILED: ${message}`);
  }
}

async function assertReverts(fn: () => Promise<unknown>, message: string) {
  try {
    await fn();
    throw new Error(`ASSERTION FAILED: expected revert but succeeded — ${message}`);
  } catch (err: unknown) {
    if (err instanceof Error && err.message.startsWith('ASSERTION FAILED')) throw err;
    // Verify this is actually a contract revert, not a network/infra error
    const errMsg = err instanceof Error ? err.message : String(err);
    const isRevert = errMsg.includes('reverted') || errMsg.includes('CALL_EXCEPTION') || errMsg.includes('execution reverted');
    if (!isRevert) {
      throw new Error(`ASSERTION FAILED: expected a revert but got unexpected error — ${message}\n  Original error: ${errMsg}`);
    }
  }
}

// ── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  if (!WRAPPER_ADDRESS) {
    throw new Error('CONFIDENTIAL_WRAPPER_UPGRADE_TEST_ADDRESS must be set in .env');
  }

  const address = WRAPPER_ADDRESS;
  const wrapper = await ethers.getContractAt(CONTRACT_NAME, address);

  // ── 1. Capture pre-upgrade state ──

  console.log('\n═══ 1. Capturing pre-upgrade state ═══\n');

  const pre = {
    name: await wrapper.name(),
    symbol: await wrapper.symbol(),
    contractURI: await wrapper.contractURI(),
    decimals: await wrapper.decimals(),
    underlying: await wrapper.underlying(),
    rate: await wrapper.rate(),
    totalSupply: await readTotalSupplyPreUpgrade(address),
    maxTotalSupply: await wrapper.maxTotalSupply(),
    owner: await wrapper.owner(),
    implementation: await getImplementationAddress(address),
    erc7984Slots: await readStorageSlots(address, BigInt(ERC7984_BASE), 6),
    wrapperSlots: await readStorageSlots(address, BigInt(WRAPPER_BASE), 3),
    unwrapRequests: await findUnwrapRequests(address),
  };

  const unwrapMappingBase = BigInt(WRAPPER_BASE) + 2n;
  const preUnwrapBaseValue = await ethers.provider.getStorage(address, ethers.toBeHex(unwrapMappingBase, 32));
  const zeroKeySlot = getMappingSlot(ethers.ZeroHash, unwrapMappingBase);
  const preZeroKeyValue = await ethers.provider.getStorage(address, zeroKeySlot);

  console.log(`  name:           ${pre.name}`);
  console.log(`  symbol:         ${pre.symbol}`);
  console.log(`  decimals:       ${pre.decimals}`);
  console.log(`  underlying:     ${pre.underlying}`);
  console.log(`  rate:           ${pre.rate}`);
  console.log(`  totalSupply:    ${pre.totalSupply}`);
  console.log(`  owner:          ${pre.owner}`);
  console.log(`  implementation: ${pre.implementation}`);
  console.log(`  pending unwraps: ${pre.unwrapRequests.pending.length}`);

  if (pre.unwrapRequests.pending.length > 0) {
    console.log('\n  ⚠ Pending unwrap requests:');
    for (const req of pre.unwrapRequests.pending) {
      console.log(`    ${req.requestId} → ${req.recipient}`);
    }
  }

  // ── 2. Execute the upgrade ──

  console.log('\n═══ 2. Executing upgrade ═══\n');

  await impersonateAccount(pre.owner);
  await setBalance(pre.owner, ethers.parseEther('10'));
  const ownerSigner = await ethers.getSigner(pre.owner);

  const factory = await ethers.getContractFactory(CONTRACT_NAME, ownerSigner);
  const newImpl = await factory.deploy();
  await newImpl.waitForDeployment();
  const newImplAddress = await newImpl.getAddress();

  const proxyAsOwner = await ethers.getContractAt(CONTRACT_NAME, address, ownerSigner);
  await proxyAsOwner.upgradeToAndCall(newImplAddress, '0x');

  const postImplementation = await getImplementationAddress(address);
  assert(postImplementation === newImplAddress, 'implementation address mismatch after upgrade');
  assert(postImplementation !== pre.implementation, 'implementation did not change');
  console.log(`  ${pre.implementation} → ${postImplementation}`);

  // ── 3. Verify state preserved ──

  console.log('\n═══ 3. Verifying state preserved ═══\n');

  const upgraded = await ethers.getContractAt(CONTRACT_NAME, address);

  const post = {
    name: await upgraded.name(),
    symbol: await upgraded.symbol(),
    contractURI: await upgraded.contractURI(),
    decimals: await upgraded.decimals(),
    underlying: await upgraded.underlying(),
    rate: await upgraded.rate(),
    totalSupply: await upgraded.inferredTotalSupply(),
    maxTotalSupply: await upgraded.maxTotalSupply(),
    owner: await upgraded.owner(),
    erc7984Slots: await readStorageSlots(address, BigInt(ERC7984_BASE), 6),
    wrapperSlots: await readStorageSlots(address, BigInt(WRAPPER_BASE), 3),
  };

  // Public getters
  const getterFields = [
    'name',
    'symbol',
    'contractURI',
    'decimals',
    'underlying',
    'rate',
    'totalSupply',
    'maxTotalSupply',
    'owner',
  ] as const;
  console.log('  Public getters:');
  for (const field of getterFields) {
    const preVal = String(pre[field]);
    const postVal = String(post[field]);
    const match = preVal === postVal;
    console.log(`    ${field}: ${match ? 'OK' : `CHANGED (${preVal} → ${postVal})`}`);
    assert(match, `${field} changed after upgrade`);
  }

  // Raw storage slots
  const erc7984SlotNames = ['_balances (map)', '_operators (map)', '_totalSupply', '_name', '_symbol', '_contractURI'];
  const wrapperSlotNames = ['_underlying + _decimals (packed)', '_rate', '_unwrapRequests (map base)'];

  console.log('\n  ERC7984 raw storage:');
  for (let i = 0; i < pre.erc7984Slots.length; i++) {
    const match = pre.erc7984Slots[i] === post.erc7984Slots[i];
    console.log(`    ${erc7984SlotNames[i]}: ${match ? 'OK' : 'CHANGED'}`);
    assert(match, `ERC7984 slot ${erc7984SlotNames[i]} changed`);
  }

  console.log('\n  Wrapper raw storage:');
  for (let i = 0; i < pre.wrapperSlots.length; i++) {
    const match = pre.wrapperSlots[i] === post.wrapperSlots[i];
    console.log(`    ${wrapperSlotNames[i]}: ${match ? 'OK' : 'CHANGED'}`);
    assert(match, `Wrapper slot ${wrapperSlotNames[i]} changed`);
  }

  // Mapping probes
  const postUnwrapBaseValue = await ethers.provider.getStorage(address, ethers.toBeHex(unwrapMappingBase, 32));
  const postZeroKeyValue = await ethers.provider.getStorage(address, zeroKeySlot);
  assert(postUnwrapBaseValue === preUnwrapBaseValue, '_unwrapRequests mapping base changed');
  assert(postZeroKeyValue === preZeroKeyValue, '_unwrapRequests zero-key probe changed');

  // Pending unwrap raw storage
  console.log(`\n  Pending unwrap requests (${pre.unwrapRequests.pending.length}):`);
  for (const req of pre.unwrapRequests.pending) {
    const postRaw = await ethers.provider.getStorage(address, req.storageSlot);
    const postRecipient = addressFromSlotValue(postRaw);
    const match = postRaw === req.rawValue;
    console.log(`    ${req.requestId}: ${match ? 'OK' : 'CHANGED'}`);
    assert(match, `_unwrapRequests[${req.requestId}] raw storage changed`);
    assert(postRecipient === req.recipient, `_unwrapRequests[${req.requestId}] recipient changed`);
  }
  if (pre.unwrapRequests.pending.length === 0) {
    console.log('    (none)');
  }

  // ── 4. Verify unwrapRequester() reads pre-upgrade mapping data ──

  console.log('\n═══ 4. Verifying unwrapRequester() with pre-upgrade keys ═══\n');

  const unknownRequester = await upgraded.unwrapRequester(ethers.ZeroHash);
  assert(unknownRequester === ethers.ZeroAddress, 'unwrapRequester(0x00) should return zero address');

  // Pending requests should return their recipient
  if (pre.unwrapRequests.pending.length > 0) {
    console.log(`  Pending (${pre.unwrapRequests.pending.length}):`);
    for (const req of pre.unwrapRequests.pending) {
      const requester = await upgraded.unwrapRequester(req.requestId);
      const match = requester === req.recipient;
      console.log(`    ${req.requestId}`);
      console.log(`      expected: ${req.recipient}`);
      console.log(`      got:      ${requester} ${match ? 'OK' : 'MISMATCH'}`);
      assert(match, `unwrapRequester(${req.requestId}) mismatch`);
    }
  } else {
    console.log('  No pending unwrap requests to verify.');
  }

  // Finalized requests should return address(0)
  const { finalizedIds } = pre.unwrapRequests;
  const finalizedSample = finalizedIds.slice(0, FINALIZED_SAMPLE_SIZE);
  if (finalizedSample.length > 0) {
    console.log(`\n  Finalized (sampling ${finalizedSample.length} of ${finalizedIds.length}):`);
    for (const requestId of finalizedSample) {
      const requester = await upgraded.unwrapRequester(requestId);
      const cleared = requester === ethers.ZeroAddress;
      console.log(`    ${requestId}: ${cleared ? 'OK (cleared)' : `UNEXPECTED (${requester})`}`);
      assert(cleared, `finalized request ${requestId} should have zero-address recipient but got ${requester}`);
    }
  } else {
    console.log('\n  No finalized unwrap requests to verify.');
  }

  // ── 5. Verify new function signatures ──

  console.log('\n═══ 5. Verifying new function signatures ═══\n');

  const unwrapFn = upgraded.interface.getFunction('unwrap(address,address,bytes32,bytes)');
  assert(unwrapFn!.outputs.length === 1, 'unwrap should have 1 output');
  assert(unwrapFn!.outputs[0].type === 'bytes32', 'unwrap should return bytes32');
  console.log('  unwrap(address,address,bytes32,bytes) → bytes32: OK');

  const finalizeFn = upgraded.interface.getFunction('finalizeUnwrap');
  assert(finalizeFn!.inputs[0].type === 'bytes32', 'finalizeUnwrap first param should be bytes32');
  console.log('  finalizeUnwrap(bytes32, ...) : OK');

  const unwrapAmountResult = await upgraded.unwrapAmount(ethers.id('test'));
  assert(unwrapAmountResult !== undefined, 'unwrapAmount should be callable');
  console.log('  unwrapAmount(bytes32) → euint64: OK');

  // totalSupply() was renamed to inferredTotalSupply() — verify the old selector reverts
  const inferredResult = await upgraded.inferredTotalSupply();
  assert(inferredResult !== undefined, 'inferredTotalSupply should be callable');
  console.log('  inferredTotalSupply() → uint256: OK');

  const oldTotalSupplyContract = new Contract(address, ['function totalSupply() view returns (uint256)'], ethers.provider);
  await assertReverts(
    () => oldTotalSupplyContract.totalSupply(),
    'old totalSupply() selector should revert after upgrade',
  );
  console.log('  totalSupply() reverts (selector removed): OK');

  // ── 6. Verify security invariants ──

  console.log('\n═══ 6. Verifying security invariants ═══\n');

  await assertReverts(
    () => upgraded.initialize('hack', 'HACK', 'uri', pre.underlying, pre.owner),
    'should not be re-initializable',
  );
  console.log('  Re-initialization blocked: OK');

  const [nonOwner] = await ethers.getSigners();
  const nonOwnerWrapper = await ethers.getContractAt(CONTRACT_NAME, address, nonOwner);
  await assertReverts(
    () => nonOwnerWrapper.upgradeToAndCall(ethers.hexlify(ethers.randomBytes(20)), '0x'),
    'non-owner should not be able to upgrade',
  );
  console.log('  Non-owner upgrade blocked: OK');

  console.log('\n═══ All checks passed ═══\n');
}

main().catch(error => {
  console.error('\nUpgrade test FAILED:\n');
  console.error(error);
  process.exitCode = 1;
});
