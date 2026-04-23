# Invariants -- PredictSwap v3

Linked from [x-ray.md](x-ray.md) Section 3. Each invariant uses an `####` heading for cross-file anchors.

---

## 1. Enforced Guards

Guards are explicit `require`/`if-revert` checks on storage variables that the compiler enforces.
Format: **predicate** -- location -- purpose.

#### G-1 depositsPaused gate
`if (depositsPaused) revert DepositsPaused()` -- `SwapPool.sol:258` -- Blocks deposits when operator has paused the pool.

#### G-2 resolved gate (deposit)
`if (resolved) revert MarketResolved()` -- `SwapPool.sol:259` -- Prevents deposits into a resolved market.

#### G-3 zero-amount deposit
`if (amount == 0) revert ZeroAmount()` -- `SwapPool.sol:260` -- Rejects zero-value deposit calls.

#### G-4 dust deposit
`if (lpMinted == 0) revert DepositTooSmall()` -- `SwapPool.sol:271` -- Prevents dust deposits that round to zero LP tokens.

#### G-5 swapsPaused gate (swap)
`if (swapsPaused) revert SwapsPaused()` -- `SwapPool.sol:290` -- Blocks swaps when operator has paused swaps.

#### G-6 zero-amount swap
`if (sharesIn == 0) revert ZeroAmount()` -- `SwapPool.sol:291` -- Rejects zero-value swap calls.

#### G-7 swap liquidity check
`if (normOut > availableOut) revert InsufficientLiquidity(availableOut, normOut)` -- `SwapPool.sol:301` -- Ensures the output side has enough physical tokens to fill the swap.

#### G-8 zero-output swap
`if (rawOut == 0) revert SwapTooSmall()` -- `SwapPool.sol:315` -- Prevents swaps that produce zero output after truncation.

#### G-9 swapsPaused gate (withdrawal)
`if (swapsPaused) revert SwapsPaused()` -- `SwapPool.sol:342` -- Standard withdrawal only available when swaps are active; directs users to withdrawProRata.

#### G-10 zero-amount withdrawal
`if (lpAmount == 0) revert ZeroAmount()` -- `SwapPool.sol:343` -- Rejects zero-value withdrawal calls.

#### G-11 withdrawal liquidity check
`if (totalOutflow > available) revert InsufficientLiquidity(available, totalOutflow)` -- `SwapPool.sol:370` -- Ensures the receive side has enough physical tokens for payout + protocol fee combined.

#### G-12 swapsNotPaused gate (withdrawProRata)
`if (!swapsPaused) revert SwapsNotPaused()` -- `SwapPool.sol:426` -- Pro-rata exit only available when swaps are paused.

#### G-13 zero-amount withdrawProRata
`if (lpAmount == 0) revert ZeroAmount()` -- `SwapPool.sol:427` -- Rejects zero-value pro-rata withdrawal calls.

#### G-14 cross-side liquidity (withdrawProRata)
`if (crossShare > availableCross) revert InsufficientLiquidity(availableCross, crossShare)` -- `SwapPool.sol:446` -- Ensures the cross-side has enough tokens for the remainder.

#### G-15 fee cap LP (constructor)
`if (lpFeeBps_ > MAX_LP_FEE) revert FeeTooHigh()` -- `SwapPool.sol:176` -- Hard cap LP fee at 1.00% at deployment.

#### G-16 fee cap protocol (constructor)
`if (protocolFeeBps_ > MAX_PROTOCOL_FEE) revert FeeTooHigh()` -- `SwapPool.sol:177` -- Hard cap protocol fee at 0.50% at deployment.

#### G-17 fee cap LP (setFees)
`if (lpFeeBps_ > MAX_LP_FEE) revert FeeTooHigh()` -- `SwapPool.sol:527` -- Hard cap LP fee at 1.00% on fee change.

#### G-18 fee cap protocol (setFees)
`if (protocolFeeBps_ > MAX_PROTOCOL_FEE) revert FeeTooHigh()` -- `SwapPool.sol:528` -- Hard cap protocol fee at 0.50% on fee change.

