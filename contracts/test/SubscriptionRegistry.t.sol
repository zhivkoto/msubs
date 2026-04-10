// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { SubscriptionRegistry } from "../src/SubscriptionRegistry.sol";
import { ISubscriptionRegistry } from "../src/interfaces/ISubscriptionRegistry.sol";
import {
    SubscriptionPermission,
    SubscriptionStatus,
    SubscriptionLib
} from "../src/libraries/SubscriptionLib.sol";
import { MockERC20 } from "./helpers/MockERC20.sol";

contract SubscriptionRegistryTest is Test {

    SubscriptionRegistry internal reg;
    MockERC20             internal token;

    address internal module   = makeAddr("module");
    address internal user     = makeAddr("user");
    address internal merchant = makeAddr("merchant");

    bytes32 internal subscriptionId = keccak256("sub1");

    SubscriptionPermission internal basePerm;

    function setUp() public {
        reg   = new SubscriptionRegistry(address(this)); // address(this) = moduleAdmin
        token = new MockERC20("USDC", "USDC", 6);
        // Authorize the mock module to call register()
        reg.setAuthorizedModule(module, true);

        basePerm = SubscriptionPermission({
            token:         address(token),
            merchant:      merchant,
            maxAmount:     10e6,
            periodSeconds: 30 days,
            startTime:     uint48(block.timestamp),
            lastChargedAt: 0,
            expiresAt:     0,
            status:        SubscriptionStatus.Active,
            planId:        keccak256("plan1"),
            sessionKey:    makeAddr("sessionKey")
        });
    }

    // ─── register ─────────────────────────────────────────────────────────────

    function test_Register_Success() public {
        vm.prank(module);
        reg.register(subscriptionId, user, basePerm);

        (address rUser, address rModule, SubscriptionPermission memory p) = reg.getRecord(subscriptionId);
        assertEq(rUser,  user);
        assertEq(rModule, module);
        assertEq(p.merchant, merchant);
        assertEq(p.maxAmount, 10e6);
    }

    function test_Register_EmitsEvent() public {
        vm.prank(module);
        vm.expectEmit(true, true, true, false);
        emit ISubscriptionRegistry.SubscriptionRegistered(subscriptionId, user, merchant);
        reg.register(subscriptionId, user, basePerm);
    }

    function test_Register_UpdatesUserIndex() public {
        vm.prank(module);
        reg.register(subscriptionId, user, basePerm);

        bytes32[] memory ids = reg.getSubscriptionsByUser(user);
        assertEq(ids.length, 1);
        assertEq(ids[0], subscriptionId);
    }

    function test_Register_UpdatesMerchantIndex() public {
        vm.prank(module);
        reg.register(subscriptionId, user, basePerm);

        bytes32[] memory ids = reg.getSubscriptionsByMerchant(merchant);
        assertEq(ids.length, 1);
        assertEq(ids[0], subscriptionId);
    }

    function test_Register_IncrementsTotalCount() public {
        assertEq(reg.totalSubscriptions(), 0);
        vm.prank(module);
        reg.register(subscriptionId, user, basePerm);
        assertEq(reg.totalSubscriptions(), 1);
    }

    function test_Register_RevertDuplicate() public {
        vm.prank(module);
        reg.register(subscriptionId, user, basePerm);

        vm.prank(module);
        vm.expectRevert(abi.encodeWithSelector(
            SubscriptionRegistry.SubscriptionAlreadyRegistered.selector, subscriptionId
        ));
        reg.register(subscriptionId, user, basePerm);
    }

    function test_Register_RevertZeroUser() public {
        vm.prank(module);
        vm.expectRevert(SubscriptionLib.ZeroAddress.selector);
        reg.register(subscriptionId, address(0), basePerm);
    }

    // ─── updateStatus ─────────────────────────────────────────────────────────

    function test_UpdateStatus_Success() public {
        vm.prank(module);
        reg.register(subscriptionId, user, basePerm);

        vm.prank(module);
        reg.updateStatus(subscriptionId, uint8(SubscriptionStatus.Paused));

        (, , SubscriptionPermission memory p) = reg.getRecord(subscriptionId);
        assertEq(uint8(p.status), uint8(SubscriptionStatus.Paused));
    }

    function test_UpdateStatus_EmitsEvent() public {
        vm.prank(module);
        reg.register(subscriptionId, user, basePerm);

        vm.prank(module);
        vm.expectEmit(true, false, false, true);
        emit ISubscriptionRegistry.StatusUpdated(subscriptionId, uint8(SubscriptionStatus.Cancelled));
        reg.updateStatus(subscriptionId, uint8(SubscriptionStatus.Cancelled));
    }

    function test_UpdateStatus_RevertNotModule() public {
        vm.prank(module);
        reg.register(subscriptionId, user, basePerm);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(
            SubscriptionRegistry.UnauthorizedModule.selector, subscriptionId, stranger, module
        ));
        reg.updateStatus(subscriptionId, uint8(SubscriptionStatus.Cancelled));
    }

    function test_UpdateStatus_RevertNotRegistered() public {
        vm.prank(module);
        vm.expectRevert(abi.encodeWithSelector(
            SubscriptionRegistry.SubscriptionNotRegistered.selector, subscriptionId
        ));
        reg.updateStatus(subscriptionId, uint8(SubscriptionStatus.Cancelled));
    }

    // ─── recordCharge ─────────────────────────────────────────────────────────

    function test_RecordCharge_Success() public {
        vm.prank(module);
        reg.register(subscriptionId, user, basePerm);

        uint48 ts = uint48(block.timestamp + 100);
        vm.prank(module);
        reg.recordCharge(subscriptionId, ts, 10e6);

        (, , SubscriptionPermission memory p) = reg.getRecord(subscriptionId);
        assertEq(p.lastChargedAt, ts);
    }

    function test_RecordCharge_EmitsEvent() public {
        vm.prank(module);
        reg.register(subscriptionId, user, basePerm);

        vm.prank(module);
        vm.expectEmit(true, false, false, true);
        emit ISubscriptionRegistry.ChargeRecorded(subscriptionId, uint48(1000), 10e6);
        reg.recordCharge(subscriptionId, uint48(1000), 10e6);
    }

    function test_RecordCharge_RevertUnauthorized() public {
        vm.prank(module);
        reg.register(subscriptionId, user, basePerm);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(
            SubscriptionRegistry.UnauthorizedModule.selector, subscriptionId, stranger, module
        ));
        reg.recordCharge(subscriptionId, uint48(1000), 10e6);
    }

    // ─── getDueSubscriptions ──────────────────────────────────────────────────

    function test_GetDueSubscriptions_EmptyOnFreshSub() public {
        vm.prank(module);
        reg.register(subscriptionId, user, basePerm);

        // Not yet due: first charge requires startTime + periodSeconds
        // basePerm.startTime = block.timestamp at setUp; warp to 1s after that is not enough
        vm.warp(1);
        (bytes32[] memory ids, uint256 next) = reg.getDueSubscriptions(0, 10);
        // block.timestamp(1) < startTime + periodSeconds, so not due
        assertEq(ids.length, 0);
        assertEq(next, type(uint256).max); // no more pages
    }

    function test_GetDueSubscriptions_DueAfterPeriod() public {
        vm.prank(module);
        reg.register(subscriptionId, user, basePerm);

        // Warp past period
        vm.warp(uint256(basePerm.periodSeconds) + 1);
        (bytes32[] memory ids, ) = reg.getDueSubscriptions(0, 10);
        assertEq(ids.length, 1);
        assertEq(ids[0], subscriptionId);
    }

    function test_GetDueSubscriptions_NotDueWhenPaused() public {
        vm.prank(module);
        reg.register(subscriptionId, user, basePerm);
        vm.prank(module);
        reg.updateStatus(subscriptionId, uint8(SubscriptionStatus.Paused));

        vm.warp(uint256(basePerm.periodSeconds) + 1);
        (bytes32[] memory ids, ) = reg.getDueSubscriptions(0, 10);
        assertEq(ids.length, 0);
    }

    function test_GetDueSubscriptions_NotDueAfterExpiry() public {
        // Set expiresAt in the past
        basePerm.expiresAt = uint48(1); // expired at timestamp 1
        bytes32 sid2 = keccak256("sub2");
        vm.prank(module);
        reg.register(sid2, user, basePerm);

        vm.warp(uint256(basePerm.periodSeconds) + 1);
        (bytes32[] memory ids, ) = reg.getDueSubscriptions(0, 10);
        assertEq(ids.length, 0);
    }

    function test_GetDueSubscriptions_Pagination() public {
        // Register 5 subscriptions, all due
        for (uint256 i = 0; i < 5; i++) {
            bytes32 sid = keccak256(abi.encode("sub", i));
            vm.prank(module);
            reg.register(sid, user, basePerm);
        }

        vm.warp(uint256(basePerm.periodSeconds) + 1);

        // Page 1: limit 3
        (bytes32[] memory page1, uint256 cursor1) = reg.getDueSubscriptions(0, 3);
        assertEq(page1.length, 3);
        assertTrue(cursor1 > 0);

        // Page 2: remaining
        (bytes32[] memory page2, uint256 cursor2) = reg.getDueSubscriptions(cursor1, 3);
        assertEq(page2.length, 2);
        assertEq(cursor2, type(uint256).max); // no more pages (sentinel = max uint256)
    }

    // ─── getActiveSubscriptionsForWallet ─────────────────────────────────────

    function test_GetActiveSubscriptionsForWallet() public {
        vm.prank(module);
        reg.register(subscriptionId, user, basePerm);

        (bytes32[] memory ids, SubscriptionPermission[] memory perms) =
            reg.getActiveSubscriptionsForWallet(user);
        assertEq(ids.length, 1);
        assertEq(ids[0], subscriptionId);
        assertEq(perms[0].merchant, merchant);
    }

    function test_GetActiveSubscriptionsForWallet_ExcludesCancelled() public {
        vm.prank(module);
        reg.register(subscriptionId, user, basePerm);
        vm.prank(module);
        reg.updateStatus(subscriptionId, uint8(SubscriptionStatus.Cancelled));

        (bytes32[] memory ids, ) = reg.getActiveSubscriptionsForWallet(user);
        assertEq(ids.length, 0);
    }

    function test_GetActiveSubscriptionsForWallet_IncludesPaused() public {
        vm.prank(module);
        reg.register(subscriptionId, user, basePerm);
        vm.prank(module);
        reg.updateStatus(subscriptionId, uint8(SubscriptionStatus.Paused));

        (bytes32[] memory ids, ) = reg.getActiveSubscriptionsForWallet(user);
        assertEq(ids.length, 1);
    }

    function test_GetActiveSubscriptionsForWallet_IncludesGracePeriod() public {
        vm.prank(module);
        reg.register(subscriptionId, user, basePerm);
        vm.prank(module);
        reg.updateStatus(subscriptionId, uint8(SubscriptionStatus.GracePeriod));

        (bytes32[] memory ids, ) = reg.getActiveSubscriptionsForWallet(user);
        assertEq(ids.length, 1);
    }

    // ─── getRecord ────────────────────────────────────────────────────────────

    function test_GetRecord_RevertNotRegistered() public {
        vm.expectRevert(abi.encodeWithSelector(
            SubscriptionRegistry.SubscriptionNotRegistered.selector, subscriptionId
        ));
        reg.getRecord(subscriptionId);
    }
}
