import { CONTRACT_NAME, getConfidentialWrapperProxyName } from '../../../tasks/deploy';
import {
  CONFIDENTIAL_WRAPPER_V2_CONTRACT,
  getConfidentialWrapperV2ImplName,
} from '../../../tasks/upgrades/confidentialWrapperV2';
import {
  CONFIDENTIAL_WRAPPER_V3_CONTRACT,
  getConfidentialWrapperV3ImplName,
} from '../../../tasks/upgrades/confidentialWrapperV3';
import { expect } from 'chai';
import hre from 'hardhat';
import { FunctionFragment, Interface, ethers } from 'ethers';

describe('ConfidentialWrapperV3 Upgrade', function () {
  const WRAPPER_NAME = 'Upgrade Test Wrapper V3';
  const WRAPPER_SYMBOL = 'cUPTEST3';
  const CONTRACT_URI =
    'data:application/json;utf8,{"name":"Upgrade Test Wrapper V3","symbol":"cUPTEST3","description":"Test wrapper for V3 upgrade flow"}';
  const ADDRESSES_TO_BLOCK = Array.from({ length: 2 }, () =>
    ethers.getAddress(ethers.hexlify(ethers.randomBytes(20))),
  );

  async function deployV2Proxy() {
    const erc20Factory = await hre.ethers.getContractFactory('ERC20Mock');
    const underlying = await erc20Factory.deploy('Test Token', 'TEST', 6);
    await underlying.waitForDeployment();
    const underlyingAddress = await underlying.getAddress();

    const { deployer } = await hre.getNamedAccounts();

    await hre.run('task:deployConfidentialWrapper', {
      name: WRAPPER_NAME,
      symbol: WRAPPER_SYMBOL,
      contractUri: CONTRACT_URI,
      underlying: underlyingAddress,
      owner: deployer,
    });

    const proxyDeployment = await hre.deployments.get(getConfidentialWrapperProxyName(WRAPPER_NAME));
    const proxyAddress = proxyDeployment.address;

    // Advance proxy to V2
    await hre.run('task:deployConfidentialWrapperV2Impl');
    const v2Deployment = await hre.deployments.get(getConfidentialWrapperV2ImplName());
    const v2Selector = FunctionFragment.from('reinitializeV2()').selector;
    const wrapper = await hre.ethers.getContractAt(CONTRACT_NAME, proxyAddress);
    const deployerSigner = await hre.ethers.getSigner(deployer);
    await wrapper.connect(deployerSigner).upgradeToAndCall(v2Deployment.address, v2Selector);

    return { proxyAddress, underlyingAddress, deployer };
  }

  it('Should upgrade from V2 to V3, preserving state and enabling denylist methods', async function () {
    const { proxyAddress, underlyingAddress, deployer } = await deployV2Proxy();
    const deployerSigner = await hre.ethers.getSigner(deployer);
    const [user, outsider] = await hre.ethers.getSigners();

    const wrapperV2 = await hre.ethers.getContractAt(CONFIDENTIAL_WRAPPER_V2_CONTRACT, proxyAddress);
    const v2ImplAddress = await hre.upgrades.erc1967.getImplementationAddress(proxyAddress);

    // Deploy V3 implementation via task and upgrade
    await hre.run('task:deployConfidentialWrapperV3Impl');
    const v3Deployment = await hre.deployments.get(getConfidentialWrapperV3ImplName());
    const v3ImplAddress = v3Deployment.address;
    expect(v3ImplAddress).to.not.equal(v2ImplAddress);

    const v3Iface = new Interface(['function reinitializeV3(address[], bytes4, bool)']);
    const v3Calldata = v3Iface.encodeFunctionData('reinitializeV3', [ADDRESSES_TO_BLOCK, '0x00000000', false]);
    await wrapperV2.connect(deployerSigner).upgradeToAndCall(v3ImplAddress, v3Calldata);

    const wrapperV3 = await hre.ethers.getContractAt(CONFIDENTIAL_WRAPPER_V3_CONTRACT, proxyAddress);

    // Implementation updated
    expect(await hre.upgrades.erc1967.getImplementationAddress(proxyAddress)).to.equal(v3ImplAddress);

    // State preserved through upgrade
    expect(await wrapperV3.name()).to.equal(WRAPPER_NAME);
    expect(await wrapperV3.symbol()).to.equal(WRAPPER_SYMBOL);
    expect(await wrapperV3.contractURI()).to.equal(CONTRACT_URI);
    expect(await wrapperV3.owner()).to.equal(deployer);
    expect(await wrapperV3.underlying()).to.equal(underlyingAddress);

    // Denylist state initialised
    for (const address of ADDRESSES_TO_BLOCK) {
      expect(await wrapperV3.isBlocked(address)).to.be.true;
    }

    // blockUser / unblockUser
    await expect(wrapperV3.connect(deployerSigner).blockUser(user.address))
      .to.emit(wrapperV3, 'UserBlocked')
      .withArgs(user.address);
    expect(await wrapperV3.isBlocked(user.address)).to.be.true;

    await expect(wrapperV3.connect(outsider).blockUser(outsider.address))
      .to.be.revertedWithCustomError(wrapperV3, 'OwnableUnauthorizedAccount')
      .withArgs(outsider.address);

    await expect(wrapperV3.connect(deployerSigner).unblockUser(user.address))
      .to.emit(wrapperV3, 'UserUnblocked')
      .withArgs(user.address);
    expect(await wrapperV3.isBlocked(user.address)).to.be.false;

    // reinitializeV3 cannot be called again
    await expect(
      wrapperV3.connect(deployerSigner).reinitializeV3([], '0x00000000', false),
    ).to.be.revertedWithCustomError(wrapperV3, 'InvalidInitialization');
  });
});
