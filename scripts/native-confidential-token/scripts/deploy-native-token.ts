import 'dotenv/config';
import { ethers, upgrades } from 'hardhat';

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is required`);
  }
  return value;
}

async function main() {
  const factory = await ethers.getContractFactory('NativeConfidentialToken');

  const proxy = await upgrades.deployProxy(
    factory,
    [
      requiredEnv('TOKEN_NAME'),
      requiredEnv('TOKEN_SYMBOL'),
      requiredEnv('TOKEN_CONTRACT_URI'),
      requiredEnv('OWNER_ADDRESS'),
    ],
    {
      initializer: 'initialize',
      kind: 'uups',
    },
  );

  await proxy.waitForDeployment();

  const proxyAddress = await proxy.getAddress();
  const implementationAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);

  console.log({
    proxyAddress,
    implementationAddress,
  });
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
