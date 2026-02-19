import "dotenv/config";
import { task, types } from "hardhat/config";
import { TaskArguments } from "hardhat/types";

// Example usage:
// npx hardhat task:allowHandle --handle 0x... --account 0x... --network mainnet
task("task:allowHandle")
  .addParam("handle", "The encrypted handle (bytes32) to allow", undefined, types.string)
  .addParam("account", "The account or contract address to allow the handle to", undefined, types.string)
  .setAction(async function (taskArguments: TaskArguments, { ethers, network }) {
    const [signer] = await ethers.getSigners();

    let aclAddress: string;
    if (network.name == "mainnet") {
      aclAddress = "0xcA2E8f1F656CD25C01F05d0b243Ab1ecd4a8ffb6";
    } else {
      throw new Error(`This task is currently only available for calling ACL on mainnet. Network: ${network.name}`);
    }

    const aclAbi = ["function allow(bytes32 handle, address account) external"];
    const acl = new ethers.Contract(aclAddress, aclAbi, signer);

    console.log(`Allowing handle ${taskArguments.handle} to account ${taskArguments.account}...`);
    console.log(`Signer: ${signer.address}`);

    const tx = await acl.allow(taskArguments.handle, taskArguments.account);
    console.log("Transaction hash:", tx.hash);
    await tx.wait();

    console.log("Handle allowed successfully!");
  });
