import { ConfidentialWrapperV3, SanctionsOracleMock } from '../types';
import { FhevmType } from '@fhevm/hardhat-plugin';
import { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers, fhevm, upgrades } from 'hardhat';
import { getRequiredEnvVar } from '../tasks/utils/loadVariables';

const name = getRequiredEnvVar('CONFIDENTIAL_WRAPPER_NAME_0');
const symbol = getRequiredEnvVar('CONFIDENTIAL_WRAPPER_SYMBOL_0');
const uri = getRequiredEnvVar('CONFIDENTIAL_WRAPPER_CONTRACT_URI_0');
const owner = getRequiredEnvVar('CONFIDENTIAL_WRAPPER_OWNER_ADDRESS_0');

const erc20contractName = '$ERC20Mock';
const erc20mockName = 'ERC20Mock';
const erc20mockSymbol = 'MOCK';
const erc20mockDecimals = 18;

describe('ConfidentialWrapperV3 Compliance', function () {
  async function deployV3(token: string) {
    const factory = await ethers.getContractFactory('ConfidentialWrapperV3');
    const proxy = await upgrades.deployProxy(factory, [name, symbol, uri, token, owner], {
      initializer: 'initialize',
      kind: 'uups',
      unsafeAllow: ['missing-initializer-call'],
    });
    await proxy.waitForDeployment();
    return proxy as unknown as ConfidentialWrapperV3;
  }

  beforeEach(async function () {
    const [holder, , operator, anyone] = await ethers.getSigners();
    const ownerSigner = await ethers.getSigner(owner);

    const token = await ethers.deployContract(erc20contractName, [erc20mockName, erc20mockSymbol, erc20mockDecimals]);
    const oracle = (await ethers.deployContract('SanctionsOracleMock')) as unknown as SanctionsOracleMock;
    const wrapper = await deployV3(token.target as string);

    this.holder = holder;
    this.recipient = ownerSigner;
    this.operator = operator;
    this.anyone = anyone;
    this.token = token;
    this.oracle = oracle;
    this.wrapper = wrapper;
    this.ownerSigner = ownerSigner;

    await this.token.$_mint(holder.address, ethers.parseUnits('1000', 18));
    await this.token.connect(holder).approve(wrapper.target, ethers.MaxUint256);
    await wrapper.connect(ownerSigner).setComplianceOracle(oracle.target);
  });

  describe('Oracle Management', function () {
    it('complianceOracle() returns the configured address', async function () {
      await expect(this.wrapper.complianceOracle()).to.eventually.equal(this.oracle.target);
    });

    it('emits ComplianceOracleUpdated when oracle is set', async function () {
      const newOracle = await ethers.deployContract('SanctionsOracleMock');
      await expect(this.wrapper.connect(this.ownerSigner).setComplianceOracle(newOracle.target))
        .to.emit(this.wrapper, 'ComplianceOracleUpdated')
        .withArgs(newOracle.target, this.oracle.target);
    });

    it('setting oracle to address(0) disables checks', async function () {
      await expect(this.wrapper.connect(this.ownerSigner).setComplianceOracle(ethers.ZeroAddress))
        .to.emit(this.wrapper, 'ComplianceOracleUpdated')
        .withArgs(ethers.ZeroAddress, this.oracle.target);
      await expect(this.wrapper.complianceOracle()).to.eventually.equal(ethers.ZeroAddress);
    });

    it('setComplianceOracle reverts for non-owner', async function () {
      await expect(
        this.wrapper.connect(this.anyone).setComplianceOracle(this.oracle.target),
      ).to.be.revertedWithCustomError(this.wrapper, 'OwnableUnauthorizedAccount').withArgs(this.anyone.address);
    });
  });

  describe('Wrap', function () {
    it('via transferFrom succeeds for non-sanctioned user', async function () {
      await this.wrapper.connect(this.holder).wrap(this.holder.address, ethers.parseUnits('100', 18));

      const balance = await this.wrapper.confidentialBalanceOf(this.holder.address);
      await expect(
        fhevm.userDecryptEuint(FhevmType.euint64, balance, this.wrapper.target, this.holder),
      ).to.eventually.equal(ethers.parseUnits('100', 6));
    });

    it('via callback succeeds for non-sanctioned user', async function () {
      await this.token.connect(this.holder).transferAndCall(this.wrapper.target, ethers.parseUnits('100', 18));

      const balance = await this.wrapper.confidentialBalanceOf(this.holder.address);
      await expect(
        fhevm.userDecryptEuint(FhevmType.euint64, balance, this.wrapper.target, this.holder),
      ).to.eventually.equal(ethers.parseUnits('100', 6));
    });

    it('reverts via transferFrom when sender is sanctioned', async function () {
      await this.oracle.setSanctioned(this.holder.address, true);
      await expect(
        this.wrapper.connect(this.holder).wrap(this.holder.address, ethers.parseUnits('100', 18)),
      ).to.be.revertedWithCustomError(this.wrapper, 'SanctionedAddress').withArgs(this.holder.address);
    });

    it('reverts via transferFrom when to is sanctioned', async function () {
      await this.oracle.setSanctioned(this.recipient.address, true);
      await expect(
        this.wrapper.connect(this.holder).wrap(this.recipient.address, ethers.parseUnits('100', 18)),
      ).to.be.revertedWithCustomError(this.wrapper, 'SanctionedAddress').withArgs(this.recipient.address);
    });

    it('reverts via callback when sender is sanctioned', async function () {
      await this.oracle.setSanctioned(this.holder.address, true);
      await expect(
        this.token.connect(this.holder).transferAndCall(this.wrapper.target, ethers.parseUnits('100', 18)),
      ).to.be.revertedWithCustomError(this.wrapper, 'SanctionedAddress').withArgs(this.holder.address);
    });

    it('reverts via callback when to is sanctioned', async function () {
      await this.oracle.setSanctioned(this.recipient.address, true);
      await expect(
        this.token
          .connect(this.holder)
          ['transferAndCall(address,uint256,bytes)'](
            this.wrapper.target,
            ethers.parseUnits('100', 18),
            ethers.getBytes(this.recipient.address),
          ),
      ).to.be.revertedWithCustomError(this.wrapper, 'SanctionedAddress').withArgs(this.recipient.address);
    });
  });

  describe('Transfer', function () {
    beforeEach(async function () {
      await this.token.connect(this.holder).transferAndCall(this.wrapper.target, ethers.parseUnits('100', 18));
    });

    it('confidentialTransfer succeeds between non-sanctioned users', async function () {
      const encryptedInput = await fhevm
        .createEncryptedInput(this.wrapper.target, this.holder.address)
        .add64(ethers.parseUnits('10', 6))
        .encrypt();

      await expect(
        this.wrapper
          .connect(this.holder)
          ['confidentialTransfer(address,bytes32,bytes)'](
            this.recipient.address,
            encryptedInput.handles[0],
            encryptedInput.inputProof,
          ),
      ).to.emit(this.wrapper, 'ConfidentialTransfer');
    });

    it('reverts when from is sanctioned', async function () {
      await this.oracle.setSanctioned(this.holder.address, true);
      const encryptedInput = await fhevm
        .createEncryptedInput(this.wrapper.target, this.holder.address)
        .add64(ethers.parseUnits('10', 6))
        .encrypt();

      await expect(
        this.wrapper
          .connect(this.holder)
          ['confidentialTransfer(address,bytes32,bytes)'](
            this.recipient.address,
            encryptedInput.handles[0],
            encryptedInput.inputProof,
          ),
      ).to.be.revertedWithCustomError(this.wrapper, 'SanctionedAddress').withArgs(this.holder.address);
    });

    it('reverts when to is sanctioned', async function () {
      await this.oracle.setSanctioned(this.recipient.address, true);
      const encryptedInput = await fhevm
        .createEncryptedInput(this.wrapper.target, this.holder.address)
        .add64(ethers.parseUnits('10', 6))
        .encrypt();

      await expect(
        this.wrapper
          .connect(this.holder)
          ['confidentialTransfer(address,bytes32,bytes)'](
            this.recipient.address,
            encryptedInput.handles[0],
            encryptedInput.inputProof,
          ),
      ).to.be.revertedWithCustomError(this.wrapper, 'SanctionedAddress').withArgs(this.recipient.address);
    });

    it('reverts when sanctioned operator calls on behalf of unsanctioned parties', async function () {
      const until = BigInt(Math.floor(Date.now() / 1000) + 3600);
      await this.wrapper.connect(this.holder).setOperator(this.operator.address, until);
      await this.oracle.setSanctioned(this.operator.address, true);

      const encryptedInput = await fhevm
        .createEncryptedInput(this.wrapper.target, this.operator.address)
        .add64(ethers.parseUnits('10', 6))
        .encrypt();

      await expect(
        this.wrapper
          .connect(this.operator)
          ['confidentialTransferFrom(address,address,bytes32,bytes)'](
            this.holder.address,
            this.recipient.address,
            encryptedInput.handles[0],
            encryptedInput.inputProof,
          ),
      ).to.be.revertedWithCustomError(this.wrapper, 'SanctionedAddress').withArgs(this.operator.address);
    });

    it('reverts when unsanctioned operator calls on behalf of sanctioned from', async function () {
      const until = BigInt(Math.floor(Date.now() / 1000) + 3600);
      await this.wrapper.connect(this.holder).setOperator(this.operator.address, until);
      await this.oracle.setSanctioned(this.holder.address, true);

      const encryptedInput = await fhevm
        .createEncryptedInput(this.wrapper.target, this.operator.address)
        .add64(ethers.parseUnits('10', 6))
        .encrypt();

      await expect(
        this.wrapper
          .connect(this.operator)
          ['confidentialTransferFrom(address,address,bytes32,bytes)'](
            this.holder.address,
            this.recipient.address,
            encryptedInput.handles[0],
            encryptedInput.inputProof,
          ),
      ).to.be.revertedWithCustomError(this.wrapper, 'SanctionedAddress').withArgs(this.holder.address);
    });
  });

  describe('Unwrap', function () {
    beforeEach(async function () {
      await this.token.connect(this.holder).transferAndCall(this.wrapper.target, ethers.parseUnits('100', 18));
    });

    it('succeeds for non-sanctioned user', async function () {
      const encryptedInput = await fhevm
        .createEncryptedInput(this.wrapper.target, this.holder.address)
        .add64(ethers.parseUnits('10', 6))
        .encrypt();

      await expect(
        this.wrapper
          .connect(this.holder)
          ['unwrap(address,address,bytes32,bytes)'](
            this.holder.address,
            this.holder.address,
            encryptedInput.handles[0],
            encryptedInput.inputProof,
          ),
      ).to.emit(this.wrapper, 'UnwrapRequested');
    });

    it('reverts when from is sanctioned', async function () {
      await this.oracle.setSanctioned(this.holder.address, true);
      const encryptedInput = await fhevm
        .createEncryptedInput(this.wrapper.target, this.holder.address)
        .add64(ethers.parseUnits('10', 6))
        .encrypt();

      await expect(
        this.wrapper
          .connect(this.holder)
          ['unwrap(address,address,bytes32,bytes)'](
            this.holder.address,
            this.holder.address,
            encryptedInput.handles[0],
            encryptedInput.inputProof,
          ),
      ).to.be.revertedWithCustomError(this.wrapper, 'SanctionedAddress').withArgs(this.holder.address);
    });

    it('reverts when to is sanctioned', async function () {
      await this.oracle.setSanctioned(this.recipient.address, true);
      const encryptedInput = await fhevm
        .createEncryptedInput(this.wrapper.target, this.holder.address)
        .add64(ethers.parseUnits('10', 6))
        .encrypt();

      await expect(
        this.wrapper
          .connect(this.holder)
          ['unwrap(address,address,bytes32,bytes)'](
            this.holder.address,
            this.recipient.address,
            encryptedInput.handles[0],
            encryptedInput.inputProof,
          ),
      ).to.be.revertedWithCustomError(this.wrapper, 'SanctionedAddress').withArgs(this.recipient.address);
    });
  });

  describe('Oracle Bypass', function () {
    it('allows sanctioned user to wrap when oracle is disabled', async function () {
      await this.wrapper.connect(this.ownerSigner).setComplianceOracle(ethers.ZeroAddress);
      await this.oracle.setSanctioned(this.holder.address, true);

      await this.wrapper.connect(this.holder).wrap(this.holder.address, ethers.parseUnits('100', 18));

      const balance = await this.wrapper.confidentialBalanceOf(this.holder.address);
      await expect(
        fhevm.userDecryptEuint(FhevmType.euint64, balance, this.wrapper.target, this.holder),
      ).to.eventually.equal(ethers.parseUnits('100', 6));
    });
  });
});

export async function publicDecryptAndFinalizeUnwrap(wrapper: ConfidentialWrapperV3, caller: HardhatEthersSigner) {
  const [to, unwrapRequestId, amount] = (await wrapper.queryFilter(wrapper.filters.UnwrapRequested()))[0].args;
  const { abiEncodedClearValues, decryptionProof } = await fhevm.publicDecrypt([amount]);
  await expect(wrapper.connect(caller).finalizeUnwrap(unwrapRequestId, abiEncodedClearValues, decryptionProof))
    .to.emit(wrapper, 'UnwrapFinalized')
    .withArgs(to, unwrapRequestId, amount, abiEncodedClearValues);
}
