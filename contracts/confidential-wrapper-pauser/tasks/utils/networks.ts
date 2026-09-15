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
