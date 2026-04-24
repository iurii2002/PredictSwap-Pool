# X-Ray Report

> PredictSwap | 841 nSLOC | a466b8c (`main`) | Foundry | 24/04/26

---

## 1. Protocol Overview

**What it does:** A 1:1 swap pool for matched ERC-1155 prediction-market shares across two platforms, with single-sided LP positions and per-side rate accounting.

- **Users**: LPs deposit single-sided shares to earn fees; traders swap shares between platforms at 1:1 minus fees
- **Core flow**: Deposit ERC-1155 shares on one side, receive LP tokens, swap drains the other side's reserves, LP fee accrues to drained-side rate
- **Key mechanism**: Simplified 1:1 AMM with dual-value accounting (`aSideValue` / `bSideValue`) in 18-decimal normalized units; no constant-product curve
- **Token model**: Two ERC-1155 LPToken instances (one per market side), shared across all pools on a factory; LP tokenId mirrors the underlying market tokenId
- **Admin model**: Owner (intended multisig) controls fees and rescue; Operator (EOA) manages pool lifecycle (create, pause, resolve); no timelock on any action

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| Pool | SwapPool | 459 | 1:1 AMM with dual-value accounting, swap/deposit/withdraw logic |
| Factory & Registry | PoolFactory | 216 | Deploys pools, manages LP token instances, operator/owner admin |
| LP Token | LPToken | 105 | ERC-1155 LP positions with per-user two-bucket JIT lock |
| Fee Collection | FeeCollector | 61 | Accumulates and distributes protocol fee shares |

### How It Fits Together

The core trick: both sides of a prediction market share pair are treated as economically equivalent (1:1), so the pool needs only scalar value tracking per side rather than a bonding curve.

### Deposit & LP Minting

```
User
 └─ SwapPool.deposit(side, amount)
     ├─ _pullTokens(side, user, amount)         *ERC-1155 safeTransferFrom*
     ├─ lpMinted = normAmount * supply / sideValue   *1:1 on first deposit*
     ├─ _addSideValue(side, normAmount)          *aSideValue or bSideValue += norm*
     └─ _mintLp(side, user, lpMinted)
         └─ LPToken.mint(user, tokenId, amount)  *triggers _update -> fresh bucket*
```

### Swap

```
User
 └─ SwapPool.swap(fromSide, sharesIn)
     ├─ _computeFees(normIn) -> lpFee, protocolFee
     ├─ physicalBalanceNorm(toSide) check         *revert if insufficient*
     ├─ _pullTokens(fromSide, user, sharesIn)     *input shares enter pool*
     ├─ _pushTokens(fromSide, feeCollector, rawProtocol)  *protocol fee out*
     ├─ _pushTokens(toSide, user, rawOut)         *output shares to user*
     └─ _distributeLpFee(toSide, fromSide, lpFee, normOut)
         └─ *splits fee between drained-side and from-side LPs by value ratio*
```

### Withdrawal (swaps active)

```
User
 └─ SwapPool.withdrawal(receiveSide, lpAmount, lpSide)
     ├─ _lpToShares(lpSide, lpAmount) -> shares
     ├─ fee path: same-side=JIT on fresh only, cross-side=full fee (0 if resolved)
     ├─ InsufficientLiquidity check on receiveSide
     ├─ _burnLp(lpSide, user, lpAmount)           *LPToken.burn -> _update*
     ├─ value accounting: _subSideValue + _distributeLpFee (or redirect if last LP)
     ├─ _pushTokens(receiveSide, user, rawPayout)
     ├─ _pushTokens(receiveSide, feeCollector, rawProto)  *if protocolFee > 0*
     └─ _flushResidualIfEmpty()                   *sweep dust if all LPs gone*
```

### Withdraw Pro-Rata (swaps paused)

