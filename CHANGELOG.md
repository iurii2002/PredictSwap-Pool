# PredictSwap Pool v3 — CHANGELOG

## v3.1 — Proportional LP fee distribution (`_distributeLpFee`)

**Problem:** When one side's `sideValue` is much smaller than its physical
balance (because the other side has accumulated value overflow), a swap or
cross-side withdrawal credited 100% of the LP fee to the drained side's
few LPs — a windfall disproportionate to their actual liquidity contribution.

Example: pool reserves 510A:1000B but LP values 1400:100. A→B swap of 1000
sent all LP fee to the 100 B-side LPs, even though 890 of the B-side
physical tokens were effectively owned by A-side overflow.

**Fix:** New `_distributeLpFee(drainedSide, otherSide, lpFee, drain)` helper
splits the LP fee proportionally when `drain > drainedSideValue`:

```
feeToDrained = lpFee × drainedSideValue / drain
feeToOther   = lpFee − feeToDrained
```

When `drain ≤ drainedSideValue`, 100% goes to the drained side (unchanged
behavior). When `drainedSideValue == 0`, 100% goes to the other side.

Applied in two places:
- `swap()` — drain = `normOut` (net output after fees)
- `withdrawal()` cross-side — drain = `totalOutflow` (payout + protocolFee)

Invariant `aSideValue + bSideValue == physA + physB` is preserved because
`feeToDrained + feeToOther == lpFee` always.

**Tests added (4):**
- `testFeeDistribution_SwapSplitsWhenOverflow` — multi-swap scenario triggers split, both rates grow
- `testFeeDistribution_SwapNoSplitWhenBalanced` — balanced pool, only drained side rate grows
- `testFeeDistribution_CrossSideWithdrawalSplitsWhenOverflow` — partial cross-side withdrawal triggers split
- `testFeeDistribution_SwapSplitIsProportional` — verifies B-side share ≈ 91% when B owns ~91% of drained liquidity

---

## Summary

v3 consolidates the accounting and withdrawal paths. Each side's LP claim is
now represented by a single scalar (`aSideValue`, `bSideValue`) instead of a
four-quadrant partition matrix. Withdrawals are a single `withdrawal()`
function with a receive-side chooser when swaps are active, plus a
`withdrawProRata()` path gated to `swapsPaused`. The 24h lock on LP positions
is a two-bucket fresh/matured model (no longer a single weighted-average
timer), so quick-exit fees scale with the actually-fresh portion of a burn
instead of gating the whole claim.

Factory is hard-bound to one market pair at deploy and carries
project-level names (`marketAName`, `marketBName`, e.g. `"Polymarket"`,
`"Opinion"`). Per-pool `MarketConfig` is trimmed to `{tokenId, decimals}`;
the per-pool event description (`"Trump out 2028 — YES"`) is passed into
`createPool` and surfaces only in the `PoolCreated` event.

Affected files:
- **Rewritten:** `src/SwapPool.sol` (value accounting + unified withdrawal)
- **Rewritten:** `src/LPToken.sol` (two-bucket fresh/matured lock)
- **Rewritten:** `src/PoolFactory.sol` (factory-level names, resolve API,
  side-level tokenId uniqueness, LP tokenId == market tokenId)
- **Unchanged:** `src/FeeCollector.sol`
- **Tests:** full rewrite of `test/PredictSwap.t.sol` (47 tests passing).
- **Scripts:** deploy + integration scripts updated against v3 (`forge build`
  is clean end-to-end). `ApproveMarketContract.s.sol`, `WithdrawBothSides.s.sol`,
  `WithdrawSingleSide.s.sol`, and `WithdrawAll.s.sol` were deleted;
  `integration_tests/Withdraw.s.sol` replaces the three old withdrawal scripts.

---

## LPToken — two-bucket fresh/matured lock

Replaces the v2 weighted-average `lastDepositTime` with an explicit
`FreshDeposit { uint256 amount; uint256 timestamp; }` bucket per user per
tokenId. The matured portion is derived as `balance − fresh.amount` and never
stored. Motivation: v2 punished long-term LPs for topping up (a recent deposit
bumped the avg timer and made the whole position fee-liable); v3 fee only
applies to the actually-fresh share of a burn.

`_update` hook rules (OZ v5 single hook for mint/burn/transfer):
- **Outflow** (burn or transfer-out): consume matured first. Fresh shrinks
  only on overhang — i.e., when `value > matured`.
