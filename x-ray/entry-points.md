# Entry Points -- PredictSwap v3

---

## Protocol Flow Paths

### Path 1: Deposit

```
User -> SwapPool.deposit(side, amount)
  -> _pullTokens(side, user, amount)           [ERC-1155 safeTransferFrom]
  -> _toNorm(side, amount)                      [normalize to 18-dec]
  -> _lpToken(side).totalSupply(_lpTokenId)     [read LP supply via factory]
  -> _addSideValue(side, normAmount)            [increase aSideValue or bSideValue]
  -> _mintLp(side, user, lpMinted)              [factory.marketXLpToken().mint()]
    -> LPToken.mint(to, tokenId, amount)
      -> totalSupply[tokenId] += amount
      -> _mint(to, tokenId, amount, "")
        -> _update() hook: inflow branch grows fresh bucket
```

### Path 2: Swap

```
User -> SwapPool.swap(fromSide, sharesIn)
  -> _toNorm(fromSide, sharesIn)                [normalize]
  -> _computeFees(normIn)                       [ceiling-rounded total fee, split LP/protocol]
  -> physicalBalanceNorm(toSide)                [check output liquidity]
  -> _pullTokens(fromSide, user, sharesIn)      [ERC-1155 in]
  -> _fromNorm(fromSide, protocolFee)           [denormalize protocol fee]
  -> _pushTokens(fromSide, feeCollector, raw)   [protocol fee to FeeCollector]
  -> feeCollector.recordFee(...)                [event only]
  -> _fromNorm(toSide, normOut)                 [denormalize output]
  -> _pushTokens(toSide, user, rawOut)          [ERC-1155 out]
  -> _addSideValue(toSide, lpFee)              [LP fee accrues to drained side]
```

### Path 3: Withdrawal (swaps active)

```
User -> SwapPool.withdrawal(receiveSide, lpAmount, lpSide)
  -> _lpToShares(lpSide, lpAmount)              [convert LP to normalized value]
  -> _freshConsumedForBurn(lpSide, lpAmount)    [query LPToken.lockedAmount]
  -> _computeFees(feeBase)                      [JIT fee or cross-side fee]
  -> physicalBalanceNorm(receiveSide)            [check liquidity]
  -> _subSideValue / _addSideValue              [update value accounting]
  -> _burnLp(lpSide, user, lpAmount)
    -> LPToken.burn(from, tokenId, amount)
      -> totalSupply[tokenId] -= amount
      -> _burn(from, tokenId, amount)
        -> _update() hook: outflow branch consumes matured first
  -> _fromNorm(receiveSide, payout)             [denormalize]
  -> _pushTokens(receiveSide, user, rawPayout)  [ERC-1155 out]
  -> _pushTokens(receiveSide, feeCollector, rawProto)  [protocol fee if any]
  -> _flushResidualIfEmpty()                    [sweep dust if all LP burned]
```

### Path 4: Withdrawal Pro-Rata (swaps paused)

```
User -> SwapPool.withdrawProRata(lpAmount, lpSide)
  -> _lpToShares(lpSide, lpAmount)              [convert LP to normalized value]
  -> physicalBalanceNorm(nativeSide)             [read native physical]
  -> proportional split: nativeShare = (lpAmount * availableNative) / totalSupply
  -> cap nativeShare at shares; remainder = crossShare
  -> _subSideValue(lpSide, shares)
  -> _burnLp(lpSide, user, lpAmount)
  -> _pushTokens(nativeSide, user, rawNative)   [native portion]
  -> _pushTokens(crossSide, user, rawCross)     [cross portion if any]
  -> _flushResidualIfEmpty()
```

### Path 5: Pool Creation

```
Operator -> PoolFactory.createPool(marketA, marketB, fees, description)
  -> validate tokenId uniqueness (usedMarketATokenId, usedMarketBTokenId)
  -> new SwapPool(factory, marketA, marketB, fees, feeCollector)
  -> marketALpToken.registerPool(pool, lpIdA)   [one-shot assignment]
  -> marketBLpToken.registerPool(pool, lpIdB)
  -> pool.initialize(lpIdA, lpIdB)              [one-time wiring]
  -> pools.push(PoolInfo{...})
```

---

## Permissionless (User)

All functions: `nonReentrant`, `whenInitialized`.

### `SwapPool.deposit(Side side, uint256 amount)`

- **Guards:** `!depositsPaused`, `!resolved`, `amount > 0`
- **Value flow:** IN (ERC-1155 shares from user to pool)
- **State writes:** `aSideValue` or `bSideValue` += normAmount; LPToken totalSupply += lpMinted; fresh bucket updated
- **Revert conditions:** DepositsPaused, MarketResolved, ZeroAmount, DepositTooSmall (lpMinted==0), ERC-1155 transfer failure

### `SwapPool.swap(Side fromSide, uint256 sharesIn)`

- **Guards:** `!swapsPaused`, `!resolved`, `sharesIn > 0`
- **Value flow:** IN (fromSide shares) + OUT (toSide shares + protocol fee to FeeCollector)
- **State writes:** sideValue of toSide += lpFee (no sideValue decrease -- physical composition shifts)
- **Revert conditions:** SwapsPaused, MarketResolved, ZeroAmount, InsufficientLiquidity, SwapTooSmall (rawOut==0)

### `SwapPool.withdrawal(Side receiveSide, uint256 lpAmount, Side lpSide)`

