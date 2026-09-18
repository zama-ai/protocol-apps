import { ethers } from "ethers";

// Get the required environment variable, throw an error if it's not set
// We only check if the variable is set, not if it's empty
export function getRequiredEnvVar(name: string, defaultValue?: string): string {
  if (!(name in process.env)) {
    throw new Error(`"${name}" env variable is not set`);
  }
  if (process.env[name] === "") {
    if (defaultValue === undefined) {
      throw new Error(`"${name}" env variable is not set`);
    }
    return defaultValue;
  }
  return process.env[name]!;
}

// Parse a checksummed address from an environment variable
export function getRequiredAddressEnvVar(name: string): string {
  const value = getRequiredEnvVar(name);
  if (!ethers.isAddress(value)) {
    throw new Error(`"${name}" env variable is not a valid address: ${value}`);
  }
  return ethers.getAddress(value);
}

// Parse a JSON array of addresses from an environment variable
export function getRequiredAddressListEnvVar(name: string): string[] {
  const raw = getRequiredEnvVar(name);
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error(`"${name}" env variable must be a JSON array of addresses`);
  }
  if (!Array.isArray(parsed) || !parsed.every((item) => typeof item === "string" && ethers.isAddress(item))) {
    throw new Error(`"${name}" env variable must be a JSON array of addresses`);
  }
  return parsed.map((item) => ethers.getAddress(item));
}

// Parse a boolean flag from an environment variable, defaulting to false
export function getBooleanEnvVar(name: string): boolean {
  return (process.env[name] ?? "").toLowerCase() === "true";
}
