import { Addressable, ZeroAddress } from 'ethers';
import { ethers, upgrades } from 'hardhat';
import { CONTRACT_NAME } from '../../tasks/deploy';
import { getRequiredEnvVar } from '../../tasks/utils/loadVariables';

export const DEFAULT_WRAPPER_NAME = getRequiredEnvVar('CONFIDENTIAL_WRAPPER_NAME_0');
export const DEFAULT_WRAPPER_SYMBOL = getRequiredEnvVar('CONFIDENTIAL_WRAPPER_SYMBOL_0');
export const DEFAULT_WRAPPER_CONTRACT_URI = getRequiredEnvVar('CONFIDENTIAL_WRAPPER_CONTRACT_URI_0');
export const DEFAULT_WRAPPER_OWNER = getRequiredEnvVar('CONFIDENTIAL_WRAPPER_OWNER_ADDRESS_0');

type DeployConfidentialWrapperOptions = {
  name?: string;
  symbol?: string;
  contractUri?: string;
  owner?: string;
  blockedUsers?: string[];
  underlyingDenyListSelector?: string;
  hasUnderlyingDenyListSelector?: boolean;
  confidentialWrapperDenyList?: string;
};

export async function deployConfidentialWrapper(
  token: string | Addressable,
  {
    name = DEFAULT_WRAPPER_NAME,
    symbol = DEFAULT_WRAPPER_SYMBOL,
    contractUri = DEFAULT_WRAPPER_CONTRACT_URI,
    owner = DEFAULT_WRAPPER_OWNER,
    blockedUsers = [],
    underlyingDenyListSelector = '0x00000000',
    hasUnderlyingDenyListSelector = false,
    confidentialWrapperDenyList = ZeroAddress,
  }: DeployConfidentialWrapperOptions = {},
) {
  const factory = await ethers.getContractFactory(CONTRACT_NAME);
  const proxy = await upgrades.deployProxy(
    factory,
    [
      name,
      symbol,
      contractUri,
      token,
      owner,
      blockedUsers,
      underlyingDenyListSelector,
      hasUnderlyingDenyListSelector,
      confidentialWrapperDenyList,
    ],
    { initializer: 'initialize', kind: 'uups' },
  );
  await proxy.waitForDeployment();
  return ethers.getContractAt(CONTRACT_NAME, await proxy.getAddress());
}
