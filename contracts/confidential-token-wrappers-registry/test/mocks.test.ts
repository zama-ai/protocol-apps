import { expect } from 'chai';
import { ethers } from 'hardhat';

describe('ERC20Mock', function () {
  beforeEach(async function () {
    const [deployer, alice, bob] = await ethers.getSigners();
    const ERC20Mock = await ethers.getContractFactory('ERC20Mock');
    const token = await ERC20Mock.deploy('Mock Token', 'MTK', 18);
    await token.waitForDeployment();
    Object.assign(this, { token, deployer, alice, bob });
  });

  it('should support custom decimals', async function () {
    const ERC20Mock = await ethers.getContractFactory('ERC20Mock');
    const token6 = await ERC20Mock.deploy('Six Decimals', 'SIX', 6);
    expect(await token6.decimals()).to.equal(6);
  });

  it('should mint tokens', async function () {
    const amount = ethers.parseUnits('1000', 18);
    await this.token.mint(this.alice.address, amount);
    expect(await this.token.balanceOf(this.alice.address)).to.equal(amount);
  });

  it('should revert if mint amount exceeds max', async function () {
    const maxAmount = ethers.parseUnits('1000000', 18);
    const tooMuch = maxAmount + 1n;
    await expect(this.token.mint(this.alice.address, tooMuch))
      .to.be.revertedWithCustomError(this.token, 'MintAmountExceedsMax')
      .withArgs(tooMuch, maxAmount);
  });
});

describe('USDTMock', function () {
  beforeEach(async function () {
    const [deployer, alice, bob] = await ethers.getSigners();
    const USDTMock = await ethers.getContractFactory('USDTMock');
    const usdt = await USDTMock.deploy();
    await usdt.waitForDeployment();
    Object.assign(this, { usdt, deployer, alice, bob });
  });

  it('should have correct name, symbol, and decimals', async function () {
    expect(await this.usdt.name()).to.equal('Tether USD (Mock)');
    expect(await this.usdt.symbol()).to.equal('USDTMock');
    expect(await this.usdt.decimals()).to.equal(6);
  });

  it('should approve from zero allowance', async function () {
    const amount = ethers.parseUnits('100', 6);
    await this.usdt.connect(this.alice).approve(this.bob.address, amount);
    expect(await this.usdt.allowance(this.alice.address, this.bob.address)).to.equal(amount);
  });

  it('should approve to zero', async function () {
    const amount = ethers.parseUnits('100', 6);
    await this.usdt.connect(this.alice).approve(this.bob.address, amount);
    await this.usdt.connect(this.alice).approve(this.bob.address, 0);
    expect(await this.usdt.allowance(this.alice.address, this.bob.address)).to.equal(0);
  });

  it('should revert when changing non-zero allowance to non-zero', async function () {
    const amount1 = ethers.parseUnits('100', 6);
    const amount2 = ethers.parseUnits('200', 6);
    await this.usdt.connect(this.alice).approve(this.bob.address, amount1);
    await expect(this.usdt.connect(this.alice).approve(this.bob.address, amount2)).to.be.revertedWithoutReason();
  });

  it('should allow setting new allowance after resetting to zero', async function () {
    const amount1 = ethers.parseUnits('100', 6);
    const amount2 = ethers.parseUnits('200', 6);
    await this.usdt.connect(this.alice).approve(this.bob.address, amount1);
    await this.usdt.connect(this.alice).approve(this.bob.address, 0);
    await this.usdt.connect(this.alice).approve(this.bob.address, amount2);
    expect(await this.usdt.allowance(this.alice.address, this.bob.address)).to.equal(amount2);
  });
});
