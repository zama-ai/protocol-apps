import { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/signers';
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

describe('ConfidentialWrapper Upgrade Chain', function () {
  const WRAPPER_NAME = 'Upgrade Chain Test Wrapper';
  const WRAPPER_SYMBOL = 'cUPCHAIN';
  const CONTRACT_URI =
    'data:application/json;utf8,{"name":"Upgrade Chain Test Wrapper","symbol":"cUPCHAIN","description":"Test wrapper for full upgrade chain"}';
  const ADDRESSES_TO_BLOCK = Array.from({ length: 2 }, () => ethers.getAddress(ethers.hexlify(ethers.randomBytes(20))));
  const SELECTOR_CUSDC = '0xfe575a87';

  let proxyAddress: string;
  let underlyingAddress: string;
  let deployer: string;
  let deployerSigner: HardhatEthersSigner;
  let user: HardhatEthersSigner;
  let outsider: HardhatEthersSigner;
  let prevImplAddress: string;

  before(async function () {
    [user, outsider] = await hre.ethers.getSigners();
    const { deployer: d } = await hre.getNamedAccounts();
    deployer = d;
    deployerSigner = await hre.ethers.getSigner(deployer);

    const erc20Factory = await hre.ethers.getContractFactory('ERC20Mock');
    const underlying = await erc20Factory.deploy('Test Token', 'TEST', 6);
    await underlying.waitForDeployment();
    underlyingAddress = await underlying.getAddress();

    await hre.run('task:deployConfidentialWrapper', {
      name: WRAPPER_NAME,
      symbol: WRAPPER_SYMBOL,
      contractUri: CONTRACT_URI,
      underlying: underlyingAddress,
      owner: deployer,
    });

    const proxyDeployment = await hre.deployments.get(getConfidentialWrapperProxyName(WRAPPER_NAME));
    proxyAddress = proxyDeployment.address;
    prevImplAddress = await hre.upgrades.erc1967.getImplementationAddress(proxyAddress);
  });

  describe('V1 → V2', function () {
    before(async function () {
      await hre.run('task:deployConfidentialWrapperV2Impl');
      const v2Deployment = await hre.deployments.get(getConfidentialWrapperV2ImplName());
      const v2Selector = FunctionFragment.from('reinitializeV2()').selector;
      const wrapper = await hre.ethers.getContractAt(CONTRACT_NAME, proxyAddress);
      await wrapper.connect(deployerSigner).upgradeToAndCall(v2Deployment.address, v2Selector);
    });

    it('upgrades implementation and preserves state', async function () {
      const wrapperV2 = await hre.ethers.getContractAt(CONFIDENTIAL_WRAPPER_V2_CONTRACT, proxyAddress);
      const newImplAddress = await hre.upgrades.erc1967.getImplementationAddress(proxyAddress);

      expect(newImplAddress).to.not.equal(prevImplAddress);
      prevImplAddress = newImplAddress;

      expect(await wrapperV2.name()).to.equal(WRAPPER_NAME);
      expect(await wrapperV2.symbol()).to.equal(WRAPPER_SYMBOL);
      expect(await wrapperV2.contractURI()).to.equal(CONTRACT_URI);
      expect(await wrapperV2.owner()).to.equal(deployer);
      expect(await wrapperV2.underlying()).to.equal(underlyingAddress);

      await expect(wrapperV2.connect(deployerSigner).reinitializeV2()).to.be.revertedWithCustomError(
        wrapperV2,
        'InvalidInitialization',
      );
    });
  });

  describe('V2 → V3', function () {
    before(async function () {
      await hre.run('task:deployConfidentialWrapperV3Impl');
      const v3Deployment = await hre.deployments.get(getConfidentialWrapperV3ImplName());
      const v3Iface = new Interface(['function reinitializeV3(address[], bytes4, bool)']);
      const v3Calldata = v3Iface.encodeFunctionData('reinitializeV3', [ADDRESSES_TO_BLOCK, SELECTOR_CUSDC, true]);
      const wrapperV2 = await hre.ethers.getContractAt(CONFIDENTIAL_WRAPPER_V2_CONTRACT, proxyAddress);
      await wrapperV2.connect(deployerSigner).upgradeToAndCall(v3Deployment.address, v3Calldata);
    });

    it('upgrades implementation, preserves state, and initializes denylist', async function () {
      const wrapperV3 = await hre.ethers.getContractAt(CONFIDENTIAL_WRAPPER_V3_CONTRACT, proxyAddress);
      const newImplAddress = await hre.upgrades.erc1967.getImplementationAddress(proxyAddress);

      expect(newImplAddress).to.not.equal(prevImplAddress);
      prevImplAddress = newImplAddress;

      expect(await wrapperV3.name()).to.equal(WRAPPER_NAME);
      expect(await wrapperV3.symbol()).to.equal(WRAPPER_SYMBOL);
      expect(await wrapperV3.contractURI()).to.equal(CONTRACT_URI);
      expect(await wrapperV3.owner()).to.equal(deployer);
      expect(await wrapperV3.underlying()).to.equal(underlyingAddress);

      for (const address of ADDRESSES_TO_BLOCK) {
        expect(await wrapperV3.isBlocked(address)).to.be.true;
      }

      await expect(wrapperV3.connect(deployerSigner).blockUser(user.address))
        .to.emit(wrapperV3, 'UserBlocked')
        .withArgs(user.address);
      await expect(wrapperV3.connect(outsider).blockUser(outsider.address))
        .to.be.revertedWithCustomError(wrapperV3, 'OwnableUnauthorizedAccount')
        .withArgs(outsider.address);
      await wrapperV3.connect(deployerSigner).unblockUser(user.address);

      await expect(
        wrapperV3.connect(deployerSigner).reinitializeV3([], '0x00000000', false),
      ).to.be.revertedWithCustomError(wrapperV3, 'InvalidInitialization');
    });
  });
});
