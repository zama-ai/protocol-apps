import { task } from "hardhat/config";
import type { TaskArguments } from "hardhat/types";

// Example:
// npx hardhat task:verifyFHEVMMultiSigHelper --address 0x... --network mainnet
task("task:verifyFHEVMMultiSigHelper")
  .addParam("address", "The deployed FHEVMMultiSigHelper contract address")
  .setAction(async function (taskArguments: TaskArguments, { run }) {
    console.log("Verifying FHEVMMultiSigHelper at:", taskArguments.address);

    await run("verify:verify", {
      address: taskArguments.address,
      contract: "contracts/FHEVMMultiSigHelper.sol:FHEVMMultiSigHelper",
    });

    console.log("FHEVMMultiSigHelper verified successfully!");
  });
