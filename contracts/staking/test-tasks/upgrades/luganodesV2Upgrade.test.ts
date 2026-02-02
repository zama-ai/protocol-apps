import { deployOperatorStaking, getOperatorStakingName, OPERATOR_STAKING_CONTRACT_NAME } from '../../tasks/deployment';
import {
  LUGANODES_OPERATOR_STAKING_V2_CONTRACT_NAME_TESTNET,
  getLuganodesOperatorStakingV2ImplName,
} from '../../tasks/deployment/upgrades/luganodesV2';
import { getProtocolStakingCoproProxyAddress } from '../../tasks/utils/getAddresses';
import { expect } from 'chai';
import hre from 'hardhat';

describe('LuganodesOperatorStakingV2 Upgrade', function () {
  // Expected values after upgrade (these are the correct values)
  const EXPECTED_NAME = 'Mock Luganodes Staked ZAMA (Coprocessor)';
  const EXPECTED_SYMBOL = 'stZAMA-Mock-Luganodes-Coprocessor';

  describe('Upgrade Flow', function () {
    it('Should fix swapped name and symbol after upgrade', async function () {
      const network = await hre.ethers.provider.getNetwork();
      const { deployer } = await hre.getNamedAccounts();
      const deployerSigner = await hre.ethers.getSigner(deployer);

      // Get the protocol staking address
      const protocolStakingAddress = await getProtocolStakingCoproProxyAddress(hre);

      // Deploy a new operator staking contract with SWAPPED name and symbol (simulating the bug)
      // The bug was that name and symbol were swapped during initialization
      await deployOperatorStaking(
        EXPECTED_SYMBOL, // Swapped: symbol passed as name
        EXPECTED_NAME, // Swapped: name passed as symbol
        protocolStakingAddress,
        deployer,
        1000,
        100,
        hre,
      );

      // Get the deployed operator staking contract using the token name (which is the swapped symbol)
      const operatorStakingDeployment = await hre.deployments.get(getOperatorStakingName(EXPECTED_SYMBOL));
      const operatorStakingProxyAddress = operatorStakingDeployment.address;
      const operatorStaking = await hre.ethers.getContractAt(
        OPERATOR_STAKING_CONTRACT_NAME,
        operatorStakingProxyAddress,
      );

      // Verify initial state has swapped name and symbol (simulating the bug)
      // Name contains symbol value and symbol contains name value
      expect(await operatorStaking.name()).to.equal(EXPECTED_SYMBOL);
      expect(await operatorStaking.symbol()).to.equal(EXPECTED_NAME);

      // Deposit and get total assets for verifying state consistency
      await hre.run('task:depositOperatorStakingFromDeployer', {
        assets: BigInt(1000),
        receiver: deployer,
        operatorStakingAddress: operatorStakingProxyAddress,
      });
      const totalAssets = await operatorStaking.totalAssets();

      console.log('totalAssets', totalAssets);

      // Run the task to deploy the new implementation contract with new Luganodes names and symbol
      await hre.run('task:deployLuganodesOperatorStakingV2Impl', {
        operatorStakingProxyAddress,
      });

      // Retrieve the deployment artifact for the new implementation contract to get its address
      const implementationDeployment = await hre.deployments.get(getLuganodesOperatorStakingV2ImplName(network.name));
      const implementationAddress = implementationDeployment.address;

      // Upgrade the proxy to the new implementation
      await operatorStaking.connect(deployerSigner).upgradeToAndCall(implementationAddress, '0x');

      // Get the upgraded operator staking V2 contract
      const operatorStakingV2 = await hre.ethers.getContractAt(
        LUGANODES_OPERATOR_STAKING_V2_CONTRACT_NAME_TESTNET,
        operatorStakingProxyAddress,
      );

      // Verify name and symbol are now correct in V2
      expect(await operatorStakingV2.name()).to.equal(EXPECTED_NAME);
      expect(await operatorStakingV2.symbol()).to.equal(EXPECTED_SYMBOL);

      // Verify total assets are the same after upgrade
      expect(await operatorStakingV2.totalAssets()).to.equal(totalAssets);
    });
  });

  describe('Helper Functions', function () {
    it('Should generate correct implementation name', function () {
      expect(getLuganodesOperatorStakingV2ImplName('mainnet')).to.equal('LuganodesOperatorStakingV2Mainnet_Impl');
      expect(getLuganodesOperatorStakingV2ImplName('testnet')).to.equal('LuganodesOperatorStakingV2Testnet_Impl');
      expect(getLuganodesOperatorStakingV2ImplName('hardhat')).to.equal('LuganodesOperatorStakingV2Testnet_Impl');
    });
  });
});
