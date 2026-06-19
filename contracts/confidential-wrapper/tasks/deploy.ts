import { getRequiredEnvVar } from './utils/loadVariables';
import { task, types } from 'hardhat/config';
import { HardhatRuntimeEnvironment } from 'hardhat/types';

export const CONTRACT_NAME = 'ConfidentialWrapper';

// Get the deployment name for a confidential wrapper
export function getConfidentialWrapperName(tokenName: string): string {
  return `ConfidentialWrapper_${tokenName}`;
}

// Get the implementation deployment name for a confidential wrapper
export function getConfidentialWrapperImplName(tokenName: string): string {
  return `ConfidentialWrapper_${tokenName}_Impl`;
}

// Get the proxy deployment name for a confidential wrapper
export function getConfidentialWrapperProxyName(tokenName: string): string {
  return `ConfidentialWrapper_${tokenName}_Proxy`;
}

type ConfidentialWrapperInitConfig = {
  name: string;
  symbol: string;
  contractUri: string;
  underlying: string;
  owner: string;
  blockedUsers: string[];
  underlyingDenyListSelector: string;
  hasUnderlyingDenyListSelector: boolean;
};

function getRequiredJsonEnvVar<T>(name: string): T {
  return JSON.parse(getRequiredEnvVar(name)) as T;
}

function getRequiredBooleanEnvVar(name: string): boolean {
  const value = getRequiredEnvVar(name);
  if (value === 'true') return true;
  if (value === 'false') return false;
  throw new Error(`${name} must be either "true" or "false"`);
}

// Deploy a confidential wrapper contract as a function
async function deployConfidentialWrapper(initConfig: ConfidentialWrapperInitConfig, hre: HardhatRuntimeEnvironment) {
  const { ethers, upgrades, deployments, getNamedAccounts } = hre;
  const { save, getArtifact } = deployments;
  const { deployer } = await getNamedAccounts();
  const {
    name,
    symbol,
    contractUri,
    underlying,
    owner,
    blockedUsers,
    underlyingDenyListSelector,
    hasUnderlyingDenyListSelector,
  } = initConfig;

  // Deploy the proxy contract
  const confidentialWrapperFactory = await ethers.getContractFactory(CONTRACT_NAME);
  const proxy = await upgrades.deployProxy(
    confidentialWrapperFactory,
    [
      name,
      symbol,
      contractUri,
      underlying,
      owner,
      blockedUsers,
      underlyingDenyListSelector,
      hasUnderlyingDenyListSelector,
    ],
    { initializer: 'initialize', kind: 'uups' },
  );

  await proxy.waitForDeployment();
  const proxyAddress = await proxy.getAddress();

  console.log(
    [
      `✅ Deployed ${name} ConfidentialWrapper:`,
      `  - Confidential wrapper proxy address:  ${proxyAddress}`,
      `  - name: ${name}`,
      `  - symbol: ${symbol}`,
      `  - contract URI: ${contractUri}`,
      `  - underlying: ${underlying}`,
      `  - owner: ${owner}`,
      `  - Deployed by deployer account: ${deployer}`,
      `  - Network: ${hre.network.name}`,
      '',
    ].join('\n'),
  );

  // Save the deployment artifacts
  const implementationAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
  const artifact = await getArtifact(CONTRACT_NAME);
  await save(getConfidentialWrapperProxyName(name), { address: proxyAddress, abi: artifact.abi });
  await save(getConfidentialWrapperImplName(name), { address: implementationAddress, abi: artifact.abi });
}

// Deploy a confidential wrapper contract
// Example usage:
// npx hardhat task:deployConfidentialWrapper \
// --name "ZAMA" \
// --symbol "cZAMA" \
// --contract-uri 'data:application/json;utf8,{"name":"Confidential ZAMA","symbol":"cZAMA","description":"Confidential wrapper of ZAMA shielding it into a confidential token"}' \
// --underlying "0x1234567890123456789012345678901234567890" \
// --owner "0x1234567890123456789012345678901234567890" \
// --blocked-users '["0x1111111111111111111111111111111111111111"]' \
// --underlying-deny-list-selector "0xfe575a87" \
// --has-underlying-deny-list-selector true \
// --network testnet
task('task:deployConfidentialWrapper')
  .addParam('name', 'The name of the confidential wrapper contract to deploy', undefined, types.string)
  .addParam('symbol', 'The symbol of the confidential wrapper contract to deploy', undefined, types.string)
  .addParam('contractUri', 'The contract URI of the confidential wrapper contract to deploy', undefined, types.string)
  .addParam(
    'underlying',
    'The underlying token address of the confidential wrapper contract to deploy',
    undefined,
    types.string,
  )
  .addParam('owner', 'The owner address of the confidential wrapper contract to deploy', undefined, types.string)
  .addParam(
    'blockedUsers',
    'JSON array of addresses to seed into the wrapper denylist during initialize',
    undefined,
    types.json,
  )
  .addParam(
    'underlyingDenyListSelector',
    'Function selector used to query the underlying token denylist',
    undefined,
    types.string,
  )
  .addParam(
    'hasUnderlyingDenyListSelector',
    'Whether the underlying token denylist selector should be enabled',
    undefined,
    types.boolean,
  )
  .setAction(async function (
    {
      name,
      symbol,
      contractUri,
      underlying,
      owner,
      blockedUsers,
      underlyingDenyListSelector,
      hasUnderlyingDenyListSelector,
    },
    hre,
  ) {
    await deployConfidentialWrapper(
      {
        name,
        symbol,
        contractUri,
        underlying,
        owner,
        blockedUsers,
        underlyingDenyListSelector,
        hasUnderlyingDenyListSelector,
      },
      hre,
    );
  });