#### G-19 factory-only initialize
`if (msg.sender != address(factory)) revert Unauthorized()` -- `SwapPool.sol:195` -- Only the factory can initialize a pool.

#### G-20 one-shot initialize
`if (_initialized) revert AlreadyInitialized()` -- `SwapPool.sol:196` -- Pool can only be initialized once.

#### G-21 valid LP token IDs (initialize)
`if (marketALpTokenId_ == 0 || marketBLpTokenId_ == 0) revert InvalidTokenID()` -- `SwapPool.sol:197` -- Prevents zero LP token IDs during initialization.

#### G-22 whenInitialized modifier
`if (!_initialized) revert NotInitialized()` -- `SwapPool.sol:205` -- All user operations require the pool to be initialized.

#### G-23 factory-only admin (SwapPool)
`if (msg.sender != address(factory)) revert Unauthorized()` -- `SwapPool.sol:498,503,509,515,525,538,552,562,569` -- All SwapPool admin functions gated by factory address.

#### G-24 zero-address constructor guards
`if (factory_ == address(0) || feeCollector_ == address(0)) revert ZeroAddress()` -- `SwapPool.sol:173` -- Prevents deployment with zero-address dependencies.

#### G-25 decimal bound
`if (marketA_.decimals > 18 || marketB_.decimals > 18) revert InvalidDecimals()` -- `SwapPool.sol:175` -- Prevents overflow in normalization math.

#### G-26 onlyPool (LPToken)
`if (msg.sender != pool[tokenId]) revert OnlyPool()` -- `LPToken.sol:84` -- Only the registered pool can mint/burn a given tokenId.

#### G-27 onlyFactory (LPToken)
`if (msg.sender != factory) revert OnlyFactory()` -- `LPToken.sol:98` -- Only the factory can register new pool-tokenId bindings.

#### G-28 one-shot registerPool
`if (pool[tokenId] != address(0)) revert TokenIdAlreadyRegistered()` -- `LPToken.sol:101` -- Each tokenId can only be registered to one pool, permanently.

#### G-29 unique pool pair (PoolFactory)
`if (poolIndex[key] != 0) revert PoolAlreadyExists(key)` -- `PoolFactory.sol:203` -- Prevents creating duplicate pools for the same A/B tokenId pair.

#### G-30 unique market-A tokenId
`if (usedMarketATokenId[marketA_.tokenId]) revert MarketATokenIdAlreadyUsed(...)` -- `PoolFactory.sol:204` -- Each A-side tokenId used at most once across all pools in this factory.

#### G-31 unique market-B tokenId
`if (usedMarketBTokenId[marketB_.tokenId]) revert MarketBTokenIdAlreadyUsed(...)` -- `PoolFactory.sol:205` -- Each B-side tokenId used at most once across all pools in this factory.

#### G-32 operator access control
`if (msg.sender != operator && msg.sender != owner()) revert NotOperator()` -- `PoolFactory.sol:139` -- Operator-gated functions also allow owner.

#### G-33 zero-tokenId rejection (createPool)
`if (marketA_.tokenId == 0 || marketB_.tokenId == 0) revert InvalidTokenID()` -- `PoolFactory.sol:199` -- Prevents zero tokenIds in pool creation.

#### G-34 rescueTokens surplus check
`if (normAmount == 0 || physical <= tracked) revert NothingToRescue()` followed by `if (normAmount > surplus) revert NothingToRescue()` -- `SwapPool.sol:545-547` -- Rescue limited to surplus above tracked value.

#### G-35 rescueERC1155 pool token guard
`if (contractAddress_ == mktA || contractAddress_ == mktB) revert CannotRescuePoolTokens()` -- `SwapPool.sol:557` -- Prevents rescue of any tokenId from market contract addresses.

#### G-36 FeeCollector zero-amount guard
`if (amount == 0) revert ZeroAmount()` -- `FeeCollector.sol:34` -- Prevents meaningless zero-amount fee records.

---

## 2. Inferred Single-Contract Invariants

Derived from delta-writes, guard-lifts, temporal properties, or NatSpec. Not enforced by single explicit checks.

