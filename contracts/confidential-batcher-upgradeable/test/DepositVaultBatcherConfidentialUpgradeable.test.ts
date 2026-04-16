import { FhevmType } from '@fhevm/hardhat-plugin';
import { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/signers';
import { time } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers, fhevm } from 'hardhat';

import type { DepositVaultBatcherConfidentialUpgradeable } from '../types/contracts/DepositVaultBatcherConfidentialUpgradeable';
import type { $ERC20Mock } from '../types/contracts-exposed/mocks/ERC20Mock.sol/$ERC20Mock';
import type { ERC4626Mock } from '../types/contracts/mocks/ERC4626Mock';
import type { ERC7984ERC20WrapperMock } from '../types/contracts/mocks/ERC7984ERC20WrapperMock';

/** Cast Addressable | string to string for fhevm helpers. */
function addr(target: string | { toString(): string }): string {
  return target.toString();
}

// ─── Constants ─────────────────────────────────────────────────────────────────
const MIN_BATCH_AGE = 3600; // 1 hour
const RETRY_WINDOW = 604_800; // 7 days
const DEPOSIT_AMOUNT = 1_000_000n; // 1.000000 wrapped (6 decimal places)
const DEFAULT_USER_MINT = 10_000_000; // 10.000000 underlying (6 decimals)
const MaxUint48 = 2n ** 48n - 1n; // setOperator "until" far-future timestamp

