// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.28;

import { IPaymaster } from "account-abstraction/interfaces/IPaymaster.sol";

/// @title ISubscriptionPaymaster
/// @notice ERC-4337 Verifying Paymaster for subscription-related UserOperations.
/// @dev Extends IPaymaster with subscription-specific funding and rate-limiting
///      management functions. Implementations MUST restrict sponsorship to
///      UserOperations whose callData targets one of:
///      subscribe(), cancel(), pause(), resume(), update(), or processRenewal().
///      Any UserOperation targeting other calldata MUST be rejected.
interface ISubscriptionPaymaster is IPaymaster {

    // ─── Events ───────────────────────────────────────────────────────────────

    /// @notice Emitted when the paymaster sponsors a UserOperation.
    /// @param subscriptionId  Subscription involved (bytes32(0) for setup ops).
    /// @param sender          UserOp sender address.
    /// @param maxCost         Maximum gas cost approved.
    event PaymasterApproved(
        bytes32 indexed subscriptionId,
        address indexed sender,
        uint256         maxCost
    );

    /// @notice Emitted when a gas budget is updated.
    /// @param user       Address whose budget was updated.
    /// @param newBudget  Remaining daily budget in wei.
    event GasBudgetUpdated(address indexed user, uint256 newBudget);

    // ─── Funding ──────────────────────────────────────────────────────────────

    /// @notice Deposit ETH to fund gas sponsorship.
    function deposit() external payable;

    /// @notice Withdraw ETH from the paymaster balance.
    /// @dev Only callable by the paymaster owner/treasury.
    /// @param amount  Amount to withdraw in wei.
    /// @param to      Recipient address.
    function withdraw(uint256 amount, address payable to) external;

    /// @notice Check remaining gas sponsorship balance.
    /// @return  Balance in wei held by this paymaster in the EntryPoint.
    function balance() external view returns (uint256);

    // ─── Rate Limiting ────────────────────────────────────────────────────────

    /// @notice Get the remaining daily gas budget for a user.
    /// @param user  User address to check.
    /// @return      Remaining budget in wei for the current day window.
    function remainingBudget(address user) external view returns (uint256);

    /// @notice Set the daily gas budget per user.
    /// @dev Only callable by the paymaster owner.
    /// @param budgetWei  Budget in wei per user per day.
    function setDailyBudget(uint256 budgetWei) external;
}