```
User
 └─ SwapPool.withdrawProRata(lpAmount, lpSide)
     ├─ nativeShare = lpAmount * physicalNative / totalSupply  *capped at claim*
     ├─ crossShare = claim - nativeShare
     ├─ _burnLp, _subSideValue
     ├─ _pushTokens(nativeSide, user, rawNative)
     ├─ _pushTokens(crossSide, user, rawCross)    *remainder in cross tokens*
     └─ _flushResidualIfEmpty()
```

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **DEX/AMM** with **Yield Aggregator** characteristics

Swap/deposit/withdraw with LP token mint/burn and fee tiers are classic DEX/AMM signals. Per-side rate growth from accumulated fees mirrors vault-style share appreciation, giving it yield aggregator characteristics.

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| Owner | Trusted | `setOperator`, `setFeeCollector`, `setPoolFees`, all `rescuePool*` -- all instant, no timelock. Can also perform operator actions. |
| Operator | Bounded (lifecycle only) | `createPool`, `setPoolDepositsPaused`, `setPoolSwapsPaused`, `setResolvePool`, `resolvePoolAndPause` -- all instant. Cannot change fees or rescue funds. |
| User / LP | Untrusted | `deposit`, `swap`, `withdrawal`, `withdrawProRata` -- all nonReentrant-guarded. |

**Adversary Ranking** (ordered by threat level):

1. **MEV searcher / sandwich attacker** -- 1:1 swap pools with fixed fees are sandwich targets when one side has low liquidity; fee is the only slippage.
2. **Malicious first LP / empty pool attacker** -- First deposit mints LP 1:1 with no minimum liquidity; empty-pool transitions are a known DEX risk surface.
3. **Compromised operator** -- Can resolve or pause at the wrong time, enabling fee-free withdrawals or blocking user exits.
4. **Compromised owner** -- Instant fee changes, feeCollector redirect, and rescue powers with no timelock or delay.
5. **Liquidity manipulation attacker** -- Strategic single-sided deposits and withdrawals to distort the fee distribution ratio in `_distributeLpFee`.

See [entry-points.md](entry-points.md) for the full permissionless entry point map.

### Trust Boundaries

- **Factory -> Pool admin** -- all SwapPool admin functions check `msg.sender == address(factory)`; factory immutable. If factory owner key is compromised, every pool is exposed to instant fee changes (up to 1.5%) and fund rescue via `rescueTokens`.

- **Operator lifecycle gate** -- operator can resolve without pausing (`setResolvePool`), waiving all withdrawal fees. Comment at `PoolFactory.sol:314` warns `resolvePoolAndPause` should be used; using `setResolvePool` alone opens a window for fee-free cross-side exits before pause.

- **LPToken pool registration** -- one-shot `registerPool` binds tokenId to pool address permanently (`LPToken.sol:101`). Only the registered pool can mint/burn. Factory controls registration; no path to re-register.

### Key Attack Surfaces

- **LP fee distribution under extreme side imbalance** &nbsp;&#91;[I-1](invariants.md#i-1), [I-9](invariants.md#i-9)&#93; -- `SwapPool.sol:658-670` `_distributeLpFee` splits fees by `drainedVal / drain` ratio; when `drainedVal` approaches zero but is nonzero, rounding in `(lpFee * drainedVal) / drain` truncates aggressively. Worth tracing whether a strategic sequence of swaps and deposits can direct fee rounding to a controlled side.

- **Cross-side withdrawal value accounting with last-LP edge cases** &nbsp;&#91;[I-1](invariants.md#i-1)&#93; -- `SwapPool.sol:381-398` has three branching paths for fee crediting depending on `isLastLp` and `receiveSide == lpSide`; the `isLastLp && lpFee > 0` branch at line 385 redirects fee to opposite side. Worth checking the interaction when BOTH sides' last LPs withdraw in the same block.

