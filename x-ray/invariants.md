# Invariants -- PredictSwap v3

---

## Global Invariants

#### G-1: Pool solvency
totalPhysical(A) + totalPhysical(B) >= aSideValue + bSideValue, always. The pool never owes more than it holds.

#### G-2: Value conservation across operations
For every deposit/swap/withdrawal, the change in (aSideValue + bSideValue) plus fees extracted equals the change in total physical balance, within rounding tolerance of 1 unit per operation per low-decimal side.

#### G-3: Fee bounds
lpFeeBps <= MAX_LP_FEE (100) AND protocolFeeBps <= MAX_PROTOCOL_FEE (50), enforced at construction and by setFees. Total fee never exceeds 1.5%.

#### G-4: LP rate monotonicity (non-decreasing)
marketARate() and marketBRate() never decrease from swap fees. Rates start at 1e18 and grow as LP fees accrue to sideValue.

#### G-5: Admin gating
All SwapPool state-changing admin functions revert unless msg.sender == address(factory). PoolFactory operator functions revert unless msg.sender == operator OR msg.sender == owner().

#### G-6: Fee collector receives all protocol fees
Every protocol fee computed by _computeFees is transferred to feeCollector via _pushTokens, followed by recordFee. No protocol fee is silently absorbed (except when _fromNorm truncates to 0 on low-decimal tokens).

---

## Inter-Contract Invariants

#### I-1: LP supply tracks minted minus burned

For each side S and tokenId T:
`LPToken.totalSupply(T) == sum_of_all_mints(T) - sum_of_all_burns(T)`

**Derivation:** `LPToken.mint` increments `totalSupply[tokenId]` then calls `_mint`. `LPToken.burn` decrements `totalSupply[tokenId]` then calls `_burn`. Both are `onlyPool(tokenId)` gated. No other path modifies `totalSupply`. The pool calls mint in `deposit` and burn in `withdrawal`/`withdrawProRata`. OZ ERC-1155 `_mint`/`_burn` enforce balance consistency internally.

#### I-2: Side value tracks deposits minus withdrawals plus LP fees

For each side S:
`sideValue(S) == sum_deposits(S) + sum_lpFees_credited(S) - sum_withdrawals(S)`
(all in normalized 18-dec units)

