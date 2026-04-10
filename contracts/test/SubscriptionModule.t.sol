// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { SubscriptionTestBase } from "./helpers/SubscriptionTestBase.sol";
import { SubscriptionModule }   from "../src/SubscriptionModule.sol";
import { ISubscriptionModule }  from "../src/interfaces/ISubscriptionModule.sol";
import {
    SubscriptionPermission,
    SubscriptionStatus,
    SubscriptionLib
} from "../src/libraries/SubscriptionLib.sol";
import { IModule } from "erc7579/interfaces/IERC7579Module.sol";

contract SubscriptionModuleTest is SubscriptionTestBase {

    // ─── onInstall / isInitialized ────────────────────────────────────────────

    function test_OnInstall_MarksInitialized() public {
        address newAccount = makeAddr("newAccount");
        assertFalse(subscriptionModule.isInitialized(newAccount));

        vm.prank(newAccount);
        subscriptionModule.onInstall(bytes(""));
        assertTrue(subscriptionModule.isInitialized(newAccount));
    }

    function test_OnInstall_RevertAlreadyInitialized() public {
        // user is already initialized in setUp
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IModule.AlreadyInitialized.selector, user));
        subscriptionModule.onInstall(bytes(""));
    }

    function test_OnUninstall_ClearsInitialization() public {
        assertTrue(subscriptionModule.isInitialized(user));
        vm.prank(user);
        subscriptionModule.onUninstall(bytes(""));
        assertFalse(subscriptionModule.isInitialized(user));
    }

    function test_IsModuleType() public view {
        assertTrue(subscriptionModule.isModuleType(1)); // VALIDATOR
        assertTrue(subscriptionModule.isModuleType(2)); // EXECUTOR
        assertFalse(subscriptionModule.isModuleType(3)); // FALLBACK
        assertFalse(subscriptionModule.isModuleType(4)); // HOOK
    }

    // ─── subscribe ────────────────────────────────────────────────────────────

    function test_Subscribe_Success() public {
        bytes32 sid = _subscribe();

        SubscriptionPermission memory p = _getPermission(sid);
        assertEq(p.token,         address(token));
        assertEq(p.merchant,      receiver);
        assertEq(p.maxAmount,     PLAN_AMOUNT);
        assertEq(p.periodSeconds, PLAN_PERIOD);
        assertEq(p.startTime,     uint48(block.timestamp));
        assertEq(p.lastChargedAt, 0);
        assertEq(p.expiresAt,     0);
        assertEq(uint8(p.status), uint8(SubscriptionStatus.Active));
        assertEq(p.planId,        planId);
        assertEq(p.sessionKey,    sessionKey);
    }

    function test_Subscribe_EmitsEvent() public {
        vm.prank(user);
        vm.expectEmit(false, true, true, false);
        emit ISubscriptionModule.SubscriptionCreated(
            bytes32(0), // subscriptionId (not checked)
            user,
            receiver,
            planId,
            address(token),
            PLAN_AMOUNT,
            PLAN_PERIOD,
            uint48(block.timestamp),
            sessionKey
        );
        subscriptionModule.subscribe(planId, sessionKey, 0);
    }

    function test_Subscribe_RegistersInRegistry() public {
        bytes32 sid = _subscribe();

        bytes32[] memory ids = subscriptionRegistry.getSubscriptionsByUser(user);
        assertEq(ids.length, 1);
        assertEq(ids[0], sid);
    }

    function test_Subscribe_WithExpiry() public {
        uint48 expiry = uint48(block.timestamp + 365 days);
        bytes32 sid = _subscribeWith(sessionKey, expiry);

        SubscriptionPermission memory p = _getPermission(sid);
        assertEq(p.expiresAt, expiry);
    }

    function test_Subscribe_RevertNotInitialized() public {
        address uninstalled = makeAddr("uninstalled");
        vm.prank(uninstalled);
        vm.expectRevert(abi.encodeWithSelector(IModule.NotInitialized.selector, uninstalled));
        subscriptionModule.subscribe(planId, sessionKey, 0);
    }

    function test_Subscribe_RevertZeroSessionKey() public {
        vm.prank(user);
        vm.expectRevert(SubscriptionLib.InvalidSessionKeyAddress.selector);
        subscriptionModule.subscribe(planId, address(0), 0);
    }

    function test_Subscribe_RevertInvalidPlan() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLib.PlanNotFound.selector, keccak256("nonexistent")));
        subscriptionModule.subscribe(keccak256("nonexistent"), sessionKey, 0);
    }

    function test_Subscribe_RevertDeprecatedPlan() public {
        vm.prank(merchantEOA);
        merchantRegistry.deprecatePlan(planId);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLib.PlanInactive.selector, planId));
        subscriptionModule.subscribe(planId, sessionKey, 0);
    }

    function test_Subscribe_RevertDuplicateActive() public {
        bytes32 sid = _subscribe();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLib.SubscriptionAlreadyActive.selector, sid));
        subscriptionModule.subscribe(planId, sessionKey, 0);
    }

    function test_Subscribe_AllowsResubscribeAfterCancel() public {
        bytes32 sid1 = _subscribe();

        vm.prank(user);
        subscriptionModule.cancel(sid1);

        // After cancel, new subscription gets a different nonce → different ID
        bytes32 sid2 = _subscribe();
        assertTrue(sid2 != sid1);
    }

    // ─── cancel ───────────────────────────────────────────────────────────────

    function test_Cancel_Success() public {
        bytes32 sid = _subscribe();

        vm.prank(user);
        vm.expectEmit(true, true, false, true);
        emit ISubscriptionModule.SubscriptionCancelled(sid, user, uint48(block.timestamp));
        subscriptionModule.cancel(sid);

        SubscriptionPermission memory p = _getPermission(sid);
        assertEq(uint8(p.status), uint8(SubscriptionStatus.Cancelled));
    }

    function test_Cancel_RevertNotFound() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLib.SubscriptionNotFound.selector, keccak256("nonexistent")));
        subscriptionModule.cancel(keccak256("nonexistent"));
    }

    function test_Cancel_RevertAlreadyCancelled() public {
        bytes32 sid = _subscribe();
        vm.prank(user);
        subscriptionModule.cancel(sid);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLib.SubscriptionTerminal.selector, sid));
        subscriptionModule.cancel(sid);
    }

    function test_Cancel_RemovesFromActiveList() public {
        bytes32 sid = _subscribe();

        (bytes32[] memory idsBefore, ) = subscriptionModule.getActiveSubscriptionsFor(user);
        assertEq(idsBefore.length, 1);

        vm.prank(user);
        subscriptionModule.cancel(sid);

        (bytes32[] memory idsAfter, ) = subscriptionModule.getActiveSubscriptionsFor(user);
        assertEq(idsAfter.length, 0);
    }

    // ─── pause / resume ───────────────────────────────────────────────────────

    function test_Pause_Success() public {
        bytes32 sid = _subscribe();

        vm.prank(user);
        subscriptionModule.pause(sid);

        assertEq(uint8(_getPermission(sid).status), uint8(SubscriptionStatus.Paused));
    }

    function test_Pause_RevertNotActive() public {
        bytes32 sid = _subscribe();
        vm.prank(user);
        subscriptionModule.pause(sid);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLib.SubscriptionNotActive.selector, sid));
        subscriptionModule.pause(sid);
    }

    function test_Resume_Success() public {
        bytes32 sid = _subscribe();
        vm.prank(user);
        subscriptionModule.pause(sid);

        vm.prank(user);
        subscriptionModule.resume(sid);

        assertEq(uint8(_getPermission(sid).status), uint8(SubscriptionStatus.Active));
    }

    function test_Resume_RevertNotPaused() public {
        bytes32 sid = _subscribe();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLib.SubscriptionNotPaused.selector, sid));
        subscriptionModule.resume(sid);
    }

    function test_Resume_RevertAfterHardExpiry() public {
        uint48 expiry = uint48(block.timestamp + 1 days);
        bytes32 sid = _subscribeWith(sessionKey, expiry);

        vm.prank(user);
        subscriptionModule.pause(sid);

        // Warp past expiry
        vm.warp(block.timestamp + 2 days);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLib.SubscriptionExpired.selector, sid));
        subscriptionModule.resume(sid);
    }

    // ─── update ───────────────────────────────────────────────────────────────

    function test_Update_Success() public {
        bytes32 sid = _subscribe();

        // Register a new plan with different amount
        vm.prank(merchantEOA);
        bytes32 newPlanId = merchantRegistry.registerPlan(address(token), 20e6, 7 days, "Pro Weekly");

        bytes32 oldPlanId = _getPermission(sid).planId;

        vm.prank(user);
        vm.expectEmit(true, false, false, true);
        emit ISubscriptionModule.SubscriptionUpdated(sid, oldPlanId, newPlanId, uint8(SubscriptionStatus.Active), uint8(SubscriptionStatus.Active));
        subscriptionModule.update(sid, newPlanId);

        SubscriptionPermission memory p = _getPermission(sid);
        assertEq(p.planId,        newPlanId);
        assertEq(p.maxAmount,     20e6);
        assertEq(p.periodSeconds, 7 days);
    }

    function test_Update_DoesNotResetLastChargedAt() public {
        bytes32 sid = _subscribe();
        // Process first renewal to set lastChargedAt
        _warpPeriod();
        subscriptionModule.processRenewalFor(user, sid);
        uint48 lastCharged = _getPermission(sid).lastChargedAt;
        assertTrue(lastCharged > 0);

        vm.prank(merchantEOA);
        bytes32 newPlanId = merchantRegistry.registerPlan(address(token), 20e6, 7 days, "Pro Weekly");

        vm.prank(user);
        subscriptionModule.update(sid, newPlanId);

        // lastChargedAt must be preserved
        assertEq(_getPermission(sid).lastChargedAt, lastCharged);
    }

    function test_Update_RevertWrongMerchant() public {
        bytes32 sid = _subscribe();

        // Create a second merchant with a different plan
        address auth2 = makeAddr("auth2");
        address recv2 = makeAddr("recv2");
        vm.prank(auth2);
        merchantRegistry.registerMerchant(recv2, "");
        vm.prank(auth2);
        bytes32 otherPlanId = merchantRegistry.registerPlan(address(token), 5e6, 30 days, "Other");

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLib.PlanMerchantMismatch.selector, otherPlanId, receiver, recv2));
        subscriptionModule.update(sid, otherPlanId);
    }

    function test_Update_RevertOnTerminalSubscription() public {
        bytes32 sid = _subscribe();
        vm.prank(user);
        subscriptionModule.cancel(sid);

        vm.prank(merchantEOA);
        bytes32 newPlanId = merchantRegistry.registerPlan(address(token), 20e6, 7 days, "Pro2");

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLib.SubscriptionTerminal.selector, sid));
        subscriptionModule.update(sid, newPlanId);
    }

    // ─── rotateSessionKey ─────────────────────────────────────────────────────

    function test_RotateSessionKey_Success() public {
        bytes32 sid = _subscribe();
        address newKey = makeAddr("newKey");

        vm.prank(user);
        subscriptionModule.rotateSessionKey(sid, newKey);

        assertEq(_getPermission(sid).sessionKey, newKey);
    }

    function test_RotateSessionKey_RevertZeroKey() public {
        bytes32 sid = _subscribe();
        vm.prank(user);
        vm.expectRevert(SubscriptionLib.InvalidSessionKeyAddress.selector);
        subscriptionModule.rotateSessionKey(sid, address(0));
    }

    function test_RotateSessionKey_RevertTerminal() public {
        bytes32 sid = _subscribe();
        vm.prank(user);
        subscriptionModule.cancel(sid);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLib.SubscriptionTerminal.selector, sid));
        subscriptionModule.rotateSessionKey(sid, makeAddr("newKey"));
    }

    // ─── processRenewal ───────────────────────────────────────────────────────

    function test_ProcessRenewal_Success() public {
        bytes32 sid = _subscribe();
        _warpPeriod();

        uint256 merchantBalBefore = token.balanceOf(receiver);
        uint256 treasuryBalBefore = token.balanceOf(treasury);
        uint256 userBalBefore     = token.balanceOf(user);

        subscriptionModule.processRenewalFor(user, sid);

        // Merchant gets full amount (feeTier == 0 by default)
        assertEq(token.balanceOf(receiver), merchantBalBefore + PLAN_AMOUNT);
        assertEq(token.balanceOf(treasury), treasuryBalBefore); // no fee
        assertEq(token.balanceOf(user),     userBalBefore - PLAN_AMOUNT);
    }

    function test_ProcessRenewal_EmitsChargedEvent() public {
        bytes32 sid = _subscribe();
        _warpPeriod();

        vm.expectEmit(true, true, false, false);
        emit ISubscriptionModule.SubscriptionCharged(sid, receiver, PLAN_AMOUNT, 0, 0, 0);
        subscriptionModule.processRenewalFor(user, sid);
    }

    function test_ProcessRenewal_UpdatesLastChargedAt() public {
        bytes32 sid = _subscribe();
        _warpPeriod();
        uint48 ts = uint48(block.timestamp);

        subscriptionModule.processRenewalFor(user, sid);

        assertEq(_getPermission(sid).lastChargedAt, ts);
    }

    function test_ProcessRenewal_RevertPeriodNotElapsed() public {
        bytes32 sid = _subscribe();
        _warpPeriod();

        subscriptionModule.processRenewalFor(user, sid); // first renewal

        // Try again immediately - should revert
        vm.expectRevert(); // PeriodNotElapsed
        subscriptionModule.processRenewalFor(user, sid);
    }

    function test_ProcessRenewal_RevertNotActive() public {
        bytes32 sid = _subscribe();
        vm.prank(user);
        subscriptionModule.pause(sid);

        _warpPeriod();
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLib.SubscriptionNotActive.selector, sid));
        subscriptionModule.processRenewalFor(user, sid);
    }

    function test_ProcessRenewal_MarksExpiredOnHardExpiry() public {
        uint48 expiry = uint48(block.timestamp + 5 days);
        bytes32 sid = _subscribeWith(sessionKey, expiry);

        // Warp past expiry AND period
        vm.warp(block.timestamp + 10 days);

        // First renewal attempt should emit SubscriptionExpired and return without charging
        uint256 merchantBalBefore = token.balanceOf(receiver);
        subscriptionModule.processRenewalFor(user, sid);
        assertEq(token.balanceOf(receiver), merchantBalBefore); // no charge
        assertEq(uint8(_getPermission(sid).status), uint8(SubscriptionStatus.Expired));
    }

    function test_ProcessRenewal_AllowsFirstChargeWithoutPreviousCharge() public {
        bytes32 sid = _subscribe();
        // Warp just past one period from epoch (lastChargedAt=0)
        vm.warp(uint256(PLAN_PERIOD) + 1);

        subscriptionModule.processRenewalFor(user, sid);

        assertEq(_getPermission(sid).lastChargedAt, uint48(block.timestamp));
    }

    function test_ProcessRenewal_MultipleSuccessivePeriods() public {
        bytes32 sid = _subscribe();

        for (uint256 i = 0; i < 3; i++) {
            _warpPeriod();
            subscriptionModule.processRenewalFor(user, sid);
        }

        // User should have been charged 3 times
        assertEq(token.balanceOf(user), 1_000e6 - PLAN_AMOUNT * 3);
    }

    // ─── getActiveSubscriptions ───────────────────────────────────────────────

    function test_GetActiveSubscriptions_ReturnsActive() public {
        bytes32 sid = _subscribe();

        vm.prank(user);
        (bytes32[] memory ids, SubscriptionPermission[] memory perms) =
            subscriptionModule.getActiveSubscriptions();
        assertEq(ids.length, 1);
        assertEq(ids[0], sid);
        assertEq(perms[0].merchant, receiver);
    }

    function test_GetActiveSubscriptions_ExcludesCancelled() public {
        bytes32 sid = _subscribe();
        vm.prank(user);
        subscriptionModule.cancel(sid);

        vm.prank(user);
        (bytes32[] memory ids, ) = subscriptionModule.getActiveSubscriptions();
        assertEq(ids.length, 0);
    }

    function test_GetActiveSubscriptions_IncludesPaused() public {
        bytes32 sid = _subscribe();
        vm.prank(user);
        subscriptionModule.pause(sid);

        vm.prank(user);
        (bytes32[] memory ids, ) = subscriptionModule.getActiveSubscriptions();
        assertEq(ids.length, 1);
        assertEq(ids[0], sid);
    }

    // ─── validateUserOp ───────────────────────────────────────────────────────

    function test_ValidateUserOp_ValidSessionKeySignature() public {
        bytes32 sid = _subscribe();

        // [H-02] validation now requires period elapsed; warp past first period
        _warpPeriod();

        // Simulate a userOpHash
        bytes32 userOpHash = keccak256("test_userop_hash");

        // Session key signs the userOpHash
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sessionKeyPk, userOpHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        // validateRenewal is called by the smart account (user in ERC-7579 path)
        vm.prank(user);
        uint256 result = subscriptionModule.validateRenewal(sid, userOpHash, sig);
        assertEq(result, 0); // VALIDATION_SUCCESS
    }

    function test_ValidateUserOp_ReturnsFailed_WhenPeriodNotElapsed() public {
        bytes32 sid = _subscribe();

        // Do NOT warp - period has not elapsed, validation must return FAILED
        bytes32 userOpHash = keccak256("test_userop_hash");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sessionKeyPk, userOpHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(user);
        uint256 result = subscriptionModule.validateRenewal(sid, userOpHash, sig);
        assertEq(result, 1); // VALIDATION_FAILED (period not elapsed per H-02 fix)
    }

    function test_ValidateUserOp_InvalidSignature() public {
        bytes32 sid = _subscribe();
        bytes32 userOpHash = keccak256("test_userop_hash");

        // Wrong private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xbadc0de1, userOpHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(user);
        uint256 result = subscriptionModule.validateRenewal(sid, userOpHash, sig);
        assertEq(result, 1); // VALIDATION_FAILED
    }

    function test_ValidateRenewal_RevertTerminal() public {
        bytes32 sid = _subscribe();
        vm.prank(user);
        subscriptionModule.cancel(sid);

        bytes memory sig = new bytes(65);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLib.SubscriptionTerminal.selector, sid));
        subscriptionModule.validateRenewal(sid, bytes32(0), sig);
    }

    function test_ValidateRenewal_RevertExpired() public {
        uint48 expiry = uint48(block.timestamp + 1);
        bytes32 sid = _subscribeWith(sessionKey, expiry);

        vm.warp(block.timestamp + 100);

        bytes memory sig = new bytes(65);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLib.SubscriptionExpired.selector, sid));
        subscriptionModule.validateRenewal(sid, bytes32(0), sig);
    }

    // ─── Fuzz ─────────────────────────────────────────────────────────────────

    function testFuzz_Subscribe_SessionKeyNeverZero(address sk) public {
        vm.assume(sk != address(0));
        vm.prank(user);
        bytes32 sid = subscriptionModule.subscribe(planId, sk, 0);
        assertEq(_getPermission(sid).sessionKey, sk);
    }

    function testFuzz_ProcessRenewal_PeriodBoundary(uint32 warpDelta) public {
        vm.assume(warpDelta > 0);
        bytes32 sid = _subscribe();

        uint256 targetTime = uint256(PLAN_PERIOD) + warpDelta;
        vm.warp(targetTime);

        // Should always succeed when warpDelta > 0 means we're past period
        subscriptionModule.processRenewalFor(user, sid);
        assertGe(_getPermission(sid).lastChargedAt, uint48(PLAN_PERIOD));
    }
}

/// @dev Minimal struct for test - avoids importing full PackedUserOperation in test file.
struct PackedUserOperationMock {
    address sender;
    bytes   signature;
}
