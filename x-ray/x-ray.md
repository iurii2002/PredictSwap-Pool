# X-Ray Pre-Audit Report -- PredictSwap v3

**Branch:** main | **Commit:** 02b05f2 | **Date:** 2026-04-23
**nSLOC:** 823 | **Contracts:** 4 | **Protocol class:** DEX/AMM (prediction-market swap pool)

---

## 1. Protocol Overview

PredictSwap v3 is a prediction-market swap pool protocol using ERC-1155 tokens. One `PoolFactory` per project pair deploys `SwapPool` instances for matched market-A / market-B outcomes. LPs deposit to either side and earn fees from 1:1 swaps. A two-bucket JIT lock (fresh/matured) in `LPToken` prevents LP sniping by charging a quick-exit fee on positions held less than 24 hours.

### Contracts

| Contract | nSLOC | Purpose |
|---|---|---|
| `SwapPool.sol` | 441 | Core pool: deposit, swap, withdrawal, withdrawProRata, value accounting |
| `PoolFactory.sol` | 216 | Registry + deployer. Owner/operator roles. Deploys 2 LPToken instances |
| `LPToken.sol` | 105 | ERC-1155 LP token with two-bucket JIT lock, pool-only mint/burn |
| `FeeCollector.sol` | 61 | Accumulates protocol fee cuts; owner can withdraw |

### Architecture

Users and LPs interact **only with SwapPool** — they never call PoolFactory directly. SwapPool pulls/pushes ERC-1155 prediction-market shares from external market contracts, mints/burns LP via LPToken, and forwards protocol fees to FeeCollector. Owner and Operator manage pools through PoolFactory, which proxies all admin calls to SwapPool (`msg.sender == address(factory)` gate). For a visual overview, see the [architecture diagram](architecture.svg).

### Temporal Phases

1. **Deployment and Initialization** -- Factory deploys SwapPool, registers LP tokenIds, calls `initialize()`.
2. **Steady State** -- Deposits, swaps, and withdrawals operate. Operator can pause/resolve.

No proxies, no upgrades, no governance, no oracles.

---

## 2. Attack Surface Analysis

### 2.1 Last-LP same-side JIT withdrawal value leak

- **Location:** `SwapPool.sol:378-382`
- **Mechanism:** When the last LP on a side withdraws same-side with a JIT fee, `_addSideValue(_oppositeSide(lpSide), lpFee)` inflates the opposite side's tracked value by `lpFee`. However the physical tokens backing that fee remain on the withdrawing side (only the payout is sent; the fee delta stays as physical tokens of `lpSide`). Opposite-side LPs now have an inflated `sideValue` backed partly by tokens on the wrong side, forcing them into `withdrawProRata` to collect.
- **Impact:** Value misattribution; opposite-side LPs cannot withdraw same-side for the full amount.
- **Invariants:** I-1, I-2, X-1

### 2.2 Cross-side withdrawal LP fee direction divergence

- **Location:** `SwapPool.sol:387-388`
- **Mechanism:** On cross-side withdrawal, `_addSideValue(receiveSide, lpFee)` credits the LP fee to the receive side's tracked value. But the physical token for that fee was taken from `receiveSide` physical balance (the payout was reduced). The receive side's physical balance decreases by `shares - lpFee` worth of tokens going out as payout, yet its tracked value increases by `lpFee`. This progressively diverges per-side value from per-side physical holdings.
- **Impact:** Gradual per-side imbalance. Mitigated by design intent (value is global, physical composition is fluid), but can surprise same-side withdrawers.
- **Invariants:** I-2, G-2

### 2.3 LPToken self-transfer fresh bucket corruption

- **Location:** `LPToken.sol:135-189` (`_update` hook)
- **Mechanism:** When `from == to`, OZ `super._update` is a no-op on balance. The outflow branch reads `preBalance = balanceOf(from, id) + value` -- but the balance did not actually decrease, so `preBalance` overestimates. The inflow branch then adds `value` to `tf.amount`, potentially inflating `fresh.amount` beyond the actual balance. A user with 100 LP who self-transfers 100 would have `fresh.amount = 200` after two iterations.
- **Impact:** `lockedAmount()` returns inflated value; `_freshConsumedForBurn` overestimates fresh consumed, charging excess JIT fee on next withdrawal.
- **Invariants:** I-3, X-2

### 2.4 Operator compromise -- instant pause/resolve/create

- **Location:** `PoolFactory.sol:138-141, 296-322`
- **Mechanism:** Operator (or owner) can instantly pause swaps/deposits and resolve pools with no timelock or delay. A compromised operator key can grief all pools simultaneously.
- **Impact:** Denial of service; forced pro-rata withdrawal at unfavorable composition.
- **Invariants:** G-5

### 2.5 Permissionless `recordFee` event spoofing

- **Location:** `FeeCollector.sol:33-36`
- **Mechanism:** Anyone can call `recordFee` and emit `FeeReceived` with arbitrary pool, token, and amount values. No balance check.
- **Impact:** Off-chain indexers that trust `FeeReceived` events without filtering by known pool addresses will have corrupted accounting.
- **Invariants:** G-6

### 2.6 `setFeeCollector` non-propagation to existing pools

