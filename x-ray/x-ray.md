# X-Ray Report

> PredictSwap | 705 nSLOC | ca0becb (`main`) | Foundry | 16/04/26

Analyzed branch: `main` at `ca0becb`.

---

## 1. Protocol Overview

**What it does:** A 1:1 fixed-price AMM for two ERC-1155 prediction-market shares representing the same real-world outcome (e.g., YES on Polymarket vs. YES on Opinion), letting arbitrageurs close price gaps and LPs earn swap fees.

- **Users**: LPs supplying shares from either side; traders/arbitrageurs swapping one side for the other.
- **Core flow**: LP deposits shares of one platform → receives that side's LP token → pool accrues LP fees from swaps and cross-side withdrawals → LP burns to redeem at an increasing exchange rate.
- **Key mechanism**: Dual-token LP design. Both LP tokens share one exchange rate (`totalSharesNorm / totalLpSupply`); the LP token type only records the deposit side, controlling same-side (free) vs cross-side (fee) withdrawal rules.
- **Token model**: Per pool — one SwapPool + two LPTokens (A-side, B-side). One global FeeCollector accumulates protocol fees as raw ERC-1155 balances.
- **Admin model**: Two-tier. Owner (multisig-intended, slow, critical: market approval, fees, rescue, operator change). Operator (EOA, fast: pool creation, pause, resolve). No timelock on any operational action. No on-chain multisig enforcement.

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| Pool | SwapPool | 401 | 1:1 AMM holding the matched ERC-1155 pair; deposit/swap/withdraw; decimal normalization to 18-dec internal space. |
| Factory | PoolFactory | 219 | Pool deployer, registry, market-contract whitelist, owner/operator role routing. |
| LP | LPToken | 34 | ERC-20 LP share; only its associated pool can mint/burn; one-time `setPool`. |
| Fees | FeeCollector | 51 | Accumulates protocol fees as raw ERC-1155 balances; owner-gated withdrawal. |

### How It Fits Together

The core trick: both sides are declared 1:1 equivalent, so the AMM never needs a curve — it just enforces fee-adjusted 1:1 swaps plus decimal normalization, and LP fees auto-compound because they're retained inside the tracked pool balance while the LP supply stays fixed.

### Pool creation (atomic)

```
Operator ─► PoolFactory.createPool(marketA_, marketB_, fees, lpMeta)
              │   ── markets whitelist-checked
              ├─► new LPToken(A)     ── factory is temporary authority
              ├─► new LPToken(B)
              ├─► new SwapPool(factory, marketA_, marketB_, fees, lpA, lpB, fees)
              │                                   *validates fee caps, stores immutables*
              ├─► LPToken(A).setPool(pool)        *one-shot wiring, cannot re-fire*
              ├─► LPToken(B).setPool(pool)
              └─► pools.push + poolIndex[key] = poolId+1
```

### Deposit

```
User ─► SwapPool.deposit(side, amount)        [nonReentrant, !depositsPaused]
          ├─► IERC1155.safeTransferFrom(user → pool)   *external call before accounting update*
          ├─► normAmount = _toNorm(side, amount)
          ├─► lpMinted = supply==0 ? normAmount : normAmount * supply / totalSharesNorm()
          │                                            *reverts DepositTooSmall if lpMinted==0*
          ├─► marketABalance / marketBBalance += amount
          └─► LPToken(side).mint(user, lpMinted)
```

### Swap (1:1 minus fee)

```
User ─► SwapPool.swap(fromSide, sharesIn)     [nonReentrant, !swapsPaused]
          ├─► (lpFee, protocolFee) = _computeFees(normIn)   *single ceiling round*
          ├─► sharesOut = _fromNorm(toSide, normIn - lpFee - protocolFee)
          │                                    *reverts InsufficientLiquidity if sharesOut > toBalance*
          ├─► IERC1155.safeTransferFrom(user → pool, sharesIn, fromSide)
          ├─► if protocolFee>0: IERC1155.safeTransferFrom(pool → FeeCollector, rawProtocol)
          │       └─► FeeCollector.recordFee(emit event)
          ├─► IERC1155.safeTransferFrom(pool → user, sharesOut, toSide)
          └─► fromBalance += (sharesIn - rawProtocol);  toBalance -= sharesOut
```
*LP fee stays implicit in fromBalance — no mint/burn; exchange rate rises.*

### Withdraw (single-side)

