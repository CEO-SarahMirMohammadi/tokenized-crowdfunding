// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Crowdfunding is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_FEE_BPS = 1_000;
    uint16 public constant BASIS_POINTS = 10_000;

    struct Campaign {
        uint256 campaignId;
        address creator;
        IERC20 token;
        uint256 fundingGoal;
        uint256 totalRaised;
        uint256 minimumContribution;
        uint256 deadline;
        bool claimed;
        bool cancelled;
        uint256 createdAt;
    }

    uint256 public nextCampaignId = 1;
    address public treasury;
    uint16 public feeBps;

    mapping(uint256 campaignId => Campaign campaign) public campaigns;
    mapping(uint256 campaignId => mapping(address contributor => uint256 amount)) public contributions;
    mapping(uint256 campaignId => address[] contributors) private campaignContributors;
    mapping(uint256 campaignId => mapping(address contributor => bool listed)) private contributorListed;
    mapping(uint256 campaignId => uint16 feeSnapshotBps) public campaignFeeBps;
    mapping(uint256 campaignId => address treasurySnapshot) public campaignTreasury;

    error InvalidAddress();
    error InvalidAmount();
    error InvalidFundingGoal();
    error InvalidMinimumContribution();
    error InvalidDuration();
    error InvalidToken();
    error CampaignNotFound();
    error CampaignNotActive();
    error CampaignExpired();
    error CampaignNotExpired();
    error CampaignGoalReached();
    error CampaignNotSuccessful();
    error CampaignAlreadyClaimed();
    error NothingToRefund();
    error ContributionTooSmall();
    error ContributionExceedsRemaining();
    error NotCampaignCreator();
    error FeeTooHigh();

    event CampaignCreated(
        uint256 indexed campaignId,
        address indexed creator,
        address indexed token,
        uint256 fundingGoal,
        uint256 deadline
    );
    event ContributionReceived(
        uint256 indexed campaignId,
        address indexed contributor,
        uint256 amount,
        uint256 totalRaised
    );
    event CampaignSuccessful(uint256 indexed campaignId, uint256 totalRaised);
    event FundsClaimed(
        uint256 indexed campaignId,
        address indexed creator,
        uint256 netAmount,
        uint256 feeAmount
    );
    event RefundClaimed(uint256 indexed campaignId, address indexed contributor, uint256 amount);
    event CampaignCancelled(uint256 indexed campaignId, address indexed creator);
    event FeeConfigUpdated(
        address indexed oldTreasury,
        address indexed newTreasury,
        uint16 oldFeeBps,
        uint16 newFeeBps
    );

    constructor(address initialTreasury, uint16 initialFeeBps) Ownable(msg.sender) {
        _validateFeeConfig(initialTreasury, initialFeeBps);
        treasury = initialTreasury;
        feeBps = initialFeeBps;
    }

    function createCampaign(
        IERC20 token,
        uint256 fundingGoal,
        uint256 minimumContribution,
        uint256 duration
    ) external returns (uint256 campaignId) {
        if (address(token) == address(0)) revert InvalidAddress();
        if (address(token).code.length == 0) revert InvalidToken();
        if (fundingGoal == 0) revert InvalidFundingGoal();
        if (minimumContribution == 0 || minimumContribution > fundingGoal) {
            revert InvalidMinimumContribution();
        }
        if (duration == 0) revert InvalidDuration();

        campaignId = nextCampaignId++;
        uint256 deadline = block.timestamp + duration;
        campaigns[campaignId] = Campaign({
            campaignId: campaignId,
            creator: msg.sender,
            token: token,
            fundingGoal: fundingGoal,
            totalRaised: 0,
            minimumContribution: minimumContribution,
            deadline: deadline,
            claimed: false,
            cancelled: false,
            createdAt: block.timestamp
        });
        campaignFeeBps[campaignId] = feeBps;
        campaignTreasury[campaignId] = treasury;

        emit CampaignCreated(campaignId, msg.sender, address(token), fundingGoal, deadline);
    }

    function contribute(uint256 campaignId, uint256 amount) external nonReentrant {
        Campaign storage campaign = _campaign(campaignId);
        if (campaign.cancelled) revert CampaignNotActive();
        if (block.timestamp >= campaign.deadline) revert CampaignExpired();
        if (campaign.totalRaised >= campaign.fundingGoal) revert CampaignGoalReached();
        if (amount == 0) revert InvalidAmount();
        if (amount < campaign.minimumContribution) revert ContributionTooSmall();

        uint256 remaining = campaign.fundingGoal - campaign.totalRaised;
        if (amount > remaining) revert ContributionExceedsRemaining();

        campaign.totalRaised += amount;
        contributions[campaignId][msg.sender] += amount;
        if (!contributorListed[campaignId][msg.sender]) {
            contributorListed[campaignId][msg.sender] = true;
            campaignContributors[campaignId].push(msg.sender);
        }

        campaign.token.safeTransferFrom(msg.sender, address(this), amount);
        emit ContributionReceived(campaignId, msg.sender, amount, campaign.totalRaised);

        if (campaign.totalRaised == campaign.fundingGoal) {
            emit CampaignSuccessful(campaignId, campaign.totalRaised);
        }
    }

    function claimFunds(uint256 campaignId) external nonReentrant {
        Campaign storage campaign = _campaign(campaignId);
        if (msg.sender != campaign.creator) revert NotCampaignCreator();
        if (campaign.cancelled) revert CampaignNotActive();
        if (campaign.totalRaised < campaign.fundingGoal) revert CampaignNotSuccessful();
        if (campaign.claimed) revert CampaignAlreadyClaimed();

        campaign.claimed = true;
        uint256 grossAmount = campaign.totalRaised;
        uint256 feeAmount = (grossAmount * campaignFeeBps[campaignId]) / BASIS_POINTS;
        uint256 netAmount = grossAmount - feeAmount;

        if (feeAmount > 0) campaign.token.safeTransfer(campaignTreasury[campaignId], feeAmount);
        campaign.token.safeTransfer(campaign.creator, netAmount);
        emit FundsClaimed(campaignId, campaign.creator, netAmount, feeAmount);
    }

    function claimRefund(uint256 campaignId) external nonReentrant {
        Campaign storage campaign = _campaign(campaignId);
        if (campaign.cancelled == false && block.timestamp < campaign.deadline) {
            revert CampaignNotExpired();
        }
        if (campaign.totalRaised >= campaign.fundingGoal) revert CampaignNotSuccessful();

        uint256 amount = contributions[campaignId][msg.sender];
        if (amount == 0) revert NothingToRefund();

        contributions[campaignId][msg.sender] = 0;
        campaign.token.safeTransfer(msg.sender, amount);
        emit RefundClaimed(campaignId, msg.sender, amount);
    }

    function cancelCampaign(uint256 campaignId) external nonReentrant {
        Campaign storage campaign = _campaign(campaignId);
        if (msg.sender != campaign.creator) revert NotCampaignCreator();
        if (campaign.cancelled) revert CampaignNotActive();
        if (block.timestamp >= campaign.deadline) revert CampaignExpired();
        if (campaign.totalRaised >= campaign.fundingGoal) revert CampaignGoalReached();

        campaign.cancelled = true;
        emit CampaignCancelled(campaignId, msg.sender);
    }

    function setFeeConfig(address newTreasury, uint16 newFeeBps) external onlyOwner {
        _validateFeeConfig(newTreasury, newFeeBps);
        address oldTreasury = treasury;
        uint16 oldFeeBps = feeBps;
        treasury = newTreasury;
        feeBps = newFeeBps;
        emit FeeConfigUpdated(oldTreasury, newTreasury, oldFeeBps, newFeeBps);
    }

    function getCampaign(uint256 campaignId) external view returns (Campaign memory) {
        return _campaign(campaignId);
    }

    function getContribution(uint256 campaignId, address contributor) external view returns (uint256) {
        _campaign(campaignId);
        return contributions[campaignId][contributor];
    }

    function getContributors(uint256 campaignId) external view returns (address[] memory) {
        _campaign(campaignId);
        return campaignContributors[campaignId];
    }

    function getRemainingFunding(uint256 campaignId) external view returns (uint256) {
        Campaign storage campaign = _campaign(campaignId);
        if (campaign.totalRaised >= campaign.fundingGoal) return 0;
        return campaign.fundingGoal - campaign.totalRaised;
    }

    function isSuccessful(uint256 campaignId) external view returns (bool) {
        Campaign storage campaign = _campaign(campaignId);
        return campaign.totalRaised >= campaign.fundingGoal;
    }

    function isExpired(uint256 campaignId) external view returns (bool) {
        Campaign storage campaign = _campaign(campaignId);
        return block.timestamp >= campaign.deadline;
    }

    function _campaign(uint256 campaignId) internal view returns (Campaign storage campaign) {
        campaign = campaigns[campaignId];
        if (campaign.creator == address(0)) revert CampaignNotFound();
    }

    function _validateFeeConfig(address proposedTreasury, uint16 proposedFeeBps) internal pure {
        if (proposedTreasury == address(0)) revert InvalidAddress();
        if (proposedFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
    }
}