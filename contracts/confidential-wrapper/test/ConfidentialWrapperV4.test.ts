import { expect } from 'chai';
import { ethers, fhevm } from 'hardhat';
import hre from 'hardhat';
import { allowHandle, impersonate } from './utils/accounts';
import { deployConfidentialWrapper } from './utils/confidentialWrapper';
import { getRequiredEnvVar } from '../tasks/utils/loadVariables';

const name = getRequiredEnvVar('CONFIDENTIAL_WRAPPER_NAME_0');
const symbol = getRequiredEnvVar('CONFIDENTIAL_WRAPPER_SYMBOL_0');
const uri = getRequiredEnvVar('CONFIDENTIAL_WRAPPER_CONTRACT_URI_0');
const owner = getRequiredEnvVar('CONFIDENTIAL_WRAPPER_OWNER_ADDRESS_0');

const SELECTOR_CUSDC = '0xfe575a87';

async function deployDenyList() {
  return ethers.deployContract('MockConfidentialWrapperDenyList');
}

// Fresh deploy of the flattened (V4) ConfidentialWrapper via the shared helper.
async function deployWrapper(
  token: string,
  selector = '0x00000000',
  hasSelector = false,
  denyListAddress = ethers.ZeroAddress,
) {
  return deployConfidentialWrapper(token, {
    name,
    symbol,
    contractUri: uri,
    owner,
    underlyingDenyListSelector: selector,
    hasUnderlyingDenyListSelector: hasSelector,
    confidentialWrapperDenyList: denyListAddress,
  });
}

