# Hoodi Testnet addresses

## Token

> The ZAMAMock token is a mintable mock ERC-20 deployed for staking testing.
> Any address may call `mint(address,uint256)`, capped at 1,000,000 ZAMAMock
> per call (`publicMintCap`). Holders of `MINTER_ROLE` (the `ProtocolStaking`
> contracts below) can mint above that cap for reward payouts.

| Name     | Symbol     | Address |
| -------- | ---------- | ------- |
| ZAMAMock | `ZAMAMock` | [`0x58713Eca04e01114480b30bE8Ca0d8838F342a55`](https://eth-hoodi.blockscout.com/address/0x58713Eca04e01114480b30bE8Ca0d8838F342a55) |


## Staking

### Protocol staking

| Role        | Address |
| ----------- | ------- |
| KMS         | [`0xB6CE80007422D411825a712e522AE1dcA2746033`](https://eth-hoodi.blockscout.com/address/0xB6CE80007422D411825a712e522AE1dcA2746033) |
| Coprocessor | [`0xe41B550CA6F01b756926Be7D593c9F266Cae6221`](https://eth-hoodi.blockscout.com/address/0xe41B550CA6F01b756926Be7D593c9F266Cae6221) |

### Operator staking

| Name       | Role        | Staking Address | Rewarder Address |
| ---------- | ----------- | --------------- | ---------------- |
| Zama       | KMS         | [`0xbFb717A712aC94204aE9E7049332641f3332C82f`](https://eth-hoodi.blockscout.com/address/0xbFb717A712aC94204aE9E7049332641f3332C82f) | [`0x1F00Fdd750Aa2d627a370a66D71BfDb396540434`](https://eth-hoodi.blockscout.com/address/0x1F00Fdd750Aa2d627a370a66D71BfDb396540434) |
| Dfns       | KMS         | [`0x5278AB58212949C60A8EEEf1E3cBb7bc6588d7b9`](https://eth-hoodi.blockscout.com/address/0x5278AB58212949C60A8EEEf1E3cBb7bc6588d7b9) | [`0xA70BBDF02803e22f35Abc4EEd40752653B0236F0`](https://eth-hoodi.blockscout.com/address/0xA70BBDF02803e22f35Abc4EEd40752653B0236F0) |
| Figment    | KMS         | [`0x6570756591Ed9351D0D53D840D3e8F321887F4Fa`](https://eth-hoodi.blockscout.com/address/0x6570756591Ed9351D0D53D840D3e8F321887F4Fa) | [`0xB8feeB695247810A81BB0e2a32D3b1c01D8fE01A`](https://eth-hoodi.blockscout.com/address/0xB8feeB695247810A81BB0e2a32D3b1c01D8fE01A) |
| Zama       | Coprocessor | [`0xC1Ba8ed5c9bFE4E1d185D81ddCa1EDF999E45107`](https://eth-hoodi.blockscout.com/address/0xC1Ba8ed5c9bFE4E1d185D81ddCa1EDF999E45107) | [`0xdBE943948D4970ed6f0527fDCdC2a01A58A530c9`](https://eth-hoodi.blockscout.com/address/0xdBE943948D4970ed6f0527fDCdC2a01A58A530c9) |
| Blockscape | Coprocessor | [`0xD86AE01b0c578D93fB89F0d181E8189B5c463cFE`](https://eth-hoodi.blockscout.com/address/0xD86AE01b0c578D93fB89F0d181E8189B5c463cFE) | [`0x35a4A730911a9504b2E47DB130B211cA8452e2fb`](https://eth-hoodi.blockscout.com/address/0x35a4A730911a9504b2E47DB130B211cA8452e2fb) |