```
User ─► SwapPool.withdrawSingleSide(lpAmount, lpSide, receiveSide)
          ├─► normOut = lpAmount * totalSharesNorm / totalLpSupply
          ├─► LPToken(lpSide).burn(user, lpAmount)
          ├─► if lpSide == receiveSide:         ── FREE, never blocked by swapsPaused
          │     └─► push rawOut to user; balance -= rawOut
          └─► else:                              ── cross-side: fee unless resolved
                ├─► revert if swapsPaused
                ├─► if resolved: push full normOut to user (no fee)
                └─► else: compute fees, push (actual + protocol) out, recordFee
          _flushResidualIfEmpty() *if totalLpSupply==0 sweep leftovers to FeeCollector*
```

### Residual flush on last exit

```
If the final LP burn leaves totalLpSupply()==0 but balances>0:
    marketABalance and marketBBalance are swept to FeeCollector
    (prevents a first-depositor from capturing accumulated LP fees
     by waiting out all other LPs)
```

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **DEX/AMM** with **Yield-Aggregator / Vault** characteristics

Signals: `swap`, `deposit`/`withdraw*`, LP mint/burn, explicit `exchangeRate()` view (AMM). Share-accounting math mirrors an ERC-4626-style vault (share = totalAssets / totalSupply), so vault-inflation and donation-attack intuitions apply even though the instrument is ERC-1155 not ERC-20.

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| LP / Trader | Untrusted | Call permissionless pool functions (deposit, swap, withdrawSingleSide, withdrawBothSides). No privileges beyond what their tokens authorize. |
| Operator | Bounded (cannot drain funds, cannot raise fees, cannot approve new markets) | `createPool`, pause deposits/swaps, `resolvePoolAndPausedDeposits`, `unresolvePool`. All actions instant — no timelock. Not subject to owner pause. |
| Owner | Trusted (multisig-intended) | Approve/revoke market contracts, set operator, set FeeCollector (future pools only), `setPoolFees` (bounded by MAX_LP_FEE=100bps, MAX_PROTOCOL_FEE=50bps), all rescue functions, withdraw FeeCollector balances. All actions instant — no timelock. |
| PoolFactory (as authority inside SwapPool) | Trusted | The SwapPool unconditionally accepts calls from `address(factory)` for all admin routes; any compromise of the factory compromises every pool it ever deployed. |

**Adversary Ranking** (ordered for this protocol type, adjusted by git evidence):

1. **Compromised Owner/Operator** — Two EOA-or-multisig keys control pool creation, pausing, fee changes (capped), and rescue. Bulk of admin-area commits (9 touching access_control, see §6) cluster around role and routing changes, making this the highest-churn surface.
2. **Sandwich / arbitrage MEV** — Every swap is a deterministic 1:1 minus fee; any off-chain price gap is a guaranteed extraction target (this is the protocol's raison d'être — users *are* the arbitrageurs, but adversarial traders can still front-run LP deposits/withdrawals at resolve time).
3. **Malicious market contract** — Any ERC-1155 the owner whitelists becomes trusted transfer target inside every pool deployed against it. A malicious or upgradeable ERC-1155 can revert, reenter via `onERC1155Received` (destination is attacker), or return wrong `balanceOf`.
4. **First-depositor / empty-pool manipulator** — Classic vault inflation concern applies in principle; mitigated in practice because `totalSharesNorm` reads internal `marketABalance+marketBBalance`, NOT `balanceOf(this)`, so direct donation cannot shift the exchange rate.

See [entry-points.md](entry-points.md) for the full permissionless entry-point map.

### Trust Boundaries

- **User ↔ Pool**: `nonReentrant` on all four user-facing pool entry points. State updates happen after token pulls on deposit, but reentrancy is blocked by the guard. *Git signal: fund_flows = 10 modifications, largest surface.*
- **Factory ↔ Pool**: Pool trusts `msg.sender == address(factory)` for all admin paths. No second-factor check — no role signatures, no multisig on-chain. If factory is ever replaced or the factory owner is compromised, every pool is compromised.
- **Pool ↔ LPToken**: LP token trusts `msg.sender == pool` for mint/burn. `setPool` is one-shot and checked; safe once wired in the atomic `createPool`.
- **Pool ↔ FeeCollector**: `recordFee` is unauthenticated — it only emits an event. The real fee transfer happens via `IERC1155.safeTransferFrom(pool → feeCollector, rawProtocol)` *before* the call. Off-chain indexers must filter `FeeReceived` by `msg.sender` matching a known SwapPool. *Code comment already calls this out (FeeCollector.sol:30-32).*
- **Owner delay**: None. `Ownable` (not `AccessControlDefaultAdminRules` or timelock) — ownership transfer is instant via `transferOwnership`, and every owner-gated function executes instantly.

