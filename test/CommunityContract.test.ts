import {
  time,
  loadFixture,
} from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";

describe("CommunityContract", function () {
  // We define a fixture to reuse the same setup in every test.
  async function deployCommunityContractFixture() {
    // Get signers
    const [citizen1, citizen2, citizen3, nonCitizen] = await ethers.getSigners();

    // Deploy the USDC token
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    const usdcToken = await MockUSDC.deploy();

    const WeightedMultisigAccount = await ethers.getContractFactory("WeightedMultisigAccount");
    const admin = await WeightedMultisigAccount.deploy(200);

    // Deploy the contract
    const CommunityContract = await ethers.getContractFactory(
      "CommunityContract"
    );
    const communityContract = await CommunityContract.deploy(
      await admin.getAddress(), 
      await usdcToken.getAddress()
    );

    // Test data
    const societyHash = ethers.keccak256(ethers.toUtf8Bytes("TestSociety"));
    const cityZoneHash = ethers.keccak256(ethers.toUtf8Bytes("TestCityZone"));
    const itemHash = ethers.keccak256(ethers.toUtf8Bytes("TestItem"));

    await communityContract.connect(citizen1).addSociety(societyHash);
    await communityContract.registerCitizen(societyHash, citizen1.address);
    await communityContract.registerCitizen(societyHash, citizen2.address);
    await communityContract.registerCitizen(societyHash, citizen3.address);

    return {
      communityContract,
      admin,
      usdcToken,
      citizen1,
      citizen2,
      citizen3,
      nonCitizen,
      societyHash,
      cityZoneHash,
      itemHash,
    };
  }

  describe("Deployment", function () {
    it("Should set the right admin", async function () {
      const { communityContract, admin } = await loadFixture(
        deployCommunityContractFixture
      );
      expect(await communityContract.admin()).to.equal(await admin.getAddress());
    });
  });

  describe("Admin Management", function () {
    it("Should allow admin to change admin", async function () {
      const { communityContract, admin, citizen1, citizen3 } = await loadFixture(
        deployCommunityContractFixture
      );

      // Create call data for changeAdmin function
      const changeAdminInterface = new ethers.Interface(["function changeAdmin(address _newAdmin)"]);
      const changeAdminData = changeAdminInterface.encodeFunctionData("changeAdmin", [citizen1.address]);
      
      // Get action hash for voting
      const actionHash = ethers.solidityPackedKeccak256(
        ["address", "uint256", "bytes"],
        [await communityContract.getAddress(), 0, changeAdminData]
      );

      // Propose action through the multisig
      await admin.connect(citizen1).proposeAction(
        await communityContract.getAddress(), 
        0, 
        changeAdminData
      );

      // Vote on the action - citizen3 has enough weight to pass threshold with citizen1
      await admin.connect(citizen1).voteOnAction(actionHash);
      await admin.connect(citizen3).voteOnAction(actionHash);

      // Verify admin was changed
      expect(await communityContract.admin()).to.equal(citizen1.address);
    });

    it("Should not allow non-admin to change admin", async function () {
      const { communityContract, citizen1 } = await loadFixture(
        deployCommunityContractFixture
      );

      await expect(
        communityContract.connect(citizen1).changeAdmin(citizen1.address)
      ).to.be.revertedWith("Only admin can call this function");
    });
  });

  describe("Society Management", function () {
    it("Should allow admin to add society", async function () {
      const { communityContract, citizen1 } = await loadFixture(
        deployCommunityContractFixture
      );

      const newSocietyHash = ethers.keccak256(ethers.toUtf8Bytes("TestAddNewSociety"));

      await communityContract.connect(citizen1).addSociety(newSocietyHash);
      expect(await communityContract.societyCount()).to.equal(2);
    });

    it("Should allow admin to add city zone to society", async function () {
      const { communityContract, citizen1, societyHash, cityZoneHash, itemHash } =
        await loadFixture(deployCommunityContractFixture);

      await communityContract.connect(citizen1).addSociety(societyHash);
      await communityContract
        .connect(citizen1)
        .addCityZone(societyHash, cityZoneHash);

      // We can't directly check cityZoneCount due to struct mapping limitations
      // but we can verify that we can add an item to this city zone
      await expect(
        communityContract.connect(citizen1).addItem(
          societyHash,
          cityZoneHash,
          itemHash,
          1000000, // initialPrice (1 USDC)
          100000, // minimalPrice (0.1 USDC)
          100000, // depreciationRate (0.1 USDC)
          86400, // depreciationInterval (1 day)
          3600, // releaseInterval (1 hour)
          10, // taxRate
          true // isDepreciationEnabled
        )
      ).to.not.be.reverted;
    });
  });

  describe("Citizen Management", function () {
    it("Should allow registering a new citizen", async function () {
      const { communityContract, nonCitizen, societyHash } =
        await loadFixture(deployCommunityContractFixture);

      await communityContract.connect(nonCitizen).addSociety(societyHash);

      await expect(
        communityContract
          .connect(nonCitizen)
          .registerCitizen(societyHash, nonCitizen.address)
      )
        .to.emit(communityContract, "CitizenRegistered")
        .withArgs(societyHash, nonCitizen.address, 1); // 1 is the expected citizenId
    });

    it("Should allow citizen to deposit funds", async function () {
      const { communityContract, citizen1, societyHash, usdcToken } =
        await loadFixture(deployCommunityContractFixture);

      const depositAmount = 1000000; // 1 USDC
            
      // Approve and deposit
      await (usdcToken as any).connect(citizen1).approve(await communityContract.getAddress(), depositAmount);
      await expect(
        communityContract
          .connect(citizen1)
          .depositFunds(societyHash, depositAmount)
      )
        .to.emit(communityContract, "CitizenDepositReceived")
        .withArgs(societyHash, citizen1.address, depositAmount);
    });
  });

  describe("Item Management", function () {
    async function setupItemFixture() {
      const base = await deployCommunityContractFixture();
      const { communityContract, societyHash, cityZoneHash, itemHash, usdcToken, citizen1 } =
        base;

      await communityContract
        .connect(citizen1)
        .addCityZone(societyHash, cityZoneHash);

      await communityContract.connect(citizen1).addItem(
        societyHash,
        cityZoneHash,
        itemHash,
        1000000, // initialPrice (1 USDC)
        100000, // minimalPrice (0.1 USDC)
        100000, // depreciationRate (0.1 USDC)
        86400, // depreciationInterval (1 day)
        3600, // releaseInterval (1 hour)
        10, // taxRate
        true // isDepreciationEnabled
      );

      return { ...base };
    }

    it("Should return correct item price when not rented", async function () {
      const { communityContract, societyHash, cityZoneHash, itemHash } =
        await loadFixture(setupItemFixture);

      const price = await communityContract.getItemPrice(
        societyHash,
        cityZoneHash,
        itemHash
      );
      expect(price).to.equal(1000000); // Should be initial price (1 USDC) since no time has passed
    });

    it("Should allow renting an item", async function () {
      const {
        communityContract,
        citizen1,
        societyHash,
        cityZoneHash,
        itemHash,
        usdcToken,
        admin,
      } = await loadFixture(setupItemFixture);

      const depositAmount = 2000000; // 2 USDC
      
      // Transfer USDC to citizen1
      await (usdcToken as any).transfer(citizen1.address, depositAmount);
      
      // Approve and deposit
      await (usdcToken as any).connect(citizen1).approve(await communityContract.getAddress(), depositAmount);
      
      await communityContract
        .connect(citizen1)
        .depositFunds(societyHash, depositAmount);

      // Rent the item
      const newPrice = 1500000; // 1.5 USDC
      await expect(
        communityContract
          .connect(citizen1)
          .rentItem(societyHash, cityZoneHash, itemHash, newPrice)
      )
        .to.emit(communityContract, "ItemRented")
        .withArgs(
          societyHash,
          cityZoneHash,
          itemHash,
          newPrice,
          citizen1.address
        );

      // Verify the item is rented
      expect(
        await communityContract.getCurrentItemRenter(
          societyHash,
          cityZoneHash,
          itemHash
        )
      ).to.equal(citizen1.address);
    });
  });
});
