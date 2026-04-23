# X-Ray Report

> PredictSwap v3 | 809 nSLOC | 421eeb7 (`main`) | Foundry | 2026-04-23

---

## 1. Protocol Overview

**What it does:** A 1:1 swap pool for matched ERC-1155 prediction-market outcome shares across two platforms (e.g. Polymarket YES <-> PredictFun YES for the same event).

- **Users**: LPs deposit single-sided to earn swap fees; swappers exchange equivalent outcome shares cross-platform
- **Core flow**: deposit -> swap (1:1 minus fees) -> withdraw (same-side or cross-side)
- **Key mechanism**: Simplified value accounting with two scalars (`aSideValue`, `bSideValue`) and per-side LP rates; no constant-product curve
- **Token model**: Two external ERC-1155 prediction-market tokens per pool; two shared ERC-1155 LP tokens (one per side, deployed by factory); LP tokenId mirrors the underlying market tokenId
- **Admin model**: Owner (intended multisig) controls fees and rescue; Operator (EOA) creates pools and manages pause/resolve lifecycle. No timelock. No proxy.

For a visual overview of the protocol's architecture, see [architecture.json](architecture.json).

### Contracts in Scope

| Subsystem | Key Contract | nSLOC | Role |
|-----------|-------------|------:|------|
| Pool Core | SwapPool | 437 | 1:1 AMM -- deposit, swap, withdrawal, pro-rata exit, value accounting |
| Factory & Registry | PoolFactory | 216 | Deploys pools & LP token instances; registry; admin relay |
| LP Positions | LPToken | 105 | Shared ERC-1155 LP token with two-bucket JIT lock (24h fresh/matured) |
| Fee Collection | FeeCollector | 51 | Protocol fee accumulator; owner-withdrawable |

### How It Fits Together

The core trick: both sides of a prediction-market outcome are treated as 1:1 in value; the pool tracks two scalar accounting values (`aSideValue`/`bSideValue`) and derives per-side LP rates by dividing each by its LP supply. Swap fees credit the drained side's value, causing its rate to grow monotonically.

### Deposit & LP Minting

```
User
 -> SwapPool.deposit(side, amount)
    |-- _pullTokens()            ERC-1155 safeTransferFrom from user
    |-- _toNorm()                normalize to 18-dec
    |-- lpMinted = normAmt * supply / sideValue   (or 1:1 if first deposit)
    |-- _addSideValue(side, normAmount)            accounting update
    +-- _mintLp() -> LPToken.mint()
        +-- _update()            fresh bucket bookkeeping on recipient
```

### Swap (A -> B)

```
User
 -> SwapPool.swap(fromSide=A, sharesIn)
    |-- _computeFees()           ceil-rounded total, then split LP/protocol
    |-- physicalBalanceNorm(B)   liquidity check
    |-- _pullTokens(A)           pull input shares from user
    |-- _pushTokens(A -> FeeCollector)   protocol fee in input-side tokens
    |-- _pushTokens(B -> User)           output shares to swapper
    +-- _addSideValue(B, lpFee)          LP fee accrues to drained side
```

LP fee goes to B-side value because B reserves were consumed -- `marketBRate` grows, `marketARate` unchanged.

### Withdrawal (unified)

```
User
 -> SwapPool.withdrawal(receiveSide, lpAmount, lpSide)
    |-- _lpToShares()            claim = lpAmount * rate / 1e18
    |-- _freshConsumedForBurn() -> LPToken.lockedAmount()
    |                             JIT fee on fresh portion only (same-side, unresolved)
    |-- _subSideValue()          accounting debit
    |-- _burnLp() -> LPToken.burn()
    |-- _pushTokens(receiveSide -> User)
    |-- _pushTokens(receiveSide -> FeeCollector)   protocol fee
    +-- _flushResidualIfEmpty()  sweep dust when both LP supplies = 0
```

### Pool Lifecycle (Operator)

```
Operator
 -> PoolFactory.createPool(marketA, marketB, fees)
    |-- new SwapPool(...)
    |-- LPToken.registerPool(pool, lpId)  x2   one-shot per side
    +-- SwapPool.initialize(lpIdA, lpIdB)

Operator
 -> PoolFactory.resolvePoolAndPause(poolId)
    +-- SwapPool.setResolvedAndPaused()
        resolved=true, depositsPaused=true, swapsPaused=true
        users exit via withdrawProRata() -- no fees, proportional split
```

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **DEX/AMM** -- specialized 1:1 swap pool for matched ERC-1155 prediction-market outcome shares