// Deploy all confidential wrapper contracts
// Example usage:
// npx hardhat task:deployAllConfidentialWrappers --network testnet
task('task:deployAllConfidentialWrappers').setAction(async function (_, hre) {
  console.log('Deploying confidential wrapper contracts...');

  // Get the number of confidential wrappers from environment variable
  const numWrappers = parseInt(getRequiredEnvVar('NUM_CONFIDENTIAL_WRAPPERS'));

  for (let i = 0; i < numWrappers; i++) {
    // Get the name from environment variable
    const name = getRequiredEnvVar(`CONFIDENTIAL_WRAPPER_NAME_${i}`);
    const symbol = getRequiredEnvVar(`CONFIDENTIAL_WRAPPER_SYMBOL_${i}`);
    const contractUri = getRequiredEnvVar(`CONFIDENTIAL_WRAPPER_CONTRACT_URI_${i}`);
    const underlying = getRequiredEnvVar(`CONFIDENTIAL_WRAPPER_UNDERLYING_ADDRESS_${i}`);
    const owner = getRequiredEnvVar(`CONFIDENTIAL_WRAPPER_OWNER_ADDRESS_${i}`);
    const blockedUsers = getRequiredJsonEnvVar<string[]>(`CONFIDENTIAL_WRAPPER_BLOCKED_USERS_${i}`);
    const underlyingDenyListSelector = getRequiredEnvVar(`CONFIDENTIAL_WRAPPER_UNDERLYING_DENY_LIST_SELECTOR_${i}`);
    const hasUnderlyingDenyListSelector = getRequiredBooleanEnvVar(
      `CONFIDENTIAL_WRAPPER_HAS_UNDERLYING_DENY_LIST_SELECTOR_${i}`,
    );

    await hre.run('task:deployConfidentialWrapper', {
      name,
      symbol,
      contractUri,
      underlying,
      owner,
      blockedUsers,
      underlyingDenyListSelector,
      hasUnderlyingDenyListSelector,
    });
  }

  console.log('✅ All confidential wrapper contracts deployed\n');
});

// Deploy a bare ConfidentialWrapper implementation (no proxy).
// Used when preparing an upgrade proposal: deploy the new implementation, then call
// `upgradeToAndCall(implAddress, reinitializeVX_calldata)` on the existing proxy.
// Example usage:
// npx hardhat task:deployConfidentialWrapperImpl --network testnet
async function deployConfidentialWrapperImpl(hre: HardhatRuntimeEnvironment) {
  const { getNamedAccounts, ethers, deployments, network } = hre;
  const { save, getArtifact } = deployments;
  const { deployer } = await getNamedAccounts();
  const deployerSigner = await ethers.getSigner(deployer);

  const factory = await ethers.getContractFactory(CONTRACT_NAME, deployerSigner);
  const implementation = await factory.deploy();
  await implementation.waitForDeployment();

  const implementationAddress = await implementation.getAddress();

  console.log(
    [
      `✅ Deployed ${CONTRACT_NAME} implementation:`,
      `  - Implementation address: ${implementationAddress}`,
      `  - Deployed by deployer account: ${deployer}`,
      `  - Network: ${network.name}`,
      '',
    ].join('\n'),
  );

  const artifact = await getArtifact(CONTRACT_NAME);
  await save(`${CONTRACT_NAME}_Impl`, { address: implementationAddress, abi: artifact.abi });

  return implementationAddress;
}

task('task:deployConfidentialWrapperImpl').setAction(async function (_, hre) {
  console.log(`Deploying ${CONTRACT_NAME} implementation...\n`);
  await deployConfidentialWrapperImpl(hre);
});

task('task:verifyConfidentialWrapperImpl')
  .addParam('implAddress', 'The address of the implementation contract to verify', '', types.string)
  .setAction(async function ({ implAddress }, hre) {
    const { run } = hre;
    console.log(`Verifying ${CONTRACT_NAME} implementation at ${implAddress}...\n`);
    await run('verify:verify', { address: implAddress, constructorArguments: [] });
  });
