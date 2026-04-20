// Ported from https://github.com/OpenZeppelin/openzeppelin-confidential-contracts/blob/v0.4.0-rc.0/test/finance/BatcherConfidential.test.ts
//
// Adapted to the upgradeable (UUPS) fork. The concrete mock
// `BatcherConfidentialSwapMockUpgradeable` replaces upstream's non-upgradeable
// `$BatcherConfidentialSwapMock` and is deployed via `upgrades.deployProxy`.

import { FhevmType } from '@fhevm/hardhat-plugin';
import { anyValue } from '@nomicfoundation/hardhat-chai-matchers/withArgs';
import { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers, fhevm, upgrades } from 'hardhat';

import type { BatcherConfidentialSwapMockUpgradeable } from '../types/contracts/mocks/BatcherConfidentialSwapMockUpgradeable';
import type { ERC7984ERC20WrapperMock } from '../types/contracts/mocks/ERC7984ERC20WrapperMock';
import type { ExchangeMock } from '../types/contracts/mocks/ExchangeMock';

const name = 'ConfidentialFungibleToken';
const symbol = 'CFT';
const wrapAmount = BigInt(ethers.parseEther('10'));
const exchangeRateDecimals = 6n;
const exchangeRateMantissa = 10n ** exchangeRateDecimals;

enum BatchState {
  Pending,
  Dispatched,
  Finalized,
  Canceled,
}

enum ExecuteOutcome {
  Complete,
  Partial,
  Cancel,
}

// Helper to encode batch state as bitmap (mirrors _encodeStateBitmap in contract).
function encodeStateBitmap(...states: BatchState[]): bigint {
  return states.reduce((acc, state) => acc | (1n << BigInt(state)), 0n);
}

async function deployBatcher(
  fromToken: string,
  toToken: string,
  exchange: string,
  admin: string,
  owner: string,
): Promise<BatcherConfidentialSwapMockUpgradeable> {
  const factory = await ethers.getContractFactory('BatcherConfidentialSwapMockUpgradeable');
  const proxy = await upgrades.deployProxy(factory, [fromToken, toToken, exchange, admin, owner], {
    initializer: 'initialize',
    kind: 'uups',
  });
  await proxy.waitForDeployment();
  return factory.attach(await proxy.getAddress()) as unknown as BatcherConfidentialSwapMockUpgradeable;
}

