# MIP Subscription Permissions - Reference Implementation

This directory contains the canonical Foundry reference implementation of the [MIP Subscription Permissions Standard](../MIP-subscription-permissions.md).

---

## Architecture Overview

```
contracts/src/
├── libraries/
│   └── SubscriptionLib.sol        # Shared types, EIP-712 hashing, error defs, sig recovery
├── interfaces/
│   ├── ISubscriptionModule.sol    # Core module interface + standard events
│   ├── ISubscriptionValidator.sol # Renewal validation hook
│   ├── ISubscriptionRegistry.sol  # Global registry interface
│   ├── IMerchantRegistry.sol      # Merchant/plan management interface
│   └── ISubscriptionPaymaster.sol # ERC-4337 paymaster interface
├── MerchantRegistry.sol           # Permissionless merchant + plan registry
├── SubscriptionRegistry.sol       # Global subscription index (no fund custody)
├── SubscriptionModule.sol         # Core ERC-7579 module (Validator + Executor)
└── SubscriptionPaymaster.sol      # ERC-4337 verifying paymaster
```

### Data Flow

```
User signs once →  SubscriptionModule.subscribe(planId, sessionKey, expiresAt)
                        ↓ validates plan in MerchantRegistry
                        ↓ stores SubscriptionPermission in account storage
                        ↓ registers in SubscriptionRegistry

Off-chain crank → SubscriptionRegistry.getDueSubscriptions(cursor, limit)
                        ↓ finds subscriptions where lastChargedAt + period ≤ now
                        ↓ submits UserOperation via ERC-4337 EntryPoint

EntryPoint → SubscriptionModule.processRenewalFor(account, subscriptionId)
                        ↓ checks: active, period elapsed, not expired
                        ↓ SafeERC20.transferFrom(account → merchant, netAmount)
                        ↓ SafeERC20.transferFrom(account → treasury, feeAmount)
                        ↓ registry.recordCharge(...)
                        ↓ emits SubscriptionCharged

SubscriptionPaymaster (validates gas sponsorship):
                        ↓ only sponsors allowlisted selectors
                        ↓ enforces per-user daily gas budget
                        ↓ rate-limits per subscription per period
```

### Contract Responsibilities

| Contract | Responsibility | Holds Funds? |
|---|---|---|
| `MerchantRegistry` | Plan & merchant config, immutable plan terms | No |
| `SubscriptionRegistry` | Global index, crank query, wallet view | No |
| `SubscriptionModule` | Core ERC-7579 module, renewal execution | No |
| `SubscriptionPaymaster` | Gas sponsorship for subscription UserOps | ETH only (for gas) |

**No contract holds user funds.** All token transfers are `safeTransferFrom` from the smart account directly to the merchant and treasury.

---

## Security Model

### Bounded Blast Radius
A compromised session key can only:
- Transfer `maxAmount` tokens per `periodSeconds` interval
- Transfer to the pre-specified `merchant` address only
- Interact with the pre-specified `token` only
- Cannot redirect funds, cannot charge more, cannot charge faster

### Checks-Effects-Interactions
All state changes occur before external calls (ERC-20 transfers).

### ReentrancyGuard
`processRenewal` and `processRenewalFor` are protected by `nonReentrant`.

### Access Control
- `subscribe`, `cancel`, `pause`, `resume`, `update`, `rotateSessionKey` - only callable by the smart account (msg.sender == account).
- `processRenewal` / `processRenewalFor` - permissionless; on-chain constraints are the security boundary.
- Registry writes - only callable by the module that registered the subscription.

---

## How to Build

### Prerequisites

