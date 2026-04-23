# Entry Point Map

> PredictSwap v3 | 28 entry points | 5 permissionless | 6 operator-gated | 17 admin/owner-only

---

## Protocol Flow Paths

### Setup (Owner -> Operator)

```
PoolFactory.constructor(owner_)
  -> PoolFactory.setOperator(operator_)     (optional, set in constructor)
  -> PoolFactory.createPool(marketA, marketB, fees)
     |-- new SwapPool(...)
     |-- LPToken.registerPool(pool, lpIdA)   one-shot
     |-- LPToken.registerPool(pool, lpIdB)   one-shot
     +-- SwapPool.initialize(lpIdA, lpIdB)   one-shot, atomic in createPool
```

### User Flow (swaps active)

```
[pool created]
  -> SwapPool.deposit(side, amount)                   deposits not paused, not resolved
     |-> SwapPool.swap(fromSide, sharesIn)             swaps not paused, output liquidity exists
     |-> SwapPool.withdrawal(receiveSide, lpAmount, lpSide)   swaps not paused
     +-> [repeat]
```

### User Flow (swaps paused / resolved)

```
[pool resolved or swaps paused]
  -> SwapPool.withdrawProRata(lpAmount, lpSide)        swaps ARE paused, fee-free proportional exit
```

### Resolution (Operator)

```
[pool active]
  -> [event resolves off-chain]
  -> PoolFactory.resolvePoolAndPause(poolId)
     +-- SwapPool.setResolvedAndPaused()
         resolved=true, depositsPaused=true, swapsPaused=true
  -> users exit via withdrawProRata()
```

### Fee Withdrawal (Owner)

```
[swaps/withdrawals generate protocol fees]
  -> FeeCollector.withdraw(token, tokenId, amount, to)
  -> FeeCollector.withdrawAll(token, tokenId, to)
  -> FeeCollector.withdrawBatch(token, tokenIds[], amounts[], to)
  -> FeeCollector.withdrawAllBatch(token, tokenIds[], to)
```

---

## Permissionless

### `SwapPool.deposit(Side side, uint256 amount)`

