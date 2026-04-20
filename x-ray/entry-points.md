# Entry Point Map

> PredictSwap | 35 entry points | 5 permissionless | 17 role-gated | 13 admin-only

---

## Protocol Flow Paths

### Setup (Owner → Operator)

`new FeeCollector(owner_)` → `new PoolFactory(feeCollector_, operator_, owner_)`
                                      │
                                      └─► `PoolFactory.approveMarketContract(marketA_addr)` [Owner]
                                      └─► `PoolFactory.approveMarketContract(marketB_addr)` [Owner]
                                                │
                                                └─► `PoolFactory.createPool(marketA, marketB, fees, lpMeta)` [Operator or Owner]
                                                      ├─► `new LPToken(A)` and `new LPToken(B)`
                                                      ├─► `new SwapPool(...)`
                                                      ├─► `LPToken.setPool(pool)` × 2  ◄── atomic, one-shot
                                                      └─► push into `pools[]` / `poolIndex[key]`

### User Flow (permissionless)

`[createPool above]` → user holds market ERC-1155 shares → user approves pool operator on market ERC-1155
                                                                │
                                                                └─► `SwapPool.deposit(side, amount)`  ◄── !depositsPaused
                                                                      ├─► `SwapPool.swap(fromSide, sharesIn)`  ◄── !swapsPaused, toSide has liquidity
                                                                      ├─► `SwapPool.withdrawSingleSide(lp, lpSide, receiveSide)`
                                                                      │        └─► same-side path: free, never blocked
                                                                      │        └─► cross-side path: !swapsPaused; fee unless resolved
                                                                      └─► `SwapPool.withdrawBothSides(lp, lpSide, samesideBps)`
                                                                               same rules per sub-path

### Pool Lifecycle (Operator)

`[deposits above]` → [market event settled off-chain] → `PoolFactory.resolvePoolAndPausedDeposits(poolId)`
                                                             └─► `SwapPool.setResolvedAndPausedDeposits()`  ◄── cross-side withdrawals become fee-free
                                                        or     `PoolFactory.setPoolDepositsPaused / setPoolSwapsPaused(poolId, bool)`
                                                             └─► corresponding SwapPool setter

### Fee Withdrawal (Owner)

`[user swaps / cross-side withdrawals accrue protocol fee]` → raw ERC-1155 transferred to FeeCollector
                                                                    │
                                                                    └─► `FeeCollector.withdraw | withdrawBatch | withdrawAll | withdrawAllBatch` [Owner]

---

## Permissionless

### `SwapPool.deposit(Side side, uint256 amount)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | LP (user) |
| Parameters | side (user-controlled), amount (user-controlled) |
| Call chain | `→ IERC1155(_marketContract).safeTransferFrom(user → pool) → LPToken(side).mint(user, lpMinted)` |
| State modified | `marketABalance` or `marketBBalance`; LP token `totalSupply` |
| Value flow | User → Pool (ERC-1155 shares in); LP token minted to user |
| Reentrancy guard | yes |

### `SwapPool.swap(Side fromSide, uint256 sharesIn)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Trader / Arbitrageur (user) |
| Parameters | fromSide (user-controlled), sharesIn (user-controlled) |
| Call chain | `→ IERC1155.safeTransferFrom(user → pool) → IERC1155.safeTransferFrom(pool → FeeCollector) → FeeCollector.recordFee() → IERC1155.safeTransferFrom(pool → user)` |
| State modified | `marketABalance`, `marketBBalance` |
| Value flow | User → Pool (fromSide sharesIn); Pool → FeeCollector (rawProtocol); Pool → User (sharesOut toSide) |
| Reentrancy guard | yes |

