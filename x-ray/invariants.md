# Invariant Map

> PredictSwap | 20 guards | 14 inferred | 3 not enforced on-chain

---

## 1. Enforced Guards (Reference)

Per-call preconditions. Heading IDs below (`G-N`) are anchor targets from x-ray.md attack surfaces.

#### G-1
`if (depositsPaused) revert DepositsPaused()` · `SwapPool.sol:258` · Prevents deposits when operator has paused the pool; enforces lifecycle gate

#### G-2
`if (resolved) revert MarketResolved()` · `SwapPool.sol:259` · Blocks deposits after event resolution to prevent new exposure to a settled outcome

#### G-3
`if (swapsPaused) revert SwapsPaused()` · `SwapPool.sol:290` · Prevents swaps during emergency pause; forces users to withdrawProRata instead

#### G-4
`if (resolved) revert MarketResolved()` · `SwapPool.sol:291` · Blocks swaps after resolution; prevents arbitrage on known outcomes

#### G-5
`if (normOut > availableOut) revert InsufficientLiquidity(availableOut, normOut)` · `SwapPool.sol:302` · Prevents swap output from exceeding physical reserves on the drained side

#### G-6
`if (rawOut == 0) revert SwapTooSmall()` · `SwapPool.sol:316` · Catches precision loss from `_fromNorm` truncation on small swaps with low-decimal tokens

#### G-7
`if (swapsPaused) revert SwapsPaused()` · `SwapPool.sol:344` · Gates `withdrawal()` to active-swap mode only; paused pools must use `withdrawProRata`

#### G-8
`if (totalOutflow > available) revert InsufficientLiquidity(available, totalOutflow)` · `SwapPool.sol:372` · Prevents withdrawal outflow (payout + protocolFee) from exceeding physical reserves on receive side

#### G-9
`if (rawPayout == 0) revert ZeroAmount()` · `SwapPool.sol:402` · Catches zero-output withdrawals from precision loss or trivially small LP burns

#### G-10
`if (!swapsPaused) revert SwapsNotPaused()` · `SwapPool.sol:434` · Gates `withdrawProRata()` to paused mode only; active pools must use `withdrawal`

#### G-11
`if (rawNative == 0 && rawCross == 0) revert ZeroAmount()` · `SwapPool.sol:467` · Prevents pro-rata withdrawal from producing zero output on both sides

#### G-12
`if (msg.sender != address(factory)) revert Unauthorized()` · `SwapPool.sol:195,509,515,521,527,537,549` · Factory-only gate on initialize and all admin setters/rescue functions

#### G-13
`if (_initialized) revert AlreadyInitialized()` · `SwapPool.sol:196` · One-shot latch preventing re-initialization of LP tokenIds

#### G-14
`if (lpFeeBps_ > MAX_LP_FEE) revert FeeTooHigh()` · `SwapPool.sol:176,538` · Caps LP fee at 1.00% (100 bps) at both construction and runtime update

#### G-15
`if (protocolFeeBps_ > MAX_PROTOCOL_FEE) revert FeeTooHigh()` · `SwapPool.sol:177,539` · Caps protocol fee at 0.50% (50 bps) at both construction and runtime update

#### G-16
`if (totalPhysical <= totalTracked) revert NothingToRescue()` · `SwapPool.sol:558` · Prevents rescue of tracked pool funds; only surplus (donated/accidental) tokens can be rescued

#### G-17
`if (pool[tokenId] != address(0)) revert TokenIdAlreadyRegistered()` · `LPToken.sol:101` · One-shot pool registration per tokenId; prevents reassignment

#### G-18
`if (msg.sender != pool[tokenId]) revert OnlyPool()` · `LPToken.sol:84` · Restricts mint/burn to the registered pool for each tokenId

#### G-19
`if (msg.sender != operator && msg.sender != owner()) revert NotOperator()` · `PoolFactory.sol:139` · Dual-role gate: operator or owner can call operator functions

#### G-20
`if (usedMarketATokenId[marketA_.tokenId]) revert MarketATokenIdAlreadyUsed(...)` · `PoolFactory.sol:204-205` · Prevents tokenId reuse across pools on either market side; enforces LP tokenId collision-freedom

---

## 2. Inferred Invariants (Single-Contract)

Inferred invariants are derived from structural analysis of the source code. Each block below cites one of five extraction methods in its `Derivation` field:

- **Delta-pair analysis** -- two or more storage variables in the same function body that change by equal-and-opposite amounts
- **Guard lift** -- a `require` / `if-revert` on a storage variable, promoted from per-call to global by checking all write sites
- **State-machine edge** -- a storage variable transitioning through discrete values with no reverse path
- **Temporal predicate** -- a check tied to `block.timestamp` or a stored duration/deadline variable
- **NatSpec-stated global property** -- a developer-asserted invariant in NatSpec or inline comment

---

#### I-1

`Conservation` · On-chain: **Yes**

> `aSideValue + bSideValue == physicalBalanceNorm(MARKET_A) + physicalBalanceNorm(MARKET_B)` after every state-changing operation (excluding FeeCollector outflows).

