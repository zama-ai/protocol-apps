import { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers, fhevm } from 'hardhat';
import { DEFAULT_WRAPPER_OWNER, deployConfidentialWrapper } from './utils/confidentialWrapper';

const owner = DEFAULT_WRAPPER_OWNER;

const WRAP_AMOUNT = ethers.parseUnits('100', 6);

describe('ConfidentialWrapper Pausable', function () {
  let wrapper: any;
  let token: any;
  let ownerSigner: HardhatEthersSigner;
  let holder: HardhatEthersSigner;
  let recipient: HardhatEthersSigner;
  let operator: HardhatEthersSigner;
  let pauser: HardhatEthersSigner;
  let outsider: HardhatEthersSigner;

  beforeEach(async function () {
    // skip signers[1]: it is DEFAULT_WRAPPER_OWNER, kept distinct from the roles below
    [holder, , recipient, operator, pauser, outsider] = await ethers.getSigners();
    ownerSigner = await ethers.getSigner(owner);
    token = await ethers.deployContract('$ERC20Mock', ['Mock Token', 'MOCK', 6]);
    wrapper = await deployConfidentialWrapper(token.target as string);
    await token.$_mint(holder.address, ethers.parseUnits('1000', 6));
    await token.connect(holder).approve(wrapper.target, ethers.MaxUint256);
  });

  describe('setPauser', function () {
    it('leaves the pauser unset after initialize', async function () {
      expect(await wrapper.pauser()).to.equal(ethers.ZeroAddress);
      expect(await wrapper.paused()).to.be.false;
    });

    it('sets the pauser and emits PauserUpdated', async function () {
      await expect(wrapper.connect(ownerSigner).setPauser(pauser.address))
        .to.emit(wrapper, 'PauserUpdated')
        .withArgs(pauser.address);
      expect(await wrapper.pauser()).to.equal(pauser.address);
    });

    it('reverts for non-owner', async function () {
      await expect(wrapper.connect(outsider).setPauser(pauser.address))
        .to.be.revertedWithCustomError(wrapper, 'OwnableUnauthorizedAccount')
        .withArgs(outsider.address);
    });

    it('replaces the previous pauser, revoking the old one', async function () {
      await wrapper.connect(ownerSigner).setPauser(pauser.address);
      await wrapper.connect(ownerSigner).setPauser(outsider.address);
      expect(await wrapper.pauser()).to.equal(outsider.address);
      await expect(wrapper.connect(pauser).pause())
        .to.be.revertedWithCustomError(wrapper, 'SenderNotPauser')
        .withArgs(pauser.address);
    });

    it('disables pausing when set to the zero address', async function () {
      await wrapper.connect(ownerSigner).setPauser(pauser.address);
      await expect(wrapper.connect(ownerSigner).setPauser(ethers.ZeroAddress))
        .to.emit(wrapper, 'PauserUpdated')
        .withArgs(ethers.ZeroAddress);
      expect(await wrapper.pauser()).to.equal(ethers.ZeroAddress);
      await expect(wrapper.connect(pauser).pause())
        .to.be.revertedWithCustomError(wrapper, 'SenderNotPauser')
        .withArgs(pauser.address);
    });

    it('is callable while paused, and clearing the pauser still leaves the owner able to unpause', async function () {
      await wrapper.connect(ownerSigner).setPauser(pauser.address);
      await wrapper.connect(pauser).pause();

      // rotating and then clearing the pauser mid-incident must not strand the pause
      await wrapper.connect(ownerSigner).setPauser(outsider.address);
      expect(await wrapper.pauser()).to.equal(outsider.address);
      await wrapper.connect(ownerSigner).setPauser(ethers.ZeroAddress);
      expect(await wrapper.paused()).to.be.true;

      await expect(wrapper.connect(ownerSigner).unpause()).to.emit(wrapper, 'Unpaused').withArgs(ownerSigner.address);
      expect(await wrapper.paused()).to.be.false;
    });
  });

  describe('pause', function () {
    beforeEach(async function () {
      await wrapper.connect(ownerSigner).setPauser(pauser.address);
    });

    it('pauses and emits Paused', async function () {
      await expect(wrapper.connect(pauser).pause()).to.emit(wrapper, 'Paused').withArgs(pauser.address);
      expect(await wrapper.paused()).to.be.true;
    });

    it('reverts for a non-pauser', async function () {
      await expect(wrapper.connect(outsider).pause())
        .to.be.revertedWithCustomError(wrapper, 'SenderNotPauser')
        .withArgs(outsider.address);
    });

    it('reverts for the owner when the owner is not the pauser', async function () {
      await expect(wrapper.connect(ownerSigner).pause())
        .to.be.revertedWithCustomError(wrapper, 'SenderNotPauser')
        .withArgs(ownerSigner.address);
    });

    it('reverts when already paused', async function () {
      await wrapper.connect(pauser).pause();
      await expect(wrapper.connect(pauser).pause()).to.be.revertedWithCustomError(wrapper, 'EnforcedPause');
    });
  });

  describe('unpause', function () {
    beforeEach(async function () {
      await wrapper.connect(ownerSigner).setPauser(pauser.address);
      await wrapper.connect(pauser).pause();
    });

    it('unpauses and emits Unpaused', async function () {
      await expect(wrapper.connect(ownerSigner).unpause()).to.emit(wrapper, 'Unpaused').withArgs(ownerSigner.address);
      expect(await wrapper.paused()).to.be.false;
    });

    it('reverts for the pauser', async function () {
      await expect(wrapper.connect(pauser).unpause())
        .to.be.revertedWithCustomError(wrapper, 'OwnableUnauthorizedAccount')
        .withArgs(pauser.address);
    });

    it('reverts when not paused', async function () {
      await wrapper.connect(ownerSigner).unpause();
      await expect(wrapper.connect(ownerSigner).unpause()).to.be.revertedWithCustomError(wrapper, 'ExpectedPause');
    });
  });

  describe('gated entry points', function () {
    beforeEach(async function () {
      await wrapper.connect(holder).wrap(holder.address, WRAP_AMOUNT);
      await wrapper.connect(ownerSigner).setPauser(pauser.address);
      await wrapper.connect(pauser).pause();
    });

    it('rejects wrap, leaving the underlying where it was', async function () {
      const balanceBefore = await token.balanceOf(holder.address);
      await expect(wrapper.connect(holder).wrap(holder.address, WRAP_AMOUNT)).to.be.revertedWithCustomError(
        wrapper,
        'EnforcedPause',
      );
      // wrap reaches the gate through _mint, so the transfer it already made is unwound
      expect(await token.balanceOf(holder.address)).to.equal(balanceBefore);
    });

    it('rejects the ERC-1363 callback path', async function () {
      await expect(
        token.connect(holder)['transferAndCall(address,uint256)'](wrapper.target, WRAP_AMOUNT),
      ).to.be.revertedWithCustomError(wrapper, 'EnforcedPause');
    });

    it('rejects unwrap (euint64 overload)', async function () {
      const balance = await wrapper.confidentialBalanceOf(holder.address);
      await expect(
        wrapper.connect(holder).unwrap(holder.address, holder.address, balance),
      ).to.be.revertedWithCustomError(wrapper, 'EnforcedPause');
    });

    it('rejects unwrap (externalEuint64 overload)', async function () {
      const encryptedInput = await fhevm
        .createEncryptedInput(wrapper.target, holder.address)
        .add64(ethers.parseUnits('10', 6))
        .encrypt();
      await expect(
        wrapper
          .connect(holder)
          [
            'unwrap(address,address,bytes32,bytes)'
          ](holder.address, holder.address, encryptedInput.handles[0], encryptedInput.inputProof),
      ).to.be.revertedWithCustomError(wrapper, 'EnforcedPause');
    });

    it('rejects confidentialTransfer', async function () {
      const balance = await wrapper.confidentialBalanceOf(holder.address);
      await expect(
        wrapper.connect(holder)['confidentialTransfer(address,bytes32)'](recipient.address, balance),
      ).to.be.revertedWithCustomError(wrapper, 'EnforcedPause');
    });

    it('rejects confidentialTransferFrom', async function () {
      const until = BigInt(Math.floor(Date.now() / 1000) + 3600);
      await wrapper.connect(holder).setOperator(operator.address, until);
      const encryptedInput = await fhevm
        .createEncryptedInput(wrapper.target, operator.address)
        .add64(ethers.parseUnits('10', 6))
        .encrypt();
      await expect(
        wrapper
          .connect(operator)
          [
            'confidentialTransferFrom(address,address,bytes32,bytes)'
          ](holder.address, recipient.address, encryptedInput.handles[0], encryptedInput.inputProof),
      ).to.be.revertedWithCustomError(wrapper, 'EnforcedPause');
    });
  });

  describe('ungated entry points', function () {
    beforeEach(async function () {
      await wrapper.connect(ownerSigner).setPauser(pauser.address);
      await wrapper.connect(pauser).pause();
    });

    it('allows setOperator', async function () {
      const until = BigInt(Math.floor(Date.now() / 1000) + 3600);
      await expect(wrapper.connect(holder).setOperator(operator.address, until)).not.to.be.reverted;
      expect(await wrapper.isOperator(holder.address, operator.address)).to.be.true;
    });

    it('allows blockUser and unblockUser', async function () {
      await expect(wrapper.connect(ownerSigner).blockUser(outsider.address))
        .to.emit(wrapper, 'UserBlocked')
        .withArgs(outsider.address);
      await expect(wrapper.connect(ownerSigner).unblockUser(outsider.address))
        .to.emit(wrapper, 'UserUnblocked')
        .withArgs(outsider.address);
    });
  });

  describe('finalizeUnwrap', function () {
    let unwrapRequestId: string;
    let unwrapAmount: string;

    beforeEach(async function () {
      await wrapper.connect(holder).wrap(holder.address, WRAP_AMOUNT);
      const balance = await wrapper.confidentialBalanceOf(holder.address);
      await wrapper.connect(holder).unwrap(holder.address, recipient.address, balance);
      const event = (await wrapper.queryFilter(wrapper.filters.UnwrapRequested())).at(-1)!;
      unwrapRequestId = event.args[1];
      unwrapAmount = event.args[2];
      await wrapper.connect(ownerSigner).setPauser(pauser.address);
      await wrapper.connect(pauser).pause();
    });

    it('rejects settlement while paused', async function () {
      await expect(wrapper.connect(recipient).finalizeUnwrap(unwrapRequestId, 0, '0x')).to.be.revertedWithCustomError(
        wrapper,
        'EnforcedPause',
      );
    });

    it('settles the pending request once unpaused', async function () {
      const { abiEncodedClearValues, decryptionProof } = await fhevm.publicDecrypt([unwrapAmount]);
      const recipientBalanceBefore = await token.balanceOf(recipient.address);

      await wrapper.connect(ownerSigner).unpause();

      await expect(wrapper.connect(recipient).finalizeUnwrap(unwrapRequestId, abiEncodedClearValues, decryptionProof))
        .to.emit(wrapper, 'UnwrapFinalized')
        .withArgs(recipient.address, unwrapRequestId, unwrapAmount, abiEncodedClearValues);
      expect(await token.balanceOf(recipient.address)).to.equal(recipientBalanceBefore + WRAP_AMOUNT);
    });
  });

  describe('resuming', function () {
    it('restores wrapping and confidential transfers after unpause', async function () {
      await wrapper.connect(ownerSigner).setPauser(pauser.address);
      await wrapper.connect(pauser).pause();
      await wrapper.connect(ownerSigner).unpause();

      await expect(wrapper.connect(holder).wrap(holder.address, WRAP_AMOUNT)).not.to.be.reverted;
      const balance = await wrapper.confidentialBalanceOf(holder.address);
      await expect(wrapper.connect(holder)['confidentialTransfer(address,bytes32)'](recipient.address, balance)).not.to
        .be.reverted;
    });

    it('can be paused again by the same pauser', async function () {
      await wrapper.connect(ownerSigner).setPauser(pauser.address);
      await wrapper.connect(pauser).pause();
      await wrapper.connect(ownerSigner).unpause();
      await expect(wrapper.connect(pauser).pause()).to.emit(wrapper, 'Paused').withArgs(pauser.address);
    });
  });
});
