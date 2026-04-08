# PredictSwap

**Cross-chain prediction market arbitrage and liquidity protocol.**

Identical real-world events trade at different prices across fragmented prediction market platforms. PredictSwap is the first permissionless venue for 1:1 swaps between shares on any two ERC-1155 prediction market platforms — same outcome, different platforms, one pool.

---

## How It Works

YES shares for the same event on two platforms should cost exactly the same. In practice they don't, due to low liquidity and no cross-platform arbitrage infrastructure. PredictSwap fixes this:

1. **Bridge** — For cross-chain markets, users lock ERC-1155 shares on the source chain via an escrow contract. LayerZero V2 relays the message to the destination chain, where a receiver contract mints 1:1 wrapped tokens.
2. **Pool** — Each `SwapPool` holds one matched pair (marketA tokenId ↔ marketB tokenId). Both sides are treated as economically equivalent.
3. **Swap** — Users deposit one side and receive the other, minus a per-pool fee (default 0.40% — 0.30% to LPs, 0.10% protocol).
4. **Liquidity** — LPs deposit single-sided. LP tokens accrue fees automatically — no claiming needed.

```
Source Chain                          Destination Chain
──────────────────────────────────────────────────────
Market A ERC-1155                     Market B ERC-1155
     │                                      (native)
  Escrow                                       │
     │                                         │
     └──── LayerZero V2 ────► BridgeReceiver   │
                                     │         │
                               WrappedToken    │
                                     │         │
                                     └── SwapPool ──┘
                                        (1:1 AMM)
```

Same-chain markets skip the bridge entirely — `SwapPool` works with any two ERC-1155 contracts on the same chain.

---

## Pool Mechanics

```
exchangeRate  = totalSharesNorm / lpSupply       (1e18 scaled)
lpToMint      = normAmount * lpSupply / totalSharesNorm  (1:1 on first deposit)
normOut       = lpBurned * totalSharesNorm / lpSupply
rawOut        = denormalize(normOut, receiveSide)

Swap fee:     configurable per pool, default 0.40% total
  LP fee      → stays in pool (auto-compounds, no new LP minted)
  Protocol    → transferred to FeeCollector
```

All pool math operates in a shared 18-decimal normalized space. Raw balances are stored in each token's native decimals. This allows pools to pair tokens with different decimal precisions (e.g. 6-decimal and 18-decimal shares) without any value distortion.

LP fees compound silently into `totalSharesNorm` without minting new LP tokens — existing LP positions appreciate automatically.

### Fee Calculation

Fees are set per-pool at creation time and adjustable by the factory owner. They are computed as a single ceiling-rounded total, then split between LP and protocol:

```
totalFee    = ceil(amount * (lpFeeBps + protocolFeeBps) / FEE_DENOMINATOR)
protocolFee = (totalFee * protocolFeeBps) / (lpFeeBps + protocolFeeBps)
lpFee       = totalFee - protocolFee
```

A single ceiling rounding (not one per component) ensures the aggregate fee never exceeds one rounding unit above the configured rate, while still guaranteeing at least 1 unit of fee on any non-zero amount with non-zero bps.

### Withdrawal Rules

| Operation | Fee | Blocked by `swapsPaused`? |
|---|---|---|
| `deposit()` | None | No |
| `withdrawSingleSide()` — same side | None | No |
| `withdrawSingleSide()` — cross side | Yes (unless resolved) | Yes |
| `withdrawBothSides()` — same-side portion | None | No |
| `withdrawBothSides()` — cross-side portion | Yes (unless resolved) | Yes |
| `swap()` | Yes | Yes |

Same-side withdrawals are never blocked. LPs can always exit on their original side regardless of pool state.

`withdrawBothSides()` accepts a `samesideBps` parameter (0–10000) instead of absolute amounts — the split is computed on-chain at execution time, preventing DoS from stale off-chain values:

```
samesideAmount  = grossOut * samesideBps / FEE_DENOMINATOR
crosssideAmount = grossOut - samesideAmount
```

---

## Architecture

### Pool layer (generic — any two ERC-1155 markets)

| Contract | Role |
|---|---|
| `PoolFactory` | Deploys pools, maintains registry, manages operator role and approved market contracts |
| `SwapPool` | 1:1 AMM per matched market pair. Fully self-describing — stores both market contract addresses, token IDs, decimals, names, and fees |
| `LPToken` | ERC-20 LP token. Two per pool — one per market side |
| `FeeCollector` | Accumulates protocol fees across all pools |

### Bridge layer (cross-chain pairs)

