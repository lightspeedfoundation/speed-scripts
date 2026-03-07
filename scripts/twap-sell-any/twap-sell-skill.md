# TWAP Sell Skill

Complete reference for `twap-sell-any.ps1` and `twap-sell-any.sh` — Time-Weighted Average Price sell execution bots built on the `speed` CLI.

---

## Table of Contents

1. [Concept](#1-concept)
2. [Parameters Reference](#2-parameters-reference)
3. [Execution Math](#3-execution-math)
4. [Script Flow](#4-script-flow)
5. [Running the Scripts](#5-running-the-scripts)
6. [Reading the Output](#6-reading-the-output)
7. [Interpreting the Summary](#7-interpreting-the-summary)
8. [Pitfalls and Limits](#8-pitfalls-and-limits)

---

## 1. Concept

TWAP sell is the mirror of TWAP buy: split an existing token position into N equal slices and sell one slice per interval, regardless of price. The goal is to minimise slippage and market impact when exiting a large position.

A single large market sell on a thin orderbook can move the price 3–10% against you before the order fills. Spreading the sell over time allows the orderbook to recover between fills, resulting in a better average exit price.

**When to use it:**
- You hold a large token position relative to the token's liquidity
- You need to exit but want to minimise price impact
- You do not have a specific price target — you just want out over time
- You want to record the average exit price and best/worst fills for P/L tracking

**Difference from `ladder-sell-any`:** Ladder sell exits at price targets (each rung fires at a specific profit %). TWAP sell exits on time regardless of whether price is up or down. Ladder sell is reward-optimised; TWAP sell is execution-optimised.

**No initial buy:** Unlike most other scripts in this toolkit, TWAP sell does not execute a buy first. It operates on a position you already hold. Use `speed balance` to check your current holdings before running.

---

## 2. Parameters Reference

| Parameter (PS1)    | Flag (SH)             | Type    | Default  | Description |
|---|---|---|---|---|
| `-Chain`           | `--chain`             | string  | required | Chain name or ID (`base`, `ethereum`, `arbitrum`, etc.) |
| `-Token`           | `--token`             | string  | required | Token contract address or alias (`speed`). |
| `-TokenAmount`     | `--token-amount`      | string  | required | Total token amount to sell, in human-readable units (e.g. `98000` or `0.00002287`). Run `speed balance` to check holdings. |
| `-Slices`          | `--slices`            | integer | `5`      | Number of equal sell slices. |
| `-IntervalSeconds` | `--interval-seconds`  | integer | `300`    | Wait time between slices (seconds). |
| `-TokenSymbol`     | `--tokensymbol`       | string  | address  | Display label in output. |
| `-DryRun`          | `--dry-run`           | switch  | off      | Quote each slice and log timing without executing sells. |

---

## 3. Execution Math

```
sliceAmount = TokenAmount / Slices

For each slice i:
  Execute: speed swap --sell Token --buy eth -a sliceAmount
  Record: ethReceived_i, price_i = ethReceived_i / sliceAmount

Summary:
  totalEth     = sum(ethReceived_i)
  averagePrice = mean(price_i)
```

**Total execution time:**
```
totalTime = (Slices - 1) × IntervalSeconds
e.g. Slices=5, IntervalSeconds=300 → 4 × 300s = 20 minutes
```

---

## 4. Script Flow

```
Setup
  Detect token decimals
  Compute sliceAmount = TokenAmount / Slices
  Log execution plan

For each slice 1..N:
  Quote sliceAmount Token → ETH  (preview)
  Execute sell (or DryRun log)
  Record ethReceived, price
  Wait IntervalSeconds (skip on last slice)

Summary
  Total tokens sold, total ETH received
  Average price, price range
  Best/worst slice (highest/lowest ETH per token)
  Failed slice count (if any)
```

---

## 5. Running the Scripts

### Find your token balance first

```powershell
# Check current holdings
speed balance -c base
```

### PowerShell — common scenarios

```powershell
# SPEED: sell 98000 tokens in 5 slices, 5 minutes apart
.\twap-sell-any.ps1 -Chain base -Token speed -TokenAmount 98000 -Slices 5 -IntervalSeconds 300

# cbBTC: sell small position in 5 slices
.\twap-sell-any.ps1 -Chain base `
    -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf `
    -TokenSymbol cbBTC `
    -TokenAmount 0.00002287 -Slices 5 -IntervalSeconds 600

# Slow exit: 8 slices, 30 min apart (3.5 hours)
.\twap-sell-any.ps1 -Chain base -Token speed -TokenAmount 500000 -Slices 8 -IntervalSeconds 1800

# Dry run: preview sell prices and timing
.\twap-sell-any.ps1 -Chain base -Token speed -TokenAmount 98000 -Slices 5 -DryRun
```

### Bash — common scenarios

```bash
# SPEED: sell 98000 tokens
./twap-sell-any.sh --chain base --token speed --token-amount 98000 --slices 5 --interval-seconds 300

# cbBTC: sell small position
./twap-sell-any.sh --chain base \
    --token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf \
    --tokensymbol cbBTC \
    --token-amount 0.00002287 --slices 5 --interval-seconds 600

# Dry run
./twap-sell-any.sh --chain base --token speed --token-amount 98000 --slices 5 --dry-run

# Make executable first (Linux/Mac)
chmod +x twap-sell-any.sh
```

---

## 6. Reading the Output

### Per-slice output

```
[09:00:00] Slice 1/5 — quoting 19600.000000 SPEED -> ETH...
         Quote: 0.00040040 ETH  (price: 0.00000002043 ETH/token)
         >>> speed swap -c base --sell speed --buy eth -a 19600.000000 -y
         Slice 1 complete. Got 0.00040040 ETH.
[09:05:00] Slice 2/5 — quoting 19600.000000 SPEED -> ETH...
         Quote: 0.00039800 ETH  (price: 0.00000002031 ETH/token)
         ...
```

### Summary block

```
=== TWAP Sell Complete ===
  Slices completed  : 5 / 5
  Total tokens sold : 98000.000000 SPEED
  Total ETH received: 0.00199820 ETH
  Average price     : 0.00000002039 ETH/token
  Price range       : 0.00000002025 – 0.00000002055 ETH/token
  Best slice        : Slice 1  (0.00000002043 ETH/token)
  Worst slice       : Slice 4  (0.00000002025 ETH/token)
```

---

## 7. Interpreting the Summary

**Average price** — mean ETH received per token across all slices. Higher is better (you sold at a better rate on average).

**Best slice** — the slice that received the most ETH per token (highest sell price). Indicates the best moment in the execution window.

**Worst slice** — the slice that received the least ETH per token (lowest sell price). May indicate a brief dip or a large sell moving the market.

**Failed slices** — if any slices failed, those tokens remain in your wallet. The summary warns you to check the balance manually.

---

## 8. Pitfalls and Limits

| Pitfall | Details | Fix |
|---|---|---|
| TokenAmount exceeds actual wallet balance | If you specify more tokens than you actually hold, the first sell that attempts to exceed the balance will fail. | Run `speed balance -c <chain>` first to confirm the exact amount. |
| Price falls throughout execution | TWAP averages in both directions. If price declines during execution, later slices sell at lower prices. | TWAP does not optimise for price direction. If price is crashing, consider selling all at once or using a stop-loss instead. |
| Rounding leaves a dust amount | When sliceAmount has many decimal places, rounding may leave a tiny amount unsold after N slices. | The summary reports total tokens sold. Run `speed balance` after completion to check for dust. |
| Interval too short on low-liquidity tokens | Very frequent sells may drain the orderbook liquidity before it recovers. | Use longer IntervalSeconds for thin tokens — give the market time to replenish. |
| Parallel sells conflict | Running TWAP sell simultaneously with another exit script (trailing stop, bracket) on the same token creates competing sell transactions. | Run only one exit script at a time per token position. |
