import assert from "assert";
import { type DeployFunction } from "hardhat-deploy/types";

import {
  getBooleanEnvVar,
  getRequiredAddressEnvVar,
  getRequiredAddressListEnvVar,
  getRequiredUint48EnvVar,
} from "../tasks/utils/loadVariables";
import { getNetworkConfig, resolveRegistry } from "../tasks/utils/networks";

const CONTRACT_NAME = "ConfidentialWrapperPauser";

/**
 * Deploys the chain's ConfidentialWrapperPauser (P-RFC-006 migration step 1). Permissionless: anyone can run it,
 * the default admin (owner) is the governance address given in the environment, the default-admin transfer delay
 * comes from PAUSER_DEFAULT_ADMIN_DELAY (seconds), the registry the pauser gates on is the chain's
 * ConfidentialTokenWrappersRegistry from config/networks.json (PAUSER_REGISTRY_ADDRESS overrides it, for forks and
 * local runs), and the roster is seeded in the constructor.
 *
 * npx hardhat deploy --network <ethereum|sepolia|polygon|amoy>
 */
const deploy: DeployFunction = async (hre) => {
  const { getNamedAccounts, deployments, network } = hre;
  const { deployer } = await getNamedAccounts();
  assert(deployer, "Missing named deployer account");

  const admin = getRequiredAddressEnvVar("PAUSER_ADMIN_ADDRESS");
  const adminDelay = getRequiredUint48EnvVar("PAUSER_DEFAULT_ADMIN_DELAY");
  const initialPausers = getRequiredAddressListEnvVar("PAUSER_INITIAL_PAUSERS");
  // AccessControl would silently accept both; a roster typo must not reach the chain.
  if (initialPausers.some((address) => address === hre.ethers.ZeroAddress)) {
    throw new Error("PAUSER_INITIAL_PAUSERS must not contain the zero address");
  }
  if (new Set(initialPausers.map((address) => address.toLowerCase())).size !== initialPausers.length) {
    throw new Error("PAUSER_INITIAL_PAUSERS must not contain duplicates");
  }

  const registry = resolveRegistry(hre, process.env.PAUSER_REGISTRY_ADDRESS || undefined);
  if ((await hre.ethers.provider.getCode(registry)) === "0x") {
    throw new Error(`Registry ${registry} has no code on network "${network.name}"`);
  }

  const networkConfig = getNetworkConfig(network.name);
  if (networkConfig && admin.toLowerCase() !== networkConfig.governance.toLowerCase()) {
    const message =
      `PAUSER_ADMIN_ADDRESS ${admin} is not the expected ${networkConfig.governanceLabel} ` +
      `${networkConfig.governance} for network "${network.name}"`;
    if (!getBooleanEnvVar("PAUSER_ALLOW_ADMIN_MISMATCH")) {
      throw new Error(`${message}. Set PAUSER_ALLOW_ADMIN_MISMATCH=true to override.`);
    }
    console.warn(`⚠️  ${message} (override enabled)`);
  }

  console.log(`Network:         ${network.name}`);
  console.log(`Deployer:        ${deployer}`);
  console.log(`Admin (owner):   ${admin}`);
  console.log(`Admin delay:     ${adminDelay} s`);
  console.log(`Registry:        ${registry}`);
  console.log(`Initial pausers: ${JSON.stringify(initialPausers)}`);

  const { address, newlyDeployed } = await deployments.deploy(CONTRACT_NAME, {
    from: deployer,
    args: [adminDelay, admin, registry, initialPausers],
    log: true,
    skipIfAlreadyDeployed: false,
  });

  console.log(`✅ ${newlyDeployed ? "Deployed" : "Reused"} ${CONTRACT_NAME} on ${network.name} at ${address}`);
  console.log(
    `Verify with: npx hardhat task:verifyConfidentialWrapperPauser --address ${address} --network ${network.name}`,
  );
};

deploy.tags = [CONTRACT_NAME];

export default deploy;
