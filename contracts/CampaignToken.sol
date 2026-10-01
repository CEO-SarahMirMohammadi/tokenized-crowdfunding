// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract CampaignToken is ERC20, Ownable {
    uint8 public constant TOKEN_DECIMALS = 6;
    uint256 public constant FAUCET_MAX_PER_CALL = 10_000 * 10 ** TOKEN_DECIMALS;
    uint256 public constant FAUCET_MAX_PER_WALLET = 100_000 * 10 ** TOKEN_DECIMALS;

    bool public faucetEnabled;
    mapping(address account => uint256 amount) public faucetMinted;

    error InvalidAddress();
    error InvalidAmount();
    error FaucetDisabled();
    error FaucetCallLimitExceeded();
    error FaucetWalletLimitExceeded();

    event TokensMinted(address indexed recipient, uint256 amount);
    event FaucetStatusUpdated(bool enabled);
    event FaucetMinted(address indexed recipient, uint256 amount);

    constructor(address initialOwner) ERC20("Campaign Token", "CAMP") Ownable(initialOwner) {
        if (initialOwner == address(0)) revert InvalidAddress();
    }

    function decimals() public pure override returns (uint8) {
        return TOKEN_DECIMALS;
    }

    function mint(address recipient, uint256 amount) external onlyOwner {
        if (recipient == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        _mint(recipient, amount);
        emit TokensMinted(recipient, amount);
    }

    function setFaucetEnabled(bool enabled) external onlyOwner {
        faucetEnabled = enabled;
        emit FaucetStatusUpdated(enabled);
    }

    function faucet(uint256 amount) external {
        if (!faucetEnabled) revert FaucetDisabled();
        if (amount == 0) revert InvalidAmount();
        if (amount > FAUCET_MAX_PER_CALL) revert FaucetCallLimitExceeded();
        if (faucetMinted[msg.sender] + amount > FAUCET_MAX_PER_WALLET) {
            revert FaucetWalletLimitExceeded();
        }

        faucetMinted[msg.sender] += amount;
        _mint(msg.sender, amount);
        emit FaucetMinted(msg.sender, amount);
    }
}