import "dotenv/config";
import { task, types } from "hardhat/config";
import { HardhatRuntimeEnvironment } from "hardhat/types";

// Example usage:
// npx hardhat task:publicDecrypt --handle 0x... --network mainnet
task("task:publicDecrypt")
  .addParam("handle", "Ciphertext handle to public decrypt", undefined, types.string)
  .setAction(async function ({ handle }, hre: HardhatRuntimeEnvironment) {
    await hre.fhevm.initializeCLIApi();
    const publicDecryptedHandle = await hre.fhevm.publicDecrypt([handle]);
    console.log(`Public decrypted value for handle ${handle} is: `, publicDecryptedHandle.clearValues[handle]);
    console.log(`Abi-encoded cleartext is: `, publicDecryptedHandle.abiEncodedClearValues);
    console.log(`DecryptionProof is: `, publicDecryptedHandle.decryptionProof);
  });
