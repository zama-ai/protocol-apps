import { Signer } from 'ethers';
import { task, types } from 'hardhat/config';
import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { getRequiredEnvVar } from './utils/loadVariables';

export const CONTRACT_NAME = 'ConfidentialWrapper';

type HreWithDeployHook = HardhatRuntimeEnvironment & {
  zamaWrapperDeploy?: {
    getDeployerSigner?: (hre: HardhatRuntimeEnvironment) => Promise<Signer>;
    resolveDeployerAddress?: (hre: HardhatRuntimeEnvironment) => Promise<string>;
  };
};

// Select the deploy signer. Default: local PRIVATE_KEY/MNEMONIC via namedAccounts.
export async function getDeployerSigner(hre: HardhatRuntimeEnvironment): Promise<Signer> {
  const override = (hre as HreWithDeployHook).zamaWrapperDeploy?.getDeployerSigner;
  if (override) {
    return override(hre);
  }
  const { deployer } = await hre.getNamedAccounts();
  return hre.ethers.getSigner(deployer);
}

// Resolve the deployer address
export async function resolveDeployerAddress(hre: HardhatRuntimeEnvironment): Promise<string> {
  const override = (hre as HreWithDeployHook).zamaWrapperDeploy?.resolveDeployerAddress;
  if (override) {
    return override(hre);
  }
  // The exact account getDeployerSigner signs with (named `deployer` = accounts[0]).
  const { deployer } = await hre.getNamedAccounts();
  if (!deployer) {
    throw new Error('No signer configured: set PRIVATE_KEY or MNEMONIC');
  }
  return deployer;
}

// Artifact names are keyed by token symbol (e.g. `cUSDT`), not the human name, which can contain
// spaces/parens that make bad filenames (`ConfidentialWrapper_Confidential Token Test_Proxy.json`).
export function getConfidentialWrapperName(tokenSymbol: string): string {
  return `ConfidentialWrapper_${tokenSymbol}`;
}

export function getConfidentialWrapperImplName(tokenSymbol: string): string {
  return `ConfidentialWrapper_${tokenSymbol}_Impl`;
}

export function getConfidentialWrapperUpgradeImplName(label: string, name?: string): string {
  return name ? `ConfidentialWrapper_${name}_${label}_Impl` : `ConfidentialWrapper_${label}_Impl`;
}

export function getConfidentialWrapperProxyName(tokenSymbol: string): string {
  return `ConfidentialWrapper_${tokenSymbol}_Proxy`;
}

export type ConfidentialWrapperInitConfig = {
  name: string;
  symbol: string;
  contractUri: string;
  underlying: string;
  owner: string;
  blockedUsers: string[];
  underlyingDenyListSelector: string;
  initialObservers: string[];
};

function getRequiredJsonEnvVar<T>(name: string): T {
  return JSON.parse(getRequiredEnvVar(name)) as T;
}

