import { FhevmType } from '@fhevm/hardhat-plugin';
import { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers, fhevm } from 'hardhat';
import { getAclAddress } from './utils/accounts';
import { DEFAULT_WRAPPER_OWNER, deployConfidentialWrapper } from './utils/confidentialWrapper';

const owner = DEFAULT_WRAPPER_OWNER;
const WILDCARD_CONTRACT = '0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF';
const MAX_UINT64 = (1n << 64n) - 1n;

async function getAclContract() {
  return ethers.getContractAt(
    [
      'event DelegatedForUserDecryption(address indexed delegator, address indexed delegate, address contractAddress, uint64 delegationCounter, uint64 oldExpirationDate, uint64 newExpirationDate)',
      'event RevokedDelegationForUserDecryption(address indexed delegator, address indexed delegate, address contractAddress, uint64 delegationCounter, uint64 oldExpirationDate)',
      'function getUserDecryptionDelegationExpirationDate(address delegator, address delegate, address contractAddress) view returns (uint64)',
    ],
    await getAclAddress(),
  );
}

async function expectWildcardDelegation(wrapper: any, observer: string, expectedExpiration: bigint) {
  const acl = await getAclContract();
  expect(
    await acl.getUserDecryptionDelegationExpirationDate(await wrapper.getAddress(), observer, WILDCARD_CONTRACT),
  ).to.equal(expectedExpiration);
}

async function delegatedDecryptEuint64(wrapper: any, delegator: any, delegate: HardhatEthersSigner, handle: string) {
  const wrapperAddress = await wrapper.getAddress();
  const keypair = fhevm.generateKeypair();
  const startTimestamp = Math.floor(Date.now() / 1000);
  const durationDays = 1;
  const eip712 = fhevm.createDelegatedUserDecryptEIP712(
    keypair.publicKey,
    [wrapperAddress],
    await delegator.getAddress(),
    startTimestamp,
    durationDays,
  );
  const signature = await delegate.signTypedData(
    eip712.domain,
    { [eip712.primaryType]: eip712.types[eip712.primaryType] },
    eip712.message,
  );
  const results = await fhevm.delegatedUserDecrypt(
    [{ handle, contractAddress: wrapperAddress, fhevmType: FhevmType.euint64 }],
    keypair.privateKey,
    keypair.publicKey,
    signature,
    [wrapperAddress],
    await delegator.getAddress(),
    delegate.address,
    startTimestamp,
    durationDays,
  );
  return results[handle] as bigint;
}