**Derivation** -- NatSpec: `README.md` -- "aSideValue + bSideValue == physicalBalanceNorm(A) + physicalBalanceNorm(B)". Confirmed by delta-pair analysis: in `deposit()` delta(sideValue) = +normAmount at `SwapPool.sol:274` paired with physical inflow via `_pullTokens` at `:262`. In `swap()` net delta(aSideValue + bSideValue) = +lpFee via `_distributeLpFee` at `:321` paired with physical net change +normIn - normOut - protocolFee = +lpFee. In `withdrawal()` delta(sideValue) = -(shares - lpFee) at `:388` paired with physical outflow payoutNorm + protocolFee = shares - lpFee. Covered by `invariant_ValueConservation` (128 runs x 8192 calls).

**If violated** -- Pool becomes insolvent (physical < tracked) or leaks value (physical > tracked, extractable via rescue).

---

#### I-2

`Conservation` · On-chain: **Yes**

> `LPToken.totalSupply[tokenId] == sum of balanceOf(user, tokenId)` for all users.

**Derivation** -- Delta-pair: `LPToken.sol:107` `totalSupply[tokenId] += amount` paired with `_mint(to, tokenId, amount, "")` which calls OZ `_update` incrementing `balanceOf`. Symmetric at `:112` for burn. OZ ERC1155 guarantees `_update` is the sole balance mutation path.

**If violated** -- Rate calculation (`sideValue / supply`) produces wrong exchange rate; depositors receive too many or too few LP tokens.

---

#### I-3

`Bound` · On-chain: **Yes**

> `lpFeeBps` is in `[0, 100]` globally (MAX_LP_FEE = 100 = 1.00%).

**Derivation** -- Guard-lift: `if (lpFeeBps_ > MAX_LP_FEE) revert FeeTooHigh()` at `SwapPool.sol:176` (constructor) and `:538` (setFees). Write sites for `lpFeeBps`: constructor `:186`, `setFees` `:540`. Both write sites are preceded by the guard. No other write site exists.

**If violated** -- LP fee exceeds the 1% hard cap, overcharging swappers and cross-side withdrawers.

---

#### I-4

`Bound` · On-chain: **Yes**

> `protocolFeeBps` is in `[0, 50]` globally (MAX_PROTOCOL_FEE = 50 = 0.50%).

**Derivation** -- Guard-lift: `if (protocolFeeBps_ > MAX_PROTOCOL_FEE) revert FeeTooHigh()` at `SwapPool.sol:177` (constructor) and `:539` (setFees). Write sites for `protocolFeeBps`: constructor `:187`, `setFees` `:541`. Both write sites guarded. No other write site.

**If violated** -- Protocol fee exceeds the 0.5% hard cap.

---

#### I-5

`StateMachine` · On-chain: **Yes**

> `SwapPool._initialized`: `false@196` -> `true@198`, one-shot latch with no reverse path.

**Derivation** -- Edge: `SwapPool.sol:196` `if (_initialized) revert AlreadyInitialized()` followed by `:198` `_initialized = true`. No function sets `_initialized = false`. Grep confirms `_initialized` is written only at line 198.

**If violated** -- Pool LP tokenIds could be reassigned, breaking the tokenId-to-pool invariant.

---

#### I-6

`StateMachine` · On-chain: **Yes**

> `LPToken.pool[tokenId]`: `address(0)@101` -> `pool_@102`, one-shot latch with no reverse path.

**Derivation** -- Edge: `LPToken.sol:101` `if (pool[tokenId] != address(0)) revert TokenIdAlreadyRegistered()` followed by `:102` `pool[tokenId] = pool_`. Grep confirms `pool[tokenId]` is written only at line 102. No path to reset to `address(0)`.

**If violated** -- Multiple pools could mint/burn the same LP tokenId, corrupting supply accounting.

---

#### I-7

`StateMachine` · On-chain: **Yes**

> `PoolFactory.usedMarketATokenId[id]`: `false@204` -> `true@220`, one-shot latch. Same for `usedMarketBTokenId[id]`: `false@205` -> `true@221`.

**Derivation** -- Edge: `PoolFactory.sol:204` `if (usedMarketATokenId[...]) revert MarketATokenIdAlreadyUsed(...)` followed by `:220` `usedMarketATokenId[lpIdA] = true`. Grep confirms `usedMarketATokenId` is written only at line 220. No reverse path.

**If violated** -- Same market tokenId could be used in multiple pools, creating LP tokenId collisions on the shared LPToken instance.

---

#### I-8

`Temporal` · On-chain: **Yes**

> Fresh LP deposits mature after `LOCK_PERIOD` (24 hours): `block.timestamp >= freshDeposit[user][id].timestamp + LOCK_PERIOD` graduates the bucket.

**Derivation** -- Temporal predicate: `LPToken.sol:121` `if (f.amount == 0 || block.timestamp >= f.timestamp + LOCK_PERIOD) return 0` in `lockedAmount()`. Same check at `:152` in outflow path and `:174` in inflow path of `_update`. `LOCK_PERIOD = 24 hours` at `:51`.

**If violated** -- JIT fee could be applied to matured LP (overcharging) or skipped on fresh LP (undercharging).

