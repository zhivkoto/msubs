# msubs — Subscription Permissions Standard for Monad

**A reference implementation of a proposed open standard for onchain recurring payments on Monad.**

This repository contains a Foundry reference implementation of a draft subscription permissions standard built on ERC-4337 smart accounts and EIP-7702 EOA delegation.

---

## Why

Subscriptions are the dominant monetization model of the internet. They are fundamentally broken onchain because blockchains have no native "pull payment" primitive — every transfer requires an explicit signature from the sender.

Every existing attempt to solve this has made a tradeoff that hurts adoption:

- **Streaming protocols** (Superfluid, Sablier) model continuous flows, not discrete periodic charges. Users don't think in "tokens per second" — they think "charge me $9.99 on the 1st."
- **ERC-20 approvals** grant unlimited spending with no time bounds or rate limits. Billions have been lost to approval exploits.
- **Custodial solutions** (Binance Pay, Coinbase Commerce) defeat the point of self-custody.
- **Ad-hoc smart account modules** work today — but each vendor (Biconomy, ZeroDev, Safe) encodes permissions differently, so wallets can't display subscriptions, merchants must integrate per-vendor, and there is no interoperability.

The primitives needed to fix this already exist on Monad:

- **ERC-4337** (account abstraction) — Biconomy Nexus and Pimlico are live
- **ERC-7579** (modular smart accounts)
- **EIP-7702** (temporary EOA delegation — works for every MetaMask user, not just smart account holders)

**What's missing is a standard.** That's what this reference implementation demonstrates.

---

## The standard in 60 seconds

A user authorizes a subscription with **one signature**. After that, no further user interaction is required — a permissionless crank triggers renewals on schedule, the smart account (or EIP-7702 delegated EOA) validates the permission on-chain, and the transfer executes.

**Authorization is scoped and bounded.** A session key granted to the merchant can only trigger the exact subscription it was issued for: specific token, specific recipient, capped amount, minimum interval. If the backend is compromised, blast radius is one subscription period's worth of funds — nothing more.

**Gas is invisible.** A verifying paymaster sponsors all renewal UserOperations, funded by a small protocol fee baked into each charge. Users and merchants never touch gas.

**Failure is graceful.** Failed renewals increment a retry counter and emit `SubscriptionFailed`. After consecutive failures, the subscription moves to a `GracePeriod`; if still unpaid past the grace window, it transitions to `Expired`. No silent drain, no hidden charges.

