import { mkdirSync, writeFileSync } from "fs";
import { task } from "hardhat/config";
import { dirname } from "path";

import { WRAPPER_ABI, getNetworkConfig, listValidWrappers, parseAddressList, resolveRegistry } from "./utils/networks";

interface SetPauserProposalArgs {
  pauser: string;
  registry?: string;
  include?: string;
  exclude?: string;
  out?: string;
}

interface ProposalAction {
  symbol: string;
  to: string;
  value: string;
  data: string;
  currentPauser: string;
}

/**
 * Builds the per-chain governance payload of P-RFC-006 migration step 2: one `setPauser(pauser)` action per valid
 * wrapper in the registry, derived at proposal time (never hard-coded). Wrappers already armed with `pauser` are
 * skipped, so the task is idempotent and can be re-run after new wrappers are registered.
 *
 * The JSON output lists `{to, value, data}` actions ready to be entered in the Aragon app (Ethereum, Sepolia) or
 * a Safe transaction builder (Polygon, Amoy); the `cast` recipes reproduce each calldata for reviewers.
 *
 * Example usage:
 * npx hardhat task:setPauserProposal --pauser 0xPauser --network sepolia --out out/sepolia-setPauser.json
 */
task("task:setPauserProposal", "Emits the setPauser(pauser) actions for every registered wrapper of the chain")
  .addParam("pauser", "The chain's ConfidentialWrapperPauser address")
  .addOptionalParam("registry", "Registry to enumerate (defaults to config/networks.json)")
  .addOptionalParam("include", "Comma-separated extra wrapper addresses to arm besides the registry")
  .addOptionalParam("exclude", "Comma-separated wrapper addresses to leave out")
  .addOptionalParam("out", "Write the JSON payload to this file instead of only printing it")
  .setAction(async function (args: SetPauserProposalArgs, hre) {
    const { ethers, network } = hre;
    const pauserAddress = ethers.getAddress(args.pauser);
    const registry = resolveRegistry(hre, args.registry);
    const networkConfig = getNetworkConfig(network.name);
    const excluded = new Set(parseAddressList(args.exclude, "--exclude").map((a) => a.toLowerCase()));

    const wrappers = await listValidWrappers(hre, registry);
    for (const extra of parseAddressList(args.include, "--include")) {
      wrappers.push({ token: ethers.ZeroAddress, wrapper: extra, symbol: "(--include)" });
    }

    const iface = new ethers.Interface(WRAPPER_ABI);
    const actions: ProposalAction[] = [];
    const skipped: string[] = [];
    const owners = new Set<string>();

    for (const entry of wrappers) {
      if (excluded.has(entry.wrapper.toLowerCase())) continue;
      const wrapper = new ethers.Contract(entry.wrapper, WRAPPER_ABI, ethers.provider);
      const [currentPauser, owner] = await Promise.all([wrapper.pauser(), wrapper.owner()]);
      owners.add(owner);
      if (currentPauser.toLowerCase() === pauserAddress.toLowerCase()) {
        skipped.push(`${entry.symbol} ${entry.wrapper} (already armed)`);
        continue;
      }
      actions.push({
        symbol: entry.symbol,
        to: entry.wrapper,
        value: "0",
        data: iface.encodeFunctionData("setPauser", [pauserAddress]),
        currentPauser,
      });
    }

    const payload = {
      network: network.name,
      chainId: Number((await ethers.provider.getNetwork()).chainId),
      registry,
      pauser: pauserAddress,
      expectedProposer: networkConfig ? `${networkConfig.governanceLabel} ${networkConfig.governance}` : "unknown",
      wrapperOwners: [...owners],
      actions,
    };

    console.log(`Network:  ${network.name}`);
    console.log(`Registry: ${registry}`);
    console.log(`Pauser:   ${pauserAddress}`);
    console.log(`Wrapper owner(s): ${[...owners].join(", ")}`);
    if (networkConfig && [...owners].some((o) => o.toLowerCase() !== networkConfig.governance.toLowerCase())) {
      console.warn(`⚠️  some wrappers are not owned by ${networkConfig.governanceLabel}; check the proposer.`);
    }
    for (const line of skipped) console.log(`  skip ${line}`);
    console.log(`\n${actions.length} setPauser action(s):`);
    for (const action of actions) {
      console.log(`  ${action.symbol.padEnd(16)} ${action.to}  current pauser ${action.currentPauser}`);
    }
    console.log("\nReviewer recipe (same calldata for every action):");
    console.log(`  cast calldata "setPauser(address)" ${pauserAddress}`);
    console.log(`  -> ${iface.encodeFunctionData("setPauser", [pauserAddress])}`);

    const json = JSON.stringify(payload, null, 2);
    if (args.out) {
      mkdirSync(dirname(args.out), { recursive: true });
      writeFileSync(args.out, `${json}\n`);
      console.log(`\nPayload written to ${args.out}`);
    } else {
      console.log(`\n${json}`);
    }
  });
