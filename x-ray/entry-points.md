# Entry Point Map

> PredictSwap | 28 entry points | 5 permissionless | 12 role-gated | 11 admin-only

---

## Protocol Flow Paths

### Setup (Owner)

`deploy PoolFactory(marketA, marketB, feeCollector, operator, owner)` -> `PoolFactory.createPool(configA, configB, fees)`

### User Flow

`[createPool above]` -> `SwapPool.deposit(side, amount)`  <-- !depositsPaused && !resolved
                          |-> `SwapPool.swap(fromSide, sharesIn)`  <-- !swapsPaused && !resolved && sufficient liquidity
                          |-> `SwapPool.withdrawal(receiveSide, lpAmount, lpSide)`  <-- !swapsPaused && sufficient physical balance
                          +-> `SwapPool.withdrawProRata(lpAmount, lpSide)`  <-- swapsPaused (emergency exit)

### Lifecycle (Operator)

`[pool active]` -> [event resolves off-chain] -> `PoolFactory.resolvePoolAndPause(poolId)`  <-- atomic: resolved + depositsPaused + swapsPaused
                                                   +-> users call `withdrawProRata()` to exit

### Alternate Resolution

`[pool active]` -> `PoolFactory.setResolvePool(poolId, true)`  <-- sets resolved only, swaps/deposits blocked by resolved flag
                     +-> users call `withdrawal()` with zero fees (resolved)

---

## Permissionless

### `SwapPool.deposit()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, whenInitialized |
| Caller | User / LP |
| Parameters | `side` (user-controlled), `amount` (user-controlled) |
| Call chain | -> `_pullTokens()` -> `IERC1155.safeTransferFrom()` -> `_addSideValue()` -> `_mintLp()` -> `LPToken.mint()` |
| State modified | `aSideValue` or `bSideValue` += normAmount; `LPToken.totalSupply[tokenId]` += lpMinted; `LPToken.freshDeposit[user][tokenId]` updated |
| Value flow | Tokens: sender -> SwapPool |
| Reentrancy guard | yes |

### `SwapPool.swap()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, whenInitialized |
| Caller | User / Trader |
| Parameters | `fromSide` (user-controlled), `sharesIn` (user-controlled) |
| Call chain | -> `_pullTokens(fromSide)` -> `_pushTokens(fromSide, feeCollector)` -> `FeeCollector.recordFee()` -> `_pushTokens(toSide, user)` -> `_distributeLpFee()` |
| State modified | `aSideValue` and/or `bSideValue` via `_distributeLpFee`; physical token balances change |
| Value flow | Tokens: sender -> SwapPool (input), SwapPool -> sender (output), SwapPool -> FeeCollector (protocol fee) |
| Reentrancy guard | yes |

### `SwapPool.withdrawal()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, whenInitialized |
| Caller | User / LP |
| Parameters | `receiveSide` (user-controlled), `lpAmount` (user-controlled), `lpSide` (user-controlled) |
| Call chain | -> `_lpToShares()` -> `_freshConsumedForBurn()` -> `LPToken.lockedAmount()` -> `_burnLp()` -> `LPToken.burn()` -> `_subSideValue()` -> `_distributeLpFee()` -> `_pushTokens(user)` -> `_pushTokens(feeCollector)` -> `_flushResidualIfEmpty()` |
| State modified | `aSideValue` / `bSideValue` decreased; `LPToken.totalSupply` decreased; `LPToken.freshDeposit` updated; physical balances change |
| Value flow | Tokens: SwapPool -> sender (payout), SwapPool -> FeeCollector (protocol fee) |
| Reentrancy guard | yes |

### `SwapPool.withdrawProRata()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, whenInitialized |
| Caller | User / LP |
| Parameters | `lpAmount` (user-controlled), `lpSide` (user-controlled) |
| Call chain | -> `_lpToShares()` -> `_burnLp()` -> `LPToken.burn()` -> `_subSideValue()` -> `_pushTokens(nativeSide, user)` -> `_pushTokens(crossSide, user)` -> `_flushResidualIfEmpty()` |
| State modified | `aSideValue` / `bSideValue` decreased; `LPToken.totalSupply` decreased; physical balances change |
| Value flow | Tokens: SwapPool -> sender (native + cross portions) |
| Reentrancy guard | yes |

### `FeeCollector.recordFee()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, NONE -- permissionless |
| Caller | Anyone (intended: SwapPool only) |
| Parameters | `token` (user-controlled), `tokenId` (user-controlled), `amount` (user-controlled) |
| Call chain | emits `FeeReceived` event only |
| State modified | none (event-only) |
| Value flow | none |
| Reentrancy guard | no |