| Contract | Role |
|---|---|
| `Escrow` | Locks ERC-1155 shares on source chain, sends LayerZero message |
| `BridgeReceiver` | Receives LayerZero message, mints/burns wrapped tokens on destination chain |
| `WrappedToken` | ERC-1155 wrapper, 1:1 backed by locked shares on source chain |

Cross-chain messaging uses **LayerZero V2 OApp**. Native tokens stay on their home chains — no token bridging, only message passing. Same-chain market pairs require no bridge at all.

### Roles

| Role | Permissions |
|---|---|
| Owner (multisig) | Approve/revoke market contracts, update fee collector, change fees per pool, rescue stuck funds, set operator |
| Operator (EOA) | Create pools, pause/unpause deposits and swaps, resolve/unresolve pools |

The owner can perform all operator actions. The operator cannot touch fees or rescue funds.

---

## Development

Built with [Foundry](https://book.getfoundry.sh/).

### Prerequisites

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### Build & Test

```bash
forge build
forge test
forge fmt
forge snapshot   # gas snapshots
```

---

## Deployment

All deploy scripts require environment variables to be loaded first:

```bash
source .env
```

### 1. Deploy mock market tokens (testnet only)

```bash
forge script script/integration_tests/DeployMockPoly.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify \
  --verifier etherscan \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=$CHAIN_ID" \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

```bash
forge script script/integration_tests/MintMock.s.sol \
  --rpc-url $RPC_URL \
  --broadcast
```

Add `MARKET_A_CONTRACT`, `MARKET_B_CONTRACT`, `MARKET_A_TOKEN_ID`, `MARKET_B_TOKEN_ID` to `.env`.

### 2. Deploy FeeCollector + PoolFactory

```bash
forge script script/Deploy.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify \
  --verifier etherscan \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=$CHAIN_ID" \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

Add `FEE_COLLECTOR_ADDRESS` and `POOL_FACTORY_ADDRESS` to `.env`.

### 3. Approve market contracts

Both market contracts must be whitelisted by the factory owner before a pool can be created:

```bash
forge script script/ApproveMarketContract.s.sol \
  --rpc-url $RPC_URL \
  --broadcast
```

### 4. Create a pool

```bash
forge script script/CreatePool.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify \
  --verifier etherscan \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=$CHAIN_ID" \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

---

## Integration Testing

```bash
# Deposit into pool
forge script script/integration_tests/Deposit.s.sol \
  --rpc-url $RPC_URL --broadcast

# Swap between sides
forge script script/integration_tests/Swap.s.sol \
  --rpc-url $RPC_URL --broadcast

# Withdraw from pool
forge script script/integration_tests/WithdrawBothSides.s.sol \
  --rpc-url $RPC_URL --broadcast

forge script script/integration_tests/WithdrawSingleSide.s.sol \
  --rpc-url $RPC_URL --broadcast

forge script script/integration_tests/WithdrawAll.s.sol \
  --rpc-url $RPC_URL --broadcast
```

---

## Security

- `ReentrancyGuard` on all state-mutating pool functions with CEI ordering (LP burn before ERC-1155 transfers)
- Internal balance accounting — not `balanceOf` — as the source of truth (donation-immune)
- Approved market contract whitelist on factory — prevents operator from creating pools with unvetted ERC-1155 contracts
- Pool is fully self-describing — market contract addresses stored as immutables on the pool, independent of factory state
- `swapsPaused` blocks all cross-side value transfers: `swap()`, cross-side `withdrawSingleSide()`, and the cross-side portion of `withdrawBothSides()`
- `depositsPaused` and `swapsPaused` are independent flags — pausing one does not affect the other
- `resolved` and `depositsPaused` are independent — `unsetResolved()` does not re-enable deposits
- Fees are per-pool and adjustable only by factory owner (multisig) — operator cannot change fees
- Decimal normalization prevents value distortion when pairing tokens with different decimal precision
- Single ceiling-rounded fee prevents fee evasion via transaction splitting while avoiding double-rounding overcharge
- Cross-side liquidity checks use net debit (`actualOut + protocolFee`) — prevents false reverts near side depletion
- Last-LP residual flush (`_flushResidualIfEmpty`) sends orphaned LP fees to `FeeCollector` on full exit, preventing first-depositor capture
- Bridge escrow contracts are pausable by owner
- Wrapped token bridge address is set once and immutable thereafter
- Rescue functions for stuck tokens/ETH, owner-only, with guards preventing rescue of actively locked funds

---

## License

BUSL-1.1 — core protocol contracts (`SwapPool`, `PoolFactory`)

Scripts and tests are MIT.