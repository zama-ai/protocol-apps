import { task } from "hardhat/config";
import type { TaskArguments } from "hardhat/types";

// Example:
// npx hardhat task:verifyMultiSigHelper --address 0x... --multisig 0x... --network mainnet
task("task:verifyMultiSigHelper")
  .addParam("address", "The deployed MultiSigHelper contract address")
  .addParam("multisig", "The MultiSig contract address (constructor argument)")
  .setAction(async function (taskArguments: TaskArguments, { run }) {
    console.log("Verifying MultiSigHelper at:", taskArguments.address);

    await run("verify:verify", {
      address: taskArguments.address,
      constructorArguments: [taskArguments.multisig],
      contract: "contracts/MultiSigHelper.sol:MultiSigHelper",
    });

    console.log("MultiSigHelper verified successfully!");
  });
