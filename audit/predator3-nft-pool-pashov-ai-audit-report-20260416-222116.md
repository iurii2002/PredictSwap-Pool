# 🔐 Security Review — PredictSwap

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | default (full repo, 4 in-scope `.sol` files)           |
| **Files reviewed**               | `SwapPool.sol` · `PoolFactory.sol` · `LPToken.sol`<br>`FeeCollector.sol` |
| **Confidence threshold (1-100)** | 80                                                     |

---

## Findings

[85] **1. Same-token self-pair pool creation breaks rescue invariant and drains user deposits**

`PoolFactory.createPool` · Confidence: 85

**Description**
`createPool` does not require `(marketA_.marketContract, marketA_.tokenId) != (marketB_.marketContract, marketB_.tokenId)`. An operator mistake that creates a pool with identical sides causes `SwapPool.rescueTokens(Side.MARKET_A)` to compute `surplus = actual − tracked` where `actual = balanceOf(pool, sharedTokenId)` covers BOTH `marketABalance` and `marketBBalance` — so the owner's rescue call drains the opposite side's legitimately tracked LP deposits while preserving their LP token balance. Concrete trace: user deposits 100 into MARKET_B (`marketBBalance = 100`, `actual = 100`, `marketABalance = 0`); owner calls `rescuePoolTokens(poolId, MARKET_A, 100, attacker)`; `tracked = 0`, `actual = 100`, `surplus = 100`; pool transfers 100 of the shared ERC-1155 id to attacker; side-B LP's deposit is gone, side-B LP tokens still outstanding. The documented invariant "LP holder funds are never at risk" is broken by a missing one-line check.

**Fix**

```diff
 if (marketA_.tokenId == 0 || marketB_.tokenId == 0) revert InvalidTokenID();
 if (marketA_.decimals > 18 || marketB_.decimals > 18) revert InvalidDecimals();
 if (bytes(marketA_.name).length == 0 || bytes(marketB_.name).length == 0)
     revert MissingName();
+if (marketA_.marketContract == marketB_.marketContract &&
+    marketA_.tokenId == marketB_.tokenId) revert SameMarketNotAllowed();
```

---

[80] **2. Protocol fee silently evaded via decimal-flooring on low-decimal sides**

`SwapPool.swap` · `SwapPool.withdrawSingleSide` · `SwapPool.withdrawBothSides` · Confidence: 80

**Description**
`rawProtocol = _fromNorm(side, protocolFee)` floors in native decimals, and the subsequent `if (rawProtocol > 0)` gate skips the FeeCollector transfer entirely. For any side with <18 decimals and a swap/withdraw amount below the decimal threshold (e.g., at dec=6 with `protocolFeeBps=10`, any `normAmount < ~1e15` produces `rawProtocol = 0`), 100% of the protocol fee slice stays in the pool as implicit LP fee instead of being routed to the FeeCollector. Prediction-market ERC-1155 shares are commonly 6-decimal, and small-share trades are the dominant volume — protocol revenue systematically leaks to LPs on every sub-threshold operation.

**Fix**

```diff
-uint256 rawProtocol = _fromNorm(fromSide, protocolFee);
+// Ceiling-round the raw protocol fee so any non-zero normalized fee
+// routes at least 1 raw unit to FeeCollector.
+uint256 rawProtocol;
+{
+    uint8 dec = fromSide == Side.MARKET_A ? marketADecimals : marketBDecimals;
+    if (protocolFee == 0)            { rawProtocol = 0; }
+    else if (dec == 18)              { rawProtocol = protocolFee; }
+    else {
+        uint256 scale = 10 ** (18 - dec);
+        rawProtocol = (protocolFee + scale - 1) / scale;
+    }
+}
```
*(apply identically wherever `_fromNorm(..., protocolFee)` / `_fromNorm(..., crossProtocolFee)` is used)*

---

[75] **3. Non-canonical `_poolKey` allows duplicate pools for the same market pair**

`PoolFactory._poolKey` · `PoolFactory.createPool` · Confidence: 75

**Description**
`_poolKey(A, tA, B, tB) ≠ _poolKey(B, tB, A, tA)` because the hash encodes arguments in the supplied order. Operator can register the same economic pair twice with A/B flipped, fragmenting LP liquidity and breaking the stated "one pool per matched pair" registry invariant; `findPool` returns only one direction, so integrators must query both orderings to avoid creating duplicates.

---

[75] **4. Last LP cross-side exit forfeits their own paid LP fee to FeeCollector**

`SwapPool.withdrawSingleSide` · `SwapPool.withdrawBothSides` · `SwapPool._flushResidualIfEmpty` · Confidence: 75

**Description**
When the sole remaining LP exits via a cross-side (or both-sides with a cross portion) branch, they are charged `lpFee` on the cross portion; the fee remains in the pool on the receive side; `totalLpSupply()` immediately drops to 0; `_flushResidualIfEmpty()` then sweeps that freshly-paid lpFee (plus any sameside-unclaimable remainder) to FeeCollector. The exiter effectively pays `lpFee + protocolFee` to protocol rather than the documented `protocolFee` alone. Worst-case loss is bounded by `MAX_LP_FEE` (1%) of the cross-exit portion. The residual-flush behavior is documented for a *different* reason ("prevents first-depositor capture"), but the last-exiter tradeoff is not; a MINIMUM_LIQUIDITY-style lock on first deposit, or waiving lpFee when the exit empties the pool, would eliminate the double-charge.

