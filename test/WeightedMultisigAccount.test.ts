import { expect } from "chai";
import { ethers } from "hardhat";

describe("WeightedMultisigAccount", function () {
  let weightedMultisig: any;
  let owner: any;
  let signer1: any;
  let signer2: any;
  let signer3: any;
  let nonSigner: any;
  let ownerAddress: string;
  let signer1Address: string;
  let signer2Address: string;
  let signer3Address: string;
  let nonSignerAddress: string;

  beforeEach(async function () {
    [owner, signer1, signer2, signer3, nonSigner] = await ethers.getSigners();
    ownerAddress = await owner.getAddress();
    signer1Address = await signer1.getAddress();
    signer2Address = await signer2.getAddress();
    signer3Address = await signer3.getAddress();
    nonSignerAddress = await nonSigner.getAddress();

    const WeightedMultisigFactory = await ethers.getContractFactory("WeightedMultisigAccount");
    
    // Initialize with three signers, different weights, and threshold of 100
    weightedMultisig = await WeightedMultisigFactory.deploy(100);

    await weightedMultisig.addSigner(signer1Address, 40);
    await weightedMultisig.addSigner(signer2Address, 30);
    await weightedMultisig.addSigner(signer3Address, 65);

    await weightedMultisig.waitForDeployment();
  });

  describe("Constructor", function () {
    it("should set the owner correctly", async function () {
      expect(await weightedMultisig.owner()).to.equal(ownerAddress);
    });

    it("should recognize initial signers", async function () {
      // Check if the signers are correctly registered
      expect(await weightedMultisig.isSigner(ethers.solidityPacked(["address"], [signer1Address]))).to.be.true;
      expect(await weightedMultisig.isSigner(ethers.solidityPacked(["address"], [signer2Address]))).to.be.true;
      expect(await weightedMultisig.isSigner(ethers.solidityPacked(["address"], [signer3Address]))).to.be.true;
      expect(await weightedMultisig.isSigner(ethers.solidityPacked(["address"], [nonSignerAddress]))).to.be.false;
    });

    it("should set the correct weights for signers", async function () {
      expect(await weightedMultisig.signerWeight(ethers.solidityPacked(["address"], [signer1Address]))).to.equal(40);
      expect(await weightedMultisig.signerWeight(ethers.solidityPacked(["address"], [signer2Address]))).to.equal(30);
      expect(await weightedMultisig.signerWeight(ethers.solidityPacked(["address"], [signer3Address]))).to.equal(65);
    });

    it("should return the correct threshold", async function () {
      expect(await weightedMultisig.threshold()).to.equal(100);
    });

    it("should set the correct threshold", async function () {
      await weightedMultisig.setThreshold(85);
      expect(await weightedMultisig.threshold()).to.equal(85);
    });
  });

  describe("Adding and modifying signers", function () {
    it("should add a new signer with correct weight", async function () {
      await weightedMultisig.addSigner(nonSignerAddress, 25);
      
      expect(await weightedMultisig.isSigner(ethers.solidityPacked(["address"], [nonSignerAddress]))).to.be.true;
      expect(await weightedMultisig.signerWeight(ethers.solidityPacked(["address"], [nonSignerAddress]))).to.equal(25);
    });

    it("should change the weight of an existing signer", async function () {
      await weightedMultisig.changeSignerWeight(signer1Address, 60);
      
      expect(await weightedMultisig.signerWeight(ethers.solidityPacked(["address"], [signer1Address]))).to.equal(60);
    });
  });

  describe("Action proposal and voting", function () {
    let actionHash: string;
    let targetAddress: string;
    let callData: string;
    let value: bigint;

    beforeEach(async function () {
      targetAddress = nonSignerAddress; // Using nonSigner as the target
      callData = "0x"; // Empty call data
      value = ethers.parseEther("0"); // Zero ETH value
      
      // Calculate the action hash
      actionHash = ethers.solidityPackedKeccak256(
        ["address", "uint256", "bytes"],
        [targetAddress, value, callData]
      );

      // Propose an action
      await weightedMultisig.connect(owner).proposeAction(targetAddress, value, callData);
    });

    it("should allow proposing an action", async function () {
      // Check that the action is properly recorded (we can only verify by checking if voting works)
      await expect(weightedMultisig.connect(signer1).voteOnAction(actionHash))
        .to.not.be.reverted;
    });

    it("should prevent proposing the same action twice", async function () {
      await expect(weightedMultisig.proposeAction(targetAddress, value, callData))
        .to.be.revertedWithCustomError(weightedMultisig, "ActionAlreadyProposed")
        .withArgs(actionHash);
    });

    it("should allow a signer to vote on an action", async function () {
      await expect(weightedMultisig.connect(signer1).voteOnAction(actionHash))
        .to.not.be.reverted;
    });

    it("should prevent non-signers from voting", async function () {
      await expect(weightedMultisig.connect(nonSigner).voteOnAction(actionHash))
        .to.be.revertedWithCustomError(weightedMultisig, "NotSigner");
    });

    it("should prevent a signer from voting twice on the same action", async function () {
      await weightedMultisig.connect(signer1).voteOnAction(actionHash);
      
      await expect(weightedMultisig.connect(signer1).voteOnAction(actionHash))
        .to.be.revertedWithCustomError(weightedMultisig, "AlreadyVoted")
        .withArgs(actionHash);
    });

    it("should execute the action when threshold is met", async function () {
      // Create a mock contract to verify the call
      const MockFactory = await ethers.getContractFactory("MockContract");
      const mockContract = await MockFactory.deploy() as any;
      await mockContract.waitForDeployment();

      // Create calldata for a function on the mock contract
      const mockFunctionSignature = new ethers.Interface(["function setValue(uint256 _value)"]);
      const mockCallData = mockFunctionSignature.encodeFunctionData("setValue", [42]);

      // New action with mock contract as target
      const mockTargetAddress = await mockContract.getAddress();
      const newActionHash = ethers.solidityPackedKeccak256(
        ["address", "uint256", "bytes"],
        [mockTargetAddress, 0, mockCallData]
      );

      // Propose and vote on the action
      await weightedMultisig.connect(signer1).proposeAction(mockTargetAddress, 0, mockCallData);
      
      // Signer1 (40) + Signer3 (65) = 105, enough to pass threshold (100)
      await weightedMultisig.connect(signer1).voteOnAction(newActionHash);
      // Action should not be executed yet
      expect(await mockContract.value()).to.equal(0);
      
      await expect(weightedMultisig.connect(signer3).voteOnAction(newActionHash))
        .to.emit(weightedMultisig, "ActionExecuted")
        .withArgs(newActionHash);
      
      // Verify that the action was executed (mock contract's value should be updated)
      expect(await mockContract.value()).to.equal(42);
    });

    it("should not allow voting on a non-existent action", async function () {
      const fakeActionHash = ethers.solidityPackedKeccak256(
        ["address", "uint256", "bytes"],
        [nonSignerAddress, 1, "0x1234"]
      );
      
      await expect(weightedMultisig.connect(signer1).voteOnAction(fakeActionHash))
        .to.be.revertedWithCustomError(weightedMultisig, "ActionNotProposed")
        .withArgs(fakeActionHash);
    });

    it("should not allow voting on an already executed action", async function () {
      // Create a mock contract
      const MockFactory = await ethers.getContractFactory("MockContract");
      const mockContract = await MockFactory.deploy() as any;
      await mockContract.waitForDeployment();

      // Create calldata
      const mockInterface = new ethers.Interface(["function setValue(uint256 _value)"]);
      const mockCallData = mockInterface.encodeFunctionData("setValue", [42]);

      // New action with mock contract as target
      const mockTargetAddress = await mockContract.getAddress();
      const newActionHash = ethers.solidityPackedKeccak256(
        ["address", "uint256", "bytes"],
        [mockTargetAddress, 0, mockCallData]
      );

      // Propose and execute the action
      await weightedMultisig.connect(signer1).proposeAction(mockTargetAddress, 0, mockCallData);
      
      await weightedMultisig.connect(signer1).voteOnAction(newActionHash);
      await weightedMultisig.connect(signer3).voteOnAction(newActionHash);
      
      // Try to vote again
      await expect(weightedMultisig.connect(signer2).voteOnAction(newActionHash))
        .to.be.revertedWithCustomError(weightedMultisig, "ActionAlreadyExecuted")
        .withArgs(newActionHash);
    });

    it("should revert if the action execution fails", async function () {
      // Create a mock contract that can revert
      const MockFactory = await ethers.getContractFactory("MockRevertingContract");
      const mockContract = await MockFactory.deploy() as any;
      await mockContract.waitForDeployment();

      // Create calldata for a function that will revert
      const mockInterface = new ethers.Interface(["function revertingFunction()"]);
      const mockCallData = mockInterface.encodeFunctionData("revertingFunction", []);

      // New action with mock contract as target
      const mockTargetAddress = await mockContract.getAddress();
      const newActionHash = ethers.solidityPackedKeccak256(
        ["address", "uint256", "bytes"],
        [mockTargetAddress, 0, mockCallData]
      );

      // Propose the action
      await weightedMultisig.connect(signer1).proposeAction(mockTargetAddress, 0, mockCallData);
      
      // Get enough votes to execute
      await weightedMultisig.connect(signer1).voteOnAction(newActionHash);
      
      // This should revert because the target function reverts
      await expect(weightedMultisig.connect(signer3).voteOnAction(newActionHash))
        .to.be.revertedWithCustomError(weightedMultisig, "ActionFailed")
        .withArgs(newActionHash);
    });
  });
});
