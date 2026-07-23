# Confidential token base

This project contains the reusable contract building blocks for native confidential token integrations.

## Contents

* `contracts/token/ERC7984Upgradeable.sol`: upgradeable ERC7984 abstract base
* `contracts/fhevm/ZamaEthereumConfigUpgradeable.sol`: fhEVM Ethereum config helper

## Notes

* This project contains reusable base contracts only. It does not include a blessed deployable native token implementation.
* A separate reference deployment example lives in `scripts/native-confidential-token/`.
* This is a source-only package. It does not ship a Hardhat config, scripts, or runtime environment configuration.
