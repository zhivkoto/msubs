// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { SubscriptionTestBase } from "./helpers/SubscriptionTestBase.sol";
import { SubscriptionModule }   from "../src/SubscriptionModule.sol";
import { SubscriptionRegistry } from "../src/SubscriptionRegistry.sol";
import { ISubscriptionModule }  from "../src/interfaces/ISubscriptionModule.sol";
import {
    SubscriptionPermission,
    SubscriptionStatus,
    SubscriptionLib
} from "../src/libraries/SubscriptionLib.sol";

/// @notice Full lifecycle integration tests.
/// Tests the complete subscription journey from setup through renewal → cancel,
/// grace period flow, upgrade, and session key compromise scenarios.
contract IntegrationTest is SubscriptionTestBase {

    // ─── Full happy-path lifecycle ─────────────────────────────────────────────

    /// @notice Setup → first renewal → second renewal → cancel.
    function test_FullLifecycle_SetupRenewalCancel() public {
        // 1. Subscribe
        bytes32 sid = _subscribe();
        assertEq(uint8(_getPermission(sid).status), uint8(SubscriptionStatus.Active));

        uint256 initialBalance = token.balanceOf(user);

        // 2. First renewal (must warp past period since lastChargedAt=0)
        vm.warp(block.timestamp + PLAN_PERIOD + 1);
        subscriptionModule.processRenewalFor(user, sid);
        assertEq(token.balanceOf(user), initialBalance - PLAN_AMOUNT);
        assertGt(_getPermission(sid).lastChargedAt, 0);

        // 3. Second renewal
        vm.warp(block.timestamp + PLAN_PERIOD + 1);
        subscriptionModule.processRenewalFor(user, sid);
        assertEq(token.balanceOf(user), initialBalance - PLAN_AMOUNT * 2);

        // 4. Cancel
        vm.prank(user);
        subscriptionModule.cancel(sid);
        assertEq(uint8(_getPermission(sid).status), uint8(SubscriptionStatus.Cancelled));

        // Registry should reflect cancelled
        (bytes32[] memory ids, ) = subscriptionRegistry.getActiveSubscriptionsForWallet(user);
        assertEq(ids.length, 0);
    }

    /// @notice Renewal → pause → no charge during pause → resume → successful renewal.
    function test_FullLifecycle_PauseResume() public {
        bytes32 sid = _subscribe();

        // First renewal
        _warpPeriod();
        subscriptionModule.processRenewalFor(user, sid);

        // Pause
        vm.prank(user);
        subscriptionModule.pause(sid);

        // Renewal attempt while paused should revert
        _warpPeriod();
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLib.SubscriptionNotActive.selector, sid));
        subscriptionModule.processRenewalFor(user, sid);

        // Resume
        vm.prank(user);
        subscriptionModule.resume(sid);

        // Renewal now succeeds
        subscriptionModule.processRenewalFor(user, sid);
        assertEq(uint8(_getPermission(sid).status), uint8(SubscriptionStatus.Active));
    }

    /// @notice Setup → hard expiry → renewal attempt marks expired.
    function test_FullLifecycle_HardExpiry() public {
        uint48 expiry = uint48(block.timestamp + 45 days);
        bytes32 sid = _subscribeWith(sessionKey, expiry);

        // First renewal within expiry
        vm.warp(block.timestamp + PLAN_PERIOD + 1);
        subscriptionModule.processRenewalFor(user, sid);

        // Warp past expiry
        vm.warp(block.timestamp + 20 days); // now 31+20=51 days > 45

        // Renewal should mark expired, not charge
        uint256 balBefore = token.balanceOf(receiver);
        subscriptionModule.processRenewalFor(user, sid);
        assertEq(token.balanceOf(receiver), balBefore); // no charge
        assertEq(uint8(_getPermission(sid).status), uint8(SubscriptionStatus.Expired));

        // Subsequent renewals revert as NotActive
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLib.SubscriptionNotActive.selector, sid));
        subscriptionModule.processRenewalFor(user, sid);
    }

    // ─── Upgrade flow ─────────────────────────────────────────────────────────

    /// @notice Subscribe to basic plan → upgrade to pro → renewal charges new amount.
    function test_UpgradeFlow() public {
        bytes32 sid = _subscribe(); // Pro Monthly: 10 USDC/30 days

        // Register a Pro Weekly plan (same merchant, 20 USDC/7 days)
        vm.prank(merchantEOA);
        bytes32 proWeekly = merchantRegistry.registerPlan(
            address(token), 20e6, 7 days, "Pro Weekly"
        );

        // First renewal under basic plan
        _warpPeriod();
        subscriptionModule.processRenewalFor(user, sid);
        assertEq(token.balanceOf(user), 1_000e6 - PLAN_AMOUNT);

        // Upgrade
        vm.prank(user);
        subscriptionModule.update(sid, proWeekly);

        // lastChargedAt is preserved; next renewal uses new period (7 days)
        uint48 lastCharged = _getPermission(sid).lastChargedAt;
        vm.warp(uint256(lastCharged) + 7 days + 1);

        uint256 balBefore = token.balanceOf(user);
        subscriptionModule.processRenewalFor(user, sid);
        assertEq(token.balanceOf(user), balBefore - 20e6); // new amount charged
    }

    // ─── Multiple subscriptions per account ───────────────────────────────────

    function test_MultipleSubscriptions_SameAccount() public {
        // Register a second plan (different name = different planId)
        vm.prank(merchantEOA);
        bytes32 planId2 = merchantRegistry.registerPlan(
            address(token), 50e6, 7 days, "Enterprise Weekly"
        );

        bytes32 sid1 = _subscribe(); // 10 USDC/month

        vm.prank(user);
        bytes32 sid2 = subscriptionModule.subscribe(planId2, sessionKey, 0); // 50 USDC/week

        assertTrue(sid1 != sid2);

        (bytes32[] memory ids, ) = subscriptionModule.getActiveSubscriptionsFor(user);
        assertEq(ids.length, 2);

        // Renew both independently
        vm.warp(block.timestamp + 8 days);
        subscriptionModule.processRenewalFor(user, sid2); // 50 USDC
        vm.warp(block.timestamp + PLAN_PERIOD); // another 30 days
        subscriptionModule.processRenewalFor(user, sid1); // 10 USDC

        assertEq(token.balanceOf(user), 1_000e6 - 50e6 - PLAN_AMOUNT);
    }

    // ─── Multiple users, same merchant ────────────────────────────────────────

    function test_MultipleUsers_SameMerchant() public {
        address user2 = makeAddr("user2");
        vm.prank(user2);
        subscriptionModule.onInstall(bytes(""));
        token.mint(user2, 500e6);
        vm.prank(user2);
        token.approve(address(subscriptionModule), type(uint256).max);

        bytes32 sid1;
        vm.prank(user);
        sid1 = subscriptionModule.subscribe(planId, sessionKey, 0);

        address sk2 = makeAddr("sk2");
        bytes32 sid2;
        vm.prank(user2);
        sid2 = subscriptionModule.subscribe(planId, sk2, 0);

        assertTrue(sid1 != sid2);

        // Both subscriptions registered in registry
        bytes32[] memory byMerchant = subscriptionRegistry.getSubscriptionsByMerchant(receiver);
        assertEq(byMerchant.length, 2);

        // Renew both
        _warpPeriod();
        subscriptionModule.processRenewalFor(user, sid1);
        subscriptionModule.processRenewalFor(user2, sid2);

        assertEq(token.balanceOf(receiver), PLAN_AMOUNT * 2);
    }

    // ─── Session key compromise simulation ────────────────────────────────────

    /// @notice Attacker with session key can only charge maxAmount to pre-specified merchant.
    ///         User rotates key to neutralize the compromised key.
    function test_SessionKeyCompromise_BoundedBlastRadius() public {
        bytes32 sid = _subscribe();
        _warpPeriod();

        // Attacker uses session key to trigger renewal — should succeed (bounded)
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        subscriptionModule.processRenewalFor(user, sid); // attacker triggers it

        // Charged only to pre-specified merchant at correct amount
        assertEq(token.balanceOf(receiver), PLAN_AMOUNT);

        // Cannot trigger again before period
        vm.prank(attacker);
        vm.expectRevert(); // PeriodNotElapsed
        subscriptionModule.processRenewalFor(user, sid);

        // User detects compromise, rotates key
        address newKey = makeAddr("newKey");
        vm.prank(user);
        subscriptionModule.rotateSessionKey(sid, newKey);

        // Old session key is now dead — but the on-chain enforcement is what matters
        // (validateUserOp would now reject old key signatures)
        assertEq(_getPermission(sid).sessionKey, newKey);

        // Subscription still active with new key
        assertEq(uint8(_getPermission(sid).status), uint8(SubscriptionStatus.Active));
    }

    // ─── Merchant change scenario ─────────────────────────────────────────────

    /// @notice Merchant registers new receiver, deprecates old plans, creates new ones.
    ///         Existing subscriber continues on old terms until they manually upgrade.
    function test_MerchantPriceChange_ExistingSubscriberUnaffected() public {
        bytes32 sid = _subscribe();
        _warpPeriod();

        // Merchant raises prices: deprecate old plan, register new one
        vm.prank(merchantEOA);
        merchantRegistry.deprecatePlan(planId);
        vm.prank(merchantEOA);
        bytes32 newPlan = merchantRegistry.registerPlan(address(token), 15e6, 30 days, "Pro Monthly v2");

        // Existing subscriber's renewal still works at old price
        uint256 balBefore = token.balanceOf(user);
        subscriptionModule.processRenewalFor(user, sid);
        assertEq(token.balanceOf(user), balBefore - PLAN_AMOUNT); // still 10 USDC, not 15

        // New subscriber on old plan fails
        address newUser = makeAddr("newUser");
        vm.prank(newUser);
        subscriptionModule.onInstall(bytes(""));
        token.mint(newUser, 500e6);
        vm.prank(newUser);
        token.approve(address(subscriptionModule), type(uint256).max);

        vm.prank(newUser);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLib.PlanInactive.selector, planId));
        subscriptionModule.subscribe(planId, sessionKey, 0);

        // But new subscriber can use new plan
        vm.prank(newUser);
        bytes32 sid2 = subscriptionModule.subscribe(newPlan, sessionKey, 0);
        // Retrieve from new user context (not from user)
        SubscriptionPermission memory p2 = subscriptionModule.getSubscriptionFor(newUser, sid2);
        assertEq(p2.maxAmount, 15e6);
    }

    // ─── EIP-712 type hash consistency ────────────────────────────────────────

    function test_EIP712_TypeHashConsistency() public view {
        bytes32 expected = keccak256(
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
        assertEq(SubscriptionLib.SUBSCRIPTION_PERMISSION_TYPE_HASH, expected);
    }

    // ─── Registry synchronization ─────────────────────────────────────────────

    function test_Registry_MirrorsModuleState() public {
        bytes32 sid = _subscribe();

        // Registry reflects Active
        (, , SubscriptionPermission memory rp) = subscriptionRegistry.getRecord(sid);
        assertEq(uint8(rp.status), uint8(SubscriptionStatus.Active));

        // Pause via module → registry mirrors it
        vm.prank(user);
        subscriptionModule.pause(sid);
        (, , SubscriptionPermission memory rp2) = subscriptionRegistry.getRecord(sid);
        assertEq(uint8(rp2.status), uint8(SubscriptionStatus.Paused));

        // Resume
        vm.prank(user);
        subscriptionModule.resume(sid);
        (, , SubscriptionPermission memory rp3) = subscriptionRegistry.getRecord(sid);
        assertEq(uint8(rp3.status), uint8(SubscriptionStatus.Active));

        // Cancel
        vm.prank(user);
        subscriptionModule.cancel(sid);
        (, , SubscriptionPermission memory rp4) = subscriptionRegistry.getRecord(sid);
        assertEq(uint8(rp4.status), uint8(SubscriptionStatus.Cancelled));
    }

    function test_Registry_RecordsChargeTimestamp() public {
        bytes32 sid = _subscribe();
        _warpPeriod();

        uint48 ts = uint48(block.timestamp);
        subscriptionModule.processRenewalFor(user, sid);

        (, , SubscriptionPermission memory rp) = subscriptionRegistry.getRecord(sid);
        assertEq(rp.lastChargedAt, ts);
    }

    // ─── Crank query integration ───────────────────────────────────────────────

    function test_CrankQuery_FindsDueSubscriptions() public {
        bytes32 sid = _subscribe();

        // Not due yet
        (bytes32[] memory ids1, ) = subscriptionRegistry.getDueSubscriptions(0, 10);
        assertEq(ids1.length, 0);

        // Warp past period
        _warpPeriod();
        (bytes32[] memory ids2, ) = subscriptionRegistry.getDueSubscriptions(0, 10);
        assertEq(ids2.length, 1);
        assertEq(ids2[0], sid);

        // After renewal, no longer due
        subscriptionModule.processRenewalFor(user, sid);
        (bytes32[] memory ids3, ) = subscriptionRegistry.getDueSubscriptions(0, 10);
        assertEq(ids3.length, 0);
    }

    // ─── Fuzz: period boundary edge cases ─────────────────────────────────────

    function testFuzz_PeriodBoundary_ExactlyAtBoundary(uint32 extraSeconds) public {
        vm.assume(extraSeconds > 0 && extraSeconds < 365 days);
        bytes32 sid = _subscribe();

        // First renewal: warp to exactly periodSeconds from epoch (lastChargedAt=0)
        vm.warp(uint256(PLAN_PERIOD) + extraSeconds);
        subscriptionModule.processRenewalFor(user, sid);

        uint48 firstCharge = _getPermission(sid).lastChargedAt;

        // Second renewal: must be >= firstCharge + period
        vm.warp(uint256(firstCharge) + PLAN_PERIOD + 1);
        subscriptionModule.processRenewalFor(user, sid);

        assertGt(_getPermission(sid).lastChargedAt, firstCharge);
    }

    function testFuzz_SubscriptionId_Deterministic(
        address u,
        address m,
        bytes32 p,
        uint256 n
    ) public pure {
        bytes32 id1 = SubscriptionLib.deriveSubscriptionId(u, m, p, n);
        bytes32 id2 = SubscriptionLib.deriveSubscriptionId(u, m, p, n);
        assertEq(id1, id2);

        // Different nonce → different ID
        if (n < type(uint256).max) {
            bytes32 id3 = SubscriptionLib.deriveSubscriptionId(u, m, p, n + 1);
            assertTrue(id3 != id1);
        }
    }

    // ─── Insufficient balance handling ────────────────────────────────────────

    function test_InsufficientBalance_EmitsFailedEvent() public {
        bytes32 sid = _subscribe();
        _warpPeriod();

        // Drain user's token balance
        uint256 bal = token.balanceOf(user);
        vm.prank(user);
        token.transfer(makeAddr("drain"), bal);

        // Renewal should NOT revert — it emits SubscriptionFailed and handles gracefully
        // (M-03 fix: processRenewal catches transfer failures instead of reverting)
        vm.expectEmit(true, false, false, false);
        emit ISubscriptionModule.SubscriptionFailed(sid, 1, "");
        subscriptionModule.processRenewalFor(user, sid);

        // Subscription should still be Active (not yet in GracePeriod after 1 failure)
        SubscriptionPermission memory p = subscriptionModule.getSubscriptionFor(user, sid);
        assertEq(uint8(p.status), uint8(SubscriptionStatus.Active));
    }

    // ─── Re-subscription after cancel ─────────────────────────────────────────

    function test_Resubscribe_AfterCancel_GetsFreshPermission() public {
        bytes32 sid1 = _subscribe();
        _warpPeriod();
        subscriptionModule.processRenewalFor(user, sid1);

        vm.prank(user);
        subscriptionModule.cancel(sid1);

        // Re-subscribe (new nonce → new subscriptionId)
        bytes32 sid2 = _subscribe();
        assertTrue(sid1 != sid2);

        SubscriptionPermission memory p2 = _getPermission(sid2);
        assertEq(p2.lastChargedAt, 0);    // fresh — no previous charges
        assertEq(uint8(p2.status), uint8(SubscriptionStatus.Active));
    }

    // ─── Wallet visibility ────────────────────────────────────────────────────

    function test_WalletVisibility_CrossAccountAggregation() public {
        // Subscribe as user
        bytes32 sid = _subscribe();

        // Wallet queries registry (cross-account aggregation)
        (bytes32[] memory ids, SubscriptionPermission[] memory perms) =
            subscriptionRegistry.getActiveSubscriptionsForWallet(user);
        assertEq(ids.length, 1);
        assertEq(ids[0], sid);
        assertEq(perms[0].merchant, receiver);
        assertEq(perms[0].maxAmount, PLAN_AMOUNT);
    }
}
