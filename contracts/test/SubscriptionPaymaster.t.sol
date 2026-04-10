// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { SubscriptionPaymaster } from "../src/SubscriptionPaymaster.sol";
import { SubscriptionRegistry }  from "../src/SubscriptionRegistry.sol";
import { MerchantRegistry }      from "../src/MerchantRegistry.sol";
import { SubscriptionModule }    from "../src/SubscriptionModule.sol";
import {
    SubscriptionPermission,
    SubscriptionStatus,
    SubscriptionLib
} from "../src/libraries/SubscriptionLib.sol";
import { MockERC20 } from "./helpers/MockERC20.sol";

import { IPaymaster } from "account-abstraction/interfaces/IPaymaster.sol";
import { PackedUserOperation } from "account-abstraction/interfaces/PackedUserOperation.sol";

/// @dev Minimal mock EntryPoint for paymaster testing.
contract MockEntryPoint {
    mapping(address => uint256) private _deposits;
    mapping(address => uint256) private _stakes;

    function depositTo(address pm) external payable {
        _deposits[pm] += msg.value;
    }

    function balanceOf(address pm) external view returns (uint256) {
        return _deposits[pm];
    }

    function withdrawTo(address payable to, uint256 amount) external {
        require(_deposits[msg.sender] >= amount, "insufficient");
        _deposits[msg.sender] -= amount;
        to.transfer(amount);
    }

    function addStake(uint32) external payable {
        _stakes[msg.sender] += msg.value;
    }

    function unlockStake() external { }

    function withdrawStake(address payable to) external {
        uint256 amt = _stakes[msg.sender];
        _stakes[msg.sender] = 0;
        to.transfer(amt);
    }

    receive() external payable { }
}