### Key Attack Surfaces

Sorted by priority (AMM threat weights × git hotspot × access-control churn):

- **Factory-owner operational powers (no timelock)** — `setPoolFees` (bounded by MAX caps), `setFeeCollector` (future pools only), `setOperator`, all `rescuePool*` variants. Rescue is scoped to surplus/foreign-token balance via the per-function checks in `SwapPool.rescueTokens` (must be `actual - tracked`) and `SwapPool.rescueERC1155` (reverts on own market contracts). A compromised owner cannot drain LP funds directly, but can: raise fees to MAX (100+50=150bps), swap the FeeCollector to a new address on future pools, drain any ERC-20/ETH/foreign ERC-1155 accidentally sent to the pool, and withdraw all accumulated FeeCollector balance. *Git: 9 access_control-touching commits, hotspot PoolFactory.sol.*
- **Operator operational powers (no timelock)** — `createPool` (fees set at creation, no cross-check against other pools), `setPoolDepositsPaused/SwapsPaused` (can freeze user withdrawals via `swapsPaused` blocking cross-side, though same-side always flows), `resolvePoolAndPausedDeposits` (instantly switches cross-side to fee-free — bug or griefing risk until `unresolvePool` reverses), `unresolvePool`. Operator cannot touch funds directly but can grief timing-sensitive users.
- **Market-contract whitelist quality** — `approveMarketContract` performs zero checks beyond non-zero address. Any whitelisted ERC-1155 is a root of trust for decimals, transfer semantics, and token-id validity. An upgradeable ERC-1155 (Polymarket and similar platforms commonly are) can change behavior without protocol consent.
- **Share accounting vs. balance of** — `_getBalance(side)` returns internal `marketABalance/marketBBalance`, NOT `IERC1155.balanceOf(pool)`. Donation attack (sending tokens directly) does not shift exchange rate — intentional design. Verify on every future change to these state variables; regressions here would reintroduce the classic vault-inflation attack.
- **`_flushResidualIfEmpty` gate** — Triggered when `totalLpSupply() == 0` after any withdraw variant. Sends both balances to FeeCollector. Protects against a depositor waiting for all others to exit then inflating share price; dependency is `totalLpSupply()` being correct right after LP burn, which it is because `LPToken.burn` happens before `_flushResidualIfEmpty` in all paths.
- **Cross-side fee bypass while `resolved==true`** — During the operator-controlled "resolved" window, cross-side withdrawals are fee-free. If an operator prematurely resolves, arbitrageurs can drain cheap cross-side liquidity until `unresolvePool`. Mitigation is only procedural.
- **`recordFee` unauthenticated event emission** — Anyone can spoof `FeeReceived` events with any pool/token/amount. Intended; off-chain consumers must gate on `msg.sender`. Documented in the contract.
- **`receive() payable` and ETH in pool** — The pool can accept ETH from anyone; `rescueETH` drains to an owner-selected address. Low impact (no business logic uses ETH); recovery path exists.
- **Decimals-up-to-18 normalization overflow** — `_toNorm` does `raw * 10**(18-dec)`. With `dec=0` the multiplier is 1e18; an input above `~1.16e59` (uint256 max / 1e18) would overflow. Not reachable with realistic ERC-1155 supply.

### Upgrade Architecture Concerns

No proxy pattern. All contracts are non-upgradeable. `SwapPool`, `LPToken`, and `FeeCollector` have immutable core wiring; `PoolFactory` has mutable `operator` and `feeCollector` but no upgrade mechanism. No storage-collision or implementation-initialization risks apply.

### Protocol-Type Concerns

