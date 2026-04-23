import { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers, upgrades } from 'hardhat';

import type { BatcherConfidentialUpgradeableHarness } from '../types/contracts/mocks/BatcherConfidentialUpgradeableHarness';
import type { BatcherConfidentialUpgradeableHarnessV2 } from '../types/contracts/mocks/BatcherConfidentialUpgradeableHarnessV2';
import type { ERC20Mock } from '../types/contracts/mocks/ERC20Mock';
import type { ERC7984ERC20WrapperMock } from '../types/contracts/mocks/ERC7984ERC20WrapperMock';

describe('BatcherConfidentialUpgradeable', function () {
  let owner: HardhatEthersSigner;
  let other: HardhatEthersSigner;
  let underlyingFrom: ERC20Mock;
  let underlyingTo: ERC20Mock;
  let fromToken: ERC7984ERC20WrapperMock;
  let toToken: ERC7984ERC20WrapperMock;
  let batcher: BatcherConfidentialUpgradeableHarness;

  async function deployBatcher(from: string, to: string): Promise<BatcherConfidentialUpgradeableHarness> {
    const harnessFactory = await ethers.getContractFactory('BatcherConfidentialUpgradeableHarness');
    const proxy = await upgrades.deployProxy(harnessFactory, [owner.address, from, to], {
      initializer: 'initialize',
      kind: 'uups',
    });
    await proxy.waitForDeployment();
    return harnessFactory.attach(await proxy.getAddress()) as unknown as BatcherConfidentialUpgradeableHarness;
  }

  beforeEach(async function () {
    [owner, other] = await ethers.getSigners();

    underlyingFrom = (await ethers.deployContract('ERC20Mock', ['From', 'FROM', 6])) as unknown as ERC20Mock;
    underlyingTo = (await ethers.deployContract('ERC20Mock', ['To', 'TO', 6])) as unknown as ERC20Mock;

    fromToken = (await ethers.deployContract('ERC7984ERC20WrapperMock', [
      underlyingFrom.target,
      'Confidential From',
      'cFROM',
      'https://example.com/metadata/from',
    ])) as unknown as ERC7984ERC20WrapperMock;
    toToken = (await ethers.deployContract('ERC7984ERC20WrapperMock', [
      underlyingTo.target,
      'Confidential To',
      'cTO',
      'https://example.com/metadata/to',
    ])) as unknown as ERC7984ERC20WrapperMock;

    batcher = await deployBatcher(fromToken.target as string, toToken.target as string);
  });

  describe('Deployment', function () {
    it('deploys behind a UUPS proxy with fromToken and toToken set', async function () {
      expect(await batcher.fromToken()).to.equal(fromToken.target);
      expect(await batcher.toToken()).to.equal(toToken.target);
    });

    it('reverts initialization when fromToken is not an IERC7984ERC20Wrapper', async function () {
      const harnessFactory = await ethers.getContractFactory('BatcherConfidentialUpgradeableHarness');
      await expect(
        deployBatcher(underlyingFrom.target as string, toToken.target as string),
      ).to.be.revertedWithCustomError(harnessFactory, 'InvalidWrapperToken');
    });

    it('reverts initialization when toToken is not an IERC7984ERC20Wrapper', async function () {
      const harnessFactory = await ethers.getContractFactory('BatcherConfidentialUpgradeableHarness');
      await expect(
        deployBatcher(fromToken.target as string, underlyingTo.target as string),
      ).to.be.revertedWithCustomError(harnessFactory, 'InvalidWrapperToken');
    });
  });

  describe('Initialize', function () {
    it('sets currentBatchId to 1', async function () {
      expect(await batcher.currentBatchId()).to.equal(1);
    });

    it('sets max approval on both underlying tokens', async function () {
      expect(await underlyingFrom.allowance(batcher.target, fromToken.target)).to.equal(ethers.MaxUint256);
      expect(await underlyingTo.allowance(batcher.target, toToken.target)).to.equal(ethers.MaxUint256);
    });

    it('sets owner to the provided address', async function () {
      expect(await batcher.owner()).to.equal(owner.address);
    });

    it('cannot be called twice on the proxy', async function () {
      await expect(batcher.initialize(owner.address, fromToken.target, toToken.target)).to.be.revertedWithCustomError(
        batcher,
        'InvalidInitialization',
      );
    });

    it('cannot be called on the implementation', async function () {
      const implAddress = await upgrades.erc1967.getImplementationAddress(await batcher.getAddress());
      const harnessFactory = await ethers.getContractFactory('BatcherConfidentialUpgradeableHarness');
      const impl = harnessFactory.attach(implAddress) as unknown as BatcherConfidentialUpgradeableHarness;
      await expect(impl.initialize(owner.address, fromToken.target, toToken.target)).to.be.revertedWithCustomError(
        impl,
        'InvalidInitialization',
      );
    });
  });

  describe('Upgrade', function () {
    let v2Impl: BatcherConfidentialUpgradeableHarnessV2;

    beforeEach(async function () {
      const v2Factory = await ethers.getContractFactory('BatcherConfidentialUpgradeableHarnessV2');
      v2Impl = (await v2Factory.deploy()) as unknown as BatcherConfidentialUpgradeableHarnessV2;
    });

    it('upgrades to V2 and switches routeDescription to the V2 override', async function () {
      expect(await batcher.routeDescription()).to.equal('harness');

      await batcher.connect(owner).upgradeToAndCall(v2Impl.target, '0x');

      expect(await batcher.routeDescription()).to.equal('harnessV2');
    });

    it('preserves initializer state across upgrade', async function () {
      expect(await batcher.currentBatchId()).to.equal(1);
      const approvalBefore = await underlyingFrom.allowance(batcher.target, fromToken.target);

      await batcher.connect(owner).upgradeToAndCall(v2Impl.target, '0x');

      expect(await batcher.currentBatchId()).to.equal(1);
      expect(await batcher.owner()).to.equal(owner.address);
      expect(await underlyingFrom.allowance(batcher.target, fromToken.target)).to.equal(approvalBefore);
    });

    it('reverts when a non-owner attempts to upgrade', async function () {
      await expect(batcher.connect(other).upgradeToAndCall(v2Impl.target, '0x')).to.be.revertedWithCustomError(
        batcher,
        'OwnableUnauthorizedAccount',
      );
    });
  });
});
