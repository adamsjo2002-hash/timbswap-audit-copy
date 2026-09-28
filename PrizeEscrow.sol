// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title PrizeEscrow
 * @notice Holds all prize ETH for the TimbSwap prize game.
 *         Pays winners exclusively on instruction from TimbPrize.
 *
 * Design:
 *   - Single responsibility: hold ETH, pay on authorised instruction.
 *   - Only TimbPrize can call pay(). No other address can move funds.
 *   - Owner and TimbTreasury can deposit ETH (seeding + fee routing).
 *   - Balance is always queryable — feeds the prize pot display.
 *   - No accounting logic — TimbPrize owns the accounting layer.
 *
 * Security:
 *   - ReentrancyGuard on pay() and emergencyWithdraw().
 *   - Only TimbPrize can instruct payouts.
 *   - Emergency withdrawal restricted to owner only.
 *   - ETH transfer uses call{value} with success check.
 *   - ETH only — no ERC-20 tokens.
 *
 * Deployment:
 *   1. Deploy PrizeEscrow()
 *   2. Deploy TimbPrize(prizeEscrow, ...)
 *   3. setTimbPrize(timbPrize)
 *   4. Fund via deposit() or direct ETH send
 *   5. Verify on Sourcify
 */
contract PrizeEscrow is Ownable, ReentrancyGuard {

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice TimbPrize — only address authorised to call pay().
    address public timbPrize;

    // ─── Events ──────────────────────────────────────────────────────────────

    event WinnerPaid(address indexed winner, uint256 amount, uint256 indexed round);
    event Deposited(address indexed from, uint256 amount);
    event TimbPrizeSet(address indexed timbPrize);
    event EmergencyWithdrawn(address indexed to, uint256 amount);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error NotTimbPrize();
    error InsufficientBalance(uint256 requested, uint256 available);
    error TransferFailed();

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor() Ownable(msg.sender) {}

    // ─── Payout ───────────────────────────────────────────────────────────────

    /**
     * @notice Pay a winner. Only callable by TimbPrize.
     * @param to     Winner address.
     * @param amount ETH amount in wei.
     * @param round  Round number for event indexing.
     */
    function pay(address to, uint256 amount, uint256 round)
        external
        nonReentrant
    {
        if (msg.sender != timbPrize)        revert NotTimbPrize();
        if (to == address(0))               revert ZeroAddress();
        if (amount == 0)                    revert ZeroAmount();
        if (amount > address(this).balance) {
            revert InsufficientBalance(amount, address(this).balance);
        }

        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit WinnerPaid(to, amount, round);
    }

    // ─── Deposit ──────────────────────────────────────────────────────────────

    /**
     * @notice Deposit ETH into the prize pool.
     * @dev Called by TimbTreasury, TimbPrize.fundPot(), or owner seeding.
     *      Also accepts direct ETH via receive().
     */
    function deposit() external payable {
        if (msg.value == 0) revert ZeroAmount();
        emit Deposited(msg.sender, msg.value);
    }

    // ─── Owner: Config ────────────────────────────────────────────────────────

    /**
     * @notice Set the TimbPrize address — only address that can call pay().
     */
    function setTimbPrize(address _timbPrize) external onlyOwner {
        if (_timbPrize == address(0)) revert ZeroAddress();
        timbPrize = _timbPrize;
        emit TimbPrizeSet(_timbPrize);
    }

    /**
     * @notice Emergency withdrawal — owner only. Last resort.
     */
    function emergencyWithdraw(address to, uint256 amount)
        external
        nonReentrant
        onlyOwner
    {
        if (to == address(0))               revert ZeroAddress();
        if (amount == 0)                    revert ZeroAmount();
        if (amount > address(this).balance) {
            revert InsufficientBalance(amount, address(this).balance);
        }
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit EmergencyWithdrawn(to, amount);
    }

    // ─── View ─────────────────────────────────────────────────────────────────

    /**
     * @notice Current ETH balance held in escrow.
     */
    function balance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @dev Accept ETH deposits directly.
    receive() external payable {
        if (msg.value > 0) emit Deposited(msg.sender, msg.value);
    }
}
