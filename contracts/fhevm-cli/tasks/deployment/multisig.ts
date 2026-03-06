import { task } from "hardhat/config";
import type { TaskArguments } from "hardhat/types";

// Example:
// npx hardhat task:deployFHEVMMultiSigHelper --network mainnet
task("task:deployFHEVMMultiSigHelper")
  .setAction(async function (taskArguments: TaskArguments, { ethers }) {
    const [proposer] = await ethers.getSigners();

    console.log("Deploying FHEVMMultiSigHelper...");
    const multiSigHelperFactory = await ethers.getContractFactory("FHEVMMultiSigHelper", proposer);
    const multiSigHelper = await multiSigHelperFactory.deploy();
    await multiSigHelper.waitForDeployment();
    const multiSigHelperAddress = await multiSigHelper.getAddress();

    console.log("FHEVMMultiSigHelper deployed at:", multiSigHelperAddress);
    return multiSigHelperAddress;
  });

// Example:
// npx hardhat task:allowForSafeMultiSig --helper 0x... --safe 0x... --handle 0x... --proof 0x... --network mainnet
task("task:allowForSafeMultiSig")
  .addParam("helper", "The deployed FHEVMMultiSigHelper contract address") // TOOD: remove this argument and replace it by hardcoded address
  .addParam("safe", "The Safe account")
  .addParam("handle", "The external input handle")
  .addParam("proof", "The input proof bytes")
  .setAction(async function (taskArguments: TaskArguments, { ethers }) {
    const [proposer] = await ethers.getSigners();

    console.log("Calling allowForSafeMultiSig...");
    const multiSigHelper = await ethers.getContractAt("FHEVMMultiSigHelper", taskArguments.helper, proposer);
    const tx = await multiSigHelper.allowForSafeMultiSig(taskArguments.safe, [taskArguments.handle], taskArguments.proof);
    console.log("Transaction hash:", tx.hash);
    await tx.wait();

    console.log("allowForSafeMultiSig executed successfully!");
  });

   // TOOD: add task:allowForCustomMultiSigOwners and test it with Aragon
