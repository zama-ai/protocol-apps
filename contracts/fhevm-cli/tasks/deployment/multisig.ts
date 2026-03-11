import { task } from "hardhat/config";
import type { TaskArguments } from "hardhat/types";

// Example:
// npx hardhat task:deployFHEVMMultiSigHelper --network mainnet
task("task:deployFHEVMMultiSigHelper").setAction(async function ({ ethers }) {
  const [proposer] = await ethers.getSigners();

  console.log("Deploying FHEVMMultiSigHelper...");
  const multiSigHelperFactory = await ethers.getContractFactory("FHEVMMultiSigHelper", proposer);
  const multiSigHelper = await multiSigHelperFactory.deploy();
  await multiSigHelper.waitForDeployment();
  const multiSigHelperAddress = await multiSigHelper.getAddress();

  console.log("FHEVMMultiSigHelper deployed at:", multiSigHelperAddress);
  return multiSigHelperAddress;
});
