// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.28;

// ─── Enums ────────────────────────────────────────────────────────────────────

/// @notice Status of a subscription permission.
enum SubscriptionStatus {
    Active,       // 0 — Charging on schedule
    Paused,       // 1 — User-initiated pause; no charge attempts
    Cancelled,    // 2 — Permanently cancelled; session key invalidated
    Expired,      // 3 — Hard expiry reached or max retries exceeded
    GracePeriod   // 4 — Charge failed; within merchant-configured grace window
}

// ─── Structs ──────────────────────────────────────────────────────────────────

/// @notice Core authorization record. One instance per (user, merchant, plan) tuple.
/// @dev Stored within the SubscriptionModule or SubscriptionDelegate.
struct SubscriptionPermission {
    /// @dev ERC-20 token address (e.g., USDC at 6 decimals).
    address token;
    /// @dev Merchant's receiving address. Immutable after creation.
    address merchant;
    /// @dev Maximum token amount chargeable per period (in token base units).
    uint256 maxAmount;
    /// @dev Minimum seconds between successive charges. Enforced on-chain.
    uint32 periodSeconds;
    /// @dev Timestamp when the subscription became active.
    uint48 startTime;
    /// @dev Timestamp of the last successful charge. 0 if never charged.
    uint48 lastChargedAt;
    /// @dev Hard expiration timestamp. After this point, all renewal attempts MUST revert.
    ///      0 = no hard expiry.
    uint48 expiresAt;
    /// @dev Current lifecycle status.
    SubscriptionStatus status;
    /// @dev Merchant-defined plan identifier.
    bytes32 planId;
    /// @dev Address corresponding to the session key authorized to trigger renewals.
    address sessionKey;
}

/// @notice A merchant-defined billing plan. Registered in MerchantRegistry.
struct Plan {
    /// @dev Unique plan identifier (keccak256 of merchant address + plan name).
    bytes32 planId;
    /// @dev Merchant address owning this plan.
    address merchant;
    /// @dev ERC-20 token for billing.
    address token;
    /// @dev Exact charge amount per period (in token base units).
    uint256 amount;
    /// @dev Billing interval in seconds (e.g., 2592000 = 30 days).
    uint32 period;
    /// @dev Human-readable plan name for wallet display (max 64 bytes).
    string name;
    /// @dev Whether this plan is accepting new subscribers.
    bool active;
}

/// @notice Merchant configuration. Registered in MerchantRegistry.
struct Merchant {
    /// @dev Unique merchant identifier (keccak256 of receiver address).
    bytes32 merchantId;
    /// @dev Address that receives net subscription payments (after protocol fee).
    address receiver;
    /// @dev Protocol fee in basis points charged on each renewal (e.g., 150 = 1.5%).
    uint16 feeTier;
    /// @dev Off-chain webhook URL for payment event delivery.
    string webhookUrl;
    /// @dev Whether this merchant account is active.
    bool active;
}

// ─── Library ──────────────────────────────────────────────────────────────────