#### I-1 Value conservation

**Predicate:** `aSideValue + bSideValue == physicalBalanceNorm(MARKET_A) + physicalBalanceNorm(MARKET_B) - protocolFeesExtracted - rescuedSurplus` (modulo `_fromNorm` truncation dust).

**Derivation (delta-pair):**
- `deposit()`: `_addSideValue(side, normAmount)` at `SwapPool.sol:273` paired with `_pullTokens` at `:262`. Both += normAmount.
- `swap()`: `_addSideValue(toSide, lpFee)` at `:319`. Physical change: +normIn (pulled) -normOut (pushed to user) -protocolFee (pushed to collector) = +lpFee. Matches.
- `withdrawal()`: `_subSideValue` at `:380-387`. Physical: -payout -protocolFee = -(shares - lpFee). lpFee stays in value or redirects to opposite side. Matches.
- `withdrawProRata()`: `_subSideValue(lpSide, shares)` at `:450`. Physical: -nativeShare -crossShare = -shares. Matches.
- `_flushResidualIfEmpty()`: zeros both values, sweeps all physical to FeeCollector. Terminal cleanup.
- `_fromNorm` truncation at `:653` means physical out <= normalized value. Dust accumulates in pool's favor.

**Strength:** Partial -- rounding dust from `_fromNorm` truncation means physical >= accounted over time. The `_flushResidualIfEmpty` sweep handles terminal dust.

#### I-2 LP fee BPS bound

**Predicate:** `lpFeeBps in [0, 100]` at all times.

**Derivation (guard-lift):** Enforced at constructor `SwapPool.sol:176` and `setFees` `SwapPool.sol:527`. Both guarded by `MAX_LP_FEE = 100`. No other write path to `lpFeeBps` exists (`:186`, `:529`).

**Strength:** Strong.

#### I-3 Protocol fee BPS bound

**Predicate:** `protocolFeeBps in [0, 50]` at all times.

**Derivation (guard-lift):** Enforced at constructor `SwapPool.sol:177` and `setFees` `SwapPool.sol:528`. Both guarded by `MAX_PROTOCOL_FEE = 50`. No other write path to `protocolFeeBps` exists (`:187`, `:530`).

**Strength:** Strong.

#### I-4 LP minting ratio

**Predicate:** When `supply > 0`: `lpMinted = (normAmount * supply) / sideValue`. When `supply == 0`: `lpMinted = normAmount`.

**Derivation (delta-pair):** `SwapPool.sol:268-270`. Snapshots of `supply` and `sideValue` taken before state changes in same function body. Truncates `lpMinted` downward.

**Strength:** Strong -- directly coded.

#### I-5 LP-to-shares conversion

**Predicate:** `shares = (lpAmount * rate) / RATE_PRECISION` where `rate = sideValue * RATE_PRECISION / supply`.

**Derivation (delta-pair):** `_lpToShares` at `SwapPool.sol:583-585`, `marketARate` at `SwapPool.sol:212-216`, `marketBRate` at `:219-222`. Combined: `shares = lpAmount * sideValue / supply`. Both truncate downward.

**Strength:** Strong -- directly coded.

#### I-6 Initialize one-shot latch

**Predicate:** `_initialized` transitions `false -> true` exactly once, never reverts to `false`.

**Derivation (state-machine):** `SwapPool.sol:196` guards with `if (_initialized) revert`. `:198` sets `_initialized = true`. No function sets it back to `false`. Single write site.

**Strength:** Strong.

#### I-7 Pool registration one-shot latch

**Predicate:** `LPToken.pool[tokenId]` transitions from `address(0)` to a non-zero address exactly once per tokenId, never cleared.

**Derivation (state-machine):** `LPToken.sol:101` guards with `if (pool[tokenId] != address(0)) revert`. `:102` writes `pool[tokenId] = pool_`. No function resets to `address(0)`.

**Strength:** Strong.

#### I-8 Rate monotonicity (swaps only)

**Predicate:** For a given side, `rate = sideValue * 1e18 / supply` is non-decreasing across swap operations.

