module.exports = {
  // `fhevm/ZamaConfig.sol` is vendored verbatim from @fhevm/solidity 0.13.0. Its per-network
  // branches are `block.chainid` gated, so all but the local one are unreachable under test.
  skipFiles: ['mocks', 'fhevm/ZamaConfig.sol'],
};