**As a DEX/AMM:**
- **Single-rounding fee computation** — `_computeFees` (SwapPool.sol:299) sums `totalFee` with ceiling division on the combined bps, then splits `protocolFee` by floor and assigns the remainder to `lpFee`. A prior audit-finding commit (`fe4c74d updated _computeFees`) specifically reworked this to eliminate double-rounding; verify regression tests cover `totalBps=0`, `protocolFeeBps=0`, `amount=1`, and max-bps cases.
- **No slippage protection on swap** — `SwapPool.swap(fromSide, sharesIn)` returns `sharesOut` but does not accept `minSharesOut`. Because the AMM is deterministic 1:1-minus-fee and fees are capped at 150bps, traders know output exactly in advance and slippage protection is structurally unnecessary — but any UI/router wrapping this must be aware.
- **LP fee auto-compound via balance-in-place** — LP fee is not minted as new LP tokens; it stays in `marketABalance`/`marketBBalance` on the incoming side. `exchangeRate` rises. Same-side withdrawal value is preserved because `normOut = lpBurned * totalSharesNorm / totalLpSupply` uses the updated numerator. Invariant: `totalSharesNorm()` monotone non-decreasing across a swap (ignoring rescue).

**As a Yield-Aggregator:**
- **First-depositor ratio** — When `totalLpSupply == 0`, `lpMinted = normAmount` (1:1). No virtual shares, no minimum-liquidity lock. Inflation impossible only because internal accounting is used (see §2 Key Attack Surfaces). Adding a second source for `totalSharesNorm` (e.g. `balanceOf(this)`) in the future would reintroduce the classic attack.
- **No strategy layer** — Funds never leave the pool contract. No external yield deposits, no harvest cycle, no approval chains to external protocols. Removes a large class of vault threats.

### Temporal Risk Profile

**Deployment & Initialization:**
- `LPToken.setPool` is front-run-safe because `createPool` calls it in the same transaction that deploys both tokens. Factory stores the deploying address and LP only accepts calls from it. Safe.
- Empty-pool ratio fixed at 1:1 by construction (no attacker-chosen initial price). Safe.
- `FeeCollector` and `PoolFactory` are `Ownable(owner_)` with constructor validation of non-zero addresses. Deployer must transfer ownership to the intended multisig immediately (the commit history and deploy scripts are the verification path — not checked on-chain).

---

## 3. Invariants

### Stated Invariants

- **Pool accounting is internal, not balance-of**: "`totalSharesNorm` reads `marketABalance + marketBBalance` which are internal" — implicit in SwapPool.sol:263-266 and reinforced by comment block at :36-45.
- **`setPool` is one-shot**: `if (pool != address(0)) revert PoolAlreadySet()` — LPToken.sol:60.
- **Fee caps**: `lpFeeBps_ > MAX_LP_FEE → FeeTooHigh`, `protocolFeeBps_ > MAX_PROTOCOL_FEE → FeeTooHigh` — SwapPool.sol:234-235, :592-593.
- **Decimals ≤ 18**: `if (marketA_.decimals > 18 || marketB_.decimals > 18) revert InvalidDecimals` — PoolFactory.sol:209, SwapPool.sol:233.
- **TokenId non-zero**: `if (marketA_.tokenId == 0 || marketB_.tokenId == 0) revert InvalidTokenID` — PoolFactory.sol:208, SwapPool.sol:232.
- **Resolved implies deposits paused**: `setResolvedAndPausedDeposits` writes both flags together — SwapPool.sol:573-574.
- **Pool key uniqueness**: `if (poolIndex[key] != 0) revert PoolAlreadyExists` over `keccak256(A_contract, A_id, B_contract, B_id)` — PoolFactory.sol:214. (Note: order matters — `(A,B)` and `(B,A)` are distinct keys.)
- **Rescue never touches LP funds**: `rescueTokens` enforces `amount <= actual - tracked`; `rescueERC1155` reverts for own markets — SwapPool.sol:611, :624.

### Inferred Invariants

