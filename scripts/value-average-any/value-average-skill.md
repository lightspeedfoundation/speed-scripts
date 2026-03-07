# Value Averaging Skill

Complete reference for `value-average-any.ps1` and `value-average-any.sh` — value averaging accumulation bots built on the `speed` CLI.

---

## Table of Contents

1. [Concept](#1-concept)
2. [Parameters Reference](#2-parameters-reference)
3. [Value Averaging Math](#3-value-averaging-math)
4. [Running the Scripts](#4-running-the-scripts)
5. [Reading the Output](#5-reading-the-output)
6. [P/L Interpretation](#6-pl-interpretation)
7. [Comparison to DCA](#7-comparison-to-dca)
8. [Pitfalls and Limits](#8-pitfalls-and-limits)

---

## 1. Concept

Value averaging (VA) defines a target portfolio value that grows by a fixed amount each interval. On each interval, the bot measures the current position value and either buys the deficit or (optionally) sells the surplus. This makes the buy size a function of price: when price falls, the deficit is larger and more is bought; when price rises, the deficit is smaller and less is bought.

**When to use it:**
- You want to accumulate a token over N intervals (hours, days, weeks) in a mathematically optimal way
- You believe the token will appreciate over the accumulation period but want to average into volatility
- You want a principled, systematic strategy that reacts to price automatically rather than buying fixed amounts

**With `-AllowSell` off (default):**
The bot only buys. When the position exceeds target (price ran up), the interval is skipped without selling. This is "one-sided value averaging" — an accumulation-only approach.

**With `-AllowSell` on:**
The bot becomes a full two-way rebalancer: it buys deficits AND sells surpluses. This locks in gains on price spikes while continuing to buy on dips.

**Key difference from `dca`:** DCA buys a fixed ETH amount every interval regardless of price. VA calculates the buy size each interval based on how far the position value is from the target. In a falling market, VA systematically buys more than DCA; in a rising market, VA buys less.

---

## 2. Parameters Reference

| Parameter (PS1)       | Flag (SH)                  | Type   | Default | Description |
|---|---|---|---|---|
| `-Chain`              | `--chain`                  | string | required | Chain name or ID (`base`, `ethereum`, `arbitrum`, etc.) |
| `-Token`              | `--token`                  | string | required | Token contract address or alias (`speed`). ETH is always the quote currency. |
| `-TargetIncrement`    | `--target-increment`       | float  | required | ETH by which the target portfolio value grows each interval. |
| `-Intervals`          | `--intervals`              | integer | `20`   | Total number of intervals to run. |
| `-IntervalSeconds`    | `--interval-seconds`       | integer | `3600` | Seconds between intervals (default 1 hour). |
| `-MaxBuyPerInterval`  | `--max-buy-per-interval`   | float  | `TargetIncrement × 3` | ETH cap per buy action. Prevents runaway buys after large drops. |
| `-AllowSell`          | `--allow-sell`             | switch | off     | When set, sell the surplus fraction when position exceeds target. |
| `-TokenSymbol`        | `--tokensymbol`            | string | address | Display label for the token in output. |
| `-DryRun`             | `--dry-run`                | switch | off     | Print plan and projected actions; no swaps execute. |

---

## 3. Value Averaging Math

### Target value trajectory

```
targetValue[n] = TargetIncrement × n

where n is the interval number (1-indexed).
```

The target grows linearly at `TargetIncrement` ETH per interval.

### Deficit computation

```
currentValue = quote(accumulatedTokenStr → ETH)   [0 if no tokens held]
deficit      = targetValue[n] − currentValue
```

If `deficit > 0`: below target → buy.
If `deficit < 0`: above target → skip (or sell if `AllowSell`).
If `deficit ≈ 0`: at target → hold.

### Buy amount

```
buyETH = min(deficit, MaxBuyPerInterval)
```

The buy is skipped if `buyETH < 0.0001` (0x dust limit).

### Sell amount (only when `AllowSell`)

```
sellRatio    = surplus / currentValue   (capped at 1.0)
sellTokenStr = accumulatedTokenStr × sellRatio
```

This sells exactly the fraction of the position that represents the surplus above target.

### Example walkthrough

With `TargetIncrement = 0.001`, `Intervals = 5`, price stable at 1000 tokens per 0.001 ETH:

| Interval | Target | Current Value | Deficit | Action | Buy ETH |
|---|---|---|---|---|---|
| 1 | 0.001 | 0.000 | +0.001 | BUY | 0.001 |
| 2 | 0.002 | 0.001 | +0.001 | BUY | 0.001 |
| 3 | 0.003 | 0.002 | +0.001 | BUY | 0.001 |

Now suppose price doubles between interval 3 and 4:

| Interval | Target | Current Value | Deficit | Action | Buy ETH |
|---|---|---|---|---|---|
| 4 | 0.004 | 0.006 | −0.002 | HOLD (or SELL if AllowSell) | 0 |
| 5 | 0.005 | 0.006 | −0.001 | HOLD (or SELL if AllowSell) | 0 |

Now suppose price halves between interval 3 and 4 instead:

| Interval | Target | Current Value | Deficit | Action | Buy ETH |
|---|---|---|---|---|---|
| 4 | 0.004 | 0.001 | +0.003 | BUY (capped at MaxBuy) | min(0.003, MaxBuy) |

---

## 4. Running the Scripts

### PowerShell — common scenarios

```powershell
# SPEED: buy 0.001 ETH per hour for 24 hours
.\value-average-any.ps1 -Chain base -Token speed -TargetIncrement 0.001 -Intervals 24 -IntervalSeconds 3600

# SPEED: buy + sell with allow-sell (full rebalancer)
.\value-average-any.ps1 -Chain base -Token speed `
    -TargetIncrement 0.001 -Intervals 10 -IntervalSeconds 1800 -AllowSell

# cbBTC: 12 intervals, 2-hour spacing, allow sell
.\value-average-any.ps1 -Chain base `
    -Token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf `
    -TokenSymbol cbBTC `
    -TargetIncrement 0.002 -Intervals 12 -IntervalSeconds 7200 -AllowSell

# Cap buy size: protect against large deficits after price crash
.\value-average-any.ps1 -Chain base -Token speed `
    -TargetIncrement 0.001 -Intervals 20 -MaxBuyPerInterval 0.002 -IntervalSeconds 3600

# Dry run: preview interval actions without spending
.\value-average-any.ps1 -Chain base -Token speed -TargetIncrement 0.001 -Intervals 10 -DryRun
```

### Bash — common scenarios

```bash
# SPEED: buy 0.001 ETH per hour for 24 hours
./value-average-any.sh --chain base --token speed \
    --target-increment 0.001 --intervals 24 --interval-seconds 3600

# SPEED: buy + sell with allow-sell
./value-average-any.sh --chain base --token speed \
    --target-increment 0.001 --intervals 10 --interval-seconds 1800 --allow-sell

# cbBTC, 12 intervals, 2-hour spacing
./value-average-any.sh --chain base \
    --token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf \
    --tokensymbol cbBTC \
    --target-increment 0.002 --intervals 12 --interval-seconds 7200 --allow-sell

# Dry run
./value-average-any.sh --chain base --token speed \
    --target-increment 0.001 --intervals 10 --dry-run

# Make executable first (Linux/Mac)
chmod +x value-average-any.sh
```

---

## 5. Reading the Output

Example console output:

```
=== Interval 3/20  [10:05:30] ===
  Target value    : 0.00300000 ETH
  Current value   : 0.00185000 ETH  (12000.0000 SPEED held)
  Deficit/Surplus : +0.00115000 ETH
  Avg entry cost  : 0.00000010 ETH per SPEED
  Action          : BUY 0.00115000 ETH of SPEED
  >>> speed swap -c base --sell eth --buy speed -a 0.00115000 -y
  TX: 0xabc...
```

After price spike (AllowSell mode):

```
=== Interval 5/20  [12:05:30] ===
  Target value    : 0.00500000 ETH
  Current value   : 0.00750000 ETH  (30000.0000 SPEED held)
  Deficit/Surplus : -0.00250000 ETH
  Avg entry cost  : 0.00000009 ETH per SPEED
  Action          : SELL 10000.0000 SPEED  (surplus: 0.00250000 ETH, 33.33% of position)
  >>> speed swap -c base --sell speed --buy eth -a 10000.0000 -y
  TX: 0xdef...
```

**Field meanings:**

| Field | Description |
|---|---|
| `Target value` | The target portfolio ETH value for this interval |
| `Current value` | ETH return for the current accumulated token position |
| `Deficit/Surplus` | Positive = below target (buy); negative = above target (sell or hold) |
| `Avg entry cost` | Total ETH spent / total tokens accumulated (cost basis per token) |
| `Action: BUY` | Buying `min(deficit, MaxBuyPerInterval)` ETH of token |
| `Action: SELL` | Selling the surplus fraction (only with `AllowSell`) |
| `Action: HOLD` | Position at or above target, `AllowSell` is off |
| `Action: SKIP` | Buy amount < 0.0001 ETH dust limit |

---

## 6. P/L Interpretation

**Cost basis:**
```
avgEntryCost = totalEthSpent / accumulatedTokens   (ETH per token)
```

**Current position value:**
```
quote(accumulatedTokenStr → ETH) = currentValueETH
```

**Unrealised P/L:**
```
P/L % = (currentValueETH − totalEthSpent) / totalEthSpent × 100
```

Note: `totalEthSpent` grows with each buy; `totalEthReceived` grows with each sell (when `AllowSell` is set). The script reports `netEthDeployed = totalEthSpent − totalEthReceived` as the net capital at risk.

**The VA edge:** Because more ETH is deployed when price is low, the average entry cost is lower than the time-weighted average price over the accumulation period. The degree of improvement over DCA depends on price volatility — the more volatile the token, the greater the advantage of VA over fixed DCA.

---

## 7. Comparison to DCA

| Dimension | DCA (`speed dca`) | Value Averaging |
|---|---|---|
| Buy size | Fixed per interval | Variable — function of deficit |
| Buy frequency | Every interval | Every interval (unless surplus) |
| Behaviour on price drop | Same buy | Larger buy (larger deficit) |
| Behaviour on price rise | Same buy | Smaller buy (smaller deficit) |
| Two-way rebalancing | No | Yes (with `AllowSell`) |
| Total ETH required | `amount × count` exactly | Variable; capped by `MaxBuyPerInterval` per interval |
| Optimal for | Simple accumulation, predictable spend | Lower average cost, systematic rebalancing |

---

## 8. Pitfalls and Limits

| Pitfall | Details | Fix |
|---|---|---|
| Large price crash creates huge deficit | If price drops 80%, the deficit in one interval could exceed wallet balance. | Set `MaxBuyPerInterval` to a safe cap (e.g. 3–5× `TargetIncrement`). The bot will buy up to the cap, leaving residual deficit for future intervals. |
| Buy below dust limit | When deficit is tiny (e.g. 0.00003 ETH), the buy is skipped. | Normal. The deficit rolls over to the next interval where it compounds with the next `TargetIncrement`. |
| `AllowSell` trims too aggressively | A one-interval price spike could sell a large fraction of the position before price continues higher. | Use `AllowSell` only when you are comfortable trimming gains. For pure accumulation runs, leave it off. |
| No exit strategy | The script accumulates tokens and stops. Final position is not sold automatically. | After the script completes, use `trailing-stop-any` or `limit-order-any` on the accumulated position size. |
| Accumulated token amount drift | Token amount is tracked by summing buy quotes (expected amounts). Actual received amounts may differ slightly due to slippage. | The difference is small (0.1–0.5%). The current value quote on each interval will reflect actual wallet balance indirectly through the price. |
| Long interval sessions | A 24-interval × 1-hour session runs for 24 hours. If the terminal closes, the session ends. | Run inside a persistent shell session (`screen`, `tmux`, or a background process). On Windows, use Task Scheduler or a persistent PowerShell host. |
| Dry-run position diverges from real | In dry-run, token accumulation uses the quote at the time of the simulated buy. Real execution has slippage. | Use dry-run to preview the interval cadence and buy size logic only, not to project exact token balances. |
