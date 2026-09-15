import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { readFileSync } from "fs";
import hre, { ethers } from "hardhat";
import { resolve } from "path";

import type {
  BrokenWrapperMock,
  ConfidentialWrapperMock,
  ConfidentialWrapperPauser,
  PermissiveFallbackMock,
  ReentrantWrapperMock,
} from "../types";

describe("ConfidentialWrapperPauser", function () {
  let governance: HardhatEthersSigner;
  let pauserA: HardhatEthersSigner;
  let pauserB: HardhatEthersSigner;
  let outsider: HardhatEthersSigner;
  let newGovernance: HardhatEthersSigner;

  let pauser: ConfidentialWrapperPauser;
  let wrapper1: ConfidentialWrapperMock;
  let wrapper2: ConfidentialWrapperMock;
  let unarmed: ConfidentialWrapperMock;

  async function deployFixture() {
    const [deployer, governance, pauserA, pauserB, outsider, newGovernance] = await ethers.getSigners();

    const pauser = (await ethers.deployContract("ConfidentialWrapperPauser", [
      governance.address,
      [pauserA.address, pauserB.address],
    ])) as unknown as ConfidentialWrapperPauser;

    // Two wrappers armed with the pauser contract, one still armed with an unrelated address.
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

    return { governance, pauserA, pauserB, outsider, newGovernance, pauser, wrapper1, wrapper2, unarmed };
  }

  async function deployBroken(): Promise<BrokenWrapperMock> {
    return (await ethers.deployContract("BrokenWrapperMock")) as unknown as BrokenWrapperMock;
  }

  async function deployPermissive(): Promise<PermissiveFallbackMock> {
    return (await ethers.deployContract("PermissiveFallbackMock")) as unknown as PermissiveFallbackMock;
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
    ({ governance, pauserA, pauserB, outsider, newGovernance, pauser, wrapper1, wrapper2, unarmed } =
      await loadFixture(deployFixture));
  });

  describe("constructor", function () {
    it("makes governance the owner with no pending owner", async function () {
      expect(await pauser.owner()).to.equal(governance.address);
      expect(await pauser.pendingOwner()).to.equal(ethers.ZeroAddress);
    });

    it("seeds the roster in order and emits PauserAdded for each member", async function () {
      expect(await pauser.pausers()).to.deep.equal([pauserA.address, pauserB.address]);
      expect(await pauser.isPauser(pauserA.address)).to.be.true;
      expect(await pauser.isPauser(pauserB.address)).to.be.true;
      expect(await pauser.isPauser(governance.address)).to.be.false;
      expect(await pauser.isPauser(outsider.address)).to.be.false;

      const added = await pauser.queryFilter(pauser.filters.PauserAdded());
      expect(added.map((event) => event.args.account)).to.deep.equal([pauserA.address, pauserB.address]);
    });

    it("accepts an empty roster", async function () {
      const empty = await ethers.deployContract("ConfidentialWrapperPauser", [governance.address, []]);
      expect(await empty.pausers()).to.deep.equal([]);
    });

    it("adds a duplicated pauser once", async function () {
      const deployed = (await ethers.deployContract("ConfidentialWrapperPauser", [
        governance.address,
        [pauserA.address, pauserA.address],
      ])) as unknown as ConfidentialWrapperPauser;
      expect(await deployed.pausers()).to.deep.equal([pauserA.address]);
      const added = await deployed.queryFilter(deployed.filters.PauserAdded());
      expect(added).to.have.lengthOf(1);
    });

    it("reverts on a zero-address owner", async function () {
      await expect(ethers.deployContract("ConfidentialWrapperPauser", [ethers.ZeroAddress, [pauserA.address]]))
        .to.be.revertedWithCustomError(pauser, "OwnableInvalidOwner")
        .withArgs(ethers.ZeroAddress);
    });

    it("does not put the owner on the roster by default", async function () {
      await expect(pauser.connect(governance)["pause(address)"](wrapper1.target))
        .to.be.revertedWithCustomError(pauser, "SenderNotPauser")
        .withArgs(governance.address);
    });
  });

  describe("roster management", function () {
    it("lets the owner add a pauser, emitting PauserAdded", async function () {
      await expect(pauser.connect(governance).addPauser(outsider.address))
        .to.emit(pauser, "PauserAdded")
        .withArgs(outsider.address);
      expect(await pauser.pausers()).to.deep.equal([pauserA.address, pauserB.address, outsider.address]);
      expect(await pauser.isPauser(outsider.address)).to.be.true;
    });

    it("lets the owner remove a pauser, who then cannot pause", async function () {
      await expect(pauser.connect(governance).removePauser(pauserA.address))
        .to.emit(pauser, "PauserRemoved")
        .withArgs(pauserA.address);
      // EnumerableSet moves the last entry into the freed slot.
      expect(await pauser.pausers()).to.deep.equal([pauserB.address]);
      expect(await pauser.isPauser(pauserA.address)).to.be.false;

      await expect(pauser.connect(pauserA)["pause(address)"](wrapper1.target))
        .to.be.revertedWithCustomError(pauser, "SenderNotPauser")
        .withArgs(pauserA.address);
    });

    it("is a silent no-op when adding an existing member or removing a non-member", async function () {
      await expect(pauser.connect(governance).addPauser(pauserA.address)).to.not.emit(pauser, "PauserAdded");
      await expect(pauser.connect(governance).removePauser(outsider.address)).to.not.emit(pauser, "PauserRemoved");
      expect(await pauser.pausers()).to.deep.equal([pauserA.address, pauserB.address]);
    });

    it("fills the freed slot with the last member on removal (swap-and-pop), so order is not stable", async function () {
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

    it("rejects roster changes from anyone but the owner", async function () {
      await expect(pauser.connect(pauserA).addPauser(outsider.address))
        .to.be.revertedWithCustomError(pauser, "OwnableUnauthorizedAccount")
        .withArgs(pauserA.address);
      await expect(pauser.connect(outsider).removePauser(pauserA.address))
        .to.be.revertedWithCustomError(pauser, "OwnableUnauthorizedAccount")
        .withArgs(outsider.address);
      expect(await pauser.pausers()).to.deep.equal([pauserA.address, pauserB.address]);
    });
  });

  describe("ownership (Ownable2Step)", function () {
    it("moves the owner only once the new owner accepts, keeping the roster intact", async function () {
      await expect(pauser.connect(governance).transferOwnership(newGovernance.address))
        .to.emit(pauser, "OwnershipTransferStarted")
        .withArgs(governance.address, newGovernance.address);
      expect(await pauser.pendingOwner()).to.equal(newGovernance.address);
      // Still the old owner until accepted.
      expect(await pauser.owner()).to.equal(governance.address);
      await pauser.connect(governance).addPauser(outsider.address);

      await expect(pauser.connect(outsider).acceptOwnership())
        .to.be.revertedWithCustomError(pauser, "OwnableUnauthorizedAccount")
        .withArgs(outsider.address);

      await expect(pauser.connect(newGovernance).acceptOwnership())
        .to.emit(pauser, "OwnershipTransferred")
        .withArgs(governance.address, newGovernance.address);
      expect(await pauser.owner()).to.equal(newGovernance.address);
      expect(await pauser.pendingOwner()).to.equal(ethers.ZeroAddress);
      expect(await pauser.pausers()).to.deep.equal([pauserA.address, pauserB.address, outsider.address]);

      await pauser.connect(newGovernance).removePauser(outsider.address);
      await expect(pauser.connect(governance).addPauser(governance.address))
        .to.be.revertedWithCustomError(pauser, "OwnableUnauthorizedAccount")
        .withArgs(governance.address);
    });

    it("lets the owner replace or cancel a pending transfer", async function () {
      await pauser.connect(governance).transferOwnership(newGovernance.address);
      await pauser.connect(governance).transferOwnership(outsider.address);
      expect(await pauser.pendingOwner()).to.equal(outsider.address);
      await expect(pauser.connect(newGovernance).acceptOwnership())
        .to.be.revertedWithCustomError(pauser, "OwnableUnauthorizedAccount")
        .withArgs(newGovernance.address);

      // Ownable2Step cancels a pending transfer by nominating the zero address.
      await pauser.connect(governance).transferOwnership(ethers.ZeroAddress);
      expect(await pauser.pendingOwner()).to.equal(ethers.ZeroAddress);
      await expect(pauser.connect(outsider).acceptOwnership())
        .to.be.revertedWithCustomError(pauser, "OwnableUnauthorizedAccount")
        .withArgs(outsider.address);
      expect(await pauser.owner()).to.equal(governance.address);
    });

    it("rejects transfers from anyone but the owner", async function () {
      await expect(pauser.connect(pauserA).transferOwnership(pauserA.address))
        .to.be.revertedWithCustomError(pauser, "OwnableUnauthorizedAccount")
        .withArgs(pauserA.address);
    });

    it("refuses to renounce ownership", async function () {
      await expect(pauser.connect(governance).renounceOwnership()).to.be.revertedWithCustomError(
        pauser,
        "RenounceOwnershipDisabled",
      );
      await expect(pauser.connect(outsider).renounceOwnership())
        .to.be.revertedWithCustomError(pauser, "OwnableUnauthorizedAccount")
        .withArgs(outsider.address);
      expect(await pauser.owner()).to.equal(governance.address);
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

    it("reverts with PauseFailed and empty data when the target reverts without data", async function () {
      const broken = await deployBroken();
      await expect(pauser.connect(pauserA)["pause(address)"](broken.target))
        .to.be.revertedWithCustomError(pauser, "PauseFailed")
        .withArgs(broken.target, "0x");
    });

    it("aborts on a target without the pause API (accepted: picking wrappers is the roster's job)", async function () {
      // There is no allowlist and no low-level probing: `paused()` is an ordinary call, so an address that answers
      // nothing to it (a WETH-style fallback, an EOA, the zero address) reverts the pauser itself, in both forms,
      // instead of being reported. P-RFC-006 puts target selection on the roster member; the runbook says so.
      const notAWrapper = await deployPermissive();
      for (const target of [notAWrapper.target, outsider.address, ethers.ZeroAddress]) {
        await expect(pauser.connect(pauserA)["pause(address)"](target)).to.be.revertedWithoutReason();
        await expect(
          pauser.connect(pauserA)["pause(address[])"]([wrapper1.target, target]),
        ).to.be.revertedWithoutReason();
      }
      expect(await wrapper1.paused()).to.be.false;
    });

    for (const [name, callback] of [
      ["pause(address)", CALLBACK.PauseOther],
      ["pause(address[])", CALLBACK.PauseBatch],
      ["addPauser", CALLBACK.AddSelf],
    ] as const) {
      it(`rejects a wrapper that re-enters ${name} from its pause(), surfacing the inner error`, async function () {
        const reentrant = await deployReentrant(callback, false);
        // The re-entrant call is refused because the wrapper is neither a roster member nor the owner; the mock
        // wraps that revert data in its own CallbackRejected(bytes).
        const innerError =
          callback === CALLBACK.AddSelf
            ? encodeError("OwnableUnauthorizedAccount(address)", [reentrant.target])
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
      const outcomes = await pauseOutcomes(
        pauser
          .connect(pauserA)
          ["pause(address[])"]([wrapper1.target, wrapper2.target, broken.target, unarmed.target, wrapper1.target]),
      );
      expect(outcomes).to.deep.equal([
        { name: "WrapperPaused", wrapper: wrapper1.target },
        { name: "WrapperAlreadyPaused", wrapper: wrapper2.target },
        { name: "WrapperPauseFailed", wrapper: broken.target, errorData: "0x" },
        {
          name: "WrapperPauseFailed",
          wrapper: unarmed.target,
          errorData: encodeError("SenderNotPauser(address)", [pauser.target]),
        },
        // Second occurrence of wrapper1: paused by this very batch, so already paused now.
        { name: "WrapperAlreadyPaused", wrapper: wrapper1.target },
      ]);
      expect(await wrapper1.paused()).to.be.true;
      expect(await wrapper2.paused()).to.be.true;
      expect(await unarmed.paused()).to.be.false;
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

    it("pauses a large batch in one transaction well within the block gas limit", async function () {
      const BATCH = 128;
      const wrappers: string[] = [];
      for (let i = 0; i < BATCH; i++) {
        const wrapper = await ethers.deployContract("ConfidentialWrapperMock", [governance.address, pauser.target]);
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
      // Roughly 40k gas per entry (paused() read, pause() call, two events); a whole chain fits.
      expect(receipt.gasUsed).to.be.lessThan(15_000_000n);
    });

    it("accepts an empty batch", async function () {
      await expect(pauser.connect(pauserA)["pause(address[])"]([])).to.not.be.reverted;
    });
  });

  describe("ABI parity with the live ConfidentialWrapper", function () {
    // contracts/selectors.txt is the repo-wide, CI-checked selector inventory. The block of the live
    // `ConfidentialWrapper` is the reference the pauser's wrapper interface and the mock must agree with.
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