contract SubscriptionPaymasterTest is Test {

    MockEntryPoint       internal entryPoint;
    SubscriptionRegistry internal registry;
    MerchantRegistry     internal merchantReg;
    SubscriptionModule   internal module;
    SubscriptionPaymaster internal paymaster;
    MockERC20            internal token;

    address internal owner      = makeAddr("owner");
    address internal user       = makeAddr("user");
    address internal receiver   = makeAddr("receiver");
    address internal authority  = makeAddr("authority");
    address internal treasury   = makeAddr("treasury");
    address internal sessionKey = makeAddr("sessionKey");

    bytes32 internal planId;
    bytes32 internal subscriptionId;

    function setUp() public {
        entryPoint  = new MockEntryPoint();
        registry    = new SubscriptionRegistry(address(this)); // moduleAdmin
        merchantReg = new MerchantRegistry(address(this));     // feeAdmin
        token       = new MockERC20("USDC", "USDC", 6);

        module = new SubscriptionModule(
            address(registry),
            address(merchantReg),
            treasury
        );

        // Authorize module to register subscriptions
        registry.setAuthorizedModule(address(module), true);

        // Deploy paymaster with owner
        vm.prank(owner);
        paymaster = new SubscriptionPaymaster(
            address(entryPoint),
            address(registry)
        );

        // Setup merchant & plan
        vm.prank(authority);
        merchantReg.registerMerchant(receiver, "");
        vm.prank(authority);
        planId = merchantReg.registerPlan(address(token), 10e6, 30 days, "Pro");

        // Setup user subscription
        vm.prank(user);
        module.onInstall(bytes(""));
        token.mint(user, 1000e6);
        vm.prank(user);
        token.approve(address(module), type(uint256).max);
        vm.warp(1); // set a non-zero timestamp before subscribing
        vm.prank(user);
        subscriptionId = module.subscribe(planId, sessionKey, 0);

        // Fund paymaster
        vm.deal(owner, 10 ether);
        vm.prank(owner);
        paymaster.deposit{value: 1 ether}();
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    function test_Constructor_SetsEntryPoint() public view {
        assertEq(address(paymaster.entryPoint()), address(entryPoint));
    }

    function test_Constructor_SetsRegistry() public view {
        assertEq(address(paymaster.registry()), address(registry));
    }

    function test_Constructor_RevertZeroEntryPoint() public {
        vm.expectRevert(SubscriptionLib.ZeroAddress.selector);
        new SubscriptionPaymaster(address(0), address(registry));
    }

    function test_Constructor_RevertZeroRegistry() public {
        vm.expectRevert(SubscriptionLib.ZeroAddress.selector);
        new SubscriptionPaymaster(address(entryPoint), address(0));
    }

    // ─── deposit / balance ────────────────────────────────────────────────────

    function test_Deposit_IncreasesBalance() public {
        uint256 before = paymaster.balance();
        vm.deal(address(this), 1 ether);
        paymaster.deposit{value: 0.5 ether}();
        assertEq(paymaster.balance(), before + 0.5 ether);
    }

    // ─── setDailyBudget ───────────────────────────────────────────────────────

    function test_SetDailyBudget_ByOwner() public {
        vm.prank(owner);
        paymaster.setDailyBudget(0.1 ether);
        assertEq(paymaster.dailyBudgetWei(), 0.1 ether);
    }

    function test_SetDailyBudget_RevertNonOwner() public {
        vm.prank(user);
        vm.expectRevert();
        paymaster.setDailyBudget(0.1 ether);
    }

    // ─── remainingBudget ──────────────────────────────────────────────────────

    function test_RemainingBudget_FullOnFreshWindow() public view {
        assertEq(paymaster.remainingBudget(user), paymaster.DEFAULT_DAILY_BUDGET());
    }

    // ─── validatePaymasterUserOp ──────────────────────────────────────────────

    function _buildUserOp(bytes4 sel, bytes memory args, address sender) internal pure returns (PackedUserOperation memory) {
        PackedUserOperation memory uop;
        uop.sender   = sender;
        uop.callData = abi.encodePacked(sel, args);
        return uop;
    }

    function test_ValidatePaymasterUserOp_AllowsProcessRenewal() public {
        bytes memory callData = abi.encodeWithSelector(
            bytes4(keccak256("processRenewal(bytes32)")),
            subscriptionId
        );

        PackedUserOperation memory uop;
        uop.sender   = user;
        uop.callData = callData;

        // Warp so the subscription is not "too early"
        vm.warp(block.timestamp + 31 days);

        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(uop, bytes32(0), 0.001 ether);

        assertEq(validationData, 0);
        assertTrue(context.length > 0);
    }

    function test_ValidatePaymasterUserOp_AllowsSubscribe() public {
        bytes memory callData = abi.encodeWithSelector(
            bytes4(keccak256("subscribe(bytes32,address,uint48)")),
            planId,
            sessionKey,
            uint48(0)
        );

        PackedUserOperation memory uop;
        uop.sender   = user;
        uop.callData = callData;

        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(uop, bytes32(0), 0.001 ether);
        assertEq(validationData, 0);
        assertTrue(context.length > 0);
    }

    function test_ValidatePaymasterUserOp_RejectUnknownSelector() public {
        PackedUserOperation memory uop;
        uop.sender   = user;
        uop.callData = abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), user, 100);

        vm.prank(address(entryPoint));
        vm.expectRevert(abi.encodeWithSelector(
            SubscriptionPaymaster.SelectorNotAllowlisted.selector,
            bytes4(keccak256("transfer(address,uint256)"))
        ));
        paymaster.validatePaymasterUserOp(uop, bytes32(0), 0.001 ether);
    }

    function test_ValidatePaymasterUserOp_RejectEmptyCallData() public {
        PackedUserOperation memory uop;
        uop.sender   = user;
        uop.callData = bytes("");

        vm.prank(address(entryPoint));
        vm.expectRevert(abi.encodeWithSelector(SubscriptionPaymaster.SelectorNotAllowlisted.selector, bytes4(0)));
        paymaster.validatePaymasterUserOp(uop, bytes32(0), 0.001 ether);
    }

    function test_ValidatePaymasterUserOp_RevertCallerNotEntryPoint() public {
        PackedUserOperation memory uop;
        uop.sender = user;
        uop.callData = abi.encodeWithSelector(bytes4(keccak256("cancel(bytes32)")), subscriptionId);

        vm.expectRevert(abi.encodeWithSelector(
            SubscriptionPaymaster.CallerNotEntryPoint.selector,
            address(this),
            address(entryPoint)
        ));
        paymaster.validatePaymasterUserOp(uop, bytes32(0), 0.001 ether);
    }

    function test_ValidatePaymasterUserOp_RejectExceedsDailyBudget() public {
        // Set budget to 0
        vm.prank(owner);
        paymaster.setDailyBudget(0);

        PackedUserOperation memory uop;
        uop.sender   = user;
        uop.callData = abi.encodeWithSelector(bytes4(keccak256("cancel(bytes32)")), subscriptionId);

        vm.prank(address(entryPoint));
        vm.expectRevert(abi.encodeWithSelector(
            SubscriptionPaymaster.DailyBudgetExceeded.selector,
            user, 0.001 ether, 0
        ));
        paymaster.validatePaymasterUserOp(uop, bytes32(0), 0.001 ether);
    }

    // ─── postOp ───────────────────────────────────────────────────────────────

    function test_PostOp_ReducesBudget() public {
        // Setup: approve a UserOp first
        bytes memory callData = abi.encodeWithSelector(
            bytes4(keccak256("cancel(bytes32)")),
            subscriptionId
        );
        PackedUserOperation memory uop;
        uop.sender   = user;
        uop.callData = callData;

        vm.prank(address(entryPoint));
        (bytes memory context, ) = paymaster.validatePaymasterUserOp(uop, bytes32(0), 0.001 ether);

        uint256 budgetBefore = paymaster.remainingBudget(user);

        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 0.0005 ether, 1 gwei);

        assertEq(paymaster.remainingBudget(user), budgetBefore - 0.0005 ether);
    }

    function test_PostOp_RevertCallerNotEntryPoint() public {
        vm.expectRevert(abi.encodeWithSelector(
            SubscriptionPaymaster.CallerNotEntryPoint.selector,
            address(this),
            address(entryPoint)
        ));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, bytes(""), 0, 0);
    }

    // ─── withdraw ────────────────────────────────────────────────────────────

    function test_Withdraw_RevertNonOwner() public {
        address payable to = payable(makeAddr("recipient"));
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        paymaster.withdraw(0.1 ether, to);
    }

    // ─── addStake ────────────────────────────────────────────────────────────

    function test_AddStake_ByOwner() public {
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        paymaster.addStake{value: 0.1 ether}(86400);
        // If it didn't revert, the call succeeded
    }

    // ─── Daily budget window reset ────────────────────────────────────────────

    function test_BudgetResetsAfterDay() public {
        // Consume some budget via postOp
        bytes memory callData = abi.encodeWithSelector(bytes4(keccak256("cancel(bytes32)")), subscriptionId);
        PackedUserOperation memory uop;
        uop.sender   = user;
        uop.callData = callData;

        vm.prank(address(entryPoint));
        (bytes memory context, ) = paymaster.validatePaymasterUserOp(uop, bytes32(0), 0.001 ether);
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 0.005 ether, 1 gwei);

        uint256 budgetMidDay = paymaster.remainingBudget(user);
        assertLt(budgetMidDay, paymaster.DEFAULT_DAILY_BUDGET());

        // Advance to next day
        vm.warp(block.timestamp + 86400 + 1);

        // Budget should be fully reset
        assertEq(paymaster.remainingBudget(user), paymaster.DEFAULT_DAILY_BUDGET());
    }
}
