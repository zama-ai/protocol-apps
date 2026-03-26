import { CONTRACT_NAME } from './deploy';
import { getRequiredEnvVar } from './utils/loadVariables';
import { task, types } from 'hardhat/config';
import { HardhatRuntimeEnvironment } from 'hardhat/types';

export function getConfidentialWrapperUpgradeImplName(name: string, label: string): string {
  return `ConfidentialWrapper_${name}_Impl_${label}`;
}

async function deployWrapperImplementation(name: string, label: string, hre: HardhatRuntimeEnvironment) {
  const { ethers, deployments, getNamedAccounts } = hre;
  const { save, getArtifact } = deployments;
  const { deployer } = await getNamedAccounts();

  const factory = await ethers.getContractFactory(CONTRACT_NAME);
  const implementation = await factory.deploy();
  await implementation.waitForDeployment();
  const implementationAddress = await implementation.getAddress();

  const artifactName = getConfidentialWrapperUpgradeImplName(name, label);

  console.log(
    [
      `✅ Deployed ${CONTRACT_NAME} implementation:`,
      `  - Implementation address: ${implementationAddress}`,
      `  - Artifact name: ${artifactName}`,
      `  - Deployed by deployer account: ${deployer}`,
      `  - Network: ${hre.network.name}`,
      '',
    ].join('\n'),
  );

  const artifact = await getArtifact(CONTRACT_NAME);
  await save(artifactName, { address: implementationAddress, abi: artifact.abi });
}

// Deploy a new ConfidentialWrapper implementation contract (without upgrading any proxy).
// The proxy upgrade is handled separately by the DAO.
//
// Example usage:
// npx hardhat task:deployWrapperImplementation --name "ZAMA" --label "v2" --network testnet
task('task:deployWrapperImplementation')
  .addParam('name', 'The name of the wrapper this implementation is for', undefined, types.string)
  .addParam('label', 'A version label for this implementation (e.g. "v2"), appended to the artifact name', undefined, types.string)
  .setAction(async function ({ name, label }, hre) {
    await deployWrapperImplementation(name, label, hre);
  });

// Deploy upgrade implementations for all wrappers defined in the .env file.
//
// Required env vars:
//   NUM_CONFIDENTIAL_WRAPPERS
//   CONFIDENTIAL_WRAPPER_NAME_{i}    (per wrapper)
//   CONFIDENTIAL_WRAPPER_UPGRADE_VERSION_LABEL  (shared across all wrappers)
//
// Example usage:
// npx hardhat task:deployAllWrapperImplementations --network testnet
task('task:deployAllWrapperImplementations').setAction(async function (_, hre) {
  const numWrappers = parseInt(getRequiredEnvVar('NUM_CONFIDENTIAL_WRAPPERS'));
  const label = getRequiredEnvVar('CONFIDENTIAL_WRAPPER_UPGRADE_VERSION_LABEL');

  console.log(`Deploying ${CONTRACT_NAME} implementations (version label: ${label})...\n`);

  for (let i = 0; i < numWrappers; i++) {
    const name = getRequiredEnvVar(`CONFIDENTIAL_WRAPPER_NAME_${i}`);
    await hre.run('task:deployWrapperImplementation', { name, label });
  }

  console.log('✅ All wrapper implementations deployed\n');
});
