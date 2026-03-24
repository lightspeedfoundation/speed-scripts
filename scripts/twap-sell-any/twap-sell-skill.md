## v2: configurable base token

Same behavior as `../scripts/<this-folder>/`, but the **quote currency** is not hard-coded to **ETH**. Use:

| | |
|---|---|
| **PowerShell** | `-BaseToken` (default `speed`), optional `-BaseTokenSymbol` |
| **Bash** | `--base-token` (default `speed`), optional `--base-token-symbol` |

Spend/quote amounts (e.g. `-Amount`, `-TotalAmount`, `-BasePerGrid`, `-BasePerRung`) are in **units of the base token**. Use `../scripts/` if you want ETH-only bots unchanged.

**Mainnet sample output (1000 SPEED sell test):** `../LIVE-TEST-1000-SPEED.md`

---

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
| `-Token`           | `--token`             | string  | required | Token contract address or alias (`speed`, `cbBTC`, …). |
| `-TokenAmount`     | `--token-amount`      | string  | required | Total token amount to sell, in human-readable units (e.g. `98000` or `0.00002287`). Run `speed balance` to check holdings. |
| `-Slices`          | `--slices`            | integer | `5`      | Number of equal sell slices. |
| `-IntervalSeconds` | `--interval-seconds`  | integer | `300`    | Wait time between slices (seconds). |
| `-TokenSymbol`     | `--tokensymbol`       | string  | `""`     | Optional display label for the token. |
| `-BaseToken`       | `--base-token`        | string  | `speed`  | Asset to receive when selling (`speed`, `eth`, …). |
| `-BaseTokenSymbol` | `--base-token-symbol` | string  | *(empty)* | Display label for base in logs. |
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
  Quote sliceAmount Token → BaseToken  (preview)
  Execute sell (or DryRun log)
  Record base received, price (base per token)
  Wait IntervalSeconds (skip on last slice)

Summary
  Total tokens sold, total base received
  Average price, price range
  Best/worst slice (highest / lowest base per token)
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

**Live capture (Base mainnet, 2025-03-22):** **1000** SPEED in **2** slices, **1 s** interval — see `../LIVE-TEST-1000-SPEED.md`.

```
[22:55:38] Slice 1/2 - quoting 500.000000000000000000 speed -> eth...
         Quote: 0.00005480 eth  (price: 0.00000011 eth/token)
         >>> speed swap -c base --sell speed --buy eth -a 500.000000000000000000 -y
         Slice 1 complete. Got 0.00005480 eth.
[22:55:55] Slice 2/2 - quoting 500.000000000000000000 speed -> eth...
         Quote: 0.00005480 eth  (price: 0.00000011 eth/token)
         Slice 2 complete. Got 0.00005480 eth.
```

Selling **SPEED** with default base: the script resolves **sell speed → buy eth** when token and base would both be `speed`.

### Summary block

```
=== TWAP Sell Complete ===
  Slices completed  : 2 / 2
  Total tokens sold : 1000.000000000000000000 speed
  Total base received: 0.00010960 eth
  Average price     : 0.00000011 eth/token
  Price range       : 0.00000011 to 0.00000011 eth/token
  Best slice        : Slice 1  (0.00000011 eth/token)
  Worst slice       : Slice 2  (0.00000011 eth/token)
```

---

## 7. Interpreting the Summary

**Average price** — mean **base received per token** across all slices. Higher is better (you sold at a better rate on average).

**Best slice** — the slice with the **highest** base per token (best exit). Script sorts by price; labels follow `-BaseToken`.

**Worst slice** — the slice with the **lowest** base per token. May indicate a brief dip or thin liquidity during that interval.

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
