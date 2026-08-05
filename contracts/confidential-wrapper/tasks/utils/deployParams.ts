/**
 * Locate and read committed deploy-params, organized as `<tier>/<network>/{network,wrappers}.json`
 * (tier = testnet | mainnet, network = the Hardhat network / chain). The directory layout is the
 * source of truth for the tier↔network mapping, so the tier is never stored inside the files.
 *
 * Pure fs/path (no hardhat/ethers deps) so it can be imported without an import cycle.
 */
import { existsSync, readFileSync, readdirSync } from 'fs';
import { join, resolve } from 'path';

const DEPLOY_PARAMS_ROOT = resolve(__dirname, '../../deploy-params');

export type NetworkConfig = {
  chainId: number;
  dao: string;
  registry: string;
  minDeployerBalanceWei: string;
};

/** Minimal shape needed to look up a wrappers.json entry by underlying address. */
export type WrapperParamsEntry = {
  underlying: string;
  name?: string;
  contractUri?: string;
  owner?: string;
  blockedUsers?: unknown;
  underlyingDenyListSelector?: string;
  initialObservers?: unknown;
};

export function readJsonFile<T>(path: string): T {
  if (!existsSync(path)) {
    throw new Error(`File not found: ${path}`);
  }
  try {
    return JSON.parse(readFileSync(path, 'utf8')) as T;
  } catch (err) {
    throw new Error(`Failed to parse JSON at ${path}: ${(err as Error).message}`);
  }
}

// Resolve a network's tier + directory by scanning tier dirs for `<tier>/<networkName>/network.json`.
// Network names must be unique across tiers (a chain belongs to exactly one tier).
export function resolveNetworkDir(networkName: string): { tier: string; dir: string } {
  const tiers = readdirSync(DEPLOY_PARAMS_ROOT, { withFileTypes: true })
    .filter(d => d.isDirectory())
    .map(d => d.name);

  const matches = tiers.filter(tier => existsSync(join(DEPLOY_PARAMS_ROOT, tier, networkName, 'network.json')));

  if (matches.length === 0) {
    const available = tiers
      .flatMap(tier =>
        readdirSync(join(DEPLOY_PARAMS_ROOT, tier), { withFileTypes: true })
          .filter(d => d.isDirectory())
          .map(d => `${tier}/${d.name}`),
      )
      .sort();
    throw new Error(
      `No deploy-params for network "${networkName}" under any tier in deploy-params/ ` +
        `(available: ${available.join(', ') || '<none>'})`,
    );
  }
  if (matches.length > 1) {
    throw new Error(
      `Network "${networkName}" is defined under multiple tiers (${matches.join(', ')}); ` +
        `network names must be unique across tiers`,
    );
  }
  return { tier: matches[0], dir: join(DEPLOY_PARAMS_ROOT, matches[0], networkName) };
}

// Absolute paths to a network's params files, plus its resolved tier.
export function networkParamsPaths(networkName: string): {
  tier: string;
  dir: string;
  networkJson: string;
  wrappersJson: string;
} {
  const { tier, dir } = resolveNetworkDir(networkName);
  return { tier, dir, networkJson: join(dir, 'network.json'), wrappersJson: join(dir, 'wrappers.json') };
}

export function loadNetworkConfig(networkName: string): NetworkConfig {
  return readJsonFile<NetworkConfig>(networkParamsPaths(networkName).networkJson);
}

/**
 * Find the wrappers.json entry whose `underlying` matches (checksum-insensitive).
 * Entries are keyed by wrapper symbol; each underlying may appear once.
 */
export function findWrapperByUnderlying(
  networkName: string,
  underlying: string,
): { symbol: string; entry: WrapperParamsEntry; paramsFile: string } {
  const { tier, wrappersJson } = networkParamsPaths(networkName);
  const paramsFile = `deploy-params/${tier}/${networkName}/wrappers.json`;

  if (!existsSync(wrappersJson)) {
    throw new Error(`${paramsFile} not found — add it and merge before deploying`);
  }

  const entries = readJsonFile<Record<string, WrapperParamsEntry>>(wrappersJson);
  const target = underlying.toLowerCase();
  const matches: { symbol: string; entry: WrapperParamsEntry }[] = [];

  for (const [symbol, entry] of Object.entries(entries)) {
    if (!entry || typeof entry.underlying !== 'string') {
      throw new Error(`Entry "${symbol}" in ${paramsFile} is missing an "underlying" address`);
    }
    if (entry.underlying.toLowerCase() === target) {
      matches.push({ symbol, entry });
    }
  }

  if (matches.length === 0) {
    throw new Error(
      `${paramsFile} has no entry with underlying ${underlying} — add it and merge before deploying ` +
        `(have: ${Object.keys(entries).join(', ') || '<none>'})`,
    );
  }
  if (matches.length > 1) {
    throw new Error(
      `Multiple entries in ${paramsFile} share underlying ${underlying} (${matches.map(m => m.symbol).join(', ')}); ` +
        `each underlying may appear once`,
    );
  }

  const { symbol, entry } = matches[0];
  if (symbol.length === 0) {
    throw new Error(`Empty wrapper symbol key in ${paramsFile}`);
  }
  return { symbol, entry, paramsFile };
}