describe('BatcherConfidential', function () {
  beforeEach(async function () {
    const accounts = await ethers.getSigners();
    const [holder, recipient, operator] = accounts;

    const fromTokenUnderlying = await ethers.deployContract('$ERC20Mock', [name, symbol, 18]);
    const toTokenUnderlying = await ethers.deployContract('$ERC20Mock', [name, symbol, 18]);

    const fromToken = (await ethers.deployContract('ERC7984ERC20WrapperMock', [
      fromTokenUnderlying,
      name,
      symbol,
    ])) as unknown as ERC7984ERC20WrapperMock;
    const toToken = (await ethers.deployContract('ERC7984ERC20WrapperMock', [
      toTokenUnderlying,
      name,
      symbol,
    ])) as unknown as ERC7984ERC20WrapperMock;

    for (const { to, tokens } of [holder, recipient].flatMap(x =>
      [
        { underlying: fromTokenUnderlying, wrapper: fromToken },
        { underlying: toTokenUnderlying, wrapper: toToken },
      ].map(y => ({ to: x, tokens: y })),
    )) {
      await tokens.underlying.$_mint(to, wrapAmount);
      await tokens.underlying.connect(to).approve(tokens.wrapper, wrapAmount);
      await tokens.wrapper.connect(to).wrap(to, wrapAmount);
    }

    const exchange = (await ethers.deployContract('ExchangeMock', [
      fromTokenUnderlying,
      toTokenUnderlying,
      ethers.parseEther('1'),
    ])) as unknown as ExchangeMock;

    await Promise.all(
      [fromTokenUnderlying, toTokenUnderlying].map(async token => {
        await token.$_mint(exchange, ethers.parseEther('1000'));
      }),
    );

    const batcher = await deployBatcher(
      await fromToken.getAddress(),
      await toToken.getAddress(),
      await exchange.getAddress(),
      operator.address,
      holder.address,
    );

    for (const approver of [holder, recipient]) {
      await fromToken.connect(approver).setOperator(batcher, 2n ** 48n - 1n);
    }

    Object.assign(this, {
      exchange,
      batcher,
      fromTokenUnderlying,
      toTokenUnderlying,
      fromToken,
      toToken,
      accounts: accounts.slice(3),
      holder,
      recipient,
      operator,
      fromTokenRate: BigInt(await fromToken.rate()),
      toTokenRate: BigInt(await toToken.rate()),
    });
  });

  it('should reject invalid fromToken', async function () {
    // Plain ERC-20 does not support IERC7984ERC20Wrapper via ERC-165.
    const plainErc20 = await ethers.deployContract('$ERC20Mock', ['Plain', 'PLAIN', 18]);
    await expect(
      deployBatcher(
        await plainErc20.getAddress(),
        await this.toToken.getAddress(),
        await this.exchange.getAddress(),
        this.operator.address,
        this.holder.address,
      ),
    )
      .to.be.revertedWithCustomError(this.batcher, 'InvalidWrapperToken')
      .withArgs(plainErc20.target);
  });

  it('should reject invalid toToken', async function () {
    const plainErc20 = await ethers.deployContract('$ERC20Mock', ['Plain', 'PLAIN', 18]);
    await expect(
      deployBatcher(
        await this.fromToken.getAddress(),
        await plainErc20.getAddress(),
        await this.exchange.getAddress(),
        this.operator.address,
        this.holder.address,
      ),
    )
      .to.be.revertedWithCustomError(this.batcher, 'InvalidWrapperToken')
      .withArgs(plainErc20.target);
  });

  for (const viaCallback of [true, false]) {
    describe(`join ${viaCallback ? 'via callback' : 'directly'}`, async function () {
      const join = async function (
        token: ERC7984ERC20WrapperMock,
        sender: HardhatEthersSigner,
        batcher: BatcherConfidentialSwapMockUpgradeable,
        amount: bigint,
      ) {
        if (viaCallback) {
          const encryptedInput = await fhevm
            .createEncryptedInput(token.target.toString(), sender.address)
            .add64(amount)
            .encrypt();

          return token
            .connect(sender)
            [
              'confidentialTransferAndCall(address,bytes32,bytes,bytes)'
            ](batcher, encryptedInput.handles[0], encryptedInput.inputProof, ethers.ZeroHash);
        } else {
          return batcher.connect(sender)['join(uint64)'](amount);
        }
      };

      it('should increase individual deposits', async function () {
        const batchId = await this.batcher.currentBatchId();

        await expect(this.batcher.deposits(batchId, this.holder)).to.eventually.eq(ethers.ZeroHash);

        await join(this.fromToken, this.holder, this.batcher, 1000n);

        await expect(
          fhevm.userDecryptEuint(
            FhevmType.euint64,
            await this.batcher.deposits(batchId, this.holder),
            this.batcher,
            this.holder,
          ),
        ).to.eventually.eq('1000');

        await join(this.fromToken, this.holder, this.batcher, 2000n);

        await expect(
          fhevm.userDecryptEuint(
            FhevmType.euint64,
            await this.batcher.deposits(batchId, this.holder),
            this.batcher,
            this.holder,
          ),
        ).to.eventually.eq('3000');
      });

      it('should increase total deposits', async function () {
        const batchId = await this.batcher.currentBatchId();
        await join(this.fromToken, this.holder, this.batcher, 1000n);
        await join(this.fromToken, this.recipient, this.batcher, 2000n);

        await expect(
          fhevm.userDecryptEuint(
            FhevmType.euint64,
            await this.batcher.totalDeposits(batchId),
            this.batcher,
            this.operator,
          ),
        ).to.eventually.eq('3000');
      });

      it('should emit event', async function () {
        const batchId = await this.batcher.currentBatchId();

        await expect(join(this.fromToken, this.holder, this.batcher, 1000n))
          .to.emit(this.batcher, 'Joined')
          .withArgs(batchId, this.holder.address, anyValue);
      });

      it('should not credit failed transaction', async function () {
        const batchId = await this.batcher.currentBatchId();

        await this.batcher.join(wrapAmount / this.fromTokenRate + 1n);

        await expect(
          fhevm.userDecryptEuint(
            FhevmType.euint64,
            await this.batcher.deposits(batchId, this.holder),
            this.batcher,
            this.holder,
          ),
        ).to.eventually.eq(0);
      });

      if (viaCallback) {
        it('must come from the token', async function () {
          await expect(
            this.batcher.onConfidentialTransferReceived(ethers.ZeroAddress, this.holder, ethers.ZeroHash, '0x'),
          ).to.be.revertedWithCustomError(this.batcher, 'Unauthorized');
        });
      }
    });
  }

  describe('claim', function () {
    beforeEach(async function () {
      this.batchId = await this.batcher.currentBatchId();

      await this.batcher.join(1000);
      await this.batcher.connect(this.holder).dispatchBatch();

      const [, amount] = (await this.fromToken.queryFilter(this.fromToken.filters.UnwrapRequested()))[0].args;
      const { abiEncodedClearValues, decryptionProof } = await fhevm.publicDecrypt([amount]);
      await this.batcher.dispatchBatchCallback(this.batchId, abiEncodedClearValues, decryptionProof);

      this.exchangeRate = BigInt(await this.batcher.exchangeRate(this.batchId));
      this.deposit = 1000n;
    });

    it('should clear deposits', async function () {
      await this.batcher.claim(this.batchId, this.holder);

      await expect(
        fhevm.userDecryptEuint(
          FhevmType.euint64,
          await this.batcher.deposits(this.batchId, this.holder),
          this.batcher,
          this.holder,
        ),
      ).to.eventually.eq(0);
    });

    it('should transfer out correct amount of toToken', async function () {
      const beforeBalanceToTokens = await fhevm.userDecryptEuint(
        FhevmType.euint64,
        await this.toToken.confidentialBalanceOf(this.holder),
        this.toToken,
        this.holder,
      );

      await this.batcher.claim(this.batchId, this.holder);

      await expect(
        fhevm.userDecryptEuint(
          FhevmType.euint64,
          await this.toToken.confidentialBalanceOf(this.holder),
          this.toToken,
          this.holder,
        ),
      ).to.eventually.eq(
        BigInt(beforeBalanceToTokens) + BigInt(this.exchangeRate * this.deposit) / exchangeRateMantissa,
      );
    });

    it('should revert if not finalized', async function () {
      const currentBatchId = await this.batcher.currentBatchId();
      await expect(this.batcher.claim(currentBatchId, this.holder))
        .to.be.revertedWithCustomError(this.batcher, 'BatchUnexpectedState')
        .withArgs(currentBatchId, BatchState.Pending, encodeStateBitmap(BatchState.Finalized));
    });

    it('should revert if account did not participate in the batch', async function () {
      await expect(this.batcher.claim(this.batchId, this.recipient))
        .to.be.revertedWithCustomError(this.batcher, 'ZeroDeposits')
        .withArgs(this.batchId, this.recipient.address);
    });

    it('should emit event', async function () {
      await expect(this.batcher.claim(this.batchId, this.holder))
        .to.emit(this.batcher, 'Claimed')
        .withArgs(this.batchId, this.holder.address, anyValue);
    });

    it('should allow retry claim (idempotent when fully claimed)', async function () {
      await this.batcher.claim(this.batchId, this.holder);

      await expect(
        fhevm.userDecryptEuint(
          FhevmType.euint64,
          await this.batcher.deposits(this.batchId, this.holder),
          this.batcher,
          this.holder,
        ),
      ).to.eventually.eq(0);

      await expect(this.batcher.claim(this.batchId, this.holder)).to.emit(this.batcher, 'Claimed');

      await expect(
        fhevm.userDecryptEuint(
          FhevmType.euint64,
          await this.batcher.deposits(this.batchId, this.holder),
          this.batcher,
          this.holder,
        ),
      ).to.eventually.eq(0);
    });

    it('should track failed claims properly', async function () {
      // Burn `toToken` from batcher to induce a failed transfer.
      await this.toToken['$_burn(address,uint64)'](this.batcher, 100n);

      let claimEvent = (await (await this.batcher.claim(this.batchId, this.holder)).wait()).logs.filter(
        (log: any) => log.address === this.batcher.target,
      )[0];
      let claimAmount = claimEvent.args[2];

      await expect(
        fhevm.userDecryptEuint(FhevmType.euint64, claimAmount, this.toToken.target, this.holder),
      ).to.eventually.eq(0);

      await this.toToken['$_mint(address,uint64)'](this.batcher, 100n);

      claimEvent = (await (await this.batcher.claim(this.batchId, this.holder)).wait()).logs.filter(
        (log: any) => log.address === this.batcher.target,
      )[0];
      claimAmount = claimEvent.args[2];

      await expect(
        fhevm.userDecryptEuint(FhevmType.euint64, claimAmount, this.toToken.target, this.holder),
      ).to.eventually.eq(1000n);
    });

    describe('on behalf of (relayer)', function () {
      it('should send tokens to the depositor, not the relayer', async function () {
        const relayer = this.accounts[0];

        const holderBalanceBefore = await fhevm.userDecryptEuint(
          FhevmType.euint64,
          await this.toToken.confidentialBalanceOf(this.holder),
          this.toToken,
          this.holder,
        );

        await this.batcher.connect(relayer).claim(this.batchId, this.holder);

        const expectedAmount = BigInt(this.exchangeRate * this.deposit) / exchangeRateMantissa;

        await expect(
          fhevm.userDecryptEuint(
            FhevmType.euint64,
            await this.toToken.confidentialBalanceOf(this.holder),
            this.toToken,
            this.holder,
          ),
        ).to.eventually.eq(BigInt(holderBalanceBefore) + expectedAmount);
      });

      it('should clear the depositor deposits', async function () {
        const relayer = this.accounts[0];

        await this.batcher.connect(relayer).claim(this.batchId, this.holder);

        await expect(
          fhevm.userDecryptEuint(
            FhevmType.euint64,
            await this.batcher.deposits(this.batchId, this.holder),
            this.batcher,
            this.holder,
          ),
        ).to.eventually.eq(0);
      });

      it('should emit event with the depositor address', async function () {
        const relayer = this.accounts[0];

        await expect(this.batcher.connect(relayer).claim(this.batchId, this.holder))
          .to.emit(this.batcher, 'Claimed')
          .withArgs(this.batchId, this.holder.address, anyValue);
      });
    });
  });

  describe('quit', function () {
    beforeEach(async function () {
      this.batchId = await this.batcher.currentBatchId();
      this.deposit = 1000n;

      await this.batcher.join(this.deposit);
    });

    it('should send back full deposit', async function () {
      const beforeBalance = await fhevm.userDecryptEuint(
        FhevmType.euint64,
        await this.fromToken.confidentialBalanceOf(this.holder),
        this.fromToken,
        this.holder,
      );

      await this.batcher.quit(this.batchId);

      await expect(
        fhevm.userDecryptEuint(
          FhevmType.euint64,
          await this.fromToken.confidentialBalanceOf(this.holder),
          this.fromToken,
          this.holder,
        ),
      ).to.eventually.eq(beforeBalance + this.deposit);

      await expect(
        fhevm.userDecryptEuint(
          FhevmType.euint64,
          await this.batcher.deposits(this.batchId, this.holder),
          this.batcher,
          this.holder,
        ),
      ).to.eventually.eq(0);
    });

    it('should decrease total deposits', async function () {
      await this.batcher.quit(this.batchId);

      await expect(
        fhevm.userDecryptEuint(
          FhevmType.euint64,
          await this.batcher.totalDeposits(this.batchId),
          this.batcher,
          this.operator,
        ),
      ).to.eventually.eq(0);
    });

    it('should fail if batch already dispatched', async function () {
      await this.batcher.connect(this.holder).dispatchBatch();

      await expect(this.batcher.quit(this.batchId))
        .to.be.revertedWithCustomError(this.batcher, 'BatchUnexpectedState')
        .withArgs(this.batchId, BatchState.Dispatched, encodeStateBitmap(BatchState.Pending, BatchState.Canceled));
    });

    it('should revert if caller did not participate in the batch', async function () {
      await expect(this.batcher.connect(this.recipient).quit(this.batchId))
        .to.be.revertedWithCustomError(this.batcher, 'ZeroDeposits')
        .withArgs(this.batchId, this.recipient.address);
    });

    it('should emit event', async function () {
      await expect(this.batcher.quit(this.batchId))
        .to.emit(this.batcher, 'Quit')
        .withArgs(this.batchId, this.holder.address, anyValue);
    });
  });

  describe('dispatchBatchCallback', function () {
    beforeEach(async function () {
      const joinAmount = 1000n;
      const batchId = await this.batcher.currentBatchId();

      await this.batcher.connect(this.holder).join(joinAmount);
      await this.batcher.connect(this.holder).dispatchBatch();

      const [, amount] = (await this.fromToken.queryFilter(this.fromToken.filters.UnwrapRequested()))[0].args;
      const { abiEncodedClearValues, decryptionProof } = await fhevm.publicDecrypt([amount]);

      await expect(this.batcher.unwrapRequestId(batchId)).to.eventually.eq(amount);

      Object.assign(this, { joinAmount, batchId, unwrapAmount: amount, abiEncodedClearValues, decryptionProof });
    });

    it('should finalize unwrap', async function () {
      await expect(this.batcher.dispatchBatchCallback(this.batchId, this.abiEncodedClearValues, this.decryptionProof))
        .to.emit(this.fromToken, 'UnwrapFinalized')
        .withArgs(this.batcher, this.unwrapAmount, this.unwrapAmount, this.abiEncodedClearValues);
    });

    it('should revert if proof validation fails', async function () {
      await this.fromToken.finalizeUnwrap(this.unwrapAmount, this.abiEncodedClearValues, this.decryptionProof);
      await expect(this.batcher.dispatchBatchCallback(1, BigInt(this.abiEncodedClearValues) + 1n, this.decryptionProof))
        .to.be.reverted;
    });

    it('should succeed if unwrap already finalized', async function () {
      await this.fromToken.finalizeUnwrap(this.unwrapAmount, this.abiEncodedClearValues, this.decryptionProof);
      await this.batcher.dispatchBatchCallback(this.batchId, this.abiEncodedClearValues, this.decryptionProof);
    });

    it('should emit event on batch finalization', async function () {
      await expect(this.batcher.dispatchBatchCallback(this.batchId, this.abiEncodedClearValues, this.decryptionProof))
        .to.emit(this.batcher, 'BatchFinalized')
        .withArgs(this.batchId, 10n ** 6n);
    });

    it('should be able to call multiple times if `_executeRoute` returns partial', async function () {
      await this.batcher.setExecutionOutcome(ExecuteOutcome.Partial);

      await this.batcher.dispatchBatchCallback(this.batchId, this.abiEncodedClearValues, this.decryptionProof);
      await this.batcher.dispatchBatchCallback(this.batchId, this.abiEncodedClearValues, this.decryptionProof);

      await this.batcher.setExecutionOutcome(ExecuteOutcome.Complete);

      await this.batcher.dispatchBatchCallback(this.batchId, this.abiEncodedClearValues, this.decryptionProof);
      await expect(
        this.batcher.dispatchBatchCallback(this.batchId, this.abiEncodedClearValues, this.decryptionProof),
      ).to.be.revertedWithCustomError(this.batcher, 'BatchUnexpectedState');
    });

    it('should cancel if `_executeRoute` returns cancel', async function () {
      await this.batcher.setExecutionOutcome(ExecuteOutcome.Cancel);
      const tx = this.batcher.dispatchBatchCallback(this.batchId, this.abiEncodedClearValues, this.decryptionProof);
      await expect(tx).to.emit(this.batcher, 'BatchCanceled').withArgs(this.batchId);

      await expect(tx)
        .to.emit(this.fromTokenUnderlying, 'Transfer')
        .withArgs(this.fromToken, this.batcher, this.joinAmount * this.fromTokenRate) // unwrap
        .to.emit(this.fromTokenUnderlying, 'Transfer')
        .withArgs(this.batcher, this.fromToken, this.joinAmount * this.fromTokenRate); // rewrap
    });

    it("should revert if `_executeRoute` doesn't receive any to token underlying", async function () {
      await this.exchange.setExchangeRate(0);

      await expect(this.batcher.dispatchBatchCallback(this.batchId, this.abiEncodedClearValues, this.decryptionProof))
        .to.be.revertedWithCustomError(this.batcher, 'InvalidExchangeRate')
        .withArgs(this.batchId, this.joinAmount, 0);
    });

    it('should cancel if unwrap amount is 0', async function () {
      await this.batcher.connect(this.holder).join(0n);

      await this.batcher.connect(this.holder).dispatchBatch();

      const [, amount] = (await this.fromToken.queryFilter(this.fromToken.filters.UnwrapRequested()))[1].args;
      const { abiEncodedClearValues, decryptionProof } = await fhevm.publicDecrypt([amount]);

      await expect(this.batcher.dispatchBatchCallback(this.batchId + 1n, abiEncodedClearValues, decryptionProof))
        .to.emit(this.batcher, 'BatchCanceled')
        .withArgs(this.batchId + 1n);
    });
  });

  describe('dispatchBatch', function () {
    beforeEach(async function () {
      this.batchId = await this.batcher.currentBatchId();

      await this.batcher.join(1000);
    });

    it('should emit event', async function () {
      await expect(this.batcher.dispatchBatch()).to.emit(this.batcher, 'BatchDispatched').withArgs(this.batchId);
    });
  });

  describe('batch state', async function () {
    beforeEach(async function () {
      const joinAmount = 1000n;
      const batchId = await this.batcher.currentBatchId();

      await this.batcher.connect(this.holder).join(joinAmount);
      await this.batcher.connect(this.holder).dispatchBatch();

      const [, amount] = (await this.fromToken.queryFilter(this.fromToken.filters.UnwrapRequested()))[0].args;
      const { abiEncodedClearValues, decryptionProof } = await fhevm.publicDecrypt([amount]);

      Object.assign(this, { joinAmount, batchId, unwrapAmount: amount, abiEncodedClearValues, decryptionProof });
    });

    it('should revert if batch does not exist', async function () {
      const nonExistentBatchId = this.batchId + 2n;
      await expect(this.batcher.batchState(nonExistentBatchId))
        .to.be.revertedWithCustomError(this.batcher, 'BatchNonexistent')
        .withArgs(nonExistentBatchId);
    });

    it('should return canceled if canceled', async function () {
      await this.batcher.setExecutionOutcome(ExecuteOutcome.Cancel);
      await this.batcher.dispatchBatchCallback(this.batchId, this.abiEncodedClearValues, this.decryptionProof);

      await expect(this.batcher.batchState(this.batchId)).to.eventually.eq(BatchState.Canceled);
    });

    it('should return finalized if finalized', async function () {
      await this.batcher.dispatchBatchCallback(this.batchId, this.abiEncodedClearValues, this.decryptionProof);

      await expect(this.batcher.batchState(this.batchId)).to.eventually.eq(BatchState.Finalized);
    });

    it('should return dispatched if dispatched', async function () {
      await expect(this.batcher.batchState(this.batchId)).to.eventually.eq(BatchState.Dispatched);
    });

    it('should return pending if pending', async function () {
      await expect(this.batcher.batchState(this.batchId + 1n)).to.eventually.eq(BatchState.Pending);
    });
  });

  it('cancel and quit takes tokens from the next batch', async function () {
    const amount1 = 1337n;
    const amount2 = 4337n;

    // Fresh batcher with no exchange (we never reach the swap path since we force Cancel).
    const batcher = await deployBatcher(
      await this.fromToken.getAddress(),
      await this.toToken.getAddress(),
      await this.exchange.getAddress(), // unused; kept to satisfy the ERC-165 check path
      this.operator.address,
      this.holder.address,
    );
    await this.fromToken.connect(this.holder).setOperator(batcher, 2n ** 48n - 1n);

    // ========================== First batch ==========================
    const batchId1 = await batcher.currentBatchId();

    // batch is empty
    await expect(batcher.totalDeposits(batchId1)).to.eventually.eq(0n);

    // join
    await batcher.connect(this.holder).join(amount1);

    // batch has deposit
    await expect(
      fhevm.userDecryptEuint(FhevmType.euint64, await batcher.totalDeposits(batchId1), batcher, this.operator),
    ).to.eventually.eq(amount1);

    // dispatch
    await batcher.dispatchBatch();

    // dispatch amount is publicly decryptable
    const { abiEncodedClearValues, decryptionProof } = await batcher
      .unwrapRequestId(batchId1)
      .then(amount => fhevm.publicDecrypt([amount]));

    expect(abiEncodedClearValues).to.eq(amount1);

    // cancel the batch
    const rate = await this.fromToken.rate();
    await batcher.setExecutionOutcome(ExecuteOutcome.Cancel);
    await expect(batcher.dispatchBatchCallback(batchId1, abiEncodedClearValues, decryptionProof))
      .to.emit(this.fromTokenUnderlying, 'Transfer')
      .withArgs(this.fromToken, batcher, amount1 * rate) // unwrap
      .to.emit(this.fromTokenUnderlying, 'Transfer')
      .withArgs(batcher, this.fromToken, amount1 * rate); // rewrap

    // quit
    const balanceBefore = await fhevm.userDecryptEuint(
      FhevmType.euint64,
      await this.fromToken.confidentialBalanceOf(this.holder),
      this.fromToken,
      this.holder,
    );

    await batcher.connect(this.holder).quit(batchId1);

    const balanceAfter = await fhevm.userDecryptEuint(
      FhevmType.euint64,
      await this.fromToken.confidentialBalanceOf(this.holder),
      this.fromToken,
      this.holder,
    );

    expect(balanceAfter - balanceBefore).to.eq(amount1);

    // batch size was reduced
    await expect(
      fhevm.userDecryptEuint(FhevmType.euint64, await batcher.totalDeposits(batchId1), batcher, this.operator),
    ).to.eventually.eq(0n);

    // ========================== Second batch ==========================
    const batchId2 = await batcher.currentBatchId();

    // batch is empty
    await expect(batcher.totalDeposits(batchId2)).to.eventually.eq(0n);

    // join
    await batcher.connect(this.holder).join(amount2);

    // batch has deposit
    await expect(
      fhevm.userDecryptEuint(FhevmType.euint64, await batcher.totalDeposits(batchId2), batcher, this.operator),
    ).to.eventually.eq(amount2);

    // Second batch: dispatch
    await batcher.dispatchBatch();

    // Check unwrap amount
    await expect(
      batcher
        .unwrapRequestId(batchId2)
        .then(amount => fhevm.publicDecrypt([amount]))
        .then(({ abiEncodedClearValues }) => abiEncodedClearValues),
    ).to.eventually.eq(amount2);
  });
});
