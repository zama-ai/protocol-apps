import { task, types } from 'hardhat/config';

// Verify a mock ERC20 contract
// Example usage:
// npx hardhat task:verifyMockERC20 --contract-address 0x1234567890123456789012345678901234567890 --name "Mock Token" --symbol "MTK" --decimals 18 --network testnet
task('task:verifyMockERC20')
  .addParam('contractAddress', 'The address of the mock ERC20 contract to verify', '', types.string)
  .addParam('name', 'The name of the mock ERC20 contract to verify', '', types.string)
  .addParam('symbol', 'The symbol of the mock ERC20 contract to verify', '', types.string)
  .addParam('decimals', 'The decimals of the mock ERC20 contract to verify', 18, types.int)
  .setAction(async function ({ contractAddress, name, symbol, decimals }, hre) {
    const { run } = hre;

    console.log(`Verifying mock ERC20 contract at ${contractAddress}...\n`);
    await run('verify:verify', {
      address: contractAddress,
      constructorArguments: [name, symbol, decimals],
    });
    console.log(`Mock ERC20 contract verification complete\n`);
  });

// Verify the USDTMock contract
// Example usage:
// npx hardhat task:verifyUSDTMock --contract-address 0x1234567890123456789012345678901234567890 --network testnet
task('task:verifyUSDTMock')
  .addParam('contractAddress', 'The address of the USDTMock contract to verify', '', types.string)
  .setAction(async function ({ contractAddress }, hre) {
    const { run } = hre;

    console.log(`Verifying USDTMock contract at ${contractAddress}...\n`);
    await run('verify:verify', {
      address: contractAddress,
      constructorArguments: [],
    });
    console.log(`USDTMock contract verification complete\n`);
  });