---

#### I-9

`Bound` · On-chain: **Yes**

> `marketARate() >= 1e18` and `marketBRate() >= 1e18` whenever the respective LP supply > 0.

**Derivation** -- NatSpec-implied from rate starting at `RATE_PRECISION` (1e18) when supply == 0 (`SwapPool.sol:214`). Deposit preserves rate: `lpMinted = normAmount * supply / sideValue` keeps ratio unchanged. Swap increases rate: lpFee added to sideValue with no supply change. Same-side withdrawal with JIT fee: `_subSideValue(shares - lpFee)` while supply decreases by `lpAmount`, leaving rate = old_rate + lpFee/(supply - lpAmount). Cross-side withdrawal preserves the burning side's rate. All paths are rate-neutral or rate-increasing. Covered by `invariant_RateAtLeast1e18` (128 runs x 8192 calls).

**If violated** -- LP holders could withdraw more value than they deposited plus fees, draining other LPs.

---

## 3. Inferred Invariants (Cross-Contract)

Trust assumptions that span contract boundaries. Each block cites both caller-side and callee-side code.

---

#### X-1

On-chain: **Yes**

> SwapPool assumes `LPToken.totalSupply(tokenId)` accurately tracks all mints and burns performed through the registered pool.

**Caller side** -- `SwapPool.sol:213,220,265,374,443,484-485` -- `_lpToken(side).totalSupply(_lpTokenId(side))` used for rate calculation, deposit LP minting, withdrawal share computation, and pro-rata proportioning.

**Callee side** -- `LPToken.sol:107` `totalSupply[tokenId] += amount` in `mint()` and `:112` `totalSupply[tokenId] -= amount` in `burn()`. Both gated by `onlyPool(tokenId)` modifier at `:84`. No other write path for `totalSupply`.

**If violated** -- Rate calculation `sideValue * 1e18 / supply` returns wrong value; deposits receive wrong LP amount; withdrawals compute wrong share claim.

---

#### X-2

On-chain: **No**

> SwapPool assumes that `FeeCollector.recordFee()` is only called after an actual token transfer to the FeeCollector, making `FeeReceived` events a reliable accounting trail.

**Caller side** -- `SwapPool.sol:310-311` `_pushTokens(fromSide, address(feeCollector), rawProtocol)` then `feeCollector.recordFee(...)`. Same pattern at `:408-409` and `:497-502`. The pool transfers tokens THEN calls recordFee.

**Callee side** -- `FeeCollector.sol:33` `function recordFee(address token, uint256 tokenId, uint256 amount) external` -- no access control. Any address can call and emit a `FeeReceived` event with arbitrary parameters.

**If violated** -- Off-chain fee accounting is polluted with fake events. No on-chain funds at risk since `recordFee` only emits events and does not hold or move tokens.

---

#### X-3

On-chain: **No**

> SwapPool assumes external ERC-1155 market contracts transfer exact amounts without fees, rebasing, or balance-modifying side effects.

**Caller side** -- `SwapPool.sol:692-693` `_pullTokens` calls `IERC1155(marketContract).safeTransferFrom(from, address(this), tokenId, amount, "")` and accounts for `amount` in normalized value tracking. No balance-before/after verification.

**Callee side** -- Market contracts are external (Polymarket, PredictFun, etc.) and could theoretically implement non-standard transfer behavior. Immutable addresses set at factory deployment.

**If violated** -- Pool accounting (`aSideValue`) diverges from physical token balance, breaking the I-1 conservation invariant. If market contract transfers less than `amount`, pool is drained over time.

---

## 4. Economic Invariants

Higher-order properties derived from combinations of section 2 and section 3 invariants. Every block traces back to concrete invariant IDs.

---

#### E-1

On-chain: **Yes**

> No user can extract more value from the pool than was deposited plus accumulated fees, across any sequence of deposits, swaps, and withdrawals.

**Follows from** -- `I-1` (conservation: tracked value == physical tokens) + `I-9` (rate monotonically >= 1e18) + `I-3` + `I-4` (fees bounded). Since total tracked value always equals physical tokens (I-1), and each side's rate can only increase (I-9), withdrawals are bounded by `lpAmount * rate / 1e18`. No operation sequence can produce a withdrawal exceeding the sum of all deposits plus all fee accruals minus all prior withdrawals.

**If violated** -- Pool insolvency; late withdrawers cannot exit at their entitled value.

---

#### E-2

On-chain: **Yes**

> Total fee on any single operation is at most 1.50% (150 bps = MAX_LP_FEE + MAX_PROTOCOL_FEE).

**Follows from** -- `I-3` (`lpFeeBps <= 100`) + `I-4` (`protocolFeeBps <= 50`). `SwapPool.sol:238` `totalBps = lpFeeBps + protocolFeeBps` <= 150. `_computeFees` at `:241` computes `totalFee = ceil(normAmount * totalBps / FEE_DENOMINATOR)` <= `ceil(normAmount * 150 / 10000)` = `ceil(normAmount * 0.015)`.

**If violated** -- Users are charged more than the documented maximum fee rate.