describe('ConfidentialWrapper Observers', function () {
  let token: any;
  let wrapper: any;
  let ownerSigner: HardhatEthersSigner;
  let holder: HardhatEthersSigner;
  let observerA: HardhatEthersSigner;
  let observerB: HardhatEthersSigner;
  let observerC: HardhatEthersSigner;
  let outsider: HardhatEthersSigner;

  beforeEach(async function () {
    [holder, observerA, observerB, observerC, outsider] = await ethers.getSigners();
    ownerSigner = await ethers.getSigner(owner);
    token = await ethers.deployContract('$ERC20Mock', ['Mock Token', 'MOCK', 6]);
    wrapper = await deployConfidentialWrapper(token.target as string);

    await token.$_mint(holder.address, ethers.parseUnits('1000', 6));
    await token.connect(holder).approve(wrapper.target, ethers.MaxUint256);
  });

  describe('initial observers', function () {
    it('seeds multiple observers during initialization and delegates wildcard access to each one', async function () {
      const seeded = await deployConfidentialWrapper(token.target as string, {
        initialObservers: [observerA.address, observerB.address],
      });

      expect(await seeded.observerCount()).to.equal(2);
      expect(await seeded.observerAt(0)).to.equal(observerA.address);
      expect(await seeded.observerAt(1)).to.equal(observerB.address);
      expect(await seeded.observers()).to.deep.equal([observerA.address, observerB.address]);
      expect(await seeded.isObserver(observerA.address)).to.equal(true);
      expect(await seeded.isObserver(observerB.address)).to.equal(true);
      expect(await seeded.isObserver(observerC.address)).to.equal(false);

      await expectWildcardDelegation(seeded, observerA.address, MAX_UINT64);
      await expectWildcardDelegation(seeded, observerB.address, MAX_UINT64);

      const events = await seeded.queryFilter(seeded.filters.ObserverAdded());
      expect(events.map((event: any) => event.args[0])).to.deep.equal([observerA.address, observerB.address]);
    });

    it('reverts when initial observers contains a duplicate address', async function () {
      const factory = await ethers.getContractFactory('ConfidentialWrapper');
      await expect(
        deployConfidentialWrapper(token.target as string, {
          initialObservers: [observerA.address, observerA.address],
        }),
      )
        .to.be.revertedWithCustomError(factory, 'ObserverAlreadyConfigured')
        .withArgs(observerA.address);
    });
  });

  describe('addObserver', function () {
    it('adds one observer, emits ObserverAdded, and creates a persistent wildcard delegation', async function () {
      const acl = await getAclContract();
      const tx = wrapper.connect(ownerSigner).addObserver(observerA.address);

      await expect(tx).to.emit(wrapper, 'ObserverAdded').withArgs(observerA.address);
      await expect(tx)
        .to.emit(acl, 'DelegatedForUserDecryption')
        .withArgs(await wrapper.getAddress(), observerA.address, WILDCARD_CONTRACT, 1n, 0n, MAX_UINT64);

      expect(await wrapper.isObserver(observerA.address)).to.equal(true);
      expect(await wrapper.observerCount()).to.equal(1);
      expect(await wrapper.observers()).to.deep.equal([observerA.address]);
      await expectWildcardDelegation(wrapper, observerA.address, MAX_UINT64);
    });

    it('tracks multiple observers independently', async function () {
      await wrapper.connect(ownerSigner).addObserver(observerA.address);
      await wrapper.connect(ownerSigner).addObserver(observerB.address);
      await wrapper.connect(ownerSigner).addObserver(observerC.address);

      expect(await wrapper.observerCount()).to.equal(3);
      expect(await wrapper.observers()).to.deep.equal([observerA.address, observerB.address, observerC.address]);
      await expectWildcardDelegation(wrapper, observerA.address, MAX_UINT64);
      await expectWildcardDelegation(wrapper, observerB.address, MAX_UINT64);
      await expectWildcardDelegation(wrapper, observerC.address, MAX_UINT64);
    });

    it('reverts for duplicate, zero, wrapper, and wildcard observer addresses', async function () {
      await wrapper.connect(ownerSigner).addObserver(observerA.address);
      await expect(wrapper.connect(ownerSigner).addObserver(observerA.address))
        .to.be.revertedWithCustomError(wrapper, 'ObserverAlreadyConfigured')
        .withArgs(observerA.address);
      await expect(wrapper.connect(ownerSigner).addObserver(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(wrapper, 'InvalidObserver')
        .withArgs(ethers.ZeroAddress);
      await expect(wrapper.connect(ownerSigner).addObserver(await wrapper.getAddress()))
        .to.be.revertedWithCustomError(wrapper, 'InvalidObserver')
        .withArgs(await wrapper.getAddress());
      await expect(wrapper.connect(ownerSigner).addObserver(WILDCARD_CONTRACT))
        .to.be.revertedWithCustomError(wrapper, 'InvalidObserver')
        .withArgs(WILDCARD_CONTRACT);
    });

    it('reverts for non-owner callers', async function () {
      await expect(wrapper.connect(outsider).addObserver(observerA.address))
        .to.be.revertedWithCustomError(wrapper, 'OwnableUnauthorizedAccount')
        .withArgs(outsider.address);
    });
  });

  describe('removeObserver', function () {
    beforeEach(async function () {
      await wrapper.connect(ownerSigner).addObserver(observerA.address);
      await wrapper.connect(ownerSigner).addObserver(observerB.address);
    });

    it('removes only the selected observer and revokes their wildcard delegation', async function () {
      const acl = await getAclContract();
      const tx = wrapper.connect(ownerSigner).removeObserver(observerA.address);

      await expect(tx).to.emit(wrapper, 'ObserverRemoved').withArgs(observerA.address);
      await expect(tx)
        .to.emit(acl, 'RevokedDelegationForUserDecryption')
        .withArgs(await wrapper.getAddress(), observerA.address, WILDCARD_CONTRACT, 2n, MAX_UINT64);

      expect(await wrapper.isObserver(observerA.address)).to.equal(false);
      expect(await wrapper.isObserver(observerB.address)).to.equal(true);
      expect(await wrapper.observerCount()).to.equal(1);
      expect(await wrapper.observers()).to.deep.equal([observerB.address]);
      await expectWildcardDelegation(wrapper, observerA.address, 0n);
      await expectWildcardDelegation(wrapper, observerB.address, MAX_UINT64);
    });

    it('reverts for an address that is not currently an observer', async function () {
      await expect(wrapper.connect(ownerSigner).removeObserver(observerC.address))
        .to.be.revertedWithCustomError(wrapper, 'ObserverNotConfigured')
        .withArgs(observerC.address);
    });

    it('reverts for non-owner callers', async function () {
      await expect(wrapper.connect(outsider).removeObserver(observerA.address))
        .to.be.revertedWithCustomError(wrapper, 'OwnableUnauthorizedAccount')
        .withArgs(outsider.address);
    });
  });

  describe('renounceObserver', function () {
    it('lets an observer revoke their own wildcard delegation', async function () {
      await wrapper.connect(ownerSigner).addObserver(observerA.address);

      await expect(wrapper.connect(observerA).renounceObserver())
        .to.emit(wrapper, 'ObserverRemoved')
        .withArgs(observerA.address);

      expect(await wrapper.isObserver(observerA.address)).to.equal(false);
      expect(await wrapper.observerCount()).to.equal(0);
      await expectWildcardDelegation(wrapper, observerA.address, 0n);
    });

    it('reverts when the caller is not an observer', async function () {
      await expect(wrapper.connect(observerA).renounceObserver())
        .to.be.revertedWithCustomError(wrapper, 'ObserverNotConfigured')
        .withArgs(observerA.address);
    });
  });

  describe('delegated decryption behavior', function () {
    it('allows a newly added observer to decrypt historical wrapper handles through wildcard delegation', async function () {
      await wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6));
      const historicalBalance = await wrapper.confidentialBalanceOf(holder.address);

      await wrapper.connect(ownerSigner).addObserver(observerA.address);

      await expect(fhevm.userDecryptEuint(FhevmType.euint64, historicalBalance, wrapper.target, observerA)).to.be
        .rejected;
      await expect(delegatedDecryptEuint64(wrapper, wrapper, observerA, historicalBalance)).to.eventually.equal(
        ethers.parseUnits('100', 6),
      );
    });

    it('allows all configured observers to decrypt future transfer amount handles', async function () {
      await wrapper.connect(ownerSigner).addObserver(observerA.address);
      await wrapper.connect(ownerSigner).addObserver(observerB.address);
      await wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6));

      const event = (await wrapper.queryFilter(wrapper.filters.ConfidentialTransfer())).at(-1)!;
      const mintedAmount = event.args[2];

      await expect(delegatedDecryptEuint64(wrapper, wrapper, observerA, mintedAmount)).to.eventually.equal(
        ethers.parseUnits('100', 6),
      );
      await expect(delegatedDecryptEuint64(wrapper, wrapper, observerB, mintedAmount)).to.eventually.equal(
        ethers.parseUnits('100', 6),
      );
    });

    it('prevents a removed observer from decrypting historical and future handles through the wrapper delegation', async function () {
      await wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('100', 6));
      const historicalBalance = await wrapper.confidentialBalanceOf(holder.address);

      await wrapper.connect(ownerSigner).addObserver(observerA.address);
      await expect(delegatedDecryptEuint64(wrapper, wrapper, observerA, historicalBalance)).to.eventually.equal(
        ethers.parseUnits('100', 6),
      );

      await wrapper.connect(ownerSigner).removeObserver(observerA.address);
      await expect(delegatedDecryptEuint64(wrapper, wrapper, observerA, historicalBalance)).to.be.rejected;

      await wrapper.connect(holder).wrap(holder.address, ethers.parseUnits('25', 6));
      const event = (await wrapper.queryFilter(wrapper.filters.ConfidentialTransfer())).at(-1)!;
      await expect(delegatedDecryptEuint64(wrapper, wrapper, observerA, event.args[2])).to.be.rejected;
    });
  });
});
