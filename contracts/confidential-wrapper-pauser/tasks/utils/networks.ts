import { ethers } from "ethers";
import type { HardhatRuntimeEnvironment } from "hardhat/types";

import networksJson from "../../config/networks.json";

export interface NetworkConfig {
  chainId: number;
  registry: string;
  governance: string;
  governanceLabel: string;
}

type NetworksFile = Record<string, NetworkConfig | string>;

/**
 * Returns the committed config for `networkName`, or undefined for networks without one (hardhat, forks).
 */
export function getNetworkConfig(networkName: string): NetworkConfig | undefined {
  const entry = (networksJson as NetworksFile)[networkName];
  if (entry === undefined || typeof entry === "string") return undefined;
  return entry;
}

/**
 * Resolves the registry the tasks enumerate: an explicit override first, then the committed per-network config.
 */
export function resolveRegistry(hre: HardhatRuntimeEnvironment, override?: string): string {
  if (override) {
    if (!ethers.isAddress(override)) throw new Error(`Invalid registry address: ${override}`);
    return ethers.getAddress(override);
  }
  const config = getNetworkConfig(hre.network.name);
  if (!config) {
    throw new Error(`No registry configured for network "${hre.network.name}"; pass --registry <address>.`);
  }
  return config.registry;
}

export interface Governance {
  address: string;
  label: string;
}

/**
 * Resolves the address expected to own the chain's pauser and its wrappers: an explicit override first, then the
 * committed per-network config. Undefined on networks with neither (hardhat, forks), where owner checks fall back
 * to the pauser's own owner or are skipped.
 */
export function resolveGovernance(hre: HardhatRuntimeEnvironment, override?: string): Governance | undefined {
  if (override) {
    if (!ethers.isAddress(override)) throw new Error(`Invalid governance address: ${override}`);
    return { address: ethers.getAddress(override), label: "--governance" };
  }
  const config = getNetworkConfig(hre.network.name);
  return config ? { address: config.governance, label: config.governanceLabel } : undefined;
}

/**
 * Minimal ABI of the ConfidentialWrapperPauser read path used by the tasks.
 */
export const PAUSER_ABI = [
  "function owner() view returns (address)",
  "function pendingOwner() view returns (address)",
  "function pausers() view returns (address[])",
];

export interface PauserState {
  owner: string;
  pendingOwner: string;
  roster: string[];
}

export interface PauserPreflight {
  state: PauserState;
  /** Findings that make the pauser unusable as the chain's pauser (currently: owned by someone else). */
  problems: string[];
  /** Findings worth a look that do not block. */
  warnings: string[];
}

/**
 * Checks that `pauser` is a deployed ConfidentialWrapperPauser before a task builds anything around it. Throws on the
 * inputs that could otherwise reach a governance proposal unnoticed: the zero address (which would disable pausing on
 * every wrapper), an EOA, or a contract without the pauser's read surface. An owner other than `governance` is
 * returned as a problem so callers decide whether to refuse (proposal) or report (drift check).
 */
export async function preflightPauser(
  hre: HardhatRuntimeEnvironment,
  pauser: string,
  governance?: Governance,
): Promise<PauserPreflight> {
  if (pauser === ethers.ZeroAddress) {
    throw new Error("--pauser is the zero address: arming wrappers with it disables pausing on every one of them");
  }
  if ((await hre.ethers.provider.getCode(pauser)) === "0x") {
    throw new Error(`--pauser ${pauser} has no code on ${hre.network.name}`);
  }
  const contract = new hre.ethers.Contract(pauser, PAUSER_ABI, hre.ethers.provider);
  let state: PauserState;
  try {
    const [owner, pendingOwner, roster]: [string, string, string[]] = await Promise.all([
      contract.owner(),
      contract.pendingOwner(),
      contract.pausers(),
    ]);
    state = { owner, pendingOwner, roster: [...roster] };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    throw new Error(
      `--pauser ${pauser} is not a ConfidentialWrapperPauser (owner()/pendingOwner()/pausers() failed: ${msg})`,
    );
  }

  const problems: string[] = [];
  const warnings: string[] = [];
  if (governance && state.owner.toLowerCase() !== governance.address.toLowerCase()) {
    problems.push(`pauser owner ${state.owner} is not ${governance.label} ${governance.address}`);
  }
  if (state.pendingOwner !== ethers.ZeroAddress) {
    warnings.push(`pending ownership transfer to ${state.pendingOwner} (Ownable2Step, not accepted yet)`);
  }
  if (state.roster.length === 0) {
    warnings.push("the roster is empty: nobody can pause until governance adds a member");
  }
  return { state, problems, warnings };
}

/**
 * Minimal ABI of the ConfidentialTokenWrappersRegistry read path used by the tasks.
 */
export const REGISTRY_ABI = [
  "function getTokenConfidentialTokenPairs() view returns (tuple(address tokenAddress, address confidentialTokenAddress, bool isValid)[])",
];

/**
 * Minimal ABI of the ConfidentialWrapper surface used by the tasks.
 */
export const WRAPPER_ABI = [
  "function pauser() view returns (address)",
  "function paused() view returns (bool)",
  "function owner() view returns (address)",
  "function symbol() view returns (string)",
  "function setPauser(address pauser_)",
];

export interface RegisteredWrapper {
  token: string;
  wrapper: string;
  symbol: string;
}

/**
 * Enumerates the valid (non-revoked) wrappers of `registry`, with their symbol for readable reports.
 */
export async function listValidWrappers(
  hre: HardhatRuntimeEnvironment,
  registry: string,
): Promise<RegisteredWrapper[]> {
  const registryContract = new hre.ethers.Contract(registry, REGISTRY_ABI, hre.ethers.provider);
  const pairs: { tokenAddress: string; confidentialTokenAddress: string; isValid: boolean }[] =
    await registryContract.getTokenConfidentialTokenPairs();

  const wrappers: RegisteredWrapper[] = [];
  for (const pair of pairs) {
    if (!pair.isValid) continue;
    const wrapper = new hre.ethers.Contract(pair.confidentialTokenAddress, WRAPPER_ABI, hre.ethers.provider);
    let symbol = "?";
    try {
      symbol = await wrapper.symbol();
    } catch {
      // keep the placeholder: a wrapper without a readable symbol is still reported by address
    }
    wrappers.push({ token: pair.tokenAddress, wrapper: pair.confidentialTokenAddress, symbol });
  }
  return wrappers;
}

/**
 * Splits a comma-separated list of addresses, validating and checksumming each entry.
 */
export function parseAddressList(raw: string | undefined, flag: string): string[] {
  if (!raw) return [];
  return raw
    .split(",")
    .map((item) => item.trim())
    .filter((item) => item.length > 0)
    .map((item) => {
      if (!ethers.isAddress(item)) throw new Error(`${flag}: invalid address "${item}"`);
      return ethers.getAddress(item);
    });
}
