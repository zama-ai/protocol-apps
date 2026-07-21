// // End-to-end observer decryption against a live Sepolia deployment.
// //
// // The local mock cannot cover this: its bundled ACL predates wildcard
// // delegation (no `WILDCARD_DELEGATION_ADDRESS()`), so
// // `isHandleDelegatedForUserDecryption` always returns false there. Only a
// // deployed ACL resolves the wildcard entry the wrapper writes in `addObserver`.
// //
// // Request shape — the wildcard sentinel is an ON-CHAIN concept only and must
// // never appear in the decryption request. `contractAddresses` has to name a
// // real address that is (1) not the delegator, (2) not the sentinel, and (3)
// // itself ACL-allowed on the handle. For wrapper handles that address is the
// // token holder, since balances are allowed to both the wrapper and the holder.
// // The wrapper itself cannot be used: it is the delegator, and the gateway
// // rejects the delegator appearing in `contractAddresses`.
// //
// // Skips unless run against Sepolia with CONFIDENTIAL_WRAPPER_OBSERVER_E2E_ADDRESS
// // set, e.g.
// //   CONFIDENTIAL_WRAPPER_OBSERVER_E2E_ADDRESS=0x... \
// //     npx hardhat test test/ConfidentialWrapperObserversSepolia.test.ts --network testnet

// import assert from 'node:assert/strict';
// import { SepoliaConfig } from '@zama-fhe/relayer-sdk/node';
// import { expect } from 'chai';
// import { HDNodeWallet, Wallet } from 'ethers';
// import { ethers, fhevm } from 'hardhat';

// const SEPOLIA_CHAIN_ID = 11155111n;
// const WILDCARD_CONTRACT = '0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF';
// const MAX_UINT64 = (1n << 64n) - 1n;

// // Sepolia wrap history is sparse; this window comfortably covers the deployment.
// const WRAP_LOOKBACK_BLOCKS = 200_000;
// const DECRYPT_DURATION_DAYS = 1;
// // The relayer reads the host ACL directly, so a mined `addObserver` is normally
// // visible at once. Retry briefly to absorb RPC lag behind the mining node.
// const ACL_VISIBILITY_ATTEMPTS = 10;
// const ACL_VISIBILITY_INTERVAL_MS = 3_000;
// const E2E_TIMEOUT_MS = 10 * 60 * 1000;

// const WRAPPER_ABI = [
//   'event Wrap(address indexed to, uint256 roundedAmount, bytes32 encryptedWrappedAmount)',
//   'function addObserver(address observer)',
//   'function confidentialBalanceOf(address account) view returns (bytes32)',
//   'function isObserver(address observer) view returns (bool)',
//   'function owner() view returns (address)',
//   'function rate() view returns (uint256)',
//   'function removeObserver(address observer)',
// ];

// const ACL_ABI = [
//   'function getUserDecryptionDelegationExpirationDate(address delegator, address delegate, address contractAddress) view returns (uint64)',
//   'function isHandleDelegatedForUserDecryption(address delegator, address delegate, address contractAddress, bytes32 handle) view returns (bool)',
// ];

// const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

// interface ExpectedHandle {
//   readonly label: string;
//   readonly handle: string;
//   /** Known plaintext, when derivable on-chain; undefined for the running balance. */
//   readonly expected?: bigint;
// }

// /**
//  * Decrypt every handle in one delegated request. All handles share the same
//  * `contractAddresses` entry (the holder), which is what lets them batch.
//  */
// async function delegatedDecrypt(
//   handles: readonly string[],
//   wrapperAddress: string,
//   holderAddress: string,
//   delegate: HDNodeWallet,
// ): Promise<Record<string, bigint>> {
//   const keypair = fhevm.generateKeypair();
//   const startTimestamp = Math.floor(Date.now() / 1000);
//   const contractAddresses = [holderAddress];

//   const eip712 = fhevm.createDelegatedUserDecryptEIP712(
//     keypair.publicKey,
//     contractAddresses,
//     wrapperAddress,
//     startTimestamp,
//     DECRYPT_DURATION_DAYS,
//   );
//   const signature = await delegate.signTypedData(
//     eip712.domain,
//     { [eip712.primaryType]: [...eip712.types[eip712.primaryType]] },
//     eip712.message,
//   );

//   return (await fhevm.delegatedUserDecrypt(
//     handles.map(handle => ({ handle, contractAddress: holderAddress })),
//     keypair.privateKey,
//     keypair.publicKey,
//     signature,
//     contractAddresses,
//     wrapperAddress,
//     delegate.address,
//     startTimestamp,
//     DECRYPT_DURATION_DAYS,
//   )) as Record<string, bigint>;
// }

// describe('ConfidentialWrapper Observers (Sepolia e2e)', function () {
//   this.timeout(E2E_TIMEOUT_MS);

//   const wrapperAddress = process.env.CONFIDENTIAL_WRAPPER_OBSERVER_E2E_ADDRESS;

//   let wrapper: any;
//   let acl: any;
//   let holder: string;
//   let observer: HDNodeWallet;
//   let expectedHandles: ExpectedHandle[];

//   before(async function () {
//     const { chainId } = await ethers.provider.getNetwork();
//     if (chainId !== SEPOLIA_CHAIN_ID || !wrapperAddress) {
//       this.skip();
//     }