**Derivation (delta-pair):** Swaps add `lpFee > 0` to the drained side's value at `SwapPool.sol:319` without changing supply (no LP mint/burn in swap). Deposits maintain rate by proportional minting at `:268-270`. Rate can only decrease from rounding in withdrawal.

**Strength:** Partial -- withdrawal of the last LP with fee redirects lpFee to opposite side at `:380-381`, which is a design choice affecting the withdrawer, not a rate decrease for remaining LPs.

#### I-9 Fresh bucket temporal bound

**Predicate:** `lockedAmount(user, tokenId) == 0` when `block.timestamp >= freshDeposit[user][tokenId].timestamp + LOCK_PERIOD`.

**Derivation (temporal):** `LPToken.sol:121` returns 0 when the fresh bucket has aged past 24h, even before on-chain graduation. `LOCK_PERIOD = 24 hours` is a constant at `:51`.

**Strength:** Strong -- directly coded in view function.

#### I-10 totalSupply tracks mints and burns

**Predicate:** `totalSupply[tokenId] = sum_of_mints(tokenId) - sum_of_burns(tokenId)`.

**Derivation (delta-pair):** `LPToken.sol:107` increments on mint, `:112` decrements on burn. Both gated by `onlyPool`. No other write path. OZ ERC1155 `_update` handles `balanceOf` separately; transfers do not change `totalSupply`.

**Strength:** Strong.

#### I-11 Matured-first consumption

**Predicate:** On outflow (burn or transfer-out), the fresh bucket only decreases by `max(0, outflow - matured)`.

**Derivation (delta-pair):** `LPToken._update` at `LPToken.sol:157-162`. `matured = preBalance - sf.amount`. If `value > matured`, fresh decreases by `value - matured`. Matured tokens consumed first.

**Strength:** Strong -- directly coded.

#### I-12 Fee computation ceiling rounding

**Predicate:** `totalFee = ceil(normAmount * totalBps / FEE_DENOMINATOR)`. Then `protocolFee = floor(totalFee * protocolFeeBps / totalBps)` and `lpFee = totalFee - protocolFee`.

**Derivation (delta-pair):** `SwapPool.sol:241` uses `(normAmount * totalBps + FEE_DENOMINATOR - 1) / FEE_DENOMINATOR` (ceiling division). `:242` uses floor division for protocol split. `:243` gives remainder to LP. Total fee rounding favors protocol; split rounding within total slightly favors LP.

**Strength:** Strong -- directly coded.

#### I-13 usedMarketATokenId is one-way

**Predicate:** `usedMarketATokenId[id]` once set to `true`, never reverted to `false`.

**Derivation (guard-lift):** `PoolFactory.sol:204` guards with `if (usedMarketATokenId[...]) revert`. `:220` writes `usedMarketATokenId[lpIdA] = true`. No function resets to `false`.

**Strength:** Strong.

#### I-14 usedMarketBTokenId is one-way

**Predicate:** `usedMarketBTokenId[id]` once set to `true`, never reverted to `false`.

**Derivation (guard-lift):** `PoolFactory.sol:205` guards with `if (usedMarketBTokenId[...]) revert`. `:221` writes `usedMarketBTokenId[lpIdB] = true`. No function resets to `false`.

**Strength:** Strong.

#### I-15 Weighted-average timestamp on fresh merge

**Predicate:** When merging into an existing fresh bucket, `tf.timestamp = (tf.amount * tf.timestamp + value * block.timestamp) / (tf.amount + value)`.

**Derivation (delta-pair):** `LPToken.sol:183-185`. The weighted average always produces a timestamp between the old `tf.timestamp` and `block.timestamp`. The new timestamp is >= old timestamp (since `block.timestamp >= tf.timestamp`), so the lock period is extended toward the present.

**Strength:** Strong -- directly coded. However, the extension effect is the basis for the JIT lock manipulation attack surface.

---

## 3. Cross-Contract Invariants

Edges that span two or more contracts.

#### X-1 LP supply reflects pool mints and burns only

**Predicate:** `LPToken.totalSupply[tokenId]` changes only via `mint` and `burn` calls from the registered pool.

