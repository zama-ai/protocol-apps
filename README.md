<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/.gitbook/assets/fhevm-header-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="docs/.gitbook/assets/fhevm-header-light.png">
  <img width=500 alt="Protocol Apps">
</picture>
</p>

<hr/>

<p align="center">
  <a href="https://docs.zama.ai/protocol"> 📒 Documentation</a> | <a href="https://zama.ai/community"> 💛 Community support</a> | <a href="https://github.com/zama-ai/awesome-zama"> 📚 FHE resources by Zama</a>
</p>

<p align="center">
  <a href="https://github.com/zama-ai/protocol-apps/blob/main/LICENSE">
    <!-- markdown-link-check-disable-next-line -->
    <img src="https://img.shields.io/badge/License-BSD--3--Clause--Clear-%23ffb243?style=flat-square"></a>
  <a href="https://github.com/zama-ai/bounty-program">
    <!-- markdown-link-check-disable-next-line -->
    <img src="https://img.shields.io/badge/Contribute-Zama%20Bounty%20Program-%23ffd208?style=flat-square"></a>
</p>


## About

### What is Protocol Apps?

**Protocol Apps** is a collection of decentralized applications and backend services that enshrine the [Zama Confidential Blockchain Protocol](https://docs.zama.ai/protocol). Built on top of the protocol's core framework, these apps serve as first-party implementations demonstrating the full potential of confidential smart contracts powered by Fully Homomorphic Encryption (FHE).

The Zama Confidential Blockchain Protocol enables confidential smart contracts on any EVM-compatible blockchain (L1 or L2), allowing encrypted data to be processed directly on-chain while preserving privacy. Protocol Apps leverages this foundation to deliver production-ready DeFi, governance, and utility applications.

<br></br>

### Table of contents

- [About](#about)
  - [What is Protocol Apps?](#what-is-protocol-apps)
  - [Project scope](#project-scope)
  - [Key components](#key-components)
- [Resources](#resources)
- [Working with Protocol Apps](#working-with-protocol-apps)
  - [Contributing](#contributing)
  - [License](#license)
  - [FAQ](#faq)
- [Support](#support)
  <br></br>

### Project scope

Protocol Apps encompasses the full stack required to bring confidential blockchain applications to users:
- Smart Contracts: Solidity contracts leveraging the Zama Confidential Blockchain Protocol. See [contracts](./contracts) directory.
- Frontend decentralized applications: Dapps interacting with EVM smart contracts to simplify complex blockchain interactions for non-technical users. See [dapps](./dapps) directory.
- Backend Services: Off-chain APIs and integrations with the frontend applications

<br></br>

### Key components

The applications and services in this repository include:

- **Confidential Wrappers**: Wrap ERC20 tokens for encrypted transfers
- **Non-confidential Staking**: Delegate assets on operators to help secure the Zama Protocol and earn rewards
- **ZAMA ERC20 Token**: The Zama ERC20 cross-chain token used to pay input proof and decryption requests in the Zama Protocol.
- **Governance**: The governance cross-chain contracts to manage the Zama Protocol.

<br></br>
## Resources
- [Documentation](https://docs.zama.ai/protocol) — Official documentation of the Zama Confidential Blockchain Protocol.
- [FHEVM Repository](https://github.com/zama-ai/fhevm) — Open-source code for FHEVM.


<p align="right">
  <a href="#about" > ↑ Back to top </a>
</p>

## Working with Protocol Apps
### Citations

To cite Protocol Apps in academic papers, please use the following entries:

```text
@Misc{Protocol Apps,
title={{Protocol Apps: A collection of applications that enshrine the Zama Confidential Blockchain Protocol}},
author={Zama},
year={2026},
note={\url{https://github.com/zama-ai/protocol-apps}},
}
```

### Contributing

There are two ways to contribute to Protocol Apps:

- [Open issues](https://github.com/zama-ai/protocol-apps/issues/new/choose) to report bugs and typos, or to suggest new ideas
- Request to become an official contributor by emailing hello@zama.ai.

Becoming an approved contributor involves signing our Contributor License Agreement (CLA). Only approved contributors can send pull requests, so please make sure to get in touch before you do!
<br></br>

### License

This software is distributed under the **BSD-3-Clause-Clear** license. Read [this](LICENSE) for more details.

### FAQ

**Is Zama’s technology free to use?**

> Zama’s libraries are free to use under the BSD 3-Clause Clear license only for development, research, prototyping, and experimentation purposes. However, for any commercial use of Zama's open source code, companies must purchase Zama’s commercial patent license.
>
> Everything we do is open source, and we are very transparent on what it means for our users, you can read more about how we monetize our open source products at Zama in [this blog post](https://www.zama.ai/post/open-source).

**What do I need to do if I want to use Zama’s technology for commercial purposes?**

> To commercially use Zama’s technology you need to be granted Zama’s patent license. Please contact us at hello@zama.ai for more information.

**Do you file IP on your technology?**

> Yes, all Zama’s technologies are patented.

**Can you customize a solution for my specific use case?**

> We are open to collaborating and advancing the FHE space with our partners. If you have specific needs, please email us at hello@zama.ai.

## Support

<a target="_blank" href="https://community.zama.ai">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/.gitbook/assets/support-banner-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="docs/.gitbook/assets/support-banner-light.png">
  <img alt="Support">
</picture>
</a>

🌟 If you find this project helpful or interesting, please consider giving it a star on GitHub! Your support helps to grow the community and motivates further development.

<p align="right">
  <a href="#about" > ↑ Back to top </a>
</p>
