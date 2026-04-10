// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.28;

import { Merchant, Plan } from "../libraries/SubscriptionLib.sol";

/// @title IMerchantRegistry
/// @notice Merchant onboarding and plan management.
/// @dev Plans registered here are the on-chain source of truth for subscription
///      terms. Wallets and modules MUST validate that the planId presented at
///      subscribe() time exists and is active in this registry.
interface IMerchantRegistry {

    // ─── Events ───────────────────────────────────────────────────────────────

    /// @notice Emitted when a new merchant is registered.
    /// @param merchantId  keccak256(receiver).
    /// @param receiver    Merchant receiving address.
    /// @param authority   Address authorized to manage this merchant's plans.
    event MerchantRegistered(
        bytes32 indexed merchantId,
        address indexed receiver,
        address indexed authority
    );

    /// @notice Emitted when a new plan is registered.
    /// @param planId     keccak256(merchantAddress, name).
    /// @param merchant   Merchant address.
    /// @param token      Billing token.
    /// @param amount     Charge amount per period.
    /// @param period     Billing interval in seconds.
    event PlanRegistered(
        bytes32 indexed planId,
        address indexed merchant,
        address         token,
        uint256         amount,
        uint32          period
    );

    /// @notice Emitted when a plan is deprecated.
    /// @param planId  Deprecated plan identifier.
    event PlanDeprecated(bytes32 indexed planId);

    /// @notice Emitted when the protocol fee tier for a merchant is updated.
    /// @param merchantId  Merchant identifier.
    /// @param feeTier     New fee tier in basis points.
    event MerchantFeeTierUpdated(bytes32 indexed merchantId, uint16 feeTier);

    // ─── Merchant Management ──────────────────────────────────────────────────

    /// @notice Register a new merchant.
    /// @dev Caller becomes the merchant authority (can register/deprecate plans).
    ///      Emits MerchantRegistered.
    /// @param receiver    Address to receive net subscription payments.
    /// @param webhookUrl  Off-chain webhook endpoint (stored for transparency).
    /// @return merchantId keccak256(receiver).
    function registerMerchant(
        address receiver,
        string calldata webhookUrl
    ) external returns (bytes32 merchantId);

    // ─── Fee Tier Management ──────────────────────────────────────────────────

    /// @notice Set the protocol fee tier for a merchant. Only callable by the fee admin.
    /// @param merchantId  Target merchant identifier.
    /// @param feeTier     New fee in basis points (0–300).
    function setFeeTier(bytes32 merchantId, uint16 feeTier) external;

    // ─── Plan Management ──────────────────────────────────────────────────────

    /// @notice Register a billing plan under the calling merchant.
    /// @dev Emits PlanRegistered.
    ///      Plan amount and period are immutable after registration.
    ///      To change pricing, register a new plan and deprecate the old one.
    /// @param token    ERC-20 token for billing.
    /// @param amount   Charge amount per period (in token base units).
    /// @param period   Billing interval in seconds.
    /// @param name     Human-readable plan name (max 64 bytes).
    /// @return planId  keccak256(merchantAddress, name).
    function registerPlan(
        address token,
        uint256 amount,
        uint32  period,
        string  calldata name
    ) external returns (bytes32 planId);

    /// @notice Deprecate a plan. Existing subscribers are not affected.
    /// @dev Emits PlanDeprecated. New subscriptions to this planId MUST revert.
    /// @param planId  Plan to deprecate.
    function deprecatePlan(bytes32 planId) external;

    // ─── Views ────────────────────────────────────────────────────────────────

    /// @notice Fetch merchant configuration.
    /// @param merchantId  Merchant identifier.
    /// @return            The Merchant struct.
    function getMerchant(bytes32 merchantId)
        external
        view
        returns (Merchant memory);

    /// @notice Fetch plan configuration.
    /// @param planId  Plan identifier.
    /// @return        The Plan struct.
    function getPlan(bytes32 planId)
        external
        view
        returns (Plan memory);

    /// @notice Check whether a caller is the authority for a given merchant.
    /// @param merchantId  Merchant to check.
    /// @param caller      Address to verify.
    /// @return            True if caller is the registered authority.
    function isMerchantAuthority(bytes32 merchantId, address caller)
        external
        view
        returns (bool);
}