- **Guards:** `!swapsPaused`, `lpAmount > 0`
- **Value flow:** OUT (shares to user + protocol fee to FeeCollector)
- **State writes:** sideValue decreased; LP burned; fresh bucket consumed; flush residual if empty
- **Revert conditions:** SwapsPaused, ZeroAmount, InsufficientLiquidity, ZeroAmount (rawPayout==0)
- **Fee logic:** Same-side = JIT fee on fresh portion only; cross-side = full fee. No fee when resolved.

### `SwapPool.withdrawProRata(uint256 lpAmount, Side lpSide)`

- **Guards:** `swapsPaused` (required), `lpAmount > 0`
- **Value flow:** OUT (proportional native + cross shares to user)
- **State writes:** sideValue decreased; LP burned; flush residual if empty
- **Revert conditions:** SwapsNotPaused, ZeroAmount, InsufficientLiquidity (cross-side), ZeroAmount (both outputs zero)

### `FeeCollector.recordFee(address token, uint256 tokenId, uint256 amount)`

- **Guards:** `amount > 0`
- **Value flow:** None (event only)
- **State writes:** None
- **Note:** Fully permissionless. Emits `FeeReceived` with `msg.sender` as pool address. Off-chain consumers must filter.

---

## Operator (+ Owner)

All gated by `onlyOperator` modifier: `msg.sender == operator || msg.sender == owner()`.

### `PoolFactory.createPool(MarketConfig, MarketConfig, uint256, uint256, string)`

- **Effect:** Deploys new SwapPool, registers LP tokenIds, initializes pool
- **Guards:** tokenId != 0, decimals <= 18, unique tokenId per side, unique pair key
- **Downstream:** Calls `SwapPool.initialize()`, `LPToken.registerPool()` (both one-shot)

### `PoolFactory.setPoolDepositsPaused(uint256 poolId, bool paused_)`

- **Effect:** Sets `SwapPool.depositsPaused`
- **Guards:** valid poolId

### `PoolFactory.setPoolSwapsPaused(uint256 poolId, bool paused_)`

- **Effect:** Sets `SwapPool.swapsPaused`
- **Guards:** valid poolId

### `PoolFactory.setResolvePool(uint256 poolId, bool resolved_)`

- **Effect:** Sets `SwapPool.resolved`
- **Guards:** valid poolId

### `PoolFactory.resolvePoolAndPause(uint256 poolId)`

- **Effect:** Sets resolved=true, depositsPaused=true, swapsPaused=true in one call
- **Guards:** valid poolId

---

## Owner Only

All gated by OZ `onlyOwner`.

### `PoolFactory.setOperator(address operator_)`

- **Effect:** Changes operator address
- **Guards:** operator_ != address(0)

### `PoolFactory.setFeeCollector(address feeCollector_)`

- **Effect:** Updates factory-level feeCollector
- **Note:** Does NOT propagate to existing pools (SwapPool.feeCollector is immutable)

### `PoolFactory.setPoolFees(uint256 poolId, uint256 lpFeeBps_, uint256 protocolFeeBps_)`

- **Effect:** Updates fee configuration on a specific pool
- **Guards:** lpFeeBps_ <= 100 (1%), protocolFeeBps_ <= 50 (0.5%)

### `PoolFactory.rescuePoolTokens(uint256 poolId, Side, uint256, address)`

- **Effect:** Rescues surplus pool tokens (global surplus check)
- **Note:** Uses global surplus = totalPhysical(A+B) - totalTracked. Can drain from either side.

### `PoolFactory.rescuePoolERC1155(uint256 poolId, address, uint256, uint256, address)`

- **Effect:** Rescues non-pool ERC-1155 tokens accidentally sent to the pool
- **Guards:** contractAddress != marketA and != marketB

### `PoolFactory.rescuePoolERC20(uint256 poolId, address, uint256, address)`

- **Effect:** Rescues ERC-20 tokens accidentally sent to the pool

### `PoolFactory.rescuePoolETH(uint256 poolId, address payable)`

- **Effect:** Rescues ETH sent to the pool

### `FeeCollector.withdraw(address, uint256, uint256, address)`

- **Effect:** Withdraws specific amount of a specific tokenId

### `FeeCollector.withdrawBatch(address, uint256[], uint256[], address)`

- **Effect:** Batch withdrawal with caller-specified amounts

### `FeeCollector.withdrawAll(address, uint256, address)`

- **Effect:** Withdraws entire balance of a single tokenId

### `FeeCollector.withdrawAllBatch(address, uint256[], address)`

- **Effect:** Withdraws entire balances of multiple tokenIds, skipping zeros

---

## Internal-Only (no external access)

### `SwapPool.initialize(uint256, uint256)`

- **Caller:** PoolFactory only (`msg.sender == address(factory)`)
- **One-shot:** reverts on `AlreadyInitialized`
- **Effect:** Sets `marketALpTokenId`, `marketBLpTokenId`, `_initialized = true`

### `SwapPool.setDepositsPaused / setSwapsPaused / setResolved / setResolvedAndPaused / setFees`

- **Caller:** PoolFactory only
- **Effect:** Admin state changes on the pool

### `LPToken.registerPool(address, uint256)`

- **Caller:** Factory only
- **One-shot per tokenId:** reverts on `TokenIdAlreadyRegistered`

### `LPToken.mint / LPToken.burn`

- **Caller:** Registered pool for that tokenId only (`onlyPool(tokenId)`)
