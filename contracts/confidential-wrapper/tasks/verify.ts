import { CONTRACT_NAME, getConfidentialWrapperProxyName } from './deploy';
import { getRequiredEnvVar } from './utils/loadVariables';
import { task, types } from 'hardhat/config';
import type { HardhatRuntimeEnvironment } from 'hardhat/types';

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
  return entries.every(entry => ALREADY_VERIFIED.test(entry));
}

/**
 * Verify on every explorer enabled in hardhat.config.
 *
 * - Etherscan: required (OZ hardhat-upgrades intercepts `verify:etherscan` for proxies).
 * - Blockscout / Sourcify: best-effort — failures must not fail the task after Etherscan has
 *   already succeeded. Pass `bestEffort: false` to skip them for an address they cannot verify.
 */
async function verifyOnEnabledExplorers(
  hre: HardhatRuntimeEnvironment,
  address: string,
  constructorArguments: unknown[] = [],
  { bestEffort = true }: { bestEffort?: boolean } = {},
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

  if (!bestEffort) return;

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

    // Etherscan only for the proxy: it is OZ's precompiled ERC1967Proxy, not an artifact of this
    // project, and it takes two constructor arguments. Blockscout and Sourcify would therefore warn
    // on every single run, training operators to ignore the warnings that do matter on the
    // implementation. Etherscan still gets the call because that is what links proxy to
    // implementation in its UI.
    console.log(`Verifying confidential wrapper proxy contract at ${proxyAddress}...\n`);
    await verifyOnEnabledExplorers(hre, proxyAddress, [], { bestEffort: false });

    console.log(`Verifying confidential wrapper implementation contract at ${implementationAddress}...\n`);
    await verifyOnEnabledExplorers(hre, implementationAddress, []);
  });

// Verify a bare ConfidentialWrapper implementation (no proxy).
// Example usage:
// npx hardhat task:verifyConfidentialWrapperImpl \
//   --impl-address 0x1234567890123456789012345678901234567890 \
//   --network sepolia
task('task:verifyConfidentialWrapperImpl')
  .addParam('implAddress', 'The address of the implementation contract to verify', '', types.string)
  .setAction(async function ({ implAddress }, hre) {
    console.log(`Verifying ${CONTRACT_NAME} implementation at ${implAddress}...\n`);
    await verifyOnEnabledExplorers(hre, implAddress, []);
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
