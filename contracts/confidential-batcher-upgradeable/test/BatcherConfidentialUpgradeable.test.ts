import { expect } from 'chai';
import { ethers } from 'hardhat';

import type { BatcherConfidentialUpgradeableHarness } from '../types/contracts/mocks/BatcherConfidentialUpgradeableHarness';
import type { ERC20Mock } from '../types/contracts/mocks/ERC20Mock';
import type { ERC7984ERC20WrapperMock } from '../types/contracts/mocks/ERC7984ERC20WrapperMock';

describe('BatcherConfidentialUpgradeable', function () {
  let underlyingFrom: ERC20Mock;
  let underlyingTo: ERC20Mock;
  let fromToken: ERC7984ERC20WrapperMock;
  let toToken: ERC7984ERC20WrapperMock;
  let impl: BatcherConfidentialUpgradeableHarness;
  let batcher: BatcherConfidentialUpgradeableHarness;

  beforeEach(async function () {
    underlyingFrom = (await ethers.deployContract('ERC20Mock', [
      'From',
      'FROM',
      6,
    ])) as unknown as ERC20Mock;
    underlyingTo = (await ethers.deployContract('ERC20Mock', [
      'To',
      'TO',
      6,
    ])) as unknown as ERC20Mock;

    fromToken = (await ethers.deployContract('ERC7984ERC20WrapperMock', [
      underlyingFrom.target,
      'Confidential From',
      'cFROM',
    ])) as unknown as ERC7984ERC20WrapperMock;
    toToken = (await ethers.deployContract('ERC7984ERC20WrapperMock', [
      underlyingTo.target,
      'Confidential To',
      'cTO',
    ])) as unknown as ERC7984ERC20WrapperMock;

    const harnessFactory = await ethers.getContractFactory(
      'BatcherConfidentialUpgradeableHarness',
    );
    impl = (await harnessFactory.deploy(
      fromToken.target,
      toToken.target,
    )) as unknown as BatcherConfidentialUpgradeableHarness;

    const initData = impl.interface.encodeFunctionData('initialize', []);
    const proxy = await ethers.deployContract('ERC1967Proxy', [
      impl.target,
      initData,
    ]);
    batcher = harnessFactory.attach(
      proxy.target,
    ) as unknown as BatcherConfidentialUpgradeableHarness;
  });

  describe('Deployment', function () {
    it('deploys behind an ERC1967 proxy with fromToken and toToken set', async function () {
      expect(await batcher.fromToken()).to.equal(fromToken.target);
      expect(await batcher.toToken()).to.equal(toToken.target);
    });

    it('reverts construction when fromToken is not an IERC7984ERC20Wrapper', async function () {
      const harnessFactory = await ethers.getContractFactory(
        'BatcherConfidentialUpgradeableHarness',
      );
      await expect(
        harnessFactory.deploy(underlyingFrom.target, toToken.target),
      ).to.be.revertedWithCustomError(harnessFactory, 'InvalidWrapperToken');
    });

    it('reverts construction when toToken is not an IERC7984ERC20Wrapper', async function () {
      const harnessFactory = await ethers.getContractFactory(
        'BatcherConfidentialUpgradeableHarness',
      );
      await expect(
        harnessFactory.deploy(fromToken.target, underlyingTo.target),
      ).to.be.revertedWithCustomError(harnessFactory, 'InvalidWrapperToken');
    });
  });

  describe('Initialize', function () {
    it('sets currentBatchId to 1', async function () {
      expect(await batcher.currentBatchId()).to.equal(1);
    });

    it('sets max approval on both underlying tokens', async function () {
      expect(
        await underlyingFrom.allowance(batcher.target, fromToken.target),
      ).to.equal(ethers.MaxUint256);
      expect(
        await underlyingTo.allowance(batcher.target, toToken.target),
      ).to.equal(ethers.MaxUint256);
    });

    it('cannot be called twice on the proxy', async function () {
      await expect(batcher.initialize()).to.be.revertedWithCustomError(
        batcher,
        'InvalidInitialization',
      );
    });

    it('cannot be called on the implementation', async function () {
      await expect(impl.initialize()).to.be.revertedWithCustomError(
        impl,
        'InvalidInitialization',
      );
    });
  });
});
