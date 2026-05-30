import { task, types } from 'hardhat/config';
import { HardhatRuntimeEnvironment } from 'hardhat/types';

export const CONFIDENTIAL_WRAPPER_V3_CONTRACT = 'ConfidentialWrapperV3';

// Get the name for saving the implementation in deployments
export function getConfidentialWrapperV3ImplName(): string {
  return CONFIDENTIAL_WRAPPER_V3_CONTRACT + '_Impl';
}

// Deploy the ConfidentialWrapperV3 implementation contract (no proxy)
// This is used for DAO proposals to upgrade the existing proxy
async function deployConfidentialWrapperV3Impl(hre: HardhatRuntimeEnvironment) {
  const { getNamedAccounts, ethers, deployments, network } = hre;
  const { save, getArtifact } = deployments;

  const { deployer } = await getNamedAccounts();
  const deployerSigner = await ethers.getSigner(deployer);

  const contractName = CONFIDENTIAL_WRAPPER_V3_CONTRACT;

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

  const artifact = await getArtifact(contractName);
  await save(getConfidentialWrapperV3ImplName(), {
    address: implementationAddress,
    abi: artifact.abi,
  });

  return implementationAddress;
}

// Deploy the ConfidentialWrapperV3 implementation contract
// After deploying the implementation, the owner should call `upgradeToAndCall(address,bytes)` on the Proxy,
// with the address of the implementation as first argument,
// and second argument the calldata returned by:
//   cast calldata "reinitializeV3(address[],bytes4,bool)" "[]" "0x00000000" false
// Example usage:
// npx hardhat task:deployConfidentialWrapperV3Impl --network testnet
task('task:deployConfidentialWrapperV3Impl').setAction(async function (_, hre) {
  console.log('Deploying ConfidentialWrapperV3 implementation...\n');
  await deployConfidentialWrapperV3Impl(hre);
});

// Verify the ConfidentialWrapperV3 implementation contract
// Example usage:
// npx hardhat task:verifyConfidentialWrapperV3Impl --impl-address 0x... --network testnet
task('task:verifyConfidentialWrapperV3Impl')
  .addParam('implAddress', 'The address of the implementation contract to verify', '', types.string)
  .setAction(async function ({ implAddress }, hre) {
    const { run } = hre;

    console.log(`Verifying ConfidentialWrapperV3 implementation at ${implAddress}...\n`);
    await run('verify:verify', {
      address: implAddress,
      constructorArguments: [],
    });
  });