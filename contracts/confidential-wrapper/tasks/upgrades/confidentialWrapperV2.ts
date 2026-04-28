import { task, types } from 'hardhat/config';
import { HardhatRuntimeEnvironment } from 'hardhat/types';

export const CONFIDENTIAL_WRAPPER_V2_CONTRACT = 'ConfidentialWrapperV2';

// Get the name for saving the implementation in deployments
export function getConfidentialWrapperV2ImplName(): string {
  return CONFIDENTIAL_WRAPPER_V2_CONTRACT + '_Impl';
}

// Deploy the ConfidentialWrapperV2 implementation contract (no proxy)
// This is used for DAO proposals to upgrade the existing proxy
async function deployConfidentialWrapperV2Impl(hre: HardhatRuntimeEnvironment) {
  const { getNamedAccounts, ethers, deployments, network } = hre;
  const { save, getArtifact } = deployments;

  // Get the deployer account
  const { deployer } = await getNamedAccounts();
  const deployerSigner = await ethers.getSigner(deployer);

  // Get contract name
  const contractName = CONFIDENTIAL_WRAPPER_V2_CONTRACT;

  // Get the contract factory and deploy the implementation only (no proxy)
  const factory = await ethers.getContractFactory(contractName, deployerSigner);
  const implementation = await factory.deploy();
  await implementation.waitForDeployment();

  const implementationAddress = await implementation.getAddress();

  console.log(
    [
      `✅ Deployed ${contractName} implementation:`,
      `  - Implementation address: ${implementationAddress}`,
      `  - Deployed by deployer account: ${deployer}`,
      `  - Network: ${network.name}`,
      '',
    ].join('\n'),
  );

  // Save the implementation contract artifact
  const artifact = await getArtifact(contractName);
  await save(getConfidentialWrapperV2ImplName(), {
    address: implementationAddress,
    abi: artifact.abi,
  });

  return implementationAddress;
}

// Deploy the ConfidentialWrapperV2 implementation contract
// After deploying the implementation, the owner should call `upgradeToAndCall(address,bytes)` on the Proxy,
// with the address of the implementation as first argument,
// and second argument the calldata returned by: `cast calldata "reinitializeV2()"`
// Example usage:
// npx hardhat task:deployConfidentialWrapperV2Impl --network testnet
task('task:deployConfidentialWrapperV2Impl').setAction(async function (_, hre) {
  console.log('Deploying ConfidentialWrapperV2 implementation...\n');
  await deployConfidentialWrapperV2Impl(hre);
});

// Verify the ConfidentialWrapperV2 implementation contract
// Example usage:
// npx hardhat task:verifyConfidentialWrapperV2Impl --impl-address 0x... --network testnet
task('task:verifyConfidentialWrapperV2Impl')
  .addParam('implAddress', 'The address of the implementation contract to verify', '', types.string)
  .setAction(async function ({ implAddress }, hre) {
    const { run } = hre;

    console.log(`Verifying ConfidentialWrapperV2 implementation at ${implAddress}...\n`);
    await run('verify:verify', {
      address: implAddress,
      constructorArguments: [],
    });
  });
