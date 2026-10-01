const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  const treasury = process.env.TREASURY_ADDRESS || deployer.address;
  const feeBps = Number(process.env.PLATFORM_FEE_BPS || 250);

  const CampaignToken = await ethers.getContractFactory("CampaignToken");
  const token = await CampaignToken.deploy(deployer.address);
  await token.waitForDeployment();

  const Crowdfunding = await ethers.getContractFactory("Crowdfunding");
  const crowdfunding = await Crowdfunding.deploy(treasury, feeBps);
  await crowdfunding.waitForDeployment();

  console.log(`CampaignToken: ${await token.getAddress()}`);
  console.log(`Crowdfunding: ${await crowdfunding.getAddress()}`);
  console.log(`Treasury: ${treasury}`);
  console.log(`Platform fee: ${feeBps} bps`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});