/* eslint-disable no-unexpected-multiline */
describe('DepositVaultBatcherConfidentialUpgradeable', function () {
  let owner: HardhatEthersSigner;
  let user: HardhatEthersSigner;
  let other: HardhatEthersSigner;

  let underlying: $ERC20Mock;
  let vault: ERC4626Mock;
  let cToken: ERC7984ERC20WrapperMock; // wraps underlying (fromToken)
  let cShare: ERC7984ERC20WrapperMock; // wraps vault shares (toToken)
  let batcher: DepositVaultBatcherConfidentialUpgradeable;
  let impl: DepositVaultBatcherConfidentialUpgradeable;

  beforeEach(async function () {
    [owner, user, other] = await ethers.getSigners();

    // 1. Deploy mock underlying ERC20 (6 decimals)
    underlying = (await ethers.deployContract('$ERC20Mock', [
      'Mock USDC',
      'USDC',
      6,
    ])) as unknown as $ERC20Mock;

    // 2. Deploy mock ERC4626 vault backed by underlying
    vault = (await ethers.deployContract('ERC4626Mock', [
      underlying.target,
      'Vault Share',
      'vUSDC',
    ])) as unknown as ERC4626Mock;

    // 3. Deploy confidential wrappers
    //    cToken wraps underlying (fromToken for deposits)
    cToken = (await ethers.deployContract('ERC7984ERC20WrapperMock', [
      underlying.target,
      'Confidential USDC',
      'cUSDC',
    ])) as unknown as ERC7984ERC20WrapperMock;

    //    cShare wraps vault shares (toToken for deposits)
    cShare = (await ethers.deployContract('ERC7984ERC20WrapperMock', [
      vault.target,
      'Confidential vUSDC',
      'cvUSDC',
    ])) as unknown as ERC7984ERC20WrapperMock;

    // 4. Deploy batcher implementation with constructor args (immutables)
    const batcherFactory = await ethers.getContractFactory(
      'DepositVaultBatcherConfidentialUpgradeable',
    );
    impl = (await batcherFactory.deploy(
      cToken.target,
      cShare.target,
      vault.target,
    )) as unknown as DepositVaultBatcherConfidentialUpgradeable;

    // 5. Deploy ERC1967Proxy with initialize calldata
    const initData = impl.interface.encodeFunctionData('initialize', [
      owner.address,
      MIN_BATCH_AGE,
      RETRY_WINDOW,
    ]);
    const proxy = await ethers.deployContract('ERC1967Proxy', [
      impl.target,
      initData,
    ]);
    batcher = batcherFactory.attach(
      proxy.target,
    ) as unknown as DepositVaultBatcherConfidentialUpgradeable;
  });

  // ─── Initialize ──────────────────────────────────────────────────────────────
  describe('Initialize', function () {
    it('sets owner to deployer', async function () {
      expect(await batcher.owner()).to.equal(owner.address);
    });

    it('sets minBatchAge', async function () {
      expect(await batcher.minBatchAge()).to.equal(MIN_BATCH_AGE);
    });

    it('sets retryWindow', async function () {
      expect(await batcher.retryWindow()).to.equal(RETRY_WINDOW);
    });

    it('sets currentBatchId to 1', async function () {
      expect(await batcher.currentBatchId()).to.equal(1);
    });

    it('sets batchCreatedAt for batch 1', async function () {
      const createdAt = await batcher.batchCreatedAt(1);
      expect(createdAt).to.be.gt(0);
    });

    it('cannot be called twice on the proxy', async function () {
      await expect(
        batcher.initialize(owner.address, MIN_BATCH_AGE, RETRY_WINDOW),
      ).to.be.revertedWithCustomError(batcher, 'InvalidInitialization');
    });

    it('cannot be called on the implementation', async function () {
      await expect(
        impl.initialize(owner.address, MIN_BATCH_AGE, RETRY_WINDOW),
      ).to.be.revertedWithCustomError(impl, 'InvalidInitialization');
    });

    it('reverts when fromToken underlying does not match vault asset', async function () {
      // Deploy a second underlying so the wrapper's underlying != vault.asset()
      const otherUnderlying = await ethers.deployContract('$ERC20Mock', [
        'Other',
        'OTHER',
        6,
      ]);
      const badFromToken = await ethers.deployContract(
        'ERC7984ERC20WrapperMock',
        [otherUnderlying.target, 'bad', 'BAD'],
      );

      const batcherFactory = await ethers.getContractFactory(
        'DepositVaultBatcherConfidentialUpgradeable',
      );
      const badImpl = await batcherFactory.deploy(
        badFromToken.target,
        cShare.target,
        vault.target,
      );
      const initData = badImpl.interface.encodeFunctionData('initialize', [
        owner.address,
        MIN_BATCH_AGE,
        RETRY_WINDOW,
      ]);

      await expect(
        ethers.deployContract('ERC1967Proxy', [badImpl.target, initData]),
      ).to.be.reverted;
    });

    it('reverts when toToken underlying does not match vault address', async function () {
      const badToToken = await ethers.deployContract(
        'ERC7984ERC20WrapperMock',
        [underlying.target, 'bad', 'BAD'],
      );

      const batcherFactory = await ethers.getContractFactory(
        'DepositVaultBatcherConfidentialUpgradeable',
      );
      const badImpl = await batcherFactory.deploy(
        cToken.target,
        badToToken.target,
        vault.target,
      );
      const initData = badImpl.interface.encodeFunctionData('initialize', [
        owner.address,
        MIN_BATCH_AGE,
        RETRY_WINDOW,
      ]);

      await expect(
        ethers.deployContract('ERC1967Proxy', [badImpl.target, initData]),
      ).to.be.reverted;
    });
  });

  // ─── Upgrade ─────────────────────────────────────────────────────────────────
  describe('Upgrade', function () {
    it('preserves storage state after upgrade', async function () {
      const minBatchAgeBefore = await batcher.minBatchAge();
      const retryWindowBefore = await batcher.retryWindow();
      const batchIdBefore = await batcher.currentBatchId();

      // Deploy new implementation
      const batcherFactory = await ethers.getContractFactory(
        'DepositVaultBatcherConfidentialUpgradeable',
      );
      const newImpl = await batcherFactory.deploy(
        cToken.target,
        cShare.target,
        vault.target,
      );
      await batcher.connect(owner).upgradeToAndCall(newImpl.target, '0x');

      expect(await batcher.minBatchAge()).to.equal(minBatchAgeBefore);
      expect(await batcher.retryWindow()).to.equal(retryWindowBefore);
      expect(await batcher.currentBatchId()).to.equal(batchIdBefore);
    });

    it('only owner can authorize upgrade', async function () {
      const batcherFactory = await ethers.getContractFactory(
        'DepositVaultBatcherConfidentialUpgradeable',
      );
      const newImpl = await batcherFactory.deploy(
        cToken.target,
        cShare.target,
        vault.target,
      );

      await expect(
        batcher.connect(other).upgradeToAndCall(newImpl.target, '0x'),
      ).to.be.revertedWithCustomError(batcher, 'OwnableUnauthorizedAccount');
    });

    it('batch lifecycle works after upgrade', async function () {
      // Deploy new implementation and upgrade
      const batcherFactory = await ethers.getContractFactory(
        'DepositVaultBatcherConfidentialUpgradeable',
      );
      const newImpl = await batcherFactory.deploy(
        cToken.target,
        cShare.target,
        vault.target,
      );
      await batcher.connect(owner).upgradeToAndCall(newImpl.target, '0x');

      // Now run a full deposit lifecycle to verify everything works
      // Mint, approve, wrap, deposit, dispatch, callback, claim
      const rawAmount = BigInt(DEFAULT_USER_MINT) * (await cToken.rate());
      await underlying.$_mint(user.address, rawAmount);
      await underlying.connect(user).approve(cToken.target, ethers.MaxUint256);
      await cToken.connect(user).wrap(user.address, rawAmount);

      // Set operator so batcher can unwrap on behalf of cToken
      await cToken.connect(user).setOperator(batcher.target, MaxUint48);

      // Confidential transfer to batcher
      const encryptedInput = await fhevm
        .createEncryptedInput(addr(cToken.target), user.address)
        .add64(DEPOSIT_AMOUNT)
        .encrypt();

      await cToken
        .connect(user)
        ['confidentialTransferAndCall(address,bytes32,bytes,bytes)'](
          batcher.target,
          encryptedInput.handles[0],
          encryptedInput.inputProof,
          '0x',
        );

      const batchId = await batcher.currentBatchId();
      expect(batchId).to.be.gte(1);

      // Advance time past minBatchAge
      await time.increase(MIN_BATCH_AGE + 1);

      // Dispatch
      await batcher.dispatchBatch();

      // Public decrypt and callback
      const dispatchedBatchId = batchId;
      const unwrapReqId = await batcher.unwrapRequestId(dispatchedBatchId);
      const unwrapHandle = await cToken.unwrapAmount(unwrapReqId);
      const { abiEncodedClearValues, decryptionProof } =
        await fhevm.publicDecrypt([unwrapHandle]);
      const cleartext = ethers.AbiCoder.defaultAbiCoder().decode(
        ['uint64'],
        abiEncodedClearValues,
      )[0];

      await batcher.dispatchBatchCallback(
        dispatchedBatchId,
        cleartext,
        decryptionProof,
      );

      // Verify batch is finalized
      expect(await batcher.batchState(dispatchedBatchId)).to.equal(2); // Finalized

      // Claim
      await batcher.claim(dispatchedBatchId, user.address);

      // Verify user received toToken (cShare)
      const cShareBalanceHandle = await cShare.confidentialBalanceOf(
        user.address,
      );
      const cShareBalance = await fhevm.userDecryptEuint(
        FhevmType.euint64,
        cShareBalanceHandle,
        addr(cShare.target),
        user,
      );
      expect(cShareBalance).to.be.gt(0);
    });
  });

  // ─── Policy Setters ──────────────────────────────────────────────────────────
  describe('Policy Setters', function () {
    describe('setMinBatchAge', function () {
      it('owner can update minBatchAge', async function () {
        const newAge = 7200;
        await batcher.connect(owner).setMinBatchAge(newAge);
        expect(await batcher.minBatchAge()).to.equal(newAge);
      });

      it('non-owner cannot update minBatchAge', async function () {
        await expect(
          batcher.connect(other).setMinBatchAge(7200),
        ).to.be.revertedWithCustomError(batcher, 'OwnableUnauthorizedAccount');
      });

      it('emits MinBatchAgeSet event', async function () {
        const newAge = 7200;
        await expect(batcher.connect(owner).setMinBatchAge(newAge))
          .to.emit(batcher, 'MinBatchAgeSet')
          .withArgs(newAge);
      });
    });

    describe('setRetryWindow', function () {
      it('owner can update retryWindow', async function () {
        const newWindow = 1_209_600;
        await batcher.connect(owner).setRetryWindow(newWindow);
        expect(await batcher.retryWindow()).to.equal(newWindow);
      });

      it('non-owner cannot update retryWindow', async function () {
        await expect(
          batcher.connect(other).setRetryWindow(1_209_600),
        ).to.be.revertedWithCustomError(batcher, 'OwnableUnauthorizedAccount');
      });

      it('emits RetryWindowSet event', async function () {
        const newWindow = 1_209_600;
        await expect(batcher.connect(owner).setRetryWindow(newWindow))
          .to.emit(batcher, 'RetryWindowSet')
          .withArgs(newWindow);
      });
    });

    describe('setMaxSlippageBps', function () {
      it('owner can update maxSlippageBps', async function () {
        const newBps = 500;
        await batcher.connect(owner).setMaxSlippageBps(newBps);
        expect(await batcher.maxSlippageBps()).to.equal(newBps);
      });

      it('non-owner cannot update maxSlippageBps', async function () {
        await expect(
          batcher.connect(other).setMaxSlippageBps(500),
        ).to.be.revertedWithCustomError(batcher, 'OwnableUnauthorizedAccount');
      });

      it('emits MaxSlippageBpsSet event', async function () {
        const newBps = 500;
        await expect(batcher.connect(owner).setMaxSlippageBps(newBps))
          .to.emit(batcher, 'MaxSlippageBpsSet')
          .withArgs(newBps);
      });

      it('reverts when exceeding 10000 bps', async function () {
        await expect(
          batcher.connect(owner).setMaxSlippageBps(10_001),
        ).to.be.revertedWithCustomError(batcher, 'InvalidMaxSlippageBps');
      });
    });
  });

  // ─── Pause ───────────────────────────────────────────────────────────────────
  describe('Pause', function () {
    it('owner can pause', async function () {
      await batcher.connect(owner).pause();
      expect(await batcher.paused()).to.equal(true);
    });

    it('owner can unpause', async function () {
      await batcher.connect(owner).pause();
      await batcher.connect(owner).unpause();
      expect(await batcher.paused()).to.equal(false);
    });

    it('non-owner cannot pause', async function () {
      await expect(
        batcher.connect(other).pause(),
      ).to.be.revertedWithCustomError(batcher, 'OwnableUnauthorizedAccount');
    });

    it('non-owner cannot unpause', async function () {
      await batcher.connect(owner).pause();
      await expect(
        batcher.connect(other).unpause(),
      ).to.be.revertedWithCustomError(batcher, 'OwnableUnauthorizedAccount');
    });

    it('dispatchBatch reverts when paused', async function () {
      await batcher.connect(owner).pause();
      await time.increase(MIN_BATCH_AGE + 1);
      await expect(batcher.dispatchBatch()).to.be.revertedWithCustomError(
        batcher,
        'EnforcedPause',
      );
    });

    it('deposits revert when paused', async function () {
      // Setup: mint, approve, wrap
      const rawAmount = BigInt(DEFAULT_USER_MINT) * (await cToken.rate());
      await underlying.$_mint(user.address, rawAmount);
      await underlying.connect(user).approve(cToken.target, ethers.MaxUint256);
      await cToken.connect(user).wrap(user.address, rawAmount);
      await cToken.connect(user).setOperator(batcher.target, MaxUint48);

      // Pause
      await batcher.connect(owner).pause();

      // Attempt deposit via confidentialTransferAndCall
      const encryptedInput = await fhevm
        .createEncryptedInput(addr(cToken.target), user.address)
        .add64(DEPOSIT_AMOUNT)
        .encrypt();

      await expect(
        cToken
          .connect(user)
          ['confidentialTransferAndCall(address,bytes32,bytes,bytes)'](
            batcher.target,
            encryptedInput.handles[0],
            encryptedInput.inputProof,
            '0x',
          ),
      ).to.be.reverted;
    });

    it('quit works when paused', async function () {
      // Setup: deposit first
      const rawAmount = BigInt(DEFAULT_USER_MINT) * (await cToken.rate());
      await underlying.$_mint(user.address, rawAmount);
      await underlying.connect(user).approve(cToken.target, ethers.MaxUint256);
      await cToken.connect(user).wrap(user.address, rawAmount);
      await cToken.connect(user).setOperator(batcher.target, MaxUint48);

      const encryptedInput = await fhevm
        .createEncryptedInput(addr(cToken.target), user.address)
        .add64(DEPOSIT_AMOUNT)
        .encrypt();
      await cToken
        .connect(user)
        ['confidentialTransferAndCall(address,bytes32,bytes,bytes)'](
          batcher.target,
          encryptedInput.handles[0],
          encryptedInput.inputProof,
          '0x',
        );

      const batchId = await batcher.currentBatchId();

      // Pause
      await batcher.connect(owner).pause();

      // Quit should still work
      await expect(batcher.connect(user).quit(batchId)).to.not.be.reverted;
    });

    it('claim works when paused (on finalized batch)', async function () {
      // Full lifecycle first: deposit -> dispatch -> callback
      const rawAmount = BigInt(DEFAULT_USER_MINT) * (await cToken.rate());
      await underlying.$_mint(user.address, rawAmount);
      await underlying.connect(user).approve(cToken.target, ethers.MaxUint256);
      await cToken.connect(user).wrap(user.address, rawAmount);
      await cToken.connect(user).setOperator(batcher.target, MaxUint48);

      const encryptedInput = await fhevm
        .createEncryptedInput(addr(cToken.target), user.address)
        .add64(DEPOSIT_AMOUNT)
        .encrypt();
      await cToken
        .connect(user)
        ['confidentialTransferAndCall(address,bytes32,bytes,bytes)'](
          batcher.target,
          encryptedInput.handles[0],
          encryptedInput.inputProof,
          '0x',
        );

      const batchId = await batcher.currentBatchId();
      await time.increase(MIN_BATCH_AGE + 1);
      await batcher.dispatchBatch();

      const unwrapReqId = await batcher.unwrapRequestId(batchId);
      const unwrapHandle = await cToken.unwrapAmount(unwrapReqId);
      const { abiEncodedClearValues, decryptionProof } =
        await fhevm.publicDecrypt([unwrapHandle]);
      const cleartext = ethers.AbiCoder.defaultAbiCoder().decode(
        ['uint64'],
        abiEncodedClearValues,
      )[0];
      await batcher.dispatchBatchCallback(batchId, cleartext, decryptionProof);

      // Now pause
      await batcher.connect(owner).pause();

      // Claim should still work
      await expect(batcher.claim(batchId, user.address)).to.not.be.reverted;
    });
  });

  // ─── Batch Lifecycle ─────────────────────────────────────────────────────────
  describe('Batch Lifecycle', function () {
    beforeEach(async function () {
      // Mint underlying to user, approve wrapper, wrap tokens
      const rawAmount = BigInt(DEFAULT_USER_MINT) * (await cToken.rate());
      await underlying.$_mint(user.address, rawAmount);
      await underlying.connect(user).approve(cToken.target, ethers.MaxUint256);
      await cToken.connect(user).wrap(user.address, rawAmount);

      // Set operator so batcher can interact with wrapped tokens
      await cToken.connect(user).setOperator(batcher.target, MaxUint48);
    });

    it('full lifecycle: deposit -> dispatch -> callback -> claim', async function () {
      // 1. Deposit via confidentialTransferAndCall
      const encryptedInput = await fhevm
        .createEncryptedInput(addr(cToken.target), user.address)
        .add64(DEPOSIT_AMOUNT)
        .encrypt();

      await cToken
        .connect(user)
        ['confidentialTransferAndCall(address,bytes32,bytes,bytes)'](
          batcher.target,
          encryptedInput.handles[0],
          encryptedInput.inputProof,
          '0x',
        );

      const batchId = await batcher.currentBatchId();

      // 2. Advance time past minBatchAge
      await time.increase(MIN_BATCH_AGE + 1);

      // 3. Dispatch
      await expect(batcher.dispatchBatch())
        .to.emit(batcher, 'BatchDispatched')
        .withArgs(batchId);

      // Batch is now dispatched
      expect(await batcher.batchState(batchId)).to.equal(1); // Dispatched

      // 4. Public decrypt and callback
      const unwrapReqId = await batcher.unwrapRequestId(batchId);
      const unwrapHandle = await cToken.unwrapAmount(unwrapReqId);
      const { abiEncodedClearValues, decryptionProof } =
        await fhevm.publicDecrypt([unwrapHandle]);
      const cleartext = ethers.AbiCoder.defaultAbiCoder().decode(
        ['uint64'],
        abiEncodedClearValues,
      )[0];

      await expect(
        batcher.dispatchBatchCallback(batchId, cleartext, decryptionProof),
      ).to.emit(batcher, 'BatchFinalized');

      // Batch is now finalized
      expect(await batcher.batchState(batchId)).to.equal(2); // Finalized

      // 5. Claim
      await expect(batcher.claim(batchId, user.address)).to.emit(
        batcher,
        'Claimed',
      );

      // Verify user received cShare tokens
      const cShareBalanceHandle = await cShare.confidentialBalanceOf(
        user.address,
      );
      const cShareBalance = await fhevm.userDecryptEuint(
        FhevmType.euint64,
        cShareBalanceHandle,
        addr(cShare.target),
        user,
      );
      expect(cShareBalance).to.be.gt(0);
    });

    it('dispatchBatch reverts when batch is too young', async function () {
      // Deposit first
      const encryptedInput = await fhevm
        .createEncryptedInput(addr(cToken.target), user.address)
        .add64(DEPOSIT_AMOUNT)
        .encrypt();
      await cToken
        .connect(user)
        ['confidentialTransferAndCall(address,bytes32,bytes,bytes)'](
          batcher.target,
          encryptedInput.handles[0],
          encryptedInput.inputProof,
          '0x',
        );

      // Try to dispatch immediately (no time advancement)
      await expect(batcher.dispatchBatch()).to.be.revertedWithCustomError(
        batcher,
        'BatchTooYoung',
      );
    });

    it('vault revert stays dispatched within retry window', async function () {
      // Make vault revert deposits
      await vault.setRevertDeposits(true);

      // Deposit
      const encryptedInput = await fhevm
        .createEncryptedInput(addr(cToken.target), user.address)
        .add64(DEPOSIT_AMOUNT)
        .encrypt();
      await cToken
        .connect(user)
        ['confidentialTransferAndCall(address,bytes32,bytes,bytes)'](
          batcher.target,
          encryptedInput.handles[0],
          encryptedInput.inputProof,
          '0x',
        );

      const batchId = await batcher.currentBatchId();
      await time.increase(MIN_BATCH_AGE + 1);

      // Dispatch
      await batcher.dispatchBatch();

      // Callback with vault reverting (within retry window)
      const unwrapReqId = await batcher.unwrapRequestId(batchId);
      const unwrapHandle = await cToken.unwrapAmount(unwrapReqId);
      const { abiEncodedClearValues, decryptionProof } =
        await fhevm.publicDecrypt([unwrapHandle]);
      const cleartext = ethers.AbiCoder.defaultAbiCoder().decode(
        ['uint64'],
        abiEncodedClearValues,
      )[0];
      await batcher.dispatchBatchCallback(batchId, cleartext, decryptionProof);

      // Batch should remain dispatched (Partial outcome, not canceled yet)
      expect(await batcher.batchState(batchId)).to.equal(1); // Dispatched
    });

    it('vault revert cancels after retry window expires', async function () {
      // Make vault revert deposits
      await vault.setRevertDeposits(true);

      // Deposit
      const encryptedInput = await fhevm
        .createEncryptedInput(addr(cToken.target), user.address)
        .add64(DEPOSIT_AMOUNT)
        .encrypt();
      await cToken
        .connect(user)
        ['confidentialTransferAndCall(address,bytes32,bytes,bytes)'](
          batcher.target,
          encryptedInput.handles[0],
          encryptedInput.inputProof,
          '0x',
        );

      const batchId = await batcher.currentBatchId();
      await time.increase(MIN_BATCH_AGE + 1);

      // Dispatch
      await batcher.dispatchBatch();

      // Advance time past retry window
      await time.increase(RETRY_WINDOW + 1);

      // Callback with vault still reverting (past retry window -> cancel)
      const unwrapReqId = await batcher.unwrapRequestId(batchId);
      const unwrapHandle = await cToken.unwrapAmount(unwrapReqId);
      const { abiEncodedClearValues, decryptionProof } =
        await fhevm.publicDecrypt([unwrapHandle]);
      const cleartext = ethers.AbiCoder.defaultAbiCoder().decode(
        ['uint64'],
        abiEncodedClearValues,
      )[0];

      await expect(
        batcher.dispatchBatchCallback(batchId, cleartext, decryptionProof),
      ).to.emit(batcher, 'BatchCanceled');

      // Batch should be canceled
      expect(await batcher.batchState(batchId)).to.equal(3); // Canceled
    });

    it('user can quit a pending batch', async function () {
      // Deposit
      const encryptedInput = await fhevm
        .createEncryptedInput(addr(cToken.target), user.address)
        .add64(DEPOSIT_AMOUNT)
        .encrypt();
      await cToken
        .connect(user)
        ['confidentialTransferAndCall(address,bytes32,bytes,bytes)'](
          batcher.target,
          encryptedInput.handles[0],
          encryptedInput.inputProof,
          '0x',
        );

      const batchId = await batcher.currentBatchId();

      // Quit
      await expect(batcher.connect(user).quit(batchId))
        .to.emit(batcher, 'Quit')
        .withArgs(batchId, user.address, () => true);
    });

    it('user can quit a canceled batch', async function () {
      // Make vault revert deposits
      await vault.setRevertDeposits(true);

      // Deposit
      const encryptedInput = await fhevm
        .createEncryptedInput(addr(cToken.target), user.address)
        .add64(DEPOSIT_AMOUNT)
        .encrypt();
      await cToken
        .connect(user)
        ['confidentialTransferAndCall(address,bytes32,bytes,bytes)'](
          batcher.target,
          encryptedInput.handles[0],
          encryptedInput.inputProof,
          '0x',
        );

      const batchId = await batcher.currentBatchId();
      await time.increase(MIN_BATCH_AGE + 1);
      await batcher.dispatchBatch();

      // Move past retry window so callback cancels
      await time.increase(RETRY_WINDOW + 1);

      const unwrapReqId = await batcher.unwrapRequestId(batchId);
      const unwrapHandle = await cToken.unwrapAmount(unwrapReqId);
      const { abiEncodedClearValues, decryptionProof } =
        await fhevm.publicDecrypt([unwrapHandle]);
      const cleartext = ethers.AbiCoder.defaultAbiCoder().decode(
        ['uint64'],
        abiEncodedClearValues,
      )[0];
      await batcher.dispatchBatchCallback(batchId, cleartext, decryptionProof);

      // Quit from canceled batch
      await expect(batcher.connect(user).quit(batchId)).to.not.be.reverted;
    });
  });
});
