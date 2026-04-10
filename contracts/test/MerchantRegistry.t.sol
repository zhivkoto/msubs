// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { MerchantRegistry } from "../src/MerchantRegistry.sol";
import { IMerchantRegistry } from "../src/interfaces/IMerchantRegistry.sol";
import { Plan, Merchant, SubscriptionLib } from "../src/libraries/SubscriptionLib.sol";
import { MockERC20 } from "./helpers/MockERC20.sol";

contract MerchantRegistryTest is Test {

    MerchantRegistry internal reg;
    MockERC20        internal token;

    address internal authority = makeAddr("authority");
    address internal receiver  = makeAddr("receiver");

    function setUp() public {
        reg   = new MerchantRegistry(address(this)); // address(this) = feeAdmin
        token = new MockERC20("USDC", "USDC", 6);
    }

    // ─── registerMerchant ─────────────────────────────────────────────────────

    function test_RegisterMerchant_Success() public {
        vm.prank(authority);
        bytes32 mId = reg.registerMerchant(receiver, "https://hook.example.com");

        assertEq(mId, keccak256(abi.encode(receiver)));

        Merchant memory m = reg.getMerchant(mId);
        assertEq(m.receiver,  receiver);
        assertEq(m.feeTier,   0);
        assertEq(m.webhookUrl, "https://hook.example.com");
        assertTrue(m.active);
        assertTrue(reg.isMerchantAuthority(mId, authority));
    }

    function test_RegisterMerchant_EmitsEvent() public {
        vm.prank(authority);
        vm.expectEmit(true, true, true, false);
        emit IMerchantRegistry.MerchantRegistered(keccak256(abi.encode(receiver)), receiver, authority);
        reg.registerMerchant(receiver, "");
    }

    function test_RegisterMerchant_RevertZeroReceiver() public {
        vm.prank(authority);
        vm.expectRevert(SubscriptionLib.InvalidMerchantReceiver.selector);
        reg.registerMerchant(address(0), "");
    }

    function test_RegisterMerchant_RevertDuplicateReceiver() public {
        vm.prank(authority);
        reg.registerMerchant(receiver, "");

        address auth2 = makeAddr("auth2");
        vm.prank(auth2);
        vm.expectRevert(abi.encodeWithSelector(MerchantRegistry.MerchantAlreadyRegistered.selector, receiver));
        reg.registerMerchant(receiver, "");
    }

    function test_RegisterMerchant_RevertAuthorityAlreadyHasMerchant() public {
        address receiver2 = makeAddr("receiver2");
        vm.prank(authority);
        reg.registerMerchant(receiver, "");

        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(MerchantRegistry.AuthorityAlreadyHasMerchant.selector, authority));
        reg.registerMerchant(receiver2, "");
    }

    // ─── registerPlan ─────────────────────────────────────────────────────────

    function test_RegisterPlan_Success() public {
        vm.prank(authority);
        reg.registerMerchant(receiver, "");

        vm.prank(authority);
        bytes32 pId = reg.registerPlan(address(token), 10e6, 30 days, "Pro");

        assertEq(pId, keccak256(abi.encode(authority, "Pro")));

        Plan memory p = reg.getPlan(pId);
        assertEq(p.merchant, receiver);
        assertEq(p.token,    address(token));
        assertEq(p.amount,   10e6);
        assertEq(p.period,   30 days);
        assertEq(p.name,     "Pro");
        assertTrue(p.active);
    }

    function test_RegisterPlan_EmitsEvent() public {
        vm.prank(authority);
        reg.registerMerchant(receiver, "");

        bytes32 expectedPlanId = keccak256(abi.encode(authority, "Pro"));
        vm.prank(authority);
        vm.expectEmit(true, true, false, true);
        emit IMerchantRegistry.PlanRegistered(expectedPlanId, receiver, address(token), 10e6, 30 days);
        reg.registerPlan(address(token), 10e6, 30 days, "Pro");
    }

    function test_RegisterPlan_RevertNotAuthority() public {
        vm.prank(authority);
        reg.registerMerchant(receiver, "");

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(MerchantRegistry.NotMerchantAuthority.selector);
        reg.registerPlan(address(token), 10e6, 30 days, "Pro");
    }

    function test_RegisterPlan_RevertZeroToken() public {
        vm.prank(authority);
        reg.registerMerchant(receiver, "");

        vm.prank(authority);
        vm.expectRevert(SubscriptionLib.InvalidToken.selector);
        reg.registerPlan(address(0), 10e6, 30 days, "Pro");
    }

    function test_RegisterPlan_RevertZeroAmount() public {
        vm.prank(authority);
        reg.registerMerchant(receiver, "");

        vm.prank(authority);
        vm.expectRevert(SubscriptionLib.InvalidAmount.selector);
        reg.registerPlan(address(token), 0, 30 days, "Pro");
    }

    function test_RegisterPlan_RevertZeroPeriod() public {
        vm.prank(authority);
        reg.registerMerchant(receiver, "");

        vm.prank(authority);
        vm.expectRevert(SubscriptionLib.InvalidPeriod.selector);
        reg.registerPlan(address(token), 10e6, 0, "Pro");
    }

    function test_RegisterPlan_RevertDuplicate() public {
        vm.prank(authority);
        reg.registerMerchant(receiver, "");

        vm.prank(authority);
        reg.registerPlan(address(token), 10e6, 30 days, "Pro");

        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(
            MerchantRegistry.PlanAlreadyRegistered.selector,
            keccak256(abi.encode(authority, "Pro"))
        ));
        reg.registerPlan(address(token), 20e6, 60 days, "Pro");
    }

    function test_RegisterPlan_RevertNameTooLong() public {
        vm.prank(authority);
        reg.registerMerchant(receiver, "");

        string memory longName = "this_name_is_way_too_long_for_a_plan_name_and_exceeds_64_bytes_limit_xyz";
        vm.prank(authority);
        vm.expectRevert(SubscriptionLib.InvalidPlanName.selector); // dedicated error (was InvalidAmount before fix)
        reg.registerPlan(address(token), 10e6, 30 days, longName);
    }

    function test_MultiplePlans_SameMerchant() public {
        vm.prank(authority);
        reg.registerMerchant(receiver, "");

        vm.prank(authority);
        bytes32 p1 = reg.registerPlan(address(token), 10e6, 30 days, "Basic");
        vm.prank(authority);
        bytes32 p2 = reg.registerPlan(address(token), 50e6, 30 days, "Pro");

        assertTrue(p1 != p2);
        assertEq(reg.getPlan(p1).amount, 10e6);
        assertEq(reg.getPlan(p2).amount, 50e6);
    }

    // ─── deprecatePlan ────────────────────────────────────────────────────────

    function test_DeprecatePlan_Success() public {
        vm.prank(authority);
        reg.registerMerchant(receiver, "");

        vm.prank(authority);
        bytes32 pId = reg.registerPlan(address(token), 10e6, 30 days, "Pro");

        vm.prank(authority);
        vm.expectEmit(true, false, false, false);
        emit IMerchantRegistry.PlanDeprecated(pId);
        reg.deprecatePlan(pId);

        assertFalse(reg.getPlan(pId).active);
    }

    function test_DeprecatePlan_RevertUnauthorized() public {
        vm.prank(authority);
        reg.registerMerchant(receiver, "");

        vm.prank(authority);
        bytes32 pId = reg.registerPlan(address(token), 10e6, 30 days, "Pro");

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        reg.deprecatePlan(pId);
    }

    function test_DeprecatePlan_RevertNotFound() public {
        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLib.PlanNotFound.selector, bytes32(keccak256("nonexistent"))));
        reg.deprecatePlan(keccak256("nonexistent"));
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function test_GetMerchantIdByReceiver() public {
        vm.prank(authority);
        bytes32 mId = reg.registerMerchant(receiver, "");

        assertEq(reg.getMerchantIdByReceiver(receiver), mId);
        assertEq(reg.getMerchantIdByReceiver(makeAddr("unknown")), bytes32(0));
    }

    function test_GetMerchantIdByAuthority() public {
        vm.prank(authority);
        bytes32 mId = reg.registerMerchant(receiver, "");

        assertEq(reg.getMerchantIdByAuthority(authority), mId);
    }

    // ─── Fuzz tests ───────────────────────────────────────────────────────────

    function testFuzz_RegisterMerchant_AnyValidReceiver(address recv) public {
        vm.assume(recv != address(0));
        address auth = makeAddr("auth_fuzz");
        vm.assume(reg.getMerchantIdByReceiver(recv) == bytes32(0));

        vm.prank(auth);
        bytes32 mId = reg.registerMerchant(recv, "");
        assertEq(mId, keccak256(abi.encode(recv)));
    }

    function testFuzz_RegisterPlan_AnyValidParams(
        uint256 amount,
        uint32  period
    ) public {
        vm.assume(amount > 0 && amount < type(uint128).max);
        vm.assume(period > 0);

        vm.prank(authority);
        reg.registerMerchant(receiver, "");

        vm.prank(authority);
        bytes32 pId = reg.registerPlan(address(token), amount, period, "Fuzz Plan");
        assertEq(reg.getPlan(pId).amount, amount);
        assertEq(reg.getPlan(pId).period, period);
    }
}
