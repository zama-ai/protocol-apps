import { getConfidentialWrapperUpgradeImplName } from './deploy-upgrade-impl';
import { getRequiredEnvVar } from './utils/loadVariables';
import { task, types } from 'hardhat/config';

// Verify a ConfidentialWrapper implementation contract on Etherscan.
//
// Example usage:
// npx hardhat task:verifyWrapperImplementation --address 0x1234567890123456789012345678901234567890 --network testnet
task('task:verifyWrapperImplementation')
  .addParam('address', 'The address of the implementation contract to verify', undefined, types.string)
  .setAction(async function ({ address }, hre) {
    const { run } = hre;

    console.log(`Verifying ${address}...\n`);
    await run('verify:verify', {
      address,
      constructorArguments: [],
    });
  });

// Verify all upgrade implementation contracts defined in the .env file.
// Reads NUM_CONFIDENTIAL_WRAPPERS and looks up each wrapper's name and upgrade version.
//
// Required env vars:
//   NUM_CONFIDENTIAL_WRAPPERS
//   CONFIDENTIAL_WRAPPER_NAME_{i}    (per wrapper)
//   CONFIDENTIAL_WRAPPER_UPGRADE_VERSION_LABEL  (shared across all wrappers)
//
// Example usage:
// npx hardhat task:verifyAllUpgradeImplementations --network testnet
task('task:verifyAllUpgradeImplementations').setAction(async function (_, hre) {
  const { run, deployments } = hre;
  const { get } = deployments;

  const numWrappers = parseInt(getRequiredEnvVar('NUM_CONFIDENTIAL_WRAPPERS'));

  for (let i = 0; i < numWrappers; i++) {
    const name = getRequiredEnvVar(`CONFIDENTIAL_WRAPPER_NAME_${i}`);
    const version = getRequiredEnvVar('CONFIDENTIAL_WRAPPER_UPGRADE_VERSION_LABEL');

    try {
      const artifactName = getConfidentialWrapperUpgradeImplName(name, version);
      const deployment = await get(artifactName);

      await run('task:verifyWrapperImplementation', { address: deployment.address });
    } catch (error) {
      console.error(`An error occurred verifying implementation for ${name}:`, error);
    }
  }
});
