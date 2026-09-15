import { task, types } from "hardhat/config";

import { WRAPPER_ABI, getNetworkConfig, listValidWrappers, parseAddressList, resolveRegistry } from "./utils/networks";

const PAUSER_ABI = [
  "function defaultAdmin() view returns (address)",
  "function pendingDefaultAdmin() view returns (address newAdmin, uint48 acceptSchedule)",
  "function defaultAdminDelay() view returns (uint48)",
  "function pausers() view returns (address[])",
];

interface CheckPausersArgs {
  pauser: string;
  registry?: string;
  expectedPausers?: string;
  include?: string;
  strict: boolean;
}

/**
 * Post-execution assertion and drift check (P-RFC-006 success criteria 1 and 2): every valid wrapper of the
 * registry must report `pauser() == <chain ConfidentialWrapperPauser>`, the pauser's default admin (owner) must be
 * the chain's governance, and, when given, `pausers()` must equal the agreed roster.
 *
 * Example usage:
 * npx hardhat task:checkPausers --pauser 0xPauser --network sepolia
 * npx hardhat task:checkPausers --pauser 0xPauser --expected-pausers 0xA,0xB --network ethereum
 */
task("task:checkPausers", "Asserts every registered wrapper is armed with the chain pauser and reports the roster")
  .addParam("pauser", "The chain's ConfidentialWrapperPauser address")
  .addOptionalParam("registry", "Registry to enumerate (defaults to config/networks.json)")
  .addOptionalParam("expectedPausers", "Comma-separated roster the on-chain pausers() must equal")
  .addOptionalParam("include", "Comma-separated extra wrapper addresses to check besides the registry")
  .addOptionalParam("strict", "Exit with code 1 on any mismatch", true, types.boolean)
  .setAction(async function (args: CheckPausersArgs, hre) {
    const { ethers, network } = hre;
    const pauserAddress = ethers.getAddress(args.pauser);
    const registry = resolveRegistry(hre, args.registry);
    const networkConfig = getNetworkConfig(network.name);
    const failures: string[] = [];

    console.log(`Network:  ${network.name}`);
    console.log(`Registry: ${registry}`);
    console.log(`Pauser:   ${pauserAddress}`);

    // --- Pauser contract: default admin and roster ---
    const pauserContract = new ethers.Contract(pauserAddress, PAUSER_ABI, ethers.provider);
    const admin: string = await pauserContract.defaultAdmin();
    const [pendingAdmin, acceptSchedule]: [string, bigint] = await pauserContract.pendingDefaultAdmin();
    const adminDelay: bigint = await pauserContract.defaultAdminDelay();
    const roster: string[] = await pauserContract.pausers();

    console.log(`\nAdmin (owner): ${admin} (transfer delay ${adminDelay} s)`);
    if (networkConfig && admin.toLowerCase() !== networkConfig.governance.toLowerCase()) {
      failures.push(`admin ${admin} is not ${networkConfig.governanceLabel} ${networkConfig.governance}`);
    }
    if (acceptSchedule !== 0n) {
      const when = new Date(Number(acceptSchedule) * 1000).toISOString();
      console.warn(`⚠️  pending default admin transfer to ${pendingAdmin}, acceptable from ${when}`);
    }

    console.log(`Roster (${roster.length}):`);
    for (const member of roster) console.log(`  - ${member}`);

    if (args.expectedPausers !== undefined) {
      const expected = parseAddressList(args.expectedPausers, "--expected-pausers")
        .map((a) => a.toLowerCase())
        .sort();
      const actual = roster.map((a) => a.toLowerCase()).sort();
      if (JSON.stringify(expected) !== JSON.stringify(actual)) {
        failures.push(`roster mismatch: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
      }
    }

    // --- Wrappers: pauser() must be the chain pauser ---
    const wrappers = await listValidWrappers(hre, registry);
    for (const extra of parseAddressList(args.include, "--include")) {
      wrappers.push({ token: ethers.ZeroAddress, wrapper: extra, symbol: "(--include)" });
    }

    console.log(`\nWrappers (${wrappers.length}):`);
    for (const entry of wrappers) {
      const wrapper = new ethers.Contract(entry.wrapper, WRAPPER_ABI, ethers.provider);
      let line = `  ${entry.symbol.padEnd(16)} ${entry.wrapper}`;
      try {
        const [currentPauser, paused] = await Promise.all([wrapper.pauser(), wrapper.paused()]);
        const armed = currentPauser.toLowerCase() === pauserAddress.toLowerCase();
        line += ` pauser=${currentPauser} paused=${paused} ${armed ? "✅" : "❌"}`;
        if (!armed) failures.push(`${entry.symbol} ${entry.wrapper}: pauser() is ${currentPauser}`);
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        line += ` ❌ read failed: ${msg}`;
        failures.push(`${entry.symbol} ${entry.wrapper}: pauser()/paused() read failed`);
      }
      console.log(line);
    }

    // --- Verdict ---
    if (failures.length === 0) {
      console.log(`\n✅ ${wrappers.length} wrapper(s) armed with ${pauserAddress}; admin and roster as expected.`);
      return;
    }
    console.error(`\n❌ ${failures.length} problem(s):`);
    for (const failure of failures) console.error(`  - ${failure}`);
    if (args.strict) process.exitCode = 1;
  });
