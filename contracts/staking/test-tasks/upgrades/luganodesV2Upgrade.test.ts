import { getOperatorStakingName } from '../../tasks/deployment';
import {
  LUGANODES_OPERATOR_STAKING_V2_CONTRACT_NAME,
  getLuganodesOperatorStakingV2ImplName,
} from '../../tasks/deployment/upgrades/luganodesV2';
import { getRequiredEnvVar } from '../../tasks/utils/loadVariables';
import { getOperatorStakingContractsFixture } from '../utils';
import { loadFixture } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import hre from 'hardhat';

describe('LuganodesOperatorStakingV2 Upgrade', function () {
  // Expected new expected values after upgrade
  const EXPECTED_NAME = 'Luganodes Staked ZAMA (Coprocessor)';
  const EXPECTED_SYMBOL = 'stZAMA-Luganodes-Coprocessor';

  // Consider first copro contract
  const COPRO_TOKEN_NAME = getRequiredEnvVar(`OPERATOR_STAKING_COPRO_TOKEN_NAME_0`);

  let operatorStaking: any;

  // Reset the contracts' state between each test
  beforeEach(async function () {
    const fixture = await loadFixture(getOperatorStakingContractsFixture);
    operatorStaking = fixture.coproOperatorStakings[0];
  });

  describe('Upgrade Flow', function () {
    it('Should fix swapped name and symbol after upgrade', async function () {
      const { deployer } = await hre.getNamedAccounts();
      const deployerSigner = await hre.ethers.getSigner(deployer);

      // Get the deployed operator staking contract
      const operatorStakingDeployment = await hre.deployments.get(getOperatorStakingName(COPRO_TOKEN_NAME));
      const operatorStakingProxyAddress = operatorStakingDeployment.address;
      const operatorStaking = await hre.ethers.getContractAt('OperatorStaking', operatorStakingProxyAddress);

      // Verify initial state does not match the new expected values
      expect(await operatorStaking.name()).to.not.equal(EXPECTED_NAME);
      expect(await operatorStaking.symbol()).to.not.equal(EXPECTED_SYMBOL);

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
      const implementationDeployment = await hre.deployments.get(getLuganodesOperatorStakingV2ImplName());
      const implementationAddress = implementationDeployment.address;

      // Upgrade the proxy to the new implementation
      await operatorStaking.connect(deployerSigner).upgradeToAndCall(implementationAddress, '0x');

      // Get the upgraded operator staking V2 contract
      const operatorStakingV2 = await hre.ethers.getContractAt(
        LUGANODES_OPERATOR_STAKING_V2_CONTRACT_NAME,
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
      expect(getLuganodesOperatorStakingV2ImplName()).to.equal('LuganodesOperatorStakingV2_Impl');
    });
  });
});
