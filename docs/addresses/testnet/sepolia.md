# Sepolia Testnet addresses

## Token

| Name               | Address |
| ------------------ | ------- |
| Zama Token       | [`0xa798B04149e7a61cc95B7D114AD420e8969eA268`](https://sepolia.etherscan.io/address/0xa798B04149e7a61cc95B7D114AD420e8969eA268) |
| Zama OFT Adapter | [`0x55D5258841e9Fd304007683ff4637b0a80fb0e62`](https://sepolia.etherscan.io/address/0x55D5258841e9Fd304007683ff4637b0a80fb0e62) |


## Confidential tokens

> The **mocked** testnet confidential wrappers wrap ERC-20 tokens deployed specifically for testing. Their underlying ERC-20 tokens have a publicly accessible `mint(address to, uint256 amount)` function, limited to **1,000,000 tokens per call**. The **non-mocked** wrappers wrap "official" testnet ERC-20 tokens with restricted minting permissions.
>
> **Note:** The ZAMA (Mock) underlying token is a mock token deployed for testing purposes — it is **not** the real sepolia ZAMA token defined above in the [Token](#token) section.



## Wrappers registry

| Name              | Address |
| ----------------- | ------- |
| Wrappers Registry | [`0x2f0750Bbb0A246059d80e94c454586a7F27a128e`](https://sepolia.etherscan.io/address/0x2f0750Bbb0A246059d80e94c454586a7F27a128e) |

### Confidential wrappers

| Name                | Symbol      | Address | Underlying Mint | Underlying Token |
| ------------------- | ----------- | ------- | --------------- | ---------------- |
| Confidential USDC (Mock) | `cUSDCMock` | [`0x7c5BF43B851c1dff1a4feE8dB225b87f2C223639`](https://sepolia.etherscan.io/address/0x7c5BF43B851c1dff1a4feE8dB225b87f2C223639) | Public (1M limit) | [`0x9b5Cd13b8eFbB58Dc25A05CF411D8056058aDFfF`](https://sepolia.etherscan.io/address/0x9b5Cd13b8eFbB58Dc25A05CF411D8056058aDFfF) |
| Confidential USDT (Mock) | `cUSDTMock` | [`0x4E7B06D78965594eB5EF5414c357ca21E1554491`](https://sepolia.etherscan.io/address/0x4E7B06D78965594eB5EF5414c357ca21E1554491) | Public (1M limit) | [`0xa7dA08FafDC9097Cc0E7D4f113A61e31d7e8e9b0`](https://sepolia.etherscan.io/address/0xa7dA08FafDC9097Cc0E7D4f113A61e31d7e8e9b0) |
| Confidential WETH (Mock) | `cWETHMock` | [`0x46208622DA27d91db4f0393733C8BA082ed83158`](https://sepolia.etherscan.io/address/0x46208622DA27d91db4f0393733C8BA082ed83158) | Public (1M limit) | [`0xff54739b16576FA5402F211D0b938469Ab9A5f3F`](https://sepolia.etherscan.io/address/0xff54739b16576FA5402F211D0b938469Ab9A5f3F) |
| Confidential BRON (Mock) | `cBRONMock` | [`0xaa5612FA27c927a0c7961f5AEFEE5ba3A0F9C891`](https://sepolia.etherscan.io/address/0xaa5612FA27c927a0c7961f5AEFEE5ba3A0F9C891) | Public (1M limit) | [`0xFf021fB13cA64e5354c62c954b949a88cfDEb25E`](https://sepolia.etherscan.io/address/0xFf021fB13cA64e5354c62c954b949a88cfDEb25E) |
| Confidential ZAMA (Mock) | `cZAMAMock` | [`0xf2D628d2598aF4eAF94CB76a437Ff86CA78FfbFB`](https://sepolia.etherscan.io/address/0xf2D628d2598aF4eAF94CB76a437Ff86CA78FfbFB) | Public (1M limit) | [`0x75355a85c6FB9df5f0C80FF54e8747EEe9a0BF57`](https://sepolia.etherscan.io/address/0x75355a85c6FB9df5f0C80FF54e8747EEe9a0BF57) |
| Confidential tGBP (Mock) | `ctGBPMock` | [`0xfCE5c7069c5525eF6c8C2b2E35A745bA20a2F7CC`](https://sepolia.etherscan.io/address/0xfCE5c7069c5525eF6c8C2b2E35A745bA20a2F7CC) | Public (1M limit) | [`0x93c931278A2aad1916783F952f94276eA5111442`](https://sepolia.etherscan.io/address/0x93c931278A2aad1916783F952f94276eA5111442) |
| Confidential XAUt (Mock) | `cXAUtMock` | [`0xe4FcF848739845BC81Dee1d5352cf3844F0a60C7`](https://sepolia.etherscan.io/address/0xe4FcF848739845BC81Dee1d5352cf3844F0a60C7) | Public (1M limit) | [`0x24377AE4AA0C45ecEe71225007f17c5D423dd940`](https://sepolia.etherscan.io/address/0x24377AE4AA0C45ecEe71225007f17c5D423dd940) |
| Confidential tGBP | `ctGBP` | [`0x167DC962808B32CFFFc7e14B5018c0bE06A3A208`](https://sepolia.etherscan.io/address/0x167DC962808B32CFFFc7e14B5018c0bE06A3A208) | Restricted | [`0xf6Ef9ADB61A48E29E36bc873070A46A3D2667ff3`](https://sepolia.etherscan.io/address/0xf6Ef9ADB61A48E29E36bc873070A46A3D2667ff3) |


## Staking

> The testnet staking contracts are using the following mocked mintable ERC-20 token as the underlying asset token: [`0x9216F67a276B4bf1D883C4Ec24095C2bc53C2ef4`](https://sepolia.etherscan.io/address/0x9216F67a276B4bf1D883C4Ec24095C2bc53C2ef4).

### Protocol staking

| Role        | Address |
| ----------- | ------- |
| KMS         | [`0x0309b4308A6AC121B9b3A960aC7Bc9bd8256cf38`](https://sepolia.etherscan.io/address/0x0309b4308A6AC121B9b3A960aC7Bc9bd8256cf38) |
| Coprocessor | [`0xc22E393D2A1C1BD65c88d34a3bE4DD77e8952E71`](https://sepolia.etherscan.io/address/0xc22E393D2A1C1BD65c88d34a3bE4DD77e8952E71) |

### Operator staking

| Name          | Role        | Address |
| --------------| ----------- | ------- |
| Zama          | KMS         | [`0x454D1738C8eD25C744aF01730EE39a27B683A246`](https://sepolia.etherscan.io/address/0x454D1738C8eD25C744aF01730EE39a27B683A246) |
| Dfns          | KMS         | [`0x8e0bFD7736E9628E2179fB98d44223eF9840fBC7`](https://sepolia.etherscan.io/address/0x8e0bFD7736E9628E2179fB98d44223eF9840fBC7) |
| Figment       | KMS         | [`0x1a5f6C8FFdd869b30FFC73cC9424025829aCad04`](https://sepolia.etherscan.io/address/0x1a5f6C8FFdd869b30FFC73cC9424025829aCad04) |
| Fireblocks    | KMS         | [`0xe85765700Ef107E94fd57FbF1D1863ff87a2948D`](https://sepolia.etherscan.io/address/0xe85765700Ef107E94fd57FbF1D1863ff87a2948D) |
| InfStones     | KMS         | [`0x5F1310b6E8F7DcC24A9A6F74229cf66EE075d4D6`](https://sepolia.etherscan.io/address/0x5F1310b6E8F7DcC24A9A6F74229cf66EE075d4D6) |
| Unit410       | KMS         | [`0xFcC6F9cA8CC4A491B05306D57374a3F6c1f52484`](https://sepolia.etherscan.io/address/0xFcC6F9cA8CC4A491B05306D57374a3F6c1f52484) |
| LayerZero     | KMS         | [`0x6c12eB5d89E6f89399610C7b3Efca40671E82F06`](https://sepolia.etherscan.io/address/0x6c12eB5d89E6f89399610C7b3Efca40671E82F06) |
| Ledger        | KMS         | [`0xe52419533D0322a57d6db28d32463aa6717FeA3c`](https://sepolia.etherscan.io/address/0xe52419533D0322a57d6db28d32463aa6717FeA3c) |
| Omakase       | KMS         | [`0xb1A7026C28cB91604FB7B1669f060aB74A30c255`](https://sepolia.etherscan.io/address/0xb1A7026C28cB91604FB7B1669f060aB74A30c255) |
| Stake Capital | KMS         | [`0xdd0a1B86C8bf653e5bA575bE81bBD733E59803Ae`](https://sepolia.etherscan.io/address/0xdd0a1B86C8bf653e5bA575bE81bBD733E59803Ae) |
| OpenZeppelin  | KMS         | [`0x76427A3830295406d4aBae5b4754749048f58098`](https://sepolia.etherscan.io/address/0x76427A3830295406d4aBae5b4754749048f58098) |
| Etherscan     | KMS         | [`0xDF3f304c291466F21BB711d00E48a0d9AD9D64aF`](https://sepolia.etherscan.io/address/0xDF3f304c291466F21BB711d00E48a0d9AD9D64aF) |
| Conduit       | KMS         | [`0xd6C131CD3c1243934658781a9F7A2CBd1E40f6bF`](https://sepolia.etherscan.io/address/0xd6C131CD3c1243934658781a9F7A2CBd1E40f6bF) |
| Zama          | Coprocessor | [`0x1504646d2e4F924db4c6D6F8e42713e5492604ce`](https://sepolia.etherscan.io/address/0x1504646d2e4F924db4c6D6F8e42713e5492604ce) |
| Blockscape    | Coprocessor | [`0xd32b8E13D9e9733f21068168637e68131122C212`](https://sepolia.etherscan.io/address/0xd32b8E13D9e9733f21068168637e68131122C212) |
| P2P           | Coprocessor | [`0x419Bcec8A8B60688AC7EfeFECC5f83E922191b2A`](https://sepolia.etherscan.io/address/0x419Bcec8A8B60688AC7EfeFECC5f83E922191b2A) |
| Artifact      | Coprocessor | [`0x98B50c22245994360Ecf1F695a7383A3f983AeF4`](https://sepolia.etherscan.io/address/0x98B50c22245994360Ecf1F695a7383A3f983AeF4) |
| Luganodes     | Coprocessor | [`0xe89d9ca0579F19B77af04b201E73A26CECA07600`](https://sepolia.etherscan.io/address/0xe89d9ca0579F19B77af04b201E73A26CECA07600) |


## Governance

| Name                     | Address |
| ------------------------ | ------- |
| Protocol DAO             | [`0x08e8a84c3c8c7cba165B1adcf67Ae4639eF84f52`](https://sepolia.etherscan.io/address/0x08e8a84c3c8c7cba165B1adcf67Ae4639eF84f52) |
| Governance OApp Sender   | [`0x909692c2f4979ca3fa11B5859d499308A1ec4932`](https://sepolia.etherscan.io/address/0x909692c2f4979ca3fa11B5859d499308A1ec4932) |


## Pausing

| Name            | Address |
| --------------- | ------- |
| Pauser Set                    | [`0xc62392B4100a1bD45AbDBf91E70f1E4349402b46`](https://sepolia.etherscan.io/address/0xc62392B4100a1bD45AbDBf91E70f1E4349402b46) |
| Pauser Set Wrapper (minting)  | [`0xEd03Be6711787f3068885137723504a075514040`](https://sepolia.etherscan.io/address/0xEd03Be6711787f3068885137723504a075514040) |
