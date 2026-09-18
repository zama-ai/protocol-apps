import { task, types } from "hardhat/config";

import {
  WRAPPER_ABI,
  listRegisteredWrappers,
  parseAddressList,
  preflightPauser,
  resolveGovernance,
  resolveRegistry,
  wrapperLabel,
} from "./utils/networks";

interface CheckPausersArgs {
  pauser: string;
  registry?: string;
  governance?: string;
  expectedPausers?: string;
  include?: string;
  strict: boolean;
}

/**
 * Post-execution assertion and drift check (P-RFC-006 success criteria 1 and 2): every wrapper registered in the
 * registry, revoked pairs included (revocation only flips the registry flag, the wrapper keeps running), must report
 * `pauser() == <chain ConfidentialWrapperPauser>` and `owner() == governance` (a wrapper
 * transferred away from governance could not be unpaused, re-armed or upgraded by it), the pauser's owner must be
 * the chain's governance, and, when given, `pausers()` must equal the agreed roster. Governance comes from
 * `config/networks.json` or `--governance`; without either, the pauser's own owner is the reference.
 *
 * Example usage:
 * npx hardhat task:checkPausers --pauser 0xPauser --network sepolia
 * npx hardhat task:checkPausers --pauser 0xPauser --expected-pausers 0xA,0xB --network ethereum
 */
task("task:checkPausers", "Asserts every registered wrapper is armed with the chain pauser and reports the roster")
  .addParam("pauser", "The chain's ConfidentialWrapperPauser address")
  .addOptionalParam("registry", "Registry to enumerate (defaults to config/networks.json)")
  .addOptionalParam("governance", "Expected owner of the pauser and the wrappers (defaults to config/networks.json)")
  .addOptionalParam("expectedPausers", "Comma-separated roster the on-chain pausers() must equal")
  .addOptionalParam("include", "Comma-separated extra wrapper addresses to check besides the registry")
  .addOptionalParam("strict", "Exit with code 1 on any mismatch", true, types.boolean)
  .setAction(async function (args: CheckPausersArgs, hre) {
    const { ethers, network } = hre;
    const pauserAddress = ethers.getAddress(args.pauser);
    const registry = resolveRegistry(hre, args.registry);
    const governance = resolveGovernance(hre, args.governance);
    const failures: string[] = [];

    console.log(`Network:  ${network.name}`);
    console.log(`Registry: ${registry}`);
    console.log(`Pauser:   ${pauserAddress}`);

    // --- Pauser contract: owner and roster ---
    const { state, problems, warnings } = await preflightPauser(hre, pauserAddress, governance);
    const { owner, roster } = state;
    failures.push(...problems);
    for (const warning of warnings) console.warn(`⚠️  ${warning}`);

    console.log(`\nOwner: ${owner}${governance ? ` (expected ${governance.label} ${governance.address})` : ""}`);

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

    // --- Wrappers: pauser() must be the chain pauser, owner() must be governance ---
    const expectedOwner = governance ?? { address: owner, label: "the pauser's owner" };
    const wrappers = await listRegisteredWrappers(hre, registry);
    for (const extra of parseAddressList(args.include, "--include")) {
      wrappers.push({ token: ethers.ZeroAddress, wrapper: extra, symbol: "(--include)", revoked: false });
    }

    console.log(`\nWrappers (${wrappers.length}), expected owner ${expectedOwner.label} ${expectedOwner.address}:`);
    for (const entry of wrappers) {
      const wrapper = new ethers.Contract(entry.wrapper, WRAPPER_ABI, ethers.provider);
      let line = `  ${wrapperLabel(entry)}`;
      try {
        const [currentPauser, paused, wrapperOwner]: [string, boolean, string] = await Promise.all([
          wrapper.pauser(),
          wrapper.paused(),
          wrapper.owner(),
        ]);
        const armed = currentPauser.toLowerCase() === pauserAddress.toLowerCase();
        const owned = wrapperOwner.toLowerCase() === expectedOwner.address.toLowerCase();
        line += ` pauser=${currentPauser} paused=${paused} owner=${wrapperOwner} ${armed && owned ? "✅" : "❌"}`;
        if (!armed) failures.push(`${entry.symbol} ${entry.wrapper}: pauser() is ${currentPauser}`);
        if (!owned) {
          failures.push(`${entry.symbol} ${entry.wrapper}: owner() is ${wrapperOwner}, not ${expectedOwner.address}`);
        }
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        line += ` ❌ read failed: ${msg}`;
        failures.push(`${entry.symbol} ${entry.wrapper}: pauser()/paused()/owner() read failed`);
      }
      console.log(line);
    }

    // --- Verdict ---
    if (failures.length === 0) {
      console.log(
        `\n✅ ${wrappers.length} wrapper(s) armed with ${pauserAddress} and owned by ${expectedOwner.address}; ` +
          "pauser owner and roster as expected.",
      );
      return failures;
    }
    console.error(`\n❌ ${failures.length} problem(s):`);
    for (const failure of failures) console.error(`  - ${failure}`);
    if (args.strict) process.exitCode = 1;
    return failures;
  });
