import { task } from "hardhat/config";
import type { TaskArguments } from "hardhat/types";

// Example:
// npx hardhat task:deployMultiSigHelper --multisig 0x... --network mainnet
task("task:deployMultiSigHelper")
  .addParam("multisig", "The address of the MultiSig contract")
  .setAction(async function (taskArguments: TaskArguments, { ethers }) {
    const [proposer] = await ethers.getSigners();

    console.log("Deploying MultiSigHelper...");
    const multiSigHelperFactory = await ethers.getContractFactory("MultiSigHelper", proposer);
    const multiSigHelper = await multiSigHelperFactory.deploy(taskArguments.multisig);
    await multiSigHelper.waitForDeployment();
    const multiSigHelperAddress = await multiSigHelper.getAddress();

    console.log("MultiSigHelper deployed at:", multiSigHelperAddress);
    return multiSigHelperAddress;
  });

// Example:
// npx hardhat task:allowForMultiSig --helper 0x... --handle 0x... --proof 0x... --network mainnet
task("task:allowForMultiSig")
  .addParam("helper", "The deployed MultiSigHelper contract address")
  .addParam("handle", "The external euint64 input handle")
  .addParam("proof", "The input proof bytes")
  .setAction(async function (taskArguments: TaskArguments, { ethers }) {
    const [proposer] = await ethers.getSigners();

    console.log("Calling allowForMultiSig...");
    const multiSigHelper = await ethers.getContractAt("MultiSigHelper", taskArguments.helper, proposer);
    const tx = await multiSigHelper.allowForMultiSig(taskArguments.handle, taskArguments.proof);
    console.log("Transaction hash:", tx.hash);
    await tx.wait();

    console.log("allowForMultiSig executed successfully!");
  });