- **JIT fee basis calculation reads before burn** &nbsp;&#91;[I-8](invariants.md#i-8)&#93; -- `SwapPool.sol:607-614` `_freshConsumedForBurn` queries `lp.balanceOf` and `lp.lockedAmount` BEFORE `_burnLp` at line 378. Worth confirming the LPToken `_update` hook's outflow logic at `LPToken.sol:148-167` consumes matured-first correctly when the caller's fresh bucket has a weighted-average timestamp near the 24h boundary.

- **Operator resolve-without-pause window** -- `PoolFactory.sol:308-311` `setResolvePool` sets resolved=true without touching pause flags; `SwapPool.sol:355,362` skip all fees when resolved. Worth tracing whether an attacker monitoring the operator's `setResolvePool` tx can front-run with a cross-side withdrawal to exit at zero fee before `resolvePoolAndPause` lands.

- **ERC-1155 callback during swap state transition** &nbsp;&#91;[X-2](invariants.md#x-2)&#93; -- `SwapPool.sol:305-317` pulls input tokens (triggering `onERC1155Received` on the pool via ERC1155Holder) then pushes output tokens. ReentrancyGuard covers direct reentry, but worth confirming no cross-contract callback path bypasses the guard through the FeeCollector or LPToken interactions in the same call.

- **`withdrawProRata` proportional share uses LP amount not value** &nbsp;&#91;[I-1](invariants.md#i-1)&#93; -- `SwapPool.sol:445` `nativeShare = (lpAmount * availableNative) / totalSupply` divides by LP supply, not sideValue. LPs with accumulated fee gains (rate > 1e18) get a native share proportional to their LP tokens, not their value claim. Worth checking whether this creates an incentive asymmetry between early and late withdrawers during pause.

- **`rescueTokens` surplus calculation is cross-side** -- `SwapPool.sol:556-561` computes global surplus as `totalPhysical - totalTracked` across both sides. A donation to side A creates surplus that could be rescued as side B tokens. Owner-only; no user funds at risk but worth confirming the surplus math accounts for pending fee distributions.

### Protocol-Type Concerns

**As a DEX/AMM:**
- `SwapPool.sol:268-271` -- first deposit mints LP 1:1 with no minimum liquidity lock. The pool is donation-immune (uses internal accounting, not `balanceOf`), but worth tracing the rate path when the first depositor withdraws immediately with a tiny second depositor present.
- `SwapPool.sol:686-689` -- `_fromNorm` truncation when converting 18-decimal normalized amounts back to low-decimal tokens (e.g., 6 decimals). A 1 wei normalized amount becomes 0 raw, caught by `SwapTooSmall` / `ZeroAmount` guards, but worth checking dust accumulation across many small swaps.

### Temporal Risk Profile

**Deployment & Initialization:**
- `SwapPool.sol:194-202` -- `initialize()` is factory-gated (`msg.sender == factory`) and one-shot (`_initialized` latch). No front-running risk since factory calls it atomically in `createPool`.
- `PoolFactory` constructor deploys LPToken instances and sets immutable market contracts. No post-deployment initialization window.

**Market Stress:**
- Prediction market resolution creates a binary outcome -- one side's shares become worthless. If operator delays `resolvePoolAndPause`, arbitrageurs with off-chain resolution knowledge can drain the winning side's liquidity via swaps before the pool is frozen.

### Composability & Dependency Risks

**Dependency Risk Map:**

> **ERC-1155 Prediction Market Contracts** -- via `SwapPool._pullTokens / _pushTokens`
> - Assumes: standard ERC-1155 `safeTransferFrom` transfers exact amounts, no fee-on-transfer, no rebasing
> - Validates: NONE (no balance-before/after check)
> - Mutability: Depends on market platform (Polymarket, PredictFun -- could be upgradeable)
> - On failure: reverts (safeTransferFrom reverts on insufficient balance or approval)

> **OpenZeppelin ERC1155 / Ownable / ReentrancyGuard** -- via inheritance
> - Assumes: standard OZ v5 behavior for `_update` hook, reentrancy guard, ownership transfer
> - Validates: N/A (inherited)
> - Mutability: Immutable (pinned submodule)
> - On failure: N/A

