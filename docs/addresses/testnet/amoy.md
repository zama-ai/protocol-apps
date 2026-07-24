# Polygon Amoy Testnet addresses

## Governance 

| Name                     | Address |
| ------------------------ | ------- |
| Amoy Governance OApp Receiver | [`0x696fCA81b616b4cd08Ea436492a443046fF3c6a6`](https://amoy.polygonscan.com/address/0x696fCA81b616b4cd08Ea436492a443046fF3c6a6) |
| Amoy Admin Module             | [`0x43cdd2cCbeB38Eb62fDf54e17aFBabf450ebBB01`](https://amoy.polygonscan.com/address/0x43cdd2cCbeB38Eb62fDf54e17aFBabf450ebBB01) |
| Amoy multisig | [`0xF0b1FE5DecfFe400fb141BBEAF9B181bCF76E3Cb`](https://amoy.polygonscan.com/address/0xF0b1FE5DecfFe400fb141BBEAF9B181bCF76E3Cb) |

The Amoy multisig owns the Wrappers Registry and each confidential wrapper below.

## Wrappers Registry

| Name | Address |
| ---- | ------- |
| ConfidentialTokenWrappersRegistry | [`0xF486c3D4F4562760A43883e72E8D6f6Cf2EFdA94`](https://amoy.polygonscan.com/address/0xF486c3D4F4562760A43883e72E8D6f6Cf2EFdA94) |

## Mock tokens

> These plain ERC-20 mocks stand in for the OFT (bridged) representation of the token on this
> chain — the interim model until a confidential OFT (cOFT) exists. A production Amoy
> deployment would instead register the bridged OFT addresses. `USDCMock` uses `ERC20Mock`;
> `USDTMock` uses the dedicated `USDTMock` contract (non-standard USDT approve behavior). Both
> use 6 decimals.

| Symbol | Address |
| ------ | ------- |
| USDCMock | [`0x8516e725223e3F829537D6A877E1aAE954811B69`](https://amoy.polygonscan.com/address/0x8516e725223e3F829537D6A877E1aAE954811B69) |
| USDTMock | [`0x164F5A056166d8F2ce09FdAc6d040209a8C94d01`](https://amoy.polygonscan.com/address/0x164F5A056166d8F2ce09FdAc6d040209a8C94d01) |

## Confidential Wrappers

| Name | Symbol | Wrapper (proxy) | Underlying |
| ---- | ------ | --------------- | ---------- |
| Confidential USDC (Mock) | `cUSDCMock` | [`0x7a1728f2A07cE4D62167dE1348af168509011b7b`](https://amoy.polygonscan.com/address/0x7a1728f2A07cE4D62167dE1348af168509011b7b) | USDCMock [`0x8516…1B69`](https://amoy.polygonscan.com/address/0x8516e725223e3F829537D6A877E1aAE954811B69) |
| Confidential USDT (Mock) | `cUSDTMock` | [`0x2ABad2203Eba104b52cf040cCcFA100Df15687F8`](https://amoy.polygonscan.com/address/0x2ABad2203Eba104b52cf040cCcFA100Df15687F8) | USDTMock [`0x164F…4d01`](https://amoy.polygonscan.com/address/0x164F5A056166d8F2ce09FdAc6d040209a8C94d01) |