| Aspect | Detail |
|--------|--------|
| Signature | `deposit(Side, uint256) external nonReentrant whenInitialized returns (uint256 lpMinted)` |
| Location | `SwapPool.sol:252-277` |
| Caller | Any user / LP |
| Parameters | `side` (user-controlled enum), `amount` (user-controlled uint256) |
| Guards | [G-1](invariants.md#g-1-depositspaused-gate) depositsPaused, [G-2](invariants.md#g-2-resolved-gate-deposit) resolved, [G-3](invariants.md#g-3-zero-amount-deposit) amount!=0, [G-4](invariants.md#g-4-dust-deposit) lpMinted!=0, [G-22](invariants.md#g-22-wheninitialized-modifier) initialized |
| Call chain | `_pullTokens() -> IERC1155.safeTransferFrom()` -> `_toNorm()` -> `_addSideValue()` -> `_mintLp() -> LPToken.mint() -> ERC1155._mint() -> _update()` |
| State modified | `aSideValue` or `bSideValue` += normAmount; `LPToken.totalSupply[tokenId]` += lpMinted; `LPToken.balanceOf[user][tokenId]` += lpMinted; `LPToken.freshDeposit[user][tokenId]` updated (weighted merge) |
| Value flow | **IN**: ERC-1155 shares from user to pool |
| Reentrancy | `nonReentrant` guard on SwapPool; ERC-1155 `safeTransferFrom` callback occurs during `_pullTokens` before state changes |
| Return | `lpMinted` -- number of LP tokens minted |

### `SwapPool.swap(Side fromSide, uint256 sharesIn)`

| Aspect | Detail |
|--------|--------|
| Signature | `swap(Side, uint256) external nonReentrant whenInitialized returns (uint256 sharesOut)` |
| Location | `SwapPool.sol:284-323` |
| Caller | Any user / swapper |
| Parameters | `fromSide` (user-controlled enum), `sharesIn` (user-controlled uint256) |
| Guards | [G-5](invariants.md#g-5-swapspaused-gate-swap) swapsPaused, [G-6](invariants.md#g-6-zero-amount-swap) sharesIn!=0, [G-7](invariants.md#g-7-swap-liquidity-check) normOut<=availableOut, [G-8](invariants.md#g-8-zero-output-swap) rawOut!=0, [G-22](invariants.md#g-22-wheninitialized-modifier) initialized |
| Call chain | `_pullTokens(fromSide) -> IERC1155.safeTransferFrom()` -> `_pushTokens(fromSide -> FeeCollector) -> IERC1155.safeTransferFrom()` -> `FeeCollector.recordFee()` -> `_pushTokens(toSide -> user) -> IERC1155.safeTransferFrom()` -> `_addSideValue(toSide, lpFee)` |
| State modified | `aSideValue` or `bSideValue` += lpFee (drained side only) |
| Value flow | **IN**: fromSide shares from user. **OUT**: toSide shares to user + fromSide protocol fee to FeeCollector |
| Reentrancy | `nonReentrant` guard; three external calls via `safeTransferFrom` (pull, push to collector, push to user); `_addSideValue` executes after all three pushes |
| Return | `sharesOut` -- raw output amount sent to user |

### `SwapPool.withdrawal(Side receiveSide, uint256 lpAmount, Side lpSide)`

| Aspect | Detail |
|--------|--------|
| Signature | `withdrawal(Side, uint256, Side) external nonReentrant whenInitialized returns (uint256 received)` |
| Location | `SwapPool.sol:336-407` |
| Caller | Any LP holder |
| Parameters | `receiveSide` (user-controlled enum), `lpAmount` (user-controlled uint256), `lpSide` (user-controlled enum) |
| Guards | [G-9](invariants.md#g-9-swapspaused-gate-withdrawal) swapsPaused must be false, [G-10](invariants.md#g-10-zero-amount-withdrawal) lpAmount!=0, [G-11](invariants.md#g-11-withdrawal-liquidity-check) totalOutflow<=available, [G-22](invariants.md#g-22-wheninitialized-modifier) initialized |
| Call chain | `_lpToShares()` -> `_freshConsumedForBurn() -> LPToken.lockedAmount() + LPToken.balanceOf()` -> `_computeFees()` -> `_subSideValue()` -> `_burnLp() -> LPToken.burn() -> ERC1155._burn() -> _update()` -> `_pushTokens(-> user)` -> `_pushTokens(-> FeeCollector)` -> `_flushResidualIfEmpty()` |
| State modified | `aSideValue`/`bSideValue` debited (and possibly credited on opposite side for lpFee); `LPToken.totalSupply` -= lpAmount; `LPToken.balanceOf[user]` -= lpAmount; `LPToken.freshDeposit` updated |
| Value flow | **OUT**: receiveSide shares to user (payout) + receiveSide shares to FeeCollector (protocol fee) |
| Fee logic | Same-side: JIT fee on fresh portion only (when unresolved). Cross-side: full fee on claim (when unresolved). Resolved: no fees. |
| Reentrancy | `nonReentrant` guard; LP burn triggers `_update` hook; two external `safeTransferFrom` calls for payout and protocol fee |
| Return | `received` -- raw payout amount sent to user |

### `SwapPool.withdrawProRata(uint256 lpAmount, Side lpSide)`

| Aspect | Detail |
|--------|--------|
| Signature | `withdrawProRata(uint256, Side) external nonReentrant whenInitialized returns (uint256 nativeOut, uint256 crossOut)` |
| Location | `SwapPool.sol:420-467` |
| Caller | Any LP holder |
| Parameters | `lpAmount` (user-controlled uint256), `lpSide` (user-controlled enum) |
| Guards | [G-12](invariants.md#g-12-swapsnotpaused-gate-withdrawprorata) swapsPaused must be true, [G-13](invariants.md#g-13-zero-amount-withdrawprorata) lpAmount!=0, [G-14](invariants.md#g-14-cross-side-liquidity-withdrawprorata) crossShare<=availableCross, [G-22](invariants.md#g-22-wheninitialized-modifier) initialized |
| Call chain | `_lpToShares()` -> `_subSideValue()` -> `_burnLp() -> LPToken.burn()` -> `_pushTokens(nativeSide -> user)` -> `_pushTokens(crossSide -> user)` -> `_flushResidualIfEmpty()` |
| State modified | `aSideValue`/`bSideValue` -= shares; `LPToken.totalSupply` -= lpAmount; `LPToken.balanceOf[user]` -= lpAmount |
| Value flow | **OUT**: native-side shares to user + cross-side shares to user. No fees. |
| Pro-rata math | `nativeShare = (lpAmount * availableNative) / totalSupply`, capped at `shares`. Remainder paid in cross-side tokens. |
| Reentrancy | `nonReentrant` guard; two external `safeTransferFrom` calls |
| Return | `nativeOut` (raw native amount), `crossOut` (raw cross amount) |

### `FeeCollector.recordFee(address token, uint256 tokenId, uint256 amount)`

| Aspect | Detail |
|--------|--------|
| Signature | `recordFee(address, uint256, uint256) external` |
| Location | `FeeCollector.sol:33-36` |
| Caller | **Anyone** (intended: SwapPool after fee transfer) |
| Parameters | `token` (user-controlled), `tokenId` (user-controlled), `amount` (user-controlled) |
| Guards | [G-36](invariants.md#g-36-feecollector-zero-amount-guard) amount!=0 |
| Call chain | Emits `FeeReceived(msg.sender, token, tokenId, amount)` only |
| State modified | None -- event-only accounting |
| Value flow | None |
| Reentrancy | No guard (no state changes) |
| Security note | Permissionless -- off-chain indexers MUST filter by `msg.sender` being a known SwapPool address |

---

## Role-Gated (Operator via PoolFactory)

Access: `onlyOperator` modifier -- operator address OR owner.

| Function | Location | Parameters | Call Chain | State Modified |
|----------|----------|------------|------------|----------------|
| `PoolFactory.createPool(marketA_, marketB_, lpFeeBps_, protocolFeeBps_, eventDescription_)` | `PoolFactory.sol:192-248` | All operator-provided | `new SwapPool(...)` -> `LPToken.registerPool() x2` -> `SwapPool.initialize()` | `pools[]` appended, `poolIndex[key]` set, `usedMarket*TokenId` set true, `LPToken.pool[tokenId]` set, `SwapPool._initialized` set true |
| `PoolFactory.setPoolDepositsPaused(poolId, paused_)` | `PoolFactory.sol:296-299` | poolId, paused_ | `SwapPool.setDepositsPaused()` | `SwapPool.depositsPaused` |
| `PoolFactory.setPoolSwapsPaused(poolId, paused_)` | `PoolFactory.sol:301-305` | poolId, paused_ | `SwapPool.setSwapsPaused()` | `SwapPool.swapsPaused` |
| `PoolFactory.setResolvePool(poolId, resolved_)` | `PoolFactory.sol:308-312` | poolId, resolved_ | `SwapPool.setResolved()` | `SwapPool.resolved` |
| `PoolFactory.resolvePoolAndPause(poolId)` | `PoolFactory.sol:316-322` | poolId | `SwapPool.setResolvedAndPaused()` | `SwapPool.resolved=true`, `depositsPaused=true`, `swapsPaused=true` |

---

## Admin-Only (Owner)

### PoolFactory (onlyOwner via OZ Ownable)

| Function | Location | Parameters | State Modified |
|----------|----------|------------|----------------|
| `setOperator(operator_)` | `PoolFactory.sol:277-281` | operator_ (non-zero) | `operator` |
| `setFeeCollector(feeCollector_)` | `PoolFactory.sol:283-286` | feeCollector_ (non-zero) | `feeCollector` (factory only; existing pools keep old collector) |
| `setPoolFees(poolId, lpFeeBps_, protocolFeeBps_)` | `PoolFactory.sol:289-292` | poolId, lpFeeBps_ (<=100), protocolFeeBps_ (<=50) | `SwapPool.lpFeeBps`, `SwapPool.protocolFeeBps` |
| `rescuePoolTokens(poolId, side, amount, to)` | `PoolFactory.sol:326-331` | all owner-provided | Physical balance only (surplus above tracked value) |
| `rescuePoolERC1155(poolId, contractAddr, tokenId, amount, to)` | `PoolFactory.sol:333-338` | all owner-provided | Sends non-pool ERC-1155 tokens from pool |
| `rescuePoolERC20(poolId, token, amount, to)` | `PoolFactory.sol:340-344` | all owner-provided | Sends stuck ERC-20 tokens from pool |
| `rescuePoolETH(poolId, to)` | `PoolFactory.sol:346-349` | poolId, to | Sends stuck ETH from pool |

### FeeCollector (onlyOwner via OZ Ownable)

| Function | Location | Parameters | State Modified |
|----------|----------|------------|----------------|
| `withdraw(token, tokenId, amount, to)` | `FeeCollector.sol:40-45` | all owner-provided | ERC-1155 balance of FeeCollector |
| `withdrawBatch(token, tokenIds[], amounts[], to)` | `FeeCollector.sol:47-59` | all owner-provided | ERC-1155 balances (batch) |
| `withdrawAll(token, tokenId, to)` | `FeeCollector.sol:62-68` | all owner-provided | Entire balance of one tokenId |
| `withdrawAllBatch(token, tokenIds[], to)` | `FeeCollector.sol:72-81` | all owner-provided | Entire balances of multiple tokenIds |

---

## View / Pure Functions (no state changes)

| Contract | Function | Returns |
|----------|----------|---------|
| SwapPool | `marketARate()` | Current A-side LP rate (1e18 scaled) |
| SwapPool | `marketBRate()` | Current B-side LP rate (1e18 scaled) |
| SwapPool | `totalFeeBps()` | lpFeeBps + protocolFeeBps |
| SwapPool | `physicalBalanceNorm(Side)` | Normalized physical balance of a side |
| LPToken | `lockedAmount(user, tokenId)` | Currently-locked fresh LP amount |
| LPToken | `isLocked(user, tokenId)` | Whether any portion is still fresh |
| LPToken | `totalSupply(tokenId)` | Total supply for a tokenId |
| LPToken | `balanceOf(user, tokenId)` | User balance for a tokenId (inherited ERC1155) |
| PoolFactory | `getPool(poolId)` | PoolInfo struct |
| PoolFactory | `getAllPools()` | Array of all PoolInfo |
| PoolFactory | `poolCount()` | Number of pools |
| PoolFactory | `findPool(marketATokenId, marketBTokenId)` | (found, poolId) lookup |