**Token Assumptions** (unvalidated):
- ERC-1155 shares: assumes no transfer callbacks that modify pool state beyond the standard `onERC1155Received` hook (which SwapPool accepts via ERC1155Holder)
- ERC-1155 shares: assumes decimal precision stored at pool creation (`marketADecimals`, `marketBDecimals`) remains accurate for the lifetime of the pool

---

## 3. Invariants

> ### Full invariant map: **[invariants.md](invariants.md)**
>
> A dedicated reference file contains the complete invariant analysis -- do not look here for the catalog.
>
> - **20 Enforced Guards** (`G-1` ... `G-20`) -- per-call preconditions with `Check` / `Location` / `Purpose`
> - **9 Single-Contract Invariants** (`I-1` ... `I-9`) -- Conservation, Bound, Ratio, StateMachine, Temporal
> - **3 Cross-Contract Invariants** (`X-1` ... `X-3`) -- caller/callee pairs that cross scope boundaries
> - **2 Economic Invariants** (`E-1` ... `E-2`) -- higher-order properties deriving from `I-N` + `X-N`
>
> Every inferred block cites a concrete delta-pair, guard-lift + write-sites, state edge, temporal predicate, or NatSpec quote. The **On-chain=No** blocks are the high-signal ones -- each is simultaneously an invariant and a potential bug. Attack-surface bullets above cross-link directly into the relevant blocks (e.g. `[X-2]`, `[I-1]`).

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Present | `README.md` -- comprehensive, covers mechanics, fees, roles, architecture, security |
| NatSpec | ~4 annotations | Sparse; most functions have descriptive comments but few formal NatSpec tags |
| Spec/Whitepaper | README serves as spec | No separate whitepaper; README documents invariant and fee formulas |
| Inline Comments | Adequate | Key mechanisms documented (withdrawal rules, fee distribution, JIT lock); some comments have typos |

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files | 4 | File scan (always reliable) |
| Test functions | 167 | File scan (always reliable) |
| Line coverage | 98.0% (source only) | `forge coverage --ir-minimum` |
| Branch coverage | 82.6% (source only) | `forge coverage --ir-minimum` |

### Test Depth

| Category | Count | Contracts Covered |
|----------|-------|-------------------|
| Unit | 148 | SwapPool, PoolFactory, LPToken, FeeCollector |
| Stateless Fuzz | 19 | SwapPool (conservation, fees, rates, lock, pro-rata) |
| Stateful Fuzz (Foundry) | 6 | SwapPool (ValueConservation, PoolSolvency, RateAtLeast1e18, FeeBounds, LPSupplyNonNegative, CallSummary) |
| Formal Verification (Certora) | 0 | none |
| Formal Verification (Halmos) | 0 | none |
| Fork | 0 | none |

### Gaps

- No formal verification (Certora/Halmos/HEVM) for the core accounting math -- given the fee distribution branching and rounding, formal methods would strengthen confidence in the conservation invariant.
- No fork tests against live prediction market contracts -- integration with real ERC-1155 market behavior is untested.
- Branch coverage on SwapPool is 73.8% -- the uncovered branches likely include edge cases in fee distribution and rescue paths.

---

## 6. Developer & Git History

> Repo shape: normal_dev -- normal development history with 16 source-touching commits over 51 days (2026-03-04 to 2026-04-24)

### Contributors

| Author | Commits | Source Lines (+/-) | % of Source Changes |
|--------|--------:|--------------------|--------------------:|
| Iurii | 36 | +2935 / -1579 | 100% |

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors | 1 | Single developer |
| Merge commits | 0 of 36 (0%) | No merge commits -- likely no peer review |
| Repo age | 2026-03-04 to 2026-04-24 | 51 days |
| Recent source activity (30d) | 8 commits | Active -- 5 of 8 late commits lack test changes |
| Test co-change rate | 62.5% | Measures file co-modification in commits, not coverage |

