import { expect } from 'chai';
import { ethers, upgrades } from 'hardhat';

async function deployDenyList(owner: string) {
  const factory = await ethers.getContractFactory('ConfidentialWrapperDenyList');
  const proxy = await upgrades.deployProxy(factory, [owner], {
    initializer: 'initialize',
    kind: 'uups',
  });
  await proxy.waitForDeployment();
  return ethers.getContractAt('ConfidentialWrapperDenyList', await proxy.getAddress());
}

describe('ConfidentialWrapperDenyList', function () {
  beforeEach(async function () {
    [this.ownerSigner, this.outsider, this.thirdParty] = await ethers.getSigners();
    this.accounts = Array.from({ length: 5 }, () => ethers.getAddress(ethers.hexlify(ethers.randomBytes(20))));
    this.denyList = await deployDenyList(this.ownerSigner.address);
  });

  // ─── Initializer ─────────────────────────────────────────────────────────

  describe('initialize', function () {
    it('sets the owner correctly', async function () {
      expect(await this.denyList.owner()).to.equal(this.ownerSigner.address);
    });

    it('reverts when called a second time', async function () {
      await expect(
        this.denyList.connect(this.ownerSigner).initialize(this.outsider.address),
      ).to.be.revertedWithCustomError(
        this.denyList,
        'InvalidInitialization',
      );
    });
  });

  // ─── name ─────────────────────────────────────────────────────────────────

  describe('name', function () {
    it('returns a non-empty descriptive name', async function () {
      const n = await this.denyList.name();
      expect(n).to.be.a('string').and.have.length.greaterThan(0);
      expect(n).to.equal('Confidential Wrapper DenyList');
    });
  });

  // ─── addToDenyList ────────────────────────────────────────────────────────

  describe('addToDenyList', function () {
    it('denies a single address and emits DeniedAddressesAdded', async function () {
      await expect(this.denyList.connect(this.ownerSigner).addToDenyList([this.accounts[0]]))
        .to.emit(this.denyList, 'DeniedAddressesAdded')
        .withArgs([this.accounts[0]]);
      expect(await this.denyList.isDenied(this.accounts[0])).to.be.true;
    });

    it('denies a batch of addresses and emits DeniedAddressesAdded', async function () {
      const batch = this.accounts.slice(0, 3);
      await expect(this.denyList.connect(this.ownerSigner).addToDenyList(batch))
        .to.emit(this.denyList, 'DeniedAddressesAdded')
        .withArgs(batch);
      for (const addr of batch) {
        expect(await this.denyList.isDenied(addr)).to.be.true;
      }
    });

    it('adding an already-denied address does nothing', async function () {
      await this.denyList.connect(this.ownerSigner).addToDenyList([this.accounts[0]]);
      await expect(this.denyList.connect(this.ownerSigner).addToDenyList([this.accounts[0]])).not.to.be.reverted;
      expect(await this.denyList.isDenied(this.accounts[0])).to.be.true;
    });

    it('accepts an empty array without reverting', async function () {
      await expect(this.denyList.connect(this.ownerSigner).addToDenyList([])).not.to.be.reverted;
    });

    it('reverts for non-owner', async function () {
      await expect(this.denyList.connect(this.outsider).addToDenyList([this.accounts[0]]))
        .to.be.revertedWithCustomError(this.denyList, 'OwnableUnauthorizedAccount')
        .withArgs(this.outsider.address);
    });
  });

  // ─── removeFromDenyList ───────────────────────────────────────────────────

  describe('removeFromDenyList', function () {
    beforeEach(async function () {
      await this.denyList.connect(this.ownerSigner).addToDenyList(this.accounts.slice(0, 3));
    });

    it('removes a single address and emits DeniedAddressesRemoved', async function () {
      await expect(this.denyList.connect(this.ownerSigner).removeFromDenyList([this.accounts[0]]))
        .to.emit(this.denyList, 'DeniedAddressesRemoved')
        .withArgs([this.accounts[0]]);
      expect(await this.denyList.isDenied(this.accounts[0])).to.be.false;
    });

    it('removes a batch of addresses and emits DeniedAddressesRemoved', async function () {
      const batch = this.accounts.slice(0, 3);
      await expect(this.denyList.connect(this.ownerSigner).removeFromDenyList(batch))
        .to.emit(this.denyList, 'DeniedAddressesRemoved')
        .withArgs(batch);
      for (const addr of batch) {
        expect(await this.denyList.isDenied(addr)).to.be.false;
      }
    });

    it('removing a non-denied address does not revert', async function () {
      await expect(this.denyList.connect(this.ownerSigner).removeFromDenyList([this.accounts[4]])).not.to.be.reverted;
      expect(await this.denyList.isDenied(this.accounts[4])).to.be.false;
    });

    it('accepts an empty array without reverting', async function () {
      await expect(this.denyList.connect(this.ownerSigner).removeFromDenyList([])).not.to.be.reverted;
    });

    it('reverts for non-owner', async function () {
      await expect(this.denyList.connect(this.outsider).removeFromDenyList([this.accounts[0]]))
        .to.be.revertedWithCustomError(this.denyList, 'OwnableUnauthorizedAccount')
        .withArgs(this.outsider.address);
    });
  });

  // ─── isDenied ─────────────────────────────────────────────────────────────

  describe('isDenied', function () {
    it('returns false for all addresses before any are denied', async function () {
      for (const addr of this.accounts) {
        expect(await this.denyList.isDenied(addr)).to.be.false;
      }
    });

    it('returns true after adding and false after removing', async function () {
      await this.denyList.connect(this.ownerSigner).addToDenyList([this.accounts[0]]);
      expect(await this.denyList.isDenied(this.accounts[0])).to.be.true;
      await this.denyList.connect(this.ownerSigner).removeFromDenyList([this.accounts[0]]);
      expect(await this.denyList.isDenied(this.accounts[0])).to.be.false;
    });
  });

  // ─── Ownable2Step ─────────────────────────────────────────────────────────

  describe('Ownable2Step', function () {
    it('transfers ownership via a two-step process', async function () {
      await this.denyList.connect(this.ownerSigner).transferOwnership(this.outsider.address);
      expect(await this.denyList.pendingOwner()).to.equal(this.outsider.address);
      expect(await this.denyList.owner()).to.equal(this.ownerSigner.address);

      await this.denyList.connect(this.outsider).acceptOwnership();
      expect(await this.denyList.owner()).to.equal(this.outsider.address);
    });

    it('reverts when non-pending-owner tries to accept', async function () {
      await this.denyList.connect(this.ownerSigner).transferOwnership(this.outsider.address);
      await expect(this.denyList.connect(this.thirdParty).acceptOwnership()).to.be.revertedWithCustomError(
        this.denyList,
        'OwnableUnauthorizedAccount',
      );
    });
  });

  // ─── UUPS upgrade guard ───────────────────────────────────────────────────

  describe('_authorizeUpgrade', function () {
    it('reverts when a non-owner attempts an upgrade', async function () {
      const factory = await ethers.getContractFactory('ConfidentialWrapperDenyList');
      const newImpl = await factory.deploy();
      await newImpl.waitForDeployment();

      await expect(this.denyList.connect(this.outsider).upgradeToAndCall(await newImpl.getAddress(), '0x'))
        .to.be.revertedWithCustomError(this.denyList, 'OwnableUnauthorizedAccount')
        .withArgs(this.outsider.address);
    });
  });
});
