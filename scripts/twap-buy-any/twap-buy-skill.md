# TWAP Buy Skill

Complete reference for `twap-buy-any.ps1` and `twap-buy-any.sh` — Time-Weighted Average Price buy execution bots built on the `speed` CLI.

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

TWAP (Time-Weighted Average Price) is an execution algorithm, not a trading strategy. The goal is not to predict price direction — it is to **minimise the timing risk and market impact** of a known, fixed order size.

Instead of executing a single large market buy (which creates slippage and exposes you entirely to one price point), TWAP splits the total order into N equal slices and executes one slice per interval regardless of current price.

**Result:** Your average entry price converges toward the time-weighted average price of the token over the execution window, rather than a single price point.

**When to use it:**
- You have decided to buy a specific total amount and want to reduce timing risk
- The token has thin liquidity — a single large buy would move the market against you
- You want price averaging without the indefinite commitment of DCA
- You are entering a large position and want spread over hours/days

**Difference from `dca` (CLI command):** The CLI `dca` command is perpetual/indefinite — it keeps buying on a schedule with no fixed total or end date. TWAP buy is a single session with a fixed total spend and a defined finish time.

**Difference from `value-average-any`:** Value averaging adjusts the buy amount based on portfolio value. TWAP always buys equal ETH slices regardless of price. TWAP is purely time-based execution.

---

## 2. Parameters Reference

| Parameter (PS1)    | Flag (SH)             | Type    | Default  | Description |
|---|---|---|---|---|
| `-Chain`           | `--chain`             | string  | required | Chain name or ID (`base`, `ethereum`, `arbitrum`, etc.) |
| `-Token`           | `--token`             | string  | required | Token contract address or alias (`speed`). |
| `-TotalAmount`     | `--total-amount`      | string  | required | Total ETH to deploy across all slices. |
| `-Slices`          | `--slices`            | integer | `5`      | Number of equal buy slices. |
| `-IntervalSeconds` | `--interval-seconds`  | integer | `300`    | Wait time between slices (seconds). |
| `-TokenSymbol`     | `--tokensymbol`       | string  | address  | Display label in output. |
| `-DryRun`          | `--dry-run`           | switch  | off      | Quote each slice and log timing without executing buys. |

---

## 3. Execution Math

```
sliceAmount = TotalAmount / Slices

For each slice i:
  Execute: speed swap --sell eth --buy Token -a sliceAmount
  Record: tokensReceived_i, price_i = sliceAmount / tokensReceived_i

Summary:
  totalTokens  = sum(tokensReceived_i)
  averagePrice = mean(price_i)
  variance     = (max(price_i) - min(price_i)) / mean(price_i) × 100
```

**Total execution time:**
```
totalTime = (Slices - 1) × IntervalSeconds
e.g. Slices=5, IntervalSeconds=300 → 4 intervals × 300s = 20 minutes
```

**Price averaging effect:**
If price moves linearly from P_start to P_end over the TWAP window:
```
TWAP average ≈ (P_start + P_end) / 2
```
Compared to a single buy at P_start, TWAP is better if price rises (you bought some cheaper slices) and worse if price falls (you kept buying into the decline). Over time, across many trades, the timing risk averages out.

---

## 4. Script Flow

```
Setup
  Detect token decimals
  Compute sliceAmount = TotalAmount / Slices
  Log execution plan

For each slice 1..N:
  Quote sliceAmount ETH → Token  (preview)
  Execute buy (or DryRun log)
  Record tokensReceived, price
  Wait IntervalSeconds (skip on last slice)

Summary
  Total ETH spent, total tokens received
  Average price, price range, variance
  Best/worst slice
  Failed slice count (if any)
```

---

## 5. Running the Scripts

### PowerShell — common scenarios

```powershell
# SPEED: 5 slices, 5 minutes apart (20 min total)
.\twap-buy-any.ps1 -Chain base -Token speed -TotalAmount 0.01 -Slices 5 -IntervalSeconds 300

# cbBTC: 10 slices, 10 minutes apart (90 min total)
.\twap-buy-any.ps1 -Chain base `
    -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf `
    -TokenSymbol cbBTC `
    -TotalAmount 0.05 -Slices 10 -IntervalSeconds 600