describe('ConfidentialWrapperV4 DenyList', function () {
  // ─── setConfidentialWrapperDenyList ──────────────────────────────────────────────

  describe('setConfidentialWrapperDenyList', function () {
    beforeEach(async function () {
      const [, , outsider] = await ethers.getSigners();
      this.outsider = outsider;
      this.ownerSigner = await ethers.getSigner(owner);
      const token = await ethers.deployContract('$ERC20Mock', ['Mock Token', 'MOCK', 6]);
      this.denyList = await deployDenyList();
      this.wrapper = await deployWrapper(token.target as string);
    });

    it('sets the registry and emits ConfidentialWrapperDenyListUpdated', async function () {
      const registryAddress = await this.denyList.getAddress();
      await expect(this.wrapper.connect(this.ownerSigner).setConfidentialWrapperDenyList(registryAddress))
        .to.emit(this.wrapper, 'ConfidentialWrapperDenyListUpdated')
        .withArgs(registryAddress);
      expect(await this.wrapper.confidentialWrapperDenyList()).to.equal(registryAddress);
    });

    it('updates to a new registry address', async function () {
      const registryAddress = await this.denyList.getAddress();
      await this.wrapper.connect(this.ownerSigner).setConfidentialWrapperDenyList(registryAddress);

      const denyList2 = await deployDenyList();
      const newRegistryAddress = await denyList2.getAddress();
      await this.wrapper.connect(this.ownerSigner).setConfidentialWrapperDenyList(newRegistryAddress);
      expect(await this.wrapper.confidentialWrapperDenyList()).to.equal(newRegistryAddress);
    });

    it('revokes the registry by setting address(0) and emits ConfidentialWrapperDenyListUpdated', async function () {
      const registryAddress = await this.denyList.getAddress();
      await this.wrapper.connect(this.ownerSigner).setConfidentialWrapperDenyList(registryAddress);
      await expect(this.wrapper.connect(this.ownerSigner).setConfidentialWrapperDenyList(ethers.ZeroAddress))
        .to.emit(this.wrapper, 'ConfidentialWrapperDenyListUpdated')
        .withArgs(ethers.ZeroAddress);
      expect(await this.wrapper.confidentialWrapperDenyList()).to.equal(ethers.ZeroAddress);
    });

    it('reverts with ConfidentialWrapperDenyListAlreadySet when setting the same registry address', async function () {
      const registryAddress = await this.denyList.getAddress();
      await this.wrapper.connect(this.ownerSigner).setConfidentialWrapperDenyList(registryAddress);
      await expect(this.wrapper.connect(this.ownerSigner).setConfidentialWrapperDenyList(registryAddress))
        .to.be.revertedWithCustomError(this.wrapper, 'ConfidentialWrapperDenyListAlreadySet')
        .withArgs(registryAddress);
    });

    it('reverts with ConfidentialWrapperDenyListAlreadySet when re-setting address(0) when no registry is configured', async function () {
      await expect(this.wrapper.connect(this.ownerSigner).setConfidentialWrapperDenyList(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(this.wrapper, 'ConfidentialWrapperDenyListAlreadySet')
        .withArgs(ethers.ZeroAddress);
    });

    it('reverts for non-owner', async function () {
      const registryAddress = await this.denyList.getAddress();
      await expect(this.wrapper.connect(this.outsider).setConfidentialWrapperDenyList(registryAddress))
        .to.be.revertedWithCustomError(this.wrapper, 'OwnableUnauthorizedAccount')
        .withArgs(this.outsider.address);
    });
  });

  // ─── Registry-sourced blocking ────────────────────────────────────────────

  describe('Registry-sourced blocking', function () {
    beforeEach(async function () {
      [this.holder, this.recipient, this.operator] = await ethers.getSigners();
      this.ownerSigner = await ethers.getSigner(owner);
      this.token = await ethers.deployContract('$ERC20Mock', ['Mock Token', 'MOCK', 6]);
      this.denyList = await deployDenyList();
      this.wrapper = await deployWrapper(
        this.token.target as string,
        '0x00000000',
        false,
        await this.denyList.getAddress(),
      );
      await this.token.$_mint(this.holder.address, ethers.parseUnits('1000', 6));
      await this.token.connect(this.holder).approve(this.wrapper.target, ethers.MaxUint256);
    });

    describe('Wrap', function () {
      describe('sender denied', function () {
        beforeEach(async function () {
          await this.denyList.addToDenyList([this.holder.address]);
        });

        it('reverts via wrap', async function () {
          await expect(this.wrapper.connect(this.holder).wrap(this.holder.address, ethers.parseUnits('100', 6)))
            .to.be.revertedWithCustomError(this.wrapper, 'BlockedUser')
            .withArgs(this.holder.address);
        });

        it('reverts via ERC-1363 callback', async function () {
          await expect(this.token.connect(this.holder).transferAndCall(this.wrapper.target, ethers.parseUnits('100', 6)))
            .to.be.revertedWithCustomError(this.wrapper, 'BlockedUser')
            .withArgs(this.holder.address);
        });
      });

      describe('recipient denied', function () {
        beforeEach(async function () {
          await this.denyList.addToDenyList([this.recipient.address]);
        });

        it('reverts via wrap', async function () {
          await expect(this.wrapper.connect(this.holder).wrap(this.recipient.address, ethers.parseUnits('100', 6)))
            .to.be.revertedWithCustomError(this.wrapper, 'BlockedUser')
            .withArgs(this.recipient.address);
        });
      });
    });

    describe('Unwrap', function () {
      beforeEach(async function () {
        await this.wrapper.connect(this.holder).wrap(this.holder.address, ethers.parseUnits('100', 6));
      });

      describe('recipient denied', function () {
        beforeEach(async function () {
          await this.denyList.addToDenyList([this.recipient.address]);
        });

        it('reverts when `to` is registry-denied', async function () {
          const balance = await this.wrapper.confidentialBalanceOf(this.holder.address);
          await expect(this.wrapper.connect(this.holder).unwrap(this.holder.address, this.recipient.address, balance))
            .to.be.revertedWithCustomError(this.wrapper, 'BlockedUser')
            .withArgs(this.recipient.address);
        });

        it('reverts when `to` is registry-denied (externalEuint64 overload)', async function () {
          const encryptedInput = await fhevm
            .createEncryptedInput(this.wrapper.target, this.holder.address)
            .add64(ethers.parseUnits('10', 6))
            .encrypt();
          await expect(
            this.wrapper
              .connect(this.holder)
              [
                'unwrap(address,address,bytes32,bytes)'
              ](this.holder.address, this.recipient.address, encryptedInput.handles[0], encryptedInput.inputProof),
          )
            .to.be.revertedWithCustomError(this.wrapper, 'BlockedUser')
            .withArgs(this.recipient.address);
        });
      });

      describe('sender denied', function () {
        beforeEach(async function () {
          await this.denyList.addToDenyList([this.holder.address]);
        });

        it('reverts when `from` is registry-denied (caught in _update)', async function () {
          const balance = await this.wrapper.confidentialBalanceOf(this.holder.address);
          await expect(this.wrapper.connect(this.holder).unwrap(this.holder.address, this.holder.address, balance))
            .to.be.revertedWithCustomError(this.wrapper, 'BlockedUser')
            .withArgs(this.holder.address);
        });
      });

      describe('operator denied', function () {
        beforeEach(async function () {
          const until = BigInt(Math.floor(Date.now() / 1000) + 3600);
          await this.wrapper.connect(this.holder).setOperator(this.operator.address, until);
          const balance = (await this.wrapper.confidentialBalanceOf(this.holder.address)) as string;
          const wrapperSigner = await impersonate(hre, await this.wrapper.getAddress());
          await allowHandle(hre, wrapperSigner, this.operator, balance);
          await this.denyList.addToDenyList([this.operator.address]);
        });

        it('reverts when operator is registry-denied (euint64 overload)', async function () {
          const balance = await this.wrapper.confidentialBalanceOf(this.holder.address);
          await expect(this.wrapper.connect(this.operator).unwrap(this.holder.address, this.holder.address, balance))
            .to.be.revertedWithCustomError(this.wrapper, 'BlockedUser')
            .withArgs(this.operator.address);
        });

        it('reverts when operator is registry-denied (externalEuint64 overload)', async function () {
          const encryptedInput = await fhevm
            .createEncryptedInput(this.wrapper.target, this.operator.address)
            .add64(ethers.parseUnits('10', 6))
            .encrypt();
          await expect(
            this.wrapper
              .connect(this.operator)
              [
                'unwrap(address,address,bytes32,bytes)'
              ](this.holder.address, this.holder.address, encryptedInput.handles[0], encryptedInput.inputProof),
          )
            .to.be.revertedWithCustomError(this.wrapper, 'BlockedUser')
            .withArgs(this.operator.address);
        });
      });
    });

    describe('finalizeUnwrap', function () {
      beforeEach(async function () {
        await this.wrapper.connect(this.holder).wrap(this.holder.address, ethers.parseUnits('100', 6));
        const balance = await this.wrapper.confidentialBalanceOf(this.holder.address);
        await this.wrapper.connect(this.holder).unwrap(this.holder.address, this.holder.address, balance);
        const event = (await this.wrapper.queryFilter(this.wrapper.filters.UnwrapRequested()))[0];
        this.unwrapRequestId = event.args[1];
        await this.denyList.addToDenyList([this.holder.address]);
      });

      it('reverts when requester is registry-denied between unwrap and finalization', async function () {
        await expect(this.wrapper.connect(this.holder).finalizeUnwrap(this.unwrapRequestId, 0, '0x'))
          .to.be.revertedWithCustomError(this.wrapper, 'BlockedUser')
          .withArgs(this.holder.address);
      });
    });

    describe('finalizeUnwrap — Caller not Requester', function () {
      describe('holder-initiated unwrap', function () {
        beforeEach(async function () {
          await this.wrapper.connect(this.holder).wrap(this.holder.address, ethers.parseUnits('100', 6));
          const balance = await this.wrapper.confidentialBalanceOf(this.holder.address);
          await this.wrapper.connect(this.holder).unwrap(this.holder.address, this.recipient.address, balance);
          const event = (await this.wrapper.queryFilter(this.wrapper.filters.UnwrapRequested())).at(-1)!;
          this.unwrapRequestId = event.args[1];
        });

        it('reverts when `from` is registry-denied between unwrap and finalization', async function () {
          await this.denyList.addToDenyList([this.holder.address]);
          await expect(this.wrapper.connect(this.recipient).finalizeUnwrap(this.unwrapRequestId, 0, '0x'))
            .to.be.revertedWithCustomError(this.wrapper, 'BlockedUser')
            .withArgs(this.holder.address);
        });

        it('reverts when `to` is registry-denied between unwrap and finalization', async function () {
          await this.denyList.addToDenyList([this.recipient.address]);
          await expect(this.wrapper.connect(this.holder).finalizeUnwrap(this.unwrapRequestId, 0, '0x'))
            .to.be.revertedWithCustomError(this.wrapper, 'BlockedUser')
            .withArgs(this.recipient.address);
        });
      });

      describe('operator-initiated unwrap', function () {
        beforeEach(async function () {
          await this.wrapper.connect(this.holder).wrap(this.holder.address, ethers.parseUnits('100', 6));
          const until = BigInt(Math.floor(Date.now() / 1000) + 3600);
          await this.wrapper.connect(this.holder).setOperator(this.operator.address, until);
          const encryptedInput = await fhevm
            .createEncryptedInput(this.wrapper.target, this.operator.address)
            .add64(ethers.parseUnits('100', 6))
            .encrypt();
          await this.wrapper
            .connect(this.operator)
            [
              'unwrap(address,address,bytes32,bytes)'
            ](this.holder.address, this.recipient.address, encryptedInput.handles[0], encryptedInput.inputProof);
          const event = (await this.wrapper.queryFilter(this.wrapper.filters.UnwrapRequested())).at(-1)!;
          this.unwrapRequestId = event.args[1];
        });

        it('reverts when operator is registry-denied between unwrap and finalization', async function () {
          await this.denyList.addToDenyList([this.operator.address]);
          await expect(this.wrapper.connect(this.recipient).finalizeUnwrap(this.unwrapRequestId, 0, '0x'))
            .to.be.revertedWithCustomError(this.wrapper, 'BlockedUser')
            .withArgs(this.operator.address);
        });
      });
    });

    describe('confidentialTransfer', function () {
      beforeEach(async function () {
        await this.wrapper.connect(this.holder).wrap(this.holder.address, ethers.parseUnits('100', 6));
        this.encryptedInput = await fhevm
          .createEncryptedInput(this.wrapper.target, this.holder.address)
          .add64(ethers.parseUnits('10', 6))
          .encrypt();
      });

      it('reverts when sender is registry-denied', async function () {
        await this.denyList.addToDenyList([this.holder.address]);
        await expect(
          this.wrapper
            .connect(this.holder)
            [
              'confidentialTransfer(address,bytes32,bytes)'
            ](this.recipient.address, this.encryptedInput.handles[0], this.encryptedInput.inputProof),
        )
          .to.be.revertedWithCustomError(this.wrapper, 'BlockedUser')
          .withArgs(this.holder.address);
      });

      it('reverts when recipient is registry-denied', async function () {
        await this.denyList.addToDenyList([this.recipient.address]);
        await expect(
          this.wrapper
            .connect(this.holder)
            [
              'confidentialTransfer(address,bytes32,bytes)'
            ](this.recipient.address, this.encryptedInput.handles[0], this.encryptedInput.inputProof),
        )
          .to.be.revertedWithCustomError(this.wrapper, 'BlockedUser')
          .withArgs(this.recipient.address);
      });
    });

    describe('confidentialTransferFrom', function () {
      beforeEach(async function () {
        await this.wrapper.connect(this.holder).wrap(this.holder.address, ethers.parseUnits('100', 6));
        const until = BigInt(Math.floor(Date.now() / 1000) + 3600);
        await this.wrapper.connect(this.holder).setOperator(this.operator.address, until);
        const balance = (await this.wrapper.confidentialBalanceOf(this.holder.address)) as string;
        const wrapperSigner = await impersonate(hre, await this.wrapper.getAddress());
        await allowHandle(hre, wrapperSigner, this.operator, balance);
        this.encryptedInput = await fhevm
          .createEncryptedInput(this.wrapper.target, this.operator.address)
          .add64(ethers.parseUnits('10', 6))
          .encrypt();
      });

      it('reverts when operator is registry-denied', async function () {
        await this.denyList.addToDenyList([this.operator.address]);
        await expect(
          this.wrapper
            .connect(this.operator)
            [
              'confidentialTransferFrom(address,address,bytes32,bytes)'
            ](this.holder.address, this.recipient.address, this.encryptedInput.handles[0], this.encryptedInput.inputProof),
        )
          .to.be.revertedWithCustomError(this.wrapper, 'BlockedUser')
          .withArgs(this.operator.address);
      });

      it('reverts when sender (from) is registry-denied', async function () {
        await this.denyList.addToDenyList([this.holder.address]);
        await expect(
          this.wrapper
            .connect(this.operator)
            [
              'confidentialTransferFrom(address,address,bytes32,bytes)'
            ](this.holder.address, this.recipient.address, this.encryptedInput.handles[0], this.encryptedInput.inputProof),
        )
          .to.be.revertedWithCustomError(this.wrapper, 'BlockedUser')
          .withArgs(this.holder.address);
      });

      it('reverts when recipient is registry-denied', async function () {
        await this.denyList.addToDenyList([this.recipient.address]);
        await expect(
          this.wrapper
            .connect(this.operator)
            [
              'confidentialTransferFrom(address,address,bytes32,bytes)'
            ](this.holder.address, this.recipient.address, this.encryptedInput.handles[0], this.encryptedInput.inputProof),
        )
          .to.be.revertedWithCustomError(this.wrapper, 'BlockedUser')
          .withArgs(this.recipient.address);
      });
    });

    describe('confidentialTransferAndCall', function () {
      beforeEach(async function () {
        await this.wrapper.connect(this.holder).wrap(this.holder.address, ethers.parseUnits('100', 6));
        this.encryptedInput = await fhevm
          .createEncryptedInput(this.wrapper.target, this.holder.address)
          .add64(ethers.parseUnits('10', 6))
          .encrypt();
      });

      it('reverts when sender is registry-denied', async function () {
        await this.denyList.addToDenyList([this.holder.address]);
        await expect(
          this.wrapper
            .connect(this.holder)
            [
              'confidentialTransferAndCall(address,bytes32,bytes,bytes)'
            ](this.recipient.address, this.encryptedInput.handles[0], this.encryptedInput.inputProof, '0x'),
        )
          .to.be.revertedWithCustomError(this.wrapper, 'BlockedUser')
          .withArgs(this.holder.address);
      });

      it('reverts when recipient is registry-denied', async function () {
        await this.denyList.addToDenyList([this.recipient.address]);
        await expect(
          this.wrapper
            .connect(this.holder)
            [
              'confidentialTransferAndCall(address,bytes32,bytes,bytes)'
            ](this.recipient.address, this.encryptedInput.handles[0], this.encryptedInput.inputProof, '0x'),
        )
          .to.be.revertedWithCustomError(this.wrapper, 'BlockedUser')
          .withArgs(this.recipient.address);
      });
    });

    describe('confidentialTransferFromAndCall', function () {
      beforeEach(async function () {
        await this.wrapper.connect(this.holder).wrap(this.holder.address, ethers.parseUnits('100', 6));
        const until = BigInt(Math.floor(Date.now() / 1000) + 3600);
        await this.wrapper.connect(this.holder).setOperator(this.operator.address, until);
        const balance = (await this.wrapper.confidentialBalanceOf(this.holder.address)) as string;
        const wrapperSigner = await impersonate(hre, await this.wrapper.getAddress());
        await allowHandle(hre, wrapperSigner, this.operator, balance);
        this.encryptedInput = await fhevm
          .createEncryptedInput(this.wrapper.target, this.operator.address)
          .add64(ethers.parseUnits('10', 6))
          .encrypt();
      });

      it('reverts when operator is registry-denied', async function () {
        await this.denyList.addToDenyList([this.operator.address]);
        await expect(
          this.wrapper
            .connect(this.operator)
            [
              'confidentialTransferFromAndCall(address,address,bytes32,bytes,bytes)'
            ](this.holder.address, this.recipient.address, this.encryptedInput.handles[0], this.encryptedInput.inputProof, '0x'),
        )
          .to.be.revertedWithCustomError(this.wrapper, 'BlockedUser')
          .withArgs(this.operator.address);
      });

      it('reverts when sender (from) is registry-denied', async function () {
        await this.denyList.addToDenyList([this.holder.address]);
        await expect(
          this.wrapper
            .connect(this.operator)
            [
              'confidentialTransferFromAndCall(address,address,bytes32,bytes,bytes)'
            ](this.holder.address, this.recipient.address, this.encryptedInput.handles[0], this.encryptedInput.inputProof, '0x'),
        )
          .to.be.revertedWithCustomError(this.wrapper, 'BlockedUser')
          .withArgs(this.holder.address);
      });

      it('reverts when recipient is registry-denied', async function () {
        await this.denyList.addToDenyList([this.recipient.address]);
        await expect(
          this.wrapper
            .connect(this.operator)
            [
              'confidentialTransferFromAndCall(address,address,bytes32,bytes,bytes)'
            ](this.holder.address, this.recipient.address, this.encryptedInput.handles[0], this.encryptedInput.inputProof, '0x'),
        )
          .to.be.revertedWithCustomError(this.wrapper, 'BlockedUser')
          .withArgs(this.recipient.address);
      });
    });
  });

  // ─── Registry disabled (address(0)) ──────────────────────────────────────

  describe('Registry disabled (address(0))', function () {
    beforeEach(async function () {
      [this.holder] = await ethers.getSigners();
      this.ownerSigner = await ethers.getSigner(owner);
      const token = await ethers.deployContract('$ERC20Mock', ['Mock', 'MOCK', 6]);
      await token.$_mint(this.holder.address, ethers.parseUnits('100', 6));
      this.wrapper = await deployWrapper(token.target as string);
      await (token as any).connect(this.holder).approve(this.wrapper.target, ethers.MaxUint256);
    });

    it('allows wrap when no registry is configured', async function () {
      expect(await this.wrapper.confidentialWrapperDenyList()).to.equal(ethers.ZeroAddress);
      await expect(this.wrapper.connect(this.holder).wrap(this.holder.address, ethers.parseUnits('100', 6))).not.to.be
        .reverted;
    });

    it('stops blocking after registry is revoked via setConfidentialWrapperDenyList(address(0))', async function () {
      const denyList = await deployDenyList();
      await this.wrapper.connect(this.ownerSigner).setConfidentialWrapperDenyList(await denyList.getAddress());

      await denyList.addToDenyList([this.holder.address]);
      await expect(this.wrapper.connect(this.holder).wrap(this.holder.address, ethers.parseUnits('100', 6)))
        .to.be.revertedWithCustomError(this.wrapper, 'BlockedUser')
        .withArgs(this.holder.address);

      await this.wrapper.connect(this.ownerSigner).setConfidentialWrapperDenyList(ethers.ZeroAddress);
      await expect(this.wrapper.connect(this.holder).wrap(this.holder.address, ethers.parseUnits('100', 6))).not.to.be
        .reverted;
    });
  });

  // ─── Deny-list precedence ─────────────────────────────────────────────────

  describe('Deny-list precedence', function () {
    beforeEach(async function () {
      [this.holder] = await ethers.getSigners();
      this.ownerSigner = await ethers.getSigner(owner);
      this.token = await ethers.deployContract('ERC20MockCUSDC');
      this.denyList = await deployDenyList();
      this.wrapper = await deployWrapper(this.token.target as string, SELECTOR_CUSDC, true, await this.denyList.getAddress());
      await this.token.mint(this.holder.address, ethers.parseUnits('100', 6));
      await this.token.connect(this.holder).approve(this.wrapper.target, ethers.MaxUint256);
      await this.token.setDenyListed(this.holder.address, true);
      await this.denyList.addToDenyList([this.holder.address]);
    });

    it('local block list is checked first — reverts BlockedUser not UnderlyingDenyListedAddress when on both', async function () {
      await this.wrapper.connect(this.ownerSigner).blockUser(this.holder.address);
      await expect(this.wrapper.connect(this.holder).wrap(this.holder.address, ethers.parseUnits('100', 6)))
        .to.be.revertedWithCustomError(this.wrapper, 'BlockedUser')
        .withArgs(this.holder.address);
    });

    it('registry check is before underlying check — reverts BlockedUser (not UnderlyingDenyListedAddress) when registry denies even if underlying also denies', async function () {
      await expect(this.wrapper.connect(this.holder).wrap(this.holder.address, ethers.parseUnits('100', 6)))
        .to.be.revertedWithCustomError(this.wrapper, 'BlockedUser')
        .withArgs(this.holder.address);
    });
  });

  // ─── setUnderlyingDenyListSelector ───────────────────────────────────────

  describe('setUnderlyingDenyListSelector', function () {
    beforeEach(async function () {
      [this.holder, , this.outsider] = await ethers.getSigners();
      this.ownerSigner = await ethers.getSigner(owner);
      this.token = await ethers.deployContract('ERC20MockCUSDC');
      this.wrapper = await deployWrapper(this.token.target as string);
      await this.token.mint(this.holder.address, ethers.parseUnits('100', 6));
      await this.token.connect(this.holder).approve(this.wrapper.target, ethers.MaxUint256);
    });

    it('activates the underlying check and emits UnderlyingDenyListSelectorUpdated', async function () {
      await expect(this.wrapper.connect(this.ownerSigner).setUnderlyingDenyListSelector(SELECTOR_CUSDC, true))
        .to.emit(this.wrapper, 'UnderlyingDenyListSelectorUpdated')
        .withArgs(SELECTOR_CUSDC, true);

      const [isSet, selector] = await this.wrapper.getUnderlyingDenyListSelector();
      expect(isSet).to.be.true;
      expect(selector).to.equal(SELECTOR_CUSDC);
    });

    it('blocking is enforced after activating the underlying check', async function () {
      await this.wrapper.connect(this.ownerSigner).setUnderlyingDenyListSelector(SELECTOR_CUSDC, true);
      await this.token.setDenyListed(this.holder.address, true);
      await expect(this.wrapper.connect(this.holder).wrap(this.holder.address, ethers.parseUnits('100', 6)))
        .to.be.revertedWithCustomError(this.wrapper, 'UnderlyingDenyListedAddress')
        .withArgs(this.holder.address);
    });

    it('deactivates the underlying check by setting a zero selector with isSet false', async function () {
      await this.wrapper.connect(this.ownerSigner).setUnderlyingDenyListSelector(SELECTOR_CUSDC, true);
      await this.token.setDenyListed(this.holder.address, true);
      await expect(this.wrapper.connect(this.holder).wrap(this.holder.address, ethers.parseUnits('100', 6))).to.be
        .reverted;

      await this.wrapper.connect(this.ownerSigner).setUnderlyingDenyListSelector('0x00000000', false);
      await expect(this.wrapper.connect(this.holder).wrap(this.holder.address, ethers.parseUnits('100', 6))).not.to.be
        .reverted;
    });

    it('reverts with NonZeroSelectorRequiresIsSet when a non-zero selector is paired with isSet false', async function () {
      await expect(this.wrapper.connect(this.ownerSigner).setUnderlyingDenyListSelector(SELECTOR_CUSDC, false))
        .to.be.revertedWithCustomError(this.wrapper, 'NonZeroSelectorRequiresIsSet')
        .withArgs(SELECTOR_CUSDC);
    });

    it('reverts with UnderlyingDenyListSelectorAlreadySet when the same (selector, isSet) pair is re-sent', async function () {
      await this.wrapper.connect(this.ownerSigner).setUnderlyingDenyListSelector(SELECTOR_CUSDC, true);
      await expect(this.wrapper.connect(this.ownerSigner).setUnderlyingDenyListSelector(SELECTOR_CUSDC, true))
        .to.be.revertedWithCustomError(this.wrapper, 'UnderlyingDenyListSelectorAlreadySet')
        .withArgs(SELECTOR_CUSDC, true);
    });

    it('changes the selector to a different one', async function () {
      const SELECTOR_CUSDT = '0x59bf1abe';
      await this.wrapper.connect(this.ownerSigner).setUnderlyingDenyListSelector(SELECTOR_CUSDT, true);
      const [isSet, selector] = await this.wrapper.getUnderlyingDenyListSelector();
      expect(isSet).to.be.true;
      expect(selector).to.equal(SELECTOR_CUSDT);
    });

    it('reverts for non-owner', async function () {
      await expect(this.wrapper.connect(this.outsider).setUnderlyingDenyListSelector(SELECTOR_CUSDC, true))
        .to.be.revertedWithCustomError(this.wrapper, 'OwnableUnauthorizedAccount')
        .withArgs(this.outsider.address);
    });
  });

  // ─── Fresh deploy via the extended initialize ─────────────────────────────

  describe('initialize (fresh V4 deploy via extended initialize)', function () {
    beforeEach(async function () {
      this.ownerSigner = await ethers.getSigner(owner);
      this.token = await ethers.deployContract('$ERC20Mock', ['Mock', 'MOCK', 6]);
    });

    it('configures base, V3, and V4 state in a single initialize call', async function () {
      const denyList = await deployDenyList();
      const registryAddress = await denyList.getAddress();

      const wrapper = await deployWrapper(this.token.target as string, SELECTOR_CUSDC, true, registryAddress);

      // Base state
      expect(await wrapper.name()).to.equal(name);
      expect(await wrapper.symbol()).to.equal(symbol);
      expect(await wrapper.contractURI()).to.equal(uri);
      expect(await wrapper.owner()).to.equal(owner);
      expect(await wrapper.underlying()).to.equal(await this.token.getAddress());

      // Underlying deny-list selector state
      const [isSet, selector] = await wrapper.getUnderlyingDenyListSelector();
      expect(isSet).to.be.true;
      expect(selector).to.equal(SELECTOR_CUSDC);

      // Registry state
      expect(await wrapper.confidentialWrapperDenyList()).to.equal(registryAddress);
    });

    it('reverts when reinitializeV4 is called after a fresh deploy', async function () {
      const wrapper = await deployWrapper(this.token.target as string);
      await expect(wrapper.connect(this.ownerSigner).reinitializeV4(ethers.ZeroAddress)).to.be.revertedWithCustomError(
        wrapper,
        'InvalidInitialization',
      );
    });

    it('reverts with NonZeroSelectorRequiresIsSet when initialized with a non-zero selector and hasSelector false', async function () {
      await expect(deployWrapper(this.token.target as string, SELECTOR_CUSDC, false))
        .to.be.revertedWithCustomError(
          await ethers.getContractFactory('ConfidentialWrapper'),
          'NonZeroSelectorRequiresIsSet',
        )
        .withArgs(SELECTOR_CUSDC);
    });
  });

  // ─── isBlocked getter ─────────────────────────────────────────────────────

  describe('isBlocked', function () {
    beforeEach(async function () {
      [this.holder] = await ethers.getSigners();
      this.ownerSigner = await ethers.getSigner(owner);
      this.token = await ethers.deployContract('$ERC20Mock', ['Mock', 'MOCK', 6]);
    });

    it('returns false when address is neither locally blocked nor registry-denied', async function () {
      const denyList = await deployDenyList();
      const wrapper = await deployWrapper(this.token.target as string, '0x00000000', false, await denyList.getAddress());
      expect(await wrapper.isBlocked(this.holder.address)).to.be.false;
    });

    it('returns true when address is only locally blocked', async function () {
      const wrapper = await deployWrapper(this.token.target as string);
      await wrapper.connect(this.ownerSigner).blockUser(this.holder.address);
      expect(await wrapper.isBlocked(this.holder.address)).to.be.true;
    });

    it('returns true when address is only registry-denied', async function () {
      const denyList = await deployDenyList();
      const wrapper = await deployWrapper(this.token.target as string, '0x00000000', false, await denyList.getAddress());
      await denyList.addToDenyList([this.holder.address]);
      expect(await wrapper.isBlocked(this.holder.address)).to.be.true;
    });

    it('returns false when address is registry-denied but no registry is configured', async function () {
      const denyList = await deployDenyList();
      const wrapper = await deployWrapper(this.token.target as string);
      await denyList.addToDenyList([this.holder.address]);
      expect(await wrapper.isBlocked(this.holder.address)).to.be.false;
    });
  });
});
