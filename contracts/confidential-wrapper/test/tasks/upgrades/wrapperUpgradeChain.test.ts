import { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/signers';
import { CONTRACT_NAME } from '../../../tasks/deploy';
import { expect } from 'chai';
import { ethers as ethersUtils } from 'ethers';
import hre from 'hardhat';
import oldConfidentialWrapperV3Artifact from '../../fixtures/frozen/ConfidentialWrapperV3.mainnet.json';
import erc1967ProxyArtifact from '@openzeppelin/contracts/build/contracts/ERC1967Proxy.json';

describe('ConfidentialWrapper Upgrade Chain', function () {
  const WRAPPER_NAME = 'Upgrade Chain Test Wrapper';
  const WRAPPER_SYMBOL = 'cUPCHAIN';
  const CONTRACT_URI =
    'data:application/json;utf8,{"name":"Upgrade Chain Test Wrapper","symbol":"cUPCHAIN","description":"Test wrapper for full upgrade chain"}';
  const SELECTOR_CUSDC = '0xfe575a87';
  const V4_IFACE = new ethersUtils.Interface(['function reinitializeV4(address)']);

  let deployer: string;
  let deployerSigner: HardhatEthersSigner;
  let user: HardhatEthersSigner;
  let outsider: HardhatEthersSigner;

  async function deployUnderlying() {
    const erc20Factory = await hre.ethers.getContractFactory('ERC20Mock');
    const underlying = await erc20Factory.deploy('Test Token', 'TEST', 6);
    await underlying.waitForDeployment();
    return underlying;
  }

  async function deployHistoricalV3Proxy(
    underlyingAddress: string,
    blockedAddresses: string[],
    selector = '0x00000000',
    hasSelector = false,
  ) {
    const oldV3Factory = new hre.ethers.ContractFactory(
      oldConfidentialWrapperV3Artifact.abi as any,
      oldConfidentialWrapperV3Artifact.bytecode,
      deployerSigner,
    );
    const oldV3Impl = await oldV3Factory.deploy();
    await oldV3Impl.waitForDeployment();

    const initData = oldV3Factory.interface.encodeFunctionData('initialize', [
      WRAPPER_NAME,
      WRAPPER_SYMBOL,
      CONTRACT_URI,
      underlyingAddress,
      deployer,
    ]);
    const proxyFactory = new hre.ethers.ContractFactory(
      (erc1967ProxyArtifact as any).abi,
      erc1967ProxyArtifact.bytecode,
      deployerSigner,
    );
    const proxy = await proxyFactory.deploy(await oldV3Impl.getAddress(), initData);
    await proxy.waitForDeployment();

    const proxyAddress = await proxy.getAddress();
    const wrapper: any = new hre.ethers.Contract(proxyAddress, oldConfidentialWrapperV3Artifact.abi, deployerSigner);
    await wrapper.connect(deployerSigner).reinitializeV2();
    await wrapper.connect(deployerSigner).reinitializeV3(blockedAddresses, selector, hasSelector);
    return proxyAddress;
  }

  async function deployCurrentImplementation() {
    await hre.run('task:deployConfidentialWrapperImpl');
    const implDeployment = await hre.deployments.get(`${CONTRACT_NAME}_Impl`);
    return implDeployment.address;
  }

  async function deployMockDenyList() {
    const denyList = await hre.ethers.deployContract('MockConfidentialWrapperDenyList');
    await denyList.waitForDeployment();
    return denyList;
  }

  async function expectCurrentState(
    proxyAddress: string,
    underlyingAddress: string,
    blockedAddresses: string[],
    selector: string,
    hasSelector: boolean,
    denyList: any,
  ) {
    const wrapper: any = await hre.ethers.getContractAt(CONTRACT_NAME, proxyAddress);

    expect(await wrapper.name()).to.equal(WRAPPER_NAME);
    expect(await wrapper.symbol()).to.equal(WRAPPER_SYMBOL);
    expect(await wrapper.contractURI()).to.equal(CONTRACT_URI);
    expect(await wrapper.owner()).to.equal(deployer);
    expect(await wrapper.underlying()).to.equal(underlyingAddress);

    for (const address of blockedAddresses) {
      expect(await wrapper.isBlocked(address)).to.be.true;
    }

    const [isSet, configuredSelector] = await wrapper.getUnderlyingDenyListSelector();
    expect(isSet).to.equal(hasSelector);
    expect(configuredSelector).to.equal(selector);

    await expect(wrapper.connect(deployerSigner).blockUser(user.address))
      .to.emit(wrapper, 'UserBlocked')
      .withArgs(user.address);
    await expect(wrapper.connect(outsider).blockUser(outsider.address))
      .to.be.revertedWithCustomError(wrapper, 'OwnableUnauthorizedAccount')
      .withArgs(outsider.address);
    await wrapper.connect(deployerSigner).unblockUser(user.address);

    // V4 feature: the centralized deny-list registry is wired and contributes to blocking.
    const registryAddress = await denyList.getAddress();
    expect(await wrapper.confidentialWrapperDenyList()).to.equal(registryAddress);

    const registryDenied = ethersUtils.getAddress(ethersUtils.hexlify(ethersUtils.randomBytes(20)));
    expect(await wrapper.isBlocked(registryDenied)).to.be.false;
    await denyList.addToDenyList([registryDenied]);
    expect(await wrapper.isBlocked(registryDenied)).to.be.true;

    await expect(wrapper.connect(deployerSigner).reinitializeV4(ethersUtils.ZeroAddress)).to.be.revertedWithCustomError(
      wrapper,
      'InvalidInitialization',
    );
  }

  before(async function () {
    [user, outsider] = await hre.ethers.getSigners();
    const { deployer: d } = await hre.getNamedAccounts();
    deployer = d;
    deployerSigner = await hre.ethers.getSigner(deployer);
  });

  it('upgrades from historical V3 to the current flat implementation via reinitializeV4', async function () {
    const underlying = await deployUnderlying();
    const underlyingAddress = await underlying.getAddress();
    const blockedAddresses = Array.from({ length: 2 }, () =>
      ethersUtils.getAddress(ethersUtils.hexlify(ethersUtils.randomBytes(20))),
    );

    const proxyAddress = await deployHistoricalV3Proxy(underlyingAddress, blockedAddresses, SELECTOR_CUSDC, true);
    const historicalV3ImplAddress = await hre.upgrades.erc1967.getImplementationAddress(proxyAddress);
    const currentImplAddress = await deployCurrentImplementation();
    expect(currentImplAddress).to.not.equal(historicalV3ImplAddress);

    // The flat implementation is V4 (reinitializer(4)); wire the centralized registry on upgrade.
    const denyList = await deployMockDenyList();
    const registryAddress = await denyList.getAddress();
    const reinitializeV4Calldata = V4_IFACE.encodeFunctionData('reinitializeV4', [registryAddress]);

    const wrapperV3: any = new hre.ethers.Contract(proxyAddress, oldConfidentialWrapperV3Artifact.abi, deployerSigner);
    await wrapperV3.connect(deployerSigner).upgradeToAndCall(currentImplAddress, reinitializeV4Calldata);

    expect(await hre.upgrades.erc1967.getImplementationAddress(proxyAddress)).to.equal(currentImplAddress);
    await expectCurrentState(proxyAddress, underlyingAddress, blockedAddresses, SELECTOR_CUSDC, true, denyList);
  });
});
