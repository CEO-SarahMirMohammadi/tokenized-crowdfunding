# Tokenized Crowdfunding

## Overview

Tokenized Crowdfunding is a Solidity-first decentralized fundraising protocol. Creators publish time-limited campaigns denominated in an ERC-20 token, contributors fund them directly on-chain, and the contract settles successful and unsuccessful campaigns according to deterministic rules.

## Problem

Traditional crowdfunding platforms custody user funds and apply platform-specific payout and refund rules. Those arrangements can make settlement opaque and leave contributors dependent on a central operator.

## Solution

Campaign state, contributions, deadlines, platform fees, and settlement are enforced by Solidity contracts. Funds are held in the crowdfunding contract until the campaign either reaches its goal or becomes refundable. ERC-20 transfers use OpenZeppelin `SafeERC20`.

## Architecture

- `CampaignToken` is a six-decimal ERC-20 for local development and demonstrations. Its owner can mint tokens; an owner-controlled faucet can be enabled for bounded test distributions.
- `Crowdfunding` creates campaigns for deployed ERC-20 tokens, records contributor balances, and handles successful payouts, failed-campaign refunds, and cancellation refunds.
- OpenZeppelin `Ownable` restricts token minting and platform-fee configuration. `ReentrancyGuard` and checks-effects-interactions protect token-moving operations.
- Every campaign snapshots the fee rate and treasury in effect when it is created, so a later global fee update does not change that campaign's economics or fee recipient.

## Campaign Lifecycle

1. A creator selects an ERC-20 token, funding goal, minimum contribution, and duration.
2. Contributors approve the crowdfunding contract and deposit at least the campaign minimum per contribution. Deposits cannot exceed the remaining amount needed to reach the goal.
3. Reaching the goal marks the campaign successful immediately. The creator may claim the funds once.
4. If the deadline passes below the goal, contributors may reclaim their deposits. The creator may also cancel an unsuccessful campaign before its deadline, making it refundable immediately.

## Funding Flow

Contributors call `approve` on the campaign token, then call `contribute`. The crowdfunding contract updates the contribution and raised totals and pulls the tokens with `safeTransferFrom`. The campaign records each contributor once in its contributor list, while repeated deposits accumulate in that contributor's balance.

## Successful Campaign

When `totalRaised` equals `fundingGoal`, the contract emits `CampaignSuccessful` and rejects further deposits. The creator calls `claimFunds`; the contract marks the campaign claimed, sends the snapshotted fee to the treasury, and transfers the remainder to the creator.

## Failed Campaign

A campaign that reaches its deadline below its goal is unsuccessful. Its contributors may withdraw their recorded deposits. No platform fee is charged on refunds, and campaign contributions are zeroed before tokens are transferred back.

## Refund Mechanism

Refunds are available only after an unsuccessful campaign expires or after its creator cancels it. Each contributor's stored balance is cleared before transfer, preventing double refunds. A successful campaign cannot be refunded through this mechanism.

## Platform Fee

The contract owner configures the treasury and fee together through `setFeeConfig`. Fees are expressed in basis points, capped at 1,000 bps (10%), and the fee rate and treasury are snapshotted when each campaign is created. A zero fee is valid. Successful campaign claims split the gross raised amount between the snapshotted treasury and creator; integer division rounds any fractional token unit down for the fee.

## Smart Contracts

### `CampaignToken.sol`

An OpenZeppelin ERC-20 named Campaign Token (`CAMP`) with six decimals. The owner can mint tokens and enable or disable the testing faucet. The faucet caps both each request and cumulative faucet mints per wallet.

### `Crowdfunding.sol`

The campaign registry and settlement engine. It exposes campaign creation, contributions, creator claims, contributor refunds, creator cancellation, fee configuration, campaign details, contribution details, remaining funding, and success/expiry queries.

## Security

- Solidity 0.8.24 checked arithmetic and custom errors for invalid states and inputs.
- OpenZeppelin `SafeERC20`, `Ownable`, and `ReentrancyGuard`.
- State changes precede outbound token transfers in claim and refund paths; failed external transfers revert the transaction.
- Goal caps, deadline checks, creator authorization, fee validation, one-time claims, and zeroed refund balances.
- Campaign fee and treasury snapshots prevent later owner configuration changes from retroactively affecting existing campaigns.

This project is an educational portfolio implementation, not audited software. It assumes campaign tokens are conventional ERC-20s; fee-on-transfer or rebasing tokens may not behave as intended because contribution accounting uses the requested transfer amount. Review and audit contracts before any production use.

## Testing

The Hardhat test suite covers deployment, campaign creation, one and multiple contributors, minimum contributions, goal completion, creator settlement, fee distribution and snapshots, failed-campaign and cancellation refunds, deadline behavior, access control, configuration validation, and duplicate-claim protection.

## Installation

Requirements: Node.js 18 or newer and npm.

```bash
npm install
```

## Usage

Compile and run the local test suite:

```bash
npm run compile
npm test
```

Deploy both contracts to the local Hardhat network:

```bash
npm run deploy:local
```

For Sepolia, copy `.env.example` to `.env`, set `SEPOLIA_RPC_URL` and `PRIVATE_KEY`, optionally set `TREASURY_ADDRESS` and `PLATFORM_FEE_BPS`, then run:

```bash
npm run deploy:sepolia
```

The deployment account owns `CampaignToken` and `Crowdfunding`. It can mint test tokens, configure the faucet, and update the global fee configuration. For local campaigns, mint or faucet tokens to contributors, have them approve the deployed crowdfunding address, and then call `createCampaign` and `contribute`.

## Project Structure

```text
contracts/
  CampaignToken.sol
  Crowdfunding.sol
scripts/
  deploy.js
test/
  Crowdfunding.test.js
hardhat.config.js
package.json
.env.example
.gitignore
requirements.txt
README.md
LICENSE
```

## Design Decisions

- Campaigns accept one ERC-20 each, avoiding implicit price conversion or custody across multiple assets.
- Contributions are capped at the outstanding goal amount; overfunding is rejected instead of creating ambiguous refund shares.
- Creator cancellation is limited to an unsuccessful campaign before its deadline. A campaign at goal cannot be cancelled.
- A contributor's minimum applies to each deposit, while balances accumulate across deposits.
- The global fee rate and treasury are snapshotted per campaign, keeping settlement terms stable after launch.

## Future Improvements

- Add optional allowlists, milestone-based releases, and campaign metadata references.
- Support permit-based approvals and carefully designed fee-on-transfer token accounting.
- Add an emergency response policy with explicit governance and contributor protections.
- Run independent audits and expand invariant and property-based testing before production use.

## Description

Built a Solidity 0.8.24 ERC-20 crowdfunding protocol with deadline-based campaign settlement, capped contributions, creator cancellation, pull-based refunds, configurable basis-point fees, and per-campaign fee snapshots; tested access control and reentrancy-safe payout flows with Hardhat and OpenZeppelin.