### File Hotspots

| File | Modifications | Note |
|------|-------------:|------|
| src/SwapPool.sol | 16 | Highest churn -- prioritize review |
| src/PoolFactory.sol | 10 | Second-highest churn |
| src/LPToken.sol | 6 | Moderate churn |
| src/FeeCollector.sol | 6 | Moderate churn |

### Security-Relevant Commits

| SHA | Date | Subject | Score | Key Signal |
|-----|------|---------|------:|------------|
| 00e897d | 2026-03-04 | first full version with tests and deploy | 16 | Tightens access control (+3/-2), changes token transfer and accounting logic |
| 58cc2a5 | 2026-04-23 | added tests | 15 | Adds 6 runtime guards, tightens access control (+22/-9) |
| 02b05f2 | 2026-04-23 | corrected based on ai check | 14 | Removes 1 guard, changes accounting -- no test file changes |
| 98b4e12 | 2026-04-22 | updated to v2 | 13 | Large rewrite (1204 lines), loosens access control (+4/-6), removes 7 guards |
| 0b9d21f | 2026-03-04 | init | 13 | Initial commit with 45 guards, 9 access control additions |

### Dangerous Area Evolution

| Security Area | Commits | Key Files |
|--------------|--------:|-----------|
| fund_flows | 16 | SwapPool.sol, FeeCollector.sol, LPToken.sol |
| state_machines | 16 | SwapPool.sol, PoolFactory.sol |
| access_control | 11 | FeeCollector.sol, LPToken.sol, PoolFactory.sol |

### Forked Dependencies

| Library | Path | Upstream | Status | Notes |
|---------|------|----------|--------|-------|
| openzeppelin-contracts | lib/openzeppelin-contracts | OpenZeppelin | Submodule | Some pragma ranges differ from modern OZ -- expected for multi-version OZ repo |

### Security Observations

- **Single-developer project** -- Iurii authored 100% of commits; no code review process evident from git history.
- **No merge commits** -- 0 of 36 commits are merges; all changes are direct pushes.
- **5 late source commits without test changes** -- `a466b8c`, `f7eea36`, `84a9558`, `02b05f2`, `54b2735` modify SwapPool.sol but do not include test file changes.
- **SwapPool.sol is the #1 hotspot** -- 16 modifications, including 3 commits in the last 24h touching fee distribution logic.
- **v2 rewrite (98b4e12) loosened access control** -- removed 7 runtime guards and changed 6 access control patterns in a 1204-line change.
- **"corrected based on ai check" (02b05f2)** -- score 14, modifies accounting and access control in SwapPool and FeeCollector without test changes.

### Cross-Reference Synthesis

- **SwapPool.sol is #1 in BOTH churn (16 commits) AND attack-surface priority** -- all top-6 surfaces route through it; highest-leverage review: `_distributeLpFee`, `withdrawal` fee branching, `_freshConsumedForBurn`.
- **Last 3 commits all touch `_distributeLpFee` / fee logic without tests** -- late changes to the most sensitive accounting path carry the highest residual risk.
- **v2 rewrite removed guards then subsequent commits added new ones** -- `98b4e12` stripped 7 guards, `58cc2a5` added 6 back. Worth confirming the final guard set matches the v2 accounting model.

---

## X-Ray Verdict

**ADEQUATE** -- Unit, fuzz, and invariant tests provide strong structural coverage, but no formal verification, no peer review, and no timelock on admin actions.

**Structural facts:**
1. 841 nSLOC across 4 contracts, single-developer project with 36 commits over 51 days
2. 148 unit + 19 fuzz + 6 stateful invariant tests; 98% source line coverage, 82.6% branch coverage
3. No timelock on any owner/operator action; owner has instant fee change (up to 1.5%) and rescue powers
4. 3 commits in the last 24h modify fee distribution logic without corresponding test changes
5. Zero merge commits -- no evidence of peer review in git history
