import { getConfidentialWrapperProxyName } from './deploy';
import { getRequiredEnvVar } from './utils/loadVariables';
import { task, types } from 'hardhat/config';
import type { HardhatRuntimeEnvironment } from 'hardhat/types';

function isAlreadyVerified(err: unknown): boolean {
  return /already verified/i.test(err instanceof Error ? err.message : String(err));
}

/**
 * Verify on every explorer enabled in hardhat.config.
 *
 * - Etherscan: required (OZ hardhat-upgrades intercepts `verify:etherscan` for proxies).
 * - Blockscout / Sourcify: best-effort — proxy bytecode is OZ's precompiled 0.8.29 artifact, so
 *   those providers often cannot match this repo's 0.8.27 compile; failures must not fail the task
 *   after Etherscan succeeds. (`verify:verify` also skips Blockscout entirely.)
 */
async function verifyOnEnabledExplorers(
  hre: HardhatRuntimeEnvironment,
  address: string,
  constructorArguments: unknown[] = [],
): Promise<void> {
  const { run, config } = hre;

  if (config.etherscan.enabled !== false) {
    try {
      // Prefer verify:etherscan so OZ's proxy interceptor runs; verify:verify would also kick off
      // Sourcify in-process and could throw after a successful Etherscan verify.
      await run('verify:etherscan', {
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
      await run('verify:blockscout', { address });
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
      await run('verify:sourcify', { address });
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

// Verify a confidential wrapper contract
// Example usage:
// npx hardhat task:verifyConfidentialWrapper --proxy-address 0x1234567890123456789012345678901234567890 --network sepolia
task('task:verifyConfidentialWrapper')
  .addParam('proxyAddress', 'The address of the confidential wrapper proxy contract to verify', '', types.string)
  .setAction(async function ({ proxyAddress }, hre) {
    const { upgrades } = hre;

    const implementationAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);

    console.log(`Verifying confidential wrapper proxy contract at ${proxyAddress}...\n`);
    await verifyOnEnabledExplorers(hre, proxyAddress, []);

    console.log(`Verifying confidential wrapper implementation contract at ${implementationAddress}...\n`);
    await verifyOnEnabledExplorers(hre, implementationAddress, []);
  });

// Verify all confidential wrapper contracts
// Since all confidential wrapper contracts share the same implementation, we normally only have to
// verify one of them. However, since they are proxied, verifying all of them has the benefit of linking
// the proxies with their implementation on Etherscan.
// Example usage:
// npx hardhat task:verifyAllConfidentialWrappers --network sepolia
task('task:verifyAllConfidentialWrappers').setAction(async function (_, hre) {
  const { run, deployments } = hre;
  const { get } = deployments;

  const numWrappers = parseInt(getRequiredEnvVar('NUM_CONFIDENTIAL_WRAPPERS'));

  for (let i = 0; i < numWrappers; i++) {
    const symbol = getRequiredEnvVar(`CONFIDENTIAL_WRAPPER_SYMBOL_${i}`);

    try {
      const proxyAddress = await get(getConfidentialWrapperProxyName(symbol));
      await run('task:verifyConfidentialWrapper', { proxyAddress: proxyAddress.address });
    } catch (error) {
      console.error('An error occurred:', error);
    }
  }
});
