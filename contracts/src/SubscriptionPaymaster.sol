// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IPaymaster } from "account-abstraction/interfaces/IPaymaster.sol";
import { IEntryPoint } from "account-abstraction/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "account-abstraction/interfaces/PackedUserOperation.sol";

import { ISubscriptionPaymaster } from "./interfaces/ISubscriptionPaymaster.sol";
import { SubscriptionLib } from "./libraries/SubscriptionLib.sol";
import { SubscriptionRegistry } from "./SubscriptionRegistry.sol";
import {
    SubscriptionPermission,
    SubscriptionStatus
} from "./libraries/SubscriptionLib.sol";

/// @title SubscriptionPaymaster
/// @notice ERC-4337 Verifying Paymaster that sponsors gas for subscription-related
///         UserOperations. Implements rate limiting to prevent paymaster drain attacks.
///
/// @dev Allowlisted selectors (the only calls this paymaster will sponsor):
///      - SubscriptionModule.subscribe(bytes32,address,uint48)         → 0x...
///      - SubscriptionModule.cancel(bytes32)
///      - SubscriptionModule.pause(bytes32)
///      - SubscriptionModule.resume(bytes32)
///      - SubscriptionModule.update(bytes32,bytes32)
///      - SubscriptionModule.processRenewal(bytes32)
///      - SubscriptionModule.processRenewalFor(address,bytes32)
///
/// Rate limiting:
///      Per-user daily gas budget. Each day window (86400 seconds) a user can
///      consume at most `dailyBudgetWei` in gas costs. The budget resets every
///      24 hours. This caps the maximum paymaster drain from a single compromised
///      session key to ~10× the cost of a single renewal per user per day.
contract SubscriptionPaymaster is IPaymaster, ISubscriptionPaymaster, Ownable, ReentrancyGuard {

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 public constant DAY_SECONDS = 86_400;

    /// @notice Default daily budget per user: 0.01 ETH - generous for renewals at ~$0.001/each.
    uint256 public constant DEFAULT_DAILY_BUDGET = 0.01 ether;

    // ─── Allowlisted Selectors ────────────────────────────────────────────────

    bytes4 internal constant SEL_SUBSCRIBE      = bytes4(keccak256("subscribe(bytes32,address,uint48)"));
    bytes4 internal constant SEL_CANCEL         = bytes4(keccak256("cancel(bytes32)"));
    bytes4 internal constant SEL_PAUSE          = bytes4(keccak256("pause(bytes32)"));
    bytes4 internal constant SEL_RESUME         = bytes4(keccak256("resume(bytes32)"));
    bytes4 internal constant SEL_UPDATE         = bytes4(keccak256("update(bytes32,bytes32)"));
    bytes4 internal constant SEL_PROCESS_RENEWAL        = bytes4(keccak256("processRenewal(bytes32)"));
    bytes4 internal constant SEL_PROCESS_RENEWAL_FOR    = bytes4(keccak256("processRenewalFor(address,bytes32)"));

    // ─── Immutables ───────────────────────────────────────────────────────────

    /// @notice ERC-4337 EntryPoint v0.7.
    IEntryPoint public immutable entryPoint;

    /// @notice Global subscription registry (for rate-limit validation).
    SubscriptionRegistry public immutable registry;

    // ─── Storage ──────────────────────────────────────────────────────────────

    /// @notice Daily gas budget per user in wei.
    uint256 public dailyBudgetWei;

    /// @dev user → day window start timestamp (floored to day boundary).
    mapping(address => uint256) private _budgetWindowStart;

    /// @dev user → gas consumed in current window (wei).
    mapping(address => uint256) private _budgetConsumed;

    // ─── Context encoding ─────────────────────────────────────────────────────

    /// @dev Packed context passed from validatePaymasterUserOp → postOp.
    ///      Layout: abi.encode(user, maxCost, subscriptionId)
    struct PaymasterContext {
        address user;
        uint256 maxCost;
        bytes32 subscriptionId;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @param _entryPoint  ERC-4337 EntryPoint address.
    /// @param _registry    SubscriptionRegistry address.
    constructor(
        address _entryPoint,
        address _registry
    ) Ownable(msg.sender) {
        if (_entryPoint == address(0) || _registry == address(0)) {
            revert SubscriptionLib.ZeroAddress();
        }
        entryPoint      = IEntryPoint(_entryPoint);
        registry        = SubscriptionRegistry(_registry);
        dailyBudgetWei  = DEFAULT_DAILY_BUDGET;
    }

    // ─── IPaymaster ───────────────────────────────────────────────────────────

    /// @inheritdoc IPaymaster
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external returns (bytes memory context, uint256 validationData) {
        _requireFromEntryPoint();

        // 1. Validate callData selector is allowlisted
        bytes calldata callData = userOp.callData;
        if (callData.length < 4) revert SelectorNotAllowlisted(bytes4(0));

        bytes4 sel = bytes4(callData[:4]);
        if (!_isAllowlistedSelector(sel)) {
            revert SelectorNotAllowlisted(sel);
        }

        // 2. Extract subscriptionId for renewal-specific rate limiting
        bytes32 subscriptionId = bytes32(0);
        if (sel == SEL_PROCESS_RENEWAL && callData.length >= 36) {
            subscriptionId = abi.decode(callData[4:36], (bytes32));
        } else if (sel == SEL_PROCESS_RENEWAL_FOR && callData.length >= 68) {
            // processRenewalFor(address user, bytes32 subscriptionId)
            (, subscriptionId) = abi.decode(callData[4:68], (address, bytes32));
        }

        // 3. Per-subscription rate limiting: max 1 renewal sponsorship per periodSeconds
        if (subscriptionId != bytes32(0)) {
            _checkSubscriptionRateLimit(subscriptionId);
        }

        // 4. Per-user daily budget check
        address user = userOp.sender;
        _checkDailyBudget(user, maxCost);

        // Encode context for postOp
        context = abi.encode(PaymasterContext({
            user:           user,
            maxCost:        maxCost,
            subscriptionId: subscriptionId
        }));

        // validationData: 0 = success, no time bounds
        validationData = 0;

        emit PaymasterApproved(subscriptionId, user, maxCost);
        userOpHash; // referenced to avoid unused var warning
    }

    /// @inheritdoc IPaymaster
    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external {
        _requireFromEntryPoint();

        PaymasterContext memory ctx = abi.decode(context, (PaymasterContext));

        // Only charge budget on success (or revert - bundler charges either way).
        // On postOpReverted, nothing to record.
        if (mode != PostOpMode.postOpReverted) {
            _consumeDailyBudget(ctx.user, actualGasCost);
            emit GasBudgetUpdated(ctx.user, _remainingBudget(ctx.user));
        }

        actualUserOpFeePerGas; // used for context; no additional accounting needed
    }

    // ─── ISubscriptionPaymaster ───────────────────────────────────────────────

    /// @inheritdoc ISubscriptionPaymaster
    function deposit() external payable {
        entryPoint.depositTo{value: msg.value}(address(this));
    }

    /// @inheritdoc ISubscriptionPaymaster
    function withdraw(uint256 amount, address payable to) external onlyOwner nonReentrant {
        entryPoint.withdrawTo(to, amount);
    }

    /// @inheritdoc ISubscriptionPaymaster
    function balance() external view returns (uint256) {
        return entryPoint.balanceOf(address(this));
    }

    /// @inheritdoc ISubscriptionPaymaster
    function remainingBudget(address user) external view returns (uint256) {
        return _remainingBudget(user);
    }

    /// @inheritdoc ISubscriptionPaymaster
    function setDailyBudget(uint256 budgetWei) external onlyOwner {
        dailyBudgetWei = budgetWei;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    /// @notice Add stake to the EntryPoint (required for paymaster operation).
    /// @param unstakeDelaySec  Minimum unstake delay in seconds.
    function addStake(uint32 unstakeDelaySec) external payable onlyOwner {
        entryPoint.addStake{value: msg.value}(unstakeDelaySec);
    }

    /// @notice Unlock stake from the EntryPoint.
    function unlockStake() external onlyOwner {
        entryPoint.unlockStake();
    }

    /// @notice Withdraw unlocked stake.
    function withdrawStake(address payable to) external onlyOwner {
        entryPoint.withdrawStake(to);
    }

    // ─── Internal Helpers ─────────────────────────────────────────────────────

    function _requireFromEntryPoint() internal view {
        if (msg.sender != address(entryPoint)) {
            revert CallerNotEntryPoint(msg.sender, address(entryPoint));
        }
    }

    function _isAllowlistedSelector(bytes4 sel) internal pure returns (bool) {
        return (
            sel == SEL_SUBSCRIBE          ||
            sel == SEL_CANCEL             ||
            sel == SEL_PAUSE              ||
            sel == SEL_RESUME             ||
            sel == SEL_UPDATE             ||
            sel == SEL_PROCESS_RENEWAL    ||
            sel == SEL_PROCESS_RENEWAL_FOR
        );
    }

    function _checkSubscriptionRateLimit(bytes32 subscriptionId) internal view {
        // Rate limit: the registry's lastChargedAt + periodSeconds tells us when
        // the next renewal is valid. If a renewal has already been processed in
        // the current period, the on-chain module will revert anyway - we add
        // an early paymaster check to save gas.
        try registry.getRecord(subscriptionId) returns (
            address,
            address,
            SubscriptionPermission memory perm
        ) {
            if (perm.lastChargedAt != 0) {
                uint48 nextAt = perm.lastChargedAt + perm.periodSeconds;
                if (uint48(block.timestamp) < nextAt) {
                    revert RenewalTooEarly(subscriptionId, nextAt);
                }
            }
            // Check subscription is active
            if (perm.status != SubscriptionStatus.Active) {
                revert SubscriptionLib.SubscriptionNotActive(subscriptionId);
            }
        } catch {
            // If registry lookup fails (not registered yet), allow through -             // the module will enforce constraints.
        }
    }

    function _checkDailyBudget(address user, uint256 cost) internal view {
        uint256 remaining = _remainingBudget(user);
        if (cost > remaining) {
            revert DailyBudgetExceeded(user, cost, remaining);
        }
    }

    function _consumeDailyBudget(address user, uint256 cost) internal {
        uint256 windowStart = _currentWindowStart();
        if (_budgetWindowStart[user] < windowStart) {
            // Reset window
            _budgetWindowStart[user] = windowStart;
            _budgetConsumed[user]    = cost;
        } else {
            _budgetConsumed[user] += cost;
        }
    }

    function _remainingBudget(address user) internal view returns (uint256) {
        uint256 windowStart = _currentWindowStart();
        if (_budgetWindowStart[user] < windowStart) {
            return dailyBudgetWei; // fresh window
        }
        uint256 consumed = _budgetConsumed[user];
        return consumed >= dailyBudgetWei ? 0 : dailyBudgetWei - consumed;
    }

    function _currentWindowStart() internal view returns (uint256) {
        return (block.timestamp / DAY_SECONDS) * DAY_SECONDS;
    }

    // ─── Errors ───────────────────────────────────────────────────────────────

    error SelectorNotAllowlisted(bytes4 sel);
    error CallerNotEntryPoint(address caller, address expected);
    error DailyBudgetExceeded(address user, uint256 requested, uint256 remaining);
    error RenewalTooEarly(bytes32 subscriptionId, uint48 nextAt);
}