Code signals: `swap()`, `deposit()` (single-sided addLiquidity), `withdrawal()`/`withdrawProRata()` (removeLiquidity), LP token mint/burn, fee tiers, per-side reserves tracking. Not a constant-product AMM -- uses fixed 1:1 pricing with fee deduction. No oracle dependency, no borrowing, no leverage.

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| User / LP | Untrusted | deposit, swap, withdrawal, withdrawProRata -- all permissionless, nonReentrant |
| Operator | Bounded | createPool, pause deposits/swaps, resolve pools. Cannot change fees, cannot rescue funds. All actions instant -- no timelock. |
| Owner | Trusted (intended multisig) | setPoolFees (instant, capped at 1% LP + 0.5% protocol), setFeeCollector (future pools only), setOperator, rescue* functions. All instant -- no on-chain timelock enforcement. |
| FeeCollector Owner | Trusted | withdraw accumulated protocol fees. May be same key as PoolFactory owner. |

**Adversary Ranking** (ordered by threat level for this protocol type):

1. **Compromised operator** -- can resolve pools to waive all fees instantly, pause/unpause to manipulate which withdrawal path is available, front-run user withdrawals by pausing swaps, create pools with zero fees.
2. **Owner key compromise** -- can change fees to maximum (capped), redirect fee collector for future pools, rescue surplus tokens from pools, change operator.
3. **MEV searcher / JIT liquidity attacker** -- deposits immediately before a swap to capture fees, withdraws immediately after. The 24h two-bucket lock is the primary defense.
4. **Malicious/upgradeable market contract** -- the ERC-1155 market contracts are immutably bound at factory deploy; if one has non-standard transfer behavior or reentrancy, it affects all pools.
5. **First depositor / empty-pool attacker** -- exploits the `supply == 0` branch where LP mints 1:1; less severe than ERC4626 inflation since internal accounting (not `balanceOf`) is used.

See [entry-points.md](entry-points.md) for the full permissionless entry point map.

### Trust Boundaries

