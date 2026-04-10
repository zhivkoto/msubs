// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.28;

import { Script, console2 } from "forge-std/Script.sol";

import { MerchantRegistry }     from "../src/MerchantRegistry.sol";
import { SubscriptionRegistry } from "../src/SubscriptionRegistry.sol";
import { SubscriptionModule }   from "../src/SubscriptionModule.sol";
import { SubscriptionPaymaster } from "../src/SubscriptionPaymaster.sol";

/// @title Deploy
/// @notice Deployment script for the MIP Subscription Permissions reference implementation.
///         All constructor arguments are sourced from environment variables so that the
///         same script can target any network without modification.
///
/// @dev DO NOT deploy without first setting all required env vars:
///
///      Required:
///        DEPLOYER_PRIVATE_KEY   Private key of the deploying EOA.
///        TREASURY_ADDRESS       Protocol treasury receiving fee cuts.
///        ENTRY_POINT_ADDRESS    ERC-4337 EntryPoint v0.7 address on the target network.
///        FEE_ADMIN_ADDRESS      Address authorized to set merchant fee tiers via setFeeTier().
///        MODULE_ADMIN_ADDRESS   Address authorized to whitelist modules in SubscriptionRegistry.
///
///      Optional:
///        PAYMASTER_STAKE_AMOUNT Stake to add to EntryPoint (default: 0.1 ether).
///        PAYMASTER_UNSTAKE_DELAY Unstake delay in seconds (default: 86400).
///        PAYMASTER_DEPOSIT       Initial ETH deposit for gas sponsorship (default: 0.5 ether).
///
///      Run (dry-run):
///        forge script script/Deploy.s.sol --rpc-url $MONAD_TESTNET_RPC_URL --private-key $DEPLOYER_PRIVATE_KEY
///
///      Run (broadcast):
///        forge script script/Deploy.s.sol --rpc-url $MONAD_TESTNET_RPC_URL \
///          --private-key $DEPLOYER_PRIVATE_KEY --broadcast
contract Deploy is Script {

    function run() external {
        // ── Load env vars ─────────────────────────────────────────────────────
        uint256 deployerKey    = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address treasury       = vm.envAddress("TREASURY_ADDRESS");
        address entryPoint     = vm.envAddress("ENTRY_POINT_ADDRESS");
        address feeAdmin       = vm.envAddress("FEE_ADMIN_ADDRESS");
        address moduleAdmin    = vm.envAddress("MODULE_ADMIN_ADDRESS");

        uint256 stakeAmount    = vm.envOr("PAYMASTER_STAKE_AMOUNT",  uint256(0.1 ether));
        uint32  unstakeDelay   = uint32(vm.envOr("PAYMASTER_UNSTAKE_DELAY", uint256(86_400)));
        uint256 depositAmount  = vm.envOr("PAYMASTER_DEPOSIT",       uint256(0.5 ether));

        address deployer = vm.addr(deployerKey);

        console2.log("=== MIP Subscription Permissions Deployment ===");
        console2.log("Deployer:    ", deployer);
        console2.log("Treasury:    ", treasury);
        console2.log("EntryPoint:  ", entryPoint);
        console2.log("FeeAdmin:    ", feeAdmin);
        console2.log("ModuleAdmin: ", moduleAdmin);
        console2.log("Chain ID:    ", block.chainid);

        vm.startBroadcast(deployerKey);

        // ── 1. MerchantRegistry ───────────────────────────────────────────────
        MerchantRegistry merchantRegistry = new MerchantRegistry(feeAdmin);
        console2.log("MerchantRegistry:     ", address(merchantRegistry));

        // ── 2. SubscriptionRegistry ───────────────────────────────────────────
        SubscriptionRegistry subscriptionRegistry = new SubscriptionRegistry(moduleAdmin);
        console2.log("SubscriptionRegistry: ", address(subscriptionRegistry));

        // ── 3. SubscriptionModule ─────────────────────────────────────────────
        SubscriptionModule subscriptionModule = new SubscriptionModule(
            address(subscriptionRegistry),
            address(merchantRegistry),
            treasury
        );
        console2.log("SubscriptionModule:   ", address(subscriptionModule));

        // ── 4. SubscriptionPaymaster ──────────────────────────────────────────
        SubscriptionPaymaster paymaster = new SubscriptionPaymaster(
            entryPoint,
            address(subscriptionRegistry)
        );
        console2.log("SubscriptionPaymaster:", address(paymaster));

        // ── 5. Fund & stake paymaster ─────────────────────────────────────────
        if (stakeAmount > 0) {
            paymaster.addStake{ value: stakeAmount }(unstakeDelay);
            console2.log("Staked (wei):", stakeAmount);
            console2.log("Unstake delay (sec):", unstakeDelay);
        }

        if (depositAmount > 0) {
            paymaster.deposit{ value: depositAmount }();
            console2.log("Deposited:", depositAmount, "wei for gas sponsorship");
        }

        vm.stopBroadcast();

        // ── Summary ───────────────────────────────────────────────────────────
        console2.log("");
        console2.log("=== Deployment Complete ===");
        console2.log("Next step: moduleAdmin must call:");
        console2.log("  subscriptionRegistry.setAuthorizedModule(subscriptionModule, true)");
        console2.log("Add these to your .env / deployment config:");
        console2.log("MERCHANT_REGISTRY=    ", address(merchantRegistry));
        console2.log("SUBSCRIPTION_REGISTRY=", address(subscriptionRegistry));
        console2.log("SUBSCRIPTION_MODULE=  ", address(subscriptionModule));
        console2.log("SUBSCRIPTION_PAYMASTER=", address(paymaster));
    }
}