**Derivation (edge):** `LPToken.mint` at `LPToken.sol:107` and `LPToken.burn` at `:112` are the only writers, both gated by `onlyPool(tokenId)` at `:83-86`. Pool address set by `registerPool` at `:102`, gated by `onlyFactory` at `:98`. SwapPool reads `totalSupply` at `SwapPool.sol:213,220,265,374,435,473-474`.

**Strength:** Strong.

#### X-2 FeeCollector receives tokens before recordFee

**Predicate:** SwapPool pushes ERC-1155 tokens to FeeCollector via `_pushTokens` before calling `recordFee`. If the push reverts, `recordFee` never executes.

**Derivation (edge):**
- In `swap()`: `_pushTokens` at `SwapPool.sol:309` then `recordFee` at `:310`.
- In `withdrawal()`: `_pushTokens` at `:400` then `recordFee` at `:401`.
- In `_flushResidualIfEmpty()`: `_pushTokens` at `:486` then `recordFee` at `:487`, and `:490` then `:491`.
- All three call sites maintain push-before-record ordering.

**Strength:** Strong.

#### X-3 SwapPool reads LPToken fresh bucket before burn

**Predicate:** `SwapPool._freshConsumedForBurn` reads `LPToken.lockedAmount` and `balanceOf` before `_burnLp` modifies the fresh bucket via `LPToken._update`.

**Derivation (edge):** `_freshConsumedForBurn` called at `SwapPool.sol:352` reads `lp.balanceOf` and `lp.lockedAmount` at `:594-595`. `_burnLp` called later at `:391` triggers `LPToken._update` which modifies `freshDeposit`. The read-before-burn ordering ensures the fee base reflects the pre-burn fresh amount.

**Strength:** Strong.

#### X-4 FeeCollector address immutable in deployed pools

**Predicate:** `SwapPool.feeCollector` is `immutable` (set at construction). `PoolFactory.setFeeCollector` only affects pools created after the change.

**Derivation (edge):** `SwapPool.sol:63` declares `FeeCollector public immutable feeCollector`. `PoolFactory.createPool` passes `address(feeCollector)` at `PoolFactory.sol:213`. `PoolFactory.setFeeCollector` at `:283-286` updates factory storage but cannot retroactively change immutable in existing pools.

**Strength:** Strong -- Solidity language guarantee. Design decision, not a bug.

#### X-5 Factory deploys and immediately initializes

**Predicate:** Every SwapPool created by `PoolFactory.createPool` is initialized atomically in the same transaction. No front-running window exists.

**Derivation (edge):** `PoolFactory.createPool` at `PoolFactory.sol:207` deploys `new SwapPool(...)`, then calls `registerPool` on both LPTokens at `:222-223`, then `pool_.initialize(lpIdA, lpIdB)` at `:225`. All in one transaction. The `_initialized` one-shot latch at `SwapPool.sol:196` prevents re-initialization.

**Strength:** Strong.

#### X-6 Admin calls two-layer access control

**Predicate:** All SwapPool admin functions require `msg.sender == address(factory)`. The factory restricts callers to operator (via `onlyOperator`) or owner (via `onlyOwner`). Two-layer gating.

**Derivation (edge):** SwapPool checks at `SwapPool.sol:498,503,509,515,525,538,552,562,569`. PoolFactory operator check at `PoolFactory.sol:138-141`. Owner check via OZ `Ownable.onlyOwner`. Factory address is immutable on pool at `SwapPool.sol:55`.

**Strength:** Strong.

#### X-7 SwapPool assumes factory LP token references are immutable

**Predicate:** `SwapPool._lpToken()` calls `factory.marketALpToken()` / `factory.marketBLpToken()`, which are declared `immutable` on PoolFactory.

**Derivation (edge):** `SwapPool.sol:637-638` reads LP token from factory. `PoolFactory.sol:70-73` declares both as `LPToken public immutable`. Set in constructor at `:172-173`. Cannot change post-deploy.

**Strength:** Strong.

#### X-8 External ERC-1155 trust assumption