**Derivation:** `_addSideValue(S, normAmount)` is called in `deposit` (for deposit amount) and in `swap`/`withdrawal` (for LP fee credited to the drained/opposite side). `_subSideValue(S, shares)` is called in `withdrawal`/`withdrawProRata` (for the LP's claim). No other path modifies `aSideValue`/`bSideValue` except `_flushResidualIfEmpty` which zeros both when all LP is burned.

**Caveat (attack surface 2.1):** In last-LP same-side withdrawal, `_addSideValue(oppositeSide, lpFee)` credits a fee to a side that did not receive corresponding physical tokens -- the fee remains physically on the withdrawing side. This inflates opposite side's tracked value relative to its physical.

**Caveat (attack surface 2.2):** In cross-side withdrawal, `_addSideValue(receiveSide, lpFee)` credits LP fee to receive side, but the fee is deducted from the payout (receive-side physical decreases). Net physical change on receiveSide = -(shares - lpFee) but tracked change = +lpFee. Global sum is conserved but per-side diverges.

#### I-3: Fresh bucket amount <= user balance

For each user U, tokenId T:
`freshDeposit[U][T].amount <= balanceOf(U, T)`
(after graduation of matured deposits)

**Derivation:** On outflow, `_update` consumes matured first, then reduces `sf.amount` by `value - matured`. On inflow, `tf.amount += value` and balance also increases by `value` (from `super._update`). Graduation zeros `sf.amount` when `block.timestamp >= timestamp + LOCK_PERIOD`.

**Caveat (attack surface 2.3):** When `from == to` (self-transfer), `super._update` is a no-op on balance, but the outflow branch reads `preBalance = balanceOf(from, id) + value` (overestimated since balance was not reduced), and the inflow branch adds `value` to `tf.amount`. This can inflate `fresh.amount` above actual balance.

#### I-4: TokenId uniqueness per factory

For each PoolFactory instance:
- Each marketA tokenId is used by at most one pool: `usedMarketATokenId[id]` set true on first use, checked before reuse.
- Each marketB tokenId is used by at most one pool: `usedMarketBTokenId[id]` set true on first use.
- LP tokenId == market tokenId, so LP token registration cannot collide within a factory.

**Derivation:** `createPool` checks `usedMarketATokenId[marketA_.tokenId]` and `usedMarketBTokenId[marketB_.tokenId]` before setting them true. `LPToken.registerPool` independently rejects if `pool[tokenId] != address(0)`. Both are one-shot: no path unsets them.

---

## Cross-Function Invariants

#### X-1: Withdrawal payout <= LP claim value

For any withdrawal (same-side or cross-side):
`payout = shares - lpFee - protocolFee`, where `shares = lpAmount * rate / 1e18`.
Payout is always strictly less than or equal to the LP's proportional claim.

**Derivation:** `_lpToShares` computes `(lpAmount * rate) / RATE_PRECISION`. Fees are subtracted: `payout = shares - lpFee - protocolFee`. `_computeFees` uses ceiling rounding: `totalFee = (normAmount * totalBps + FEE_DENOMINATOR - 1) / FEE_DENOMINATOR`, ensuring fees are never undercharged. When resolved, fees are zero so payout == shares.

**Tested by:** `invariant_RateAtLeast1e18` (rate never decreases, so LP always gets at least deposit back from rate perspective). `testFuzz_Withdrawal_DepositWithdrawNoProfit` (no instant profit from deposit-then-withdraw).

#### X-2: JIT fee is proportional to fresh consumed

For same-side withdrawal when `!resolved`:
`feeBase = (shares * freshBurned) / lpAmount` where `freshBurned = max(0, lpAmount - matured)`.

**Derivation:** `_freshConsumedForBurn` reads `balance = lp.balanceOf(msg.sender, tokenId)` and `locked = lp.lockedAmount(msg.sender, tokenId)`. `matured = balance - locked`. `freshBurned = max(0, lpAmount - matured)`. Then `feeBase = (shares * freshBurned) / lpAmount` -- fee scales linearly with the fraction of LP that is fresh.

**Caveat:** If `lockedAmount` is inflated due to self-transfer corruption (I-3), `freshBurned` will be overestimated, and the user pays more JIT fee than warranted.

#### X-3: ProRata proportional fairness

For withdrawProRata:
`nativeShare = (lpAmount * availableNative) / totalSupply`, capped at `shares`.
Each LP gets the same fraction of native-side physical reserves.

**Derivation:** The formula ensures proportional distribution: two LPs with equal LP balances get equal shares of native reserves. The cap at `shares` prevents overpayment when native reserves exceed obligations. Cross-side remainder inherits the shortfall. No fees are charged.

**Tested by:** `testFuzz_ProRata_NeverOverpays`, `testFuzz_ProRata_NoFees`.

---

## Edge-Case Invariants

#### E-1: Flush residual sweep

When `aSupply + bSupply == 0` (all LP burned), `_flushResidualIfEmpty` zeros both `aSideValue` and `bSideValue`, then sweeps all remaining physical tokens to `feeCollector`.

**Derivation:** Called at the end of `withdrawal` and `withdrawProRata`. Checks `factory.marketALpToken().totalSupply(marketALpTokenId) + factory.marketBLpToken().totalSupply(marketBLpTokenId) == 0`. If true, reads raw balances of both sides and pushes any nonzero amount to feeCollector with `recordFee`.

**Tested by:** `testFuzz_FlushResidual_FullExit`.

**Significance:** Without this, rounding dust would be trapped permanently. The sweep ensures no value is locked in an empty pool.

#### E-2: First depositor gets 1:1 LP

When `totalSupply == 0` for a side, `deposit` mints `lpMinted = normAmount` (1:1 with normalized deposit).

**Derivation:** `SwapPool.deposit` line 268-269: `lpMinted = (supply == 0) ? normAmount : (normAmount * supply) / sideValue`. First depositor sets the baseline rate at exactly 1e18. Subsequent depositors get LP proportional to their contribution relative to existing sideValue.

**Significance:** No inflation attack vector because the first deposit directly sets supply = normAmount and sideValue = normAmount, yielding rate = 1e18. There is no share-price manipulation window between the first mint and value assignment (both happen atomically in the same call).