//     // `fhevm.getRelayerMetadata()` (used by test/utils/accounts) is mock-only,
//     // so the live ACL address comes from the relayer SDK's Sepolia config.
//     await fhevm.initializeCLIApi();

//     wrapper = await ethers.getContractAt(WRAPPER_ABI, wrapperAddress!);
//     acl = await ethers.getContractAt(ACL_ABI, SepoliaConfig.aclContractAddress!);

//     // The configured signer must own the wrapper: only the owner may add observers.
//     const [signer] = await ethers.getSigners();
//     const owner = await wrapper.owner();
//     expect(ethers.getAddress(owner), 'configured signer must own the wrapper').to.equal(
//       ethers.getAddress(signer.address),
//     );

//     // An observer only ever signs an EIP-712 payload off-chain, so an ephemeral
//     // key needs no funding and keeps the run self-contained.
//     observer = Wallet.createRandom();
//     await (await wrapper.connect(signer).addObserver(observer.address)).wait();

//     // Collect several handles the observer should be able to read. Wrap events
//     // carry a cleartext `roundedAmount`, giving exact expectations; the running
//     // balance is included as a third handle without a fixed expectation.
//     const rate = await wrapper.rate();
//     const latestBlock = await ethers.provider.getBlockNumber();
//     const wraps = await wrapper.queryFilter(wrapper.filters.Wrap(), latestBlock - WRAP_LOOKBACK_BLOCKS, latestBlock);
//     if (wraps.length === 0) {
//       throw new Error(`No Wrap events on ${wrapperAddress} in the last ${WRAP_LOOKBACK_BLOCKS} blocks`);
//     }

//     holder = ethers.getAddress(wraps[wraps.length - 1].args.to);
//     expectedHandles = wraps
//       .filter((wrap: any) => ethers.getAddress(wrap.args.to) === holder)
//       .map((wrap: any) => ({
//         label: `wrap amount @ block ${wrap.blockNumber}`,
//         handle: wrap.args.encryptedWrappedAmount,
//         expected: wrap.args.roundedAmount / rate,
//       }));
//     expectedHandles.push({
//       label: 'confidentialBalanceOf(holder)',
//       handle: await wrapper.confidentialBalanceOf(holder),
//     });

//     // Wait until the ACL reports the delegation for every handle.
//     for (let attempt = 0; attempt < ACL_VISIBILITY_ATTEMPTS; attempt++) {
//       const flags = await Promise.all(
//         expectedHandles.map(({ handle }) =>
//           acl.isHandleDelegatedForUserDecryption(wrapperAddress, observer.address, holder, handle),
//         ),
//       );
//       if (flags.every(Boolean)) return;
//       await sleep(ACL_VISIBILITY_INTERVAL_MS);
//     }
//     throw new Error('ACL did not report the wildcard delegation for all handles');
//   });

//   after(async function () {
//     if (wrapper && observer && (await wrapper.isObserver(observer.address))) {
//       const [signer] = await ethers.getSigners();
//       await (await wrapper.connect(signer).removeObserver(observer.address)).wait();
//     }
//   });

//   it('grants the observer a permanent wildcard delegation on-chain', async function () {
//     expect(await wrapper.isObserver(observer.address)).to.equal(true);
//     expect(
//       await acl.getUserDecryptionDelegationExpirationDate(wrapperAddress, observer.address, WILDCARD_CONTRACT),
//     ).to.equal(MAX_UINT64);
//     // The wildcard is resolved by the ACL, not registered per contract.
//     expect(await acl.getUserDecryptionDelegationExpirationDate(wrapperAddress, observer.address, holder)).to.equal(0n);
//   });

//   it('decrypts multiple wrapper handles in a single delegated request', async function () {
//     const results = await delegatedDecrypt(
//       expectedHandles.map(({ handle }) => handle),
//       wrapperAddress!,
//       holder,
//       observer,
//     );

//     expect(Object.keys(results)).to.have.lengthOf(expectedHandles.length);
//     for (const { label, handle, expected } of expectedHandles) {
//       const value = results[handle];
//       expect(value, `${label} should decrypt`).to.be.a('bigint');
//       if (expected !== undefined) {
//         expect(value, `${label} should match its Wrap event`).to.equal(expected);
//       }
//     }
//   });

//   it('rejects the wildcard sentinel as a decryption contract address', async function () {
//     // The sentinel holds no ACL grant, so it can never stand in for the holder.
//     const { handle } = expectedHandles[0];
//     expect(
//       await acl.isHandleDelegatedForUserDecryption(wrapperAddress, observer.address, WILDCARD_CONTRACT, handle),
//     ).to.equal(false);
//     await assert.rejects(delegatedDecrypt([handle], wrapperAddress!, WILDCARD_CONTRACT, observer));
//   });

//   it('stops decrypting once the observer is removed', async function () {
//     const [signer] = await ethers.getSigners();
//     const { handle } = expectedHandles[0];
//     await (await wrapper.connect(signer).removeObserver(observer.address)).wait();

//     expect(await wrapper.isObserver(observer.address)).to.equal(false);
//     expect(
//       await acl.getUserDecryptionDelegationExpirationDate(wrapperAddress, observer.address, WILDCARD_CONTRACT),
//     ).to.equal(0n);
//     await assert.rejects(delegatedDecrypt([handle], wrapperAddress!, holder, observer));
//   });
// });
