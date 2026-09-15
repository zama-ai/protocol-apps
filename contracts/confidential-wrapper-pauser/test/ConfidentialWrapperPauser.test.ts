import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { readFileSync } from "fs";
import hre, { ethers } from "hardhat";
import { resolve } from "path";

import type {
  BrokenWrapperMock,
  ConfidentialTokenWrappersRegistryMock,
  ConfidentialWrapperMock,
  ConfidentialWrapperPauser,
  ConfidentialWrapperPauserHarness,
  PermissiveFallbackMock,
  ReentrantWrapperMock,
} from "../types";

const DEFAULT_ADMIN_ROLE = ethers.ZeroHash;
const PAUSER_ROLE = ethers.id("PAUSER_ROLE");
const ADMIN_DELAY = 24 * 60 * 60; // 1 day, in seconds
const DELAY_INCREASE_WAIT = 5 * 24 * 60 * 60; // AccessControlDefaultAdminRules.defaultAdminDelayIncreaseWait()

describe("ConfidentialWrapperPauser", function () {
  let governance: HardhatEthersSigner;
  let pauserA: HardhatEthersSigner;
  let pauserB: HardhatEthersSigner;
  let outsider: HardhatEthersSigner;
  let newGovernance: HardhatEthersSigner;

  let registry: ConfidentialTokenWrappersRegistryMock;
  let pauser: ConfidentialWrapperPauser;
  let wrapper1: ConfidentialWrapperMock;
  let wrapper2: ConfidentialWrapperMock;
  let unarmed: ConfidentialWrapperMock;

  async function deployFixture() {
    const [deployer, governance, pauserA, pauserB, outsider, newGovernance] = await ethers.getSigners();

    const registry = (await ethers.deployContract(
      "ConfidentialTokenWrappersRegistryMock",
    )) as unknown as ConfidentialTokenWrappersRegistryMock;
    const pauser = (await ethers.deployContract("ConfidentialWrapperPauser", [
      ADMIN_DELAY,
      governance.address,
      registry.target,
      [pauserA.address, pauserB.address],
    ])) as unknown as ConfidentialWrapperPauser;

    // Two wrappers armed with the pauser contract, one still armed with an unrelated address; all three registered.
    const wrapper1 = (await ethers.deployContract("ConfidentialWrapperMock", [
      governance.address,
      pauser.target,
    ])) as unknown as ConfidentialWrapperMock;
    const wrapper2 = (await ethers.deployContract("ConfidentialWrapperMock", [
      governance.address,
      pauser.target,
    ])) as unknown as ConfidentialWrapperMock;
    const unarmed = (await ethers.deployContract("ConfidentialWrapperMock", [
      governance.address,
      deployer.address,
    ])) as unknown as ConfidentialWrapperMock;

    for (const wrapper of [wrapper1, wrapper2, unarmed]) await registry.register(wrapper.target);

    return { governance, pauserA, pauserB, outsider, newGovernance, registry, pauser, wrapper1, wrapper2, unarmed };
  }

  // The hostile targets below are registered by default: the registry gate is tested on its own, and these mocks
  // exist to exercise what happens once a registered address is actually called.
  async function deployBroken(): Promise<BrokenWrapperMock> {
    const broken = (await ethers.deployContract("BrokenWrapperMock")) as unknown as BrokenWrapperMock;
    await registry.register(broken.target);
    return broken;
  }

  async function deployPermissive(register = true): Promise<PermissiveFallbackMock> {
    const permissive = (await ethers.deployContract("PermissiveFallbackMock")) as unknown as PermissiveFallbackMock;
    if (register) await registry.register(permissive.target);
    return permissive;
  }

  // ReentrantWrapperMock.Callback
  const CALLBACK = { PauseOther: 0, PauseBatch: 1, AddSelf: 2 } as const;

  async function deployReentrant(
    callback: number,
    swallow: boolean,
    other = wrapper1.target as string,
  ): Promise<ReentrantWrapperMock> {
    const reentrant = (await ethers.deployContract("ReentrantWrapperMock", [
      pauser.target,
      other,
    ])) as unknown as ReentrantWrapperMock;
    await reentrant.configure(callback, swallow);
    await registry.register(reentrant.target);
    return reentrant;
  }

  /** The WrapperPaused / WrapperAlreadyPaused / WrapperPauseFailed events of a call, in emission order. */
  async function pauseOutcomes(
    tx: Promise<ethers.ContractTransactionResponse>,
  ): Promise<{ name: string; wrapper: string; errorData?: string }[]> {
    const receipt = (await (await tx).wait())!;
    return receipt.logs
      .filter((log) => log.address === pauser.target)
      .map((log) => pauser.interface.parseLog(log)!)
      .filter((parsed) => ["WrapperPaused", "WrapperAlreadyPaused", "WrapperPauseFailed"].includes(parsed.name))
      .map((parsed) => ({
        name: parsed.name,
        wrapper: parsed.args.wrapper as string,
        ...(parsed.name === "WrapperPauseFailed" ? { errorData: parsed.args.errorData as string } : {}),
      }));
  }

  function encodeError(fragment: string, args: unknown[]): string {
    return new ethers.Interface([`error ${fragment}`]).encodeErrorResult(fragment.split("(")[0], args);
  }

  beforeEach(async function () {
    ({ governance, pauserA, pauserB, outsider, newGovernance, registry, pauser, wrapper1, wrapper2, unarmed } =
      await loadFixture(deployFixture));
  });

  describe("constructor", function () {
    it("makes governance the sole default admin, reported as owner(), with the configured delay", async function () {
      expect(await pauser.defaultAdmin()).to.equal(governance.address);
      expect(await pauser.owner()).to.equal(governance.address);
      expect(await pauser.hasRole(DEFAULT_ADMIN_ROLE, governance.address)).to.be.true;
      expect(await pauser.getRoleMembers(DEFAULT_ADMIN_ROLE)).to.deep.equal([governance.address]);
      expect(await pauser.defaultAdminDelay()).to.equal(ADMIN_DELAY);
      expect(await pauser.pendingDefaultAdmin()).to.deep.equal([ethers.ZeroAddress, 0n]);
      expect(await pauser.pendingDefaultAdminDelay()).to.deep.equal([0n, 0n]);
      expect(await pauser.defaultAdminDelayIncreaseWait()).to.equal(DELAY_INCREASE_WAIT);
      expect(await pauser.getRoleAdmin(PAUSER_ROLE)).to.equal(DEFAULT_ADMIN_ROLE);
      expect(await pauser.registry()).to.equal(registry.target);
    });

    it("rejects a registry address without code", async function () {
      for (const bogus of [ethers.ZeroAddress, outsider.address]) {
        await expect(
          ethers.deployContract("ConfidentialWrapperPauser", [
            ADMIN_DELAY,
            governance.address,
            bogus,
            [pauserA.address],
          ]),
        )
          .to.be.revertedWithCustomError(pauser, "InvalidRegistry")
          .withArgs(bogus);
      }
    });

    it("accepts a zero delay, making the admin transfer a plain two-step", async function () {
      const twoStep = (await ethers.deployContract("ConfidentialWrapperPauser", [
        0,
        governance.address,
        registry.target,
        [pauserA.address],
      ])) as unknown as ConfidentialWrapperPauser;
      expect(await twoStep.defaultAdminDelay()).to.equal(0);
      await twoStep.connect(governance).beginDefaultAdminTransfer(newGovernance.address);
      await twoStep.connect(newGovernance).acceptDefaultAdminTransfer();
      expect(await twoStep.owner()).to.equal(newGovernance.address);
    });

    it("seeds the roster in order and emits PauserAdded and RoleGranted for each member", async function () {
      expect(await pauser.pausers()).to.deep.equal([pauserA.address, pauserB.address]);
      expect(await pauser.getRoleMembers(PAUSER_ROLE)).to.deep.equal([pauserA.address, pauserB.address]);
      expect(await pauser.getRoleMemberCount(PAUSER_ROLE)).to.equal(2);
      expect(await pauser.getRoleMember(PAUSER_ROLE, 1)).to.equal(pauserB.address);
      expect(await pauser.isPauser(pauserA.address)).to.be.true;
      expect(await pauser.isPauser(pauserB.address)).to.be.true;
      expect(await pauser.isPauser(governance.address)).to.be.false;
      expect(await pauser.isPauser(outsider.address)).to.be.false;

      const added = await pauser.queryFilter(pauser.filters.PauserAdded());
      expect(added.map((event) => event.args.account)).to.deep.equal([pauserA.address, pauserB.address]);
      const granted = await pauser.queryFilter(pauser.filters.RoleGranted(PAUSER_ROLE));
      expect(granted.map((event) => event.args.account)).to.deep.equal([pauserA.address, pauserB.address]);
    });

    it("accepts an empty roster", async function () {
      const empty = await ethers.deployContract("ConfidentialWrapperPauser", [
        ADMIN_DELAY,
        governance.address,
        registry.target,
        [],
      ]);
      expect(await empty.pausers()).to.deep.equal([]);
    });

    it("grants a duplicated pauser once", async function () {
      const deployed = (await ethers.deployContract("ConfidentialWrapperPauser", [
        ADMIN_DELAY,
        governance.address,
        registry.target,
        [pauserA.address, pauserA.address],
      ])) as unknown as ConfidentialWrapperPauser;
      expect(await deployed.pausers()).to.deep.equal([pauserA.address]);
      const added = await deployed.queryFilter(deployed.filters.PauserAdded());
      expect(added).to.have.lengthOf(1);
    });

    it("reverts on a zero-address admin", async function () {
      await expect(
        ethers.deployContract("ConfidentialWrapperPauser", [
          ADMIN_DELAY,
          ethers.ZeroAddress,
          registry.target,
          [pauserA.address],
        ]),
      )
        .to.be.revertedWithCustomError(pauser, "AccessControlInvalidDefaultAdmin")
        .withArgs(ethers.ZeroAddress);
    });

    it("does not put the admin on the roster by default", async function () {
      await expect(pauser.connect(governance)["pause(address)"](wrapper1.target))
        .to.be.revertedWithCustomError(pauser, "SenderNotPauser")
        .withArgs(governance.address);
    });
  });

  describe("roster management", function () {
    it("lets the admin add a pauser through addPauser (RoleGranted + PauserAdded)", async function () {
      await expect(pauser.connect(governance).addPauser(outsider.address))
        .to.emit(pauser, "RoleGranted")
        .withArgs(PAUSER_ROLE, outsider.address, governance.address)
        .and.to.emit(pauser, "PauserAdded")
        .withArgs(outsider.address);
      expect(await pauser.pausers()).to.deep.equal([pauserA.address, pauserB.address, outsider.address]);
      expect(await pauser.isPauser(outsider.address)).to.be.true;
      expect(await pauser.hasRole(PAUSER_ROLE, outsider.address)).to.be.true;
    });

    it("lets the admin remove a pauser through removePauser, who then cannot pause", async function () {
      await expect(pauser.connect(governance).removePauser(pauserA.address))
        .to.emit(pauser, "RoleRevoked")
        .withArgs(PAUSER_ROLE, pauserA.address, governance.address)
        .and.to.emit(pauser, "PauserRemoved")
        .withArgs(pauserA.address);
      // EnumerableSet moves the last entry into the freed slot.
      expect(await pauser.pausers()).to.deep.equal([pauserB.address]);
      expect(await pauser.isPauser(pauserA.address)).to.be.false;

      await expect(pauser.connect(pauserA)["pause(address)"](wrapper1.target))
        .to.be.revertedWithCustomError(pauser, "SenderNotPauser")
        .withArgs(pauserA.address);
    });

    it("is a silent no-op when adding an existing member or removing a non-member", async function () {
      await expect(pauser.connect(governance).addPauser(pauserA.address))
        .to.not.emit(pauser, "PauserAdded")
        .and.to.not.emit(pauser, "RoleGranted");
      await expect(pauser.connect(governance).removePauser(outsider.address))
        .to.not.emit(pauser, "PauserRemoved")
        .and.to.not.emit(pauser, "RoleRevoked");
      expect(await pauser.pausers()).to.deep.equal([pauserA.address, pauserB.address]);
    });

    it("exposes the same roster through the raw AccessControl functions", async function () {
      await expect(pauser.connect(governance).grantRole(PAUSER_ROLE, outsider.address))
        .to.emit(pauser, "PauserAdded")
        .withArgs(outsider.address);
      expect(await pauser.isPauser(outsider.address)).to.be.true;

      await expect(pauser.connect(governance).revokeRole(PAUSER_ROLE, outsider.address))
        .to.emit(pauser, "PauserRemoved")
        .withArgs(outsider.address);
      expect(await pauser.isPauser(outsider.address)).to.be.false;
    });

    it("lets a member step down with renounceRole, emitting PauserRemoved", async function () {
      await expect(pauser.connect(pauserA).renounceRole(PAUSER_ROLE, pauserA.address))
        .to.emit(pauser, "RoleRevoked")
        .withArgs(PAUSER_ROLE, pauserA.address, pauserA.address)
        .and.to.emit(pauser, "PauserRemoved")
        .withArgs(pauserA.address);
      expect(await pauser.pausers()).to.deep.equal([pauserB.address]);

      await expect(pauser.connect(pauserB).renounceRole(PAUSER_ROLE, pauserA.address)).to.be.revertedWithCustomError(
        pauser,
        "AccessControlBadConfirmation",
      );
    });

    it("fills the freed slot with the last member on removal (swap-and-pop), so indices are not stable", async function () {
      await pauser.connect(governance).addPauser(outsider.address);
      await pauser.connect(governance).addPauser(newGovernance.address);
      expect(await pauser.pausers()).to.deep.equal([
        pauserA.address,
        pauserB.address,
        outsider.address,
        newGovernance.address,
      ]);

      await pauser.connect(governance).removePauser(pauserB.address);
      expect(await pauser.pausers()).to.deep.equal([pauserA.address, newGovernance.address, outsider.address]);
      expect(await pauser.getRoleMember(PAUSER_ROLE, 1)).to.equal(newGovernance.address);
      expect(await pauser.getRoleMember(PAUSER_ROLE, 2)).to.equal(outsider.address);
      expect(await pauser.getRoleMemberCount(PAUSER_ROLE)).to.equal(3);
      // Past the end, EnumerableSet reverts with an array-out-of-bounds panic.
      await expect(pauser.getRoleMember(PAUSER_ROLE, 3)).to.be.revertedWithPanic(0x32);

      await pauser.connect(governance).removePauser(pauserA.address);
      expect(await pauser.pausers()).to.deep.equal([outsider.address, newGovernance.address]);

      // Removing the last slot needs no swap; re-adding appends at the end.
      await pauser.connect(governance).removePauser(newGovernance.address);
      await pauser.connect(governance).addPauser(pauserA.address);
      expect(await pauser.pausers()).to.deep.equal([outsider.address, pauserA.address]);
      for (const account of [pauserA, pauserB, outsider, newGovernance]) {
        expect(await pauser.isPauser(account.address)).to.equal(
          (await pauser.pausers()).includes(account.address),
          account.address,
        );
      }
    });

    it("rejects roster changes from anyone but the admin", async function () {
      await expect(pauser.connect(pauserA).addPauser(outsider.address))
        .to.be.revertedWithCustomError(pauser, "AccessControlUnauthorizedAccount")
        .withArgs(pauserA.address, DEFAULT_ADMIN_ROLE);
      await expect(pauser.connect(outsider).removePauser(pauserA.address))
        .to.be.revertedWithCustomError(pauser, "AccessControlUnauthorizedAccount")
        .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
      await expect(pauser.connect(outsider).grantRole(PAUSER_ROLE, outsider.address))
        .to.be.revertedWithCustomError(pauser, "AccessControlUnauthorizedAccount")
        .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
      await expect(pauser.connect(outsider).revokeRole(PAUSER_ROLE, pauserA.address))
        .to.be.revertedWithCustomError(pauser, "AccessControlUnauthorizedAccount")
        .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
    });
  });

  describe("default admin (AccessControlDefaultAdminRules)", function () {
    it("never grants or revokes DEFAULT_ADMIN_ROLE directly", async function () {
      await expect(
        pauser.connect(governance).grantRole(DEFAULT_ADMIN_ROLE, newGovernance.address),
      ).to.be.revertedWithCustomError(pauser, "AccessControlEnforcedDefaultAdminRules");
      await expect(
        pauser.connect(governance).revokeRole(DEFAULT_ADMIN_ROLE, governance.address),
      ).to.be.revertedWithCustomError(pauser, "AccessControlEnforcedDefaultAdminRules");
    });

    it("moves the admin only through a scheduled transfer accepted after the delay, keeping the roster intact", async function () {
      const tx = await pauser.connect(governance).beginDefaultAdminTransfer(newGovernance.address);
      const schedule = (await time.latest()) + ADMIN_DELAY;
      await expect(tx).to.emit(pauser, "DefaultAdminTransferScheduled").withArgs(newGovernance.address, schedule);
      expect(await pauser.pendingDefaultAdmin()).to.deep.equal([newGovernance.address, schedule]);
      // Still the old admin until accepted.
      expect(await pauser.owner()).to.equal(governance.address);

      await expect(pauser.connect(outsider).acceptDefaultAdminTransfer())
        .to.be.revertedWithCustomError(pauser, "AccessControlInvalidDefaultAdmin")
        .withArgs(outsider.address);
      await expect(pauser.connect(newGovernance).acceptDefaultAdminTransfer())
        .to.be.revertedWithCustomError(pauser, "AccessControlEnforcedDefaultAdminDelay")
        .withArgs(schedule);

      await time.increase(ADMIN_DELAY + 1);
      await expect(pauser.connect(newGovernance).acceptDefaultAdminTransfer())
        .to.emit(pauser, "RoleRevoked")
        .withArgs(DEFAULT_ADMIN_ROLE, governance.address, newGovernance.address)
        .and.to.emit(pauser, "RoleGranted")
        .withArgs(DEFAULT_ADMIN_ROLE, newGovernance.address, newGovernance.address);
      expect(await pauser.owner()).to.equal(newGovernance.address);
      expect(await pauser.defaultAdmin()).to.equal(newGovernance.address);
      expect(await pauser.getRoleMembers(DEFAULT_ADMIN_ROLE)).to.deep.equal([newGovernance.address]);
      expect(await pauser.pendingDefaultAdmin()).to.deep.equal([ethers.ZeroAddress, 0n]);
      expect(await pauser.pausers()).to.deep.equal([pauserA.address, pauserB.address]);

      await pauser.connect(newGovernance).addPauser(outsider.address);
      await expect(pauser.connect(governance).addPauser(governance.address))
        .to.be.revertedWithCustomError(pauser, "AccessControlUnauthorizedAccount")
        .withArgs(governance.address, DEFAULT_ADMIN_ROLE);
    });

    it("lets the new admin schedule a second transfer that the previous admin can no longer cancel", async function () {
      await pauser.connect(governance).beginDefaultAdminTransfer(newGovernance.address);
      await time.increase(ADMIN_DELAY + 1);
      await pauser.connect(newGovernance).acceptDefaultAdminTransfer();

      const tx = await pauser.connect(newGovernance).beginDefaultAdminTransfer(outsider.address);
      const schedule = (await time.latest()) + ADMIN_DELAY;
      await expect(tx).to.emit(pauser, "DefaultAdminTransferScheduled").withArgs(outsider.address, schedule);
      await expect(pauser.connect(governance).cancelDefaultAdminTransfer())
        .to.be.revertedWithCustomError(pauser, "AccessControlUnauthorizedAccount")
        .withArgs(governance.address, DEFAULT_ADMIN_ROLE);
      await expect(pauser.connect(governance).beginDefaultAdminTransfer(governance.address))
        .to.be.revertedWithCustomError(pauser, "AccessControlUnauthorizedAccount")
        .withArgs(governance.address, DEFAULT_ADMIN_ROLE);

      await time.increase(ADMIN_DELAY + 1);
      await pauser.connect(outsider).acceptDefaultAdminTransfer();
      expect(await pauser.owner()).to.equal(outsider.address);
      expect(await pauser.getRoleMembers(DEFAULT_ADMIN_ROLE)).to.deep.equal([outsider.address]);
      expect(await pauser.getRoleMemberCount(DEFAULT_ADMIN_ROLE)).to.equal(1);
      expect(await pauser.hasRole(DEFAULT_ADMIN_ROLE, newGovernance.address)).to.be.false;
      expect(await pauser.pausers()).to.deep.equal([pauserA.address, pauserB.address]);
    });

    it("replaces a pending transfer when the admin schedules another one", async function () {
      await pauser.connect(governance).beginDefaultAdminTransfer(newGovernance.address);
      const tx = await pauser.connect(governance).beginDefaultAdminTransfer(outsider.address);
      const schedule = (await time.latest()) + ADMIN_DELAY;
      await expect(tx)
        .to.emit(pauser, "DefaultAdminTransferCanceled")
        .and.to.emit(pauser, "DefaultAdminTransferScheduled")
        .withArgs(outsider.address, schedule);
      expect(await pauser.pendingDefaultAdmin()).to.deep.equal([outsider.address, schedule]);

      await time.increase(ADMIN_DELAY + 1);
      await expect(pauser.connect(newGovernance).acceptDefaultAdminTransfer())
        .to.be.revertedWithCustomError(pauser, "AccessControlInvalidDefaultAdmin")
        .withArgs(newGovernance.address);
      await pauser.connect(outsider).acceptDefaultAdminTransfer();
      expect(await pauser.owner()).to.equal(outsider.address);
    });

    it("lets the admin cancel a pending transfer", async function () {
      await pauser.connect(governance).beginDefaultAdminTransfer(newGovernance.address);
      await expect(pauser.connect(governance).cancelDefaultAdminTransfer()).to.emit(
        pauser,
        "DefaultAdminTransferCanceled",
      );
      expect(await pauser.pendingDefaultAdmin()).to.deep.equal([ethers.ZeroAddress, 0n]);
      await time.increase(ADMIN_DELAY + 1);
      await expect(pauser.connect(newGovernance).acceptDefaultAdminTransfer())
        .to.be.revertedWithCustomError(pauser, "AccessControlInvalidDefaultAdmin")
        .withArgs(newGovernance.address);
    });

    it("rejects transfer, cancel and delay changes from anyone but the admin", async function () {
      await expect(pauser.connect(pauserA).beginDefaultAdminTransfer(pauserA.address))
        .to.be.revertedWithCustomError(pauser, "AccessControlUnauthorizedAccount")
        .withArgs(pauserA.address, DEFAULT_ADMIN_ROLE);
      await expect(pauser.connect(pauserA).cancelDefaultAdminTransfer())
        .to.be.revertedWithCustomError(pauser, "AccessControlUnauthorizedAccount")
        .withArgs(pauserA.address, DEFAULT_ADMIN_ROLE);
      await expect(pauser.connect(pauserA).changeDefaultAdminDelay(0))
        .to.be.revertedWithCustomError(pauser, "AccessControlUnauthorizedAccount")
        .withArgs(pauserA.address, DEFAULT_ADMIN_ROLE);
    });

    it("raises the delay after the new delay has elapsed, capped at defaultAdminDelayIncreaseWait", async function () {
      const newDelay = 3 * ADMIN_DELAY;
      const tx = await pauser.connect(governance).changeDefaultAdminDelay(newDelay);
      const schedule = (await time.latest()) + newDelay;
      await expect(tx).to.emit(pauser, "DefaultAdminDelayChangeScheduled").withArgs(newDelay, schedule);
      expect(await pauser.pendingDefaultAdminDelay()).to.deep.equal([newDelay, schedule]);
      // Still the old delay until the schedule passes, and transfers scheduled meanwhile use it.
      expect(await pauser.defaultAdminDelay()).to.equal(ADMIN_DELAY);
      await pauser.connect(governance).beginDefaultAdminTransfer(newGovernance.address);
      expect((await pauser.pendingDefaultAdmin())[1]).to.equal((await time.latest()) + ADMIN_DELAY);
      await pauser.connect(governance).cancelDefaultAdminTransfer();

      await time.increaseTo(schedule + 1);
      expect(await pauser.defaultAdminDelay()).to.equal(newDelay);
      expect(await pauser.pendingDefaultAdminDelay()).to.deep.equal([0n, 0n]);
      await pauser.connect(governance).beginDefaultAdminTransfer(newGovernance.address);
      expect((await pauser.pendingDefaultAdmin())[1]).to.equal((await time.latest()) + newDelay);

      // A jump above the wait cap takes effect after the cap (5 days), not after the new delay.
      const hugeDelay = 30 * ADMIN_DELAY;
      const capped = await pauser.connect(governance).changeDefaultAdminDelay(hugeDelay);
      await expect(capped)
        .to.emit(pauser, "DefaultAdminDelayChangeScheduled")
        .withArgs(hugeDelay, (await time.latest()) + DELAY_INCREASE_WAIT);
    });

    it("lowers the delay only after the difference to the current delay has elapsed", async function () {
      const tx = await pauser.connect(governance).changeDefaultAdminDelay(0);
      const schedule = (await time.latest()) + ADMIN_DELAY;
      await expect(tx).to.emit(pauser, "DefaultAdminDelayChangeScheduled").withArgs(0, schedule);
      expect(await pauser.pendingDefaultAdminDelay()).to.deep.equal([0n, schedule]);
      expect(await pauser.defaultAdminDelay()).to.equal(ADMIN_DELAY);

      await time.increaseTo(schedule + 1);
      expect(await pauser.defaultAdminDelay()).to.equal(0);
      // With a zero delay the transfer becomes a plain two-step.
      await pauser.connect(governance).beginDefaultAdminTransfer(newGovernance.address);
      await pauser.connect(newGovernance).acceptDefaultAdminTransfer();
      expect(await pauser.owner()).to.equal(newGovernance.address);
    });

    it("rolls back a pending delay change, implicitly cancels a superseded one, and restricts both to the admin", async function () {
      await pauser.connect(governance).changeDefaultAdminDelay(2 * ADMIN_DELAY);
      await expect(pauser.connect(governance).changeDefaultAdminDelay(3 * ADMIN_DELAY)).to.emit(
        pauser,
        "DefaultAdminDelayChangeCanceled",
      );
      expect((await pauser.pendingDefaultAdminDelay())[0]).to.equal(3 * ADMIN_DELAY);

      await expect(pauser.connect(pauserA).rollbackDefaultAdminDelay())
        .to.be.revertedWithCustomError(pauser, "AccessControlUnauthorizedAccount")
        .withArgs(pauserA.address, DEFAULT_ADMIN_ROLE);
      await expect(pauser.connect(governance).rollbackDefaultAdminDelay()).to.emit(
        pauser,
        "DefaultAdminDelayChangeCanceled",
      );
      expect(await pauser.pendingDefaultAdminDelay()).to.deep.equal([0n, 0n]);
      await time.increase(3 * ADMIN_DELAY + 1);
      expect(await pauser.defaultAdminDelay()).to.equal(ADMIN_DELAY);
      // Rolling back with nothing pending is a silent no-op.
      await expect(pauser.connect(governance).rollbackDefaultAdminDelay()).to.not.emit(
        pauser,
        "DefaultAdminDelayChangeCanceled",
      );
    });

    it("only renounces the admin after a scheduled transfer to the zero address has matured", async function () {
      await expect(pauser.connect(governance).renounceRole(DEFAULT_ADMIN_ROLE, governance.address))
        .to.be.revertedWithCustomError(pauser, "AccessControlEnforcedDefaultAdminDelay")
        .withArgs(0);

      await pauser.connect(governance).beginDefaultAdminTransfer(ethers.ZeroAddress);
      const [, schedule] = await pauser.pendingDefaultAdmin();
      await expect(pauser.connect(governance).renounceRole(DEFAULT_ADMIN_ROLE, governance.address))
        .to.be.revertedWithCustomError(pauser, "AccessControlEnforcedDefaultAdminDelay")
        .withArgs(schedule);

      await time.increase(ADMIN_DELAY + 1);
      await pauser.connect(governance).renounceRole(DEFAULT_ADMIN_ROLE, governance.address);
      expect(await pauser.owner()).to.equal(ethers.ZeroAddress);
      // The roster is frozen from then on, but keeps working.
      await expect(pauser.connect(governance).addPauser(outsider.address))
        .to.be.revertedWithCustomError(pauser, "AccessControlUnauthorizedAccount")
        .withArgs(governance.address, DEFAULT_ADMIN_ROLE);
      await pauser.connect(pauserA)["pause(address)"](wrapper1.target);
      expect(await wrapper1.paused()).to.be.true;
    });

    it("keeps the default-admin rules on the internal role-admin setter", async function () {
      const harness = (await ethers.deployContract("ConfidentialWrapperPauserHarness", [
        ADMIN_DELAY,
        governance.address,
        registry.target,
        [pauserA.address],
      ])) as unknown as ConfidentialWrapperPauserHarness;
      const OTHER_ROLE = ethers.id("OTHER_ROLE");

      await expect(harness.exposedSetRoleAdmin(PAUSER_ROLE, OTHER_ROLE))
        .to.emit(harness, "RoleAdminChanged")
        .withArgs(PAUSER_ROLE, DEFAULT_ADMIN_ROLE, OTHER_ROLE);
      expect(await harness.getRoleAdmin(PAUSER_ROLE)).to.equal(OTHER_ROLE);

      await expect(harness.exposedSetRoleAdmin(DEFAULT_ADMIN_ROLE, OTHER_ROLE)).to.be.revertedWithCustomError(
        harness,
        "AccessControlEnforcedDefaultAdminRules",
      );
    });
  });

  describe("ERC-165", function () {
    function interfaceId(abi: string[]): string {
      const iface = new ethers.Interface(abi);
      let id = 0n;
      for (const fragment of iface.fragments) {
        if (fragment.type === "function") id ^= BigInt(ethers.id(fragment.format("sighash")).slice(0, 10));
      }
      return ethers.toBeHex(id, 4);
    }

    it("reports IConfidentialWrapperPauser and the AccessControl interfaces", async function () {
      const rfc = interfaceId([
        "function addPauser(address)",
        "function removePauser(address)",
        "function isPauser(address) view returns (bool)",
        "function pausers() view returns (address[])",
        "function pause(address)",
        "function pause(address[])",
        "function registry() view returns (address)",
      ]);
      const accessControl = interfaceId([
        "function hasRole(bytes32,address) view returns (bool)",
        "function getRoleAdmin(bytes32) view returns (bytes32)",
        "function grantRole(bytes32,address)",
        "function revokeRole(bytes32,address)",
        "function renounceRole(bytes32,address)",
      ]);
      const enumerable = interfaceId([
        "function getRoleMember(bytes32,uint256) view returns (address)",
        "function getRoleMemberCount(bytes32) view returns (uint256)",
      ]);
      const defaultAdminRules = interfaceId([
        "function defaultAdmin() view returns (address)",
        "function pendingDefaultAdmin() view returns (address,uint48)",
        "function defaultAdminDelay() view returns (uint48)",
        "function pendingDefaultAdminDelay() view returns (uint48,uint48)",
        "function beginDefaultAdminTransfer(address)",
        "function cancelDefaultAdminTransfer()",
        "function acceptDefaultAdminTransfer()",
        "function changeDefaultAdminDelay(uint48)",
        "function rollbackDefaultAdminDelay()",
        "function defaultAdminDelayIncreaseWait() view returns (uint48)",
      ]);

      expect(await pauser.supportsInterface(rfc)).to.be.true;
      expect(await pauser.supportsInterface(accessControl)).to.be.true;
      expect(await pauser.supportsInterface(enumerable)).to.be.true;
      expect(await pauser.supportsInterface(defaultAdminRules)).to.be.true;
      expect(await pauser.supportsInterface("0x01ffc9a7")).to.be.true; // IERC165
      expect(await pauser.supportsInterface("0xffffffff")).to.be.false;
    });

    it("does not report interfaces it only partially implements or merely calls", async function () {
      // owner() is exposed for ERC-5313 readers, but OpenZeppelin does not advertise IERC5313 through ERC-165.
      expect(await pauser.supportsInterface(interfaceId(["function owner() view returns (address)"]))).to.be.false;
      // The wrapper-side surface the pauser calls is not something it implements.
      expect(await pauser.supportsInterface(interfaceId(["function pause()", "function paused() view returns (bool)"])))
        .to.be.false;
      // A subset or a single selector of the RFC interface is not the interface.
      expect(
        await pauser.supportsInterface(
          interfaceId([
            "function addPauser(address)",
            "function removePauser(address)",
            "function isPauser(address) view returns (bool)",
            "function pausers() view returns (address[])",
            "function pause(address)",
            "function pause(address[])",
          ]),
        ),
      ).to.be.false;
      expect(await pauser.supportsInterface(interfaceId(["function pause(address[])"]))).to.be.false;
      expect(await pauser.supportsInterface("0x00000000")).to.be.false;
      expect(await pauser.supportsInterface("0x80ac58cd")).to.be.false; // IERC721
    });
  });

  describe("pause(address)", function () {
    it("lets a roster member pause an armed wrapper", async function () {
      await expect(pauser.connect(pauserA)["pause(address)"](wrapper1.target))
        .to.emit(pauser, "WrapperPaused")
        .withArgs(wrapper1.target)
        .and.to.emit(wrapper1, "Paused")
        .withArgs(pauser.target);
      expect(await wrapper1.paused()).to.be.true;
      expect(await wrapper2.paused()).to.be.false;
    });

    it("rejects callers off the roster with SenderNotPauser", async function () {
      await expect(pauser.connect(outsider)["pause(address)"](wrapper1.target))
        .to.be.revertedWithCustomError(pauser, "SenderNotPauser")
        .withArgs(outsider.address);
      expect(await wrapper1.paused()).to.be.false;
    });

    it("reverts with PauseFailed carrying SenderNotPauser when the wrapper is armed elsewhere", async function () {
      await expect(pauser.connect(pauserA)["pause(address)"](unarmed.target))
        .to.be.revertedWithCustomError(pauser, "PauseFailed")
        .withArgs(unarmed.target, encodeError("SenderNotPauser(address)", [pauser.target]));
      expect(await unarmed.paused()).to.be.false;
    });

    it("reports an already-paused wrapper with WrapperAlreadyPaused instead of reverting", async function () {
      await pauser.connect(pauserA)["pause(address)"](wrapper1.target);
      const tx = pauser.connect(pauserB)["pause(address)"](wrapper1.target);
      await expect(tx).to.emit(pauser, "WrapperAlreadyPaused").withArgs(wrapper1.target);
      await expect(tx).to.not.emit(pauser, "WrapperPaused");
      await expect(tx).to.not.emit(wrapper1, "Paused");
      expect(await wrapper1.paused()).to.be.true;
    });

    it("reverts with PauseFailed and empty data when a registered target reverts without data", async function () {
      const broken = await deployBroken();
      await expect(pauser.connect(pauserA)["pause(address)"](broken.target))
        .to.be.revertedWithCustomError(pauser, "PauseFailed")
        .withArgs(broken.target, "0x");
    });

    it("aborts on a registered contract without the pause API (accepted: the registry only lists wrappers)", async function () {
      // The registry is the trust boundary, so paused() is an ordinary call: an entry that answers nothing to it
      // reverts the pauser itself, in both forms, instead of being reported. The live registry validates ERC-7984
      // support at registration and only Zama governance registers, so this cannot happen with a real entry.
      const notAWrapper = await deployPermissive();
      await expect(pauser.connect(pauserA)["pause(address)"](notAWrapper.target)).to.be.revertedWithoutReason();
      await expect(
        pauser.connect(pauserA)["pause(address[])"]([wrapper1.target, notAWrapper.target]),
      ).to.be.revertedWithoutReason();
      expect(await wrapper1.paused()).to.be.false;
    });

    it("reverts with PauseFailed carrying WrapperNotRegistered for an address the registry does not list, without calling it", async function () {
      // A WETH-style contract that would swallow the call's gas: never reached.
      const permissive = await deployPermissive(false);
      for (const target of [permissive.target, outsider.address, ethers.ZeroAddress]) {
        await expect(pauser.connect(pauserA)["pause(address)"](target))
          .to.be.revertedWithCustomError(pauser, "PauseFailed")
          .withArgs(target, encodeError("WrapperNotRegistered(address)", [target]));
      }
      expect(await permissive.queryFilter(permissive.filters.Deposit())).to.have.lengthOf(0);
    });

    it("reverts with PauseFailed carrying WrapperNotRegistered for a revoked wrapper, and pauses it again once re-registered", async function () {
      await registry.revoke(wrapper1.target);
      await expect(pauser.connect(pauserA)["pause(address)"](wrapper1.target))
        .to.be.revertedWithCustomError(pauser, "PauseFailed")
        .withArgs(wrapper1.target, encodeError("WrapperNotRegistered(address)", [wrapper1.target]));
      expect(await wrapper1.paused()).to.be.false;

      await registry.register(wrapper1.target);
      await expect(pauser.connect(pauserA)["pause(address)"](wrapper1.target))
        .to.emit(pauser, "WrapperPaused")
        .withArgs(wrapper1.target);
    });

    for (const [name, callback] of [
      ["pause(address)", CALLBACK.PauseOther],
      ["pause(address[])", CALLBACK.PauseBatch],
      ["addPauser", CALLBACK.AddSelf],
    ] as const) {
      it(`rejects a wrapper that re-enters ${name} from its pause(), surfacing the inner error`, async function () {
        const reentrant = await deployReentrant(callback, false);
        // The re-entrant call is refused because the wrapper is neither a roster member nor the admin; the mock
        // wraps that revert data in its own CallbackRejected(bytes).
        const innerError =
          callback === CALLBACK.AddSelf
            ? encodeError("AccessControlUnauthorizedAccount(address,bytes32)", [reentrant.target, DEFAULT_ADMIN_ROLE])
            : encodeError("SenderNotPauser(address)", [reentrant.target]);

        await expect(pauser.connect(pauserA)["pause(address)"](reentrant.target))
          .to.be.revertedWithCustomError(pauser, "PauseFailed")
          .withArgs(reentrant.target, encodeError("CallbackRejected(bytes)", [innerError]));
        expect(await reentrant.paused()).to.be.false;
        expect(await wrapper1.paused()).to.be.false;
        expect(await pauser.isPauser(reentrant.target)).to.be.false;
      });
    }

    it("does not let a re-entering wrapper touch other wrappers or the roster even when it swallows the error", async function () {
      const reentrant = await deployReentrant(CALLBACK.PauseBatch, true);
      await expect(pauser.connect(pauserA)["pause(address)"](reentrant.target))
        .to.emit(pauser, "WrapperPaused")
        .withArgs(reentrant.target);
      expect(await reentrant.paused()).to.be.true;
      expect(await wrapper1.paused()).to.be.false;
      expect(await pauser.pausers()).to.deep.equal([pauserA.address, pauserB.address]);
      expect(await pauser.isPauser(reentrant.target)).to.be.false;
    });

    it("leaves unpausing to the wrapper owner", async function () {
      await pauser.connect(pauserA)["pause(address)"](wrapper1.target);
      await expect(wrapper1.connect(pauserA).unpause())
        .to.be.revertedWithCustomError(wrapper1, "OwnableUnauthorizedAccount")
        .withArgs(pauserA.address);
      await expect(wrapper1.connect(governance).unpause()).to.emit(wrapper1, "Unpaused").withArgs(governance.address);
      expect(await wrapper1.paused()).to.be.false;
      // And the roster can pause again afterwards.
      await pauser.connect(pauserB)["pause(address)"](wrapper1.target);
      expect(await wrapper1.paused()).to.be.true;
    });
  });

  describe("pause(address[])", function () {
    it("pauses every armed wrapper and emits WrapperPaused for each", async function () {
      await expect(pauser.connect(pauserB)["pause(address[])"]([wrapper1.target, wrapper2.target]))
        .to.emit(pauser, "WrapperPaused")
        .withArgs(wrapper1.target)
        .and.to.emit(pauser, "WrapperPaused")
        .withArgs(wrapper2.target);
      expect(await wrapper1.paused()).to.be.true;
      expect(await wrapper2.paused()).to.be.true;
    });

    it("rejects callers off the roster with SenderNotPauser", async function () {
      await expect(pauser.connect(outsider)["pause(address[])"]([wrapper1.target]))
        .to.be.revertedWithCustomError(pauser, "SenderNotPauser")
        .withArgs(outsider.address);
    });

    it("is best effort: every entry gets exactly one outcome, in order, and a failing one never stops the rest", async function () {
      await pauser.connect(pauserB)["pause(address)"](wrapper2.target);
      const broken = await deployBroken();
      const unregistered = await deployPermissive(false);
      await registry.revoke(unarmed.target);
      const revoked = unarmed;
      const outcomes = await pauseOutcomes(
        pauser
          .connect(pauserA)
          ["pause(address[])"]([
            wrapper1.target,
            wrapper2.target,
            broken.target,
            unregistered.target,
            outsider.address,
            revoked.target,
            wrapper1.target,
          ]),
      );
      expect(outcomes).to.deep.equal([
        { name: "WrapperPaused", wrapper: wrapper1.target },
        { name: "WrapperAlreadyPaused", wrapper: wrapper2.target },
        { name: "WrapperPauseFailed", wrapper: broken.target, errorData: "0x" },
        {
          name: "WrapperPauseFailed",
          wrapper: unregistered.target,
          errorData: encodeError("WrapperNotRegistered(address)", [unregistered.target]),
        },
        {
          name: "WrapperPauseFailed",
          wrapper: outsider.address,
          errorData: encodeError("WrapperNotRegistered(address)", [outsider.address]),
        },
        {
          name: "WrapperPauseFailed",
          wrapper: revoked.target,
          errorData: encodeError("WrapperNotRegistered(address)", [revoked.target]),
        },
        // Second occurrence of wrapper1: paused by this very batch, so already paused now.
        { name: "WrapperAlreadyPaused", wrapper: wrapper1.target },
      ]);
      expect(await wrapper1.paused()).to.be.true;
      expect(await wrapper2.paused()).to.be.true;
      expect(await revoked.paused()).to.be.false;
    });

    it("reports a wrapper armed elsewhere with its SenderNotPauser and still pauses the rest", async function () {
      const outcomes = await pauseOutcomes(
        pauser.connect(pauserA)["pause(address[])"]([unarmed.target, wrapper1.target]),
      );
      expect(outcomes).to.deep.equal([
        {
          name: "WrapperPauseFailed",
          wrapper: unarmed.target,
          errorData: encodeError("SenderNotPauser(address)", [pauser.target]),
        },
        { name: "WrapperPaused", wrapper: wrapper1.target },
      ]);
      expect(await unarmed.paused()).to.be.false;
      expect(await wrapper1.paused()).to.be.true;
    });

    it("is idempotent: re-running a whole batch reports every wrapper as already paused and changes nothing", async function () {
      const batch = [wrapper1.target, wrapper2.target];
      await pauser.connect(pauserA)["pause(address[])"](batch);
      const tx = pauser.connect(pauserB)["pause(address[])"](batch);
      expect(await pauseOutcomes(tx)).to.deep.equal([
        { name: "WrapperAlreadyPaused", wrapper: wrapper1.target },
        { name: "WrapperAlreadyPaused", wrapper: wrapper2.target },
      ]);
      await expect(tx).to.not.emit(wrapper1, "Paused");
      await expect(tx).to.not.emit(wrapper2, "Paused");
    });

    it("keeps going after a wrapper that re-enters the pauser from its pause()", async function () {
      const bubbling = await deployReentrant(CALLBACK.PauseOther, false, wrapper2.target as string);
      const swallowing = await deployReentrant(CALLBACK.AddSelf, true);
      const outcomes = await pauseOutcomes(
        pauser.connect(pauserA)["pause(address[])"]([bubbling.target, swallowing.target, wrapper1.target]),
      );
      expect(outcomes.map((outcome) => [outcome.name, outcome.wrapper])).to.deep.equal([
        ["WrapperPauseFailed", bubbling.target],
        ["WrapperPaused", swallowing.target],
        ["WrapperPaused", wrapper1.target],
      ]);
      // The re-entrant calls changed nothing: wrapper2 was never paused, the roster is intact.
      expect(await wrapper2.paused()).to.be.false;
      expect(await wrapper1.paused()).to.be.true;
      expect(await pauser.pausers()).to.deep.equal([pauserA.address, pauserB.address]);
    });

    it("skips unregistered WETH-style entries without calling them, so they cannot drain the batch's gas", async function () {
      // Without the registry gate, a permissive-fallback target was called and burned 63/64 of the remaining gas;
      // two of them ran the whole batch out of gas.
      const weth1 = await deployPermissive(false);
      const weth2 = await deployPermissive(false);
      const tx = await pauser
        .connect(pauserA)
        ["pause(address[])"]([weth1.target, weth2.target, wrapper1.target, wrapper2.target]);
      const receipt = (await tx.wait())!;

      expect(await pauseOutcomes(Promise.resolve(tx))).to.deep.equal([
        {
          name: "WrapperPauseFailed",
          wrapper: weth1.target,
          errorData: encodeError("WrapperNotRegistered(address)", [weth1.target]),
        },
        {
          name: "WrapperPauseFailed",
          wrapper: weth2.target,
          errorData: encodeError("WrapperNotRegistered(address)", [weth2.target]),
        },
        { name: "WrapperPaused", wrapper: wrapper1.target },
        { name: "WrapperPaused", wrapper: wrapper2.target },
      ]);
      expect(await weth1.queryFilter(weth1.filters.Deposit())).to.have.lengthOf(0);
      expect(await weth2.queryFilter(weth2.filters.Deposit())).to.have.lengthOf(0);
      // Each unregistered entry costs one registry lookup and one event, nothing more.
      expect(receipt.gasUsed).to.be.lessThan(300_000n);
    });

    it("pauses a large batch in one transaction well within the block gas limit", async function () {
      const BATCH = 128;
      const wrappers: string[] = [];
      for (let i = 0; i < BATCH; i++) {
        const wrapper = await ethers.deployContract("ConfidentialWrapperMock", [governance.address, pauser.target]);
        await registry.register(wrapper.target);
        wrappers.push(wrapper.target as string);
      }
      const tx = await pauser.connect(pauserA)["pause(address[])"](wrappers);
      const receipt = (await tx.wait())!;
      const outcomes = await pauseOutcomes(Promise.resolve(tx));
      expect(outcomes).to.have.lengthOf(BATCH);
      expect(outcomes.every((outcome, i) => outcome.name === "WrapperPaused" && outcome.wrapper === wrappers[i])).to.be
        .true;
      for (const address of wrappers) {
        expect(await (await ethers.getContractAt("ConfidentialWrapperMock", address)).paused()).to.be.true;
      }
      // Roughly 45k gas per entry (registry lookup, paused() read, pause() call, two events); a whole chain fits.
      expect(receipt.gasUsed).to.be.lessThan(15_000_000n);
    });

    it("accepts an empty batch", async function () {
      await expect(pauser.connect(pauserA)["pause(address[])"]([])).to.not.be.reverted;
    });
  });

  describe("ABI parity with the live contracts", function () {
    // contracts/selectors.txt is the repo-wide, CI-checked selector inventory. The blocks of the live
    // `ConfidentialWrapper` and `ConfidentialTokenWrappersRegistry` are the references the pauser's interfaces and
    // the mocks must agree with.
    function liveSelectors(contractName: string): Set<string> {
      const text = readFileSync(resolve(__dirname, "../../selectors.txt"), "utf8");
      const start = text.startsWith(`${contractName}\n`) ? 0 : text.indexOf(`\n${contractName}\n`);
      expect(start, `${contractName} block in contracts/selectors.txt`).to.be.greaterThan(-1);
      const end = text.indexOf("\n\n", text.indexOf("╰", start));
      const block = text.slice(start, end === -1 ? undefined : end);
      const selectors = new Set<string>();
      for (const match of block.matchAll(/\|\s*Function\s*\|\s*([^|]+?)\s*\|\s*(0x[0-9a-f]{8})\s*\|/g)) {
        selectors.add(`${match[1]}=${match[2]}`);
      }
      return selectors;
    }

    async function functionSelectors(contractName: string): Promise<string[]> {
      const artifact = await hre.artifacts.readArtifact(contractName);
      const iface = new ethers.Interface(artifact.abi);
      return iface.fragments
        .filter((fragment) => fragment.type === "function")
        .map((fragment) => `${fragment.format("sighash")}=${ethers.id(fragment.format("sighash")).slice(0, 10)}`);
    }

    it("calls the wrapper through selectors the live ConfidentialWrapper exposes", async function () {
      const reference = liveSelectors("ConfidentialWrapper");
      for (const selector of await functionSelectors("IPausableWrapper")) {
        expect(reference.has(selector), selector).to.be.true;
      }
    });

    it("calls the registry through selectors the live ConfidentialTokenWrappersRegistry exposes", async function () {
      const reference = liveSelectors("ConfidentialTokenWrappersRegistry");
      const used = await functionSelectors("IConfidentialTokenWrappersRegistry");
      expect(used).to.have.lengthOf(1);
      for (const selector of used) expect(reference.has(selector), selector).to.be.true;
      const mock = await functionSelectors("ConfidentialTokenWrappersRegistryMock");
      for (const selector of used) expect(mock, selector).to.include(selector);
    });

    it("tests against a mock whose pause surface matches the live ConfidentialWrapper", async function () {
      const reference = liveSelectors("ConfidentialWrapper");
      const surface = ["pause()", "paused()", "pauser()", "setPauser(address)", "unpause()", "owner()"];
      const mock = await functionSelectors("ConfidentialWrapperMock");
      for (const signature of surface) {
        const entry = mock.find((selector) => selector.startsWith(`${signature}=`));
        expect(entry, `${signature} on ConfidentialWrapperMock`).to.not.be.undefined;
        expect(reference.has(entry!), entry).to.be.true;
      }
    });
  });
});
