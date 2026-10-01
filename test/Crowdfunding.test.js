const { expect } = require("chai");
const { ethers, network } = require("hardhat");

const DAY = 24 * 60 * 60;
const units = (value) => ethers.parseUnits(value, 6);

describe("Tokenized Crowdfunding", function () {
  let owner;
  let creator;
  let alice;
  let bob;
  let treasury;
  let outsider;
  let token;
  let crowdfunding;

  async function createCampaign({ goal = units("100"), minimum = units("10"), duration = 7 * DAY } = {}) {
    const campaignId = await crowdfunding.nextCampaignId();
    await crowdfunding.connect(creator).createCampaign(await token.getAddress(), goal, minimum, duration);
    return campaignId;
  }

  async function contribute(campaignId, contributor, amount) {
    await token.connect(contributor).approve(await crowdfunding.getAddress(), amount);
    return crowdfunding.connect(contributor).contribute(campaignId, amount);
  }

  async function expectCustomError(transaction, error, contract = crowdfunding) {
    await expect(transaction).to.be.revertedWithCustomError(contract, error);
  }

  async function expireCampaign(campaignId) {
    const campaign = await crowdfunding.getCampaign(campaignId);
    await network.provider.send("evm_setNextBlockTimestamp", [Number(campaign.deadline)]);
    await network.provider.send("evm_mine");
  }

  beforeEach(async function () {
    [owner, creator, alice, bob, treasury, outsider] = await ethers.getSigners();

    const CampaignToken = await ethers.getContractFactory("CampaignToken");
    token = await CampaignToken.deploy(owner.address);
    await token.waitForDeployment();

    const Crowdfunding = await ethers.getContractFactory("Crowdfunding");
    crowdfunding = await Crowdfunding.deploy(treasury.address, 250);
    await crowdfunding.waitForDeployment();

    await token.mint(alice.address, units("1000"));
    await token.mint(bob.address, units("1000"));
  });

  it("deploys the six-decimal token and initializes the fee configuration", async function () {
    expect(await token.decimals()).to.equal(6);
    expect(await token.owner()).to.equal(owner.address);
    expect(await crowdfunding.treasury()).to.equal(treasury.address);
    expect(await crowdfunding.feeBps()).to.equal(250);
  });

  it("creates a campaign with its creator, goal, deadline, and fee snapshot", async function () {
    const campaignId = await createCampaign();
    const campaign = await crowdfunding.getCampaign(campaignId);

    expect(campaign.campaignId).to.equal(campaignId);
    expect(campaign.creator).to.equal(creator.address);
    expect(campaign.token).to.equal(await token.getAddress());
    expect(campaign.fundingGoal).to.equal(units("100"));
    expect(campaign.totalRaised).to.equal(0);
    expect(campaign.minimumContribution).to.equal(units("10"));
    expect(campaign.deadline).to.be.greaterThan(campaign.createdAt);
    expect(campaign.claimed).to.equal(false);
    expect(campaign.cancelled).to.equal(false);
    expect(await crowdfunding.campaignFeeBps(campaignId)).to.equal(250);
  });

  it("accepts contributions and tracks contributor totals", async function () {
    const campaignId = await createCampaign();
    await contribute(campaignId, alice, units("20"));
    await contribute(campaignId, alice, units("10"));
    await contribute(campaignId, bob, units("30"));

    expect(await token.balanceOf(await crowdfunding.getAddress())).to.equal(units("60"));
    expect((await crowdfunding.getCampaign(campaignId)).totalRaised).to.equal(units("60"));
    expect(await crowdfunding.getContribution(campaignId, alice.address)).to.equal(units("30"));
    expect(await crowdfunding.getContributors(campaignId)).to.deep.equal([alice.address, bob.address]);
  });

  it("enforces the minimum contribution on each deposit", async function () {
    const campaignId = await createCampaign();
    await token.connect(alice).approve(await crowdfunding.getAddress(), units("9"));

    await expectCustomError(crowdfunding.connect(alice).contribute(campaignId, units("9")), "ContributionTooSmall");
  });

  it("prevents contributions above the remaining funding goal", async function () {
    const campaignId = await createCampaign({ goal: units("100") });
    await contribute(campaignId, alice, units("80"));
    await token.connect(bob).approve(await crowdfunding.getAddress(), units("30"));

    await expectCustomError(crowdfunding.connect(bob).contribute(campaignId, units("30")), "ContributionExceedsRemaining");
    expect(await crowdfunding.getRemainingFunding(campaignId)).to.equal(units("20"));
  });

  it("marks a campaign successful exactly at its goal", async function () {
    const campaignId = await createCampaign({ goal: units("100") });
    await contribute(campaignId, alice, units("60"));
    await expect(contribute(campaignId, bob, units("40")))
      .to.emit(crowdfunding, "CampaignSuccessful")
      .withArgs(campaignId, units("100"));

    expect(await crowdfunding.isSuccessful(campaignId)).to.equal(true);
    expect(await crowdfunding.getRemainingFunding(campaignId)).to.equal(0);
    await expectCustomError(crowdfunding.connect(alice).contribute(campaignId, units("10")), "CampaignGoalReached");
  });

  it("pays the creator net funds and the treasury its platform fee", async function () {
    const campaignId = await createCampaign({ goal: units("100") });
    await crowdfunding.connect(owner).setFeeConfig(outsider.address, 500);
    await contribute(campaignId, alice, units("100"));

    await expect(crowdfunding.connect(creator).claimFunds(campaignId))
      .to.emit(crowdfunding, "FundsClaimed")
      .withArgs(campaignId, creator.address, units("97.5"), units("2.5"));

    expect(await token.balanceOf(creator.address)).to.equal(units("97.5"));
    expect(await token.balanceOf(treasury.address)).to.equal(units("2.5"));
    expect(await token.balanceOf(outsider.address)).to.equal(0);
    expect(await token.balanceOf(await crowdfunding.getAddress())).to.equal(0);
    expect((await crowdfunding.getCampaign(campaignId)).claimed).to.equal(true);
    await expectCustomError(crowdfunding.connect(creator).claimFunds(campaignId), "CampaignAlreadyClaimed");
  });

  it("allows contributors to reclaim funds after an unsuccessful campaign expires", async function () {
    const campaignId = await createCampaign();
    await contribute(campaignId, alice, units("20"));
    const balanceBeforeRefund = await token.balanceOf(alice.address);
    await expireCampaign(campaignId);

    expect(await crowdfunding.isExpired(campaignId)).to.equal(true);
    await expect(crowdfunding.connect(alice).claimRefund(campaignId))
      .to.emit(crowdfunding, "RefundClaimed").withArgs(campaignId, alice.address, units("20"));
    expect(await token.balanceOf(alice.address)).to.equal(balanceBeforeRefund + units("20"));
    expect(await crowdfunding.getContribution(campaignId, alice.address)).to.equal(0);
    await expectCustomError(crowdfunding.connect(alice).claimRefund(campaignId), "NothingToRefund");
  });

  it("allows cancellation refunds and rejects actions after the deadline", async function () {
    const cancelledId = await createCampaign();
    await contribute(cancelledId, alice, units("20"));
    await expect(crowdfunding.connect(creator).cancelCampaign(cancelledId))
      .to.emit(crowdfunding, "CampaignCancelled").withArgs(cancelledId, creator.address);
    await crowdfunding.connect(alice).claimRefund(cancelledId);
    expect(await token.balanceOf(alice.address)).to.equal(units("1000"));

    const expiredId = await createCampaign({ duration: 60 });
    await contribute(expiredId, alice, units("20"));
    await expireCampaign(expiredId);
    await token.connect(bob).approve(await crowdfunding.getAddress(), units("20"));
    await expectCustomError(crowdfunding.connect(bob).contribute(expiredId, units("20")), "CampaignExpired");
    await expectCustomError(crowdfunding.connect(creator).cancelCampaign(expiredId), "CampaignExpired");
  });

  it("restricts creator and owner actions and validates fee settings", async function () {
    const campaignId = await createCampaign();
    const Crowdfunding = await ethers.getContractFactory("Crowdfunding");
    await expectCustomError(crowdfunding.connect(outsider).cancelCampaign(campaignId), "NotCampaignCreator");
    await expectCustomError(crowdfunding.connect(outsider).claimFunds(campaignId), "NotCampaignCreator");
    await expectCustomError(Crowdfunding.deploy(ethers.ZeroAddress, 100), "InvalidAddress", Crowdfunding);
    await expectCustomError(Crowdfunding.deploy(treasury.address, 1001), "FeeTooHigh", Crowdfunding);
    await expectCustomError(crowdfunding.connect(outsider).setFeeConfig(outsider.address, 100), "OwnableUnauthorizedAccount");
    await expectCustomError(crowdfunding.connect(owner).setFeeConfig(ethers.ZeroAddress, 100), "InvalidAddress");
    await expectCustomError(crowdfunding.connect(owner).setFeeConfig(treasury.address, 1001), "FeeTooHigh");
  });
});