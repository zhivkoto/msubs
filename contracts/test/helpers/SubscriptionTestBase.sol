// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { MockERC20 }           from "./MockERC20.sol";
import { MerchantRegistry }     from "../../src/MerchantRegistry.sol";
import { SubscriptionRegistry } from "../../src/SubscriptionRegistry.sol";
import { SubscriptionModule }   from "../../src/SubscriptionModule.sol";
import {
    SubscriptionPermission,
    SubscriptionStatus,
    Plan,
    Merchant,
    SubscriptionLib
} from "../../src/libraries/SubscriptionLib.sol";

/// @dev Base test contract with shared setup and helpers.
abstract contract SubscriptionTestBase is Test {

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 internal constant USDC_DECIMALS = 6;
    uint256 internal constant PLAN_AMOUNT   = 10e6;   // 10 USDC
    uint32  internal constant PLAN_PERIOD   = 30 days;
    string  internal constant PLAN_NAME     = "Pro Monthly";

    // ─── Actors ───────────────────────────────────────────────────────────────

    address internal treasury    = makeAddr("treasury");
    address internal merchantEOA = makeAddr("merchant");   // authority for merchant
    address internal receiver    = makeAddr("receiver");   // fund recipient
    address internal user        = makeAddr("user");       // smart account (simulated)
    address internal sessionKey  = makeAddr("sessionKey");
    uint256 internal sessionKeyPk;

    // ─── Contracts ────────────────────────────────────────────────────────────

    MockERC20           internal token;
    MerchantRegistry    internal merchantRegistry;
    SubscriptionRegistry internal subscriptionRegistry;
    SubscriptionModule  internal subscriptionModule;

    // ─── State ────────────────────────────────────────────────────────────────

    bytes32 internal merchantId;
    bytes32 internal planId;

    // ─── Setup ────────────────────────────────────────────────────────────────

    function setUp() public virtual {
        // Generate session key from deterministic private key
        sessionKeyPk = 0xdeadbeef1234;
        sessionKey = vm.addr(sessionKeyPk);

        // Deploy token
        token = new MockERC20("USD Coin", "USDC", uint8(USDC_DECIMALS));

        // Deploy core contracts
        // address(this) acts as feeAdmin and moduleAdmin in tests
        merchantRegistry     = new MerchantRegistry(address(this));
        subscriptionRegistry = new SubscriptionRegistry(address(this));
        subscriptionModule   = new SubscriptionModule(
            address(subscriptionRegistry),
            address(merchantRegistry),
            treasury
        );

        // Authorize the subscription module to call registry.register()
        subscriptionRegistry.setAuthorizedModule(address(subscriptionModule), true);

        // Register merchant
        vm.prank(merchantEOA);
        merchantId = merchantRegistry.registerMerchant(receiver, "https://merchant.example.com/webhook");

        // Register plan
        vm.prank(merchantEOA);
        planId = merchantRegistry.registerPlan(
            address(token),
            PLAN_AMOUNT,
            PLAN_PERIOD,
            PLAN_NAME
        );

        // Install module for user (simulates onInstall call from smart account)
        vm.prank(user);
        subscriptionModule.onInstall(bytes(""));

        // Fund user account with USDC and approve module
        token.mint(user, 1_000e6);
        vm.prank(user);
        token.approve(address(subscriptionModule), type(uint256).max);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    /// @dev Subscribe as user with default session key, no expiry.
    function _subscribe() internal returns (bytes32 subscriptionId) {
        vm.prank(user);
        subscriptionId = subscriptionModule.subscribe(planId, sessionKey, 0);
    }

    /// @dev Subscribe with custom params.
    function _subscribeWith(
        address sk,
        uint48  expiresAt
    ) internal returns (bytes32 subscriptionId) {
        vm.prank(user);
        subscriptionId = subscriptionModule.subscribe(planId, sk, expiresAt);
    }

    /// @dev Warp forward one full period plus one second.
    function _warpPeriod() internal {
        vm.warp(block.timestamp + PLAN_PERIOD + 1);
    }

    /// @dev Get permission snapshot for a user subscription.
    function _getPermission(bytes32 sid) internal view returns (SubscriptionPermission memory) {
        return subscriptionModule.getSubscriptionFor(user, sid);
    }
}