/// @title SubscriptionLib
/// @notice Shared EIP-712 hashing utilities, subscription ID derivation, and
///         common error definitions for the MIP Subscription Permissions Standard.
library SubscriptionLib {

    // ─── EIP-712 Constants ────────────────────────────────────────────────────

    bytes32 internal constant DOMAIN_TYPE_HASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    bytes32 internal constant SUBSCRIPTION_PERMISSION_TYPE_HASH = keccak256(
        "SubscriptionPermission("
            "address token,"
            "address merchant,"
            "uint256 maxAmount,"
            "uint32 periodSeconds,"
            "uint48 startTime,"
            "uint48 expiresAt,"
            "bytes32 planId,"
            "address sessionKey,"
            "uint256 nonce"
        ")"
    );

    bytes32 internal constant DOMAIN_NAME_HASH    = keccak256("SubscriptionPermissions");
    bytes32 internal constant DOMAIN_VERSION_HASH = keccak256("1");

    // ─── ID Derivation ────────────────────────────────────────────────────────

    /// @notice Derive a deterministic subscription ID.
    /// @param user       Smart account or EOA address.
    /// @param merchant   Merchant receiving address.
    /// @param planId     Plan identifier.
    /// @param nonce      Per-account subscription nonce to allow re-subscription.
    /// @return id        keccak256 subscription identifier.
    function deriveSubscriptionId(
        address user,
        address merchant,
        bytes32 planId,
        uint256 nonce
    ) internal pure returns (bytes32 id) {
        id = keccak256(abi.encode(user, merchant, planId, nonce));
    }

    // ─── EIP-712 Helpers ──────────────────────────────────────────────────────

    /// @notice Compute the EIP-712 domain separator for a given verifying contract.
    /// @param verifyingContract  Address of the contract holding the domain.
    /// @return separator         Domain separator bytes32.
    function domainSeparator(address verifyingContract) internal view returns (bytes32 separator) {
        separator = keccak256(abi.encode(
            DOMAIN_TYPE_HASH,
            DOMAIN_NAME_HASH,
            DOMAIN_VERSION_HASH,
            block.chainid,
            verifyingContract
        ));
    }

    /// @notice Hash a SubscriptionPermission for EIP-712 signing.
    /// @param p      Permission struct to hash.
    /// @param nonce  Nonce used during subscription creation.
    /// @return hash  Struct hash (inner, without domain prefix).
    function hashPermission(
        SubscriptionPermission memory p,
        uint256 nonce
    ) internal pure returns (bytes32 hash) {
        hash = keccak256(abi.encode(
            SUBSCRIPTION_PERMISSION_TYPE_HASH,
            p.token,
            p.merchant,
            p.maxAmount,
            p.periodSeconds,
            p.startTime,
            p.expiresAt,
            p.planId,
            p.sessionKey,
            nonce
        ));
    }

    /// @notice Produce the EIP-712 signed digest (domain + struct hash).
    /// @param domainSep  Domain separator computed for the verifying contract.
    /// @param structHash Inner hash from `hashPermission`.
    /// @return digest    The bytes32 that should be signed.
    function toTypedDataHash(bytes32 domainSep, bytes32 structHash) internal pure returns (bytes32 digest) {
        digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
    }

    // ─── Signature Recovery ───────────────────────────────────────────────────

    /// @notice Recover the signer from an EIP-712 digest + compact signature.
    /// @param digest     EIP-712 typed-data hash.
    /// @param signature  Compact 65-byte ECDSA signature (r, s, v).
    /// @return signer    Recovered address (address(0) on invalid sig).
    function recoverSigner(bytes32 digest, bytes memory signature) internal pure returns (address signer) {
        if (signature.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8   v;
        assembly ("memory-safe") {
            // signature memory layout: [length (32)] [r (32)] [s (32)] [v (1)...]
            let ptr := add(signature, 32)
            r := mload(ptr)
            s := mload(add(ptr, 32))
            v := byte(0, mload(add(ptr, 64)))
        }
        if (v < 27) v += 27;
        if (v != 27 && v != 28) return address(0);
        signer = ecrecover(digest, v, r, s);
    }

    // ─── Custom Errors ────────────────────────────────────────────────────────

    error SubscriptionNotFound(bytes32 subscriptionId);
    error SubscriptionAlreadyActive(bytes32 subscriptionId);
    error SubscriptionTerminal(bytes32 subscriptionId);
    error SubscriptionNotActive(bytes32 subscriptionId);
    error SubscriptionNotPaused(bytes32 subscriptionId);
    error SubscriptionExpired(bytes32 subscriptionId);
    error PeriodNotElapsed(bytes32 subscriptionId, uint48 nextChargeAt, uint48 now_);
    error AmountExceedsCap(bytes32 subscriptionId, uint256 attempted, uint256 cap);
    error InvalidSessionKey(bytes32 subscriptionId, address provided, address expected);
    error UnauthorizedCaller(address caller, address expected);
    error PlanNotFound(bytes32 planId);
    error PlanInactive(bytes32 planId);
    error PlanMerchantMismatch(bytes32 planId, address expected, address got);
    error MerchantNotFound(bytes32 merchantId);
    error MerchantInactive(bytes32 merchantId);
    error InvalidFeeTier(uint16 feeTier, uint16 max);
    error InvalidSessionKeyAddress();
    error InvalidMerchantReceiver();
    error InvalidPeriod();
    error InvalidAmount();
    error InvalidToken();
    error ZeroAddress();
    error InvalidPlanName();
}
