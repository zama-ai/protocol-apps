import { CONTRACT_NAME, getConfidentialWrapperProxyName } from '../../../tasks/deploy';
import {
  CONFIDENTIAL_WRAPPER_V2_CONTRACT,
  getConfidentialWrapperV2ImplName,
} from '../../../tasks/upgrades/confidentialWrapperV2';
import { expect } from 'chai';
import hre from 'hardhat';

describe('ConfidentialWrapperV2 Upgrade', function () {
  const WRAPPER_NAME = 'Upgrade Test Wrapper';
  const WRAPPER_SYMBOL = 'cUPTEST';
  const CONTRACT_URI =
    'data:application/json;utf8,{"name":"Upgrade Test Wrapper","symbol":"cUPTEST","description":"Test wrapper for upgrade flow"}';

  describe('Upgrade Flow', function () {
    it('Should deploy a new implementation and upgrade the proxy preserving state', async function () {
      const { deployer } = await hre.getNamedAccounts();
      const deployerSigner = await hre.ethers.getSigner(deployer);

      // Deploy mock underlying ERC20 (6 decimals to stay within euint64 range)
      const erc20Factory = await hre.ethers.getContractFactory('ERC20Mock');
      const underlying = await erc20Factory.deploy('Test Token', 'TEST', 6);
      await underlying.waitForDeployment();
      const underlyingAddress = await underlying.getAddress();

      // Deploy ConfidentialWrapper proxy via the deployment task
      await hre.run('task:deployConfidentialWrapper', {
        name: WRAPPER_NAME,
        symbol: WRAPPER_SYMBOL,
        contractUri: CONTRACT_URI,
        underlying: underlyingAddress,
        owner: deployer,
      });

      // Get the proxy address from deployments
      const proxyDeployment = await hre.deployments.get(getConfidentialWrapperProxyName(WRAPPER_NAME));
      const proxyAddress = proxyDeployment.address;

      // Get the wrapper contract at proxy address
      const wrapper = await hre.ethers.getContractAt(CONTRACT_NAME, proxyAddress);

      // Verify initial state
      expect(await wrapper.name()).to.equal(WRAPPER_NAME);
      expect(await wrapper.symbol()).to.equal(WRAPPER_SYMBOL);
      expect(await wrapper.contractURI()).to.equal(CONTRACT_URI);
      expect(await wrapper.owner()).to.equal(deployer);

      // Get initial implementation address
      const initialImplAddress = await hre.upgrades.erc1967.getImplementationAddress(proxyAddress);

      // Run the task to deploy the new ConfidentialWrapperV2 implementation
      await hre.run('task:deployConfidentialWrapperV2Impl');

      // Retrieve the deployment artifact for the new implementation contract to get its address
      const implDeployment = await hre.deployments.get(getConfidentialWrapperV2ImplName());
      const newImplAddress = implDeployment.address;

      // Ensure the new implementation is a different address
      expect(newImplAddress).to.not.equal(initialImplAddress);

      // Upgrade the proxy to the new implementation with reinitializeV2() calldata
      const calldata = '0xc4115874'; // returned via: `cast calldata "reinitializeV2()"`
      await wrapper.connect(deployerSigner).upgradeToAndCall(newImplAddress, calldata);

      // Get the upgraded ConfidentialWrapperV2 contract
      const wrapperV2 = await hre.ethers.getContractAt(CONFIDENTIAL_WRAPPER_V2_CONTRACT, proxyAddress);

      // Verify the implementation address was updated
      const postUpgradeImplAddress = await hre.upgrades.erc1967.getImplementationAddress(proxyAddress);
      expect(postUpgradeImplAddress).to.equal(newImplAddress);

      // Verify state is preserved after upgrade
      expect(await wrapperV2.name()).to.equal(WRAPPER_NAME);
      expect(await wrapperV2.symbol()).to.equal(WRAPPER_SYMBOL);
      expect(await wrapperV2.contractURI()).to.equal(CONTRACT_URI);
      expect(await wrapperV2.owner()).to.equal(deployer);
    });
  });
});