---

[75] **5. Swap / withdraw paths accept zero-raw-output and destroy LP without compensation**

`SwapPool.swap` · `SwapPool.withdrawSingleSide` · `SwapPool.withdrawBothSides` · Confidence: 75

**Description**
When input or LP burn amounts are small enough that `_fromNorm(receiveSide, normOut)` floors to 0 on a <18-decimal side, the functions proceed silently: pool pulls input (or burns LP), the `if (sharesOut > toBalance)` check passes when both are zero, user receives zero shares. No `ZeroAmount` revert is applied on the *output* (only on the input). Primarily self-harm — value stays in pool benefiting remaining LPs — but a guaranteed-non-zero-output invariant is standard and trivial to add.

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [85] | Same-token self-pair pool creation breaks rescue invariant |
| 2 | [80] | Protocol fee silently evaded via decimal-flooring |
| 3 | [75] | Non-canonical `_poolKey` allows duplicate pools |
| 4 | [75] | Last LP cross-side exit forfeits paid LP fee to FeeCollector |
| 5 | [75] | Swap / withdraw paths accept zero-raw-output |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **CEI violation / read-only reentrancy in swap** — `SwapPool.swap` — Code smells: `_updateBalance` for both sides runs AFTER `_pullTokens`/`_pushTokens(feeCollector)`/`feeCollector.recordFee`/`_pushTokens(msg.sender)`; `onERC1155Received` on a contract `msg.sender` fires while `marketABalance`/`marketBBalance`/`exchangeRate()` still hold pre-swap values — `nonReentrant` blocks same-pool re-entry but downstream integrators reading `exchangeRate()` during the callback see stale state. No concrete external consumer of this pool's `exchangeRate()` identified; exploitability depends on integration surface.
- **Unauthenticated `recordFee` event emitter** — `FeeCollector.recordFee` — Code smells: no access control, any caller emits `FeeReceived(msg.sender, token, tokenId, amount)`; NatSpec acknowledges "filter by msg.sender in indexer." Off-chain accounting/analytics/automation that reads these events without a per-pool allowlist can be poisoned with fabricated fee flows. No on-chain fund impact.
- **Contract-level (not `(contract, tokenId)`) block in `rescueERC1155`** — `SwapPool.rescueERC1155` — Code smells: reverts when `contractAddress_ == marketAContract || contractAddress_ == marketBContract`, ignoring `tokenId_`. Prediction-market ERC-1155 contracts expose many outcome tokenIds on a single contract address; any foreign tokenId on the same contract accidentally sent to the pool is permanently unrecoverable.
- **`unsetResolved` leaves deposits paused** — `SwapPool.unsetResolved` — Code smells: `setResolvedAndPausedDeposits` atomically sets both flags; `unsetResolved` clears only `resolved` and leaves `depositsPaused = true`, requiring a separate `setPoolDepositsPaused(false)` call. State-coupling asymmetry — not a fund-loss, but an operational footgun after an accidental resolve.
- **Cross-side exit DoS when `resolved && swapsPaused`** — `SwapPool.withdrawSingleSide` / `SwapPool.withdrawBothSides` — Code smells: `if (swapsPaused) revert SwapsPaused();` is checked BEFORE the `if (resolved)` fee-free branch on cross-side paths. A resolved pool whose swaps are paused blocks LPs on the losing side from claiming winning-side shares until operator unpauses. Reorder the checks or allow `resolved` to bypass `swapsPaused`.
- **Operator resolve/unresolve toggles a fee-free cross-side window** — `PoolFactory.resolvePoolAndPausedDeposits` / `PoolFactory.unresolvePool` — Code smells: `setFees` is owner-gated, but operator-only `resolve`/`unresolve` lets the fast-role flip cross-side withdrawals to zero-fee and back. A compromised operator can resolve, let a confederate drain cross-side fee-free, then unresolve.
- **`_toNorm` overflow at `decimals = 0` with whale-sized balances** — `SwapPool._toNorm` — Code smells: `raw * 10**(18-dec)` overflows uint256 when `dec = 0` and `raw ≥ ~1.16e59`. Factory caps decimals at 18 but sets no floor; for integer-valued ERC-1155 share designs, deposit/swap would DoS via overflow rather than silently corrupt. Low reachability but zero guard.
- **`FeeCollector.withdrawBatch` / `withdrawAllBatch` behavior on zero-amount entries and mismatched lengths** — `FeeCollector.withdrawBatch` / `withdrawAllBatch` — Code smells: no explicit length-equality check on `tokenIds`/`amounts`; `withdrawAllBatch` leaves zero-amount entries in the array passed to `safeBatchTransferFrom`. Non-standard ERC-1155 implementations (some prediction-market wrappers) can revert on zero-amount batch entries; owner call would unexpectedly revert. Liveness concern only.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
