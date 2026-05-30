
import { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { FunctionFragment, Interface } from 'ethers';
import { ethers, fhevm, upgrades } from 'hardhat';
import { getRequiredEnvVar } from '../tasks/utils/loadVariables';

const name = getRequiredEnvVar('CONFIDENTIAL_WRAPPER_NAME_0');
const symbol = getRequiredEnvVar('CONFIDENTIAL_WRAPPER_SYMBOL_0');
const uri = getRequiredEnvVar('CONFIDENTIAL_WRAPPER_CONTRACT_URI_0');
const owner = getRequiredEnvVar('CONFIDENTIAL_WRAPPER_OWNER_ADDRESS_0');

const BLOCKED_ADDRESSES = Array.from({ length: 5 }, () =>
  ethers.getAddress(ethers.hexlify(ethers.randomBytes(20))),
);

const SELECTOR_CUSDC = '0xfe575a87';
const SELECTOR_CUSDT = '0x59bf1abe';
const SELECTOR_TGBP  = '0x97f735d5';
const SELECTOR_XAUT  = '0xfbac3951';

const V3_IFACE = new Interface(['function reinitializeV3(address[], bytes4, bool)']);

async function deployV3(
  token: string,
  selector = '0x00000000',
  hasSelector = false,
  blockedUsers: string[] = [],
) {
  const ownerSigner = await ethers.getSigner(owner);

  const v1Factory = await ethers.getContractFactory('ConfidentialWrapper');
  const proxy = await upgrades.deployProxy(v1Factory, [name, symbol, uri, token, owner], {
    initializer: 'initialize',
    kind: 'uups',
  });
  await proxy.waitForDeployment();
  const proxyAddress = await proxy.getAddress();

  const v2Impl = await ethers.deployContract('ConfidentialWrapperV2');
  await v2Impl.waitForDeployment();
  const v2Selector = FunctionFragment.from('reinitializeV2()').selector;
  await proxy.connect(ownerSigner).upgradeToAndCall(await v2Impl.getAddress(), v2Selector);

  const v3Impl = await ethers.deployContract('ConfidentialWrapperV3');
  await v3Impl.waitForDeployment();
  const v3Calldata = V3_IFACE.encodeFunctionData('reinitializeV3', [blockedUsers, selector, hasSelector]);
  await proxy.connect(ownerSigner).upgradeToAndCall(await v3Impl.getAddress(), v3Calldata);

  return ethers.getContractAt('ConfidentialWrapperV3', proxyAddress);
}

async function prepareV2ProxyForV3Upgrade(token: string) {
  const ownerSigner = await ethers.getSigner(owner);

  const v1Factory = await ethers.getContractFactory('ConfidentialWrapper');
  const proxy = await upgrades.deployProxy(v1Factory, [name, symbol, uri, token, owner], {
    initializer: 'initialize',
    kind: 'uups',
  });
  await proxy.waitForDeployment();

  const v2Impl = await ethers.deployContract('ConfidentialWrapperV2');
  await v2Impl.waitForDeployment();
  const v2Selector = FunctionFragment.from('reinitializeV2()').selector;
  await proxy.connect(ownerSigner).upgradeToAndCall(await v2Impl.getAddress(), v2Selector);

  const v3Impl = await ethers.deployContract('ConfidentialWrapperV3');
  await v3Impl.waitForDeployment();

  return { proxy, v3Impl, ownerSigner };
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
        await expect(wrapper.connect(ownerSigner).blockUser(target))
          .to.emit(wrapper, 'UserBlocked').withArgs(target);
        expect(await wrapper.isBlocked(target)).to.be.true;
      });

      it('reverts for zero address', async function () {
        await expect(wrapper.connect(ownerSigner).blockUser(ethers.ZeroAddress))
          .to.be.revertedWithCustomError(wrapper, 'CannotBlockNullAddress');
      });

      it('reverts when user is already blocked', async function () {
        const target = BLOCKED_ADDRESSES[0];
        await wrapper.connect(ownerSigner).blockUser(target);
        await expect(wrapper.connect(ownerSigner).blockUser(target))
          .to.be.revertedWithCustomError(wrapper, 'UserAlreadyBlocked').withArgs(target);
      });

      it('reverts for non-owner', async function () {
        await expect(wrapper.connect(outsider).blockUser(BLOCKED_ADDRESSES[0]))
          .to.be.revertedWithCustomError(wrapper, 'OwnableUnauthorizedAccount').withArgs(outsider.address);
      });
    });

    describe('unblockUser', function () {
      it('removes user from denylist and emits UserUnblocked', async function () {
        const target = BLOCKED_ADDRESSES[0];
        await wrapper.connect(ownerSigner).blockUser(target);
        await expect(wrapper.connect(ownerSigner).unblockUser(target))
          .to.emit(wrapper, 'UserUnblocked').withArgs(target);
        expect(await wrapper.isBlocked(target)).to.be.false;
      });

      it('reverts when user is not blocked', async function () {
        await expect(wrapper.connect(ownerSigner).unblockUser(BLOCKED_ADDRESSES[0]))
          .to.be.revertedWithCustomError(wrapper, 'UserAlreadyUnblocked').withArgs(BLOCKED_ADDRESSES[0]);
      });

      it('reverts for non-owner', async function () {
        const target = BLOCKED_ADDRESSES[0];
        await wrapper.connect(ownerSigner).blockUser(target);
        await expect(wrapper.connect(outsider).unblockUser(target))
          .to.be.revertedWithCustomError(wrapper, 'OwnableUnauthorizedAccount').withArgs(outsider.address);
      });
    });

    describe('isBlocked', function () {
      it('returns false for all addresses before any are blocked', async function () {
        for (const addr of BLOCKED_ADDRESSES) {
          expect(await wrapper.isBlocked(addr)).to.be.false;
        }
      });

      it('blocks and unblocks all five addresses independently', async function () {
        for (const addr of BLOCKED_ADDRESSES) {
          await wrapper.connect(ownerSigner).blockUser(addr);
          expect(await wrapper.isBlocked(addr)).to.be.true;
        }
        for (const addr of BLOCKED_ADDRESSES) {
          await wrapper.connect(ownerSigner).unblockUser(addr);
          expect(await wrapper.isBlocked(addr)).to.be.false;
        }
      });
    });
  });

  describe('reinitializeV3 initialization', function () {
    it('blocks addresses passed in the blockedUsers array', async function () {
      const token = await ethers.deployContract('$ERC20Mock', ['Mock', 'MOCK', 6]);
      const seeds = [BLOCKED_ADDRESSES[0], BLOCKED_ADDRESSES[1]];
      const wrapper = await deployV3(token.target as string, '0x00000000', false, seeds);
      expect(await wrapper.isBlocked(seeds[0])).to.be.true;
      expect(await wrapper.isBlocked(seeds[1])).to.be.true;
      expect(await wrapper.isBlocked(BLOCKED_ADDRESSES[2])).to.be.false;
    });

    it('emits UserBlocked events for seeded addresses during upgrade', async function () {
      const token = await ethers.deployContract('$ERC20Mock', ['Mock', 'MOCK', 6]);
      const { proxy, v3Impl, ownerSigner } = await prepareV2ProxyForV3Upgrade(token.target as string);
      const wrapperV3 = await ethers.getContractAt('ConfidentialWrapperV3', await proxy.getAddress());
      const seeds = [BLOCKED_ADDRESSES[0], BLOCKED_ADDRESSES[1]];
      const v3Calldata = V3_IFACE.encodeFunctionData('reinitializeV3', [seeds, '0x00000000', false]);
      await expect(proxy.connect(ownerSigner).upgradeToAndCall(await v3Impl.getAddress(), v3Calldata))
        .to.emit(wrapperV3, 'UserBlocked').withArgs(seeds[0])
        .to.emit(wrapperV3, 'UserBlocked').withArgs(seeds[1]);
    });

    it('reverts upgrade when blockedUsers contains address(0)', async function () {
      const token = await ethers.deployContract('$ERC20Mock', ['Mock', 'MOCK', 6]);
      const { proxy, v3Impl, ownerSigner } = await prepareV2ProxyForV3Upgrade(token.target as string);
      const v3Calldata = V3_IFACE.encodeFunctionData('reinitializeV3', [[ethers.ZeroAddress], '0x00000000', false]);
      await expect(proxy.connect(ownerSigner).upgradeToAndCall(await v3Impl.getAddress(), v3Calldata))
        .to.be.revertedWithCustomError(v3Impl, 'CannotBlockNullAddress');
    });

    it('reverts upgrade when blockedUsers contains duplicate addresses', async function () {
      const token = await ethers.deployContract('$ERC20Mock', ['Mock', 'MOCK', 6]);
      const { proxy, v3Impl, ownerSigner } = await prepareV2ProxyForV3Upgrade(token.target as string);
      const dup = BLOCKED_ADDRESSES[0];
      const v3Calldata = V3_IFACE.encodeFunctionData('reinitializeV3', [[dup, dup], '0x00000000', false]);
      await expect(proxy.connect(ownerSigner).upgradeToAndCall(await v3Impl.getAddress(), v3Calldata))
        .to.be.revertedWithCustomError(v3Impl, 'UserAlreadyBlocked').withArgs(dup);
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
          .to.be.revertedWithCustomError(wrapper, 'BlockedUser').withArgs(holder.address);
      });

      it('reverts via transferFrom when recipient is blocked', async function () {
        await wrapper.connect(ownerSigner).blockUser(recipient.address);
        await expect(wrapper.connect(holder).wrap(recipient.address, ethers.parseUnits('100', 6)))
          .to.be.revertedWithCustomError(wrapper, 'BlockedUser').withArgs(recipient.address);
      });

      it('reverts via ERC-1363 callback when sender is blocked', async function () {
        await wrapper.connect(ownerSigner).blockUser(holder.address);
        await expect(token.connect(holder).transferAndCall(wrapper.target, ethers.parseUnits('100', 6)))
          .to.be.revertedWithCustomError(wrapper, 'BlockedUser').withArgs(holder.address);
      });

      it('reverts via ERC-1363 callback when recipient is blocked', async function () {
        await wrapper.connect(ownerSigner).blockUser(recipient.address);
        await expect(
          token.connect(holder)['transferAndCall(address,uint256,bytes)'](
            wrapper.target,
            ethers.parseUnits('100', 6),
            ethers.solidityPacked(['address'], [recipient.address]),
          ),
        ).to.be.revertedWithCustomError(wrapper, 'BlockedUser').withArgs(recipient.address);
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
            .to.be.revertedWithCustomError(wrapper, 'BlockedUser').withArgs(recipient.address);
        });

        it('reverts when `from` is blocked (caught in _update)', async function () {
          const balance = await wrapper.confidentialBalanceOf(holder.address);
          await wrapper.connect(ownerSigner).blockUser(holder.address);
          await expect(wrapper.connect(holder).unwrap(holder.address, holder.address, balance))
            .to.be.revertedWithCustomError(wrapper, 'BlockedUser').withArgs(holder.address);
        });

        it('reverts when operator is blocked', async function () {
          const balance = await wrapper.confidentialBalanceOf(holder.address);
          const until = BigInt(Math.floor(Date.now() / 1000) + 3600);
          await wrapper.connect(holder).setOperator(operator.address, until);
          await wrapper.connect(ownerSigner).blockUser(operator.address);
          await expect(wrapper.connect(operator).unwrap(holder.address, holder.address, balance))
            .to.be.revertedWithCustomError(wrapper, 'BlockedUser').withArgs(operator.address);
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
            wrapper.connect(holder)['unwrap(address,address,bytes32,bytes)'](
              holder.address, recipient.address, encryptedInput.handles[0], encryptedInput.inputProof,
            ),
          ).to.be.revertedWithCustomError(wrapper, 'BlockedUser').withArgs(recipient.address);
        });

        it(`reverts when 'from' is blocked (caught in _update)`, async function () {
          const encryptedInput = await fhevm
            .createEncryptedInput(wrapper.target, holder.address)
            .add64(ethers.parseUnits('10', 6))
            .encrypt();
          await wrapper.connect(ownerSigner).blockUser(holder.address);
          await expect(
            wrapper.connect(holder)['unwrap(address,address,bytes32,bytes)'](
              holder.address, recipient.address, encryptedInput.handles[0], encryptedInput.inputProof,
            ),
          ).to.be.revertedWithCustomError(wrapper, 'BlockedUser').withArgs(holder.address);
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
            wrapper.connect(operator)['unwrap(address,address,bytes32,bytes)'](
              holder.address, holder.address, encryptedInput.handles[0], encryptedInput.inputProof,
            ),
          ).to.be.revertedWithCustomError(wrapper, 'BlockedUser').withArgs(operator.address);
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
          .to.be.revertedWithCustomError(wrapper, 'BlockedUser').withArgs(holder.address);
      });
    });

    describe('Confidential Transfer', function () {
      beforeEach(async function () {
        await wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6));
      });

      it('reverts when sender is blocked', async function () {
        const encryptedInput = await fhevm
          .createEncryptedInput(wrapper.target, holder.address).add64(ethers.parseUnits('10', 6)).encrypt();
        await wrapper.connect(ownerSigner).blockUser(holder.address);
        await expect(
          wrapper.connect(holder)['confidentialTransfer(address,bytes32,bytes)'](
            recipient.address, encryptedInput.handles[0], encryptedInput.inputProof,
          ),
        ).to.be.revertedWithCustomError(wrapper, 'BlockedUser').withArgs(holder.address);
      });

      it('reverts when recipient is blocked', async function () {
        const encryptedInput = await fhevm
          .createEncryptedInput(wrapper.target, holder.address).add64(ethers.parseUnits('10', 6)).encrypt();
        await wrapper.connect(ownerSigner).blockUser(recipient.address);
        await expect(
          wrapper.connect(holder)['confidentialTransfer(address,bytes32,bytes)'](
            recipient.address, encryptedInput.handles[0], encryptedInput.inputProof,
          ),
        ).to.be.revertedWithCustomError(wrapper, 'BlockedUser').withArgs(recipient.address);
      });

      it('reverts when a blocked operator calls on behalf of non-blocked parties', async function () {
        const until = BigInt(Math.floor(Date.now() / 1000) + 3600);
        await wrapper.connect(holder).setOperator(operator.address, until);
        const encryptedInput = await fhevm
          .createEncryptedInput(wrapper.target, operator.address).add64(ethers.parseUnits('10', 6)).encrypt();
        await wrapper.connect(ownerSigner).blockUser(operator.address);
        await expect(
          wrapper.connect(operator)['confidentialTransferFrom(address,address,bytes32,bytes)'](
            holder.address, recipient.address, encryptedInput.handles[0], encryptedInput.inputProof,
          ),
        ).to.be.revertedWithCustomError(wrapper, 'BlockedUser').withArgs(operator.address);
      });
    });

    describe('confidentialTransferAndCall', function () {
      beforeEach(async function () {
        await wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6));
      });

      it('reverts when sender is blocked', async function () {
        const encryptedInput = await fhevm
          .createEncryptedInput(wrapper.target, holder.address).add64(ethers.parseUnits('10', 6)).encrypt();
        await wrapper.connect(ownerSigner).blockUser(holder.address);
        await expect(
          wrapper.connect(holder)['confidentialTransferAndCall(address,bytes32,bytes,bytes)'](
            recipient.address, encryptedInput.handles[0], encryptedInput.inputProof, '0x',
          ),
        ).to.be.revertedWithCustomError(wrapper, 'BlockedUser').withArgs(holder.address);
      });

      it('reverts when recipient is blocked', async function () {
        const encryptedInput = await fhevm
          .createEncryptedInput(wrapper.target, holder.address).add64(ethers.parseUnits('10', 6)).encrypt();
        await wrapper.connect(ownerSigner).blockUser(recipient.address);
        await expect(
          wrapper.connect(holder)['confidentialTransferAndCall(address,bytes32,bytes,bytes)'](
            recipient.address, encryptedInput.handles[0], encryptedInput.inputProof, '0x',
          ),
        ).to.be.revertedWithCustomError(wrapper, 'BlockedUser').withArgs(recipient.address);
      });
    });

    describe('confidentialTransferFromAndCall', function () {
      beforeEach(async function () {
        await wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6));
        const until = BigInt(Math.floor(Date.now() / 1000) + 3600);
        await wrapper.connect(holder).setOperator(operator.address, until);
      });

      it('reverts when operator is blocked', async function () {
        const encryptedInput = await fhevm
          .createEncryptedInput(wrapper.target, operator.address).add64(ethers.parseUnits('10', 6)).encrypt();
        await wrapper.connect(ownerSigner).blockUser(operator.address);
        await expect(
          wrapper.connect(operator)['confidentialTransferFromAndCall(address,address,bytes32,bytes,bytes)'](
            holder.address, recipient.address, encryptedInput.handles[0], encryptedInput.inputProof, '0x',
          ),
        ).to.be.revertedWithCustomError(wrapper, 'BlockedUser').withArgs(operator.address);
      });

      it('reverts when sender (from) is blocked', async function () {
        const encryptedInput = await fhevm
          .createEncryptedInput(wrapper.target, operator.address).add64(ethers.parseUnits('10', 6)).encrypt();
        await wrapper.connect(ownerSigner).blockUser(holder.address);
        await expect(
          wrapper.connect(operator)['confidentialTransferFromAndCall(address,address,bytes32,bytes,bytes)'](
            holder.address, recipient.address, encryptedInput.handles[0], encryptedInput.inputProof, '0x',
          ),
        ).to.be.revertedWithCustomError(wrapper, 'BlockedUser').withArgs(holder.address);
      });

      it('reverts when recipient is blocked', async function () {
        const encryptedInput = await fhevm
          .createEncryptedInput(wrapper.target, operator.address).add64(ethers.parseUnits('10', 6)).encrypt();
        await wrapper.connect(ownerSigner).blockUser(recipient.address);
        await expect(
          wrapper.connect(operator)['confidentialTransferFromAndCall(address,address,bytes32,bytes,bytes)'](
            holder.address, recipient.address, encryptedInput.handles[0], encryptedInput.inputProof, '0x',
          ),
        ).to.be.revertedWithCustomError(wrapper, 'BlockedUser').withArgs(recipient.address);
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
        .to.be.revertedWithCustomError(wrapper, 'UnderlyingDenyListedAddress').withArgs(holder.address);
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
        .to.be.revertedWithCustomError(wrapper, 'UnderlyingDenyListedAddress').withArgs(holder.address);
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
        .to.be.revertedWithCustomError(wrapper, 'UnderlyingDenyListedAddress').withArgs(holder.address);
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
        .to.be.revertedWithCustomError(wrapper, 'UnderlyingDenyListedAddress').withArgs(holder.address);
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
      await expect(wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6)))
        .to.be.revertedWithCustomError(wrapper, 'UnderlyingDenyListCallFailed');
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
      await expect(wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6)))
        .to.be.revertedWithCustomError(wrapper, 'InvalidUnderlyingDenyListResponse');
    });
  });

  describe('Underlying DenyList — invalid selector (UnderlyingDenyListCallFailed)', function () {
    it('reverts wrap when configured selector does not exist on the underlying token', async function () {
      const [holder] = await ethers.getSigners();
      const token: any = await ethers.deployContract('ERC20MockCUSDC');
      const wrapper = await deployV3(token.target as string, '0xdeadbeef', true);
      await token.mint(holder.address, ethers.parseUnits('100', 6));
      await token.connect(holder).approve(wrapper.target, ethers.MaxUint256);
      await expect(wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6)))
        .to.be.revertedWithCustomError(wrapper, 'UnderlyingDenyListCallFailed');
    });
  });

  describe('Underlying DenyList — hasSelector = false bypasses underlying check', function () {
    it('allows wrap even when underlying would return blacklisted = true', async function () {
      const [holder] = await ethers.getSigners();
      const token: any = await ethers.deployContract('ERC20MockCUSDC');
      const wrapper = await deployV3(token.target as string, SELECTOR_CUSDC, false);
      await token.mint(holder.address, ethers.parseUnits('100', 6));
      await token.connect(holder).approve(wrapper.target, ethers.MaxUint256);
      await token.setDenyListed(holder.address, true);
      await expect(wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6))).not.to.be.reverted;
    });
  });

  describe('Underlying DenyList — local block list checked before underlying', function () {
    it('reverts with BlockedUser (not UnderlyingDenyListedAddress) when user is on both lists', async function () {
      const [holder] = await ethers.getSigners();
      const ownerSigner = await ethers.getSigner(owner);
      const token: any = await ethers.deployContract('ERC20MockCUSDC');
      const wrapper = await deployV3(token.target as string, SELECTOR_CUSDC, true);
      await token.mint(holder.address, ethers.parseUnits('100', 6));
      await token.connect(holder).approve(wrapper.target, ethers.MaxUint256);
      await wrapper.connect(ownerSigner).blockUser(holder.address);
      await token.setDenyListed(holder.address, true);
      await expect(wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6)))
        .to.be.revertedWithCustomError(wrapper, 'BlockedUser').withArgs(holder.address);
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
          .createEncryptedInput(wrapper.target, holder.address).add64(ethers.parseUnits('10', 6)).encrypt();
        await token.setDenyListed(holder.address, true);
        await expect(
          wrapper.connect(holder)['confidentialTransfer(address,bytes32,bytes)'](
            recipient.address, encryptedInput.handles[0], encryptedInput.inputProof,
          ),
        ).to.be.revertedWithCustomError(wrapper, 'UnderlyingDenyListedAddress').withArgs(holder.address);
      });

      it('reverts when recipient is flagged by underlying denylist', async function () {
        const encryptedInput = await fhevm
          .createEncryptedInput(wrapper.target, holder.address).add64(ethers.parseUnits('10', 6)).encrypt();
        await token.setDenyListed(recipient.address, true);
        await expect(
          wrapper.connect(holder)['confidentialTransfer(address,bytes32,bytes)'](
            recipient.address, encryptedInput.handles[0], encryptedInput.inputProof,
          ),
        ).to.be.revertedWithCustomError(wrapper, 'UnderlyingDenyListedAddress').withArgs(recipient.address);
      });
    });

    describe('Unwrap', function () {
      it('reverts when `to` is flagged by underlying denylist', async function () {
        const balance = await wrapper.confidentialBalanceOf(holder.address);
        await token.setDenyListed(recipient.address, true);
        await expect(wrapper.connect(holder).unwrap(holder.address, recipient.address, balance))
          .to.be.revertedWithCustomError(wrapper, 'UnderlyingDenyListedAddress').withArgs(recipient.address);
      });

      it('reverts when `from` is flagged by underlying denylist (caught in _update)', async function () {
        const balance = await wrapper.confidentialBalanceOf(holder.address);
        await token.setDenyListed(holder.address, true);
        await expect(wrapper.connect(holder).unwrap(holder.address, holder.address, balance))
          .to.be.revertedWithCustomError(wrapper, 'UnderlyingDenyListedAddress').withArgs(holder.address);
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
          .to.be.revertedWithCustomError(wrapper, 'UnderlyingDenyListedAddress').withArgs(holder.address);
      });
    });
  });
});