### `SwapPool.withdrawSingleSide(uint256 lpAmount, Side lpSide, Side receiveSide)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | LP (user) |
| Parameters | lpAmount (user-controlled), lpSide (user-controlled), receiveSide (user-controlled) |
| Call chain | `→ LPToken(lpSide).burn(user) → IERC1155.safeTransferFrom(pool → user) [→ IERC1155.safeTransferFrom(pool → FeeCollector) → FeeCollector.recordFee() if cross-side and !resolved]` |
| State modified | one LP token `totalSupply`; one or both balance slots; if last exit, `_flushResidualIfEmpty` sweeps both |
| Value flow | LP tokens burned; Pool → User (shares); Pool → FeeCollector on cross-side |
| Reentrancy guard | yes |

### `SwapPool.withdrawBothSides(uint256 lpAmount, Side lpSide, uint256 samesideBps)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | LP (user) |
| Parameters | lpAmount (user-controlled), lpSide (user-controlled), samesideBps (user-controlled, ≤ FEE_DENOMINATOR) |
| Call chain | `→ LPToken(lpSide).burn(user) → IERC1155.safeTransferFrom(pool → user) [same-side] → IERC1155.safeTransferFrom(pool → user / FeeCollector) [cross-side if >0]` |
| State modified | LP token `totalSupply`; both balance slots |
| Value flow | LP burned; Pool → User (same-side + cross-side); Pool → FeeCollector (cross-side protocol fee) |
| Reentrancy guard | yes |

### `FeeCollector.recordFee(address token, uint256 tokenId, uint256 amount)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone (intended: SwapPool) |
| Parameters | token (user-controlled), tokenId (user-controlled), amount (user-controlled) |
| Call chain | emits `FeeReceived(msg.sender, token, tokenId, amount)` |
| State modified | none |
| Value flow | none — event emission only |
| Reentrancy guard | no |
| Note | Unauthenticated by design — off-chain consumers filter `FeeReceived` by `msg.sender` matching a known SwapPool (doc: FeeCollector.sol:30-32). |

### `SwapPool.receive()` payable (not a function call — ETH fallback)

Anyone can send ETH; only `rescueETH` (owner-routed) drains it. No other business logic reads ETH balance.

---

## Role-Gated

### SwapPool — `msg.sender == address(factory)` (all admin routes below)

All of these are invoked only from PoolFactory. The factory enforces its own role split before routing.

#### `SwapPool.setDepositsPaused(bool paused_)` *(factory routes operator/owner)*
| Aspect | Detail |
|--------|--------|
| Visibility | external, msg.sender check |
| Caller | PoolFactory |
| Parameters | paused_ (protocol-derived) |
| State modified | `depositsPaused` |
| Value flow | none |

#### `SwapPool.setSwapsPaused(bool paused_)` *(factory routes operator/owner)*
Same shape; writes `swapsPaused`.

#### `SwapPool.setResolvedAndPausedDeposits()` *(factory routes operator/owner)*
Writes `resolved = true; depositsPaused = true`. Reverts if already resolved.

#### `SwapPool.unsetResolved()` *(factory routes operator/owner)*
Writes `resolved = false`. Reverts if not resolved.

#### `SwapPool.setFees(uint256 lpFeeBps_, uint256 protocolFeeBps_)` *(factory routes owner)*
Checks MAX_LP_FEE / MAX_PROTOCOL_FEE caps; updates `lpFeeBps`, `protocolFeeBps`.

#### `SwapPool.rescueTokens(Side side, uint256 amount, address to)` *(factory routes owner)*
Only rescues `actual - tracked` surplus on the pool's own markets. Reverts `NothingToRescue` if amount exceeds surplus.

#### `SwapPool.rescueERC1155(address contractAddress_, uint256 tokenId_, uint256 amount, address to)` *(factory routes owner)*
Reverts if `contractAddress_` is either of the pool's own market contracts.

#### `SwapPool.rescueERC20(address token, uint256 amount, address to)` *(factory routes owner)*
Unscoped ERC-20 rescue — pool does not hold ERC-20 operationally.

#### `SwapPool.rescueETH(address payable to)` *(factory routes owner)*
Drains entire ETH balance to `to`.

### LPToken — `onlyPool`

