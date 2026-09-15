import assert from "assert";
import { type DeployFunction } from "hardhat-deploy/types";

import { getBooleanEnvVar, getRequiredAddressEnvVar, getRequiredAddressListEnvVar } from "../tasks/utils/loadVariables";
import { getNetworkConfig } from "../tasks/utils/networks";

const CONTRACT_NAME = "ConfidentialWrapperPauser";

/**
 * Deploys the chain's ConfidentialWrapperPauser (P-RFC-006 migration step 1). Permissionless: anyone can run it,
 * the owner is the governance address given in the environment and the roster is seeded in the constructor.
 *
 * npx hardhat deploy --network <ethereum|sepolia|polygon|amoy>
 */
const deploy: DeployFunction = async (hre) => {
  const { getNamedAccounts, deployments, network } = hre;
  const { deployer } = await getNamedAccounts();
  assert(deployer, "Missing named deployer account");

  const owner = getRequiredAddressEnvVar("PAUSER_OWNER_ADDRESS");
  const initialPausers = getRequiredAddressListEnvVar("PAUSER_INITIAL_PAUSERS");
  // The constructor would silently accept both; a roster typo must not reach the chain.
  if (initialPausers.some((address) => address === hre.ethers.ZeroAddress)) {
    throw new Error("PAUSER_INITIAL_PAUSERS must not contain the zero address");
  }
  if (new Set(initialPausers.map((address) => address.toLowerCase())).size !== initialPausers.length) {
    throw new Error("PAUSER_INITIAL_PAUSERS must not contain duplicates");
  }

  const networkConfig = getNetworkConfig(network.name);
  if (networkConfig && owner.toLowerCase() !== networkConfig.governance.toLowerCase()) {
    const message =
      `PAUSER_OWNER_ADDRESS ${owner} is not the expected ${networkConfig.governanceLabel} ` +
      `${networkConfig.governance} for network "${network.name}"`;
    if (!getBooleanEnvVar("PAUSER_ALLOW_OWNER_MISMATCH")) {
      throw new Error(`${message}. Set PAUSER_ALLOW_OWNER_MISMATCH=true to override.`);
    }
    console.warn(`⚠️  ${message} (override enabled)`);
  }

  console.log(`Network:         ${network.name}`);
  console.log(`Deployer:        ${deployer}`);
  console.log(`Owner:           ${owner}`);
  console.log(`Initial pausers: ${JSON.stringify(initialPausers)}`);

  const { address, newlyDeployed } = await deployments.deploy(CONTRACT_NAME, {
    from: deployer,
    args: [owner, initialPausers],
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