- **Location:** `PoolFactory.sol:283-287`, `SwapPool.sol:63`
- **Mechanism:** `SwapPool.feeCollector` is `immutable`. When the owner calls `factory.setFeeCollector(newAddr)`, only future pools use the new collector. Existing pools continue sending fees to the old address permanently.
- **Impact:** Protocol fees from existing pools are irrecoverable if the old FeeCollector is abandoned. Owner must be aware of this at deployment time.
- **Invariants:** G-6

### 2.7 `rescueTokens` global surplus cross-side drain

- **Location:** `SwapPool.sol:548-554`
- **Mechanism:** `rescueTokens` computes surplus as `totalPhysical(A+B) - totalTracked` globally. If all surplus is physically on side A but the owner calls `rescueTokens(Side.MARKET_B, ...)`, it drains side-B physical tokens that are obligated to side-B LPs. The check passes because global surplus exists.
- **Impact:** Owner can accidentally drain obligated tokens from one side. Requires owner action (admin-gated).
- **Invariants:** I-2, E-1

### 2.8 Protocol fee truncation on low-decimal tokens

- **Location:** `SwapPool.sol:308, 658-662`
- **Mechanism:** `_fromNorm` truncates normalized amounts: `norm / 10^(18-dec)`. For 6-decimal tokens, a `protocolFee` under `1e12` in normalized units truncates to 0 raw. Small swaps (~1-250 raw units at 10bps protocol fee) yield zero protocol fee -- the fee is computed but never transferred.
- **Impact:** Protocol revenue leakage on micro-swaps. LP fee is still credited to `sideValue` in normalized form, creating a tiny tracked-vs-physical surplus (rounding dust).
- **Invariants:** I-1, G-3

---

## 3. Invariants

See `invariants.md` for the full invariant catalog with concrete derivations.

**Summary:** 6 global (G-1..G-6), 4 inter-contract (I-1..I-4), 3 cross-function (X-1..X-3), 2 edge-case (E-1..E-2).

---

## 4. Entry Points

See `entry-points.md` for the complete entry-point catalog by access level.

---

## 5. Coverage and Testing Assessment

### Current State

| Contract | Lines | Stmts | Branches | Funcs |
|---|---|---|---|---|
| FeeCollector | 100% | 100% | 100% | 100% |
| LPToken | 100% | 98.57% | 94.44% | 100% |
| PoolFactory | 98.91% | 96.30% | 96% | 100% |
| SwapPool | 96.95% | 92.54% | 71.43% | 100% |

### Test Suite Composition

- **162 unit tests** across `PredictSwap.t.sol` (143 tests) and `PredictSwapFuzz.t.sol` (19 fuzz tests)
- **6 Foundry invariant tests** in `PredictSwapInvariant.t.sol` with handler-based stateful fuzzing
- **No Echidna, Medusa, Certora, Halmos, or fork tests**

### Gaps

- SwapPool branch coverage at 71.43% -- rescue paths and edge-case reverts likely untested
- No self-transfer test for LPToken (attack surface 2.3)
- No test for last-LP same-side JIT fee path (attack surface 2.1)
- No cross-decimal rounding boundary tests (6-dec vs 18-dec edge)
- Invariant handler does not cover `withdrawProRata` (paused-state path untested by fuzzer)

---

## 6. Code Quality Observations

- Single developer, 31 commits over 50 days. High test co-change rate (76.9%).
- Late large commit `98b4e12` "updated to v2" (1204 lines) followed by `02b05f2` "corrected based on ai check" (51 lines) -- high-risk pattern for regression.
- NatSpec coverage is sparse (~4 documented functions). Internal helpers lack documentation.
- No external dependencies beyond OZ contracts. Clean import structure.
- `receive() external payable {}` on SwapPool accepts ETH with no clear purpose beyond `rescueETH`.
- `FeeCollector.withdrawAllBatch` makes two passes over `tokenIds` calling `balanceOf` each time -- O(2n) external calls. Gas-expensive for large arrays but functionally correct.

---

## 7. X-Ray Verdict

### Tier: FRAGILE

**Dimension breakdown:**

| Dimension | Rating | Rationale |
|---|---|---|
| Tests | HARDENED | Unit (143) + stateless fuzz (19) + stateful invariant (6). Handler covers deposit/swap/withdraw/time-skip. |
| Docs | FRAGILE | Sparse NatSpec (~4 functions). No specification document. Contract-level comments exist but no formal properties. |
| Access Control | FRAGILE | Owner/operator roles exist and are enforced, but no timelock on any admin action. Instant resolve + pause. |

**Governing rule:** Tier = min(Tests, Docs, Access Control) = FRAGILE.

### Structural Facts

- 823 nSLOC, 4 contracts, 0 proxies, 0 oracles, 0 governance
- 5 permissionless entry points, all `nonReentrant + whenInitialized`
- ERC-1155 only (no ERC-20 pool tokens, no ETH value flow in core paths)
- 1:1 value model with fee tiers (LP 0-1%, protocol 0-0.5%)
- Two-bucket JIT lock with 24h maturation and weighted-average timestamp
- Immutable `feeCollector` per pool; mutable at factory level (non-propagating)
- Market tokenIds strictly non-reusable per side within a factory
- `rescueTokens` uses global surplus check, not per-side
- All admin calls on SwapPool gated by `msg.sender == address(factory)`