- **Exchange rate monotone non-decreasing across swap**: `totalSharesNorm` increases by `normIn - protocolFee` while `totalLpSupply` is unchanged by swap. Violated if a future change makes swap mint/burn LP.
- **Same-side withdrawal is value-preserving**: `lpBurned * totalSharesNorm / totalLpSupply → rawOut` with no fee, so a round-trip `deposit(X) → withdraw(X, sameSide)` returns `≤ X` (≤ because rounding favors the pool) and is never blocked by `swapsPaused`.
- **`totalLpSupply == 0` ⇒ both balance slots drained next withdraw**: `_flushResidualIfEmpty` runs at the end of every withdraw path. Violated if a future path forgets to call it.
- **Protocol fee never exceeds LP's remaining output**: `normOut - lpFee - protocolFee ≥ 0`. Combined MAX fees = 150bps < 10000, so subtraction cannot underflow for realistic `normOut`.
- **Factory ↔ pool identity is immutable**: Pool stores `factory` as `immutable`; compromising factory compromises the pool, but factory cannot be swapped post-deploy.

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Present | `README.md` — architecture, mechanics, deploy flow, 400+ lines. |
| NatSpec | Adequate | Extensive file-level and role/flow NatSpec; per-function `@notice` on most externals; `@param`/`@return` sparser on internal helpers. |
| Spec/Whitepaper | Missing | No `spec.md` / `whitepaper.pdf` / `design.md` detected. |
| Inline Comments | Thorough | Section dividers (`─── X ───`), rationale comments on non-obvious flows (residual flush, single-rounding fees, `recordFee` unauthenticated-by-design note). |
| Audit artifacts | Present | `audit/` folder contains AI audit reports and developer responses. |

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files | 2 | File scan (always reliable) |
| Test functions | 119 | File scan (always reliable) |
| Line coverage | Unavailable — `forge coverage` failed (exit 1) during analysis | Coverage tool |
| Branch coverage | Unavailable — same | Coverage tool |

### Test Depth

| Category | Count | Contracts Covered |
|----------|-------|-------------------|
| Unit | 119 | SwapPool, PoolFactory, LPToken, FeeCollector (broad) |
| Stateless Fuzz | 0 | none |
| Stateful Fuzz (Foundry) | 0 | none |
| Stateful Fuzz (Echidna) | 0 | none |
| Stateful Fuzz (Medusa) | 0 | none |
| Formal Verification (Certora) | 0 | none |
| Formal Verification (Halmos) | 0 | none |
| Formal Verification (HEVM) | 0 | none |
| Scribble Annotations | 0 | none |
| Fork | 0 | none |

### Gaps

- **No stateful fuzzing / invariants** — for a protocol whose correctness hinges on an accounting identity (`totalSharesNorm / totalLpSupply` monotone; same-side round-trip ≤ in; rescue never touches LP funds), a Foundry `invariant_*` test suite would directly encode the inferred invariants in §3. Highest-leverage gap.
- **No stateless fuzzing** — `_computeFees`, `_toNorm`/`_fromNorm`, `withdrawBothSides` splitting math are all arithmetic-heavy and well-suited to property-based tests.
- **No fork tests** — pool behavior against real Polymarket / Opinion Trade ERC-1155 contracts on their deployed chains is not exercised; integration tests use `MockERC1155.sol`.

---

## 6. Developer & Git History

> Repo shape: **normal_dev** — 24 commits over 37 days (2026-03-04 → 2026-04-10); 10 commits touch source files; no merge commits.

### Contributors

| Author | Commits | Source Lines (+/-) | % of Source Changes |
|--------|--------:|--------------------|--------------------:|
| Iurii  | 24      | +2200 / -960      | 100%                |

Single-developer codebase. No peer-review history visible on-chain.

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors | 1 | Single-dev — no peer review evidence |
| Merge commits | 0 of 24 (0%) | No formal PR/review flow |
| Repo age | 2026-03-04 → 2026-04-10 | 37 days, short history |
| Recent source activity (30d) | 8 commits | Active through audit window |
| Test co-change rate | 80% | 80% of source-changing commits also modify tests — measures file co-modification, NOT coverage |

### File Hotspots

| File | Modifications | Note |
|------|-------------:|------|
| src/SwapPool.sol | 10 | Highest churn — matches threat surface priority |
| src/PoolFactory.sol | 9 | Access-control / routing layer — frequently reshaped |
| src/LPToken.sol | 5 | Stable, small |
| src/FeeCollector.sol | 5 | Stable, small |

### Security-Relevant Commits

**Score** = weighted sum of fix-like signals (message keywords, diff patterns, security-domain coverage). 10+ warrants a manual diff.