- [Foundry](https://getfoundry.sh/) installed
- Solidity 0.8.28+ (managed by Foundry via `foundry.toml`)

### Install

```bash
cd contracts
forge install  # installs from lib/ (already committed)
```

Or to reinstall from scratch:

```bash
forge install OpenZeppelin/openzeppelin-contracts@v5.0.2 --no-git
forge install erc7579/erc7579-implementation --no-git
forge install eth-infinitism/account-abstraction@v0.7.0 --no-git
```

### Build

```bash
forge build
```

Expected output: `Compiler run successful!` with only lint warnings.

---

## How to Test

### Run all tests

```bash
forge test -vv
```

Expected: **128 tests, 0 failing**.

### Run specific test contract

```bash
forge test --match-contract MerchantRegistryTest -vv
forge test --match-contract SubscriptionRegistryTest -vv
forge test --match-contract SubscriptionModuleTest -vv
forge test --match-contract SubscriptionPaymasterTest -vv
forge test --match-contract IntegrationTest -vv
```

### Gas report

```bash
forge test --gas-report
```

> **Note:** The gas report may skip `SubscriptionPaymasterTest` due to a Foundry `--gas-report` + `via_ir` interaction with the MockEntryPoint in tests. All paymaster tests pass under `forge test`. Use `--no-match-contract SubscriptionPaymasterTest` for a clean gas table:

```bash
forge test --gas-report --no-match-contract SubscriptionPaymasterTest
```

### Coverage

```bash
forge coverage --ir-minimum
```

Expected: ~80% overall, 88-100% on core contracts.

| Contract | Line Coverage |
|---|---|
| MerchantRegistry | ~100% |
| SubscriptionRegistry | ~99% |
| SubscriptionModule | ~89% |
| SubscriptionPaymaster | ~81% |

---

## Deployment Instructions

### Prerequisites

Set required environment variables:

```bash
export DEPLOYER_PRIVATE_KEY=<your private key>
export TREASURY_ADDRESS=<protocol treasury address>
export ENTRY_POINT_ADDRESS=<ERC-4337 EntryPoint v0.7 address>
```

Optional:

```bash
export PAYMASTER_STAKE_AMOUNT=100000000000000000    # 0.1 ETH default
export PAYMASTER_UNSTAKE_DELAY=86400               # 1 day default
export PAYMASTER_DEPOSIT=500000000000000000        # 0.5 ETH default
```

### Dry run (no broadcast)

```bash
forge script script/Deploy.s.sol \
  --rpc-url $MONAD_TESTNET_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY
```

### Broadcast (real deployment)

```bash
forge script script/Deploy.s.sol \
  --rpc-url $MONAD_TESTNET_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast
```

### Deployment order

1. `MerchantRegistry` - no constructor args
2. `SubscriptionRegistry` - no constructor args
3. `SubscriptionModule` - args: `(registry, merchantRegistry, treasury)`
4. `SubscriptionPaymaster` - args: `(entryPoint, registry)`
5. Fund paymaster: `addStake` + `deposit`

---

## Monad-Specific Notes

### EIP-7702 Support

Monad mainnet natively supports EIP-7702. This enables EOA users to subscribe without migrating to a smart account. The `SubscriptionDelegate` pattern described in the MIP spec would be a separate contract (not included in this reference implementation) that delegates EIP-7702 code to EOAs.

### Gas Economics

Monad's gas costs (~$0.001/tx) make the `SubscriptionPaymaster` economically viable for subscriptions as small as $1/month. Protocol fee revenue from renewals can replenish the paymaster treasury.

### Parallel Execution

Monad's parallel execution engine handles concurrent renewal transactions efficiently. The registry's paginated `getDueSubscriptions` design is intentional - cranks can shard pages across parallel workers.

### EntryPoint Address

The ERC-4337 EntryPoint v0.7 address on Monad testnet should be verified via [Biconomy](https://docs.biconomy.io) or [Pimlico](https://docs.pimlico.io) documentation. The canonical EntryPoint v0.7 address on other EVM chains is `0x0000000071727De22E5E9d8BAf0edAc6f37da032`.

---

## Design Decisions

### 1. Concrete type imports over interfaces in core contracts

`SubscriptionModule` imports `SubscriptionRegistry` and `MerchantRegistry` directly (not via their interfaces) to access auxiliary view functions (`getRecord`, `getMerchantIdByReceiver`) not in the standard interface. This is a reference implementation trade-off - in a production deployment, these could be extended interfaces.

### 2. `_activePlanSubscription` mapping for duplicate prevention

Duplicate subscription detection uses a `account → planId → subscriptionId` mapping rather than re-deriving IDs. This cleanly handles the case where a user cancels and re-subscribes to the same plan (different nonce → different ID, but same plan).

### 3. validateRenewal called by smart account (not EntryPoint directly)

In ERC-7579, the smart account calls `validateUserOp` on the validator module, passing `msg.sender = account`. Tests simulate this with `vm.prank(user)`. In production, the EntryPoint calls `account.validateUserOp(...)` which internally calls `module.validateUserOp(...)`.

### 4. processRenewal is permissionless

Any address can call `processRenewalFor(account, subscriptionId)`. The security boundary is fully on-chain: period, amount cap, and active status. The crank is a liveness mechanism, not a trust assumption.

### 5. Fee calculation in processRenewal

Fee tier is looked up from `MerchantRegistry` at renewal time, not stored in the permission. This allows the protocol to adjust fee tiers without migrating existing subscriptions.

---

## Edge Cases Addressed

| Edge Case | Handling |
|---|---|
| First charge (lastChargedAt=0) | Period elapsed check: `lastChargedAt == 0` means no constraint on period |
| Hard expiry during renewal | `processRenewal` marks `Expired`, emits `SubscriptionExpired`, returns without charging |
| Re-subscribe after cancel | New nonce → new subscriptionId; fresh state |
| Upgrade preserves lastChargedAt | `update()` only changes planId/amount/period; no reset |
| Session key compromise | Bounded to `maxAmount` / `periodSeconds` / single `merchant`; user calls `rotateSessionKey()` |
| Module uninstall without cancel | Registry retains stale Active state; crank retries fail naturally |
