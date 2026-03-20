# PredictSwap

**Cross-chain prediction market arbitrage and liquidity protocol.**

Identical real-world events trade at different prices across fragmented prediction market platforms. PredictSwap is the first permissionless venue for 1:1 swaps between [Polymarket](https://polymarket.com) (Polygon) and [Opinion](https://opinion.markets) (BSC) shares — the same outcome, two chains, one pool.

---

## How It Works

YES shares for the same event on Polymarket and Opinion should cost exactly the same. In practice they don't, due to low liquidity and no cross-platform arbitrage infrastructure. PredictSwap fixes this:

1. **Bridge** — Users lock Opinion ERC-1155 shares on BSC via `OpinionEscrow`. LayerZero V2 relays the message to Polygon, where `BridgeReceiver` mints 1:1 `WrappedOpinionToken` (ERC-1155).
2. **Pool** — Each `SwapPool` holds one matched pair (Polymarket tokenId ↔ Opinion tokenId). Both sides are treated as economically equivalent.
3. **Swap** — Users deposit one side and receive the other, minus a 0.40% fee (0.30% to LPs, 0.10% protocol).
4. **Liquidity** — LPs deposit single-sided. LP tokens accrue fees automatically — no claiming needed.

```
BSC                                    Polygon
───────────────────────────────────────────────────────
Opinion ERC-1155                       Polymarket ERC-1155
     │                                        │
OpinionEscrow ──── LayerZero V2 ───► BridgeReceiver
     │                                        │
     └──────────── WrappedOpinionToken ───────┘
                            │
                        SwapPool
                      (1:1 AMM)
```

---

## Pool Mechanics

```
exchangeRate  = totalShares / lpSupply          (1e18 scaled)
lpToMint      = depositAmount * lpSupply / totalShares   (1:1 on first deposit)
sharesOut     = lpBurned * totalShares / lpSupply

Swap fee:     0.40% total
  0.30% LP fee      → stays in pool (auto-compounds, no new LP minted)
  0.10% protocol    → transferred to FeeCollector
```

LP fees compound silently into `totalShares` without minting new LP tokens — existing LP positions appreciate automatically.

---

## Architecture

| Contract | Chain | Role |
|---|---|---|
| `OpinionEscrow` | BSC | Locks Opinion ERC-1155 shares, sends LZ message |
| `BridgeReceiver` | Polygon | Receives LZ message, mints/burns `WrappedOpinionToken` |
| `WrappedOpinionToken` | Polygon | ERC-1155 wrapper, 1:1 backed by locked shares |
| `PoolFactory` | Polygon | Deploys pools, owns fee config |
| `SwapPool` | Polygon | 1:1 AMM per matched market pair |
| `LPToken` | Polygon | ERC-20 LP token per pool |
| `FeeCollector` | Polygon | Accumulates protocol fees |

Cross-chain messaging uses **LayerZero V2 OApp**. Native tokens stay on their home chains — no token bridging, only message passing.

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

## Deployment

All deploy scripts require environment variables to be loaded first:

```bash
source .env
```

### 1. Deploy Mock Polymarket Token (testnet only)

```bash
forge script script/integration_tests/DeployMockPoly.s.sol:DeployMockPolymarket \
  --rpc-url $POLYGON_RPC_URL \
  --broadcast \
  --verify \
  --verifier etherscan \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=$POLYGON_CHAIN_ID" \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

### 2. Mint Mock Tokens (testnet only)

```bash
forge script script/integration_tests/MintMock.s.sol \
  --rpc-url $POLYGON_RPC_URL \
  --broadcast
```

### 3. Deploy FeeCollector + PoolFactory

```bash
forge script script/Deploy.s.sol \
  --rpc-url $POLYGON_RPC_URL \
  --broadcast \
  --verify \
  --verifier etherscan \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=$POLYGON_CHAIN_ID" \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

### 4. Create a Pool

```bash
forge script script/CreatePool.s.sol \
  --rpc-url $POLYGON_RPC_URL \
  --broadcast \
  --verify \
  --verifier etherscan \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=$POLYGON_CHAIN_ID" \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

---

## Integration Testing

These scripts run against live testnet state and do not require `--verify`:

```bash
# Deposit into pool
forge script script/integration_tests/Deposit.s.sol \
  --rpc-url $POLYGON_RPC_URL --broadcast

# Swap between sides
forge script script/integration_tests/Swap.s.sol \
  --rpc-url $POLYGON_RPC_URL --broadcast

# Withdraw from pool
forge script script/integration_tests/Withdraw.s.sol \
  --rpc-url $POLYGON_RPC_URL --broadcast
```

---

## Environment Variables

```env
POLYGON_RPC_URL=
POLYGON_CHAIN_ID=137
BSC_RPC_URL=
BSC_CHAIN_ID=56
ETHERSCAN_API_KEY=
PRIVATE_KEY=
```

---

## Security

- `ReentrancyGuard` on all state-mutating pool functions
- Internal balance accounting — not `balanceOf` — as the source of truth (donation-immune)
- `WrappedOpinionToken.setBridge()` callable only once (`BridgeAlreadySet` guard)
- `OpinionEscrow` and `BridgeReceiver` are pausable by owner
- Rescue functions for stuck tokens/ETH, with guards preventing rescue of actively locked funds

Audit is in progress. Do not deploy to mainnet without a completed audit.

---

## License

MIT