**Predicate:** SwapPool assumes external ERC-1155 market contracts transfer exact amounts, revert on failure, and do not have fee-on-transfer behavior.

**Derivation (edge):** `SwapPool._pullTokens` at `SwapPool.sol:657` and `_pushTokens` at `:661` call `IERC1155.safeTransferFrom`. The pool updates internal accounting by the requested `amount` without checking actual balance change. Market contracts are immutably bound at `PoolFactory.sol:165-166`.

**Strength:** Not enforced on-chain. If external contract has non-standard behavior, conservation invariant I-1 breaks.

---

## 4. Economic Invariants

Higher-order properties deriving from I-N + X-N combinations.

#### E-1 LP share value non-decreasing from fee accrual

**Predicate:** For a given side, the LP rate (`sideValue / supply`) never decreases due to swap fees. Swap fees always add to `sideValue` without minting new LP.

**Derivation:** Swaps credit `lpFee` to the drained side's value at `SwapPool.sol:319` without changing supply. Deposits maintain rate by proportional minting at `:268-270`. The rate can only decrease from rounding in withdrawal, which truncates the withdrawer's claim downward.

**Linked invariants:** [I-8](#i-8-rate-monotonicity-swaps-only), [I-4](#i-4-lp-minting-ratio), [I-1](#i-1-value-conservation).

**Strength:** Partial -- edge case: last-LP same-side withdrawal redirects lpFee to opposite side at `:377-381`. The last LP on a side does not capture their own JIT fee.

#### E-2 No value extraction without LP burn or valid swap

**Predicate:** Tokens can only leave the pool via: (a) `withdrawal`/`withdrawProRata` which burns proportional LP, (b) `swap` which requires equal-value input minus fees, (c) `rescueTokens` which is owner-only and limited to surplus above tracked value, (d) `_flushResidualIfEmpty` which only runs when all LP is burned.

**Derivation:** All outflow paths via `_pushTokens`: `swap` at `SwapPool.sol:309,316`, `withdrawal` at `:395,400`, `withdrawProRata` at `:457,461`, `rescueTokens` at `:548`, `rescueERC1155` at `:558` (non-pool tokens only per G-35), `_flushResidualIfEmpty` at `:486,490`. Each path either requires LP burn, input tokens, owner auth, or empty pool.

**Linked invariants:** [I-1](#i-1-value-conservation), [I-5](#i-5-lp-to-shares-conversion), [G-7](#g-7-swap-liquidity-check), [G-11](#g-11-withdrawal-liquidity-check), [G-34](#g-34-rescuetokens-surplus-check).

**Strength:** Strong -- assuming no rounding exploits in the share math.

#### E-3 Rounding favors the pool

**Predicate:** `_fromNorm` truncates downward at `SwapPool.sol:653`, so users receive slightly less than their normalized entitlement when market tokens have < 18 decimals. The pool retains rounding dust.

**Derivation:** `_fromNorm` divides by `10 ** (18 - dec)` which truncates toward zero. Physical tokens sent out are <= normalized value. Over many operations, dust accumulates in the pool's favor. `_flushResidualIfEmpty` sweeps this dust to FeeCollector when all LP is burned.

**Linked invariants:** [I-1](#i-1-value-conservation), [I-12](#i-12-fee-computation-ceiling-rounding).

**Strength:** Strong for individual operations. Cumulative dust is bounded by operation count times the truncation unit.

#### E-4 First depositor rate is 1:1

**Predicate:** When `supply == 0`, `lpMinted = normAmount` at `SwapPool.sol:269`. The first depositor's LP is worth exactly 1 normalized unit per LP token. No minimum liquidity burn.

**Derivation:** First deposit mints 1:1. No donation attack vector exists because the pool uses internal accounting (`aSideValue`/`bSideValue`) rather than `balanceOf` for minting math. Donated tokens increase `physicalBalanceNorm` but not `sideValue`, so they do not inflate the share price. The surplus is rescuable via `rescueTokens`.

**Linked invariants:** [I-4](#i-4-lp-minting-ratio), [G-34](#g-34-rescuetokens-surplus-check).

**Strength:** Strong -- donation-immune by design.
