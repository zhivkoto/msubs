// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { SubscriptionTestBase }  from "./helpers/SubscriptionTestBase.sol";
import { SubscriptionModule }    from "../src/SubscriptionModule.sol";
import { MerchantRegistry }      from "../src/MerchantRegistry.sol";
import { SubscriptionRegistry }  from "../src/SubscriptionRegistry.sol";
import { ISubscriptionModule }   from "../src/interfaces/ISubscriptionModule.sol";
import {
    SubscriptionPermission,
    SubscriptionStatus,
    SubscriptionLib
} from "../src/libraries/SubscriptionLib.sol";
import { IModule } from "erc7579/interfaces/IERC7579Module.sol";

/// @title EdgeCasesTest
/// @notice Edge case and regression tests covering lifecycle state transitions, fee collection, module uninstall, and session key rotation.
contract EdgeCasesTest is SubscriptionTestBase {

    // ─── C-01: Module uninstall cancels subscriptions ──────────────────────────

    function test_C01_OnUninstall_CancelsActiveSubscription() public {
        bytes32 sid = _subscribe();

        // Verify subscription is Active before uninstall
        assertEq(uint8(_getPermission(sid).status), uint8(SubscriptionStatus.Active));

        // Uninstall module
        vm.prank(user);
        vm.expectEmit(true, true, false, false);
        emit ISubscriptionModule.SubscriptionCancelled(sid, user, 0);
        subscriptionModule.onUninstall(bytes(""));

        // Subscription must be Cancelled
        assertEq(uint8(_getPermission(sid).status), uint8(SubscriptionStatus.Cancelled));
        assertFalse(subscriptionModule.isInitialized(user));
    }

    function test_C01_OnUninstall_CancelsPausedSubscription() public {
        bytes32 sid = _subscribe();
        vm.prank(user);
        subscriptionModule.pause(sid);

        vm.prank(user);
        subscriptionModule.onUninstall(bytes(""));

        assertEq(uint8(_getPermission(sid).status), uint8(SubscriptionStatus.Cancelled));
    }

    function test_C01_OnUninstall_ProcessRenewalFailsAfterUninstall() public {
        bytes32 sid = _subscribe();
        _warpPeriod();

        // Uninstall module
        vm.prank(user);
        subscriptionModule.onUninstall(bytes(""));

        // Renewal should revert - subscription is now Cancelled
        vm.expectRevert(
            abi.encodeWithSelector(SubscriptionLib.SubscriptionNotActive.selector, sid)
        );
        subscriptionModule.processRenewalFor(user, sid);
    }

    function test_C01_OnUninstall_CancelsMultipleSubscriptions() public {
        // Register a second plan
        vm.prank(merchantEOA);
        bytes32 planId2 = merchantRegistry.registerPlan(address(token), 5e6, 7 days, "Pro Weekly");

        bytes32 sid1 = _subscribe();
        vm.prank(user);
        bytes32 sid2 = subscriptionModule.subscribe(planId2, sessionKey, 0);

        // Both active
        (bytes32[] memory ids, ) = subscriptionModule.getActiveSubscriptionsFor(user);
        assertEq(ids.length, 2);

        // Uninstall
        vm.prank(user);
        subscriptionModule.onUninstall(bytes(""));

        // Both cancelled
        assertEq(uint8(_getPermission(sid1).status), uint8(SubscriptionStatus.Cancelled));
        assertEq(uint8(_getPermission(sid2).status), uint8(SubscriptionStatus.Cancelled));

        // Active list cleared
        (bytes32[] memory idsAfter, ) = subscriptionModule.getActiveSubscriptionsFor(user);
        assertEq(idsAfter.length, 0);
    }

    // ─── C-02: Fee tier (setFeeTier + fee collection) ─────────────────────────

    function test_C02_SetFeeTier_AdminCanSet() public {
        // address(this) is feeAdmin in base setup
        bytes32 mid = merchantRegistry.getMerchantIdByReceiver(receiver);
        merchantRegistry.setFeeTier(mid, 150); // 1.5%

        assertEq(merchantRegistry.getMerchant(mid).feeTier, 150);
    }

    function test_C02_SetFeeTier_RevertNonAdmin() public {
        bytes32 mid = merchantRegistry.getMerchantIdByReceiver(receiver);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(MerchantRegistry.NotFeeAdmin.selector);
        merchantRegistry.setFeeTier(mid, 100);
    }

    function test_C02_SetFeeTier_RevertExceedsCap() public {
        bytes32 mid = merchantRegistry.getMerchantIdByReceiver(receiver);

        vm.expectRevert(
            abi.encodeWithSelector(SubscriptionLib.InvalidFeeTier.selector, 301, 300)
        );
        merchantRegistry.setFeeTier(mid, 301); // > 300 bps
    }

    function test_C02_SetFeeTier_MaxCapAllowed() public {
        bytes32 mid = merchantRegistry.getMerchantIdByReceiver(receiver);
        merchantRegistry.setFeeTier(mid, 300); // exactly 300 bps = 3%
        assertEq(merchantRegistry.getMerchant(mid).feeTier, 300);
    }

    function test_C02_FeeCollectedCorrectly_OnRenewal() public {
        // Set 1.5% fee tier
        bytes32 mid = merchantRegistry.getMerchantIdByReceiver(receiver);
        merchantRegistry.setFeeTier(mid, 150); // 150 bps = 1.5%

        bytes32 sid = _subscribe();
        _warpPeriod();

        uint256 merchantBefore = token.balanceOf(receiver);
        uint256 treasuryBefore = token.balanceOf(treasury);
        uint256 userBefore     = token.balanceOf(user);

        subscriptionModule.processRenewalFor(user, sid);

        // PLAN_AMOUNT = 10e6
        // fee = 10e6 * 150 / 10000 = 150000 (0.15 USDC)
        // net = 10e6 - 150000 = 9850000
        uint256 expectedFee = (PLAN_AMOUNT * 150) / 10_000;
        uint256 expectedNet = PLAN_AMOUNT - expectedFee;

        assertEq(token.balanceOf(receiver), merchantBefore + expectedNet);
        assertEq(token.balanceOf(treasury), treasuryBefore + expectedFee);
        assertEq(token.balanceOf(user),     userBefore - PLAN_AMOUNT);
    }

    function test_C02_FeeAppliesAtChargeTime_NotAtSubscribeTime() public {
        bytes32 sid = _subscribe();

        // First renewal with 0% fee
        _warpPeriod();
        subscriptionModule.processRenewalFor(user, sid);
        uint256 merchantAfterFirst = token.balanceOf(receiver);

        // Admin sets 1% fee
        bytes32 mid = merchantRegistry.getMerchantIdByReceiver(receiver);
        merchantRegistry.setFeeTier(mid, 100);

        // Second renewal should use new fee
        _warpPeriod();
        uint256 merchantBefore = token.balanceOf(receiver);
        uint256 treasuryBefore = token.balanceOf(treasury);
        subscriptionModule.processRenewalFor(user, sid);

        uint256 expectedFee = (PLAN_AMOUNT * 100) / 10_000;
        uint256 expectedNet = PLAN_AMOUNT - expectedFee;
        assertEq(token.balanceOf(receiver) - merchantBefore, expectedNet);
        assertEq(token.balanceOf(treasury) - treasuryBefore, expectedFee);

        (merchantAfterFirst); // suppress unused var
    }

    // ─── H-01: update() fixes _activePlanSubscription ─────────────────────────

    function test_H01_Update_FixesActivePlanMapping() public {
        bytes32 sid = _subscribe();

        // Register a new plan
        vm.prank(merchantEOA);
        bytes32 newPlanId = merchantRegistry.registerPlan(address(token), 20e6, 7 days, "Pro Weekly");

        // Update subscription to new plan
        vm.prank(user);
        subscriptionModule.update(sid, newPlanId);

        // Can now subscribe to old plan (mapping was cleared)
        vm.prank(user);
        bytes32 sid2 = subscriptionModule.subscribe(planId, sessionKey, 0);
        assertTrue(sid2 != bytes32(0));
        assertEq(uint8(_getPermission(sid2).status), uint8(SubscriptionStatus.Active));
    }

    function test_H01_Update_PreventsDuplicateToNewPlan() public {
        bytes32 sid = _subscribe();

        vm.prank(merchantEOA);
        bytes32 newPlanId = merchantRegistry.registerPlan(address(token), 20e6, 7 days, "Pro Weekly");

        // Update to new plan
        vm.prank(user);
        subscriptionModule.update(sid, newPlanId);

        // Trying to subscribe to new plan should revert (already active under sid)
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(SubscriptionLib.SubscriptionAlreadyActive.selector, sid)
        );
        subscriptionModule.subscribe(newPlanId, sessionKey, 0);
    }

    function test_H01_Update_SyncsRegistry() public {
        bytes32 sid = _subscribe();

        vm.prank(merchantEOA);
        bytes32 newPlanId = merchantRegistry.registerPlan(address(token), 20e6, 7 days, "Pro Weekly");

        vm.prank(user);
        subscriptionModule.update(sid, newPlanId);

        // Registry should reflect new plan data
        (, , SubscriptionPermission memory regPerm) = subscriptionRegistry.getRecord(sid);
        assertEq(regPerm.planId, newPlanId);
        assertEq(regPerm.maxAmount, 20e6);
        assertEq(regPerm.periodSeconds, 7 days);
    }

    // ─── H-02: validateRenewal period check ───────────────────────────────────

    function test_H02_ValidateRenewal_ReturnsFailed_WhenPeriodNotElapsed() public {
        bytes32 sid = _subscribe();
        // Don't warp - period not elapsed

        bytes32 userOpHash = keccak256("hash");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sessionKeyPk, userOpHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(user);
        uint256 result = subscriptionModule.validateRenewal(sid, userOpHash, sig);
        assertEq(result, 1); // VALIDATION_FAILED
    }

    function test_H02_ValidateRenewal_ReturnsSuccess_AfterPeriodElapsed() public {
        bytes32 sid = _subscribe();
        _warpPeriod(); // warp past startTime + periodSeconds

        bytes32 userOpHash = keccak256("hash");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sessionKeyPk, userOpHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(user);
        uint256 result = subscriptionModule.validateRenewal(sid, userOpHash, sig);
        assertEq(result, 0); // VALIDATION_SUCCESS
    }

    // ─── M-01: First-charge timing ────────────────────────────────────────────

    function test_M01_FirstCharge_RequiresStartTimePlusPeriod() public {
        bytes32 sid = _subscribe();
        uint48 startTime = _getPermission(sid).startTime;

        // Try to charge before startTime + periodSeconds - should revert
        vm.warp(uint256(startTime) + PLAN_PERIOD - 1); // 1 second before valid

        vm.expectRevert(
            abi.encodeWithSelector(
                SubscriptionLib.PeriodNotElapsed.selector,
                sid,
                uint48(startTime) + PLAN_PERIOD,
                uint48(block.timestamp)
            )
        );
        subscriptionModule.processRenewalFor(user, sid);
    }

    function test_M01_FirstCharge_SucceedsAtStartTimePlusPeriod() public {
        bytes32 sid = _subscribe();
        uint48 startTime = _getPermission(sid).startTime;

        // Warp to exactly startTime + periodSeconds
        vm.warp(uint256(startTime) + PLAN_PERIOD);
        subscriptionModule.processRenewalFor(user, sid);

        assertEq(_getPermission(sid).lastChargedAt, uint48(block.timestamp));
    }

    function test_M01_NoImmediateChargeInSameBlock() public {
        bytes32 sid = _subscribe();

        // Attempting charge without warping should revert
        vm.expectRevert(); // PeriodNotElapsed
        subscriptionModule.processRenewalFor(user, sid);
    }

    function test_M01_Registry_DueSubscriptionsUsesStartTime() public {
        bytes32 sid = _subscribe();
        uint48 startTime = _getPermission(sid).startTime;

        // Just before due: no results
        vm.warp(uint256(startTime) + PLAN_PERIOD - 1);
        (bytes32[] memory ids, ) = subscriptionRegistry.getDueSubscriptions(0, 10);
        assertEq(ids.length, 0);

        // At due time: appears in results
        vm.warp(uint256(startTime) + PLAN_PERIOD);
        (ids, ) = subscriptionRegistry.getDueSubscriptions(0, 10);
        assertEq(ids.length, 1);
        assertEq(ids[0], sid);

        (sid); // suppress
    }

    // ─── M-03: SubscriptionFailed + grace period state machine ────────────────

    function test_M03_SubscriptionFailed_EmittedOnTransferFailure() public {
        bytes32 sid = _subscribe();
        _warpPeriod();

        // Drain user balance
        uint256 bal = token.balanceOf(user);
        vm.prank(user);
        token.transfer(makeAddr("drain"), bal);

        vm.expectEmit(true, false, false, false);
        emit ISubscriptionModule.SubscriptionFailed(sid, 1, "");
        subscriptionModule.processRenewalFor(user, sid);
    }

    function test_M03_GracePeriod_EnteredAfterMaxFailedAttempts() public {
        bytes32 sid = _subscribe();

        // Drain user balance
        uint256 bal = token.balanceOf(user);
        vm.prank(user);
        token.transfer(makeAddr("drain"), bal);

        // MAX_FAILED_ATTEMPTS = 4; first 3 failures stay Active
        for (uint8 i = 1; i < 4; i++) {
            _warpPeriod();
            subscriptionModule.processRenewalFor(user, sid);
            assertEq(uint8(_getPermission(sid).status), uint8(SubscriptionStatus.Active),
                "Should still be Active");
            assertEq(subscriptionModule.getFailedAttempts(user, sid), i);
        }

        // 4th failure: transition to GracePeriod
        _warpPeriod();
        vm.expectEmit(true, false, false, false);
        emit ISubscriptionModule.SubscriptionFailed(sid, 4, "");
        subscriptionModule.processRenewalFor(user, sid);

        assertEq(uint8(_getPermission(sid).status), uint8(SubscriptionStatus.GracePeriod));
        assertEq(subscriptionModule.getFailedAttempts(user, sid), 4);
        assertTrue(subscriptionModule.getGraceUntil(user, sid) > 0);
    }

    function test_M03_GracePeriod_ResetOnSuccessfulCharge() public {
        bytes32 sid = _subscribe();

        // Drain and cause 3 failures
        uint256 bal = token.balanceOf(user);
        vm.prank(user);
        token.transfer(makeAddr("drain"), bal);

        for (uint8 i = 0; i < 3; i++) {
            _warpPeriod();
            subscriptionModule.processRenewalFor(user, sid);
        }
        assertEq(subscriptionModule.getFailedAttempts(user, sid), 3);

        // Restore balance
        token.mint(user, 1_000e6);

        // Next renewal succeeds
        _warpPeriod();
        subscriptionModule.processRenewalFor(user, sid);

        assertEq(subscriptionModule.getFailedAttempts(user, sid), 0);
        assertEq(uint8(_getPermission(sid).status), uint8(SubscriptionStatus.Active));
    }

    function test_M03_GracePeriod_ExpiresAndSubscriptionExpires() public {
        bytes32 sid = _subscribe();

        // Drain balance
        uint256 bal = token.balanceOf(user);
        vm.prank(user);
        token.transfer(makeAddr("drain"), bal);

        // Hit MAX_FAILED_ATTEMPTS to enter GracePeriod
        for (uint8 i = 0; i < 4; i++) {
            _warpPeriod();
            subscriptionModule.processRenewalFor(user, sid);
        }
        assertEq(uint8(_getPermission(sid).status), uint8(SubscriptionStatus.GracePeriod));

        uint48 graceEnd = subscriptionModule.getGraceUntil(user, sid);

        // Warp past grace period end
        vm.warp(uint256(graceEnd) + 1);

        // Attempt renewal - should expire subscription
        vm.expectEmit(true, false, false, false);
        emit ISubscriptionModule.SubscriptionExpired(sid, "");
        subscriptionModule.processRenewalFor(user, sid);

        assertEq(uint8(_getPermission(sid).status), uint8(SubscriptionStatus.Expired));
    }

    function test_M03_GracePeriod_SuccessfulChargeRestoresActive() public {
        bytes32 sid = _subscribe();
        uint48 startTime = _getPermission(sid).startTime;

        // Drain balance
        uint256 bal = token.balanceOf(user);
        vm.prank(user);
        token.transfer(makeAddr("drain"), bal);

        // Enter GracePeriod (4 failures across 4 periods)
        for (uint8 i = 0; i < 4; i++) {
            _warpPeriod();
            subscriptionModule.processRenewalFor(user, sid);
        }
        assertEq(uint8(_getPermission(sid).status), uint8(SubscriptionStatus.GracePeriod));
        uint48 graceEnd = subscriptionModule.getGraceUntil(user, sid);

        // Restore balance before grace expires
        token.mint(user, 1_000e6);

        // Warp only enough that the next period has elapsed but we're still within grace.
        // Grace = 7 days from when 4th failure happened.
        // lastChargedAt is still 0 (never successfully charged), so validFrom = startTime + PLAN_PERIOD.
        // After 4 warpPeriods (4 * (PLAN_PERIOD+1)), the 5th period is already due.
        // Just warp 1 more day (well within grace window of 7 days from now).
        vm.warp(block.timestamp + 1 days);
        assertTrue(uint48(block.timestamp) < graceEnd, "still within grace window");

        subscriptionModule.processRenewalFor(user, sid);

        assertEq(uint8(_getPermission(sid).status), uint8(SubscriptionStatus.Active));
        assertEq(subscriptionModule.getFailedAttempts(user, sid), 0);
        assertEq(subscriptionModule.getGraceUntil(user, sid), 0);

        (startTime); // suppress
    }

    // ─── M-04: Expired expiresAt rejected at subscribe ────────────────────────

    function test_M04_Subscribe_RevertPastExpiresAt() public {
        // Warp to a meaningful timestamp so past timestamp is unambiguously in the past
        vm.warp(1_000_000);
        uint48 pastExpiry = uint48(block.timestamp) - 1;

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(SubscriptionLib.SubscriptionExpired.selector, bytes32(0))
        );
        subscriptionModule.subscribe(planId, sessionKey, pastExpiry);
    }

    function test_M04_Subscribe_RevertCurrentTimestampExpiresAt() public {
        vm.warp(1_000_000);
        uint48 nowExpiry = uint48(block.timestamp);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(SubscriptionLib.SubscriptionExpired.selector, bytes32(0))
        );
        subscriptionModule.subscribe(planId, sessionKey, nowExpiry);
    }

    function test_M04_Subscribe_AllowsFutureExpiresAt() public {
        uint48 futureExpiry = uint48(block.timestamp) + 365 days;

        vm.prank(user);
        bytes32 sid = subscriptionModule.subscribe(planId, sessionKey, futureExpiry);
        assertEq(_getPermission(sid).expiresAt, futureExpiry);
    }

    function test_M04_Subscribe_AllowsZeroExpiresAt() public {
        vm.prank(user);
        bytes32 sid = subscriptionModule.subscribe(planId, sessionKey, 0);
        assertEq(_getPermission(sid).expiresAt, 0);
    }

    // ─── L-03: SessionKeyRotated event ────────────────────────────────────────

    function test_L03_SessionKeyRotated_EmitsEvent() public {
        bytes32 sid = _subscribe();
        address oldKey = _getPermission(sid).sessionKey;
        address newKey = makeAddr("newKey");

        vm.prank(user);
        vm.expectEmit(true, true, true, false);
        emit ISubscriptionModule.SessionKeyRotated(sid, oldKey, newKey, 0);
        subscriptionModule.rotateSessionKey(sid, newKey);
    }

    // ─── H-04: Registry register restricted to authorized modules ─────────────

    function test_H04_Register_RevertUnauthorized() public {
        SubscriptionPermission memory perm = _getPermission(_subscribe());
        bytes32 fakeSid = keccak256("fake");

        // Stranger (not authorized module) cannot register
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(SubscriptionRegistry.UnauthorizedRegistrar.selector, stranger)
        );
        subscriptionRegistry.register(fakeSid, stranger, perm);
    }

    function test_H04_AuthorizedModule_CanRegister() public {
        // The subscriptionModule is already authorized; subscribe() calls register() internally
        bytes32 sid = _subscribe();
        (address regUser, , ) = subscriptionRegistry.getRecord(sid);
        assertEq(regUser, user);
    }

    // ─── L-01: Correct error for plan name (was InvalidAmount, now InvalidPlanName) ─

    function test_L01_RegisterPlan_CorrectErrorForEmptyName() public {
        vm.prank(merchantEOA);
        vm.expectRevert(SubscriptionLib.InvalidPlanName.selector);
        merchantRegistry.registerPlan(address(token), PLAN_AMOUNT, PLAN_PERIOD, "");
    }

    // ─── L-04: Pagination sentinel = type(uint256).max ─────────────────────────

    function test_L04_Pagination_Sentinel_IsMaxUint256() public {
        bytes32 sid = _subscribe();
        _warpPeriod();

        // Get all in one page - nextCursor should be type(uint256).max (no more pages)
        (, uint256 nextCursor) = subscriptionRegistry.getDueSubscriptions(0, 100);
        assertEq(nextCursor, type(uint256).max);

        (sid); // suppress
    }

    function test_L04_Pagination_CursorZero_IsValidStart() public {
        bytes32 sid = _subscribe();
        _warpPeriod();

        // Cursor 0 is a valid start (not end sentinel)
        (bytes32[] memory ids, ) = subscriptionRegistry.getDueSubscriptions(0, 1);
        assertEq(ids.length, 1);
        assertEq(ids[0], sid);
    }
}
