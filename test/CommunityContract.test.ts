import {
  time,
  loadFixture,
} from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import hre from "hardhat";
import { ethers } from "hardhat";

describe("CommunityContract", function () {
  // We define a fixture to reuse the same setup in every test.
  async function deployCommunityContractFixture() {
    // Get signers
    const [admin, citizen1, citizen2] = await ethers.getSigners();

    // Deploy the contract
    const CommunityContract = await ethers.getContractFactory(
      "CommunityContract"
    );
    const communityContract = await CommunityContract.deploy(admin.address);

    // Test data
    const societyHash = ethers.keccak256(ethers.toUtf8Bytes("TestSociety"));
    const cityZoneHash = ethers.keccak256(ethers.toUtf8Bytes("TestCityZone"));
    const itemHash = ethers.keccak256(ethers.toUtf8Bytes("TestItem"));

    return {
      communityContract,
      admin,
      citizen1,
      citizen2,
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
      expect(await communityContract.admin()).to.equal(admin.address);
    });
  });

  describe("Admin Management", function () {
    it("Should allow admin to change admin", async function () {
      const { communityContract, admin, citizen1 } = await loadFixture(
        deployCommunityContractFixture
      );

      await expect(
        communityContract.connect(admin).changeAdmin(citizen1.address)
      )
        .to.emit(communityContract, "AdminChanged")
        .withArgs(admin.address, citizen1.address);

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
      const { communityContract, admin, societyHash } = await loadFixture(
        deployCommunityContractFixture
      );

      await communityContract.connect(admin).addSociety(societyHash);
      expect(await communityContract.societyCount()).to.equal(1);
    });

    it("Should allow admin to add city zone to society", async function () {
      const { communityContract, admin, societyHash, cityZoneHash, itemHash } =
        await loadFixture(deployCommunityContractFixture);

      await communityContract.connect(admin).addSociety(societyHash);
      await communityContract
        .connect(admin)
        .addCityZone(societyHash, cityZoneHash);

      // We can't directly check cityZoneCount due to struct mapping limitations
      // but we can verify that we can add an item to this city zone
      await expect(
        communityContract.connect(admin).addItem(
          societyHash,
          cityZoneHash,
          itemHash,
          ethers.parseEther("1"), // initialPrice
          ethers.parseEther("0.1"), // minimalPrice
          ethers.parseEther("0.1"), // depreciationRate
          86400, // depreciationInterval (1 day)
          3600, // releaseInterval (1 hour)
          10 // taxRate
        )
      ).to.not.be.reverted;
    });
  });

  describe("Citizen Management", function () {
    it("Should allow registering a new citizen", async function () {
      const { communityContract, admin, citizen1, societyHash } =
        await loadFixture(deployCommunityContractFixture);

      await communityContract.connect(admin).addSociety(societyHash);

      await expect(
        communityContract
          .connect(admin)
          .registerCitizen(societyHash, citizen1.address)
      )
        .to.emit(communityContract, "CitizenRegistered")
        .withArgs(societyHash, citizen1.address, 1); // 1 is the expected citizenId
    });

    it("Should allow citizen to deposit funds", async function () {
      const { communityContract, admin, citizen1, societyHash } =
        await loadFixture(deployCommunityContractFixture);

      await communityContract.connect(admin).addSociety(societyHash);
      await communityContract
        .connect(admin)
        .registerCitizen(societyHash, citizen1.address);

      const depositAmount = ethers.parseEther("1");
      await expect(
        communityContract
          .connect(citizen1)
          .depositFunds(societyHash, { value: depositAmount })
      )
        .to.emit(communityContract, "CitizenDepositReceived")
        .withArgs(societyHash, citizen1.address, depositAmount);
    });
  });

  describe("Item Management", function () {
    async function setupItemFixture() {
      const base = await deployCommunityContractFixture();
      const { communityContract, admin, societyHash, cityZoneHash, itemHash } =
        base;

      await communityContract.connect(admin).addSociety(societyHash);
      await communityContract
        .connect(admin)
        .addCityZone(societyHash, cityZoneHash);
      await communityContract.connect(admin).addItem(
        societyHash,
        cityZoneHash,
        itemHash,
        ethers.parseEther("1"), // initialPrice
        ethers.parseEther("0.1"), // minimalPrice
        ethers.parseEther("0.1"), // depreciationRate
        86400, // depreciationInterval (1 day)
        3600, // releaseInterval (1 hour)
        10 // taxRate
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
      expect(price).to.equal(ethers.parseEther("1")); // Should be initial price since no time has passed
    });

    it("Should allow renting an item", async function () {
      const {
        communityContract,
        citizen1,
        societyHash,
        cityZoneHash,
        itemHash,
      } = await loadFixture(setupItemFixture);

      // Register and fund citizen1
      await communityContract.registerCitizen(societyHash, citizen1.address);
      await communityContract
        .connect(citizen1)
        .depositFunds(societyHash, { value: ethers.parseEther("2") });

      // Rent the item
      const newPrice = ethers.parseEther("1.5");
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