- **Inflow** (mint or transfer-in): graduate the recipient's fresh if aged,
  then merge incoming into fresh with a value-weighted-average timestamp.
  Transfers-in are always fresh at the recipient — maturity does **not**
  propagate across wallets (JIT-defense hardening vs. v2).

Public surface:

```solidity
uint256 public constant LOCK_PERIOD = 24 hours;
struct FreshDeposit { uint256 amount; uint256 timestamp; }
mapping(address => mapping(uint256 => FreshDeposit)) public freshDeposit;

function lockedAmount(address user, uint256 tokenId) external view returns (uint256);
function isLocked(address user, uint256 tokenId)    external view returns (bool);
function registerPool(address pool_, uint256 tokenId) external;   // factory-only
```

`registerPool` now takes the caller-supplied `tokenId` (which the factory
mirrors from the underlying market tokenId) rather than assigning via an
internal counter. Reverts on `tokenId == 0` or double-registration.

---

## PoolFactory

### Hard-bound to one project pair

Factory is specialized for one marketA↔marketB contract pair **and** carries
the project display names:

```solidity
constructor(
    address marketAContract_,
    address marketBContract_,
    address feeCollector_,
    address operator_,
    address owner_,
    string  memory marketAName_,      // e.g. "Polymarket"
    string  memory marketBName_,      // e.g. "Opinion"
    string  memory marketALpName_,    // e.g. "Polymarket LP"  (ERC-1155 instance name)
    string  memory marketBLpName_     // e.g. "Opinion LP"
)

string public marketAName;
string public marketBName;
address public immutable marketAContract;
address public immutable marketBContract;
LPToken public immutable marketALpToken;
LPToken public immutable marketBLpToken;
```

### `MarketConfig` trimmed

```diff
 struct MarketConfig {
-    address marketContract;   // factory-level immutable
     uint256 tokenId;
     uint8   decimals;
-    string  name;             // moved to factory-level marketAName / marketBName
 }
```

### `createPool` signature

```solidity
function createPool(
    MarketConfig calldata marketA_,
    MarketConfig calldata marketB_,
    uint256 lpFeeBps_,
    uint256 protocolFeeBps_,
    string   calldata eventDescription_   // e.g. "Trump out 2028 — YES"; event-only
) external onlyOperator returns (uint256 poolId);
```

`eventDescription_` flows only into the `PoolCreated` event — never stored
on-chain. Indexers that want the project names read them from the factory's
auto-generated getters once.

### LP tokenId = market tokenId

LP tokenIds mirror the underlying prediction-market tokenIds (no more
monotonic counter on `LPToken`). Within a factory, market tokenIds are
**strictly non-reusable** across pools on either side, enforced by
`usedMarketATokenId` / `usedMarketBTokenId`. If an operator attempts to
create a pool whose `marketA.tokenId` was already used (even paired against
a different `marketB.tokenId`), `createPool` reverts with
`MarketATokenIdAlreadyUsed(tokenId)` (symmetric for side B).

This is safe because one factory == one project pair; reusing a market
tokenId across pools would need a second factory.

### Resolve / pause API

```diff
-function resolvePoolAndPausedDeposits(uint256 poolId) external onlyOperator; // auto-paused deposits only
-function unresolvePool(uint256 poolId)              external onlyOperator;
+function setResolvePool(uint256 poolId, bool resolved_) external onlyOperator; // idempotent toggle
+function resolvePoolAndPause(uint256 poolId)            external onlyOperator; // one-shot: resolved+depositsPaused+swapsPaused
```

Rationale: v2's resolve left swaps live while auto-pausing deposits — giving
an operator-controlled window where cross-side was free. v3 splits the
concerns: `setResolvePool(true)` just flips the `resolved` flag (so cross-side
is free but swaps still run), and `resolvePoolAndPause` atomically sets all
three flags for a clean full-stop.

### Events

```solidity
event PoolCreated(
    uint256 indexed poolId,
    address swapPool,
    uint256 marketATokenId,
    uint256 marketALpTokenId,
    uint256 marketBTokenId,
    uint256 marketBLpTokenId,
    uint256 lpFeeBps,
    uint256 protocolFeeBps,
    string  eventDescription          // renamed from per-side marketAName/marketBName
);
```

---

## SwapPool v3 — value accounting

### State

v2's four partition variables collapse into two scalars:

```diff
-uint256 public marketAPartitionA;
-uint256 public marketAPartitionB;
-uint256 public marketBPartitionA;
-uint256 public marketBPartitionB;
+uint256 public aSideValue;   // total normalized value owed to marketA-LP holders
+uint256 public bSideValue;   // total normalized value owed to marketB-LP holders
```

Invariant (held after every state-changing function, tested in
`testValueInvariant_*`):

```
aSideValue + bSideValue == physicalBalanceNorm(A) + physicalBalanceNorm(B)
```

Physical token composition per-side is no longer tracked.

### Rates

```solidity
function marketARate() public view returns (uint256);   // aSideValue * 1e18 / marketALpSupply
function marketBRate() public view returns (uint256);   // bSideValue * 1e18 / marketBLpSupply
function physicalBalanceNorm(Side side) public view returns (uint256);
```

Each rate starts at `1e18`. A rate grows when its side's `sideValue`
receives an LP fee (see attribution below).

### Deposit

```
deposit(side, amount):
  normAmount = _toNorm(side, amount)
  if supply == 0: lpMinted = normAmount
  else:           lpMinted = normAmount * supply / sideValue(side)
  sideValue(side) += normAmount
```

### Swap

```
swap(fromSide, sharesIn):
  normIn = _toNorm(fromSide, sharesIn)
  protocolFee paid in fromSide tokens → FeeCollector (with recordFee)
  normOut = normIn − lpFee − protocolFee
  check physicalBalanceNorm(toSide) >= normOut, else InsufficientLiquidity
  pool pushes normOut of toSide to swapper
  _distributeLpFee(toSide, fromSide, lpFee, normOut)
```

Fee attribution: if `normOut ≤ toSideValue`, 100% of `lpFee` goes to the
drained side (same as v3). If `normOut > toSideValue` (overflow from the
input side), the fee splits proportionally — the drained side gets
`lpFee × toSideValue / normOut`, the input side gets the rest.

### Withdrawal (unified)

```solidity
function withdrawal(Side receiveSide, uint256 lpAmount, Side lpSide)
    external returns (uint256 received);
```

Must be called while `swapsPaused == false`; reverts `SwapsPaused` otherwise.

- **Same-side** (`receiveSide == lpSide`): no fee, except the JIT fee on the
  *fresh* portion of the burn when `!resolved`. Fresh portion is computed as
  `max(0, lpAmount − matured)` — the LPToken's outflow hook consumes matured
  first, so only the overhang is fee-liable. LP fee stays on `lpSide`.
- **Cross-side** (`receiveSide != lpSide`): full fee on claim when
  `!resolved`; free when `resolved`. LP fee is distributed via
  `_distributeLpFee(receiveSide, lpSide, lpFee, totalOutflow)` — if
  `totalOutflow > receiveSideValue`, the fee splits proportionally between
  both sides based on effective liquidity ownership.
- Reverts `InsufficientLiquidity(available, required)` if the pool's
  `physicalBalanceNorm(receiveSide) < payout + protocolFee`. When a side is
  illiquid, the user either takes the other side or (operator pauses) uses
  `withdrawProRata`.

### Withdraw pro-rata (gated to `swapsPaused`)

```solidity
function withdrawProRata(uint256 lpAmount, Side lpSide)
    external returns (uint256 nativeOut, uint256 crossOut);
```

Only callable while `swapsPaused == true`; reverts `SwapsNotPaused`
otherwise. Never charges fees.

```
nativeShare = (lpAmount * physicalBalanceNorm(nativeSide)) / sideSupply
if nativeShare > claim: nativeShare = claim    // cap at user's value
crossShare  = claim − nativeShare              // paid in cross-side tokens
```

### Withdrawal state matrix

| swapsPaused | resolved | Callable      | Fees                                              |
|-------------|----------|---------------|---------------------------------------------------|
| F           | F        | `withdrawal`  | Same-side: JIT on fresh portion. Cross-side: 0.4% |
| F           | T        | `withdrawal`  | Same-side: free. Cross-side: free.                |
| T           | F        | `withdrawProRata` | Free                                          |
| T           | T        | `withdrawProRata` | Free                                          |

Governing rule: `swapsPaused` picks the function; `resolved` toggles fees
inside `withdrawal`.

### Events

```solidity
event Withdrawn(
    address indexed user,
    Side    lpSide,
    Side    receiveSide,
    uint256 lpBurned,
    uint256 received,
    uint256 lpFee,
    uint256 protocolFee
);
event WithdrawnProRata(
    address indexed user,
    Side    lpSide,
    uint256 lpBurned,
    uint256 nativeOut,
    uint256 crossOut
);
```