#### `LPToken.mint(address to, uint256 amount)` / `LPToken.burn(address from, uint256 amount)`
| Aspect | Detail |
|--------|--------|
| Visibility | external, onlyPool (`msg.sender == pool`) |
| Caller | SwapPool |
| Parameters | protocol-derived |
| Call chain | `ERC20._mint / _burn` |

### LPToken — factory-only, one-shot

#### `LPToken.setPool(address pool_)`
| Aspect | Detail |
|--------|--------|
| Visibility | external, `msg.sender == factory` |
| Caller | PoolFactory (during createPool) |
| Parameters | pool_ (protocol-derived) |
| State modified | `pool` (one-time, reverts if already set) |

### PoolFactory — `onlyOperator` (operator or owner)

#### `PoolFactory.createPool(MarketConfig marketA_, MarketConfig marketB_, uint256 lpFeeBps_, uint256 protocolFeeBps_, string marketALpName, string marketALpSymbol, string marketBLpName, string marketBLpSymbol)`
| Aspect | Detail |
|--------|--------|
| Visibility | external, onlyOperator |
| Caller | Operator (or Owner) |
| Parameters | marketA_/marketB_ (operator-provided; must be pre-approved), fees (operator-provided; capped in SwapPool ctor), LP metadata (operator-provided) |
| Call chain | `→ new LPToken × 2 → new SwapPool → LPToken.setPool × 2 → pools.push → poolIndex[key] = poolId+1` |
| State modified | `pools`, `poolIndex` |
| Value flow | none (no tokens pulled) |

#### `PoolFactory.setPoolDepositsPaused(uint256 poolId, bool paused_)` — routes to `SwapPool.setDepositsPaused`.
#### `PoolFactory.setPoolSwapsPaused(uint256 poolId, bool paused_)` — routes to `SwapPool.setSwapsPaused`.
#### `PoolFactory.resolvePoolAndPausedDeposits(uint256 poolId)` — routes to `SwapPool.setResolvedAndPausedDeposits`.
#### `PoolFactory.unresolvePool(uint256 poolId)` — routes to `SwapPool.unsetResolved`.

---

## Admin-Only

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| PoolFactory | `approveMarketContract(marketContract_)` | address | `approvedMarketContracts[addr] = true` |
| PoolFactory | `revokeMarketContract(marketContract_)` | address | `approvedMarketContracts[addr] = false` (existing pools unaffected) |
| PoolFactory | `setOperator(operator_)` | address | `operator` |
| PoolFactory | `setFeeCollector(feeCollector_)` | address | `feeCollector` (future pools only — existing pools keep their immutable address) |
| PoolFactory | `setPoolFees(poolId, lpFeeBps_, protocolFeeBps_)` | ids + bps (capped) | pool's `lpFeeBps`, `protocolFeeBps` |
| PoolFactory | `rescuePoolTokens(poolId, side, amount, to)` | routing params | pool's market ERC-1155 surplus only |
| PoolFactory | `rescuePoolERC1155(poolId, contract, tokenId, amount, to)` | routing params | foreign ERC-1155 (reverts on own market contracts) |
| PoolFactory | `rescuePoolERC20(poolId, token, amount, to)` | routing params | pool's ERC-20 balance |
| PoolFactory | `rescuePoolETH(poolId, to)` | routing params | pool's ETH balance |
| FeeCollector | `withdraw(token, tokenId, amount, to)` | ERC-1155 params | fee balance decremented via safeTransferFrom |
| FeeCollector | `withdrawBatch(token, tokenIds, amounts, to)` | batch params | fee balances |
| FeeCollector | `withdrawAll(token, tokenId, to)` | no amount | full balance for that tokenId |
| FeeCollector | `withdrawAllBatch(token, tokenIds, to)` | batch | full balances for each tokenId (zero balances silently skipped) |

All admin functions are `onlyOwner` on their respective contracts (`PoolFactory.owner()` and `FeeCollector.owner()`), execute instantly, and are not subject to any timelock or on-chain multisig check.
