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
    } else if (network.name === "testnet") {
      aclAddress = "0xf0Ffdc93b7E186bC2f8CB3dAA75D86d1930A433D";
    } else {
      throw Error(`Unsupported network ${network.name}`);
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

// Example:
// npx hardhat task:allowForSafeMultiSig --safe 0x... --handle 0x... --proof 0x... --network mainnet
task("task:allowForSafeMultiSig")
  .addParam("safe", "The Safe account")
  .addParam("handle", "The external input handle")
  .addParam("proof", "The input proof bytes")
  .setAction(async function (taskArguments: TaskArguments, { ethers, network }) {
    const [proposer] = await ethers.getSigners();

    console.log("Calling allowForSafeMultiSig...");

    let helper;
    if (network.name === "mainnet") {
      helper = "0x26C5BBC241577b9a5D5A51AA961CC68103939836";
    } else if (network.name === "testnet") {
      helper = "0x3048Fb62cBeD3335e7B4E26461EB2fB63c5F320E";
    } else {
      throw Error(`Unsupported network ${network.name}`);
    }
    const multiSigHelper = await ethers.getContractAt("FHEVMMultiSigHelper", helper, proposer);
    const tx = await multiSigHelper.allowForSafeMultiSig(
      taskArguments.safe,
      [taskArguments.handle],
      taskArguments.proof,
    );
    console.log("Transaction hash:", tx.hash);
    await tx.wait();

    console.log("allowForSafeMultiSig executed successfully!");
  });

// Example:
// npx hardhat task:allowForCustomMultiSigOwners --multisig 0x... --owners 0x...,0x...,...,0x... --handle 0x... --proof 0x... --network mainnet
task("task:allowForCustomMultiSigOwners")
  .addParam("multisig", "The multisig account")
  .addParam("owners", "The owners of the multisig account")
  .addParam("handle", "The external input handle")
  .addParam("proof", "The input proof bytes")
  .setAction(async function (taskArguments: TaskArguments, { ethers, network }) {
    const [proposer] = await ethers.getSigners();

    console.log("Calling allowForCustomMultiSigOwners...");

    let helper;
    if (network.name === "mainnet") {
      helper = "0x26C5BBC241577b9a5D5A51AA961CC68103939836";
    } else if (network.name === "testnet") {
      helper = "0x3048Fb62cBeD3335e7B4E26461EB2fB63c5F320E";
    } else {
      throw Error(`Unsupported network ${network.name}`);
    }
    const multiSigHelper = await ethers.getContractAt("FHEVMMultiSigHelper", helper, proposer);
    const owners = taskArguments.owners.split(",");
    console.log("owners: ", owners);
    const tx = await multiSigHelper.allowForCustomMultiSigOwners(
      taskArguments.multisig,
      owners,
      [taskArguments.handle],
      taskArguments.proof,
    );
    console.log("Transaction hash:", tx.hash);
    await tx.wait();

    console.log("allowForCustomMultiSigOwners executed successfully!");
  });