- **Factory -> SwapPool admin relay** -- all SwapPool admin functions check `msg.sender == address(factory)` ([G-23](invariants.md#g-23-factory-only-admin-swappool)). Factory is immutable on the pool. If factory has a bug, all pools under it are affected. No timelock on any operational action.

- **LPToken pool registration** -- `pool[tokenId]` is a one-shot latch ([G-28](invariants.md#g-28-one-shot-registerpool)). Once registered, the pool address cannot change for that tokenId. If a pool must be redeployed, both LPToken instances must also be redeployed.

- **External ERC-1155 market contracts** -- immutably bound at factory deploy (`PoolFactory.sol:165-166`). All `safeTransferFrom` calls trust the market contract to behave per ERC-1155 spec ([X-8](invariants.md#x-8-external-erc-1155-trust-assumption)). If the market contract is upgradeable or non-standard, every pool on this factory is exposed.

### Key Attack Surfaces

- **Operator compromise: instant resolve waives fees** -- `PoolFactory.sol:308-311` `setResolvePool` waives cross-side and JIT fees instantly with no timelock; operator can toggle `resolved` back to `false` afterward. Worth confirming no value extraction is possible via resolve-withdraw-unresolve sequence. ([I-8](invariants.md#i-8-rate-monotonicity-swaps-only), [E-1](invariants.md#e-1-lp-share-value-non-decreasing-from-fee-accrual))

- **Operator compromise: pause front-running** -- `PoolFactory.sol:302-305` `setPoolSwapsPaused` forces users from `withdrawal()` (with fee) to `withdrawProRata()` (no fee, proportional). Operator could front-run a large cross-side withdrawal by pausing swaps, denying the pool its LP fee. ([G-9](invariants.md#g-9-swapspaused-gate-withdrawal), [G-12](invariants.md#g-12-swapsnotpaused-gate-withdrawprorata))

- **Owner: instant fee change** -- `PoolFactory.sol:289-291` `setPoolFees` changes LP and protocol fee BPS instantly; capped by `MAX_LP_FEE=100` and `MAX_PROTOCOL_FEE=50` ([G-17](invariants.md#g-17-fee-cap-lp-setfees), [G-18](invariants.md#g-18-fee-cap-protocol-setfees)). Worth confirming that a fee change between a user's transaction submission and execution cannot cause unexpected fee application.

- **Value accounting rounding with mixed decimals** -- `_fromNorm` truncates at `SwapPool.sol:653`; for low-decimal tokens (e.g. 6), repeated deposit/withdraw cycles accumulate truncation dust. Worth tracing whether cumulative dust can cause `aSideValue + bSideValue > physicalBalanceNorm(A) + physicalBalanceNorm(B)` (insolvency). ([I-1](invariants.md#i-1-value-conservation), [E-3](invariants.md#e-3-rounding-favors-the-pool))

- **First depositor share inflation** -- deposit at `supply==0` mints 1:1 with normalized amount at `SwapPool.sol:269`; no minimum liquidity burn. Worth checking if direct ERC-1155 transfer (donation) before first deposit can influence minting math. Pool uses `sideValue` not `physicalBalanceNorm`, so donation-immune by design. ([E-4](invariants.md#e-4-first-depositor-rate-is-11))

- **JIT lock weighted timestamp manipulation** -- `LPToken.sol:183-185` merges incoming LP into the fresh bucket with weighted-average timestamp; worth checking whether transferring 1 wei of LP to a victim can shift their fresh timestamp forward, extending their lock and increasing their JIT fee. ([I-15](invariants.md#i-15-weighted-average-timestamp-on-fresh-merge), [I-9](invariants.md#i-9-fresh-bucket-temporal-bound))

- **ERC-1155 callback reentrancy** -- `safeTransferFrom` triggers `onERC1155Received`; SwapPool uses `nonReentrant` but `_pushTokens` at `SwapPool.sol:661` calls into external contract before state is finalized (e.g. `_addSideValue` at `:319` after `_pushTokens` at `:316`). Worth tracing whether a malicious ERC-1155 contract's callback could read stale `aSideValue`/`bSideValue` via a view function during the push. ([X-8](invariants.md#x-8-external-erc-1155-trust-assumption))

- **FeeCollector.recordFee is permissionless** -- `FeeCollector.sol:33` anyone can emit `FeeReceived` with arbitrary parameters. Off-chain indexers must filter by `msg.sender` being a known SwapPool address. ([X-2](invariants.md#x-2-feecollector-receives-tokens-before-recordfee))

- **withdrawProRata proportional math** -- `SwapPool.sol:437` `nativeShare = (lpAmount * availableNative) / totalSupply`; worth checking rounding direction for the last withdrawer and whether `availableNative` can be manipulated by a prior swap that drains one side. ([G-14](invariants.md#g-14-cross-side-liquidity-withdrawprorata))

- **Last-LP fee redistribution** -- `SwapPool.sol:377-384` when the last LP on a side exits with JIT fee, lpFee is credited to the opposite side. Worth checking if an attacker can time a same-side exit as the last LP to redirect their JIT fee to a position they control on the opposite side. ([E-1](invariants.md#e-1-lp-share-value-non-decreasing-from-fee-accrual))

- **rescueERC1155 blocks entire market contract address** -- `SwapPool.sol:556-558` rejects rescue if `contractAddress_ == mktA || mktB`, regardless of tokenId. Non-pool tokenIds accidentally sent from the same market contract are permanently trapped. ([G-35](invariants.md#g-35-rescueerc1155-pool-token-guard))

### Protocol-Type Concerns

**As a DEX/AMM:**
- **1:1 pricing assumption without oracle** -- the pool assumes both sides are economically equivalent. If the underlying event resolves or one platform depegs, this assumption breaks. The `resolved` flag + `resolvePoolAndPause` is the mitigation, but depends on timely operator action.
- **LP share inflation at `supply == 0`** -- `SwapPool.sol:268-269` first deposit mints 1:1. After `_flushResidualIfEmpty` zeros everything, the next deposit restarts at 1:1. Worth confirming no state leaks across epochs.

### Temporal Risk Profile

**Deployment & Initialization:**
- `SwapPool.initialize()` is factory-gated ([G-19](invariants.md#g-19-factory-only-initialize)) and one-shot ([G-20](invariants.md#g-20-one-shot-initialize)), called atomically in `createPool` ([X-5](invariants.md#x-5-factory-deploys-and-immediately-initializes)) -- no front-running window.
- `PoolFactory` constructor validates all addresses non-zero and names non-empty (`PoolFactory.sol:156-163`); ownership set via OZ `Ownable(owner_)` -- transfer to multisig must happen post-deploy, creating a window where deployer EOA is owner.

### Composability & Dependency Risks

**Dependency Risk Map:**

> **MarketA / MarketB ERC-1155** -- via `SwapPool._pullTokens` / `_pushTokens`
> - Assumes: standard ERC-1155 `safeTransferFrom` -- exact amount transferred, reverts on failure, no fee-on-transfer
> - Validates: NONE (trusts `safeTransferFrom` to move exact amount)
> - Mutability: Immutable binding at factory deploy; but the ERC-1155 contract itself may be upgradeable
> - On failure: revert (safeTransferFrom reverts -> whole tx reverts)

> **OpenZeppelin Contracts** -- via inheritance (ERC1155, Ownable, ReentrancyGuard, SafeERC20)
> - Assumes: standard OZ v5 behavior
> - Validates: N/A (compile-time dependency)
> - Mutability: Submodule pinned in `lib/openzeppelin-contracts`
> - On failure: N/A

**Token Assumptions** (unvalidated):
- ERC-1155 market tokens: assumes no callback reentrancy beyond what `nonReentrant` covers. If market contract implements custom hooks that re-enter through a different contract, cross-contract reentrancy could bypass the per-contract guard.
- ERC-1155 market tokens: assumes `balanceOf` is not manipulable by direct transfer (donation). Pool uses internal accounting (`aSideValue`/`bSideValue`) rather than `balanceOf` -- donation-immune by design.

---

## 3. Invariants

> ### Full invariant map: **[invariants.md](invariants.md)**
>
> A dedicated reference file contains the complete invariant analysis -- do not look here for the catalog.
>
> - **36 Enforced Guards** (`G-1` ... `G-36`) -- per-call preconditions with predicate, location, purpose
> - **15 Single-Contract Invariants** (`I-1` ... `I-15`) -- Conservation, Bound, Ratio, StateMachine, Temporal
> - **8 Cross-Contract Invariants** (`X-1` ... `X-8`) -- caller/callee pairs that cross scope boundaries
> - **4 Economic Invariants** (`E-1` ... `E-4`) -- higher-order properties deriving from I-N + X-N
>
> Every inferred block cites a concrete delta-pair, guard-lift + write-sites, state edge, temporal predicate, or NatSpec quote. The `X-8` (external ERC-1155 trust assumption) is the key un-enforced cross-contract invariant. Attack-surface bullets above cross-link directly into the relevant invariant blocks.

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Present | Architecture, mechanics, fee math, withdrawal matrix, security properties |
| NatSpec | Sparse | Title/notice on contracts; few `@param`/`@return` on individual functions |
| Spec/Whitepaper | Missing | README serves as informal spec |
| Inline Comments | Adequate | Key design decisions documented (value accounting, fee routing, JIT lock) |

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files | 4 | File scan |
| Test functions | 76 | File scan |
| Stateless fuzz | 19 | Foundry fuzz tests |
| Foundry invariant | 6 | Foundry invariant tests |

### Coverage (source files only)

| Contract | Line % | Statement % | Branch % | Function % |
|----------|-------:|------------:|----------:|-----------:|
| FeeCollector | 50.00 | 31.58 | 0.00 | 60.00 |
| LPToken | 100.00 | 90.00 | 61.11 | 100.00 |
| PoolFactory | 67.39 | 59.26 | 8.00 | 52.63 |
| SwapPool | 86.43 | 80.23 | 47.30 | 86.84 |

### Test Depth

| Category | Count | Notes |
|----------|------:|-------|
| Unit | ~51 | SwapPool, LPToken, PoolFactory, FeeCollector |
| Stateless Fuzz | 19 | Fee math, deposit/withdrawal amounts |
| Stateful Fuzz (Foundry invariant) | 6 | Foundry invariant tests |
| Echidna / Medusa | 0 | None |
| Formal Verification (Certora/Halmos/HEVM) | 0 | None |
| Fork tests | 0 | None |

### Gaps

- **Branch coverage is low** -- FeeCollector 0%, PoolFactory 8%, SwapPool 47.30%. Error branches and edge cases under-tested.
- **No advanced stateful fuzzing** -- 6 foundry invariant tests exist but no Echidna/Medusa campaigns. The value conservation invariant (`aSideValue + bSideValue == physicalA + physicalB`) should be tested under randomized multi-user operation sequences with mixed decimal tokens.
- **No formal verification** -- LP minting/burning rate math and the two-bucket lock timestamp merging are amenable to symbolic analysis (Halmos, Certora).
- **FeeCollector nearly untested** -- `withdrawBatch`, `withdrawAll`, `withdrawAllBatch` error paths untested.
- **PoolFactory branch coverage 8%** -- most admin paths, error branches, and edge cases untested.
- **No fork tests** -- external ERC-1155 behavior assumed but never tested against real deployed contracts.

---

## 6. Developer & Git History

> Repo shape: normal_dev -- 29 total commits (12 source-touching) over 50 days by a single developer.

### Contributors

| Author | Commits | % of Source Changes |
|--------|--------:|--------------------:|
| Iurii | 29 | 100% |

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors | 1 | Single-developer project |
| Merge commits | 0 of 29 (0%) | No peer review evidence |
| Repo age | 50 days | ~2026-03-04 to 2026-04-23 |
| Recent source activity (30d) | 4 commits | Active -- includes major v2 rewrite |
| Test co-change rate | 83.3% | Good -- most source changes include test updates |
| Fix-without-test rate | 20% | Some fixes lack corresponding test changes |

### File Hotspots

| File | Modifications | Note |
|------|-------------:|------|
| src/SwapPool.sol | 12 | Highest churn -- core AMM logic, all value flows |
| src/PoolFactory.sol | 10 | High churn -- registry + admin relay |
| src/LPToken.sol | 6 | JIT lock logic modified across versions |
| src/FeeCollector.sol | 5 | Moderate churn |

### Security-Relevant Commits

| SHA | Date | Subject | Score | Key Signal |
|-----|------|---------|------:|------------|
| 00e897d | 2026-03-04 | first full version with tests and deploy | 16 | Removes guards, tightens access control, spans 3 security domains |
| 58cc2a5 | recent | added tests | 15 | Test addition batch |
| 98b4e12 | 2026-04-22 | updated to v2 | 13 | Removes 8 guards, loosens access control, 1204 lines changed |
| 54b2735 | 2026-04-08 | updated Factory and Pool | 9 | 848 lines changed, NO test changes |
| e1740e6 | 2026-03-23 | updated based on audit findings | 8 | Rewrites access control -- audit-driven fixes, no test changes |

### Security Observations

- **Single-developer project** -- 100% of code by one author (Iurii), 0 merge commits across 29 commits.
- **Major v2 rewrite recently** -- commit `98b4e12` changed 1204 lines across 3 source files, loosened access control, removed 8 runtime guards.
- **848-line commit without tests** -- `54b2735` "updated Factory and Pool" has no test changes.
- **Audit-driven fix commit without tests** -- `e1740e6` "updated based on audit findings" rewrites access control without corresponding test updates.
- **SwapPool.sol is the dominant hotspot** -- 12 modifications, core of all value flows.

### Cross-Reference Synthesis

- **SwapPool.sol is #1 in both churn and attack-surface priority** -- all top attack surfaces route through it (fee math, value accounting, LP interactions, ERC-1155 callbacks).
- **v2 rewrite (98b4e12) loosened access control + removed guards** -- the newest and largest commit, touching 3/4 source files. Combined with limited fuzz testing, the new code paths are the least validated.
- **Audit findings commit (e1740e6) rewrites access control without test updates** -- residual risk that fixes were incomplete or introduced new issues.

---

## X-Ray Verdict

**FRAGILE** -- Unit tests and some fuzz/invariant tests exist (76 functions, 19 stateless fuzz, 6 invariant, 83.3% test co-change rate), but branch coverage is low across the board and no advanced stateful fuzzing or formal verification exists for a protocol whose core security property (value conservation) demands it.

**Structural facts:**
1. 809 nSLOC across 4 contracts, single subsystem -- compact and reviewable
2. Single developer wrote 100% of code with 0 merge commits -- no evidence of peer review
3. Major 1204-line v2 rewrite committed recently, including loosened access control and removed guards
4. No timelock or on-chain multisig enforcement -- all admin/operator actions are instant
5. FeeCollector has 0% branch coverage; PoolFactory branch coverage is 8%
6. Operator can resolve/unresolve pools instantly with no delay, waiving all fees
