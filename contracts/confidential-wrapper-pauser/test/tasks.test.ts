import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import hre, { ethers } from "hardhat";

import type { ConfidentialWrapperMock, ConfidentialWrapperPauser, RegistryMock } from "../types";

/**
 * The Hardhat tasks against mocks: the pauser preflight of `task:setPauserProposal` and the per-wrapper pauser /
 * owner drift check of `task:checkPausers`. Both run on the in-process network, so the registry and the expected
 * governance are passed explicitly (there is no `config/networks.json` entry for "hardhat").
 */
describe("Hardhat tasks", function () {
  let deployer: HardhatEthersSigner;
  let governance: HardhatEthersSigner;
  let pauserA: HardhatEthersSigner;
  let outsider: HardhatEthersSigner;
  let pauser: ConfidentialWrapperPauser;
  let armed: ConfidentialWrapperMock;
  let unarmed: ConfidentialWrapperMock;
  let foreignOwned: ConfidentialWrapperMock;
  let revoked: ConfidentialWrapperMock;
  let registry: RegistryMock;

  async function deployFixture() {
    const [deployer, governance, pauserA, outsider] = await ethers.getSigners();
    const pauser = (await ethers.deployContract("ConfidentialWrapperPauser", [
      governance.address,
      [pauserA.address],
    ])) as unknown as ConfidentialWrapperPauser;
    const wrapper = (owner: string, pauserOf: string) =>
      ethers.deployContract("ConfidentialWrapperMock", [
        owner,
        pauserOf,
      ]) as unknown as Promise<ConfidentialWrapperMock>;
    const armed = await wrapper(governance.address, pauser.target as string);
    const unarmed = await wrapper(governance.address, deployer.address);
    const foreignOwned = await wrapper(outsider.address, pauser.target as string);
    const revoked = await wrapper(governance.address, deployer.address);
    const registry = (await ethers.deployContract("RegistryMock")) as unknown as RegistryMock;
    for (const [entry, isValid] of [
      [armed, true],
      [unarmed, true],
      [foreignOwned, true],
      [revoked, false],
    ] as const) {
      await registry.add(ethers.Wallet.createRandom().address, entry.target, isValid);
    }
    return { deployer, governance, pauserA, outsider, pauser, armed, unarmed, foreignOwned, revoked, registry };
  }

  beforeEach(async function () {
    ({ deployer, governance, pauserA, outsider, pauser, armed, unarmed, foreignOwned, revoked, registry } =
      await loadFixture(deployFixture));
  });

  /** Runs a task with the console silenced; the tasks print a report, tests read their return value. */
  async function run<T>(name: string, args: Record<string, unknown>): Promise<T> {
    const saved = { log: console.log, warn: console.warn, error: console.error };
    Object.assign(console, { log: () => {}, warn: () => {}, error: () => {} });
    try {
      return (await hre.run(name, args)) as T;
    } finally {
      Object.assign(console, saved);
    }
  }

  describe("pauser preflight (shared by both tasks)", function () {
    for (const name of ["task:setPauserProposal", "task:checkPausers"]) {
      it(`${name} rejects the zero address, an EOA and a contract that is not a pauser`, async function () {
        const base = { registry: registry.target, governance: governance.address, strict: false };
        await expect(run(name, { ...base, pauser: ethers.ZeroAddress })).to.be.rejectedWith(/zero address/);
        await expect(run(name, { ...base, pauser: outsider.address })).to.be.rejectedWith(/has no code/);
        await expect(run(name, { ...base, pauser: registry.target })).to.be.rejectedWith(
          /not a ConfidentialWrapperPauser/,
        );
      });
    }
  });

  describe("task:setPauserProposal", function () {
    it("refuses a pauser that is not owned by the expected governance", async function () {
      await expect(
        run("task:setPauserProposal", {
          pauser: pauser.target,
          registry: registry.target,
          governance: outsider.address,
        }),
      ).to.be.rejectedWith(/refusing to build the proposal: pauser owner .* is not --governance/);
    });

    it("builds one setPauser action per unarmed wrapper, revoked ones included and marked, skipping armed ones", async function () {
      const payload = await run<{
        pauser: string;
        pauserOwner: string;
        roster: string[];
        actions: { to: string; data: string; revoked: boolean }[];
      }>("task:setPauserProposal", {
        pauser: pauser.target,
        registry: registry.target,
        governance: governance.address,
      });
      expect(payload.pauser).to.equal(pauser.target);
      expect(payload.pauserOwner).to.equal(governance.address);
      expect(payload.roster).to.deep.equal([pauserA.address]);
      expect(payload.actions.map((a) => a.to)).to.deep.equal([unarmed.target, revoked.target]);
      expect(payload.actions.map((a) => a.revoked)).to.deep.equal([false, true]);
      const iface = new ethers.Interface(["function setPauser(address)"]);
      for (const action of payload.actions) {
        expect(action.data).to.equal(iface.encodeFunctionData("setPauser", [pauser.target]));
      }
    });

    it("falls back to the pauser's owner when no governance is configured", async function () {
      const payload = await run<{ actions: unknown[] }>("task:setPauserProposal", {
        pauser: pauser.target,
        registry: registry.target,
      });
      expect(payload.actions).to.have.lengthOf(2);
    });
  });

  describe("task:checkPausers", function () {
    it("reports an unarmed wrapper, a wrapper not owned by governance and an unarmed revoked wrapper, and nothing else", async function () {
      const failures = await run<string[]>("task:checkPausers", {
        pauser: pauser.target,
        registry: registry.target,
        governance: governance.address,
        strict: false,
      });
      expect(failures).to.have.lengthOf(3);
      expect(failures[0]).to.match(new RegExp(`${unarmed.target}: pauser\\(\\) is ${deployer.address}`));
      expect(failures[1]).to.match(
        new RegExp(`${foreignOwned.target}: owner\\(\\) is ${outsider.address}, not ${governance.address}`),
      );
      expect(failures[2]).to.match(new RegExp(`${revoked.target}: pauser\\(\\) is ${deployer.address}`));
    });

    it("uses the pauser's owner as the expected wrapper owner when no governance is configured", async function () {
      const failures = await run<string[]>("task:checkPausers", {
        pauser: pauser.target,
        registry: registry.target,
        strict: false,
      });
      expect(failures.filter((f) => f.includes("owner()"))).to.have.lengthOf(1);
      expect(failures.find((f) => f.includes("owner()"))).to.include(foreignOwned.target as string);
    });

    it("reports a pauser owner that is not governance as a failure instead of aborting", async function () {
      const failures = await run<string[]>("task:checkPausers", {
        pauser: pauser.target,
        registry: registry.target,
        governance: outsider.address,
        strict: false,
      });
      expect(failures[0]).to.match(/^pauser owner .* is not --governance/);
    });

    it("reports a roster mismatch and is green once every check passes", async function () {
      await unarmed.connect(governance).setPauser(pauser.target);
      await revoked.connect(governance).setPauser(pauser.target);
      await foreignOwned.connect(outsider).transferOwnership(governance.address);
      const mismatch = await run<string[]>("task:checkPausers", {
        pauser: pauser.target,
        registry: registry.target,
        governance: governance.address,
        expectedPausers: `${pauserA.address},${outsider.address}`,
        strict: false,
      });
      expect(mismatch).to.have.lengthOf(1);
      expect(mismatch[0]).to.match(/^roster mismatch/);
      const green = await run<string[]>("task:checkPausers", {
        pauser: pauser.target,
        registry: registry.target,
        governance: governance.address,
        expectedPausers: pauserA.address,
        strict: false,
      });
      expect(green).to.deep.equal([]);
    });
  });
});
