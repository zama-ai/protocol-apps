import { task } from "hardhat/config";
import type { HardhatRuntimeEnvironment } from "hardhat/types";

import { getRequiredAddressEnvVar, getRequiredAddressListEnvVar, getRequiredUint48EnvVar } from "./utils/loadVariables";

const ALREADY_VERIFIED = /already verified/i;

/**
 * Whether an explorer failure is nothing but "this is already verified".
 */
function isAlreadyVerified(err: unknown): boolean {
  const message = err instanceof Error ? err.message : String(err);
  const entries = message.split(/\n\n(?:Error|Warning) \d+: /).slice(1);
  if (entries.length === 0) {
    return ALREADY_VERIFIED.test(message);
  }
  return entries.every((entry) => ALREADY_VERIFIED.test(entry));
}

/**
 * Verify on every explorer enabled in hardhat.config.
 *
 * - Etherscan: required.
 * - Blockscout / Sourcify: best-effort — failures must not fail the task after Etherscan has already succeeded.
 */
export async function verifyOnEnabledExplorers(
  hre: HardhatRuntimeEnvironment,
  address: string,
  constructorArguments: unknown[] = [],
): Promise<void> {
  const { run, config } = hre;

  if (config.etherscan.enabled !== false) {
    try {
      await run("verify:etherscan", {
        address,
        constructorArgsParams: constructorArguments,
      });
    } catch (err) {
      if (!isAlreadyVerified(err)) throw err;
      console.log(`Already verified on Etherscan: ${address}`);
    }
  }

  if (config.blockscout?.enabled) {
    try {
      await run("verify:blockscout", { address });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      if (isAlreadyVerified(err)) {
        console.log(`Already verified on Blockscout: ${address}`);
      } else {
        console.warn(`Blockscout verification failed for ${address} (best-effort):\n${msg}`);
      }
    }
  }

  if (config.sourcify?.enabled) {
    try {
      await run("verify:sourcify", { address });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      if (isAlreadyVerified(err)) {
        console.log(`Already verified on Sourcify: ${address}`);
      } else {
        console.warn(`Sourcify verification failed for ${address} (best-effort):\n${msg}`);
      }
    }
  }
}

// Verify a deployed ConfidentialWrapperPauser. The constructor arguments are read from the same environment
// variables the deploy script used (PAUSER_DEFAULT_ADMIN_DELAY, PAUSER_ADMIN_ADDRESS, PAUSER_INITIAL_PAUSERS).
// Example usage:
// npx hardhat task:verifyConfidentialWrapperPauser --address 0x1234... --network sepolia
task("task:verifyConfidentialWrapperPauser", "Verifies a deployed ConfidentialWrapperPauser on the enabled explorers")
  .addParam("address", "Address of the deployed ConfidentialWrapperPauser")
  .setAction(async function ({ address }: { address: string }, hre) {
    const adminDelay = getRequiredUint48EnvVar("PAUSER_DEFAULT_ADMIN_DELAY");
    const admin = getRequiredAddressEnvVar("PAUSER_ADMIN_ADDRESS");
    const initialPausers = getRequiredAddressListEnvVar("PAUSER_INITIAL_PAUSERS");

    console.log(`Verifying ConfidentialWrapperPauser at ${address} on ${hre.network.name}`);
    console.log(`  admin delay:     ${adminDelay} s`);
    console.log(`  admin (owner):   ${admin}`);
    console.log(`  initial pausers: ${JSON.stringify(initialPausers)}`);

    await verifyOnEnabledExplorers(hre, address, [adminDelay.toString(), admin, initialPausers]);
  });