async function deployConfidentialWrapper(initConfig: ConfidentialWrapperInitConfig, hre: HardhatRuntimeEnvironment) {
  const { ethers, upgrades, deployments } = hre;
  const { save, getArtifact } = deployments;
  const signer = await getDeployerSigner(hre);
  const deployer = await signer.getAddress();
  const { name, symbol, contractUri, underlying, owner, blockedUsers, underlyingDenyListSelector, initialObservers } =
    initConfig;

  // Connecting the factory to `signer` routes both the impl and proxy deploy through it.
  const confidentialWrapperFactory = await ethers.getContractFactory(CONTRACT_NAME, signer);
  const proxy = await upgrades.deployProxy(
    confidentialWrapperFactory,
    [name, symbol, contractUri, underlying, owner, blockedUsers, underlyingDenyListSelector, initialObservers],
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

  const implementationAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
  const artifact = await getArtifact(CONTRACT_NAME);
  await save(getConfidentialWrapperProxyName(symbol), { address: proxyAddress, abi: artifact.abi });
  await save(getConfidentialWrapperImplName(symbol), { address: implementationAddress, abi: artifact.abi });

  return proxyAddress;
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
// --initial-observers '[]' \
// --network sepolia
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
    'Function selector used to query the underlying token denylist; 0x00000000 disables the check',
    undefined,
    types.string,
  )
  .addOptionalParam('initialObservers', 'JSON array of observer addresses to seed during initialize', [], types.json)
  .setAction(async function (
    { name, symbol, contractUri, underlying, owner, blockedUsers, underlyingDenyListSelector, initialObservers },
    hre,
  ) {
    // Return the proxy address so callers can surface it without reconstructing the artifact name.
    return deployConfidentialWrapper(
      {
        name,
        symbol,
        contractUri,
        underlying,
        owner,
        blockedUsers,
        underlyingDenyListSelector,
        initialObservers,
      },
      hre,
    );
  });

// Deploy all confidential wrapper contracts
// Example usage:
// npx hardhat task:deployAllConfidentialWrappers --network sepolia
task('task:deployAllConfidentialWrappers').setAction(async function (_, hre) {
  console.log('Deploying confidential wrapper contracts...');

  const numWrappers = parseInt(getRequiredEnvVar('NUM_CONFIDENTIAL_WRAPPERS'));

  for (let i = 0; i < numWrappers; i++) {
    const name = getRequiredEnvVar(`CONFIDENTIAL_WRAPPER_NAME_${i}`);
    const symbol = getRequiredEnvVar(`CONFIDENTIAL_WRAPPER_SYMBOL_${i}`);
    const contractUri = getRequiredEnvVar(`CONFIDENTIAL_WRAPPER_CONTRACT_URI_${i}`);
    const underlying = getRequiredEnvVar(`CONFIDENTIAL_WRAPPER_UNDERLYING_ADDRESS_${i}`);
    const owner = getRequiredEnvVar(`CONFIDENTIAL_WRAPPER_OWNER_ADDRESS_${i}`);
    const blockedUsers = getRequiredJsonEnvVar<string[]>(`CONFIDENTIAL_WRAPPER_BLOCKED_USERS_${i}`);
    const underlyingDenyListSelector = getRequiredEnvVar(`CONFIDENTIAL_WRAPPER_UNDERLYING_DENY_LIST_SELECTOR_${i}`);
    const initialObserversEnv = process.env[`CONFIDENTIAL_WRAPPER_INITIAL_OBSERVERS_${i}`];
    const initialObservers =
      initialObserversEnv === undefined || initialObserversEnv.trim() === ''
        ? []
        : (JSON.parse(initialObserversEnv) as string[]);

    await hre.run('task:deployConfidentialWrapper', {
      name,
      symbol,
      contractUri,
      underlying,
      owner,
      blockedUsers,
      underlyingDenyListSelector,
      initialObservers,
    });
  }

  console.log('✅ All confidential wrapper contracts deployed\n');
});

// Deploy a bare ConfidentialWrapper implementation (no proxy), for an upgrade proposal: deploy it,
// then call `upgradeToAndCall(implAddress, reinitializeVX_calldata)` on the existing proxy.
function resolveOptionalTaskInput(cliValue: unknown, envName: string): string | undefined {
  if (typeof cliValue === 'string' && cliValue.trim() !== '') return cliValue.trim();
  const fromEnv = process.env[envName]?.trim();
  return fromEnv || undefined;
}

function assertArtifactSegment(value: string, field: string): string {
  if (!/^[A-Za-z0-9._-]+$/.test(value)) {
    throw new Error(`${field} must be a filesystem-safe identifier (e.g. cUSDT or v4), not "${value}"`);
  }
  return value;
}

async function deployConfidentialWrapperImpl(label: string, name: string | undefined, hre: HardhatRuntimeEnvironment) {
  const { ethers, deployments, network } = hre;
  const { save, getArtifact } = deployments;
  const deployerSigner = await getDeployerSigner(hre);
  const deployer = await deployerSigner.getAddress();
  const artifactName = getConfidentialWrapperUpgradeImplName(label, name);

  const factory = await ethers.getContractFactory(CONTRACT_NAME, deployerSigner);
  const implementation = await factory.deploy();
  await implementation.waitForDeployment();

  const implementationAddress = await implementation.getAddress();

  console.log(
    [
      `✅ Deployed ${CONTRACT_NAME} implementation:`,
      `  - Implementation address: ${implementationAddress}`,
      `  - Artifact: ${artifactName}`,
      `  - Deployed by deployer account: ${deployer}`,
      `  - Network: ${network.name}`,
      '',
    ].join('\n'),
  );

  const artifact = await getArtifact(CONTRACT_NAME);
  await save(artifactName, { address: implementationAddress, abi: artifact.abi });

  return implementationAddress;
}

task('task:deployConfidentialWrapperImpl')
  .addOptionalParam(
    'name',
    'Wrapper identifier included in the saved implementation artifact (e.g. "cUSDT"). Defaults to CONFIDENTIAL_WRAPPER_UPGRADE_NAME',
    undefined,
    types.string,
  )
  .addOptionalParam(
    'label',
    'Version label appended to the saved implementation artifact (e.g. "v4"). Defaults to CONFIDENTIAL_WRAPPER_UPGRADE_VERSION_LABEL',
    undefined,
    types.string,
  )
  .setAction(async function ({ name, label }, hre) {
    const resolvedLabel = resolveOptionalTaskInput(label, 'CONFIDENTIAL_WRAPPER_UPGRADE_VERSION_LABEL');
    if (!resolvedLabel) {
      throw new Error('Provide --label or set CONFIDENTIAL_WRAPPER_UPGRADE_VERSION_LABEL');
    }
    const resolvedName = resolveOptionalTaskInput(name, 'CONFIDENTIAL_WRAPPER_UPGRADE_NAME');
    const safeLabel = assertArtifactSegment(resolvedLabel, 'label');
    const safeName = resolvedName ? assertArtifactSegment(resolvedName, 'name') : undefined;
    const tag = safeName ? `${safeName} ${safeLabel}` : safeLabel;
    console.log(`Deploying ${CONTRACT_NAME} implementation (${tag})...\n`);
    await deployConfidentialWrapperImpl(safeLabel, safeName, hre);
  });

task('task:verifyConfidentialWrapperImpl')
  .addParam('implAddress', 'The address of the implementation contract to verify', '', types.string)
  .setAction(async function ({ implAddress }, hre) {
    const { run } = hre;
    console.log(`Verifying ${CONTRACT_NAME} implementation at ${implAddress}...\n`);
    await run('verify:verify', { address: implAddress, constructorArguments: [] });
  });