**Everything is interoperable.** Every implementation speaks the same `SubscriptionPermission` struct, emits the same events, responds to the same wallet visibility interface, and uses the same `monad:subscribe?...` deep-link format. Wallets can display active subscriptions across all vendors in a unified UI. Merchants integrate once.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                    MONAD SUBSCRIPTION PROTOCOL                        │
│                                                                       │
│  ┌──────────────┐   ┌──────────────────┐   ┌──────────────────────┐  │
│  │  Merchant    │   │  Subscription    │   │  Subscription        │  │
│  │  Registry    │   │  Registry        │   │  Paymaster           │  │
│  │              │   │                  │   │  (ERC-4337)          │  │
│  │ - merchants  │   │ - subscriptions  │   │ - validates UOps     │  │
│  │ - plans      │   │ - permissions    │   │ - sponsors gas       │  │
│  │ - fee tiers  │   │ - wallet view    │   │ - per-sub rate limit │  │
│  └──────┬───────┘   └────────┬─────────┘   └──────────┬───────────┘  │
│         │                    │                          │             │
│  ┌──────┴────────────────────┴──────────────────────────┴──────────┐ │
│  │                  SubscriptionModule (ERC-7579)                   │ │
│  │                                                                   │ │
│  │  subscribe → pause/resume → update → cancel → processRenewal     │ │
│  │                                                                   │ │
│  │  - stores SubscriptionPermission per session key                  │ │
│  │  - validates period elapsed, amount, merchant, token on renewal   │ │
│  │  - handles failure retry → grace period → expired state machine  │ │
│  │  - cancels subscriptions on module uninstall                      │ │
│  └──────────────────────────┬───────────────────────────────────────┘ │
│                              │                                        │
│         ┌────────────────────┴──────────────────┐                     │
│         ▼                                        ▼                     │
│  ┌─────────────────────┐             ┌─────────────────────────┐      │
│  │  ERC-4337 Account   │             │  EOA via EIP-7702       │      │
│  │  (Biconomy, ZeroDev)│             │  (MetaMask, Rabby, etc.)│      │
│  └─────────────────────┘             └─────────────────────────┘      │
└───────────────────────────────────────────────────────────────────────┘
```

---

## Contents

| Path | Description |
|---|---|
| [`contracts/src/`](./contracts/src/) | Solidity source — `SubscriptionModule` (ERC-7579), `SubscriptionRegistry`, `MerchantRegistry`, `SubscriptionPaymaster`, `SubscriptionLib`, and 5 interfaces |
| [`contracts/test/`](./contracts/test/) | 163 tests — unit, integration, fuzz. Covers the full subscription lifecycle including grace period, retries, session key rotation, and module uninstall |
| [`contracts/script/`](./contracts/script/) | Deployment script (not executed) |
| [`contracts/README.md`](./contracts/README.md) | Build, test, and deployment documentation |

---

## Implementation status

| Component | Status |
|---|---|
| Core contracts | ✅ Complete (~2,000 lines across 5 contracts) |
| Unit + integration tests | ✅ 163/163 passing |
| Coverage | ✅ 83% line coverage |
| Gas report | ✅ Generated ([contracts/gas-report.txt](./contracts/gas-report.txt)) |
| External audit | ❌ Required before mainnet deployment |
| Monad testnet deployment | ❌ Not yet deployed |
| JS/TS SDK | ❌ Out of scope for this reference impl |
| Wallet integration | ❌ Requires ecosystem adoption |

---

## Who should be interested

| Role | Why you should care |
|---|---|
| **Wallet builders** (Phantom, MetaMask, Rabby, Backpack) | A standard subscription view across all smart account vendors, without custom integrations per vendor |
| **Smart account vendors** (Biconomy, ZeroDev, Safe, Kernel) | Ship a standards-compliant `SubscriptionModule` that interoperates with all compliant wallets |
| **Merchants** (SaaS, content, AI agents, DePIN) | Integrate recurring crypto payments once, work with every wallet and account vendor |
| **Application builders** | Drop-in subscription billing without custody or custom backend |
| **Monad ecosystem contributors** | A foundational payment primitive filling a real gap in the ecosystem |

---

## Running the reference implementation

```bash
# Clone
git clone --recursive https://github.com/zhivkoto/msubs
cd msubs/contracts

# Build
forge build

# Test
forge test -vv

# Coverage
forge coverage

# Gas report
forge test --gas-report
```

Full build and test documentation lives in [`contracts/README.md`](./contracts/README.md).

---

## Design decisions and rationale

This reference implementation makes explicit, opinionated design choices:

- **ERC-7579 module over custom contract.** Cross-vendor compatibility by default — any smart account that supports ERC-7579 can install the standard module.
- **Session keys over permit-based flows.** Scoped, persistent, revocable authorization without recurring user signatures.
- **Scoped permissions over unlimited approvals.** Bounded blast radius: a compromise caps at one period's funds, not the full wallet.
- **Crank-based renewals over native scheduling.** Monad has no native scheduling primitive, and cranks are a pure liveness mechanism — all validation happens on-chain. The crank cannot charge more, charge early, or charge a different recipient than the permission specifies.
- **Monad over Ethereum mainnet.** EIP-7702 is supported natively, gas per renewal is roughly $0.001 (trivially sustainable for paymaster economics), parallel execution handles batch renewals at scale, and 2-second finality keeps renewals feeling instant.

---

## Contributing

This is an early-stage standards proposal. The most valuable contributions right now are:

1. **Feedback on the design** — is anything ambiguous? Does the permission model cover your use case? Are there corner cases the implementation missed?
2. **Wallet prototypes** — a proof-of-concept subscription visibility UI in any Monad-compatible wallet
3. **Merchant integration experiments** — try the reference contracts with a dummy SaaS or content paywall, report friction
4. **Cross-vendor interop tests** — does the standard module work identically on Biconomy Nexus, ZeroDev Kernel, Safe, and other ERC-7579 accounts?

Open an issue or a PR. This is meant to be community infrastructure — opinions welcome.

---

## License

[MIT](./LICENSE) — this is open standards work. Fork it, ship it, improve it.