The v2 `WithdrewSameSide` / `WithdrewCrossSide` / `WithdrewProRata` events
are all removed.

### Flush residual

Unchanged in intent: when both LP supplies hit zero, any remaining physical
balance is pushed to `FeeCollector` with `recordFee(...)`, and both
`aSideValue` / `bSideValue` are zeroed. Triggers at the end of `withdrawal`
and `withdrawProRata`.

### Rescue

`rescueTokens(side, amount, to)` uses normalized units and the conservative
check `physical > aSideValue + bSideValue` (i.e., only accidental surplus
above all tracked claims can be rescued). `rescueERC1155` still blocks
attempts to rescue the pool's own market tokens (`CannotRescuePoolTokens`).

---

## Scripts updated for v3

Deploy and integration scripts now compile cleanly against the v3 contracts.
Summary of changes:

- **Deleted:** `script/ApproveMarketContract.s.sol` (factory is hard-bound
  to its market pair at deploy — no whitelist).
- **Deleted:** `script/integration_tests/WithdrawBothSides.s.sol`,
  `WithdrawSingleSide.s.sol`, `WithdrawAll.s.sol` — replaced by the new
  unified `script/integration_tests/Withdraw.s.sol`.
- **`script/Deploy.s.sol`** — new 9-arg `PoolFactory` constructor call.
  Requires `MARKET_A_CONTRACT`, `MARKET_B_CONTRACT`, `MARKET_A_NAME`,
  `MARKET_B_NAME`, `MARKET_A_LP_NAME`, `MARKET_B_LP_NAME` in `.env`.
- **`script/CreatePool.s.sol`** — trimmed `MarketConfig` (`{tokenId, decimals}`
  only), single `EVENT_DESCRIPTION` env var replaces the four LP-name vars,
  reads factory-level names for display.
- **`script/integration_tests/Deposit.s.sol`** — reads LPToken from factory,
  per-side `marketARate()`/`marketBRate()`, `totalSupply(tokenId)`.
- **`script/integration_tests/Swap.s.sol`** — uses `physicalBalanceNorm(Side)`
  and factory-level market-contract reads.
- **`script/integration_tests/Withdraw.s.sol`** (new) — unified withdrawal
  script. Auto-picks `withdrawal(receiveSide, lpAmount, lpSide)` when swaps
  are active, or `withdrawProRata(lpAmount, lpSide)` when swaps are paused.

`forge build` (without `--skip script`) is clean. `forge test` runs 47/47.

---

## Test suite

Categories:

- `Lock_*` — two-bucket fresh/matured lock (9 tests): first deposit, weighted
  average, transfer-always-fresh at recipient, matured holder receiving
  transfer, outflow-from-matured, overhang-reduces-fresh, poisoning-resistance,
  graduate-by-time, burn-doesn't-revert, per-tokenId isolation.
- `Deposit_*` — 1:1 first deposit, mint-at-rate after swap fees, paused
  revert, zero-amount revert.
- `Swap_*` — payout math, drained-side rate growth, paused revert,
  insufficient-liquidity revert.
- `Withdrawal_*` — same-side (matured/fresh/partial-fresh/fit-in-matured)
  and cross-side (unresolved/resolved), cross-side fee attribution to
  `receiveSide`, swaps-paused revert, zero-amount revert,
  insufficient-physical revert.
- `WithdrawProRata_*` — swaps-active revert, balanced all-native split,
  imbalanced native+cross split, never-fees-even-with-fresh-LP.
- `ValueInvariant_*` — post-deposit and post-mixed-ops invariant check.
- `RateAttribution_*` — swap grows drained-side rate only; same-side JIT
  fee grows own rate.
- `FeeDistribution_*` — proportional fee split when drain exceeds drained-side
  value (swap overflow, balanced no-split, cross-side withdrawal overflow,
  proportionality check).
- `Factory_*` — LP tokenId mirrors market tokenId, side-uniqueness reverts,
  `setResolvePool` toggle, `resolvePoolAndPause` atomic, name storage,
  second-factory with different names.
- `FlushResidual_*` — clean state after last exit; pro-rata exits after a
  swap still leave pool clean.
- `Rescue_*` — nothing-to-rescue when physical matches tracked; surplus
  can be rescued from an empty-tracked pool.

Build/test:
```
forge build      # clean compile (src + test + script), solc 0.8.24, via_ir, opt 200
forge test       # 172 passing (unit + fuzz + invariant)
```
