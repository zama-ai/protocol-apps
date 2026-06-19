import { expect } from 'chai';
import hre from 'hardhat';
import { deployConfidentialWrapper } from '../../utils/confidentialWrapper';

describe('ConfidentialWrapper Fresh Deploy', function () {
  const WRAPPER_NAME = 'Fresh Deploy Test Wrapper';
  const WRAPPER_SYMBOL = 'cFRESH';
  const CONTRACT_URI =
    'data:application/json;utf8,{"name":"Fresh Deploy Test Wrapper","symbol":"cFRESH","description":"Test wrapper for fresh deploy"}';

  before(async function () {
    const [deployer] = await hre.ethers.getSigners();
    this.owner = deployer.address;
    this.deployer = deployer;

    const erc20Factory = await hre.ethers.getContractFactory('ERC20Mock');
    const underlying = await erc20Factory.deploy('Test Token', 'TEST', 6);
    await underlying.waitForDeployment();
    this.underlyingAddress = await underlying.getAddress();
  });

  describe('ConfidentialWrapper fresh deploy with current state', function () {
    it('sets base + current state and locks reinitializers', async function () {
      const blockedAddresses = Array.from({ length: 5 }, () =>
        hre.ethers.getAddress(hre.ethers.hexlify(hre.ethers.randomBytes(20))),
      );
      const SELECTOR_CUSDC = '0xfe575a87';

      const denyList = await hre.ethers.deployContract('MockConfidentialWrapperDenyList');
      await denyList.waitForDeployment();
      const registryAddress = await denyList.getAddress();

      const wrapper = await deployConfidentialWrapper(this.underlyingAddress, {
        name: WRAPPER_NAME,
        symbol: WRAPPER_SYMBOL,
        contractUri: CONTRACT_URI,
        owner: this.owner,
        blockedUsers: blockedAddresses,
        underlyingDenyListSelector: SELECTOR_CUSDC,
        hasUnderlyingDenyListSelector: true,
        confidentialWrapperDenyList: registryAddress,
      });

      // Base state is fully initialized
      expect(await wrapper.name()).to.equal(WRAPPER_NAME);
      expect(await wrapper.symbol()).to.equal(WRAPPER_SYMBOL);
      expect(await wrapper.contractURI()).to.equal(CONTRACT_URI);
      expect(await wrapper.owner()).to.equal(this.owner);
      expect(await wrapper.underlying()).to.equal(this.underlyingAddress);

      // Current state is initialized with provided values
      for (const address of blockedAddresses) {
        expect(await wrapper.isBlocked(address)).to.be.true;
      }
      const [isSet, selector] = await wrapper.getUnderlyingDenyListSelector();
      expect(isSet).to.be.true;
      expect(selector).to.equal(SELECTOR_CUSDC);

      // The centralized registry is wired and contributes to blocking
      expect(await wrapper.confidentialWrapperDenyList()).to.equal(registryAddress);
      const registryDenied = hre.ethers.getAddress(hre.ethers.hexlify(hre.ethers.randomBytes(20)));
      expect(await wrapper.isBlocked(registryDenied)).to.be.false;
      await denyList.addToDenyList([registryDenied]);
      expect(await wrapper.isBlocked(registryDenied)).to.be.true;

      // Current reinitializer is locked and cannot replay
      await expect(
        wrapper.connect(this.deployer).reinitializeV4(hre.ethers.ZeroAddress),
      ).to.be.revertedWithCustomError(wrapper, 'InvalidInitialization');
    });
  });
});
