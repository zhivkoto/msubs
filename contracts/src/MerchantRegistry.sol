// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.28;

import { Merchant, Plan, SubscriptionLib } from "./libraries/SubscriptionLib.sol";
import { IMerchantRegistry } from "./interfaces/IMerchantRegistry.sol";

/// @title MerchantRegistry
/// @notice Permissionless merchant onboarding and immutable plan registration.
/// @dev Plans are immutable once registered. To change pricing, register a new plan
///      and deprecate the old one. This contract is the on-chain source of truth
///      for plan terms consumed by SubscriptionModule at subscribe() time.
///
///      Authority model:
///      - The caller of `registerMerchant` becomes the "authority" for that merchant.
///      - The authority may differ from the `receiver` (e.g., a multisig receiver
///        while an EOA is the operational authority for plan management).
///      - Only the authority may call `registerPlan` and `deprecatePlan`.
///      - Only the `feeAdmin` may call `setFeeTier`.
contract MerchantRegistry is IMerchantRegistry {

    // ─── Constants ────────────────────────────────────────────────────────────

    /// @notice Maximum fee tier in basis points (300 = 3%).
    uint16 public constant MAX_FEE_TIER = 300;

    /// @notice Maximum plan name length in bytes.
    uint256 public constant MAX_NAME_LENGTH = 64;

    // ─── Storage ──────────────────────────────────────────────────────────────

    /// @notice merchantId → Merchant config.
    mapping(bytes32 => Merchant) private _merchants;

    /// @notice merchantId → authority address (can register/deprecate plans).
    mapping(bytes32 => address) private _merchantAuthority;

    /// @notice authority address → merchantId (for plan registration lookups).
    mapping(address => bytes32) private _authorityToMerchantId;

    /// @notice planId → Plan config.
    mapping(bytes32 => Plan) private _plans;

    /// @notice receiver address → merchantId (for duplicate prevention).
    mapping(address => bytes32) private _receiverToMerchantId;

    /// @notice Governance address allowed to set fee tiers.
    address public immutable feeAdmin;

    // ─── Errors ───────────────────────────────────────────────────────────────

    error MerchantAlreadyRegistered(address receiver);
    error PlanAlreadyRegistered(bytes32 planId);
    error AuthorityAlreadyHasMerchant(address authority);
    error NotMerchantAuthority();
    error NotFeeAdmin();

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @param _feeAdmin  Address permitted to set protocol fee tiers.
    ///                   Pass address(0) to disable fee tier management.
    constructor(address _feeAdmin) {
        feeAdmin = _feeAdmin;
    }

    // ─── Merchant Management ──────────────────────────────────────────────────

    /// @inheritdoc IMerchantRegistry
    function registerMerchant(
        address receiver,
        string calldata webhookUrl
    ) external returns (bytes32 merchantId) {
        if (receiver == address(0)) revert SubscriptionLib.InvalidMerchantReceiver();
        if (_receiverToMerchantId[receiver] != bytes32(0)) {
            revert MerchantAlreadyRegistered(receiver);
        }
        if (_authorityToMerchantId[msg.sender] != bytes32(0)) {
            revert AuthorityAlreadyHasMerchant(msg.sender);
        }

        merchantId = keccak256(abi.encode(receiver));

        _merchants[merchantId] = Merchant({
            merchantId:  merchantId,
            receiver:    receiver,
            feeTier:     0,
            webhookUrl:  webhookUrl,
            active:      true
        });
        _merchantAuthority[merchantId]         = msg.sender;
        _authorityToMerchantId[msg.sender]     = merchantId;
        _receiverToMerchantId[receiver]        = merchantId;

        emit MerchantRegistered(merchantId, receiver, msg.sender);
    }

    // ─── Fee Tier Management ──────────────────────────────────────────────────

    /// @notice Set the protocol fee tier for a merchant. Admin only.
    /// @dev Fee is applied to future renewals; does not affect in-flight charges.
    ///      Cap is enforced at MAX_FEE_TIER (300 bps = 3%).
    /// @param merchantId  Target merchant.
    /// @param feeTier     New fee in basis points (0–300).
    function setFeeTier(bytes32 merchantId, uint16 feeTier) external {
        if (msg.sender != feeAdmin) revert NotFeeAdmin();
        if (feeTier > MAX_FEE_TIER) revert SubscriptionLib.InvalidFeeTier(feeTier, MAX_FEE_TIER);
        Merchant storage m = _merchants[merchantId];
        if (m.merchantId == bytes32(0)) revert SubscriptionLib.MerchantNotFound(merchantId);
        m.feeTier = feeTier;
        emit MerchantFeeTierUpdated(merchantId, feeTier);
    }

    // ─── Plan Management ──────────────────────────────────────────────────────

    /// @inheritdoc IMerchantRegistry
    function registerPlan(
        address token,
        uint256 amount,
        uint32  period,
        string  calldata name
    ) external returns (bytes32 planId) {
        if (token == address(0))  revert SubscriptionLib.InvalidToken();
        if (amount == 0)          revert SubscriptionLib.InvalidAmount();
        if (period == 0)          revert SubscriptionLib.InvalidPeriod();
        if (bytes(name).length == 0 || bytes(name).length > MAX_NAME_LENGTH) {
            revert SubscriptionLib.InvalidPlanName();
        }

        bytes32 mId = _authorityToMerchantId[msg.sender];
        if (mId == bytes32(0)) revert NotMerchantAuthority();

        Merchant storage merchant = _merchants[mId];
        if (!merchant.active) revert SubscriptionLib.MerchantInactive(mId);

        // planId = keccak256(authority address, plan name) — globally unique per merchant+name
        planId = keccak256(abi.encode(msg.sender, name));

        if (_plans[planId].planId != bytes32(0)) {
            revert PlanAlreadyRegistered(planId);
        }

        _plans[planId] = Plan({
            planId:   planId,
            merchant: merchant.receiver, // authoritative receiver
            token:    token,
            amount:   amount,
            period:   period,
            name:     name,
            active:   true
        });

        emit PlanRegistered(planId, merchant.receiver, token, amount, period);
    }

    /// @inheritdoc IMerchantRegistry
    function deprecatePlan(bytes32 planId) external {
        Plan storage plan = _plans[planId];
        if (plan.planId == bytes32(0)) revert SubscriptionLib.PlanNotFound(planId);

        // Resolve authority from plan's merchant (receiver)
        bytes32 mId = _receiverToMerchantId[plan.merchant];
        if (_merchantAuthority[mId] != msg.sender) {
            revert SubscriptionLib.UnauthorizedCaller(msg.sender, _merchantAuthority[mId]);
        }

        plan.active = false;
        emit PlanDeprecated(planId);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    /// @inheritdoc IMerchantRegistry
    function getMerchant(bytes32 merchantId) external view returns (Merchant memory) {
        return _merchants[merchantId];
    }

    /// @inheritdoc IMerchantRegistry
    function getPlan(bytes32 planId) external view returns (Plan memory) {
        return _plans[planId];
    }

    /// @inheritdoc IMerchantRegistry
    function isMerchantAuthority(bytes32 merchantId, address caller) external view returns (bool) {
        return _merchantAuthority[merchantId] == caller;
    }

    /// @notice Resolve merchantId from a receiver address.
    /// @param receiver  Receiver address.
    /// @return          merchantId (bytes32(0) if not registered).
    function getMerchantIdByReceiver(address receiver) external view returns (bytes32) {
        return _receiverToMerchantId[receiver];
    }

    /// @notice Resolve merchantId for a given authority address.
    /// @param authority  Authority address.
    /// @return           merchantId (bytes32(0) if not registered).
    function getMerchantIdByAuthority(address authority) external view returns (bytes32) {
        return _authorityToMerchantId[authority];
    }
}
