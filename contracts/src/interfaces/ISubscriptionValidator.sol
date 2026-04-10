// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.28;

/// @title ISubscriptionValidator
/// @notice Validation hook for renewal UserOperations.
/// @dev This interface is called by the smart account's validateUserOp path.
///      Implementations MUST enforce all of the following before returning success:
///      1. The UserOp is signed by the session key registered for subscriptionId.
///      2. block.timestamp >= permission.lastChargedAt + permission.periodSeconds.
///      3. permission.status == SubscriptionStatus.Active.
///      4. The charge amount equals the plan amount (not merely <= maxAmount).
///      5. If permission.expiresAt != 0: block.timestamp < permission.expiresAt.
interface ISubscriptionValidator {

    /// @notice Validate a renewal UserOperation.
    /// @dev Returns SIG_VALIDATION_SUCCESS (0) or SIG_VALIDATION_FAILED (1)
    ///      following ERC-4337 convention.
    ///      MUST revert with a descriptive error rather than returning failed
    ///      when the subscription is in a terminal state (Cancelled, Expired).
    /// @param subscriptionId  Subscription being renewed.
    /// @param userOpHash      ERC-4337 UserOperation hash.
    /// @param signature       Signature bytes from the UserOperation.
    /// @return validationData Packed ERC-4337 validation result.
    function validateRenewal(
        bytes32 subscriptionId,
        bytes32 userOpHash,
        bytes   calldata signature
    ) external view returns (uint256 validationData);
}
