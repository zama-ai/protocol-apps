import { task, types } from 'hardhat/config';
import { HardhatRuntimeEnvironment } from 'hardhat/types';

export const CONFIDENTIAL_WRAPPER_DENY_LIST_CONTRACT = 'ConfidentialWrapperDenyList';

// Get the deployment name for the ConfidentialWrapperDenyList proxy
export function getConfidentialWrapperDenyListProxyName(): string {
  return CONFIDENTIAL_WRAPPER_DENY_LIST_CONTRACT + '_Proxy';
}

// Get the deployment name for the ConfidentialWrapperDenyList implementation
export function getConfidentialWrapperDenyListImplName(): string {
  return CONFIDENTIAL_WRAPPER_DENY_LIST_CONTRACT + '_Impl';
}

// Deploy the ConfidentialWrapperDenyList as a UUPS proxy
async function deployConfidentialWrapperDenyList(owner: string, hre: HardhatRuntimeEnvironment) {
  const { ethers, upgrades, deployments, getNamedAccounts, network } = hre;
  const { save, getArtifact } = deployments;
  const { deployer } = await getNamedAccounts();

  const contractName = CONFIDENTIAL_WRAPPER_DENY_LIST_CONTRACT;

  const factory = await ethers.getContractFactory(contractName);
  const proxy = await upgrades.deployProxy(factory, [owner], {
    initializer: 'initialize',
    kind: 'uups',
  });

  await proxy.waitForDeployment();
  const proxyAddress = await proxy.getAddress();

  console.log(
    [
      `✅ Deployed ${contractName}:`,
      `  - Proxy address: ${proxyAddress}`,
      `  - Owner: ${owner}`,
      `  - Deployed by deployer account: ${deployer}`,
      `  - Network: ${network.name}`,
      '',
    ].join('\n'),
  );

  const implementationAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
  const artifact = await getArtifact(contractName);
  await save(getConfidentialWrapperDenyListProxyName(), { address: proxyAddress, abi: artifact.abi });
  await save(getConfidentialWrapperDenyListImplName(), { address: implementationAddress, abi: artifact.abi });

  return proxyAddress;
}

// Deploy the ConfidentialWrapperDenyList implementation contract (no proxy)
// This is used for DAO proposals to upgrade the existing proxy
async function deployConfidentialWrapperDenyListImpl(hre: HardhatRuntimeEnvironment) {
  const { getNamedAccounts, ethers, deployments, network } = hre;
  const { save, getArtifact } = deployments;
  const { deployer } = await getNamedAccounts();
  const deployerSigner = await ethers.getSigner(deployer);
  const contractName = CONFIDENTIAL_WRAPPER_DENY_LIST_CONTRACT;

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
  await save(getConfidentialWrapperDenyListImplName(), { address: implementationAddress, abi: artifact.abi });

  return implementationAddress;
}

// Example usage:
// npx hardhat task:deployConfidentialWrapperDenyListImpl --network testnet
task('task:deployConfidentialWrapperDenyListImpl').setAction(async function (_, hre) {
  console.log('Deploying ConfidentialWrapperDenyList implementation...\n');
  await deployConfidentialWrapperDenyListImpl(hre);
});

// Deploy the ConfidentialWrapperDenyList proxy contract
// Example usage:
// npx hardhat task:deployConfidentialWrapperDenyList --owner 0x... --network testnet
task('task:deployConfidentialWrapperDenyList')
  .addParam(
    'owner',
    'The owner address of the ConfidentialWrapperDenyList (expected to be the Zama DAO)',
    undefined,
    types.string,
  )
  .setAction(async function ({ owner }, hre) {
    console.log('Deploying ConfidentialWrapperDenyList...\n');
    await deployConfidentialWrapperDenyList(owner, hre);
  });

// Verify the ConfidentialWrapperDenyList implementation contract
// Example usage:
// npx hardhat task:verifyConfidentialWrapperDenyListImpl --impl-address 0x... --network testnet
task('task:verifyConfidentialWrapperDenyListImpl')
  .addParam('implAddress', 'The address of the implementation contract to verify', '', types.string)
  .setAction(async function ({ implAddress }, hre) {
    const { run } = hre;

    console.log(`Verifying ConfidentialWrapperDenyList implementation at ${implAddress}...\n`);
    await run('verify:verify', {
      address: implAddress,
      constructorArguments: [],
    });
  });
