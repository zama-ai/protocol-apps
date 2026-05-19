import { CONTRACT_NAME, getConfidentialWrapperProxyName } from '../../../tasks/deploy';
import {
  CONFIDENTIAL_WRAPPER_V2_CONTRACT,
  getConfidentialWrapperV2ImplName,
} from '../../../tasks/upgrades/confidentialWrapperV2';
import { ConfidentialWrapperV3 } from '../../../types';
import { expect } from 'chai';
import hre from 'hardhat';
import { FunctionFragment } from 'ethers';

describe('ConfidentialWrapperV3 Upgrade', function () {
  const WRAPPER_NAME = 'Upgrade Test Wrapper V3';
  const WRAPPER_SYMBOL = 'cUPTEST3';
  const CONTRACT_URI =
    'data:application/json;utf8,{"name":"Upgrade Test Wrapper V3","symbol":"cUPTEST3","description":"Test wrapper for V3 upgrade flow"}';

  async function deployUnderlying() {
    const erc20Factory = await hre.ethers.getContractFactory('ERC20Mock');
    const underlying = await erc20Factory.deploy('Test Token', 'TEST', 6);
    await underlying.waitForDeployment();
    return underlying;
  }

  async function deployBaseProxy(underlyingAddress: string, owner: string) {
    await hre.run('task:deployConfidentialWrapper', {
      name: WRAPPER_NAME,
      symbol: WRAPPER_SYMBOL,
      contractUri: CONTRACT_URI,
      underlying: underlyingAddress,
      owner,
    });

    const proxyDeployment = await hre.deployments.get(getConfidentialWrapperProxyName(WRAPPER_NAME));
    return proxyDeployment.address;
  }

  async function deployV3Implementation() {
    const factory = await hre.ethers.getContractFactory('ConfidentialWrapperV3');
    const implementation = await factory.deploy();
    await implementation.waitForDeployment();
    return implementation.getAddress();
  }

  it('Should upgrade V2 to V3 preserving state and enabling compliance methods', async function () {
    const { deployer } = await hre.getNamedAccounts();
    const [observer, outsider] = await hre.ethers.getSigners();
    const deployerSigner = await hre.ethers.getSigner(deployer);

    const underlying = await deployUnderlying();
    const underlyingAddress = await underlying.getAddress();
    const proxyAddress = await deployBaseProxy(underlyingAddress, deployer);

    const wrapper = await hre.ethers.getContractAt(CONTRACT_NAME, proxyAddress);

    expect(await wrapper.name()).to.equal(WRAPPER_NAME);
    expect(await wrapper.symbol()).to.equal(WRAPPER_SYMBOL);
    expect(await wrapper.contractURI()).to.equal(CONTRACT_URI);
    expect(await wrapper.owner()).to.equal(deployer);

    await hre.run('task:deployConfidentialWrapperV2Impl');
    const v2Deployment = await hre.deployments.get(getConfidentialWrapperV2ImplName());
    const v2Selector = FunctionFragment.from('reinitializeV2()').selector;
    await wrapper.connect(deployerSigner).upgradeToAndCall(v2Deployment.address, v2Selector);

    const wrapperV2 = await hre.ethers.getContractAt(CONFIDENTIAL_WRAPPER_V2_CONTRACT, proxyAddress);
    expect(await wrapperV2.name()).to.equal(WRAPPER_NAME);
    expect(await wrapperV2.symbol()).to.equal(WRAPPER_SYMBOL);
    expect(await wrapperV2.contractURI()).to.equal(CONTRACT_URI);
    expect(await wrapperV2.owner()).to.equal(deployer);

    const v3ImplementationAddress = await deployV3Implementation();
    const v3Selector = FunctionFragment.from('reinitializeV3()').selector;
    await wrapperV2.connect(deployerSigner).upgradeToAndCall(v3ImplementationAddress, v3Selector);

    const wrapperV3 = (await hre.ethers.getContractAt(
      'ConfidentialWrapperV3',
      proxyAddress,
    )) as unknown as ConfidentialWrapperV3;

    const currentImplementation = await hre.upgrades.erc1967.getImplementationAddress(proxyAddress);
    expect(currentImplementation).to.equal(v3ImplementationAddress);

    expect(await wrapperV3.name()).to.equal(WRAPPER_NAME);
    expect(await wrapperV3.symbol()).to.equal(WRAPPER_SYMBOL);
    expect(await wrapperV3.contractURI()).to.equal(CONTRACT_URI);
    expect(await wrapperV3.owner()).to.equal(deployer);
    expect(await wrapperV3.underlying()).to.equal(underlyingAddress);
    expect(await wrapperV3.complianceOracle()).to.equal(hre.ethers.ZeroAddress);
    expect(await wrapperV3.observer()).to.equal(hre.ethers.ZeroAddress);

    const oracle = await hre.ethers.deployContract('SanctionsOracleMock');
    await oracle.waitForDeployment();

    await expect(wrapperV3.connect(deployerSigner).setComplianceOracle(oracle.target))
      .to.emit(wrapperV3, 'ComplianceOracleUpdated')
      .withArgs(oracle.target, hre.ethers.ZeroAddress);
    await expect(wrapperV3.complianceOracle()).to.eventually.equal(oracle.target);

    await expect(wrapperV3.connect(deployerSigner).transferObserver(observer.address))
      .to.emit(wrapperV3, 'ObserverTransferred')
      .withArgs(observer.address, hre.ethers.ZeroAddress);
    await expect(wrapperV3.observer()).to.eventually.equal(observer.address);

    await expect(wrapperV3.connect(outsider).setComplianceOracle(oracle.target))
      .to.be.revertedWithCustomError(wrapperV3, 'OwnableUnauthorizedAccount')
      .withArgs(outsider.address);

    await expect(wrapperV3.connect(observer).renounceObserver())
      .to.emit(wrapperV3, 'ObserverRevoked')
      .withArgs(observer.address);
    await expect(wrapperV3.observer()).to.eventually.equal(hre.ethers.ZeroAddress);

    await expect(wrapperV3.connect(deployerSigner).reinitializeV3()).to.be.revertedWithCustomError(
      wrapperV3,
      'InvalidInitialization',
    );
  });
});