# Quick TWAP: 4 slices, 1 minute apart
.\twap-buy-any.ps1 -Chain base -Token speed -TotalAmount 0.004 -Slices 4 -IntervalSeconds 60

# Slow TWAP: 8 slices, 30 minutes apart (3.5 hours total)
.\twap-buy-any.ps1 -Chain base -Token speed -TotalAmount 0.08 -Slices 8 -IntervalSeconds 1800

# Dry run: preview prices and timing without spending
.\twap-buy-any.ps1 -Chain base -Token speed -TotalAmount 0.01 -Slices 5 -DryRun
```

### Bash — common scenarios

```bash
# SPEED: 5 slices, 5 minutes apart
./twap-buy-any.sh --chain base --token speed --total-amount 0.01 --slices 5 --interval-seconds 300

# cbBTC: 10 slices, 10 minutes apart
./twap-buy-any.sh --chain base \
    --token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf \
    --tokensymbol cbBTC \
    --total-amount 0.05 --slices 10 --interval-seconds 600

# Dry run
./twap-buy-any.sh --chain base --token speed --total-amount 0.01 --slices 5 --dry-run

# Make executable first (Linux/Mac)
chmod +x twap-buy-any.sh
```

---

## 6. Reading the Output

### Per-slice output

```
[09:00:00] Slice 1/5 — quoting 0.002 ETH -> cbBTC...
         Quote: 0.00000457 cbBTC  (price: 437.64 ETH/token)
         >>> speed swap -c base --sell eth --buy 0xcbB7... -a 0.002 -y
         Slice 1 complete. Got ~0.00000457 cbBTC.
[09:05:00] Slice 2/5 — quoting 0.002 ETH -> cbBTC...
         Quote: 0.00000459 cbBTC  (price: 435.73 ETH/token)
         ...
```

### Waiting between slices

```
[09:05:10] Waiting 300 s before slice 3...
```

### Summary block

```
=== TWAP Buy Complete ===
  Slices completed : 5 / 5
  Total ETH spent  : 0.01000000 ETH
  Total received   : 0.00002287 cbBTC
  Average price    : 437.14 ETH/token
  Price range      : 435.73 – 438.10 ETH/token
  Variance         : ±0.27%
  Best slice       : Slice 2  (435.73 ETH/token)
  Worst slice      : Slice 5  (438.10 ETH/token)
```

---

## 7. Interpreting the Summary

**Average price** — the mean price you paid across all slices. Lower is better (means you got more tokens per ETH).

**Variance ±X%** — the half-range of price variation as a % of the average. ±0.3% means prices were very stable. ±3%+ means significant price movement during execution.

**Best/worst slice** — the slice with the lowest/highest price (in ETH per token). Best = cheapest slice (most tokens per ETH). Worst = most expensive slice.

**Failed slices** — if any slices failed (RPC error, swap error), the summary lists the count and warns to check the wallet. Failed slices mean TotalAmount was not fully deployed.

---

## 8. Pitfalls and Limits

| Pitfall | Details | Fix |
|---|---|---|
| Price moves against you during execution | TWAP averages in both directions — if price falls throughout execution, you paid more for early slices than later ones. | TWAP does not hedge against a directional move. If you believe price will fall, wait. TWAP hedges against random timing uncertainty, not trends. |
| Small slices with high gas | If TotalAmount is small and Slices is large, each slice may be too small to justify gas costs. | Keep sliceAmount large enough to cover 2× expected gas. Use `speed estimate` to check gas before running. |
| IntervalSeconds too short | Very short intervals (< 30s) may hit RPC rate limits or 0x API rate limits. | Use IntervalSeconds >= 60 for production. Shorter is fine for DryRun testing. |
| Slice failure mid-execution | If a slice swap fails (network issue, nonce error), it is skipped and the script continues. The remaining TotalAmount is not rebalanced. | Check the summary for failed slices. Manually execute any failed slices if needed. |
| Dry-run prices vs. live prices | DryRun quotes prices at the moment of the quote call. Actual swap prices will differ slightly due to spread and slippage (typically 0.1–0.5%). | Dry-run is for timing and planning verification only, not price prediction. |
