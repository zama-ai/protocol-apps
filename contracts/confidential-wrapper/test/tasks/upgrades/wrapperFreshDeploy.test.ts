import { expect } from 'chai';
import hre from 'hardhat';

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

  describe('ConfidentialWrapper fresh deploy', function () {
    it('initialize() sets base state and locks reinitializer', async function () {
      const v1Factory = await hre.ethers.getContractFactory('ConfidentialWrapper');
      const proxy = await hre.upgrades.deployProxy(
        v1Factory,
        [WRAPPER_NAME, WRAPPER_SYMBOL, CONTRACT_URI, this.underlyingAddress, this.owner],
        { initializer: 'initialize', kind: 'uups' },
      );
      await proxy.waitForDeployment();

      const wrapper = await hre.ethers.getContractAt('ConfidentialWrapper', await proxy.getAddress());

      expect(await wrapper.name()).to.equal(WRAPPER_NAME);
      expect(await wrapper.symbol()).to.equal(WRAPPER_SYMBOL);
      expect(await wrapper.contractURI()).to.equal(CONTRACT_URI);
      expect(await wrapper.owner()).to.equal(this.owner);
      expect(await wrapper.underlying()).to.equal(this.underlyingAddress);

      // initializer(1) is locked — initialize cannot replay
      await expect(
        wrapper
          .connect(this.deployer)
          .initialize(WRAPPER_NAME, WRAPPER_SYMBOL, CONTRACT_URI, this.underlyingAddress, this.owner),
      ).to.be.revertedWithCustomError(wrapper, 'InvalidInitialization');
    });
  });

  describe('ConfidentialWrapperV2 fresh deploy', function () {
    it('initialize() reverts with error message', async function () {
      const v2Factory = await hre.ethers.getContractFactory('ConfidentialWrapperV2');
      await expect(
        hre.upgrades.deployProxy(
          v2Factory,
          [WRAPPER_NAME, WRAPPER_SYMBOL, CONTRACT_URI, this.underlyingAddress, this.owner],
          { initializer: 'initialize', kind: 'uups' },
        ),
      ).to.be.revertedWithCustomError(v2Factory, 'ConfidentialWrapperInvalidInitializerVersion');
    });

    it('initializeV2() sets base state and locks reinitializeV2', async function () {
      const v2Factory = await hre.ethers.getContractFactory('ConfidentialWrapperV2');
      const proxy = await hre.upgrades.deployProxy(
        v2Factory,
        [WRAPPER_NAME, WRAPPER_SYMBOL, CONTRACT_URI, this.underlyingAddress, this.owner],
        { initializer: 'initializeV2', kind: 'uups' },
      );
      await proxy.waitForDeployment();

      const wrapperV2 = await hre.ethers.getContractAt('ConfidentialWrapperV2', await proxy.getAddress());

      // Base state is fully initialized
      expect(await wrapperV2.name()).to.equal(WRAPPER_NAME);
      expect(await wrapperV2.symbol()).to.equal(WRAPPER_SYMBOL);
      expect(await wrapperV2.contractURI()).to.equal(CONTRACT_URI);
      expect(await wrapperV2.owner()).to.equal(this.owner);
      expect(await wrapperV2.underlying()).to.equal(this.underlyingAddress);

      // reinitializer(2) is locked — reinitializeV2 cannot replay
      await expect(wrapperV2.connect(this.deployer).reinitializeV2()).to.be.revertedWithCustomError(
        wrapperV2,
        'InvalidInitialization',
      );
    });
  });

  describe('ConfidentialWrapperV3 fresh deploy', function () {
    it('initializeV3() sets base + V3 state and locks all reinitializers', async function () {
      const blockedAddresses = Array.from({ length: 5 }, () =>
        hre.ethers.getAddress(hre.ethers.hexlify(hre.ethers.randomBytes(20))),
      );
      const SELECTOR_CUSDC = '0xfe575a87';

      const v3Factory = await hre.ethers.getContractFactory('ConfidentialWrapperV3');
      const proxy = await hre.upgrades.deployProxy(
        v3Factory,
        [
          WRAPPER_NAME,
          WRAPPER_SYMBOL,
          CONTRACT_URI,
          this.underlyingAddress,
          this.owner,
          blockedAddresses,
          SELECTOR_CUSDC,
          true,
        ],
        { initializer: 'initializeV3', kind: 'uups' },
      );
      await proxy.waitForDeployment();

      const wrapperV3 = await hre.ethers.getContractAt('ConfidentialWrapperV3', await proxy.getAddress());

      // Base state is fully initialized
      expect(await wrapperV3.name()).to.equal(WRAPPER_NAME);
      expect(await wrapperV3.symbol()).to.equal(WRAPPER_SYMBOL);
      expect(await wrapperV3.contractURI()).to.equal(CONTRACT_URI);
      expect(await wrapperV3.owner()).to.equal(this.owner);
      expect(await wrapperV3.underlying()).to.equal(this.underlyingAddress);

      // V3 state is initialized with provided values
      for (const address of blockedAddresses) {
        expect(await wrapperV3.isBlocked(address)).to.be.true;
      }
      const [isSet, selector] = await wrapperV3.getUnderlyingDenyListSelector();
      expect(isSet).to.be.true;
      expect(selector).to.equal(SELECTOR_CUSDC);

      // reinitializer(3) is locked — reinitializeV3 cannot replay
      await expect(
        wrapperV3.connect(this.deployer).reinitializeV3([], '0x00000000', false),
      ).to.be.revertedWithCustomError(wrapperV3, 'InvalidInitialization');
    });
  });
});