| SHA | Date | Subject | Score | Key Signal |
|-----|------|---------|------:|------------|
| 00e897d | 2026-03-04 | first full version with tests and deploy | 16 | tightens access control (+3/-2); touches all 3 domains; includes tests |
| 0b9d21f | 2026-03-04 | init | 13 | adds runtime guards (+45/-0); touches all 3 domains |
| ba90e05 | 2026-03-23 | updated to two LP version | 11 | tightens access control (+9/-3); 611 lines; all 3 domains |
| e1c1e83 | 2026-03-22 | formated code | 10 | tightens access control (+1/-0); "formatting" commit also shifted access-control code — **worth a manual diff** |
| 54b2735 | 2026-04-08 | updated Factory and Pool | 9 | loosens access control (+7/-9); 848 lines; no test change |
| e1740e6 | 2026-03-23 | updated based on audit findings | 8 | rewrites access control (+4/-4); no test co-change |
| ecd4961 | 2026-03-22 | formatted files | 8 | rewrites access control (+6/-6); 220 lines under a cosmetic label |
| e5ad181 | 2026-03-20 | updated contracts to v1.0.2 | 8 | tightens access control (+3/-1); all 3 domains |
| ddde578 | 2026-04-08 | updated tests | 7 | small diff, test-only |
| fe4c74d | 2026-03-23 | updated _computeFees | 7 | 2 domains; focused single-file fix — direct follow-up to audit finding on fee rounding |

### Dangerous Area Evolution

| Security Area | Commits | Key Files |
|--------------|--------:|-----------|
| fund_flows | 10 | SwapPool.sol, PoolFactory.sol, FeeCollector.sol |
| state_machines | 10 | SwapPool.sol, PoolFactory.sol |
| access_control | 9 | PoolFactory.sol, FeeCollector.sol, LPToken.sol |

Every source-touching commit hit fund_flows and state_machines; 90% also hit access_control. Reshaping is concentrated in SwapPool and PoolFactory, which are exactly the threat-prioritized contracts above.

### Security Observations

- **Single-developer risk**: 100% of source changes by one author with zero merge commits. No second-pair-of-eyes signal in-repo; external AI audit is the only review artifact on-disk.
- **Formatting commits changing access control**: `e1c1e83` and `ecd4961` are labeled as formatting but have non-zero access-control diffs — these warrant a manual diff read, because security-relevant changes can hide inside cosmetic-labeled PRs.
- **Late large diff without tests**: `54b2735` (2026-04-08, "updated Factory and Pool", 848 lines, loosens access control, no test co-change) is the largest recent commit and the only significant recent one without test changes.
- **Audit follow-up is localized**: `e1740e6` ("updated based on audit findings") and `fe4c74d` ("updated _computeFees") are small, focused, audit-driven; `fe4c74d` aligns with the single-rounding fee design noted in `audit/ai_audit_reply.md`.
- **Test co-change rate 80% is high but measures co-modification, not coverage**: combined with zero fuzz/invariant tests, this means "tests are updated alongside source" but does not guarantee the updates actually exercise new paths.
- **Forked deps are clean**: OpenZeppelin is vendored as a git submodule (not internalized). Pragma diversity inside `lib/openzeppelin-contracts` is the upstream's own pragma range — not a local fork.

### Cross-Reference Synthesis

- `SwapPool.sol` is both the top git hotspot (10 mods) and the largest threat-model surface (user-facing entry points + decimal/fee math + rescue). Prioritize deep review here.
- `e1c1e83` and `ecd4961` are labeled cosmetic but altered access_control — reconcile against the current `onlyOwner`/`onlyOperator`/`msg.sender == factory` patterns in PoolFactory and SwapPool.
- `fe4c74d` is the `_computeFees` single-rounding rework flagged in §2 (Protocol-Type Concerns). The code at `SwapPool.sol:299-309` matches the rework; regression tests for boundary cases (`totalBps=0`, `amount=1`, max-bps) should be verified.
- No technical debt markers (TODO/FIXME/HACK/XXX) were found. Zero tier-drop from code hygiene.

---

## X-Ray Verdict

**FRAGILE** — Tests cover unit-level behavior broadly but no stateful fuzz, invariant, or formal-verification tests exist; access control is role-split and bounded but has no timelock or on-chain multisig enforcement.

**Structural facts:**
1. 705 nSLOC across 4 contracts in 3 subsystems (Pool, Factory, LP+Fees); no proxy/upgrade machinery.
2. 119 unit test functions across 2 test files; 0 fuzz, 0 invariant, 0 formal-verification tests; coverage tool failed to run in this environment.
3. Single developer wrote 100% of source lines over 37 days; zero merge commits; no peer-review history visible in-repo.
4. Two-tier role model (owner / operator) gated by OpenZeppelin `Ownable` + custom `onlyOperator` modifier; no timelock; fee caps enforced (MAX_LP_FEE=100bps, MAX_PROTOCOL_FEE=50bps).
5. One AI audit cycle completed; two follow-up commits (`e1740e6`, `fe4c74d`) encode the fee-rounding remediation.
