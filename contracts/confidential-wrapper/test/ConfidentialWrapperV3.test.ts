import { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers, fhevm } from 'hardhat';
import hre from 'hardhat';
import { allowHandle, impersonate } from './utils/accounts';
import { DEFAULT_WRAPPER_OWNER, deployConfidentialWrapper } from './utils/confidentialWrapper';

const owner = DEFAULT_WRAPPER_OWNER;

const BLOCKED_ADDRESSES = Array.from({ length: 5 }, () => ethers.getAddress(ethers.hexlify(ethers.randomBytes(20))));

const SELECTOR_CUSDC = '0xfe575a87';
const SELECTOR_CUSDT = '0x59bf1abe';
const SELECTOR_TGBP = '0x97f735d5';
const SELECTOR_XAUT = '0xfbac3951';

async function deployV3(token: string, selector = '0x00000000', hasSelector = false, blockedUsers: string[] = []) {
  return deployConfidentialWrapper(token, {
    blockedUsers,
    underlyingDenyListSelector: selector,
    hasUnderlyingDenyListSelector: hasSelector,
  });
}

describe('ConfidentialWrapperV3 DenyList', function () {
  describe('Block List Management', function () {
    let wrapper: any;
    let ownerSigner: HardhatEthersSigner;
    let outsider: HardhatEthersSigner;

    beforeEach(async function () {
      [, , , outsider] = await ethers.getSigners();
      ownerSigner = await ethers.getSigner(owner);
      const token = await ethers.deployContract('$ERC20Mock', ['Mock Token', 'MOCK', 6]);
      wrapper = await deployV3(token.target as string);
    });

    describe('blockUser', function () {
      it('adds user to denylist and emits UserBlocked', async function () {
        const target = BLOCKED_ADDRESSES[0];
        await expect(wrapper.connect(ownerSigner).blockUser(target)).to.emit(wrapper, 'UserBlocked').withArgs(target);
        expect(await wrapper.isBlockedOnWrapper(target)).to.be.true;
      });

      it('reverts when user is already blocked', async function () {
        const target = BLOCKED_ADDRESSES[0];
        await wrapper.connect(ownerSigner).blockUser(target);
        await expect(wrapper.connect(ownerSigner).blockUser(target))
          .to.be.revertedWithCustomError(wrapper, 'UserAlreadyBlocked')
          .withArgs(target);
      });

      it('reverts for non-owner', async function () {
        await expect(wrapper.connect(outsider).blockUser(BLOCKED_ADDRESSES[0]))
          .to.be.revertedWithCustomError(wrapper, 'OwnableUnauthorizedAccount')
          .withArgs(outsider.address);
      });
    });

    describe('unblockUser', function () {
      it('removes user from denylist and emits UserUnblocked', async function () {
        const target = BLOCKED_ADDRESSES[0];
        await wrapper.connect(ownerSigner).blockUser(target);
        await expect(wrapper.connect(ownerSigner).unblockUser(target))
          .to.emit(wrapper, 'UserUnblocked')
          .withArgs(target);
        expect(await wrapper.isBlockedOnWrapper(target)).to.be.false;
      });

      it('reverts when user is not blocked', async function () {
        await expect(wrapper.connect(ownerSigner).unblockUser(BLOCKED_ADDRESSES[0]))
          .to.be.revertedWithCustomError(wrapper, 'UserAlreadyUnblocked')
          .withArgs(BLOCKED_ADDRESSES[0]);
      });

      it('reverts for non-owner', async function () {
        const target = BLOCKED_ADDRESSES[0];
        await wrapper.connect(ownerSigner).blockUser(target);
        await expect(wrapper.connect(outsider).unblockUser(target))
          .to.be.revertedWithCustomError(wrapper, 'OwnableUnauthorizedAccount')
          .withArgs(outsider.address);
      });
    });

    describe('isBlockedOnWrapper', function () {
      it('returns false for all addresses before any are blocked', async function () {
        for (const addr of BLOCKED_ADDRESSES) {
          expect(await wrapper.isBlockedOnWrapper(addr)).to.be.false;
        }
      });

      it('blocks and unblocks all five addresses independently', async function () {
        for (const addr of BLOCKED_ADDRESSES) {
          await wrapper.connect(ownerSigner).blockUser(addr);
          expect(await wrapper.isBlockedOnWrapper(addr)).to.be.true;
        }
        for (const addr of BLOCKED_ADDRESSES) {
          await wrapper.connect(ownerSigner).unblockUser(addr);
          expect(await wrapper.isBlockedOnWrapper(addr)).to.be.false;
        }
      });

      // with no underlying check configured, the combined view can only reflect this one
      it('is what isBlocked reports when no underlying check is configured', async function () {
        const addr = BLOCKED_ADDRESSES[0];
        expect(await wrapper.isBlocked(addr)).to.be.false;
        await wrapper.connect(ownerSigner).blockUser(addr);
        expect(await wrapper.isBlocked(addr)).to.be.true;
      });
    });
  });

  describe('initialize initialization', function () {
    it('blocks addresses passed in the blockedUsers array', async function () {
      const token = await ethers.deployContract('$ERC20Mock', ['Mock', 'MOCK', 6]);
      const seeds = [BLOCKED_ADDRESSES[0], BLOCKED_ADDRESSES[1]];
      const wrapper = await deployV3(token.target as string, '0x00000000', false, seeds);
      expect(await wrapper.isBlockedOnWrapper(seeds[0])).to.be.true;
      expect(await wrapper.isBlockedOnWrapper(seeds[1])).to.be.true;
      expect(await wrapper.isBlockedOnWrapper(BLOCKED_ADDRESSES[2])).to.be.false;
    });

    it('emits UserBlocked events for seeded addresses during initialize', async function () {
      const token = await ethers.deployContract('$ERC20Mock', ['Mock', 'MOCK', 6]);
      const seeds = [BLOCKED_ADDRESSES[0], BLOCKED_ADDRESSES[1]];
      const wrapper = await deployV3(token.target as string, '0x00000000', false, seeds);
      const events = await wrapper.queryFilter(wrapper.filters.UserBlocked());
      expect(events.length).to.equal(seeds.length);
      expect(events[0].args[0]).to.equal(seeds[0]);
      expect(events[1].args[0]).to.equal(seeds[1]);
    });

    it('reverts when blockedUsers contains duplicate addresses', async function () {
      const token = await ethers.deployContract('$ERC20Mock', ['Mock', 'MOCK', 6]);
      const factory = await ethers.getContractFactory('ConfidentialWrapper');
      const dup = BLOCKED_ADDRESSES[0];
      await expect(deployV3(token.target as string, '0x00000000', false, [dup, dup]))
        .to.be.revertedWithCustomError(factory, 'UserAlreadyBlocked')
        .withArgs(dup);
    });
  });

  describe('_requireNotBlocked', function () {
    let wrapper: any;
    let ownerSigner: HardhatEthersSigner;
    let holder: HardhatEthersSigner;
    let recipient: HardhatEthersSigner;
    let operator: HardhatEthersSigner;
    let token: any;

    beforeEach(async function () {
      [holder, recipient, operator] = await ethers.getSigners();
      ownerSigner = await ethers.getSigner(owner);
      token = await ethers.deployContract('$ERC20Mock', ['Mock Token', 'MOCK', 6]);
      wrapper = await deployV3(token.target as string);
      await token.$_mint(holder.address, ethers.parseUnits('1000', 6));
      await token.connect(holder).approve(wrapper.target, ethers.MaxUint256);
    });

    describe('Wrap', function () {
      it('succeeds for a non-blocked sender', async function () {
        await expect(wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6))).not.to.be.reverted;
      });

      it('reverts via transferFrom when sender is blocked', async function () {
        await wrapper.connect(ownerSigner).blockUser(holder.address);
        await expect(wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6)))
          .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
          .withArgs(holder.address);
      });

      it('reverts via transferFrom when recipient is blocked', async function () {
        await wrapper.connect(ownerSigner).blockUser(recipient.address);
        await expect(wrapper.connect(holder).wrap(recipient.address, ethers.parseUnits('100', 6)))
          .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
          .withArgs(recipient.address);
      });

      it('reverts via ERC-1363 callback when sender is blocked', async function () {
        await wrapper.connect(ownerSigner).blockUser(holder.address);
        await expect(token.connect(holder).transferAndCall(wrapper.target, ethers.parseUnits('100', 6)))
          .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
          .withArgs(holder.address);
      });

      it('reverts via ERC-1363 callback when recipient is blocked', async function () {
        await wrapper.connect(ownerSigner).blockUser(recipient.address);
        await expect(
          token
            .connect(holder)
            [
              'transferAndCall(address,uint256,bytes)'
            ](wrapper.target, ethers.parseUnits('100', 6), ethers.solidityPacked(['address'], [recipient.address])),
        )
          .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
          .withArgs(recipient.address);
      });
    });

    describe('Unwrap', function () {
      beforeEach(async function () {
        await wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6));
      });

      describe('euint64 overload variant', function () {
        it('reverts when `to` is blocked', async function () {
          const balance = await wrapper.confidentialBalanceOf(holder.address);
          await wrapper.connect(ownerSigner).blockUser(recipient.address);
          await expect(wrapper.connect(holder).unwrap(holder.address, recipient.address, balance))
            .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
            .withArgs(recipient.address);
        });

        it('reverts when `from` is blocked (caught in _update)', async function () {
          const balance = await wrapper.confidentialBalanceOf(holder.address);
          await wrapper.connect(ownerSigner).blockUser(holder.address);
          await expect(wrapper.connect(holder).unwrap(holder.address, holder.address, balance))
            .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
            .withArgs(holder.address);
        });

        it('reverts when operator is blocked', async function () {
          await token.$_mint(operator.address, ethers.parseUnits('1000', 6));
          await token.connect(operator).approve(wrapper.target, ethers.MaxUint256);
          await wrapper.connect(operator).wrap(operator.address, ethers.parseUnits('100', 6));
          // just to get some handle allowed to the operator
          const balanceOp = await wrapper.confidentialBalanceOf(operator.address);
          const until = BigInt(Math.floor(Date.now() / 1000) + 3600);
          await wrapper.connect(holder).setOperator(operator.address, until);
          await wrapper.connect(ownerSigner).blockUser(operator.address);
          await expect(wrapper.connect(operator).unwrap(holder.address, holder.address, balanceOp))
            .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
            .withArgs(operator.address);
        });
      });

      describe('externalEuint64 overload variant', function () {
        it('reverts when `to` is blocked', async function () {
          const encryptedInput = await fhevm
            .createEncryptedInput(wrapper.target, holder.address)
            .add64(ethers.parseUnits('10', 6))
            .encrypt();
          await wrapper.connect(ownerSigner).blockUser(recipient.address);
          await expect(
            wrapper
              .connect(holder)
              [
                'unwrap(address,address,bytes32,bytes)'
              ](holder.address, recipient.address, encryptedInput.handles[0], encryptedInput.inputProof),
          )
            .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
            .withArgs(recipient.address);
        });

        it(`reverts when 'from' is blocked (caught in _update)`, async function () {
          const encryptedInput = await fhevm
            .createEncryptedInput(wrapper.target, holder.address)
            .add64(ethers.parseUnits('10', 6))
            .encrypt();
          await wrapper.connect(ownerSigner).blockUser(holder.address);
          await expect(
            wrapper
              .connect(holder)
              [
                'unwrap(address,address,bytes32,bytes)'
              ](holder.address, recipient.address, encryptedInput.handles[0], encryptedInput.inputProof),
          )
            .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
            .withArgs(holder.address);
        });

        it('reverts when operator is blocked', async function () {
          const encryptedInput = await fhevm
            .createEncryptedInput(wrapper.target, operator.address)
            .add64(ethers.parseUnits('10', 6))
            .encrypt();
          const until = BigInt(Math.floor(Date.now() / 1000) + 3600);
          await wrapper.connect(holder).setOperator(operator.address, until);
          await wrapper.connect(ownerSigner).blockUser(operator.address);
          await expect(
            wrapper
              .connect(operator)
              [
                'unwrap(address,address,bytes32,bytes)'
              ](holder.address, holder.address, encryptedInput.handles[0], encryptedInput.inputProof),
          )
            .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
            .withArgs(operator.address);
        });
      });
    });

    describe('finalizeUnwrap', function () {
      let unwrapRequestId: string;

      beforeEach(async function () {
        await wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6));
        const balance = await wrapper.confidentialBalanceOf(holder.address);
        await wrapper.connect(holder).unwrap(holder.address, holder.address, balance);
        const event = (await wrapper.queryFilter(wrapper.filters.UnwrapRequested()))[0];
        unwrapRequestId = event.args[1];
      });

      it('reverts when requester becomes blocked between unwrap and finalization', async function () {
        await wrapper.connect(ownerSigner).blockUser(holder.address);
        await expect(wrapper.connect(holder).finalizeUnwrap(unwrapRequestId, 0, '0x'))
          .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
          .withArgs(holder.address);
      });
    });

    describe('finalizeUnwrap (blocked from/operator between unwrap and finalize)', function () {
      it('reverts with WrapperBlockedAddress(holder) when `from != to` and holder is blocked after unwrap', async function () {
        await wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6));
        const balance = await wrapper.confidentialBalanceOf(holder.address);
        await wrapper.connect(holder).unwrap(holder.address, recipient.address, balance);
        const event = (await wrapper.queryFilter(wrapper.filters.UnwrapRequested())).at(-1)!;
        const unwrapRequestId = event.args[1];

        await wrapper.connect(ownerSigner).blockUser(holder.address);

        await expect(wrapper.connect(recipient).finalizeUnwrap(unwrapRequestId, 0, '0x'))
          .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
          .withArgs(holder.address);
      });

      it('reverts with WrapperBlockedAddress(recipient) when `from != to` and recipient is blocked after unwrap', async function () {
        await wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6));
        const balance = await wrapper.confidentialBalanceOf(holder.address);
        await wrapper.connect(holder).unwrap(holder.address, recipient.address, balance);
        const event = (await wrapper.queryFilter(wrapper.filters.UnwrapRequested())).at(-1)!;
        const unwrapRequestId = event.args[1];

        await wrapper.connect(ownerSigner).blockUser(recipient.address);

        await expect(wrapper.connect(holder).finalizeUnwrap(unwrapRequestId, 0, '0x'))
          .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
          .withArgs(recipient.address);
      });

      it('reverts with WrapperBlockedAddress(operator) when an operator-initiated unwrap is finalized after the operator is blocked', async function () {
        await wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6));
        const until = BigInt(Math.floor(Date.now() / 1000) + 3600);
        await wrapper.connect(holder).setOperator(operator.address, until);

        const encryptedInput = await fhevm
          .createEncryptedInput(wrapper.target, operator.address)
          .add64(ethers.parseUnits('100', 6))
          .encrypt();
        await wrapper
          .connect(operator)
          [
            'unwrap(address,address,bytes32,bytes)'
          ](holder.address, recipient.address, encryptedInput.handles[0], encryptedInput.inputProof);
        const event = (await wrapper.queryFilter(wrapper.filters.UnwrapRequested())).at(-1)!;
        const unwrapRequestId = event.args[1];

        await wrapper.connect(ownerSigner).blockUser(operator.address);

        await expect(wrapper.connect(recipient).finalizeUnwrap(unwrapRequestId, 0, '0x'))
          .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
          .withArgs(operator.address);
      });

      it('successfully finalizes when no party is blocked, settles the underlying transfer, and reports gas', async function () {
        const wrapAmount = ethers.parseUnits('100', 6);
        await wrapper.connect(holder).wrap(holder.address, wrapAmount);
        const balance = await wrapper.confidentialBalanceOf(holder.address);
        await wrapper.connect(holder).unwrap(holder.address, recipient.address, balance);

        const event = (await wrapper.queryFilter(wrapper.filters.UnwrapRequested())).at(-1)!;
        const unwrapRequestId = event.args[1];
        const unwrapAmount = event.args[2];
        const { abiEncodedClearValues, decryptionProof } = await fhevm.publicDecrypt([unwrapAmount]);

        const recipientBalanceBefore = await token.balanceOf(recipient.address);

        const tx = await wrapper
          .connect(recipient)
          .finalizeUnwrap(unwrapRequestId, abiEncodedClearValues, decryptionProof);
        await tx.wait();

        await expect(tx)
          .to.emit(wrapper, 'UnwrapFinalized')
          .withArgs(recipient.address, unwrapRequestId, unwrapAmount, abiEncodedClearValues);

        expect(await token.balanceOf(recipient.address)).to.equal(recipientBalanceBefore + wrapAmount);
        expect(await wrapper.unwrapRequester(unwrapRequestId)).to.equal(ethers.ZeroAddress);
      });
    });

    describe('confidentialTransfer', function () {
      beforeEach(async function () {
        await wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6));
      });

      describe('externalEuint64 overload variant', function () {
        it('reverts when sender is blocked', async function () {
          const encryptedInput = await fhevm
            .createEncryptedInput(wrapper.target, holder.address)
            .add64(ethers.parseUnits('10', 6))
            .encrypt();
          await wrapper.connect(ownerSigner).blockUser(holder.address);
          await expect(
            wrapper
              .connect(holder)
              [
                'confidentialTransfer(address,bytes32,bytes)'
              ](recipient.address, encryptedInput.handles[0], encryptedInput.inputProof),
          )
            .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
            .withArgs(holder.address);
        });

        it('reverts when recipient is blocked', async function () {
          const encryptedInput = await fhevm
            .createEncryptedInput(wrapper.target, holder.address)
            .add64(ethers.parseUnits('10', 6))
            .encrypt();
          await wrapper.connect(ownerSigner).blockUser(recipient.address);
          await expect(
            wrapper
              .connect(holder)
              [
                'confidentialTransfer(address,bytes32,bytes)'
              ](recipient.address, encryptedInput.handles[0], encryptedInput.inputProof),
          )
            .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
            .withArgs(recipient.address);
        });
      });

      describe('euint64 overload variant', function () {
        it('reverts when sender is blocked', async function () {
          const balance = await wrapper.confidentialBalanceOf(holder.address);
          await wrapper.connect(ownerSigner).blockUser(holder.address);
          await expect(wrapper.connect(holder)['confidentialTransfer(address,bytes32)'](recipient.address, balance))
            .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
            .withArgs(holder.address);
        });

        it('reverts when recipient is blocked', async function () {
          const balance = await wrapper.confidentialBalanceOf(holder.address);
          await wrapper.connect(ownerSigner).blockUser(recipient.address);
          await expect(wrapper.connect(holder)['confidentialTransfer(address,bytes32)'](recipient.address, balance))
            .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
            .withArgs(recipient.address);
        });
      });
    });

    describe('confidentialTransferFrom', function () {
      beforeEach(async function () {
        await wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6));
        const until = BigInt(Math.floor(Date.now() / 1000) + 3600);
        await wrapper.connect(holder).setOperator(operator.address, until);
        const balance = (await wrapper.confidentialBalanceOf(holder.address)) as string;
        const wrapperSigner = await impersonate(hre, await wrapper.getAddress());
        await allowHandle(hre, wrapperSigner, operator, balance);
      });

      describe('externalEuint64 overload variant', function () {
        it('reverts when operator is blocked', async function () {
          const encryptedInput = await fhevm
            .createEncryptedInput(wrapper.target, operator.address)
            .add64(ethers.parseUnits('10', 6))
            .encrypt();
          await wrapper.connect(ownerSigner).blockUser(operator.address);
          await expect(
            wrapper
              .connect(operator)
              [
                'confidentialTransferFrom(address,address,bytes32,bytes)'
              ](holder.address, recipient.address, encryptedInput.handles[0], encryptedInput.inputProof),
          )
            .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
            .withArgs(operator.address);
        });

        it('reverts when sender (from) is blocked', async function () {
          const encryptedInput = await fhevm
            .createEncryptedInput(wrapper.target, operator.address)
            .add64(ethers.parseUnits('10', 6))
            .encrypt();
          await wrapper.connect(ownerSigner).blockUser(holder.address);
          await expect(
            wrapper
              .connect(operator)
              [
                'confidentialTransferFrom(address,address,bytes32,bytes)'
              ](holder.address, recipient.address, encryptedInput.handles[0], encryptedInput.inputProof),
          )
            .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
            .withArgs(holder.address);
        });

        it('reverts when recipient is blocked', async function () {
          const encryptedInput = await fhevm
            .createEncryptedInput(wrapper.target, operator.address)
            .add64(ethers.parseUnits('10', 6))
            .encrypt();
          await wrapper.connect(ownerSigner).blockUser(recipient.address);
          await expect(
            wrapper
              .connect(operator)
              [
                'confidentialTransferFrom(address,address,bytes32,bytes)'
              ](holder.address, recipient.address, encryptedInput.handles[0], encryptedInput.inputProof),
          )
            .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
            .withArgs(recipient.address);
        });
      });

      describe('euint64 overload variant', function () {
        it('reverts when operator is blocked', async function () {
          const balance = await wrapper.confidentialBalanceOf(holder.address);
          await wrapper.connect(ownerSigner).blockUser(operator.address);
          await expect(
            wrapper
              .connect(operator)
              ['confidentialTransferFrom(address,address,bytes32)'](holder.address, recipient.address, balance),
          )
            .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
            .withArgs(operator.address);
        });

        it('reverts when sender (from) is blocked', async function () {
          const balance = await wrapper.confidentialBalanceOf(holder.address);
          await wrapper.connect(ownerSigner).blockUser(holder.address);
          await expect(
            wrapper
              .connect(operator)
              ['confidentialTransferFrom(address,address,bytes32)'](holder.address, recipient.address, balance),
          )
            .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
            .withArgs(holder.address);
        });

        it('reverts when recipient is blocked', async function () {
          const balance = await wrapper.confidentialBalanceOf(holder.address);
          await wrapper.connect(ownerSigner).blockUser(recipient.address);
          await expect(
            wrapper
              .connect(operator)
              ['confidentialTransferFrom(address,address,bytes32)'](holder.address, recipient.address, balance),
          )
            .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
            .withArgs(recipient.address);
        });
      });
    });

    describe('confidentialTransferAndCall', function () {
      beforeEach(async function () {
        await wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6));
      });

      describe('externalEuint64 overload variant', function () {
        it('reverts when sender is blocked', async function () {
          const encryptedInput = await fhevm
            .createEncryptedInput(wrapper.target, holder.address)
            .add64(ethers.parseUnits('10', 6))
            .encrypt();
          await wrapper.connect(ownerSigner).blockUser(holder.address);
          await expect(
            wrapper
              .connect(holder)
              [
                'confidentialTransferAndCall(address,bytes32,bytes,bytes)'
              ](recipient.address, encryptedInput.handles[0], encryptedInput.inputProof, '0x'),
          )
            .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
            .withArgs(holder.address);
        });

        it('reverts when recipient is blocked', async function () {
          const encryptedInput = await fhevm
            .createEncryptedInput(wrapper.target, holder.address)
            .add64(ethers.parseUnits('10', 6))
            .encrypt();
          await wrapper.connect(ownerSigner).blockUser(recipient.address);
          await expect(
            wrapper
              .connect(holder)
              [
                'confidentialTransferAndCall(address,bytes32,bytes,bytes)'
              ](recipient.address, encryptedInput.handles[0], encryptedInput.inputProof, '0x'),
          )
            .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
            .withArgs(recipient.address);
        });
      });

      describe('euint64 overload variant', function () {
        it('reverts when sender is blocked', async function () {
          const balance = await wrapper.confidentialBalanceOf(holder.address);
          await wrapper.connect(ownerSigner).blockUser(holder.address);
          await expect(
            wrapper
              .connect(holder)
              ['confidentialTransferAndCall(address,bytes32,bytes)'](recipient.address, balance, '0x'),
          )
            .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
            .withArgs(holder.address);
        });

        it('reverts when recipient is blocked', async function () {
          const balance = await wrapper.confidentialBalanceOf(holder.address);
          await wrapper.connect(ownerSigner).blockUser(recipient.address);
          await expect(
            wrapper
              .connect(holder)
              ['confidentialTransferAndCall(address,bytes32,bytes)'](recipient.address, balance, '0x'),
          )
            .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
            .withArgs(recipient.address);
        });
      });
    });

    describe('confidentialTransferFromAndCall', function () {
      beforeEach(async function () {
        await wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6));
        const until = BigInt(Math.floor(Date.now() / 1000) + 3600);
        await wrapper.connect(holder).setOperator(operator.address, until);
        const balance = (await wrapper.confidentialBalanceOf(holder.address)) as string;
        const wrapperSigner = await impersonate(hre, await wrapper.getAddress());
        await allowHandle(hre, wrapperSigner, operator, balance);
      });

      describe('externalEuint64 overload variant', function () {
        it('reverts when operator is blocked', async function () {
          const encryptedInput = await fhevm
            .createEncryptedInput(wrapper.target, operator.address)
            .add64(ethers.parseUnits('10', 6))
            .encrypt();
          await wrapper.connect(ownerSigner).blockUser(operator.address);
          await expect(
            wrapper
              .connect(operator)
              [
                'confidentialTransferFromAndCall(address,address,bytes32,bytes,bytes)'
              ](holder.address, recipient.address, encryptedInput.handles[0], encryptedInput.inputProof, '0x'),
          )
            .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
            .withArgs(operator.address);
        });

        it('reverts when sender (from) is blocked', async function () {
          const encryptedInput = await fhevm
            .createEncryptedInput(wrapper.target, operator.address)
            .add64(ethers.parseUnits('10', 6))
            .encrypt();
          await wrapper.connect(ownerSigner).blockUser(holder.address);
          await expect(
            wrapper
              .connect(operator)
              [
                'confidentialTransferFromAndCall(address,address,bytes32,bytes,bytes)'
              ](holder.address, recipient.address, encryptedInput.handles[0], encryptedInput.inputProof, '0x'),
          )
            .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
            .withArgs(holder.address);
        });

        it('reverts when recipient is blocked', async function () {
          const encryptedInput = await fhevm
            .createEncryptedInput(wrapper.target, operator.address)
            .add64(ethers.parseUnits('10', 6))
            .encrypt();
          await wrapper.connect(ownerSigner).blockUser(recipient.address);
          await expect(
            wrapper
              .connect(operator)
              [
                'confidentialTransferFromAndCall(address,address,bytes32,bytes,bytes)'
              ](holder.address, recipient.address, encryptedInput.handles[0], encryptedInput.inputProof, '0x'),
          )
            .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
            .withArgs(recipient.address);
        });
      });

      describe('euint64 overload variant', function () {
        it('reverts when operator is blocked', async function () {
          const balance = await wrapper.confidentialBalanceOf(holder.address);
          await wrapper.connect(ownerSigner).blockUser(operator.address);
          await expect(
            wrapper
              .connect(operator)
              [
                'confidentialTransferFromAndCall(address,address,bytes32,bytes)'
              ](holder.address, recipient.address, balance, '0x'),
          )
            .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
            .withArgs(operator.address);
        });

        it('reverts when sender (from) is blocked', async function () {
          const balance = await wrapper.confidentialBalanceOf(holder.address);
          await wrapper.connect(ownerSigner).blockUser(holder.address);
          await expect(
            wrapper
              .connect(operator)
              [
                'confidentialTransferFromAndCall(address,address,bytes32,bytes)'
              ](holder.address, recipient.address, balance, '0x'),
          )
            .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
            .withArgs(holder.address);
        });

        it('reverts when recipient is blocked', async function () {
          const balance = await wrapper.confidentialBalanceOf(holder.address);
          await wrapper.connect(ownerSigner).blockUser(recipient.address);
          await expect(
            wrapper
              .connect(operator)
              [
                'confidentialTransferFromAndCall(address,address,bytes32,bytes)'
              ](holder.address, recipient.address, balance, '0x'),
          )
            .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
            .withArgs(recipient.address);
        });
      });
    });
  });

  describe('Underlying DenyList — cUSDC isBlacklisted (0xfe575a87)', function () {
    let wrapper: any;
    let holder: HardhatEthersSigner;
    let token: any;

    beforeEach(async function () {
      [holder] = await ethers.getSigners();
      token = await ethers.deployContract('ERC20MockCUSDC');
      wrapper = await deployV3(token.target as string, SELECTOR_CUSDC, true);
      await token.mint(holder.address, ethers.parseUnits('100', 6));
      await token.connect(holder).approve(wrapper.target, ethers.MaxUint256);
    });

    it('allows wrap when address is not deny-listed', async function () {
      await expect(wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6))).not.to.be.reverted;
    });

    it('reverts wrap when address is deny-listed', async function () {
      await token.setDenyListed(holder.address, true);
      await expect(wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6)))
        .to.be.revertedWithCustomError(wrapper, 'UnderlyingDenyListedAddress')
        .withArgs(holder.address);
    });
  });

  describe('Underlying DenyList — cUSDT getBlackListStatus (0x59bf1abe)', function () {
    let wrapper: any;
    let holder: HardhatEthersSigner;
    let token: any;

    beforeEach(async function () {
      [holder] = await ethers.getSigners();
      token = await ethers.deployContract('ERC20MockCUSDT');
      wrapper = await deployV3(token.target as string, SELECTOR_CUSDT, true);
      await token.mint(holder.address, ethers.parseUnits('100', 6));
      await token.connect(holder).approve(wrapper.target, ethers.MaxUint256);
    });

    it('allows wrap when address is not deny-listed', async function () {
      await expect(wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6))).not.to.be.reverted;
    });

    it('reverts wrap when address is deny-listed', async function () {
      await token.setDenyListed(holder.address, true);
      await expect(wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6)))
        .to.be.revertedWithCustomError(wrapper, 'UnderlyingDenyListedAddress')
        .withArgs(holder.address);
    });
  });

  describe('Underlying DenyList — tGBP isBanned (0x97f735d5)', function () {
    let wrapper: any;
    let holder: HardhatEthersSigner;
    let token: any;

    beforeEach(async function () {
      [holder] = await ethers.getSigners();
      token = await ethers.deployContract('ERC20MockTGBP');
      wrapper = await deployV3(token.target as string, SELECTOR_TGBP, true);
      await token.mint(holder.address, ethers.parseUnits('100', 6));
      await token.connect(holder).approve(wrapper.target, ethers.MaxUint256);
    });

    it('allows wrap when address is not deny-listed', async function () {
      await expect(wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6))).not.to.be.reverted;
    });

    it('reverts wrap when address is deny-listed', async function () {
      await token.setDenyListed(holder.address, true);
      await expect(wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6)))
        .to.be.revertedWithCustomError(wrapper, 'UnderlyingDenyListedAddress')
        .withArgs(holder.address);
    });
  });

  describe('Underlying DenyList — XAUt isBlocked (0xfbac3951)', function () {
    let wrapper: any;
    let holder: HardhatEthersSigner;
    let token: any;

    beforeEach(async function () {
      [holder] = await ethers.getSigners();
      token = await ethers.deployContract('ERC20MockXAUt');
      wrapper = await deployV3(token.target as string, SELECTOR_XAUT, true);
      await token.mint(holder.address, ethers.parseUnits('100', 6));
      await token.connect(holder).approve(wrapper.target, ethers.MaxUint256);
    });

    it('allows wrap when address is not deny-listed', async function () {
      await expect(wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6))).not.to.be.reverted;
    });

    it('reverts wrap when address is deny-listed', async function () {
      await token.setDenyListed(holder.address, true);
      await expect(wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6)))
        .to.be.revertedWithCustomError(wrapper, 'UnderlyingDenyListedAddress')
        .withArgs(holder.address);
    });
  });

  describe('Underlying DenyList — zero selector (0x00000000) is a valid, active selector', function () {
    let wrapper: any;
    let holder: HardhatEthersSigner;
    let token: any;

    beforeEach(async function () {
      [holder] = await ethers.getSigners();
      token = await ethers.deployContract('ERC20MockZeroSelector');
      // (selector = 0x00000000, isSet = true): a mined zero selector is an ordinary selector,
      // enablement comes from the bool — never from selector != 0.
      wrapper = await deployV3(token.target as string, '0x00000000', true);
      await token.mint(holder.address, ethers.parseUnits('100', 6));
      await token.connect(holder).approve(wrapper.target, ethers.MaxUint256);
    });

    it('dispatches to selector 0x00000000 and allows wrap when address is not deny-listed', async function () {
      await expect(wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6))).not.to.be.reverted;
    });

    it('dispatches to selector 0x00000000 and reverts wrap when address is deny-listed', async function () {
      await token.setDenyListed(holder.address, true);
      await expect(wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6)))
        .to.be.revertedWithCustomError(wrapper, 'UnderlyingDenyListedAddress')
        .withArgs(holder.address);
    });
  });

  // ─── Underlying DenyList — error paths ───────────────────────────────────

  describe('Underlying DenyList — call reverts (UnderlyingDenyListCallFailed)', function () {
    let wrapper: any;
    let holder: HardhatEthersSigner;

    beforeEach(async function () {
      [holder] = await ethers.getSigners();
      const token: any = await ethers.deployContract('ERC20MockRevertingDenyList');
      wrapper = await deployV3(token.target as string, SELECTOR_CUSDC, true);
      await token.mint(holder.address, ethers.parseUnits('100', 6));
      await token.connect(holder).approve(wrapper.target, ethers.MaxUint256);
    });

    it('reverts wrap with UnderlyingDenyListCallFailed when underlying reverts', async function () {
      await expect(
        wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6)),
      ).to.be.revertedWithCustomError(wrapper, 'UnderlyingDenyListCallFailed');
    });
  });

  describe('Underlying DenyList — invalid response (InvalidUnderlyingDenyListResponse)', function () {
    let wrapper: any;
    let holder: HardhatEthersSigner;

    beforeEach(async function () {
      [holder] = await ethers.getSigners();
      const token: any = await ethers.deployContract('ERC20MockInvalidDenyList');
      wrapper = await deployV3(token.target as string, SELECTOR_CUSDC, true);
      await token.mint(holder.address, ethers.parseUnits('100', 6));
      await token.connect(holder).approve(wrapper.target, ethers.MaxUint256);
    });

    it('reverts wrap with InvalidUnderlyingDenyListResponse when underlying returns wrong-length data', async function () {
      await expect(
        wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6)),
      ).to.be.revertedWithCustomError(wrapper, 'InvalidUnderlyingDenyListResponse');
    });
  });

  describe('Underlying DenyList — invalid selector (UnderlyingDenyListCallFailed)', function () {
    it('reverts wrap when configured selector does not exist on the underlying token', async function () {
      const [holder] = await ethers.getSigners();
      const token: any = await ethers.deployContract('ERC20MockCUSDC');
      const wrapper = await deployV3(token.target as string, '0xdeadbeef', true);
      await token.mint(holder.address, ethers.parseUnits('100', 6));
      await token.connect(holder).approve(wrapper.target, ethers.MaxUint256);
      await expect(
        wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6)),
      ).to.be.revertedWithCustomError(wrapper, 'UnderlyingDenyListCallFailed');
    });
  });

  describe('Underlying DenyList — hasSelector = false bypasses underlying check', function () {
    it('allows wrap even when underlying would return blacklisted = true', async function () {
      const [holder] = await ethers.getSigners();
      const token: any = await ethers.deployContract('ERC20MockCUSDC');
      const wrapper = await deployV3(token.target as string, '0x00000000', false);
      await token.mint(holder.address, ethers.parseUnits('100', 6));
      await token.connect(holder).approve(wrapper.target, ethers.MaxUint256);
      await token.setDenyListed(holder.address, true);
      await expect(wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6))).not.to.be.reverted;
    });
  });

  describe('Underlying DenyList — local block list checked before underlying', function () {
    it('reverts with WrapperBlockedAddress (not UnderlyingDenyListedAddress) when user is on both lists', async function () {
      const [holder] = await ethers.getSigners();
      const ownerSigner = await ethers.getSigner(owner);
      const token: any = await ethers.deployContract('ERC20MockCUSDC');
      const wrapper = await deployV3(token.target as string, SELECTOR_CUSDC, true);
      await token.mint(holder.address, ethers.parseUnits('100', 6));
      await token.connect(holder).approve(wrapper.target, ethers.MaxUint256);
      await wrapper.connect(ownerSigner).blockUser(holder.address);
      await token.setDenyListed(holder.address, true);
      await expect(wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6)))
        .to.be.revertedWithCustomError(wrapper, 'WrapperBlockedAddress')
        .withArgs(holder.address);
    });
  });

  // ─── isBlockedOnUnderlying view ──────────────────────────────────────────

  // The blocks above assert on wrap, i.e. on enforcement. These assert on the view itself:
  // the branches it can take before the staticcall, and the fact that it propagates the
  // staticcall failures rather than flattening them to false.
  describe('isBlockedOnUnderlying', function () {
    let holder: HardhatEthersSigner;
    let ownerSigner: HardhatEthersSigner;

    beforeEach(async function () {
      [holder] = await ethers.getSigners();
      ownerSigner = await ethers.getSigner(owner);
    });

    it('agrees with wrap for an address denied only by the underlying', async function () {
      const token: any = await ethers.deployContract('ERC20MockCUSDC');
      const wrapper = await deployV3(token.target as string, SELECTOR_CUSDC, true);
      await token.mint(holder.address, ethers.parseUnits('100', 6));
      await token.connect(holder).approve(wrapper.target, ethers.MaxUint256);

      expect(await wrapper.isBlockedOnUnderlying(holder.address)).to.be.false;

      await token.setDenyListed(holder.address, true);

      // the false negative this view exists to close: clear on the wrapper list, still rejected.
      // the wrap assertion duplicates the cUSDC block above on purpose — agreement between the
      // view and enforcement is what is under test, so it has to be observed in one place.
      expect(await wrapper.isBlockedOnWrapper(holder.address)).to.be.false;
      expect(await wrapper.isBlockedOnUnderlying(holder.address)).to.be.true;
      await expect(wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6)))
        .to.be.revertedWithCustomError(wrapper, 'UnderlyingDenyListedAddress')
        .withArgs(holder.address);
    });

    it('is independent of the wrapper-local denylist', async function () {
      const token: any = await ethers.deployContract('ERC20MockCUSDC');
      const wrapper = await deployV3(token.target as string, SELECTOR_CUSDC, true);
      await wrapper.connect(ownerSigner).blockUser(holder.address);

      expect(await wrapper.isBlockedOnWrapper(holder.address)).to.be.true;
      expect(await wrapper.isBlockedOnUnderlying(holder.address)).to.be.false;
    });

    it('returns false when the underlying check is disabled', async function () {
      const token: any = await ethers.deployContract('ERC20MockCUSDC');
      const wrapper = await deployV3(token.target as string, '0x00000000', false);
      await token.setDenyListed(holder.address, true);

      expect(await wrapper.isBlockedOnUnderlying(holder.address)).to.be.false;
    });

    it('returns false for the zero address, matching the mint and burn exemption', async function () {
      const token: any = await ethers.deployContract('ERC20MockCUSDC');
      const wrapper = await deployV3(token.target as string, SELECTOR_CUSDC, true);

      expect(await wrapper.isBlockedOnUnderlying(ethers.ZeroAddress)).to.be.false;
    });

    it('tracks a selector change made through setUnderlyingDenyListSelector', async function () {
      const token: any = await ethers.deployContract('ERC20MockCUSDT');
      const wrapper = await deployV3(token.target as string, '0x00000000', false);
      await token.setDenyListed(holder.address, true);

      expect(await wrapper.isBlockedOnUnderlying(holder.address)).to.be.false;

      await wrapper.connect(ownerSigner).setUnderlyingDenyListSelector(true, SELECTOR_CUSDT);
      expect(await wrapper.isBlockedOnUnderlying(holder.address)).to.be.true;
    });

    it('reverts with UnderlyingDenyListCallFailed when the underlying call reverts', async function () {
      const token: any = await ethers.deployContract('ERC20MockRevertingDenyList');
      const wrapper = await deployV3(token.target as string, SELECTOR_CUSDC, true);

      await expect(wrapper.isBlockedOnUnderlying(holder.address)).to.be.revertedWithCustomError(
        wrapper,
        'UnderlyingDenyListCallFailed',
      );
    });

    it('reverts with InvalidUnderlyingDenyListResponse when the underlying returns wrong-length data', async function () {
      const token: any = await ethers.deployContract('ERC20MockInvalidDenyList');
      const wrapper = await deployV3(token.target as string, SELECTOR_CUSDC, true);

      await expect(wrapper.isBlockedOnUnderlying(holder.address)).to.be.revertedWithCustomError(
        wrapper,
        'InvalidUnderlyingDenyListResponse',
      );
    });
  });

  // ─── isBlocked (combined) view ───────────────────────────────────────────

  describe('isBlocked', function () {
    let holder: HardhatEthersSigner;
    let ownerSigner: HardhatEthersSigner;

    beforeEach(async function () {
      [holder] = await ethers.getSigners();
      ownerSigner = await ethers.getSigner(owner);
    });

    it('returns false when neither source denies the address', async function () {
      const token: any = await ethers.deployContract('ERC20MockCUSDC');
      const wrapper = await deployV3(token.target as string, SELECTOR_CUSDC, true);

      expect(await wrapper.isBlocked(holder.address)).to.be.false;
    });

    it('returns true when only the wrapper-local denylist denies the address', async function () {
      const token: any = await ethers.deployContract('ERC20MockCUSDC');
      const wrapper = await deployV3(token.target as string, SELECTOR_CUSDC, true);
      await wrapper.connect(ownerSigner).blockUser(holder.address);

      expect(await wrapper.isBlockedOnWrapper(holder.address)).to.be.true;
      expect(await wrapper.isBlockedOnUnderlying(holder.address)).to.be.false;
      expect(await wrapper.isBlocked(holder.address)).to.be.true;
    });

    it('returns true when only the underlying denies the address', async function () {
      const token: any = await ethers.deployContract('ERC20MockCUSDC');
      const wrapper = await deployV3(token.target as string, SELECTOR_CUSDC, true);
      await token.setDenyListed(holder.address, true);

      expect(await wrapper.isBlockedOnWrapper(holder.address)).to.be.false;
      expect(await wrapper.isBlockedOnUnderlying(holder.address)).to.be.true;
      expect(await wrapper.isBlocked(holder.address)).to.be.true;
    });

    it('returns true when both sources deny the address', async function () {
      const token: any = await ethers.deployContract('ERC20MockCUSDC');
      const wrapper = await deployV3(token.target as string, SELECTOR_CUSDC, true);
      await wrapper.connect(ownerSigner).blockUser(holder.address);
      await token.setDenyListed(holder.address, true);

      expect(await wrapper.isBlocked(holder.address)).to.be.true;
    });

    it('ignores the underlying source when the check is disabled', async function () {
      const token: any = await ethers.deployContract('ERC20MockCUSDC');
      const wrapper = await deployV3(token.target as string, '0x00000000', false);
      await token.setDenyListed(holder.address, true);

      expect(await wrapper.isBlocked(holder.address)).to.be.false;

      await wrapper.connect(ownerSigner).setUnderlyingDenyListSelector(true, SELECTOR_CUSDC);
      expect(await wrapper.isBlocked(holder.address)).to.be.true;
    });

    it('returns false for the zero address, matching the mint and burn exemption', async function () {
      const token: any = await ethers.deployContract('ERC20MockCUSDC');
      const wrapper = await deployV3(token.target as string, SELECTOR_CUSDC, true);
      await token.setDenyListed(ethers.ZeroAddress, true);

      expect(await wrapper.isBlocked(ethers.ZeroAddress)).to.be.false;
    });

    it('reverts with UnderlyingDenyListCallFailed when the underlying call reverts', async function () {
      const token: any = await ethers.deployContract('ERC20MockRevertingDenyList');
      const wrapper = await deployV3(token.target as string, SELECTOR_CUSDC, true);

      await expect(wrapper.isBlocked(holder.address)).to.be.revertedWithCustomError(
        wrapper,
        'UnderlyingDenyListCallFailed',
      );
    });

    it('short-circuits the underlying call when the wrapper-local denylist already denies', async function () {
      const token: any = await ethers.deployContract('ERC20MockRevertingDenyList');
      const wrapper = await deployV3(token.target as string, SELECTOR_CUSDC, true);
      await wrapper.connect(ownerSigner).blockUser(holder.address);

      // the underlying mock getter reverts for every address, so a true result here can only come
      // from the local list being consulted first
      expect(await wrapper.isBlocked(holder.address)).to.be.true;
    });

    it('agrees with enforcement for an address denied only by the underlying', async function () {
      const token: any = await ethers.deployContract('ERC20MockCUSDC');
      const wrapper = await deployV3(token.target as string, SELECTOR_CUSDC, true);
      await token.mint(holder.address, ethers.parseUnits('100', 6));
      await token.connect(holder).approve(wrapper.target, ethers.MaxUint256);
      await token.setDenyListed(holder.address, true);

      expect(await wrapper.isBlocked(holder.address)).to.be.true;
      await expect(wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6)))
        .to.be.revertedWithCustomError(wrapper, 'UnderlyingDenyListedAddress')
        .withArgs(holder.address);
    });
  });

  // ─── Underlying DenyList — full lifecycle (cUSDC, representative) ─────────

  describe('Underlying DenyList — full lifecycle (cUSDC)', function () {
    let wrapper: any;
    let holder: HardhatEthersSigner;
    let recipient: HardhatEthersSigner;
    let token: any;

    beforeEach(async function () {
      [holder, recipient] = await ethers.getSigners();
      token = await ethers.deployContract('ERC20MockCUSDC');
      wrapper = await deployV3(token.target as string, SELECTOR_CUSDC, true);
      await token.mint(holder.address, ethers.parseUnits('1000', 6));
      await token.connect(holder).approve(wrapper.target, ethers.MaxUint256);
      await wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6));
    });

    describe('confidentialTransfer', function () {
      it('reverts when sender is flagged by underlying denylist', async function () {
        const encryptedInput = await fhevm
          .createEncryptedInput(wrapper.target, holder.address)
          .add64(ethers.parseUnits('10', 6))
          .encrypt();
        await token.setDenyListed(holder.address, true);
        await expect(
          wrapper
            .connect(holder)
            [
              'confidentialTransfer(address,bytes32,bytes)'
            ](recipient.address, encryptedInput.handles[0], encryptedInput.inputProof),
        )
          .to.be.revertedWithCustomError(wrapper, 'UnderlyingDenyListedAddress')
          .withArgs(holder.address);
      });

      it('reverts when recipient is flagged by underlying denylist', async function () {
        const encryptedInput = await fhevm
          .createEncryptedInput(wrapper.target, holder.address)
          .add64(ethers.parseUnits('10', 6))
          .encrypt();
        await token.setDenyListed(recipient.address, true);
        await expect(
          wrapper
            .connect(holder)
            [
              'confidentialTransfer(address,bytes32,bytes)'
            ](recipient.address, encryptedInput.handles[0], encryptedInput.inputProof),
        )
          .to.be.revertedWithCustomError(wrapper, 'UnderlyingDenyListedAddress')
          .withArgs(recipient.address);
      });
    });

    describe('Unwrap', function () {
      it('reverts when `to` is flagged by underlying denylist', async function () {
        const balance = await wrapper.confidentialBalanceOf(holder.address);
        await token.setDenyListed(recipient.address, true);
        await expect(wrapper.connect(holder).unwrap(holder.address, recipient.address, balance))
          .to.be.revertedWithCustomError(wrapper, 'UnderlyingDenyListedAddress')
          .withArgs(recipient.address);
      });

      it('reverts when `from` is flagged by underlying denylist (caught in _update)', async function () {
        const balance = await wrapper.confidentialBalanceOf(holder.address);
        await token.setDenyListed(holder.address, true);
        await expect(wrapper.connect(holder).unwrap(holder.address, holder.address, balance))
          .to.be.revertedWithCustomError(wrapper, 'UnderlyingDenyListedAddress')
          .withArgs(holder.address);
      });
    });

    describe('finalizeUnwrap', function () {
      it('reverts when requester is flagged by underlying denylist between unwrap and finalization', async function () {
        const balance = await wrapper.confidentialBalanceOf(holder.address);
        await wrapper.connect(holder).unwrap(holder.address, holder.address, balance);
        const event = (await wrapper.queryFilter(wrapper.filters.UnwrapRequested()))[0];
        const unwrapRequestId = event.args[1];
        await token.setDenyListed(holder.address, true);
        await expect(wrapper.connect(holder).finalizeUnwrap(unwrapRequestId, 0, '0x'))
          .to.be.revertedWithCustomError(wrapper, 'UnderlyingDenyListedAddress')
          .withArgs(holder.address);
      });
    });
  });

  describe('Underlying DenyList — Admin', function () {
    describe('getUnderlyingDenyListSelector', function () {
      it('returns (true, selector) when a selector is configured', async function () {
        const token: any = await ethers.deployContract('ERC20MockCUSDC');
        const wrapper = await deployV3(token.target as string, SELECTOR_CUSDC, true);
        const [isSet, selector] = await wrapper.getUnderlyingDenyListSelector();
        expect(isSet).to.be.true;
        expect(selector).to.equal(SELECTOR_CUSDC);
      });

      it('returns (false, 0x00000000) when no selector is configured', async function () {
        const token: any = await ethers.deployContract('$ERC20Mock', ['Mock', 'MOCK', 6]);
        const wrapper = await deployV3(token.target as string);
        const [isSet, selector] = await wrapper.getUnderlyingDenyListSelector();
        expect(isSet).to.be.false;
        expect(selector).to.equal('0x00000000');
      });
    });

    describe('setUnderlyingDenyListSelector', function () {
      let wrapper: any;
      let ownerSigner: HardhatEthersSigner;
      let holder: HardhatEthersSigner;
      let outsider: HardhatEthersSigner;
      let token: any;

      beforeEach(async function () {
        [holder, , , outsider] = await ethers.getSigners();
        ownerSigner = await ethers.getSigner(owner);
        token = await ethers.deployContract('ERC20MockCUSDC');
        wrapper = await deployV3(token.target as string);
        await token.mint(holder.address, ethers.parseUnits('100', 6));
        await token.connect(holder).approve(wrapper.target, ethers.MaxUint256);
      });

      it('activates the underlying check and emits UnderlyingDenyListSelectorUpdated', async function () {
        await expect(wrapper.connect(ownerSigner).setUnderlyingDenyListSelector(true, SELECTOR_CUSDC))
          .to.emit(wrapper, 'UnderlyingDenyListSelectorUpdated')
          .withArgs(SELECTOR_CUSDC, true);

        const [isSet, selector] = await wrapper.getUnderlyingDenyListSelector();
        expect(isSet).to.be.true;
        expect(selector).to.equal(SELECTOR_CUSDC);
      });

      it('blocking is enforced after activating the underlying check', async function () {
        await wrapper.connect(ownerSigner).setUnderlyingDenyListSelector(true, SELECTOR_CUSDC);
        await token.setDenyListed(holder.address, true);
        await expect(wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6)))
          .to.be.revertedWithCustomError(wrapper, 'UnderlyingDenyListedAddress')
          .withArgs(holder.address);
      });

      it('deactivates the underlying check by setting a zero selector with isSet false', async function () {
        await wrapper.connect(ownerSigner).setUnderlyingDenyListSelector(true, SELECTOR_CUSDC);
        await token.setDenyListed(holder.address, true);
        await expect(wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6))).to.be.reverted;

        await wrapper.connect(ownerSigner).setUnderlyingDenyListSelector(false, '0x00000000');
        await expect(wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6))).not.to.be.reverted;
      });

      it('reverts with NonZeroSelectorRequiresIsSet when a non-zero selector is paired with isSet false', async function () {
        await expect(wrapper.connect(ownerSigner).setUnderlyingDenyListSelector(false, SELECTOR_CUSDC))
          .to.be.revertedWithCustomError(wrapper, 'NonZeroSelectorRequiresIsSet')
          .withArgs(SELECTOR_CUSDC);
      });

      it('reverts with UnderlyingDenyListSelectorAlreadySet when the same (selector, isSet) pair is re-sent', async function () {
        await wrapper.connect(ownerSigner).setUnderlyingDenyListSelector(true, SELECTOR_CUSDC);
        await expect(wrapper.connect(ownerSigner).setUnderlyingDenyListSelector(true, SELECTOR_CUSDC))
          .to.be.revertedWithCustomError(wrapper, 'UnderlyingDenyListSelectorAlreadySet')
          .withArgs(SELECTOR_CUSDC, true);
      });

      it('changes the selector to a different one', async function () {
        await wrapper.connect(ownerSigner).setUnderlyingDenyListSelector(true, SELECTOR_CUSDT);
        const [isSet, selector] = await wrapper.getUnderlyingDenyListSelector();
        expect(isSet).to.be.true;
        expect(selector).to.equal(SELECTOR_CUSDT);
      });

      it('reverts for non-owner', async function () {
        await expect(wrapper.connect(outsider).setUnderlyingDenyListSelector(true, SELECTOR_CUSDC))
          .to.be.revertedWithCustomError(wrapper, 'OwnableUnauthorizedAccount')
          .withArgs(outsider.address);
      });
    });
  });
});