---

## Role-Gated

### `Factory` (msg.sender == factory, checked inside SwapPool)

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| SwapPool | `initialize(marketALpTokenId_, marketBLpTokenId_)` | tokenIds (protocol-derived) | `marketALpTokenId`, `marketBLpTokenId`, `_initialized` = true |
| SwapPool | `setDepositsPaused(paused_)` | bool (operator-provided) | `depositsPaused` |
| SwapPool | `setSwapsPaused(paused_)` | bool (operator-provided) | `swapsPaused` |
| SwapPool | `setResolved(resolved_)` | bool (operator-provided) | `resolved` |
| SwapPool | `setResolvedAndPaused()` | none | `resolved` = true, `depositsPaused` = true, `swapsPaused` = true |
| SwapPool | `setFees(lpFeeBps_, protocolFeeBps_)` | fee bps (owner-provided) | `lpFeeBps`, `protocolFeeBps` |
| SwapPool | `rescueTokens(side, rawAmount, to)` | side, amount, recipient (owner-provided) | physical balance decrease |
| SwapPool | `rescueERC1155(contractAddr, tokenId, amount, to)` | ERC-1155 params (owner-provided) | external ERC-1155 balance |
| SwapPool | `rescueERC20(token, amount, to)` | ERC-20 params (owner-provided) | external ERC-20 balance |
| SwapPool | `rescueETH(to)` | recipient (owner-provided) | ETH balance |

### `Pool` (onlyPool modifier in LPToken)

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| LPToken | `mint(to, tokenId, amount)` | (protocol-derived) | `totalSupply[tokenId]`, `balanceOf[to][tokenId]`, `freshDeposit[to][tokenId]` |
| LPToken | `burn(from, tokenId, amount)` | (protocol-derived) | `totalSupply[tokenId]`, `balanceOf[from][tokenId]`, `freshDeposit[from][tokenId]` |

### `Operator` (onlyOperator modifier in PoolFactory)

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| PoolFactory | `createPool(marketA, marketB, lpFee, protocolFee, desc)` | configs, fees (operator-provided) | `pools[]`, `poolIndex`, `usedMarketATokenId`, `usedMarketBTokenId`, deploys SwapPool |
| PoolFactory | `setPoolDepositsPaused(poolId, paused)` | (operator-provided) | -> SwapPool.depositsPaused |
| PoolFactory | `setPoolSwapsPaused(poolId, paused)` | (operator-provided) | -> SwapPool.swapsPaused |
| PoolFactory | `setResolvePool(poolId, resolved)` | (operator-provided) | -> SwapPool.resolved |
| PoolFactory | `resolvePoolAndPause(poolId)` | (operator-provided) | -> SwapPool.resolved + depositsPaused + swapsPaused |

---

## Admin-Only

### Owner (onlyOwner in PoolFactory / FeeCollector)

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| PoolFactory | `setOperator(operator_)` | address (owner-provided) | `operator` |
| PoolFactory | `setFeeCollector(feeCollector_)` | address (owner-provided) | `feeCollector` (future pools only) |
| PoolFactory | `setPoolFees(poolId, lpFee, protocolFee)` | fees (owner-provided) | -> SwapPool.lpFeeBps, protocolFeeBps |
| PoolFactory | `rescuePoolTokens(poolId, side, amount, to)` | (owner-provided) | -> SwapPool.rescueTokens |
| PoolFactory | `rescuePoolERC1155(poolId, contractAddr, tokenId, amount, to)` | (owner-provided) | -> SwapPool.rescueERC1155 |
| PoolFactory | `rescuePoolERC20(poolId, token, amount, to)` | (owner-provided) | -> SwapPool.rescueERC20 |
| PoolFactory | `rescuePoolETH(poolId, to)` | (owner-provided) | -> SwapPool.rescueETH |
| FeeCollector | `withdraw(token, tokenId, amount, to)` | (owner-provided) | ERC-1155 balance |
| FeeCollector | `withdrawBatch(token, tokenIds, amounts, to)` | (owner-provided) | ERC-1155 balances |
| FeeCollector | `withdrawAll(token, tokenId, to)` | (owner-provided) | ERC-1155 balance |
| FeeCollector | `withdrawAllBatch(token, tokenIds, to)` | (owner-provided) | ERC-1155 balances |
